[CmdletBinding()]
param(
    [int]$Port = 18789,
    [ValidateRange(1, 65535)]
    [int]$HelperPort = 57321,
    [ValidateSet(1, 2)]
    [int]$Workers = 1,
    [string]$PythonPath = '',
    [string]$RuntimeStateRoot = '',
    [string]$RuntimeLogRoot = '',
    [string]$KompressEndpoint = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$runtimeRoot = Join-Path $projectRoot 'runtime'
if ([string]::IsNullOrWhiteSpace($PythonPath)) { $PythonPath = Join-Path $runtimeRoot 'python\Scripts\python.exe' }
if ([string]::IsNullOrWhiteSpace($RuntimeStateRoot)) { $RuntimeStateRoot = Join-Path $runtimeRoot 'state' }
if ([string]::IsNullOrWhiteSpace($RuntimeLogRoot)) { $RuntimeLogRoot = Join-Path $runtimeRoot 'logs' }
if ([string]::IsNullOrWhiteSpace($KompressEndpoint)) { $KompressEndpoint = [Environment]::GetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', 'Process') }
if ([string]::IsNullOrWhiteSpace($KompressEndpoint)) { $KompressEndpoint = 'http://127.0.0.1:18790' }
[IO.Directory]::CreateDirectory($RuntimeStateRoot) | Out-Null
[IO.Directory]::CreateDirectory($RuntimeLogRoot) | Out-Null
$python = [IO.Path]::GetFullPath($PythonPath)
$launcher = Join-Path $PSScriptRoot 'headroom-launcher.py'
$target = "http://127.0.0.1:$HelperPort"
$kompressEndpoint = $KompressEndpoint
$script:StartScriptPath = $PSCommandPath
$script:RuntimeContractVersion = 1
$script:ToolOutputParallelism = '1'
$script:KompressMaxConcurrent = '1'
$script:ResponsesCompressionSoftBudgetSeconds = [Environment]::GetEnvironmentVariable('HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS', 'Process')
if ([string]::IsNullOrWhiteSpace($script:ResponsesCompressionSoftBudgetSeconds)) { $script:ResponsesCompressionSoftBudgetSeconds = '20' }
$script:KompressRequestTimeoutSeconds = [Environment]::GetEnvironmentVariable('KOMPRESS_REQUEST_TIMEOUT_SECONDS', 'Process')
if ([string]::IsNullOrWhiteSpace($script:KompressRequestTimeoutSeconds)) { $script:KompressRequestTimeoutSeconds = '20' }
$script:PatchSyncReceiptPath = Join-Path $RuntimeStateRoot 'headroom-runtime-patch-sync.json'
$legacyStatePath = Join-Path $RuntimeStateRoot 'headroom-state.json'
# New Headroom instances are isolated by port. The legacy path is read-only
# compatibility input for already-running instances.
$statePath = Join-Path $RuntimeStateRoot ("headroom-state-{0}.json" -f $Port)
$startupStatePath = Join-Path $RuntimeStateRoot ("headroom-startup-{0}.json" -f $Port)
$startupResultPath = Join-Path $RuntimeStateRoot ("headroom-startup-result-{0}.json" -f $Port)
$baseUrl = "http://127.0.0.1:$Port"
$attemptStartedAtUtc = $null
$baselineListenerPid = $null
$spawnedPid = $null
$listenerPid = $null
$startupCleanupStatus = 'not_attempted'

. (Join-Path $PSScriptRoot 'activation-lib.ps1')

function Get-HeadroomPatchSyncContract {
    if (-not (Test-Path -LiteralPath $script:PatchSyncReceiptPath -PathType Leaf)) {
        return [ordered]@{ patch_sync_status = 'missing'; patch_sync_version = 0; patch_sync_manifest_sha256 = '' }
    }
    try {
        $receipt = Get-Content -LiteralPath $script:PatchSyncReceiptPath -Raw | ConvertFrom-Json
        return [ordered]@{
            patch_sync_status = [string]$receipt.status
            patch_sync_version = [int]$receipt.sync_version
            patch_sync_manifest_sha256 = [string]$receipt.manifest_sha256
        }
    }
    catch {
        return [ordered]@{ patch_sync_status = 'invalid'; patch_sync_version = 0; patch_sync_manifest_sha256 = '' }
    }
}

function Assert-HeadroomPatchSyncContract {
    $contract = Get-HeadroomPatchSyncContract
    if ([string]$contract.patch_sync_status -notin @('synced', 'in_sync') -or [int]$contract.patch_sync_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$contract.patch_sync_manifest_sha256)) {
        throw 'headroom_runtime_patch_sync_missing_or_invalid'
    }
}

function Get-HeadroomRuntimeContract {
    $launcherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $launcher).Hash.ToLowerInvariant()
    $startHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:StartScriptPath).Hash.ToLowerInvariant()
    $patchSync = Get-HeadroomPatchSyncContract
    return [ordered]@{
        runtime_contract_version = $script:RuntimeContractVersion
        launcher_sha256 = $launcherHash
        start_script_sha256 = $startHash
        port = $Port
        helper_port = $HelperPort
        workers = $Workers
        target = $target
        kompress_endpoint = $kompressEndpoint
        tool_output_parallelism = $script:ToolOutputParallelism
        kompress_max_concurrent = $script:KompressMaxConcurrent
        responses_compression_soft_budget_seconds = $script:ResponsesCompressionSoftBudgetSeconds
        kompress_request_timeout_seconds = $script:KompressRequestTimeoutSeconds
        patch_sync_status = $patchSync.patch_sync_status
        patch_sync_version = $patchSync.patch_sync_version
        patch_sync_manifest_sha256 = $patchSync.patch_sync_manifest_sha256
    }
}

