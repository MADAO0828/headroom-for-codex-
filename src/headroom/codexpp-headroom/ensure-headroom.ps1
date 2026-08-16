[CmdletBinding()]
param(
    [int]$Port = 18787,
    [int]$HeadroomPort = 18789,
    [ValidateRange(1, 65535)]
    [int]$HelperPort = 57321,
    [ValidateSet(1, 2)]
    [int]$Workers = 1,
    [string]$PythonPath = '',
    [string]$RuntimeStateRoot = '',
    [string]$RuntimeLogRoot = '',
    [string]$KompressEndpoint = '',
    [switch]$AllowRelayPending
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$runtimeRoot = Join-Path $projectRoot 'runtime'
if ([string]::IsNullOrWhiteSpace($PythonPath)) { $PythonPath = Join-Path $runtimeRoot 'python\Scripts\python.exe' }
if ([string]::IsNullOrWhiteSpace($RuntimeStateRoot)) { $RuntimeStateRoot = Join-Path $runtimeRoot 'state' }
if ([string]::IsNullOrWhiteSpace($RuntimeLogRoot)) { $RuntimeLogRoot = Join-Path $runtimeRoot 'logs' }
if ([string]::IsNullOrWhiteSpace($KompressEndpoint)) { $KompressEndpoint = 'http://127.0.0.1:18790' }
[IO.Directory]::CreateDirectory($RuntimeStateRoot) | Out-Null
[IO.Directory]::CreateDirectory($RuntimeLogRoot) | Out-Null
$legacyStatePath = Join-Path $RuntimeStateRoot 'headroom-state.json'
$startScript = Join-Path $PSScriptRoot 'start-headroom.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-headroom.ps1'
$GatewayPort = $Port
$Port = $HeadroomPort
$statePath = Join-Path $RuntimeStateRoot ("headroom-state-{0}.json" -f $Port)
$baseUrl = "http://127.0.0.1:$Port"
$gatewayBaseUrl = "http://127.0.0.1:$GatewayPort"
$gatewayScript = Join-Path $PSScriptRoot 'gateway.py'
$gatewayStatePath = Join-Path $RuntimeStateRoot 'gateway-process-state.json'
$gatewayMetricsStatePath = Join-Path $RuntimeStateRoot 'gateway-metrics-state.json'
$python = [IO.Path]::GetFullPath($PythonPath)

# Environment variables for Headroom. Set here so start-headroom.ps1 inherits them.
# Cache mode is the production coding posture: preserve the frozen prefix and
# send eligible new content through the normal compression decision pipeline.
$env:HEADROOM_MODE = 'cache'
$env:HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
$env:HEADROOM_ONNX_CPU_ARENA = '1'
$env:HEADROOM_SKIP_UPSTREAM_CHECK = '1'
$env:HEADROOM_WS_FAIL_OPEN_ON_COMPRESSION_FAILURE = '1'
$env:HEADROOM_KOMPRESS_TIME_BUDGET_SECONDS = '25'
$env:HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS = '20'
$env:KOMPRESS_REQUEST_TIMEOUT_SECONDS = '20'
$env:HEADROOM_PIPELINE_BREAKER_THRESHOLD = '3'
$env:HEADROOM_PIPELINE_BREAKER_COOLDOWN_S = '300'
$env:HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
$env:HEADROOM_KOMPRESS_MAX_CONCURRENT = '1'
$env:HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM = '1'
$env:HEADROOM_KOMPRESS_ENDPOINT = $KompressEndpoint
$env:HELPER_URL = "http://127.0.0.1:$HelperPort"
$env:HEADROOM_WORKERS = $Workers.ToString()
$env:HEADROOM_RUNTIME_ROOT = $runtimeRoot
$env:HEADROOM_WORKSPACE_DIR = Join-Path $runtimeRoot 'private\headroom-workspace'
$env:HEADROOM_CONFIG_DIR = Join-Path $runtimeRoot 'private\headroom-config'
$env:HEADROOM_CACHE_DIR = Join-Path $runtimeRoot 'cache\headroom'
$env:HF_HOME = Join-Path $runtimeRoot 'cache\huggingface'
$env:TRANSFORMERS_CACHE = Join-Path $runtimeRoot 'cache\huggingface\transformers'
$env:HEADROOM_TELEMETRY = 'off'
$env:TRANSFORMERS_OFFLINE = '1'
$env:HF_HUB_DISABLE_SYSTEM_DOWNLOADS = '1'

$script:RuntimeContractVersion = 1
$script:ToolOutputParallelism = '1'
$script:KompressMaxConcurrent = '1'
$script:ResponsesCompressionSoftBudgetSeconds = [Environment]::GetEnvironmentVariable('HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS', 'Process')
if ([string]::IsNullOrWhiteSpace($script:ResponsesCompressionSoftBudgetSeconds)) { $script:ResponsesCompressionSoftBudgetSeconds = '20' }
$script:KompressRequestTimeoutSeconds = [Environment]::GetEnvironmentVariable('KOMPRESS_REQUEST_TIMEOUT_SECONDS', 'Process')
if ([string]::IsNullOrWhiteSpace($script:KompressRequestTimeoutSeconds)) { $script:KompressRequestTimeoutSeconds = '20' }
$script:PatchSyncReceiptPath = Join-Path $RuntimeStateRoot 'headroom-runtime-patch-sync.json'

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
    $launcherPath = Join-Path $PSScriptRoot 'headroom-launcher.py'
    $launcherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $launcherPath).Hash.ToLowerInvariant()
    $startHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $startScript).Hash.ToLowerInvariant()
    $patchSync = Get-HeadroomPatchSyncContract
    return [ordered]@{
        runtime_contract_version = $script:RuntimeContractVersion
        launcher_sha256 = $launcherHash
        start_script_sha256 = $startHash
        port = $Port
        helper_port = $HelperPort
        workers = $Workers
        target = "http://127.0.0.1:$HelperPort"
        kompress_endpoint = $KompressEndpoint
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

function Get-HeadroomState {
    $candidate = $statePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-Path -LiteralPath $legacyStatePath -PathType Leaf)) {
        # Legacy state is read-only compatibility input; all new writes use
        # the port-specific path above.
        $candidate = $legacyStatePath
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
    } catch {
        return $null
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
    $pidValue = 0
    if (-not $statePort -or -not [int]::TryParse([string]$statePort.Value, [ref]$portValue) -or $portValue -ne $Port) {
        throw "Refusing to manage PID $ListenerPid; state file port does not match $Port"
    }
    if (-not $stateListenerPid -or -not [int]::TryParse([string]$stateListenerPid.Value, [ref]$listenerValue) -or $listenerValue -ne $ListenerPid) {
        throw "Refusing to manage PID $ListenerPid; state file does not identify the listener"
    }
    if (-not $statePid -or -not [int]::TryParse([string]$statePid.Value, [ref]$pidValue) -or $pidValue -ne $ListenerPid) {
        throw "Refusing to manage PID $ListenerPid; state PID fields disagree"
    }
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

function Test-HeadroomHealthy {
    return ((Test-HeadroomEndpoint -Url "$baseUrl/livez" -Kind livez) -and (Test-HeadroomEndpoint -Url "$baseUrl/health" -Kind health))
}

function Test-KompressBrokerReady {
    try {
        $response = Invoke-WebRequest -Uri ($KompressEndpoint.TrimEnd('/') + '/readyz') -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 5
        if ([int]$response.StatusCode -ne 200) { return $false }
        $body = $response.Content | ConvertFrom-Json
        return ([string]$body.service -eq 'kompress-broker' -and $body.ready -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$body.provider) -and -not [string]::IsNullOrWhiteSpace([string]$body.backend))
    }
    catch { return $false }
}

