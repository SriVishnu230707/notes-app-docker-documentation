#Requires -Version 7.0
# Stubbed Docker/HTTP tests; no real containers are changed.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/docker-tools.ps1"
$root=Split-Path $PSScriptRoot -Parent
$state=@{Urls=@();StatsFails=$false}
$containers=@('db','redis','api','web') | ForEach-Object {
    [pscustomobject]@{Service=$_;ID="fake-$_";State='running';Health='healthy';Publishers=@([pscustomobject]@{TargetPort=80;PublishedPort=9080;Protocol='tcp';URL='127.0.0.1'})}
}
$containers+= [pscustomobject]@{Service='migrate';ID='fake-migrate';State='exited';ExitCode=0}
function docker {
    $global:LASTEXITCODE=0
    if($args -contains 'json') {return ConvertTo-Json -InputObject $containers -Depth 5 -Compress}
    if($args[0] -eq 'stats' -and $state.StatsFails){$global:LASTEXITCODE=23}
}
function Invoke-RestMethod { $state.Urls+= $args[0]; return @{status='ok';postgres='ok';redis='ok'} }
try {
    $failure=$null
    try { & "$PSScriptRoot/status.ps1" -EnvFile "$root/.env.example" -WebPort 8080 | Out-Null } catch {$failure=$_}
    if($null -eq $failure -or $state.Urls.Count -ne 0){throw 'Status checked a web port belonging to another project.'}
    Write-Host 'PASS: mismatched explicit web port rejected before HTTP.'
    & "$PSScriptRoot/status.ps1" -EnvFile "$root/.env.example" | Out-Null
    if($state.Urls[-1] -ne 'http://127.0.0.1:9080/api/health'){throw 'Status did not derive the actual published port.'}
    Write-Host 'PASS: custom published web port detected automatically.'
    ($containers | Where-Object Service -eq 'web').Publishers[0].TargetPort=5173
    & "$PSScriptRoot/status.ps1" -EnvFile "$root/.env.example" | Out-Null
    Write-Host 'PASS: Vite development port detected automatically.'
    $state.StatsFails=$true
    & "$PSScriptRoot/status.ps1" -EnvFile "$root/.env.example" | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Optional stats failure poisoned successful status exit code.'}
    Write-Host 'PASS: optional stats failure does not mask dependency health.'
    $valid=@{passed=$true;requests=12;concurrency=1;iterations_per_worker=1;p95_ms=50;max_p95_ms=2000;failures=@()}
    Read-NotesLoadReport ($valid | ConvertTo-Json -Depth 4) 1 1 2000 | Out-Null
    foreach($change in @(@{passed='false'},@{requests=0},@{p95_ms='NaN'},@{p95_ms=2500},@{failures=@('unexpected failure')},@{concurrency=2})){
        $fixture=$valid.Clone();foreach($key in $change.Keys){$fixture[$key]=$change[$key]}
        $failure=$null
        try{Read-NotesLoadReport ($fixture | ConvertTo-Json -Depth 4) 1 1 2000 | Out-Null}catch{$failure=$_}
        if($null -eq $failure){throw 'Invalid load report was accepted.'}
    }
    Write-Host 'PASS: malformed, inconsistent and over-threshold load reports refused.'
    $partial=$valid.Clone();$partial.passed=$false;$partial.requests=1;$partial.failures=@('Generator stopped')
    Read-NotesLoadReport ($partial | ConvertTo-Json -Depth 4) 1 1 2000 | Out-Null
    Write-Host 'PASS: partial failed report retained for diagnosis.'
} finally {$global:LASTEXITCODE=0}
