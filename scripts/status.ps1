#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')][string]$ProjectName='notes-app',
    [string]$EnvFile,
    [ValidateRange(1024,65535)][int]$WebPort=8080
)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/docker-tools.ps1"
$root=Split-Path $PSScriptRoot -Parent
if(-not $EnvFile){$EnvFile="$root/.env"}
$EnvFile=(Resolve-Path -LiteralPath $EnvFile).Path
$composeArgs=Get-NotesComposeArguments $root $ProjectName $EnvFile
Invoke-NotesDocker -Arguments ($composeArgs + @('ps','-a'))
$rows=@(Invoke-NotesDocker -Capture -Arguments ($composeArgs + @('ps','-a','--format','json')))
$containers=@($rows | ForEach-Object {$_ | ConvertFrom-Json} | ForEach-Object {$_})
$issues=@()
foreach($service in @('db','redis','api','web')) {
    $container=@($containers | Where-Object Service -eq $service)
    if($container.Count -ne 1 -or $container[0].State -ne 'running' -or $container[0].Health -ne 'healthy'){$issues+="$service is missing, stopped or unhealthy"}
}
$migration=@($containers | Where-Object Service -eq 'migrate')
if($migration.Count -ne 1 -or $migration[0].State -ne 'exited' -or $migration[0].ExitCode -ne 0){$issues+='Migration did not complete successfully'}
$running=@($containers | Where-Object State -eq 'running' | ForEach-Object ID)
if($running.Count){Invoke-NotesDocker -Arguments (@('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}')+$running)}
try {
    $health=Invoke-RestMethod "http://127.0.0.1:$WebPort/api/health" -TimeoutSec 10
    if($health.status -ne 'ok' -or $health.postgres -ne 'ok' -or $health.redis -ne 'ok'){$issues+='Web-to-API dependency health failed'}
} catch {$issues+='Cannot reach healthy API through the web port'}
if($issues.Count){throw ($issues -join '; ')}
Write-Host 'PASS: four services healthy, migrations complete, web-to-API-to-database/Redis reachable.'
