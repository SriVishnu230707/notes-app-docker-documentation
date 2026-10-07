# Shared helpers for packaging and recovery scripts. Never stream binary dumps
# through PowerShell's text pipeline.
function Invoke-NotesDocker {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Capture)
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed: $($Arguments[0])" }
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
