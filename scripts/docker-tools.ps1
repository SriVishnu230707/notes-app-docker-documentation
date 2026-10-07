# Shared helpers for packaging and recovery scripts. Never stream binary dumps
# through PowerShell's text pipeline.
function Invoke-NotesDocker {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Capture)
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed: $($Arguments[0]) (exit code $LASTEXITCODE)" }
    if ($Capture) { return $output }
    $output | ForEach-Object { Write-Host $_ }
}

function Get-NotesComposeArguments {
    param([string]$Root, [string]$Project, [string]$EnvFile)
    return @('compose', '--project-directory', $Root, '--env-file', $EnvFile, '-p', $Project, '-f', "$Root/compose.yaml")
}

function Assert-NotesPorts {
    param([int]$WebPort, [int]$ApiPort)
    if ($WebPort -eq $ApiPort) { throw 'Web and API ports must differ.' }
    foreach ($port in @($WebPort, $ApiPort)) {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        try { $listener.Start() }
        catch { throw "Port $port is occupied. Choose different WebPort/ApiPort values." }
        finally { $listener.Stop() }
    }
}

function Get-NotesFingerprint {
    param([string]$WebUrl)
    # Canonical ordering is independent of database query plans after restore.
    $notes = @((Invoke-RestMethod "$WebUrl/api/notes" -TimeoutSec 20) | Sort-Object id)
    $json = ConvertTo-Json -InputObject $notes -Depth 8 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    return [pscustomobject]@{ Count = $notes.Count; Sha256 = $hash }
}

function Write-NotesEnvironment {
    param([string]$Path, [hashtable]$Settings)
    # Callers provide generated alphanumeric credentials and validated numeric ports.
    $lines = $Settings.Keys | Sort-Object | ForEach-Object { "$_=$($Settings[$_])" }
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function Restore-NotesEnvironment {
    param([hashtable]$Saved)
    foreach ($name in $Saved.Keys) {
        # On current Windows .NET, setting null creates an empty variable.
        # Remove previously absent entries so they cannot override Compose .env.
        if ($null -eq $Saved[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $Saved[$name], 'Process')
        }
    }
}

function Read-NotesReleaseDefinition {
    param([string]$Bundle)
    $manifest = Get-Content -LiteralPath "$Bundle/release.json" -Raw | ConvertFrom-Json
    if ($manifest.revision -notmatch '^[a-f0-9]{40}$' -or $manifest.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid release revision or checksum.' }
    $expected = @{
        NOTES_API_IMAGE="notes-app-api:sha-$($manifest.revision)"
        NOTES_WEB_IMAGE="notes-app-web:sha-$($manifest.revision)"
        NOTES_DB_IMAGE='notes-app-postgres:17.11'
        NOTES_REDIS_IMAGE='notes-app-redis:7.4.11'
    }
    $properties = @($manifest.images.PSObject.Properties | Where-Object MemberType -eq NoteProperty)
    if ($properties.Count -ne 4) { throw 'Release manifest must contain exactly four image IDs.' }
    foreach ($tag in $expected.Values) {
        $property = $properties | Where-Object Name -CEQ $tag
        if ($null -eq $property -or $property.Value -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid release image ID or service tag.' }
    }
    $environment = @{}
    foreach ($line in (Get-Content -LiteralPath "$Bundle/.env.images")) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -cnotmatch '^(NOTES_(API|WEB|DB|REDIS)_IMAGE)=(.+)$') { throw 'Invalid release image environment.' }
        $name=$Matches[1]; $value=$Matches[3]
        if ($environment.ContainsKey($name)) { throw "Duplicate release image variable: $name" }
        if ($value -cne $expected[$name]) { throw "Release image assigned to wrong service: $name" }
        $environment[$name]=$value
    }
    if ($environment.Count -ne 4) { throw 'Release environment must define all four service images.' }
    foreach ($file in @('compose.yaml','compose.release.yaml','notes-images.tar.gz')) {
        if (-not (Test-Path -LiteralPath "$Bundle/$file" -PathType Leaf)) { throw "Release file is missing: $file" }
    }
    if ((Get-FileHash -LiteralPath "$Bundle/notes-images.tar.gz" -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.sha256) { throw 'Release archive checksum mismatch.' }
    return [pscustomobject]@{ Manifest=$manifest; Environment=$environment }
}
