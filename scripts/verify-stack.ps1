#Requires -Version 7.0
# Verify a disposable Compose project without changing the normal notes-app stack.
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$WebPort = 18080,
    [ValidateRange(1024, 65535)][int]$ApiPort = 18000,
    [switch]$BrowserTests
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$root = Split-Path $PSScriptRoot -Parent
$project = 'notes-check-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$baseArgs = @('compose', '--project-directory', $root, '--env-file', "$root/.env.example", '-p', $project, '-f', "$root/compose.yaml")
$savedEnvironment = @{}
$started = $false
$failure = $null
$cleanupFailed = $false

function Invoke-Compose {
    param([string[]]$Arguments, [switch]$TestImage)
    $commandArgs = $baseArgs
    if ($TestImage) { $commandArgs += @('-f', "$root/compose.test.yaml") }
    & docker @commandArgs @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed: $($Arguments -join ' ')" }
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Api {
    param([string]$Path, [string]$Method = 'Get', $Body)
    $request = @{ Uri = "http://127.0.0.1:$WebPort/api$Path"; Method = $Method; TimeoutSec = 20 }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = $Body | ConvertTo-Json -Compress
    }
    Invoke-RestMethod @request
}

try {
    Get-Command docker -ErrorAction Stop | Out-Null
    if ($BrowserTests) { Get-Command npm -ErrorAction Stop | Out-Null }
    Assert-Check ($WebPort -ne $ApiPort) 'Web and API ports must differ.'
    foreach ($port in @($WebPort, $ApiPort)) {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        try { $listener.Start() }
        catch { throw "Port $port is occupied. Choose different -WebPort and -ApiPort values." }
        finally { $listener.Stop() }
    }
    # Override ambient shell values as well as .env; restore everything afterwards.
    $settings = @{
        WEB_PORT = "$WebPort"; API_PORT = "$ApiPort"
        POSTGRES_DB = 'notes_check'; POSTGRES_USER = 'notes_check'
        POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
        NOTES_E2E_BASE_URL = "http://127.0.0.1:$WebPort"
    }
    foreach ($name in $settings.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
    Write-Host "Verifying isolated project $project on http://127.0.0.1:$WebPort"
    Invoke-Compose -Arguments @('config', '--quiet')
    $started = $true
    Invoke-Compose -Arguments @('up', '-d', '--build', '--wait', '--wait-timeout', '120')
    Invoke-Compose -Arguments @('exec', '-T', 'web', 'nginx', '-t')

    Write-Host 'Running API contract, PostgreSQL and Redis integration tests...'
    Invoke-Compose -TestImage -Arguments @('run', '--rm', '--build', '--no-deps', '-e', 'RUN_API_INTEGRATION=1', 'api', 'python', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py', '-v')

    $health = Invoke-Api '/health'
    Assert-Check ($health.status -eq 'ok' -and $health.postgres -eq 'ok' -and $health.redis -eq 'ok') 'Dependency health check failed.'
    $page = Invoke-WebRequest "http://127.0.0.1:$WebPort/" -UseBasicParsing -TimeoutSec 20
    Assert-Check ($page.StatusCode -eq 200 -and $page.Content -match 'id="root"') 'React entry page was not served.'
    $missing = Invoke-WebRequest "http://127.0.0.1:$WebPort/assets/missing-check.js" -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 20
    Assert-Check ($missing.StatusCode -eq 404) 'Missing assets must return 404, rather than the React HTML page.'

    $before = (Invoke-Api '/stats').writes
    $note = Invoke-Api '/notes' 'Post' @{ title = 'Docker persistence check'; content = 'Created through Nginx.' }
    Assert-Check ($null -ne $note.id) 'Create did not return a note ID.'
    $updated = Invoke-Api "/notes/$($note.id)" 'Put' @{ title = 'Docker persistence check'; content = 'Survives container replacement.' }
    Assert-Check ($updated.content -eq 'Survives container replacement.') 'Update failed.'
    $writes = (Invoke-Api '/stats').writes
    Assert-Check ($writes -eq ($before + 2)) 'Redis did not count create and update.'
    $oldDb = @(Invoke-Compose -Arguments @('ps', '-q', 'db'))[-1]

    Write-Host 'Removing test containers, keeping volumes, and recreating the stack...'
    Invoke-Compose -Arguments @('down', '--timeout', '10')
    # Use the production target again after the one-off test-image build.
    Invoke-Compose -Arguments @('up', '-d', '--build', '--wait', '--wait-timeout', '120')
    $newDb = @(Invoke-Compose -Arguments @('ps', '-q', 'db'))[-1]
    Assert-Check ($oldDb -ne $newDb) 'Database container was not replaced.'
    $persisted = Invoke-Api "/notes/$($note.id)"
    Assert-Check ($persisted.content -eq $updated.content -and $persisted.created_at -eq $note.created_at) 'PostgreSQL note did not survive container replacement.'
    Assert-Check ((Invoke-Api '/stats').writes -eq $writes) 'Redis counter did not survive container replacement.'
    Invoke-Api "/notes/$($note.id)" 'Delete' | Out-Null
    $remaining = @(Invoke-Api '/notes')
    Assert-Check (@($remaining | Where-Object id -eq $note.id).Count -eq 0) 'Deleted note still appears in the list.'

    if ($BrowserTests) {
        Push-Location "$root/frontend"
        try {
            & npm ci
            if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
            & npm run test:unit
            if ($LASTEXITCODE -ne 0) { throw 'Frontend unit checks failed.' }
            & npm run test:live
            if ($LASTEXITCODE -ne 0) { throw 'Live browser checks failed.' }
        } finally { Pop-Location }
    }
    Invoke-Compose -Arguments @('ps', '-a')
    Write-Host 'PASS: Docker startup, migrations, backend tests, Nginx, CRUD and both persistent volumes.'
} catch {
    $failure = $_
    if ($started) {
        & docker @baseArgs logs --no-color --tail 30
    }
} finally {
    if ($started) {
        # Only this invocation's uniquely named project and temporary data are removed.
        & docker @baseArgs down --volumes --remove-orphans --timeout 10
        $cleanupFailed = $LASTEXITCODE -ne 0
        if ($cleanupFailed) { Write-Warning "Cleanup failed for $project. Retry: docker compose --project-directory '$root' --env-file '$root/.env.example' -f '$root/compose.yaml' -p $project down --volumes" }
    }
    Restore-NotesEnvironment $savedEnvironment
}
if ($null -ne $failure) { throw $failure }
if ($cleanupFailed) { throw "Verification passed, but cleanup failed for $project." }
