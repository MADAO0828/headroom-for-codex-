[CmdletBinding()]
param(
    [string]$NativeLauncherPath = '',
    [switch]$DryRun,
    [switch]$KeepRunning,
    [ValidateRange(1024, 65535)][int]$IngressPort = 58321,
    [ValidateRange(1024, 65535)][int]$EgressPort = 58322,
    [ValidateRange(1024, 65535)][int]$GatewayPort = 18887,
    [ValidateRange(1024, 65535)][int]$MonitorPort = 18888,
    [ValidateRange(1024, 65535)][int]$HeadroomPort = 18889,
    [ValidateRange(1024, 65535)][int]$BrokerPort = 18890,
    [ValidateRange(1024, 65535)][int]$UpstreamPort = 18891
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$python = Join-Path $projectRoot 'runtime\python\Scripts\python.exe'
$moduleRoot = Join-Path $projectRoot 'src'
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
$canaryRoot = Join-Path $projectRoot ("runtime\canary\route-c\$timestamp")
$stateRoot = Join-Path $canaryRoot 'state'
$logRoot = Join-Path $canaryRoot 'logs'
$evidencePath = Join-Path $canaryRoot 'route-c-startup.json'
$startHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom\ensure-headroom.ps1'
$stopHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom\stop-headroom.ps1'
$monitorModule = 'route_c_poc.monitor:app'
$upstreamModule = 'route_c_poc.upstream:app'
$brokerUrl = "http://127.0.0.1:$BrokerPort"
$upstreamUrl = "http://127.0.0.1:$UpstreamPort"
$gatewayUrl = "http://127.0.0.1:$GatewayPort"
$headroomUrl = "http://127.0.0.1:$HeadroomPort"
$nativeProcess = $null
$brokerProcess = $null
$monitorProcess = $null
$upstreamProcess = $null
$gatewayProcessId = $null
$runFailure = $null
$brokerAlreadyReady = $false
$brokerReused = $false
$brokerPid = $null
$brokerIdentity = $null
$brokerCountersBefore = $null
$brokerCountersAfter = $null
$brokerCountersDelta = $null

foreach ($directory in @($stateRoot, $logRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
if ([string]::IsNullOrWhiteSpace($NativeLauncherPath)) {
    $current = Join-Path $projectRoot 'runtime\canary\route-c\current\app\codex-plus-launcher.exe'
    if (Test-Path -LiteralPath $current -PathType Leaf) {
        $NativeLauncherPath = $current
    } else {
        $latest = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'runtime\canary\route-c') -Directory -ErrorAction SilentlyContinue |
            Where-Object Name -match '^\d{8}-\d{9}$' |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'app\codex-plus-launcher.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($latest) { $NativeLauncherPath = $latest }
    }
}
$NativeLauncherPath = [IO.Path]::GetFullPath($NativeLauncherPath)

function Get-ListenerPid {
    param([int]$Port)
    $line = @(netstat -ano | Select-String -Pattern ("^\s*TCP\s+127\.0\.0\.1:{0}\s+.*LISTENING\s+(\d+)\s*$" -f $Port))
    if ($line.Count -gt 1) { throw "canary_multiple_listeners:$Port" }
    if ($line.Count -eq 0) { return $null }
    return [int]$line[0].Matches[0].Groups[1].Value
}

function Wait-HttpReady {
    param([string]$Url, [int]$TimeoutSeconds = 90)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
            if ([int]$response.StatusCode -eq 200) { return ($response.Content | ConvertFrom-Json) }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "canary_readiness_timeout:$Url"
}

function Stop-CanaryListener {
    param([int]$Port, [string]$CommandPattern)
    $pidValue = Get-ListenerPid -Port $Port
    if ($null -eq $pidValue) { return }
    $snapshot = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $pidValue) -ErrorAction SilentlyContinue
    $command = if ($snapshot) { [string]$snapshot.CommandLine } else { '' }
    if ($command -match $CommandPattern) {
        Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
    }
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [ordered]@{
            pid = $ProcessId
            status = 'unavailable'
            name = $null
            executable_path = $null
            started_at = $null
            commandline_sha256 = $null
        }
    }
    $commandLine = [string]$process.CommandLine
    $commandHash = if ([string]::IsNullOrEmpty($commandLine)) {
        $null
    } else {
        $bytes = [Text.Encoding]::UTF8.GetBytes($commandLine)
        ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object ToString x2) -join ''
    }
    return [ordered]@{
        pid = $ProcessId
        status = 'observed'
        name = [string]$process.Name
        executable_path = [string]$process.ExecutablePath
        started_at = [string]$process.CreationDate
        commandline_sha256 = $commandHash
    }
}

