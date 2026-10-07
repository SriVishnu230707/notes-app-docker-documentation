#Requires -Version 7.0
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$WebPort=18480,
      [ValidateRange(1024,65535)][int]$ApiPort=18400)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/docker-tools.ps1"
$root=Split-Path $PSScriptRoot -Parent
Assert-NotesPorts $WebPort $ApiPort
$project='notes-dev-check-'+[guid]::NewGuid().ToString('N').Substring(0,12)
$directory=Join-Path $root "test-results/$project"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$envFile=Join-Path $directory '.env'
$settings=@{WEB_PORT="$WebPort";API_PORT="$ApiPort";POSTGRES_DB='notes_dev_check';POSTGRES_USER='notes_dev_check';POSTGRES_PASSWORD=[guid]::NewGuid().ToString('N')}
Write-NotesEnvironment $envFile $settings
$composeArgs=(Get-NotesComposeArguments $root $project $envFile)+@('-f',"$root/compose.dev.yaml")
$saved=@{};$started=$false;$failure=$null;$cleanupFailure=$null
try {
    foreach($name in $settings.Keys){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$settings[$name],'Process')}
    Invoke-NotesDocker -Arguments ($composeArgs+@('config','--quiet'))
    $started=$true
    Invoke-NotesDocker -Arguments ($composeArgs+@('up','-d','--build','--wait','--wait-timeout','120'))
    $url="http://127.0.0.1:$WebPort"
    foreach($path in @('/src/main.jsx','/src/App.jsx')) {
        $response=Invoke-WebRequest "$url$path" -TimeoutSec 20
        if($response.StatusCode -ne 200 -or $response.Content -notmatch 'import'){throw 'Vite source transformation failed.'}
    }
    $note=Invoke-RestMethod "$url/api/notes" -Method Post -Headers @{Origin=$url} -ContentType application/json -Body '{"title":"Development proxy check","content":"Same-origin write through Vite"}' -ResponseHeadersVariable createdHeaders -TimeoutSec 20
    $read=Invoke-RestMethod "$url/api/notes/$($note.id)" -TimeoutSec 20
    if($read.content -ne 'Same-origin write through Vite'){throw 'Development proxy CRUD failed.'}
    # Use the server ETag verbatim; PowerShell converts JSON dates to DateTime.
    $etag=[string]@($createdHeaders['ETag'])[0]
    Invoke-RestMethod "$url/api/notes/$($note.id)" -Method Delete -Headers @{Origin=$url;'If-Match'=$etag} -TimeoutSec 20 | Out-Null
    & "$PSScriptRoot/status.ps1" -ProjectName $project -EnvFile $envFile
} catch {$failure=$_}
finally {
    try {if($started){Invoke-NotesDocker -Arguments ($composeArgs+@('down','--volumes','--remove-orphans','--timeout','10'))};Remove-Item -LiteralPath $envFile -Force}
    catch {$cleanupFailure=$_}
    finally {Restore-NotesEnvironment $saved}
}
if($null -ne $failure){if($null -ne $cleanupFailure){Write-Warning "Cleanup also failed for $project; retain $envFile"};throw $failure}
if($null -ne $cleanupFailure){throw $cleanupFailure}
Write-Host 'PASS: development startup, Vite transforms, same-origin CRUD and project-specific status.'
