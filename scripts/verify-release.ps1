#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BundlePath,
    [ValidateRange(1024,65535)][int]$WebPort=18280,
    [ValidateRange(1024,65535)][int]$ApiPort=18200)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/docker-tools.ps1"
$bundle = (Resolve-Path -LiteralPath $BundlePath).Path
$definition = Read-NotesReleaseDefinition $bundle
$manifest = $definition.Manifest
$archive = "$bundle/notes-images.tar.gz"
Assert-NotesPorts $WebPort $ApiPort
Invoke-NotesDocker -Arguments @('load', '-i', $archive)
foreach ($image in $manifest.images.PSObject.Properties) {
    $actual = Invoke-NotesDocker -Arguments @('image','inspect','--format','{{.Id}}',$image.Name) -Capture
    if ($actual -ne $image.Value) { throw "Release image ID mismatch: $($image.Name)" }
}
$project = 'notes-release-check-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$envFile = "$bundle/.env.verify"
if (Test-Path -LiteralPath $envFile) { throw 'Another verification environment already exists.' }
$settings = @{WEB_PORT="$WebPort"; API_PORT="$ApiPort"; POSTGRES_DB='notes_release'; POSTGRES_USER='notes_release'; POSTGRES_PASSWORD=[guid]::NewGuid().ToString('N')}
Write-NotesEnvironment $envFile $settings
$saved = @{}
$started = $false
$failure = $null
$cleanupFailure = $null
$argsCompose = @('compose','--project-directory',$bundle,'--env-file',$envFile,'--env-file',"$bundle/.env.images",'-p',$project,'-f',"$bundle/compose.yaml",'-f',"$bundle/compose.release.yaml")
try {
    foreach ($name in $settings.Keys) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process'); [Environment]::SetEnvironmentVariable($name,$settings[$name],'Process') }
    # Prevent shell overrides from substituting images in this verification.
    foreach ($name in $definition.Environment.Keys) {
        $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
        [Environment]::SetEnvironmentVariable($name,$definition.Environment[$name],'Process')
    }
    Invoke-NotesDocker -Arguments ($argsCompose + @('config','--quiet'))
    $started = $true
    Invoke-NotesDocker -Arguments ($argsCompose + @('up','-d','--wait','--wait-timeout','120','--no-build','--pull','never'))
    $url = "http://127.0.0.1:$WebPort"
    $health = Invoke-RestMethod "$url/api/health" -TimeoutSec 20
    if ($health.status -ne 'ok') { throw 'Packaged app health failed.' }
    $note = Invoke-RestMethod "$url/api/notes" -Method Post -ContentType application/json -Body '{"title":"Release check","content":"Runs without source folders"}' -TimeoutSec 20
    $read = Invoke-RestMethod "$url/api/notes/$($note.id)" -TimeoutSec 20
    if ($read.content -ne 'Runs without source folders') { throw 'Packaged CRUD failed.' }
    $html = Invoke-WebRequest "$url/" -TimeoutSec 20
    if ($html.Content -notmatch 'id="root"') { throw 'Packaged React page failed.' }
} catch { $failure = $_ }
finally {
    try {
        if ($started) { Invoke-NotesDocker -Arguments ($argsCompose + @('down','--volumes','--remove-orphans','--timeout','10')) }
        Remove-Item -LiteralPath $envFile -Force
    } catch { $cleanupFailure = $_ }
    finally { Restore-NotesEnvironment $saved }
}
if ($null -ne $failure) {
    if ($null -ne $cleanupFailure) { Write-Warning "Release cleanup also failed for $project. Environment file retained: $envFile" }
    throw $failure
}
if ($null -ne $cleanupFailure) { throw $cleanupFailure }
Write-Host 'PASS: release checksum, image IDs, migrations, React, API and PostgreSQL without builds or pulls.'
