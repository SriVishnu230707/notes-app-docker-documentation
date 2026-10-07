#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-f0-9]{40}$')][string]$Revision, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$root = Split-Path $PSScriptRoot -Parent
if (-not $Revision) {
    $Revision = & git -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $Revision -notmatch '^[a-f0-9]{40}$') { throw 'A full Git revision is required.' }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "artifacts/releases/$Revision" }
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $destination) { throw 'Release destination already exists. Choose a new directory.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$api = "notes-app-api:sha-$Revision"
$web = "notes-app-web:sha-$Revision"
Invoke-NotesDocker -Arguments @('build', '--target', 'production', '--label', "org.opencontainers.image.revision=$Revision", '-t', $api, "$root/backend")
Invoke-NotesDocker -Arguments @('build', '--target', 'production', '--label', "org.opencontainers.image.revision=$Revision", '-t', $web, "$root/frontend")
$db = 'postgres:17.11-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
$redis = 'redis:7.4.11-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499'
Invoke-NotesDocker -Arguments @('pull', $db)
Invoke-NotesDocker -Arguments @('pull', $redis)
# save/load retains tags, not registry RepoDigests. Bundle tags have recorded IDs.
$dbTag = 'notes-app-postgres:17.11'
$redisTag = 'notes-app-redis:7.4.11'
Invoke-NotesDocker -Arguments @('tag', $db, $dbTag)
Invoke-NotesDocker -Arguments @('tag', $redis, $redisTag)
$tar = Join-Path $destination 'notes-images.tar'
$archive = "$tar.gz"
try {
    Invoke-NotesDocker -Arguments @('save', '-o', $tar, $api, $web, $dbTag, $redisTag)
    $inputStream = [IO.File]::OpenRead($tar)
    try {
        $outputStream = [IO.File]::Create($archive)
        try {
            $gzip = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose() }
        } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
} finally { if (Test-Path -LiteralPath $tar) { Remove-Item -LiteralPath $tar } }
foreach ($file in @('compose.yaml', 'compose.release.yaml', '.env.example')) { Copy-Item -LiteralPath "$root/$file" -Destination $destination }
Write-NotesEnvironment "$destination/.env.images" @{ NOTES_API_IMAGE=$api; NOTES_WEB_IMAGE=$web; NOTES_DB_IMAGE=$dbTag; NOTES_REDIS_IMAGE=$redisTag }
$images = @{}
foreach ($tag in @($api, $web, $dbTag, $redisTag)) { $images[$tag] = Invoke-NotesDocker -Arguments @('image', 'inspect', '--format', '{{.Id}}', $tag) -Capture }
$manifest = @{ revision=$Revision; created_at_utc=[DateTime]::UtcNow.ToString('o'); sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant(); images=$images }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$destination/release.json" -Encoding utf8
Copy-Item -LiteralPath "$root/docs/release-bundle.md" -Destination "$destination/README.md"
Write-Host "PASS: release bundle written to $destination"
return [pscustomobject]@{ Directory=$destination; ArchivePath=$archive; Revision=$Revision }