function Get-CounterValue {
    param($Counters, [string]$Name)
    if ($null -eq $Counters -or -not ($Counters.PSObject.Properties.Name -contains $Name)) { return 0 }
    try { return [int]$Counters.$Name } catch { return 0 }
}

function Get-BrokerSnapshot {
    $response = Invoke-WebRequest -Uri ($brokerUrl + '/readyz') -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
    if ([int]$response.StatusCode -ne 200) { throw "canary_broker_not_ready:$([int]$response.StatusCode)" }
    $body = $response.Content | ConvertFrom-Json
    if ($body.ready -ne $true -or [string]$body.service -ne 'kompress-broker') { throw 'canary_broker_contract_invalid' }
    $listenerPid = Get-ListenerPid -Port $BrokerPort
    if ($null -eq $listenerPid) { throw 'canary_broker_listener_missing' }
    $counters = if ($body.PSObject.Properties.Name -contains 'counters') { $body.counters } else { $null }
    return [pscustomobject]@{
        ready = [bool]$body.ready
        provider = [string]$body.provider
        backend = [string]$body.backend
        pid = [int]$listenerPid
        identity = Get-ProcessIdentity -ProcessId ([int]$listenerPid)
        counters = $counters
    }
}

function Write-Receipt {
    param([string]$Status, [string]$ErrorCode = '')
    $document = [ordered]@{
        schema_version = 1
        status = $Status
        error_code = if ($ErrorCode) { $ErrorCode } else { $null }
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        production_ports_touched = $false
        native_launcher = $NativeLauncherPath
        ports = [ordered]@{
            ingress = $IngressPort; egress = $EgressPort; gateway = $GatewayPort
            monitor = $MonitorPort; headroom = $HeadroomPort; broker = $BrokerPort; upstream = $UpstreamPort
        }
        chain = "official -> $IngressPort -> $GatewayPort -> $HeadroomPort -> $EgressPort -> fake_upstream:$UpstreamPort"
        native_pid = if ($nativeProcess) { [int]$nativeProcess.Id } else { $null }
        gateway_pid = $gatewayProcessId
        broker_pid = $brokerPid
        broker_reused = [bool]$brokerReused
        broker_identity = $brokerIdentity
        broker_counters_before = $brokerCountersBefore
        broker_counters_after = $brokerCountersAfter
        broker_counters_delta = $brokerCountersDelta
        monitor_pid = if ($monitorProcess) { [int]$monitorProcess.Id } else { $null }
        upstream_pid = if ($upstreamProcess) { [int]$upstreamProcess.Id } else { $null }
        keep_running = [bool]$KeepRunning
    }
    $temporary = "$evidencePath.$([IO.Path]::GetRandomFileName())"
    [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $evidencePath, $true)
}

if ($DryRun) {
    Write-Receipt -Status 'dry_run'
    Get-Content -LiteralPath $evidencePath -Raw
    exit 0
}

