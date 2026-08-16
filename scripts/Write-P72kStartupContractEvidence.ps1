[CmdletBinding()]
param(
    [string]$OutputPath = 'evidence/p72k-startup-contract-recon-20260816.json'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Get-JsonBody([string]$Url) {
    (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri $Url).Content | ConvertFrom-Json
}

$status = Get-JsonBody 'http://127.0.0.1:18788/status'
$broker = Get-JsonBody 'http://127.0.0.1:18790/health'
$headroomState = Get-Content -LiteralPath (Join-Path $root 'runtime/state/headroom-state-18789.json') -Raw | ConvertFrom-Json
$gatewayState = Get-Content -LiteralPath (Join-Path $root 'runtime/state/gateway-process-state.json') -Raw | ConvertFrom-Json
$startResult = Get-Content -LiteralPath (Join-Path $root 'runtime/state/headroom-start-result.json') -Raw | ConvertFrom-Json
$core = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -in @(16720, 29724, 15440) } | ForEach-Object {
    [ordered]@{ pid = [int]$_.ProcessId; name = [string]$_.Name; created = [string]$_.CreationDate; path = [string]$_.ExecutablePath }
})
$hashes = @(
    'scripts/Start-HeadroomForCodexPP.ps1',
    'src/headroom/codexpp-headroom/start-headroom.ps1',
    'src/headroom/codexpp-headroom/ensure-headroom.ps1',
    'src/headroom/codexpp-headroom/headroom-launcher.py',
    'src/codexpp/Codex++/startup-root.tests.ps1'
) | ForEach-Object {
    [ordered]@{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $_)).Hash }
}
$items = @($status.items | ForEach-Object {
    [ordered]@{ key = [string]$_.key; state = [string]$_.state; issue_code = [string]$_.issue_code }
})
$evidence = [ordered]@{
    schema_version = 1
    package_id = 'P72k-managed-service-contract-recon-20260816/v1'
    author = 'Codex'
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    production_touched = $false
    production_restart_performed = $false
    current_runtime = [ordered]@{
        monitor_pid = $status.monitor.pid
        monitor_source_sha256 = $status.monitor.source_sha256
        overall = $status.overall
        official_dataplane = $status.official_dataplane.classification
        items = $items
        queue_full_total = $status.metrics.kompress_broker.queue_full_total
        queue_full_delta = $status.metrics.kompress_broker.queue_full_delta
        timeout_total = $status.metrics.kompress_broker.timeout_total
        worker_restart_total = $status.metrics.kompress_broker.worker_restart_total
        device_removal_total = $status.metrics.kompress_broker.device_removal_total
        broker_ready = $broker.ready
    }
    reused_core_processes = $core
    prior_state = [ordered]@{
        headroom_pid = $headroomState.Pid
        headroom_started_at = $headroomState.StartedAt
        headroom_has_runtime_contract = ($null -ne $headroomState.PSObject.Properties['runtime_contract_sha256'])
        gateway_pid = $gatewayState.Pid
        gateway_started_at = $gatewayState.StartedAt
        broker_pid = ($core | Where-Object { $_.pid -eq 15440 }).pid
        start_result_status = $startResult.status
        start_result_config_changed = $startResult.config_changed_after_manager
    }
    root_cause = 'port-only fast path and full ensure identity/health reuse lacked runtime source/environment contract comparison'
    correction = [ordered]@{
        root_fast_path = 'disabled; service validators always run'
        headroom_state = 'runtime_contract_version/hash, launcher/start hashes, ports, workers, target, Kompress endpoint, unit parallelism and max concurrency'
        stale_state = 'missing or mismatched contract prevents reuse; only verified managed PID may be stopped'
        direct_start = 'old listener cannot be upgraded by writing current hash; start refuses stale state'
    }
    verification = @('activation_fixture_tests_ok','startup-root fixture tests PASS','PowerShell parser errors=0','ensure parser errors=0','git diff --check PASS')
    source_hashes = $hashes
    next = @('user/Reasonix manually start again so service validators apply the new contract','verify Headroom PID creation time and runtime_contract_sha256','run minimal real main+spawned SSE and inspect queue_full_delta/terminal events')
}
$absolute = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }
[IO.Directory]::CreateDirectory((Split-Path -Parent $absolute)) | Out-Null
$json = ($evidence | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
[IO.File]::WriteAllText($absolute, ($json + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output $absolute
