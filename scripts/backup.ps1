#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')][string]$ProjectName = 'notes-app',
    [string]$EnvFile,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$root = Split-Path $PSScriptRoot -Parent
if (-not $EnvFile) { $EnvFile = "$root/.env" }
if (-not $OutputDirectory) { $OutputDirectory = "$root/backups" }
$EnvFile = (Resolve-Path -LiteralPath $EnvFile).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$composeArgs = Get-NotesComposeArguments $root $ProjectName $EnvFile
$id = [guid]::NewGuid().ToString('N')
$containerFile = "/tmp/notes-backup-$id.dump"
$archive = Join-Path $OutputDirectory ("notes-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$id.dump")
$partial = "$archive.partial"
$created = $false

try {
    Get-Command docker -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $serverVersion = @(Invoke-NotesDocker -Capture -Arguments ($composeArgs + @('exec', '-T', 'db', 'sh', '-c', 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SHOW server_version_num"')))[-1]
    if ($serverVersion -notmatch '^17\d{4}$') { throw 'This recovery workflow supports PostgreSQL 17.' }
    $created = $true
    Invoke-NotesDocker -Arguments ($composeArgs + @('exec', '-T', 'db', 'sh', '-c', 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --file="$1"', 'sh', $containerFile))
    # Validate the custom archive before copying it from the container.
    Invoke-NotesDocker -Capture -Arguments ($composeArgs + @('exec', '-T', 'db', 'pg_restore', '--list', $containerFile)) | Out-Null
    Invoke-NotesDocker -Arguments ($composeArgs + @('cp', "db:$containerFile", $partial))
    if ((Get-Item -LiteralPath $partial).Length -eq 0) { throw 'The backup archive is empty.' }
    $hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        format_version = 1
        component = 'postgresql'
        postgres_major = 17
        server_version_num = [int]$serverVersion
        created_utc = [DateTime]::UtcNow.ToString('o')
        sha256 = $hash
        bytes = (Get-Item -LiteralPath $partial).Length
    }
    [IO.File]::WriteAllText("$archive.json.partial", ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $partial -Destination $archive
    Move-Item -LiteralPath "$archive.json.partial" -Destination "$archive.json"
    Write-Host 'PASS: PostgreSQL custom-format backup and checksum manifest created.'
    [pscustomobject]@{ ArchivePath = $archive; ManifestPath = "$archive.json"; Sha256 = $hash }
} finally {
    if ($created) {
        try { Invoke-NotesDocker -Arguments ($composeArgs + @('exec', '-T', 'db', 'rm', '-f', $containerFile)) }
        catch { Write-Warning "Could not remove the temporary backup inside $ProjectName." }
    }
    foreach ($unfinished in @($partial, "$archive.json.partial")) {
        if (Test-Path -LiteralPath $unfinished) { Remove-Item -LiteralPath $unfinished }
    }
}