try {
    foreach ($port in @($IngressPort, $EgressPort, $GatewayPort, $MonitorPort, $HeadroomPort, $UpstreamPort)) {
        if ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
            throw "canary_port_in_use:$port"
        }
    }
    # Broker port is special: an already-ready broker is reused (the ONNX
    # worker cold-load takes minutes), so only reject a NON-ready listener.
    $brokerListener = Get-NetTCPConnection -State Listen -LocalPort $BrokerPort -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $brokerListener) {
        $brokerProbeReady = $false
        try {
            $bp = Invoke-WebRequest -Uri ($brokerUrl + '/readyz') -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
            $brokerProbeReady = (($bp.Content | ConvertFrom-Json).ready -eq $true)
        } catch { }
        if (-not $brokerProbeReady) {
            throw "canary_port_in_use:$BrokerPort (broker present but not ready; stop it or wait for readiness)"
        }
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "canary_python_missing:$python" }
    if (-not (Test-Path -LiteralPath $startHeadroom -PathType Leaf)) { throw "canary_headroom_script_missing:$startHeadroom" }
    if (-not (Test-Path -LiteralPath $NativeLauncherPath -PathType Leaf)) { throw "canary_native_launcher_missing:$NativeLauncherPath" }

    $canaryHome = Join-Path $canaryRoot 'home'
    $settingsDirectory = Join-Path $canaryHome '.codex-session-delete'
    [IO.Directory]::CreateDirectory($settingsDirectory) | Out-Null
    $settings = [ordered]@{
        relayProfilesEnabled = $true
        relayProfiles = @([ordered]@{
                id = 'route-c-canary'
                name = 'Route C Canary Fake Upstream'
                baseUrl = "$upstreamUrl/v1"
                upstreamBaseUrl = "$upstreamUrl/v1"
                apiKey = 'canary-placeholder-key'
                protocol = 'responses'
                relayMode = 'pureApi'
                officialMixApiKey = $false
            })
        activeRelayId = 'route-c-canary'
    }
    [IO.File]::WriteAllText((Join-Path $settingsDirectory 'settings.json'), (($settings | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

    $quotedModuleRoot = '"' + $moduleRoot + '"'
    $upstreamEnvironment = @{
        PYTHONPATH = $moduleRoot
        ROUTE_C_CANARY_UPSTREAM_STATE = (Join-Path $stateRoot 'fake-upstream.json')
    }
    $upstreamProcess = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn',$upstreamModule,'--app-dir',$quotedModuleRoot,'--host','127.0.0.1','--port',$UpstreamPort.ToString(),'--no-access-log') -Environment $upstreamEnvironment -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logRoot 'upstream.stdout.log') -RedirectStandardError (Join-Path $logRoot 'upstream.stderr.log') -PassThru
    $null = Wait-HttpReady -Url ($upstreamUrl + '/health') -TimeoutSeconds 30

    # Broker reuse: the ONNX worker takes ~5-8 minutes to cold-load on this
    # host, which is too slow for every canary run.  If a broker is already
    # listening on the canary BrokerPort and reports ready, reuse it instead
    # of spawning another cold worker.  Its state file still lands in the
    # canary run's state dir so the compression gate reads fresh counters.
    try {
        $probe = Invoke-WebRequest -Uri ($brokerUrl + '/readyz') -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        $probeBody = $probe.Content | ConvertFrom-Json
        $brokerAlreadyReady = ($probeBody.ready -eq $true)
    } catch { }
    if ($brokerAlreadyReady) {
        Write-Output 'canary: reusing already-ready broker on the canary BrokerPort'
        $brokerReused = $true
        $brokerSnapshot = Get-BrokerSnapshot
        $brokerPid = $brokerSnapshot.pid
        $brokerIdentity = $brokerSnapshot.identity
        $brokerCountersBefore = $brokerSnapshot.counters
    } else {

    $brokerEnvironment = @{
        PYTHONPATH = $moduleRoot
        KOMPRESS_BROKER_STATE_PATH = (Join-Path $stateRoot 'broker.json')
        KOMPRESS_PROVIDER_BACKEND = 'cpu'
        KOMPRESS_WORKER_PYTHON = $python
        KOMPRESS_WORKER_STDERR_PATH = (Join-Path $logRoot 'worker.stderr.log')
        KOMPRESS_REQUEST_TIMEOUT_SECONDS = '60'
        KOMPRESS_STARTUP_TIMEOUT_SECONDS = '180'
        HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
        HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = '12'
        HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
        HEADROOM_ONNX_CPU_ARENA = '1'
        HF_HOME = (Join-Path $projectRoot 'runtime\cache\huggingface')
        HF_HUB_CACHE = (Join-Path $projectRoot 'runtime\cache\huggingface\hub')
        TRANSFORMERS_CACHE = (Join-Path $projectRoot 'runtime\cache\huggingface\transformers')
        TRANSFORMERS_OFFLINE = '1'
        HF_HUB_OFFLINE = '1'
    }
    $brokerProcess = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','kompress_broker.app:app','--app-dir',$quotedModuleRoot,'--host','127.0.0.1','--port',$BrokerPort.ToString(),'--no-access-log') -Environment $brokerEnvironment -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logRoot 'broker.stdout.log') -RedirectStandardError (Join-Path $logRoot 'broker.stderr.log') -PassThru
    # The broker spawns its ONNX worker lazily on the first compress request.
    # Send a warm-up request so the worker process and model load before the
    # readiness wait, otherwise /readyz stays false and the wait times out.
    $brokerWarmDeadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $brokerWarmDeadline) {
        try {
            # The broker's /compress contract requires {"content": "..."}; an
            # empty body returns 400 without spawning the ONNX worker, which
            # would leave /readyz false forever.  Send a small valid payload
            # so the worker process and model load before the readiness wait.
            $null = Invoke-WebRequest -Uri ($brokerUrl + '/compress') -Method Post -Body (@{ content = 'warmup' } | ConvertTo-Json) -ContentType 'application/json' -NoProxy -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        } catch { }
        $readyCheck = Wait-HttpReady -Url ($brokerUrl + '/readyz') -TimeoutSeconds 5
        if ($null -ne $readyCheck -and $readyCheck.PSObject.Properties['ready'] -and $readyCheck.ready -eq $true) { break }
    }
    $null = Wait-HttpReady -Url ($brokerUrl + '/readyz') -TimeoutSeconds 240
    $brokerSnapshot = Get-BrokerSnapshot
    $brokerPid = $brokerSnapshot.pid
    $brokerIdentity = $brokerSnapshot.identity
    $brokerCountersBefore = $brokerSnapshot.counters
    } # end else (broker cold start)

    $nativeEnvironment = @{
        CODEX_PLUS_ROUTE_C_STATE_PATH = (Join-Path $stateRoot 'route-c-supervisor.json')
        HEADROOM_SETTINGS_PATH = (Join-Path $settingsDirectory 'settings.json')
        HEADROOM_ROUTE_C_ALLOW_LOOPBACK_UPSTREAM = '1'
        USERPROFILE = $canaryHome
        HOME = $canaryHome
        CODEX_HOME = (Join-Path $canaryHome '.codex')
    }
    $nativeArgs = @('--helper-only','--helper-port',$IngressPort.ToString(),'--route-c-mode','isolated','--route-c-ingress-port',$IngressPort.ToString(),'--route-c-egress-port',$EgressPort.ToString(),'--route-c-gateway-port',$GatewayPort.ToString(),'--route-c-monitor-port',$MonitorPort.ToString(),'--route-c-headroom-port',$HeadroomPort.ToString(),'--route-c-broker-port',$BrokerPort.ToString())
    # The canary launcher copy uses an asInvoker manifest (see
    # Start-RouteCCanary.ps1 deployment notes), so no elevation is needed and
    # -Environment variables are preserved.  -Verb RunAs would discard them.
    $nativeProcess = Start-Process -FilePath $NativeLauncherPath -ArgumentList $nativeArgs -Environment $nativeEnvironment -WorkingDirectory (Split-Path -Parent $NativeLauncherPath) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logRoot 'native.stdout.log') -RedirectStandardError (Join-Path $logRoot 'native.stderr.log') -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ((Get-ListenerPid -Port $IngressPort) -and (Get-ListenerPid -Port $EgressPort)) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Get-ListenerPid -Port $IngressPort) -or -not (Get-ListenerPid -Port $EgressPort)) { throw 'canary_native_route_ports_not_ready' }

    # Reasonix: enable headroom compression-decision debug for the canary
    # compression gate so a non-compressing decision is visible in logs.
    $env:HEADROOM_CODEX_COMPRESSION_DEBUG = '1'
    & $startHeadroom -Port $GatewayPort -HeadroomPort $HeadroomPort -HelperPort $EgressPort -Workers 1 -PythonPath $python -RuntimeStateRoot $stateRoot -RuntimeLogRoot $logRoot -KompressEndpoint $brokerUrl | Out-Null
    Remove-Item Env:HEADROOM_CODEX_COMPRESSION_DEBUG -ErrorAction SilentlyContinue
    $headroom = Wait-HttpReady -Url ($headroomUrl + '/health')
    $gateway = Wait-HttpReady -Url ($gatewayUrl + '/livez')
    $gatewayProcessId = Get-ListenerPid -Port $GatewayPort
    if ($headroom.ready -ne $true -or $gateway.alive -ne $true) { throw 'canary_sidecar_readiness_failed' }

    $monitorEnvironment = @{
        PYTHONPATH = $moduleRoot
        ROUTE_C_CANARY_GENERATION = (Split-Path -Leaf $canaryRoot)
        ROUTE_C_INGRESS_PORT = $IngressPort.ToString()
        ROUTE_C_EGRESS_PORT = $EgressPort.ToString()
        ROUTE_C_GATEWAY_PORT = $GatewayPort.ToString()
        ROUTE_C_MONITOR_PORT = $MonitorPort.ToString()
        ROUTE_C_HEADROOM_PORT = $HeadroomPort.ToString()
        ROUTE_C_BROKER_PORT = $BrokerPort.ToString()
    }
    $monitorProcess = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn',$monitorModule,'--app-dir',$quotedModuleRoot,'--host','127.0.0.1','--port',$MonitorPort.ToString(),'--no-access-log') -Environment $monitorEnvironment -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logRoot 'monitor.stdout.log') -RedirectStandardError (Join-Path $logRoot 'monitor.stderr.log') -PassThru
    $monitor = Wait-HttpReady -Url ("http://127.0.0.1:{0}/health" -f $MonitorPort) -TimeoutSeconds 30
    if ($monitor.ready -ne $true -or $monitor.route_scope -ne 'isolated') { throw 'canary_monitor_readiness_failed' }

    $mainBody = '{"model":"canary-model","input":"route-c-main","stream":true}'
    $mainResponse = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/responses" -f $IngressPort) -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 60 -ContentType 'application/json' -Headers @{
        Accept = 'text/event-stream'
        'x-headroom-synthetic-run-id' = 'route-c-main'
    } -Body $mainBody
    if ([int]$mainResponse.StatusCode -ne 200 -or $mainResponse.Content -notmatch 'response\.completed') { throw 'canary_main_stream_terminal_missing' }

    $spawnedBody = '{"model":"canary-model","input":"route-c-spawned","stream":true}'
    $spawnedMetadata = '{"subagent_kind":"thread_spawn","parent_thread_id":"route-c-parent"}'
    $spawnedResponse = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/responses" -f $IngressPort) -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 60 -ContentType 'application/json' -Headers @{
        Accept = 'text/event-stream'
        'x-codex-turn-metadata' = $spawnedMetadata
        'x-headroom-synthetic-run-id' = 'route-c-spawned'
    } -Body $spawnedBody
    if ([int]$spawnedResponse.StatusCode -ne 200 -or $spawnedResponse.Content -notmatch 'response\.completed') { throw 'canary_spawned_stream_terminal_missing' }

    $upstreamStatePath = Join-Path $stateRoot 'fake-upstream.json'
    if (-not (Test-Path -LiteralPath $upstreamStatePath -PathType Leaf)) { throw 'canary_fake_upstream_evidence_missing' }
    $upstreamState = Get-Content -LiteralPath $upstreamStatePath -Raw | ConvertFrom-Json
    if ([int]$upstreamState.requests -lt 2) { throw 'canary_fake_upstream_request_count_invalid' }
    $gatewayMetricsPath = Join-Path $stateRoot 'gateway-metrics-state.json'
    $gatewayMetrics = if (Test-Path -LiteralPath $gatewayMetricsPath -PathType Leaf) { Get-Content -LiteralPath $gatewayMetricsPath -Raw | ConvertFrom-Json } else { $null }
    $recent = if ($gatewayMetrics) { @($gatewayMetrics.recent) } else { @() }
    # The gateway redacts caller-supplied synthetic run ids into a digest
    # (syn_<sha256>), so match on request_class + policy_mode instead of the
    # original run id.  Only the two canary test requests hit this gateway.
    $mainMetric = $recent | Where-Object { $_.request_class -eq 'main' } | Select-Object -Last 1
    $spawnedMetric = $recent | Where-Object { $_.request_class -eq 'spawned' } | Select-Object -Last 1
    if ($null -eq $mainMetric -or [string]$mainMetric.request_class -ne 'main' -or [string]$mainMetric.policy_mode -ne 'compress') { throw 'canary_main_metric_contract_failed' }
    if ($null -eq $spawnedMetric -or [string]$spawnedMetric.request_class -ne 'spawned' -or [string]$spawnedMetric.policy_mode -ne 'bypass') { throw 'canary_spawned_metric_contract_failed' }

    # Compression gate (P58): prove nonzero Kompress execution end-to-end.
    # A ~4000-token synthetic main request must reach the broker and be
    # compressed (compressed counter > 0).  ONNX CPU inference costs roughly
    # 1.5s per 1000 tokens on this host, so 4000 tokens fits comfortably in
    # the 20s remote-client budget; larger bodies (>=13k tokens) exceed it
    # and degrade to passthrough by design.
    $compressText = ('This is a canary compression candidate that exercises the Kompress pipeline. ' * 400)
    # Headroom's Responses compression ONLY compresses tool-output items
    # (function_call_output / custom_tool_call_output); user input_text items
    # sit in the cacheable prefix and are intentionally never compressed
    # (mutating them busts prefix caching).  Use a tool-output item so the
    # router actually has a compressible unit to hand to Kompress.
    $compressBody = @{ model = 'canary-model'; input = @(@{ type = 'custom_tool_call_output'; call_id = 'canary-compress-call'; output = $compressText }); stream = $true } | ConvertTo-Json -Depth 5
    $compressResponse = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/v1/responses" -f $IngressPort) -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 90 -ContentType 'application/json' -Headers @{
        Accept = 'text/event-stream'
        'x-headroom-synthetic-run-id' = 'route-c-compress'
    } -Body $compressBody
    if ([int]$compressResponse.StatusCode -ne 200 -or $compressResponse.Content -notmatch 'response\.completed') { throw 'canary_compress_stream_terminal_missing' }
    Start-Sleep -Seconds 2
    # The broker may be reused, so an absolute counter is not evidence that
    # this run compressed anything.  Require a post-request counter delta and
    # verify that the listener PID did not change while the request ran.
    $brokerSnapshotAfter = Get-BrokerSnapshot
    $brokerCountersAfter = $brokerSnapshotAfter.counters
    if ($brokerSnapshotAfter.pid -ne $brokerPid) { throw 'canary_broker_identity_changed' }
    $brokerCountersDelta = [ordered]@{}
    foreach ($counterName in @('total', 'compressed', 'passthrough', 'timeout', 'queue_full', 'worker_restart', 'device_removal', 'error')) {
        $before = Get-CounterValue -Counters $brokerCountersBefore -Name $counterName
        $after = Get-CounterValue -Counters $brokerCountersAfter -Name $counterName
        $brokerCountersDelta[$counterName] = $after - $before
    }
    if ([int]$brokerCountersDelta.compressed -lt 1) {
        throw ('canary_compress_gate_failed:broker_compressed_delta={0}' -f [int]$brokerCountersDelta.compressed)
    }
    Write-Receipt -Status 'ready'
    if ($KeepRunning) {
        Get-Content -LiteralPath $evidencePath -Raw
        return
    }
}
catch {
    $runFailure = $_
    try { Write-Receipt -Status 'failed' -ErrorCode $_.Exception.Message } catch { }
}
finally {
    if (-not $KeepRunning) {
        try { & $stopHeadroom -Port $HeadroomPort -RuntimeStateRoot $stateRoot | Out-Null } catch { }
        Stop-CanaryListener -Port $GatewayPort -CommandPattern ("(?i)gateway:app.*--port\s+" + [regex]::Escape($GatewayPort.ToString()))
        if ($monitorProcess) { try { if (-not $monitorProcess.HasExited) { Stop-Process -Id $monitorProcess.Id -Force -ErrorAction SilentlyContinue } } catch { } }
        if ($nativeProcess) { try { if (-not $nativeProcess.HasExited) { Stop-Process -Id $nativeProcess.Id -Force -ErrorAction SilentlyContinue } } catch { } }
        if ($brokerProcess) { try { if (-not $brokerProcess.HasExited) { Stop-Process -Id $brokerProcess.Id -Force -ErrorAction SilentlyContinue } } catch { } }
        if ($upstreamProcess) { try { if (-not $upstreamProcess.HasExited) { Stop-Process -Id $upstreamProcess.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

if ($runFailure) { throw $runFailure }
Get-Content -LiteralPath $evidencePath -Raw
