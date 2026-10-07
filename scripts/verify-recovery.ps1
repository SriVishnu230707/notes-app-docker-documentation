#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$WebPort = 18180,
    [ValidateRange(1024, 65535)][int]$ApiPort = 18100,
    [ValidateRange(1024, 65535)][int]$RestoreWebPort = 19180,
    [ValidateRange(1024, 65535)][int]$RestoreApiPort = 19100
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$root = Split-Path $PSScriptRoot -Parent
Assert-NotesPorts $WebPort $ApiPort
Assert-NotesPorts $RestoreWebPort $RestoreApiPort
if (@(@($WebPort, $ApiPort, $RestoreWebPort, $RestoreApiPort) | Select-Object -Unique).Count -ne 4) { throw 'All four recovery-check ports must differ.' }
$project = 'notes-drill-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$directory = Join-Path $root "test-results/$project"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$envFile = Join-Path $directory '.env'
$settings = @{ WEB_PORT = "$WebPort"; API_PORT = "$ApiPort"; POSTGRES_DB = 'notes_drill'; POSTGRES_USER = 'notes_drill'; POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N') }
Write-NotesEnvironment $envFile $settings
$savedEnvironment = @{}
$started = $false
$failure = $null
$cleanupFailure = $null
$composeArgs = Get-NotesComposeArguments $root $project $envFile
try {
    foreach ($name in $settings.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
    $started = $true
    Invoke-NotesDocker -Arguments ($composeArgs + @('up', '-d', '--build', '--wait', '--wait-timeout', '120'))
    $url = "http://127.0.0.1:$WebPort"
    foreach ($title in @('Recovery check', 'Unicode café — recovery')) {
        $body = @{title=$title; content="Quotes: ' and Unicode: café"} | ConvertTo-Json
        Invoke-RestMethod "$url/api/notes" -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20 | Out-Null
    }
    $source = Get-NotesFingerprint $url
    $backup = & "$PSScriptRoot/backup.ps1" -ProjectName $project -EnvFile $envFile -OutputDirectory $directory
    $restored = & "$PSScriptRoot/restore.ps1" -BackupPath $backup.ArchivePath -WebPort $RestoreWebPort -ApiPort $RestoreApiPort -VerifyOnly
    if ($restored.NoteCount -ne 2 -or $restored.NotesSha256 -ne $source.Sha256) { throw 'Restored notes differ from the original data.' }
    if ($restored.ProjectName -eq $project) { throw 'Recovery must use a separate project.' }
    Write-Host 'PASS: restored note IDs, titles, Unicode, content and timestamps match the source.'

    $corrupt = Join-Path $directory 'corrupt.dump'
    Copy-Item -LiteralPath $backup.ArchivePath -Destination $corrupt
    Copy-Item -LiteralPath $backup.ManifestPath -Destination "$corrupt.json"
    [IO.File]::AppendAllText($corrupt, 'tampered')
    $refused = $false
    try { & "$PSScriptRoot/restore.ps1" -BackupPath $corrupt -WebPort $RestoreWebPort -ApiPort $RestoreApiPort -VerifyOnly | Out-Null }
    catch { if ($_.Exception.Message -match 'SHA256 or size mismatch') { $refused = $true } else { throw } }
    if (-not $refused) { throw 'Tampered archive was not rejected.' }
    Write-Host 'PASS: tampered backup refused before creating recovery containers.'
} catch { $failure = $_ }
finally {
    try {
        if ($started) { Invoke-NotesDocker -Arguments ($composeArgs + @('down', '--volumes', '--remove-orphans', '--timeout', '10')) }
        if (Test-Path -LiteralPath $envFile) { Remove-Item -LiteralPath $envFile -Force }
    } catch { $cleanupFailure = $_ }
    finally {
        Restore-NotesEnvironment $savedEnvironment
    }
}
if ($null -ne $failure) {
    if ($null -ne $cleanupFailure) { Write-Warning "Drill cleanup also failed for $project. Environment file retained: $envFile" }
    throw $failure
}
if ($null -ne $cleanupFailure) { throw $cleanupFailure }
