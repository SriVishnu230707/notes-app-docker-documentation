#Requires -Version 7.0
# Failure-path tests use a Docker stub; they never contact the engine.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/docker-tools.ps1"
$directory = Join-Path $root ('test-results/script-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
# Use OS-assigned ports so these stub checks can run beside real-stack tests.
$listeners=@()
try {
    1..4 | ForEach-Object { $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start(); $listeners+=$listener }
    $testPorts=@($listeners | ForEach-Object {$_.LocalEndpoint.Port})
} finally { foreach($listener in $listeners){$listener.Stop()} }
$revision = 'a' * 40
$imageId = 'sha256:' + ('b' * 64)
$expected = @{ NOTES_API_IMAGE="notes-app-api:sha-$revision"; NOTES_WEB_IMAGE="notes-app-web:sha-$revision"; NOTES_DB_IMAGE='notes-app-postgres:17.11'; NOTES_REDIS_IMAGE='notes-app-redis:7.4.11' }
$images = @{}
foreach ($value in $expected.Values) { $images[$value]=$imageId }
[IO.File]::WriteAllText("$directory/notes-images.tar.gz", 'test fixture, not a Docker archive')
$manifest = @{revision=$revision; sha256=(Get-FileHash "$directory/notes-images.tar.gz").Hash.ToLowerInvariant(); images=$images}
foreach ($file in @('compose.yaml','compose.release.yaml')) { Copy-Item "$root/$file" $directory }
$dockerState = @{Calls=0; Down=0; Config=0; FailConfig=$true; EnvFile=$null}
function docker {
    $dockerState.Calls++
    $global:LASTEXITCODE = 0
    if ($args -contains '--env-file') { $dockerState.EnvFile=$args[[array]::IndexOf($args,'--env-file')+1] }
    if ($args[0] -eq 'image') { return $imageId }
    if ($args -contains 'config') { $dockerState.Config++; if ($dockerState.FailConfig) { $global:LASTEXITCODE=17 } }
    if ($args -contains 'up') { $global:LASTEXITCODE=19 }
    if ($args -contains 'down') { $dockerState.Down++; $global:LASTEXITCODE=23 }
}
function Write-Fixture {
    $manifest | ConvertTo-Json -Depth 5 | Set-Content "$directory/release.json" -Encoding utf8
    Write-NotesEnvironment "$directory/.env.images" $expected
    $dockerState.Calls=0; $dockerState.Down=0; $dockerState.Config=0
}
function Assert-RejectedBeforeDocker {
    param([string]$Name)
    $failure = $null
    try { & "$PSScriptRoot/verify-release.ps1" -BundlePath $directory -WebPort $testPorts[0] -ApiPort $testPorts[1] | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $dockerState.Calls -ne 0) { throw "$Name was not rejected before Docker ($($dockerState.Calls) calls)." }
    Write-Host "PASS: $Name refused before Docker."
}
$saved = @{}
foreach ($name in @($expected.Keys) + @('WEB_PORT','API_PORT','POSTGRES_DB','POSTGRES_USER','POSTGRES_PASSWORD')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $dockerState.Calls=0
    $failure=$null
    try { & "$PSScriptRoot/export-release.ps1" -Revision ('0' * 40) -OutputDirectory "$directory/wrong-revision" | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch 'must match' -or $dockerState.Calls -ne 0 -or (Test-Path "$directory/wrong-revision")) { throw 'Wrong release revision was not rejected before side effects.' }
    Write-Host 'PASS: mislabeled Git revision refused before creating release files or images.'
    Write-Fixture
    $manifest.images = @{}
    $manifest | ConvertTo-Json -Depth 5 | Set-Content "$directory/release.json" -Encoding utf8
    Assert-RejectedBeforeDocker 'Empty image manifest'
    $manifest.images = $images
    Write-Fixture
    Add-Content "$directory/.env.images" "NOTES_API_IMAGE=$($expected.NOTES_API_IMAGE)"
    Assert-RejectedBeforeDocker 'Duplicate image variable'
    Write-Fixture
    $swapped = $expected.Clone(); $swapped.NOTES_API_IMAGE=$expected.NOTES_WEB_IMAGE
    Write-NotesEnvironment "$directory/.env.images" $swapped
    Assert-RejectedBeforeDocker 'Image assigned to wrong service'
    Write-Fixture
    Get-Content "$directory/.env.images" | Where-Object {$_ -notmatch '^NOTES_DB_IMAGE='} | Set-Content "$directory/missing.images"
    Move-Item "$directory/missing.images" "$directory/.env.images" -Force
    Assert-RejectedBeforeDocker 'Missing image variable'
    Write-Fixture
    [IO.File]::AppendAllText("$directory/notes-images.tar.gz", 'corrupt')
    Assert-RejectedBeforeDocker 'Corrupt image archive'
    $manifest.sha256=(Get-FileHash "$directory/notes-images.tar.gz").Hash.ToLowerInvariant()
    Write-Fixture
    $env:NOTES_API_IMAGE = 'original-shell-value'
    $failure=$null
    try { & "$PSScriptRoot/verify-release.ps1" -BundlePath $directory -WebPort $testPorts[0] -ApiPort $testPorts[1] | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch 'exit code 17' -or $dockerState.Down -ne 0) { throw 'Configuration failure was masked or triggered unnecessary cleanup.' }
    if ($env:NOTES_API_IMAGE -ne 'original-shell-value' -or (Test-Path "$directory/.env.verify")) { throw 'Failed verification did not restore its shell/files.' }
    Write-Host 'PASS: configuration failure preserved; no teardown before startup; shell and file cleaned.'
    Write-Fixture
    $dockerState.FailConfig=$false
    $failure=$null
    try { & "$PSScriptRoot/verify-release.ps1" -BundlePath $directory -WebPort $testPorts[0] -ApiPort $testPorts[1] | Out-Null } catch { $failure=$_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch 'exit code 19' -or $dockerState.Down -ne 1 -or -not(Test-Path "$directory/.env.verify")) { throw 'Release startup failure was masked or recovery credentials were lost.' }
    Remove-Item -LiteralPath "$directory/.env.verify" -Force
    Write-Host 'PASS: startup error preserved when teardown also fails; cleanup credentials retained.'
    # Restore and drill must report the startup failure rather than teardown failure.
    $backupManifest=@{format_version=1;component='postgresql';postgres_major=17;sha256=$manifest.sha256;bytes=(Get-Item "$directory/notes-images.tar.gz").Length}
    $backupManifest | ConvertTo-Json | Set-Content "$directory/notes-images.tar.gz.json" -Encoding utf8
    foreach ($scriptName in @('restore.ps1','verify-recovery.ps1')) {
        $dockerState.Down=0; $dockerState.EnvFile=$null
        $failure=$null
        try {
            if ($scriptName -eq 'restore.ps1') { & "$PSScriptRoot/$scriptName" -BackupPath "$directory/notes-images.tar.gz" -VerifyOnly -WebPort $testPorts[0] -ApiPort $testPorts[1] | Out-Null }
            else { & "$PSScriptRoot/$scriptName" -WebPort $testPorts[0] -ApiPort $testPorts[1] -RestoreWebPort $testPorts[2] -RestoreApiPort $testPorts[3] | Out-Null }
        } catch { $failure=$_ }
        if ($null -eq $failure -or $failure.Exception.Message -notmatch 'exit code 19' -or $dockerState.Down -ne 1 -or -not(Test-Path -LiteralPath $dockerState.EnvFile)) { throw "$scriptName masked startup failure or lost cleanup credentials." }
        Remove-Item -LiteralPath $dockerState.EnvFile -Force
        Write-Host "PASS: $scriptName preserves startup failure and cleanup credentials."
    }
    # Missing/empty/normal values must be restored distinctly on Windows and Linux.
    $probe = 'NOTES_SCRIPT_TEST_PROBE'
    $probeSaved=@{NOTES_SCRIPT_TEST_PROBE=[Environment]::GetEnvironmentVariable($probe,'Process')}
    try {
        foreach ($value in @($null,'','original')) {
            [Environment]::SetEnvironmentVariable($probe,'changed','Process')
            Restore-NotesEnvironment @{NOTES_SCRIPT_TEST_PROBE=$value}
            if ($null -eq $value) { if (Test-Path "Env:$probe") { throw 'Absent variable was not removed.' } }
            elseif ([Environment]::GetEnvironmentVariable($probe,'Process') -cne $value) { throw 'Shell value was not restored.' }
        }
    } finally { Restore-NotesEnvironment $probeSaved }
    Write-Host 'PASS: absent, empty and normal shell values restored.'
} finally {
    Restore-NotesEnvironment $saved
    # GitHub's pwsh wrapper exits with LASTEXITCODE; stub failures are expected.
    $global:LASTEXITCODE = 0
}