function Test-StateIdentityFields {
    param([object]$State)

    foreach ($field in 'ListenerPath', 'ListenerStartedAt', 'ParentPath', 'ParentStartedAt') {
        $property = $State.PSObject.Properties[$field]
        if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $false
        }
    }
    return $true
}

function Test-StateCompatibility {
    param([object]$State)
    if ($null -eq $State) { return $false }
    $schema = $State.PSObject.Properties['state_schema_version']
    $contract = $State.PSObject.Properties['route_contract_version']
    $runtimeHash = $State.PSObject.Properties['runtime_contract_sha256']
    return ($null -ne $schema -and [int]$schema.Value -eq 2 -and $null -ne $contract -and [int]$contract.Value -eq 2 -and [string]$State.http_mode -eq 'responses' -and [string]$State.wire_api -eq 'responses' -and $State.supports_websockets -eq $false -and $null -ne $runtimeHash -and [string]$runtimeHash.Value -eq (Get-HeadroomRuntimeContractHash))
}

function Test-ManagedHeadroomListenerIdentity {
    param(
        [object]$State,
        [int]$ListenerPid,
        [object]$Process
    )

    $fail = {
        param([string]$Reason)
        throw "headroom_port_conflict_unmanaged: $Reason"
    }

    if ($null -eq $State) {
        & $fail 'state is missing or invalid'
    }
    if ($ListenerPid -le 0) {
        & $fail 'listener PID is invalid'
    }
    if ($null -eq $Process) {
        & $fail "listener PID $ListenerPid no longer exists"
    }

    foreach ($field in 'Port', 'Pid', 'ListenerPid') {
        $property = $State.PSObject.Properties[$field]
        $value = 0
        if (-not $property -or -not [int]::TryParse([string]$property.Value, [ref]$value)) {
            & $fail "state field $field is missing or invalid"
        }
        if (($field -eq 'Port' -and $value -ne $Port) -or (($field -eq 'Pid' -or $field -eq 'ListenerPid') -and $value -ne $ListenerPid)) {
            & $fail "state field $field does not match the listener"
        }
    }

    $workersProperty = $State.PSObject.Properties['Workers']
    $stateWorkers = 0
    if (-not $workersProperty -or -not [int]::TryParse([string]$workersProperty.Value, [ref]$stateWorkers) -or $stateWorkers -notin @(1, 2)) {
        & $fail 'state worker count is missing or invalid'
    }
    if ($stateWorkers -ne $Workers) {
        & $fail "state worker count $stateWorkers does not match expected $Workers"
    }

    # ListenerPath/StartedAt and their parent counterparts are the minimum
    # identity contract. They remain valid for legacy route/schema versions.
    if (-not (Test-StateIdentityFields -State $State)) {
        & $fail 'state process identity fields are missing'
    }
    foreach ($field in 'state_schema_version', 'route_contract_version') {
        $property = $State.PSObject.Properties[$field]
        if ($property) {
            $version = 0
            if (-not [int]::TryParse([string]$property.Value, [ref]$version) -or $version -le 0) {
                & $fail "state field $field is invalid"
            }
        }
    }

    $processId = 0
    $processIdProperty = $Process.PSObject.Properties['Id']
    if (-not $processIdProperty -or -not [int]::TryParse([string]$processIdProperty.Value, [ref]$processId) -or $processId -ne $ListenerPid) {
        & $fail 'process PID does not match the listener'
    }
    if ([string]$Process.Name -notmatch '^python(?:\.exe)?$') {
        & $fail 'listener process is not Python'
    }

    $normalizePath = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        try { return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $null }
    }
    $expectedListenerPath = & $normalizePath ([string]$State.ListenerPath)
    $expectedParentPath = & $normalizePath ([string]$State.ParentPath)
    $knownPythonPath = & $normalizePath $python
    $launcherPath = & $normalizePath (Join-Path $PSScriptRoot 'headroom-launcher.py')
    if ($null -eq $expectedListenerPath -or $null -eq $expectedParentPath -or $null -eq $knownPythonPath -or $null -eq $launcherPath) {
        & $fail 'state or deployment paths are invalid'
    }

    $actualPath = [string]$Process.Path
    $commandLine = [string]$Process.CommandLine
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $ListenerPid) -ErrorAction Stop | Select-Object -First 1
        if ($snapshot) {
            if ([string]::IsNullOrWhiteSpace($actualPath)) { $actualPath = [string]$snapshot.ExecutablePath }
            if ([string]::IsNullOrWhiteSpace($commandLine)) { $commandLine = [string]$snapshot.CommandLine }
        }
    } catch {
        # A missing process snapshot is handled by the required path/command checks below.
    }
    $actualPath = & $normalizePath $actualPath
    if ($null -eq $actualPath) {
        & $fail 'listener executable path is unavailable'
    }
    $knownExecutablePath = ([string]::Equals($actualPath, $expectedListenerPath, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($actualPath, $expectedParentPath, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($actualPath, $knownPythonPath, [StringComparison]::OrdinalIgnoreCase))
    if (-not $knownExecutablePath) {
        & $fail 'listener executable path is outside the deployment'
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        & $fail 'listener command line is unavailable'
    }
    $commandLineNormalized = $commandLine.Replace('/', '\')
    $launcherInCommand = $commandLineNormalized.IndexOf($launcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $pythonInCommand = ($commandLineNormalized.IndexOf($knownPythonPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $commandLineNormalized.IndexOf($expectedListenerPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $commandLineNormalized.IndexOf($expectedParentPath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    $portInCommand = $commandLineNormalized -match ("(?i)(?:^|\s)--port\s+{0}(?:\s|$)" -f [regex]::Escape($Port.ToString()))
    if (-not $launcherInCommand -or (-not $pythonInCommand -and -not $knownExecutablePath) -or -not $portInCommand) {
        & $fail 'listener command line does not identify this Headroom deployment'
    }

    $expectedTarget = "http://127.0.0.1:$HelperPort"
    $stateTarget = $State.PSObject.Properties['Target']
    if ($stateTarget -and -not [string]::Equals([string]$stateTarget.Value, $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        & $fail "state target does not match helper port $HelperPort"
    }
    $stateHelperPort = $State.PSObject.Properties['HelperPort']
    if ($stateHelperPort) {
        $stateHelperValue = 0
        if (-not [int]::TryParse([string]$stateHelperPort.Value, [ref]$stateHelperValue) -or $stateHelperValue -ne $HelperPort) {
            & $fail "state helper port does not match $HelperPort"
        }
    }

    try {
        $stateStartedAt = $State.ListenerStartedAt
        if ($stateStartedAt -is [DateTime]) {
            $expectedStartedAt = ([DateTime]$stateStartedAt).ToUniversalTime()
        } else {
            $expectedStartedAt = ([DateTimeOffset]::Parse([string]$stateStartedAt)).UtcDateTime
        }
        $actualStartedAt = ([DateTime]$Process.StartTime).ToUniversalTime()
        if ([Math]::Abs(($actualStartedAt - $expectedStartedAt).TotalSeconds) -gt 10) {
            & $fail 'listener start time does not match state'
        }
    } catch {
        if ($_.Exception.Message -like 'headroom_port_conflict_unmanaged*') { throw }
        & $fail 'listener start time is unavailable or invalid'
    }
    return $true
}

function Wait-PortFree {
    param([DateTime]$Deadline)

    do {
        if ($null -eq (Get-ListenerPid -ListenPort $Port)) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $Deadline)
    throw "Headroom port 127.0.0.1:$Port did not become free after stop"
}

function Get-GatewayState {
    if (-not (Test-Path -LiteralPath $gatewayStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $gatewayStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-GatewaySnapshot {
    param(
        [AllowNull()][object]$Body,
        [int]$StatusCode,
        [ValidateSet('livez','health')][string]$Kind,
        [switch]$AllowRelayPending
    )

    if ($null -eq $Body -or $StatusCode -le 0) { return $false }
    if ([string]$Body.service -ne 'policy-gateway') { return $false }
    if ($Kind -eq 'livez') {
        return $StatusCode -eq 200 -and [string]$Body.status -eq 'healthy' -and $Body.alive -eq $true
    }
    if ($StatusCode -eq 200 -and [string]$Body.status -eq 'healthy' -and $Body.ready -eq $true) {
        return $true
    }
    if (-not $AllowRelayPending) { return $false }

    # Before Manager/client launch, preserve only the exact Gateway state
    # produced while helper $HelperPort is not listening.  Any other 503, including
    # an unhealthy Headroom dependency or a reachable helper returning 500,
    # remains fail-closed.
    $checks = $Body.PSObject.Properties['checks']
    $headroom = if ($checks) { $Body.checks.PSObject.Properties['headroom'] } else { $null }
    $helper = if ($checks) { $Body.checks.PSObject.Properties['helper'] } else { $null }
    return (
        $StatusCode -eq 503 -and [string]$Body.status -eq 'degraded' -and $Body.ready -eq $false -and
        $null -ne $headroom -and $Body.checks.headroom.ok -eq $true -and
        $null -ne $helper -and $Body.checks.helper.ok -eq $false -and
        $null -eq $Body.checks.helper.status_code
    )
}

function Test-GatewayEndpoint {
    param(
        [string]$Url,
        [ValidateSet('livez','health')][string]$Kind,
        [switch]$AllowRelayPending
    )
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 15
        $body = $response.Content | ConvertFrom-Json
        return Test-GatewaySnapshot -Body $body -StatusCode ([int]$response.StatusCode) -Kind $Kind -AllowRelayPending:$AllowRelayPending
    } catch { return $false }
}

function Test-GatewayHealthy {
    param([switch]$AllowRelayPending)
    return ((Test-GatewayEndpoint -Url "$gatewayBaseUrl/livez" -Kind livez) -and (Test-GatewayEndpoint -Url "$gatewayBaseUrl/health" -Kind health -AllowRelayPending:$AllowRelayPending))
}

function Get-GatewayProcessPath {
    param([Parameter(Mandatory)][object]$Process)
    $path = [string]$Process.Path
    if ([string]::IsNullOrWhiteSpace($path)) {
        try { $path = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Process.Id)" -ErrorAction Stop | Select-Object -First 1 -ExpandProperty ExecutablePath) } catch { }
    }
    return $path
}

function Assert-GatewayState {
    param([Parameter(Mandatory)][object]$State,[int]$ListenerPid,[object]$Process)
    if ($null -eq $Process -or $Process.Name -notlike 'python*') { throw "policy_gateway_port_conflict_unmanaged: listener process is not Python" }
    $portValue = 0; $pidValue = 0; $headroomValue = 0; $helperValue = 0
    if (-not $State -or -not $State.PSObject.Properties['Port'] -or -not [int]::TryParse([string]$State.Port,[ref]$portValue) -or $portValue -ne $GatewayPort) { throw "policy_gateway_port_conflict_unmanaged: gateway state port mismatch" }
    if ($State.PSObject.Properties['HeadroomPort'] -and (-not [int]::TryParse([string]$State.HeadroomPort,[ref]$headroomValue) -or $headroomValue -ne $Port)) { throw "policy_gateway_port_conflict_unmanaged: gateway headroom port mismatch" }
    if ($State.PSObject.Properties['HelperPort'] -and (-not [int]::TryParse([string]$State.HelperPort,[ref]$helperValue) -or $helperValue -ne $HelperPort)) { throw "policy_gateway_port_conflict_unmanaged: gateway helper port mismatch" }
    if (-not $State.PSObject.Properties['Pid'] -or -not [int]::TryParse([string]$State.Pid,[ref]$pidValue) -or $pidValue -ne $ListenerPid) { throw "policy_gateway_port_conflict_unmanaged: gateway state PID mismatch" }
    $statePathValue = [string]$State.Path
    $actualPath = Get-GatewayProcessPath -Process $Process
    if ([string]::IsNullOrWhiteSpace($statePathValue) -or [string]::IsNullOrWhiteSpace($actualPath) -or -not [IO.Path]::GetFullPath($statePathValue).Equals([IO.Path]::GetFullPath($actualPath),[StringComparison]::OrdinalIgnoreCase)) {
        throw "policy_gateway_port_conflict_unmanaged: gateway executable identity mismatch"
    }
}

function Write-GatewayState {
    param([Parameter(Mandatory)][object]$Process)
    $document = [ordered]@{
        gateway_schema_version = 2
        route_contract_version = 3
        service = 'policy-gateway'
        state_role = 'gateway-process-identity'
        Pid = [int]$Process.Id
        Port = $GatewayPort
        HeadroomPort = $Port
        HelperPort = $HelperPort
        Path = Get-GatewayProcessPath -Process $Process
        StartedAt = ([DateTime]::UtcNow.ToString('o'))
        updated_at_utc = ([DateTime]::UtcNow.ToString('o'))
    } | ConvertTo-Json -Depth 4
    $directory = Split-Path -Parent $gatewayStatePath
    $temporary = Join-Path $directory ('.gateway-state-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary,$document,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$gatewayStatePath,$true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Ensure-PolicyGateway {
    param([switch]$AllowRelayPending)
    if (-not (Test-Path -LiteralPath $gatewayScript -PathType Leaf)) { throw "Policy gateway source is missing: $gatewayScript" }
    $listenerPid = Get-ListenerPid -ListenPort $GatewayPort
    if ($null -ne $listenerPid) {
        $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        $state = Get-GatewayState
        Assert-GatewayState -State $state -ListenerPid $listenerPid -Process $listenerProcess
        if (-not (Test-GatewayHealthy -AllowRelayPending:$AllowRelayPending)) {
            Write-Log "Gateway exists but unhealthy; removing and will recreate"
            try { Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue } catch {}
            try { Stop-Process -Id (Get-CimInstance Win32_Process -Filter "ProcessId=$listenerPid").ParentProcessId -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Seconds 3
        } else { return }
    }

    $stdoutPath = Join-Path $RuntimeLogRoot "gateway-$GatewayPort.stdout.log"
    $stderrPath = Join-Path $RuntimeLogRoot "gateway-$GatewayPort.stderr.log"
    $env:HEADROOM_URL = $baseUrl
    $env:HELPER_URL = "http://127.0.0.1:$HelperPort"
    $env:POLICY_GATEWAY_STATE_PATH = $gatewayMetricsStatePath
    $gatewayProcess = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','gateway:app','--host','127.0.0.1','--port',$GatewayPort.ToString(),'--no-access-log') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    $listenerPid = $null
    do {
        Start-Sleep -Milliseconds 250
        $listenerPid = Get-ListenerPid -ListenPort $GatewayPort
        if ($null -ne $listenerPid -and (Test-GatewayHealthy -AllowRelayPending:$AllowRelayPending)) { break }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $listenerPid -or -not (Test-GatewayHealthy -AllowRelayPending:$AllowRelayPending)) {
        if ($null -ne $listenerPid) { try { Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue } catch {} }
        try { Stop-Process -Id $gatewayProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw 'policy_gateway_ready_timeout'
    }
    $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
    Assert-GatewayState -State ([pscustomobject]@{ Port = $GatewayPort; Pid = $listenerPid; Path = (Get-GatewayProcessPath -Process $listenerProcess) }) -ListenerPid $listenerPid -Process $listenerProcess
    Write-GatewayState -Process $listenerProcess
    Write-Log "policy gateway ready on $gatewayBaseUrl; Headroom remains on $baseUrl"
}

$logStamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
$logStamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
$logFile = Join-Path $RuntimeLogRoot "headroom-$Port-$logStamp.log"
function Write-Log { param([string]$Msg) $time = [DateTime]::UtcNow.ToString('HH:mm:ss'); Write-Output "[$time] $Msg" }

$ensureMutex = [Threading.Mutex]::new($false, 'Local\CodexPlusPlusHeadroomEnsure')
$ensureMutexHeld = $false
try {
    try {
        $ensureMutexHeld = $ensureMutex.WaitOne([TimeSpan]::FromSeconds(15))
    } catch [Threading.AbandonedMutexException] {
        $ensureMutexHeld = $true
    }
    if (-not $ensureMutexHeld) {
        Write-Log "mutex timeout"
        throw "Timed out waiting for the Headroom ensure lock"
    }
    Assert-HeadroomPatchSyncContract

    if (-not (Test-Path -LiteralPath $startScript) -or -not (Test-Path -LiteralPath $stopScript)) {
        Write-Log "lifecycle scripts missing"
        throw "Headroom lifecycle scripts are missing"
    }
    if (-not (Test-Path -LiteralPath $python)) {
        Write-Log "python not found at $python"
        throw "Python executable not found at $python"
    }
    Write-Log "calling Assert-KompressDependencies"
    $kompressReady = Assert-KompressDependencies -PythonPath $python
    if (-not $kompressReady) { throw 'kompress_dependencies_unavailable' }
    if (-not (Test-KompressBrokerReady)) { throw 'kompress_broker_not_ready' }
    Write-Log "Kompress dependencies and broker canary are ready"

    $listenerPid = Get-ListenerPid -ListenPort $Port
    if ($null -ne $listenerPid) {
        $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        if ($null -eq $listenerProcess -or $listenerProcess.Name -notlike 'python*') {
            throw "headroom_port_conflict_unmanaged: port $Port is bound by a non-Headroom process (PID $listenerPid)"
        }
    }
    if ($null -eq $listenerPid) {
        Write-Log "no listener on port $Port, calling start-headroom.ps1"
        try {
            & $startScript -Port $Port -HelperPort $HelperPort -Workers $Workers -PythonPath $python -RuntimeStateRoot $RuntimeStateRoot -RuntimeLogRoot $RuntimeLogRoot -KompressEndpoint $KompressEndpoint *>$null
            Write-Log "start-headroom.ps1 completed"
        } catch {
            Write-Log "start-headroom.ps1 threw: $($_.Exception.Message)"
            throw
        }
    } else {
        $state = Get-HeadroomState
        if ($null -eq $state) {
            throw "headroom_port_conflict_unmanaged: state is missing for listener PID $listenerPid"
        } else {
            $null = Test-ManagedHeadroomListenerIdentity -State $state -ListenerPid $listenerPid -Process $listenerProcess
            Assert-StateListener -State $state -ListenerPid $listenerPid
            $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
            if ($null -eq $listenerProcess -or $listenerProcess.Name -notlike 'python*') {
                throw "Refusing to manage PID $listenerPid; listener process identity is not Headroom Python"
            }
            $healthy = Test-HeadroomHealthy
            if (-not $healthy -or -not (Test-StateCompatibility -State $state)) {
                Write-Log "Headroom unhealthy, stopping PID $listenerPid"
                $null = Test-ManagedHeadroomListenerIdentity -State $state -ListenerPid $listenerPid -Process $listenerProcess
                try { & $stopScript -Port $Port -RuntimeStateRoot $RuntimeStateRoot -ErrorAction SilentlyContinue | Out-Null } catch { }
                Start-Sleep -Seconds 2
                try {
                    $boundPid = Get-ListenerPid -ListenPort $Port
                    if ($null -ne $boundPid) {
                        $boundProcess = Get-Process -Id $boundPid -ErrorAction SilentlyContinue
                        $boundState = Get-HeadroomState
                        $null = Test-ManagedHeadroomListenerIdentity -State $boundState -ListenerPid $boundPid -Process $boundProcess
                        Write-Log "port still bound after stopScript, force-killing managed PID $boundPid"
                        Stop-Process -Id $boundPid -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 3
                    }
                    Remove-Item (Join-Path $RuntimeLogRoot "headroom-$Port.stderr.log") -Force -ErrorAction SilentlyContinue
                } catch {
                    if ($_.Exception.Message -like 'headroom_port_conflict_unmanaged*') { throw }
                    Write-Log "kill cleanup error: $($_.Exception.Message)"
                }
                Write-Log "starting Headroom"
                & $startScript -Port $Port -HelperPort $HelperPort -Workers $Workers -PythonPath $python -RuntimeStateRoot $RuntimeStateRoot -RuntimeLogRoot $RuntimeLogRoot -KompressEndpoint $KompressEndpoint *>$null
            }
        }
    }

    $finalPid = Get-ListenerPid -ListenPort $Port
    if ($null -eq $finalPid) {
        throw "Headroom listener is not present after ensure"
    }
    $finalState = Get-HeadroomState
    Assert-StateListener -State $finalState -ListenerPid $finalPid
    $finalProcess = Get-Process -Id $finalPid -ErrorAction SilentlyContinue
    $null = Test-ManagedHeadroomListenerIdentity -State $finalState -ListenerPid $finalPid -Process $finalProcess
    if (-not (Test-HeadroomHealthy)) {
        throw "Headroom health checks failed after ensure at $baseUrl/livez and $baseUrl/health"
    }
    Ensure-PolicyGateway -AllowRelayPending:$AllowRelayPending
} finally {
    if ($ensureMutexHeld) {
        try {
            $ensureMutex.ReleaseMutex()
        } catch {
        }
    }
    $ensureMutex.Dispose()
}
