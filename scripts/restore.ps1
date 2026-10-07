#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [ValidateRange(1024, 65535)][int]$WebPort = 19080,
    [ValidateRange(1024, 65535)][int]$ApiPort = 19000,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$root = Split-Path $PSScriptRoot -Parent
$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
$manifestPath = "$BackupPath.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Backup checksum manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.format_version -ne 1 -or $manifest.component -ne 'postgresql' -or $manifest.postgres_major -ne 17 -or $manifest.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Unsupported backup manifest.'
}
if ((Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.sha256 -or (Get-Item -LiteralPath $BackupPath).Length -ne $manifest.bytes) {
    throw 'Backup SHA256 or size mismatch. No containers were started.'
}
Get-Command docker -ErrorAction Stop | Out-Null
Assert-NotesPorts $WebPort $ApiPort
$project = 'notes-restore-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$recoveryDirectory = Join-Path $root "backups/$project"
$envFile = Join-Path $recoveryDirectory '.env'
$settings = @{
    WEB_PORT = "$WebPort"; API_PORT = "$ApiPort"
    POSTGRES_DB = 'notes_restore'; POSTGRES_USER = 'notes_restore'
    POSTGRES_PASSWORD = [guid]::NewGuid().ToString('N')
}
$savedEnvironment = @{}
$started = $false
$success = $false
$containerFile = '/tmp/notes-restore.dump'
$composeArgs = Get-NotesComposeArguments $root $project $envFile

try {
    New-Item -ItemType Directory -Path $recoveryDirectory | Out-Null
    Write-NotesEnvironment $envFile $settings
    foreach ($name in $settings.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
    $started = $true
    Invoke-NotesDocker -Arguments ($composeArgs + @('up', '-d', '--wait', '--wait-timeout', '120', 'db', 'redis'))
    Invoke-NotesDocker -Arguments ($composeArgs + @('cp', $BackupPath, "db:$containerFile"))
    Invoke-NotesDocker -Arguments ($composeArgs + @('exec', '-T', 'db', 'sh', '-c', 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --exit-on-error --single-transaction "$1"', 'sh', $containerFile))
    Invoke-NotesDocker -Arguments ($composeArgs + @('exec', '-T', 'db', 'rm', '-f', $containerFile))
    # Pending app migrations run over the restored schema before the API starts.
    Invoke-NotesDocker -Arguments ($composeArgs + @('up', '-d', '--build', '--wait', '--wait-timeout', '120'))
    $url = "http://127.0.0.1:$WebPort"
    $health = Invoke-RestMethod "$url/api/health" -TimeoutSec 20
    if ($health.status -ne 'ok') { throw 'Restored app failed its health check.' }
    $fingerprint = Get-NotesFingerprint $url
    $success = $true
    Write-Host "PASS: archive restored into isolated project $project."
    [pscustomobject]@{
        ProjectName = $project; WebUrl = $url; EnvFile = $envFile
        NoteCount = $fingerprint.Count; NotesSha256 = $fingerprint.Sha256
        RemovedAfterVerification = [bool]$VerifyOnly
    }
} finally {
    try {
        if ($started -and ($VerifyOnly -or -not $success)) {
            Invoke-NotesDocker -Arguments ($composeArgs + @('down', '--volumes', '--remove-orphans', '--timeout', '10'))
            if (Test-Path -LiteralPath $envFile) { Remove-Item -LiteralPath $envFile -Force }
        }
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}
