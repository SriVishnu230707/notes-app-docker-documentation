#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1,16)][int]$Concurrency=4,
    [ValidateRange(1,100)][int]$Iterations=25,
    [ValidateRange(1,60000)][int]$MaxP95Ms=2000,
    [ValidateRange(1024,65535)][int]$WebPort=18380,
    [ValidateRange(1024,65535)][int]$ApiPort=18300
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/docker-tools.ps1"
$root=Split-Path $PSScriptRoot -Parent
Assert-NotesPorts $WebPort $ApiPort
$project='notes-load-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$directory=Join-Path $root "test-results/$project"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$envFile=Join-Path $directory '.env'
$settings=@{WEB_PORT="$WebPort";API_PORT="$ApiPort";POSTGRES_DB='notes_load';POSTGRES_USER='notes_load';POSTGRES_PASSWORD=[guid]::NewGuid().ToString('N')}
Write-NotesEnvironment $envFile $settings
$composeArgs=Get-NotesComposeArguments $root $project $envFile
$saved=@{}; $started=$false; $failure=$null; $cleanupFailure=$null; $report=$null
try {
    foreach($name in $settings.Keys){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$settings[$name],'Process')}
    Invoke-NotesDocker -Arguments ($composeArgs + @('config','--quiet'))
    $started=$true
    Invoke-NotesDocker -Arguments ($composeArgs + @('up','-d','--build','--wait','--wait-timeout','120'))
    # Verify real Engine limits, rather than only checking YAML declarations.
    $runningIds=@()
    foreach($service in @('db','redis','api','web','migrate')) {
        $id=Invoke-NotesDocker -Capture -Arguments ($composeArgs + @('ps','-a','-q',$service))
        $container=(@(Invoke-NotesDocker -Capture -Arguments @('inspect',$id)) -join "`n") | ConvertFrom-Json
        $config=$container[0].HostConfig
        if($service -ne 'migrate'){$runningIds+=$id}
        if($config.Memory -le 0 -or $config.NanoCpus -le 0 -or $config.PidsLimit -le 0 -or $config.LogConfig.Type -ne 'json-file' -or $config.LogConfig.Config.'max-size' -ne '10m' -or $config.LogConfig.Config.'max-file' -ne '3'){throw "Resource/log limits missing for $service"}
    }
    $output=Get-Content -LiteralPath "$PSScriptRoot/load-test.py" -Raw | & docker @composeArgs exec -T api python - --concurrency $Concurrency --iterations $Iterations --max-p95-ms $MaxP95Ms
    $exitCode=$LASTEXITCODE
    $report=($output -join "`n") | ConvertFrom-Json
    $report | Add-Member -NotePropertyName project -NotePropertyValue $project
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$directory/report.json" -Encoding utf8
    Invoke-NotesDocker -Arguments (@('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}') + $runningIds)
    if($exitCode -ne 0 -or -not $report.passed){throw "Load verification failed. See $directory/report.json"}
} catch { $failure=$_ }
finally {
    try {
        if($started){Invoke-NotesDocker -Arguments ($composeArgs + @('down','--volumes','--remove-orphans','--timeout','10'))}
        Remove-Item -LiteralPath $envFile -Force
    } catch { $cleanupFailure=$_ }
    finally {Restore-NotesEnvironment $saved}
}
if($null -ne $failure){if($null -ne $cleanupFailure){Write-Warning "Cleanup also failed for $project; retain $envFile"};throw $failure}
if($null -ne $cleanupFailure){throw $cleanupFailure}
Write-Host "PASS: $($report.requests) requests; p95 $($report.p95_ms) ms; no data or activity-count errors."
Write-Host "Report: $directory/report.json"
$report