function Get-HeadroomRuntimeContractHash {
    $contract = Get-HeadroomRuntimeContract
    $canonical = (($contract.Keys | Sort-Object | ForEach-Object { "$_=$($contract[$_])" }) -join "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    return (([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-ListenerPid {
    param([int]$ListenPort)

    $listenerLines = @(netstat -ano | Select-String -Pattern "^\s*TCP\s+127\.0\.0\.1:$ListenPort\s+.*LISTENING\s+(\d+)\s*$")
    if ($listenerLines.Count -gt 1) {
        throw "Refusing to identify a single listener on 127.0.0.1:$ListenPort; found $($listenerLines.Count) listeners"
    }
    if ($listenerLines.Count -eq 0) {
        return $null
    }
    return [int]$listenerLines[0].Matches[0].Groups[1].Value
}

function Write-HeadroomStartupState {
    param([Parameter(Mandatory)][string]$Status,[AllowNull()][string]$Code,[string]$Cleanup = $startupCleanupStatus)
    $document = [ordered]@{
        startup_schema_version = 2
        state_path = $statePath
        startup_result_path = $startupResultPath
        status = $Status
        error_code = $Code
        cleanup_status = $Cleanup
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        attempt_started_at_utc = if ($attemptStartedAtUtc) { $attemptStartedAtUtc.ToString('o') } else { $null }
        port = $Port
        baseline_listener_pid = $baselineListenerPid
        spawned_pid = $spawnedPid
        listener_pid = $listenerPid
    }
    $directory = Split-Path -Parent $startupStatePath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temporary = Join-Path $directory ('.headroom-startup-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $startupStatePath, $true)
        if ($Status -in @('ready', 'failed')) {
            $resultTemporary = Join-Path $directory ('.headroom-startup-result-' + [IO.Path]::GetRandomFileName())
            try {
                [IO.File]::WriteAllText($resultTemporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($resultTemporary, $startupResultPath, $true)
            }
            finally {
                if (Test-Path -LiteralPath $resultTemporary) { Remove-Item -LiteralPath $resultTemporary -Force -ErrorAction SilentlyContinue }
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-HeadroomStartupErrorCode {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '(?i)health') { return 'headroom_health_failed' }
    if ($message -match '(?i)state') { return 'headroom_state_failed' }
    if ($message -match '(?i)listen|listener') { return 'headroom_listener_failed' }
    return 'headroom_start_failed'
}

function Stop-SpawnedHeadroomProcess {
    $snapshots = @()
    if ($spawnedPid -and $spawnedPid -gt 0) {
        try {
            $snapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$spawnedPid)
            if ($snapshot) { $snapshots += $snapshot }
        } catch { }
    }
    if ($listenerPid -and $listenerPid -gt 0 -and $listenerPid -ne $spawnedPid) {
        try {
            $snapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$listenerPid)
            if ($snapshot) { $snapshots += $snapshot }
        } catch { }
    }
    try {
        $processIds = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
        foreach ($processId in $processIds) {
            try {
                $snapshot = Get-ActivationProcessSnapshot -ProcessId $processId
                if ($snapshot) { $snapshots += $snapshot }
            } catch { }
        }
    } catch { }
    $candidates = @(Get-ActivationHeadroomSpawnCandidates -Processes $snapshots -PythonPath $python -LauncherPath $launcher -Port $Port -Target $target -ExpectedWorkers $Workers -NotBeforeUtc $attemptStartedAtUtc -BaselinePid ([int]$baselineListenerPid))
    if ($candidates.Count -eq 0) { return 'not_found' }
    $seen = @{}
    $stopped = 0
    foreach ($candidate in $candidates) {
        $candidateId = [int]$candidate.Id
        if ($seen.ContainsKey($candidateId)) { continue }
        $seen[$candidateId] = $true
        try {
            $candidateProcess = Get-Process -Id $candidateId -ErrorAction SilentlyContinue
            if ($candidateProcess) {
                Stop-Process -InputObject $candidateProcess -Force -ErrorAction Stop
                $stopped++
            }
        } catch { }
    }
    if ($stopped -gt 0) { return 'stopped' }
    return 'stop_failed'
}

function Assert-KompressDependencies {
    param([string]$PythonPath)

    $probe = @'
import importlib
for module_name in ("transformers", "onnxruntime", "numpy"):
    importlib.import_module(module_name)
from headroom.transforms.kompress_compressor import is_kompress_available
if not is_kompress_available():
    raise RuntimeError("kompress unavailable")
'@
    try { & $PythonPath -c $probe 1>$null 2>$null } catch { $env:HEADROOM_KOMPRESS_DEFERRED = '1'; return $false }
    if ($LASTEXITCODE -ne 0) { $env:HEADROOM_KOMPRESS_DEFERRED = '1'; return $false }
    $env:HEADROOM_KOMPRESS_DEFERRED = '0'
    return $true
}

function Test-KompressBrokerReady {
    try {
        $response = Invoke-WebRequest -Uri ($kompressEndpoint.TrimEnd('/') + '/readyz') -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        if ([int]$response.StatusCode -ne 200) { return $false }
        $body = $response.Content | ConvertFrom-Json
        return ([string]$body.service -eq 'kompress-broker' -and $body.ready -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$body.provider) -and -not [string]::IsNullOrWhiteSpace([string]$body.backend))
    }
    catch { return $false }
}

function Test-HeadroomEndpoint {
    param(
        [string]$Url,
        [ValidateSet('livez', 'health')]
        [string]$Kind
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -TimeoutSec 15
        if ([int]$response.StatusCode -ne 200) {
            return $false
        }
        $body = $response.Content | ConvertFrom-Json
        if ($body.service -ne 'headroom-proxy' -or $body.status -ne 'healthy') {
            return $false
        }
        if ($Kind -eq 'livez') {
            return ($body.alive -eq $true)
        }
        if ($body.ready -ne $true) {
            return $false
        }
        $checks = $body.PSObject.Properties['checks']
        $kompress = if ($checks) { $body.checks.PSObject.Properties['kompress'] } else { $null }
        if (-not $kompress) {
            return $false
        }
        if ($body.checks.kompress.enabled -eq $false) {
            return $true
        }
        if ($body.checks.kompress.enabled -eq $true -and $body.checks.kompress.ready -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$body.checks.kompress.backend)) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Assert-HeadroomHealth {
    if (-not (Test-HeadroomEndpoint -Url "$baseUrl/livez" -Kind livez)) {
        throw "Headroom liveness check failed at $baseUrl/livez"
    }
    if (-not (Test-HeadroomEndpoint -Url "$baseUrl/health" -Kind health)) {
        throw "Headroom health check failed at $baseUrl/health"
    }
}

function Wait-HeadroomHealth {
    param([DateTime]$Deadline)

    do {
        if ((Test-HeadroomEndpoint -Url "$baseUrl/livez" -Kind livez) -and (Test-HeadroomEndpoint -Url "$baseUrl/health" -Kind health)) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $Deadline)
    throw "Headroom health checks did not pass at $baseUrl/livez and $baseUrl/health before startup deadline"
}

function Get-HeadroomState {
    $candidate = $statePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-Path -LiteralPath $legacyStatePath -PathType Leaf)) {
        $candidate = $legacyStatePath
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Headroom state file is missing: $statePath"
    }
    try {
        return Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
    } catch {
        throw "Headroom state file is invalid: $candidate"
    }
}

function Assert-StateCompatibility {
    param([Parameter(Mandatory)][object]$State)
    $schema = $State.PSObject.Properties['state_schema_version']
    $contract = $State.PSObject.Properties['route_contract_version']
    if ($null -eq $schema -or [int]$schema.Value -ne 2 -or $null -eq $contract -or [int]$contract.Value -ne 2) {
        throw "Headroom state schema is incompatible; rerun deployment/ensure before startup."
    }
    if ([string]$State.http_mode -ne 'responses' -or [string]$State.wire_api -ne 'responses' -or $State.supports_websockets -ne $false) {
        throw "Headroom state HTTP contract is incompatible; refusing startup."
    }
    $expectedContract = Get-HeadroomRuntimeContract
    $stateContractHash = $State.PSObject.Properties['runtime_contract_sha256']
    if (-not $stateContractHash -or [string]$stateContractHash.Value -ne (Get-HeadroomRuntimeContractHash)) {
        throw 'Headroom runtime contract is stale or missing; refusing reuse of existing listener.'
    }
    $stateTarget = $State.PSObject.Properties['Target']
    if ($stateTarget -and -not [string]::Equals([string]$stateTarget.Value, $target, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Headroom state target is incompatible; expected $target."
    }
    $stateHelperPort = $State.PSObject.Properties['HelperPort']
    if ($stateHelperPort) {
        $stateHelperValue = 0
        if (-not [int]::TryParse([string]$stateHelperPort.Value, [ref]$stateHelperValue) -or $stateHelperValue -ne $HelperPort) {
            throw "Headroom state helper port is incompatible; expected $HelperPort."
        }
    }
}

function Assert-StateListener {
    param(
        [object]$State,
        [int]$ListenerPid
    )

    $statePort = $State.PSObject.Properties['Port']
    $stateListenerPid = $State.PSObject.Properties['ListenerPid']
    $statePid = $State.PSObject.Properties['Pid']
    $portValue = 0
    $listenerValue = 0
    if (-not $statePort -or -not [int]::TryParse([string]$statePort.Value, [ref]$portValue) -or $portValue -ne $Port) {
        throw "Refusing to claim PID $ListenerPid; state file port does not match $Port"
    }
    if (-not $stateListenerPid -or -not [int]::TryParse([string]$stateListenerPid.Value, [ref]$listenerValue) -or $listenerValue -ne $ListenerPid) {
        throw "Refusing to claim PID $ListenerPid; state file does not identify the listener"
    }
    if ($statePid) {
        $pidValue = 0
        if (-not [int]::TryParse([string]$statePid.Value, [ref]$pidValue) -or $pidValue -ne $ListenerPid) {
            throw "Refusing to claim PID $ListenerPid; state file PID fields disagree"
        }
    }
}

function Write-HeadroomState {
    param(
        [int]$ListenerPid,
        [int]$ParentPid,
        [object]$ListenerProcess,
        [object]$ParentProcess,
        [string]$StartedAt,
        [ValidateSet(1, 2)]
        [int]$Workers = 1
    )

    if ([string]::IsNullOrWhiteSpace($StartedAt)) {
        throw "Refusing to write Headroom state; startup timestamp is unavailable"
    }
    if ($null -eq $ListenerProcess -or [string]::IsNullOrWhiteSpace($ListenerProcess.Path) -or $null -eq $ListenerProcess.StartTime) {
        throw "Refusing to write Headroom state; listener executable identity is unavailable"
    }
    if ($null -eq $ParentProcess -or [string]::IsNullOrWhiteSpace($ParentProcess.Path) -or $null -eq $ParentProcess.StartTime) {
        throw "Refusing to write Headroom state; parent executable identity is unavailable"
    }
        $runtimeContract = Get-HeadroomRuntimeContract
        $stateJson = [pscustomobject]@{
            state_schema_version = 2
            route_contract_version = 2
            runtime_contract_version = $script:RuntimeContractVersion
            runtime_contract_sha256 = Get-HeadroomRuntimeContractHash
            launcher_sha256 = $runtimeContract.launcher_sha256
            start_script_sha256 = $runtimeContract.start_script_sha256
            tool_output_parallelism = $script:ToolOutputParallelism
            kompress_max_concurrent = $script:KompressMaxConcurrent
            responses_compression_soft_budget_seconds = $script:ResponsesCompressionSoftBudgetSeconds
            kompress_request_timeout_seconds = $script:KompressRequestTimeoutSeconds
            patch_sync_status = $runtimeContract.patch_sync_status
            patch_sync_version = $runtimeContract.patch_sync_version
            patch_sync_manifest_sha256 = $runtimeContract.patch_sync_manifest_sha256
            state_path = $statePath
            state_role = 'active-headroom'
            http_mode = 'responses'
            wire_api = 'responses'
            supports_websockets = $false
            Pid = $ListenerPid
        ListenerPid = $ListenerPid
        ParentPid = $ParentPid
        Port = $Port
        HelperPort = $HelperPort
        Workers = $Workers
        Target = $target
        StartedAt = $StartedAt
        ListenerStartedAt = $ListenerProcess.StartTime.ToUniversalTime().ToString('o')
        ListenerPath = $ListenerProcess.Path
        ParentStartedAt = $ParentProcess.StartTime.ToUniversalTime().ToString('o')
        ParentPath = $ParentProcess.Path
    } | ConvertTo-Json
    $stateDirectory = Split-Path -Parent $statePath
    $temporaryStatePath = Join-Path $stateDirectory ('.headroom-state-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporaryStatePath, $stateJson, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryStatePath, $statePath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryStatePath) {
            Remove-Item -LiteralPath $temporaryStatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
Assert-HeadroomPatchSyncContract
if (-not (Test-Path -LiteralPath $python)) {
    throw "Headroom Python runtime not found: $python"
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Headroom launcher not found: $launcher"
}
$kompressReady = Assert-KompressDependencies -PythonPath $python
if (-not $kompressReady) { throw 'kompress_dependencies_unavailable' }
if (-not (Test-KompressBrokerReady)) { throw 'kompress_broker_not_ready' }

$owner = Get-ListenerPid -ListenPort $Port
if ($null -ne $owner) {
    $state = Get-HeadroomState
    Assert-StateCompatibility -State $state
    Assert-StateListener -State $state -ListenerPid $owner
    $ownerProcess = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if ($null -eq $ownerProcess -or $ownerProcess.Name -notlike 'python*') {
        throw "Refusing to claim PID $owner on port ${Port}; listener process identity is not Headroom Python"
    }
    $existingParent = $null
    if ($state.ParentPid) {
        $existingParent = Get-Process -Id ([int]$state.ParentPid) -ErrorAction SilentlyContinue
    }
    if ($null -eq $existingParent -or $existingParent.Name -notlike 'python*') {
        throw "Refusing to claim PID $owner; state parent process identity is unavailable"
    }
    $ownerSnapshot = Get-ActivationProcessSnapshot -ProcessId $owner
    $parentSnapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$existingParent.Id)
    $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid $owner -Listener $ownerSnapshot -Parent $parentSnapshot -OldPort $Port -ExpectedWorkers $Workers -ExpectedLauncherPath $launcher -ExpectedStartScriptPath (Join-Path $PSScriptRoot 'start-headroom.ps1') -ExpectedPythonPath $python
    if (-not $identity.Ready) { throw [string]$identity.ErrorCode }
    Assert-HeadroomHealth
    Write-HeadroomState -ListenerPid $owner -ParentPid ([int]$existingParent.Id) -ListenerProcess $ownerProcess -ParentProcess $existingParent -StartedAt ([string]$state.StartedAt) -Workers $Workers
    $owner
    exit 0
}

$attemptStartedAtUtc = [DateTime]::UtcNow
$baselineListenerPid = Get-ListenerPid -ListenPort $Port
if ($null -ne $baselineListenerPid) {
    throw "Refusing to start Headroom on 127.0.0.1:$Port; a listener appeared during startup preparation"
}
Write-HeadroomStartupState -Status 'starting' -Code $null





$kompressIntraThreads = if ($Workers -le 1) { '12' } else { '8' }
$environment = @{
    # Preserve the frozen prefix while allowing the normal compression
    # decision pipeline to process eligible new content.
    HEADROOM_MODE = 'cache'
    HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
    HEADROOM_ONNX_CPU_ARENA = '1'
    HEADROOM_SKIP_UPSTREAM_CHECK = '1'
    HEADROOM_TELEMETRY = 'off'
    TRANSFORMERS_OFFLINE = '1'
    HF_HUB_DISABLE_SYSTEM_DOWNLOADS = '1'
    HEADROOM_WS_FAIL_OPEN_ON_COMPRESSION_FAILURE = '1'
    HEADROOM_KOMPRESS_TIME_BUDGET_SECONDS = '25'
    HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS = $script:ResponsesCompressionSoftBudgetSeconds
    HEADROOM_PIPELINE_BREAKER_THRESHOLD = '3'
    HEADROOM_PIPELINE_BREAKER_COOLDOWN_S = '300'
    # ONNX CPU owns the inference call. Twelve threads are fastest on this
    # 8-core/16-thread host for one worker; keep eight per worker when multiple
    # workers are requested so their model pools do not oversubscribe the CPU.
    HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = $kompressIntraThreads
    HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
    HEADROOM_KOMPRESS_MAX_CONCURRENT = '1'
    # The Responses handler otherwise dispatches four compression units in
    # parallel, while the remote broker intentionally owns one serialized
    # ONNX worker. Align both sides to prevent avoidable queue_full fallback.
    HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM = '1'
    HEADROOM_KOMPRESS_ENDPOINT = $kompressEndpoint
    HEADROOM_WORKERS = $Workers.ToString()
    HEADROOM_RUNTIME_ROOT = $runtimeRoot
    # Propagate the canary compression-debug opt-in if the caller set it.
    HEADROOM_CODEX_COMPRESSION_DEBUG = [Environment]::GetEnvironmentVariable('HEADROOM_CODEX_COMPRESSION_DEBUG', 'Process')
    # Headroom's official path resolver uses this variable for ~/.headroom
    # state, logs, savings and CCR data. Keep every runtime write under the
    # project root instead of falling back to the user's C: profile.
    HEADROOM_WORKSPACE_DIR = (Join-Path $runtimeRoot 'private\headroom-workspace')
    HEADROOM_CONFIG_DIR = (Join-Path $runtimeRoot 'private\headroom-config')
    HEADROOM_CACHE_DIR = (Join-Path $runtimeRoot 'cache\headroom')
    HF_HOME = (Join-Path $runtimeRoot 'cache\huggingface')
    TRANSFORMERS_CACHE = (Join-Path $runtimeRoot 'cache\huggingface\transformers')
}
$quotedLauncher = '"' + $launcher + '"'
$arguments = @(
    $quotedLauncher, 'proxy',
    '--host', '127.0.0.1',
    '--port', $Port.ToString(),
    '--no-http2',
    '--openai-api-url', $target,
    '--no-telemetry',
    '--workers', $Workers.ToString()
)
$stdoutPath = Join-Path $RuntimeLogRoot "headroom-$Port.stdout.log"
$stderrPath = Join-Path $RuntimeLogRoot "headroom-$Port.stderr.log"
foreach ($v in 'stdoutPath','stderrPath') { $p = (Get-Variable $v).Value; if (Test-Path $p) { try { $null = [IO.File]::OpenWrite($p).Close() } catch { Set-Variable $v (Join-Path $RuntimeLogRoot "headroom-$Port-$([DateTime]::UtcNow.Ticks).$($v -replace 'Path','').log") } } }
$process = Start-Process -FilePath $python -ArgumentList $arguments -Environment $environment -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
$spawnedPid = [int]$process.Id
Write-HeadroomStartupState -Status 'spawned' -Code $null



$deadline = (Get-Date).AddSeconds(90)
$listenerPid = $null
do {
    Start-Sleep -Milliseconds 250
    $listenerPid = Get-ListenerPid -ListenPort $Port
    if ($null -ne $listenerPid) {
        break
    }
} while ((Get-Date) -lt $deadline)
if ($null -eq $listenerPid) {
    throw "Headroom did not start listening on 127.0.0.1:$Port within 90 seconds."
}
$listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
# The listener PID might be transient; wait briefly for the real Headroom process to bind
$verifyDeadline = (Get-Date).AddSeconds(10)
while ($null -eq $listenerProcess -and (Get-Date) -lt $verifyDeadline) {
    Start-Sleep -Milliseconds 500
    $listenerPid = Get-ListenerPid -ListenPort $Port
    if ($null -ne $listenerPid) { $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue }
}
if ($null -eq $listenerProcess) {
    throw "Headroom listener PID $listenerPid no longer exists"
}
    if ($listenerProcess.Name -notlike 'python*' -and $listenerProcess.Name -notlike 'headroom*') {
    # Wait briefly - the port might transition from a terminated process
    Start-Sleep -Seconds 5
    $retryPid = Get-ListenerPid -ListenPort $Port
    if ($null -ne $retryPid) { $listenerPid = $retryPid; $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue }
    if ($null -eq $listenerProcess -or ($listenerProcess.Name -notlike 'python*' -and $listenerProcess.Name -notlike 'headroom*')) {
        throw "Headroom listener PID $listenerPid ($($listenerProcess.Name)) has unexpected process identity"
        }
    }
    Write-HeadroomStartupState -Status 'listening' -Code $null
    $healthDeadline = (Get-Date).AddSeconds(30)
Wait-HeadroomHealth -Deadline $healthDeadline
$listenerProcess | Out-Null
Write-HeadroomState -ListenerPid $listenerPid -ParentPid $process.Id -ListenerProcess $listenerProcess -ParentProcess $process -StartedAt $process.StartTime.ToUniversalTime().ToString('o') -Workers $Workers
Write-HeadroomStartupState -Status 'ready' -Code $null -Cleanup 'not_required'
$listenerPid
} catch {
    $startupCode = Get-HeadroomStartupErrorCode -ErrorRecord $_
    try { Write-HeadroomStartupState -Status 'failed' -Code $startupCode } catch { }
    try { $startupCleanupStatus = Stop-SpawnedHeadroomProcess } catch { $startupCleanupStatus = 'stop_failed' }
    try { Write-HeadroomStartupState -Status 'failed' -Code $startupCode -Cleanup $startupCleanupStatus } catch { }
    throw
}
