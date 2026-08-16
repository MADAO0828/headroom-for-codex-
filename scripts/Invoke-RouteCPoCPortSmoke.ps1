[CmdletBinding()]
param(
    [int]$Port = 58322
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$python = Join-Path $root 'runtime\python\Scripts\python.exe'
$evidencePath = Join-Path $root 'evidence\p48-route-c-isolated-poc-20260802.json'
$stdoutPath = Join-Path $root "runtime\logs\route-c-poc-$Port.stdout.log"
$stderrPath = Join-Path $root "runtime\logs\route-c-poc-$Port.stderr.log"

if (-not (Test-Path -LiteralPath $python)) {
    throw "isolated python not found: $python"
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    throw "isolated port already occupied: $Port"
}

$process = Start-Process -FilePath $python -WorkingDirectory $root -PassThru `
    -ArgumentList @('-m', 'uvicorn', 'src.route_c_poc.server:app', '--host', '127.0.0.1', '--port', "$Port") `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$ready = $false
try {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        try {
            $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
            if ($response.ready -eq $true -and $response.native -eq $false -and $response.production -eq $false) {
                $ready = $true
                break
            }
        } catch {
            if (-not $process.HasExited) { continue }
            throw "isolated PoC exited before readiness (pid=$($process.Id))"
        }
    }
    if (-not $ready) {
        throw "isolated PoC readiness timeout (pid=$($process.Id), port=$Port)"
    }
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    $process.WaitForExit(5000)
}

$released = $false
$releaseDeadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $releaseDeadline) {
    if ($null -eq (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        $released = $true
        break
    }
    Start-Sleep -Milliseconds 200
}

$receipt = [ordered]@{
    package = 'P48-route-c-isolated-contract-poc/v1'
    status = if ($ready -and $released) { 'passed' } else { 'failed' }
    native = $false
    production = $false
    port = $Port
    bind = '127.0.0.1'
    pid = $process.Id
    health_ready = $ready
    port_released = $released
    upstream = 'example.invalid'
    logs = @($stdoutPath, $stderrPath)
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidencePath -Encoding utf8NoBOM
if (-not ($ready -and $released)) { throw "isolated PoC smoke failed; see $evidencePath" }
$receipt | ConvertTo-Json -Depth 5
