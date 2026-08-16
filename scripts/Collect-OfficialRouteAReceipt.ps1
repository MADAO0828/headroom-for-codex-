[CmdletBinding()]
param(
    [int]$WindowSeconds = 10,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stateRoot = Join-Path $projectRoot 'runtime\state'
$evidenceRoot = Join-Path $projectRoot 'evidence'
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')

function Get-ProcessStartTimeUtc {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    try { return $Process.StartTime.ToUniversalTime().ToString('o') } catch { return '' }
}

function Get-ProcessSnapshot {
    $items = @()
    foreach ($name in @('ChatGPT','Codex','codex')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = ''
            try { $path = $process.MainModule.FileName } catch { }
            $items += [ordered]@{
                pid = [int]$process.Id
                name = $process.ProcessName
                path = $path
                start_time_utc = Get-ProcessStartTimeUtc -Process $process
            }
        }
    }
    return @($items)
}

function Get-SocketSnapshot {
    $rows = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -in @(7897, 18787, 18789, 57321) })
    return @($rows | ForEach-Object {
        [ordered]@{ owning_pid = [int]$_.OwningProcess; remote_port = [int]$_.RemotePort; state = [string]$_.State }
    })
}

function Get-OfficialPidSet {
    param([Parameter(Mandatory)][object[]]$Processes)
    return @($Processes | Where-Object {
        $_.path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(ChatGPT\.exe|resources\\codex\.exe)$'
    } | ForEach-Object { [int]$_.pid } | Select-Object -Unique)
}

function Get-JsonOrNull {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
        return ($response.Content | ConvertFrom-Json)
    }
    catch { return $null }
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$before = [ordered]@{
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    processes = Get-ProcessSnapshot
    sockets = Get-SocketSnapshot
    monitor_status = Get-JsonOrNull -Url 'http://127.0.0.1:18788/status'
}
Start-Sleep -Seconds ([Math]::Max(1, $WindowSeconds))
$after = [ordered]@{
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    processes = Get-ProcessSnapshot
    sockets = Get-SocketSnapshot
    monitor_status = Get-JsonOrNull -Url 'http://127.0.0.1:18788/status'
}

$afterOfficial = $after.monitor_status.official_dataplane
$officialPids = @(Get-OfficialPidSet -Processes $after.processes)
$gatewaySocket = @($after.sockets | Where-Object { $_.remote_port -eq 18787 -and $_.owning_pid -in $officialPids })
$vortexSocket = @($after.sockets | Where-Object { $_.remote_port -eq 7897 -and $_.owning_pid -in $officialPids })
$classification = 'unknown'
$basis = [Collections.Generic.List[string]]::new()
if ($gatewaySocket.Count -gt 0) { [void]$basis.Add('official_pid_tcp_18787') }
if ($vortexSocket.Count -gt 0) { [void]$basis.Add('official_pid_tcp_vortex_7897') }
if ($afterOfficial.classification -in @('confirmed','bypass','unknown')) { $classification = $afterOfficial.classification }
if ($null -eq $afterOfficial -and $vortexSocket.Count -gt 0) { $classification = 'bypass' }

$document = [ordered]@{
    schema = 'official-route-a-receipt/v1'
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    classification = $classification
    basis = @($basis)
    official_pids = @($officialPids)
    official_dataplane = $afterOfficial
    before = $before
    after = $after
    route_a_confirmed = ($classification -eq 'confirmed' -and $gatewaySocket.Count -gt 0 -and $vortexSocket.Count -eq 0)
    secrets_logged = $false
    session_body_logged = $false
}

$finalOutputPath = $OutputPath
if (-not $finalOutputPath) {
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $name = if ($document.route_a_confirmed) { 'route-a-confirmed-' } else { 'route-a-not-proven-' }
    $finalOutputPath = Join-Path $evidenceRoot ($name + $timestamp + '.json')
}
$document.receipt_path = $finalOutputPath
$parent = Split-Path -Parent $finalOutputPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::WriteAllText($finalOutputPath, (($document | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
$document | ConvertTo-Json -Depth 16
