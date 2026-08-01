<#
.PARAMETER StartupGraceSeconds
Seconds without a Codex++ owner before watch mode exits. The default is 60 seconds.
.PARAMETER PrelaunchGraceSeconds
Seconds before the first Codex++ owner is expected during bootstrap. The default is 180 seconds.
.PARAMETER StartupPopupGraceSeconds
Seconds after monitor startup during which critical issues are logged and state-tracked, but popups are suppressed. The default is 25 seconds.
#>
[CmdletBinding()]
param(
    [string]$RuntimeRoot = '',
    [switch]$Watch,
    [switch]$Once,
    [switch]$NoPopup,
    [switch]$ImportOnly,
    [int]$PollSeconds = 5,
    [int]$StartupGraceSeconds = 60,
    [int]$PrelaunchGraceSeconds = 180,
    [int]$StartupPopupGraceSeconds = 25,
    [int]$PopupCooldownSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HeadroomMonitorProcessPathProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HeadroomMonitorProcessPathProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(
        IntPtr process,
        uint flags,
        StringBuilder executablePath,
        ref uint size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static string Read(int processId)
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)processId);
        if (handle == IntPtr.Zero) return String.Empty;
        try
        {
            uint size = 32768;
            var executablePath = new StringBuilder((int)size);
            return QueryFullProcessImageName(handle, 0, executablePath, ref size)
                ? executablePath.ToString()
                : String.Empty;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@
}

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path $script:ProjectRoot 'runtime' }
$script:RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$script:RuntimeStateRoot = Join-Path $script:RuntimeRoot 'state'
$script:RuntimeLogRoot = Join-Path $script:RuntimeRoot 'logs'
[IO.Directory]::CreateDirectory($script:RuntimeStateRoot) | Out-Null
[IO.Directory]::CreateDirectory($script:RuntimeLogRoot) | Out-Null

$script:GatewayBaseUrl = 'http://127.0.0.1:18787'
$script:HeadroomBaseUrl = 'http://127.0.0.1:18789'
$script:BrokerBaseUrl = 'http://127.0.0.1:18790'
$script:BaseUrl = $script:GatewayBaseUrl
$script:ProxyBaseUrl = "$($script:GatewayBaseUrl)/v1"
$script:RelayHost = '127.0.0.1'
$script:RelayPort = 57321
# Headroom's health endpoint can share the single local worker with a cold
# Kompress call. Keep monitor probes bounded without turning that contention
# into a false red gateway/route state.
$script:HttpTimeoutSeconds = 15
$script:TcpTimeoutMs = 1500
$script:CodexPlusPlusConfigPath = 'C:\Users\ma dao\.codex-plus-plus-cli\config.toml'
$script:CodexConfigPath = 'C:\Users\ma dao\.codex\config.toml'
$script:RouteStatePath = Join-Path $script:RuntimeStateRoot 'codexpp-route-state.json'
$script:RouteKeeperPath = Join-Path $PSScriptRoot 'codexpp-route-keeper.ps1'
$script:RouteReadySignalPath = Join-Path $script:RuntimeStateRoot 'codexpp-route-ready.signal'
$script:RouteSettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json'
$script:GatewayStatePath = Join-Path $script:RuntimeStateRoot 'gateway-metrics-state.json'
$script:ManagedCodexStatePath = Join-Path $script:RuntimeStateRoot 'managed-codex-processes.json'
$script:RouteStateMaxAgeSeconds = 90
$script:HeadroomMonitorMutexName = 'Local\CodexPlusPlusHeadroomMonitor'
$script:MonitorScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
$script:MonitorSourceSha256 = (Get-FileHash -LiteralPath $script:MonitorScriptPath -Algorithm SHA256).Hash.ToUpperInvariant()
$script:MonitorRoot = Split-Path -Parent $script:MonitorScriptPath
$script:TempRoot = $script:RuntimeLogRoot
$script:LogPath = Join-Path $script:RuntimeLogRoot 'codexpp-headroom-monitor.log'
$script:StatePath = Join-Path $script:RuntimeStateRoot 'codexpp-headroom-monitor-state.json'
$script:StatusStatePath = Join-Path $script:RuntimeStateRoot 'codexpp-headroom-monitor-status.json'
$script:StatusPort = 18788
$script:StatusListener = $null
$script:StatusListenerRestartCount = 0
$script:UnifiedStatus = $null
$script:PreviousActiveIssueCodes = @()
$script:RecentRecoveries = [System.Collections.Generic.List[object]]::new()
$script:StartTime = Get-Date
$script:LastFingerprint = $null
$script:LastRecoveryStatus = $null
$script:LastWarningFingerprint = $null
$script:LastWarningAt = $null
$script:LastPopupFingerprint = $null
$script:LastPopupAt = $null
$script:TrafficBaseline = $null
$script:HasSuccessfulModelRequest = $false
$script:HasUnrecoveredModelFailure = $false
$script:MonitorInstanceId = [Guid]::NewGuid().ToString('N')
$script:MonitorStartedAt = [DateTime]::UtcNow
$script:HasObservedOwner = $false
$script:PrelaunchGraceActive = $false
$script:CompressionQueueTimeoutBaseline = $null
$script:WatchMode = $Watch -or (-not $Once)

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { 'unknown' } else { [string]$Value }
    $text = $text -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)sk-[A-Za-z0-9_-]{8,}', '<redacted>'
    if ($text.Length -gt 240) {
        return $text.Substring(0, 237) + '...'
    }
    return $text
}

function Write-AtomicUtf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $temp = Join-Path $parent ('.codexpp-atomic-' + [IO.Path]::GetRandomFileName())
    $backup = $null
    try {
        [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = Join-Path $parent ('.codexpp-atomic-backup-' + [IO.Path]::GetRandomFileName())
            [IO.File]::Replace($temp, $Path, $backup, $true)
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Write-MonitorLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    try {
        $parent = Split-Path -Parent $script:LogPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent -Force)
        }
        $line = "$(Get-Date -Format o) [$Level] $(ConvertTo-SafeText $Message)`r`n"
        [IO.File]::AppendAllText($script:LogPath, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Logging must never stop the monitor.
    }
}

function ConvertTo-MonitorTrafficDocument {
    param([AllowNull()][object]$Traffic)
    if ($null -eq $Traffic) { return $null }
    return [ordered]@{
        available = [bool](Get-ObjectProperty -Object $Traffic -Name 'Available')
        traffic_known = [bool](Get-ObjectProperty -Object $Traffic -Name 'TrafficKnown')
        http_completed = (Get-ObjectProperty -Object $Traffic -Name 'HttpCompleted')
        successful_total = (Get-ObjectProperty -Object $Traffic -Name 'SuccessfulTotal')
        passthrough_models = (Get-ObjectProperty -Object $Traffic -Name 'PassthroughModels')
        failed_total = (Get-ObjectProperty -Object $Traffic -Name 'FailedTotal')
        ws_activity = (Get-ObjectProperty -Object $Traffic -Name 'WsActivity')
        ws_units = (Get-ObjectProperty -Object $Traffic -Name 'WsUnits')
        ws_frames = (Get-ObjectProperty -Object $Traffic -Name 'WsFrames')
        ws_modified = (Get-ObjectProperty -Object $Traffic -Name 'WsModified')
        frame_tokens_saved = (Get-ObjectProperty -Object $Traffic -Name 'FrameTokensSaved')
        inbound_model = (Get-ObjectProperty -Object $Traffic -Name 'InboundModel')
        inbound_http = (Get-ObjectProperty -Object $Traffic -Name 'InboundHttp')
        inbound_websocket = (Get-ObjectProperty -Object $Traffic -Name 'InboundWebSocket')
        inbound_probe = (Get-ObjectProperty -Object $Traffic -Name 'InboundProbe')
        inbound_total = (Get-ObjectProperty -Object $Traffic -Name 'InboundTotal')
        inbound_completed = (Get-ObjectProperty -Object $Traffic -Name 'InboundCompleted')
        inbound_active = (Get-ObjectProperty -Object $Traffic -Name 'InboundActive')
        has_pending_model_inbound = [bool](Get-ObjectProperty -Object $Traffic -Name 'HasPendingModelInbound')
        observation = (Get-ObjectProperty -Object $Traffic -Name 'Observation')
        path_observation = (Get-ObjectProperty -Object $Traffic -Name 'PathObservation')
        inbound_paths = @((Get-ObjectProperty -Object $Traffic -Name 'InboundPaths'))
    }
}

function ConvertTo-MonitorTrafficDeltaDocument {
    param([AllowNull()][object]$TrafficDelta)
    if ($null -eq $TrafficDelta) { return $null }
    return [ordered]@{
        http_completed = (Get-ObjectProperty -Object $TrafficDelta -Name 'HttpCompleted')
        inbound_model = (Get-ObjectProperty -Object $TrafficDelta -Name 'InboundModel')
        failed_total = (Get-ObjectProperty -Object $TrafficDelta -Name 'FailedTotal')
    }
}

function Write-MonitorState {
    param(
        [string]$Fingerprint,
        [string]$RecoveryStatus,
        [AllowNull()][object]$Traffic,
        [AllowNull()][object]$TrafficDelta,
        [AllowNull()][object]$UnifiedStatus
    )

    try {
        $state = [ordered]@{
            schema_version = 2
            monitor_instance_id = $script:MonitorInstanceId
            monitor_pid = [int]$PID
            monitor_script_path = $script:MonitorScriptPath
            monitor_source_sha256 = $script:MonitorSourceSha256
            runtime_root = $script:RuntimeRoot
            monitor_mode = if ($script:WatchMode) { 'watch' } else { 'once' }
            monitor_started_at = $script:MonitorStartedAt.ToString('o')
            timestamp = [DateTime]::UtcNow.ToString('o')
            fingerprint = (ConvertTo-SafeText $Fingerprint)
            recoveryStatus = (ConvertTo-SafeText $RecoveryStatus)
            traffic = (ConvertTo-MonitorTrafficDocument -Traffic $Traffic)
            traffic_delta = (ConvertTo-MonitorTrafficDeltaDocument -TrafficDelta $TrafficDelta)
        }
        $statusDocument = if ($null -ne $UnifiedStatus) { $UnifiedStatus } else { $script:UnifiedStatus }
        if ($null -ne $statusDocument) {
            foreach ($name in @('schema_version', 'generated_at', 'stale_after_seconds', 'overall', 'items', 'metrics', 'active_issues', 'recent_recoveries')) {
                $property = $statusDocument.PSObject.Properties[$name]
                if ($null -ne $property) { $state[$name] = $property.Value }
            }
        }
        $json = $state | ConvertTo-Json -Compress -Depth 8
        Write-AtomicUtf8Text -Path $script:StatePath -Content ($json + [Environment]::NewLine)
    }
    catch {
        Write-MonitorLog -Level WARN -Message 'Unable to write monitor state file.'
    }
}

function Read-MonitorState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        if ([int](Get-ObjectProperty -Object $state -Name 'schema_version') -ne 2) { return $null }
        $instanceId = [string](Get-ObjectProperty -Object $state -Name 'monitor_instance_id')
        if ([string]::IsNullOrWhiteSpace($instanceId) -or $instanceId -ne $script:MonitorInstanceId) { return $null }
        $timestamp = Get-ObjectProperty -Object $state -Name 'timestamp'
        $fingerprint = Get-ObjectProperty -Object $state -Name 'fingerprint'
        $status = Get-ObjectProperty -Object $state -Name 'recoveryStatus'
        if ($null -eq $timestamp -or $null -eq $fingerprint -or $null -eq $status) {
            return $null
        }
        $parsedTime = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$timestamp, [ref]$parsedTime)) {
            return $null
        }
        return [pscustomobject]@{
            MonitorInstanceId = $instanceId
            Timestamp = $parsedTime.ToUniversalTime()
            Fingerprint = [string]$fingerprint
            RecoveryStatus = [string]$status
            ActiveIssueCodes = @((Get-ObjectProperty -Object $state -Name 'active_issues') | ForEach-Object { [string](Get-ObjectProperty -Object $_ -Name 'code') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    catch {
        Write-MonitorLog -Level WARN -Message 'Monitor state file is invalid or unreadable.'
        return $null
    }
}

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-MonitorUtcDateTimeValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue)) { return $null }
    $parsed = [DateTime]::Parse($textValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $parsed.ToUniversalTime()
}

function Get-MonitorProcessExecutablePath {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object -First 1
        $cimPath = if ($null -eq $snapshot) { '' } else { [string]$snapshot.ExecutablePath }
        if (-not [string]::IsNullOrWhiteSpace($cimPath)) { return $cimPath }
    }
    catch { }
    try { return [string][HeadroomMonitorProcessPathProbe]::Read($ProcessId) } catch { return '' }
}

function Test-CommandLineParameter {
    param(
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedValue
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $namePattern = [regex]::Escape($Name)
    $valuePattern = [regex]::Escape($ExpectedValue)
    $pattern = '(?i)(?:^|\s)' + $namePattern + '\s+(?:"' + $valuePattern + '"|''' + $valuePattern + '''|' + $valuePattern + ')(?=\s|$)'
    return $CommandLine -match $pattern
}

function ConvertTo-StatsNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $null
    }
    [double]$number = 0
    if (-not [double]::TryParse(([string]$Value).Trim(), [ref]$number)) {
        return $null
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }
    return [Math]::Max([double]0, $number)
}

function ConvertTo-TokenStatsNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $null
    }

    [double]$number = 0
    if (-not [double]::TryParse(([string]$Value).Trim(), [ref]$number)) {
        return $null
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
        return $null
    }
    return $number
}

function Get-Sha256Hex {
    param([AllowNull()][string]$Value)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-CacheMetricBucket {
    return [ordered]@{
        requests = 0
        input_before = $null
        input_after = $null
        cache_read = $null
        cache_creation = $null
        output = $null
        latency_ms = $null
        cache_hit_ratio = $null
    }
}

function Add-CacheMetric {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bucket,
        [AllowNull()][object]$Metric
    )

    $Bucket.requests = [int]$Bucket.requests + 1
    if ($null -eq $Metric) { return }
    $fields = @{
        input_before = @('input_before', 'before', 'tok_before')
        input_after = @('input_after', 'after', 'tok_after')
        cache_read = @('cache_read', 'cache_read_tokens')
        cache_creation = @('cache_creation', 'cache_write', 'cache_write_tokens')
        output = @('output', 'tok_out', 'output_tokens')
        latency_ms = @('latency_ms', 'total_ms')
    }
    foreach ($target in $fields.Keys) {
        $value = $null
        foreach ($source in $fields[$target]) {
            $candidate = Get-ObjectProperty -Object $Metric -Name $source
            if ($null -ne ($number = ConvertTo-StatsNumber $candidate)) {
                $value = $number
                break
            }
        }
        if ($null -eq $value) { continue }
        if ($null -eq $Bucket[$target]) { $Bucket[$target] = 0 }
        $Bucket[$target] = [double]$Bucket[$target] + [double]$value
    }
    $ratio = ConvertTo-StatsNumber (Get-ObjectProperty -Object $Metric -Name 'cache_hit_ratio')
    if ($null -eq $ratio) { $ratio = ConvertTo-StatsNumber (Get-ObjectProperty -Object $Metric -Name 'cache_hit_pct') }
    if ($null -ne $ratio) {
        if ($null -eq $Bucket.cache_hit_ratio) { $Bucket.cache_hit_ratio = 0 }
        $Bucket.cache_hit_ratio = [double]$Bucket.cache_hit_ratio + [double]$ratio
    }
}

function Get-CacheMetricDocument {
    param([AllowNull()][object]$Metric)

    $bucket = New-CacheMetricBucket
    if ($null -ne $Metric) {
        Add-CacheMetric -Bucket $bucket -Metric $Metric
    }
    if ([int]$bucket.requests -gt 0 -and $null -ne $bucket.cache_hit_ratio) {
        $bucket.cache_hit_ratio = [Math]::Round(([double]$bucket.cache_hit_ratio / [double]$bucket.requests), 6)
    }
    elseif ([int]$bucket.requests -gt 0 -and $null -ne $bucket.input_before -and [double]$bucket.input_before -gt 0 -and $null -ne $bucket.cache_read) {
        $bucket.cache_hit_ratio = [Math]::Round(([double]$bucket.cache_read / [double]$bucket.input_before), 6)
    }
    return $bucket
}

function Get-GatewayCacheEffectiveness {
    $main = New-CacheMetricBucket
    $spawned = New-CacheMetricBucket
    $compress = New-CacheMetricBucket
    $bypass = New-CacheMetricBucket
    $result = [ordered]@{
        by_request_class = [ordered]@{ main = $main; spawned = $spawned }
        by_policy = [ordered]@{ compress = $compress; bypass = $bypass }
        confidence = 'unverifiable'
        reason_code = 'gateway_metrics_unavailable'
    }
    if (-not (Test-Path -LiteralPath $script:GatewayStatePath -PathType Leaf)) { return $result }
    try {
        $state = Get-Content -LiteralPath $script:GatewayStatePath -Raw -Encoding utf8 | ConvertFrom-Json
        $recent = @((Get-ObjectProperty -Object $state -Name 'recent'))
    }
    catch {
        $result.reason_code = 'gateway_metrics_invalid'
        return $result
    }
    if ($recent.Count -eq 0) {
        $result.reason_code = 'gateway_metrics_empty'
        return $result
    }
    $tokenEvidence = 0
    $cacheEvidence = 0
    foreach ($entry in $recent) {
        if ($null -eq $entry) { continue }
        $policy = ([string](Get-ObjectProperty -Object $entry -Name 'policy')).ToLowerInvariant()
        $requestClass = if ($policy -match 'spawn') { 'spawned' } else { 'main' }
        $policyClass = if ($policy -match 'bypass') { 'bypass' } else { 'compress' }
        $token = Get-ObjectProperty -Object $entry -Name 'token'
        $metric = if ($null -ne $token) { $token } else { $entry }
        $before = Get-ObjectProperty -Object $metric -Name 'before'
        $after = Get-ObjectProperty -Object $metric -Name 'after'
        if ($null -ne (ConvertTo-StatsNumber $before) -or $null -ne (ConvertTo-StatsNumber $after)) { $tokenEvidence++ }
        if ($null -ne (Get-ObjectProperty -Object $metric -Name 'cache_read') -or $null -ne (Get-ObjectProperty -Object $metric -Name 'cache_creation') -or $null -ne (Get-ObjectProperty -Object $metric -Name 'cache_write')) { $cacheEvidence++ }
        Add-CacheMetric -Bucket $result.by_request_class[$requestClass] -Metric ([pscustomobject]@{
                input_before = $before
                input_after = $after
                cache_read = Get-ObjectProperty -Object $metric -Name 'cache_read'
                cache_creation = if ($null -ne (Get-ObjectProperty -Object $metric -Name 'cache_creation')) { Get-ObjectProperty -Object $metric -Name 'cache_creation' } else { Get-ObjectProperty -Object $metric -Name 'cache_write' }
                output = Get-ObjectProperty -Object $metric -Name 'output'
                latency_ms = Get-ObjectProperty -Object $entry -Name 'latency_ms'
                cache_hit_ratio = Get-ObjectProperty -Object $metric -Name 'cache_hit_ratio'
            })
        Add-CacheMetric -Bucket $result.by_policy[$policyClass] -Metric ([pscustomobject]@{
                input_before = $before
                input_after = $after
                cache_read = Get-ObjectProperty -Object $metric -Name 'cache_read'
                cache_creation = if ($null -ne (Get-ObjectProperty -Object $metric -Name 'cache_creation')) { Get-ObjectProperty -Object $metric -Name 'cache_creation' } else { Get-ObjectProperty -Object $metric -Name 'cache_write' }
                output = Get-ObjectProperty -Object $metric -Name 'output'
                latency_ms = Get-ObjectProperty -Object $entry -Name 'latency_ms'
                cache_hit_ratio = Get-ObjectProperty -Object $metric -Name 'cache_hit_ratio'
            })
    }
    foreach ($bucket in @($result.by_request_class.main, $result.by_request_class.spawned, $result.by_policy.compress, $result.by_policy.bypass)) {
        if ([int]$bucket.requests -gt 0 -and $null -ne $bucket.cache_hit_ratio) {
            $bucket.cache_hit_ratio = [Math]::Round(([double]$bucket.cache_hit_ratio / [double]$bucket.requests), 6)
        }
        elseif ([int]$bucket.requests -gt 0 -and $null -ne $bucket.input_before -and [double]$bucket.input_before -gt 0 -and $null -ne $bucket.cache_read) {
            $bucket.cache_hit_ratio = [Math]::Round(([double]$bucket.cache_read / [double]$bucket.input_before), 6)
        }
    }
    if ($cacheEvidence -gt 0) {
        $result.confidence = 'verified'
        $result.reason_code = 'gateway_cache_metrics'
    }
    elseif ($tokenEvidence -gt 0) {
        $result.confidence = 'estimated'
        $result.reason_code = 'gateway_token_metrics_only'
    }
    else {
        $result.confidence = 'estimated'
        $result.reason_code = 'gateway_request_metrics_only'
    }
    return $result
}

function Get-StatsTrafficObservation {
    param([AllowNull()][object]$Body)

    $requests = Get-ObjectProperty $Body 'requests'
    $byModel = Get-ObjectProperty $requests 'by_model'
    # Headroom 0.32.1 increments requests.total only after a successful
    # completed request; failed requests are tracked separately.
    $successfulNonProbe = ConvertTo-StatsNumber (Get-ObjectProperty $requests 'total')
    $failedTotal = ConvertTo-StatsNumber (Get-ObjectProperty $requests 'failed')
    $passthrough = ConvertTo-StatsNumber (Get-ObjectProperty $byModel 'passthrough:models')
    $httpCompleted = $null
    if ($null -ne $successfulNonProbe -and $null -ne $passthrough) {
        $httpCompleted = [Math]::Max(0, $successfulNonProbe - $passthrough)
    }
    elseif ($null -ne $successfulNonProbe -and $successfulNonProbe -gt 0) {
        # passthrough:models key may be absent when no model-list probe has
        # occurred this process cycle. Use the total as an inferred lower
        # bound; the observation field notes this ambiguity.
        $httpCompleted = $successfulNonProbe
    }

    $codexWs = Get-ObjectProperty $Body 'codex_ws'
    $wsUnits = ConvertTo-StatsNumber (Get-ObjectProperty $codexWs 'units_total')
    $wsFrames = ConvertTo-StatsNumber (Get-ObjectProperty $codexWs 'frames_attempted_total')
    $wsModified = ConvertTo-StatsNumber (Get-ObjectProperty $codexWs 'units_modified_total')
    $frameTokensSaved = ConvertTo-StatsNumber (Get-ObjectProperty $codexWs 'frame_tokens_saved_sum')
    # WS compression units/frames are optimization activity, not completed
    # model requests. Keep them for display only; they never make API green.
    $wsActivity = 0

    $proxyInbound = Get-ObjectProperty $Body 'proxy_inbound'
    $byPath = Get-ObjectProperty $proxyInbound 'by_path'
    $hasInboundMetric = $null -ne $byPath
    [double]$inboundModel = 0
    [double]$inboundHttp = 0
    [double]$inboundWebSocket = 0
    [double]$inboundProbe = 0
    $pathDetails = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $byPath) {
        foreach ($pathProperty in @($byPath.PSObject.Properties)) {
            $path = ([string]$pathProperty.Name).Split('?')[0]
            $count = ConvertTo-StatsNumber $pathProperty.Value
            if ($null -eq $count) {
                continue
            }
            $isProbe = $path -match '(?i)^(?:/livez|/health|/stats|/debug/warmup|/readyz)(?:/|$)' -or $path -match '(?i)^/v1/models/?$'
            $isWebSocket = $path -match '(?i)(websocket|(^|[/_-])ws([/_-]|$)|socket)'
            $isModelPath = $path -match '(?i)^/v1/' -and -not $isProbe
            if ($isProbe) {
                $inboundProbe += $count
            }
            elseif ($isModelPath -or $isWebSocket) {
                $inboundModel += $count
                if ($isWebSocket) {
                    $inboundWebSocket += $count
                }
                else {
                    $inboundHttp += $count
                }
            }
            if ($pathDetails.Count -lt 12) {
                [void]$pathDetails.Add("$(ConvertTo-SafeText $path)=$count")
            }
        }
    }

    $inboundTotal = ConvertTo-StatsNumber (Get-ObjectProperty $proxyInbound 'total')
    $inboundCompleted = ConvertTo-StatsNumber (Get-ObjectProperty $proxyInbound 'completed')
    $inboundActive = ConvertTo-StatsNumber (Get-ObjectProperty $proxyInbound 'active')
    # `active` is a global inbound counter and may include /stats or other probes.
    # Without a model-scoped active metric it cannot prove a pending model request.
    $hasPendingModelInbound = $false

    $available = $null -ne $Body
    $trafficKnown = ($null -ne $httpCompleted -and $hasInboundMetric) -or
                    ($null -ne $successfulNonProbe -and $successfulNonProbe -gt 0 -and $hasInboundMetric)
    $httpText = if ($null -eq $httpCompleted) { 'unknown' } else { [string]$httpCompleted }
    $wsText = if ($null -eq $wsActivity) { 'unknown' } else { [string]$wsActivity }
    $observation = "HTTP=$httpText, WS=$wsText, inbound_model=$inboundModel"
    $pathObservation = if ($pathDetails.Count -gt 0) { [string]::Join(',', @($pathDetails)) } else { 'none' }
    return [pscustomobject]@{
        Available = $available
        HttpCompleted = $httpCompleted
        SuccessfulTotal = $successfulNonProbe
        FailedTotal = $failedTotal
        PassthroughModels = $passthrough
        WsActivity = $wsActivity
        WsUnits = $wsUnits
        WsFrames = $wsFrames
        WsModified = $wsModified
        FrameTokensSaved = $frameTokensSaved
        InboundModel = $inboundModel
        InboundHttp = $inboundHttp
        InboundWebSocket = $inboundWebSocket
        InboundProbe = $inboundProbe
        InboundTotal = $inboundTotal
        InboundCompleted = $inboundCompleted
        InboundActive = $inboundActive
        InboundPaths = @($pathDetails)
        HasPendingModelInbound = $hasPendingModelInbound
        TrafficKnown = $trafficKnown
        Observation = $observation
        PathObservation = $pathObservation
    }
}

function Get-LogWindowEvidence {
    param(
        [Parameter(Mandatory)][DateTime]$SinceUtc
    )

    $proxyLines = [System.Collections.Generic.List[string]]::new()
    $helperLines = [System.Collections.Generic.List[string]]::new()
    $readLogWindow = {
        param([string]$Path, [System.Collections.Generic.List[string]]$Target)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        try {
            foreach ($line in @(Get-Content -LiteralPath $Path -Tail 5000 -Encoding utf8 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
                $lineUtc = [DateTime]::MinValue
                $hasTimestamp = $false
                if ([string]$line -match '^(?<stamp>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:,|\.)\d+|\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
                    try {
                        $lineUtc = [DateTime]::Parse($Matches.stamp).ToUniversalTime()
                        $hasTimestamp = $true
                    }
                    catch { }
                }
                if (-not $hasTimestamp -and [string]$line -match '"timestamp_ms"\s*:\s*(?<epoch>\d{10,})') {
                    try {
                        $lineUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([Int64]$Matches.epoch).UtcDateTime
                        $hasTimestamp = $true
                    }
                    catch { }
                }
                if (-not $hasTimestamp -or $lineUtc -ge $SinceUtc) {
                    [void]$Target.Add([string]$line)
                }
            }
        }
        catch {
            # A missing or rotating log is evidence-limited, not a monitor failure.
        }
    }
    & $readLogWindow -Path (Join-Path $script:RuntimeLogRoot 'proxy.log') -Target $proxyLines
    & $readLogWindow -Path 'C:\Users\ma dao\.codex-session-delete\codex-plus.log' -Target $helperLines

    $allLines = @($proxyLines + $helperLines)
    $helper5xx = @($helperLines | Where-Object { $_ -match '(?i)helper\.[^\r\n]*(?:status["'']?\s*[:=]\s*["'']?5\d\d|HTTP/\d(?:\.\d)?\s+5\d\d|5\d\d\s*(?:Bad Gateway|Internal Server Error))' })
    $proxy5xx = @($proxyLines | Where-Object { $_ -match '(?i)(?:status=|status["'']?\s*[:=]\s*["'']?)5\d\d' })
    $wsFallback = @($proxyLines | Where-Object { $_ -match '(?i)WS upstream connect failed|websocket.*fallback|fallback.*websocket' })
    $framesFailed = @($allLines | Where-Object { $_ -match '(?i)frames_failed_total' })
    $wsClientErrors = @($allLines | Where-Object { $_ -match '(?i)ws:client_error|ws[_-]client[_-]error|client_error' })
    $compressionTimeout = @($allLines | Where-Object { $_ -match '(?i)Kompress execution saturated|compression.*(?:timeout|deadline)|compress.*(?:timeout|deadline)' })
    $compressionQuarantine = @($allLines | Where-Object { $_ -match '(?i)quarantin(?:e|ed|ing)' })
    $perfLines = @($proxyLines | Where-Object { $_ -match '(?i)\bPERF\b' })
    $helperSuccess = @($helperLines | Where-Object { $_ -match '(?i)helper\.[^\r\n]*(?:status["'']?\s*[:=]\s*["'']?2\d\d|protocol_proxy_stream_ok)' })
    $proxySuccess = @($proxyLines | Where-Object { $_ -match '(?i)(?:status=|status["'']?\s*[:=]\s*["'']?)2\d\d|WS upstream.*(?:connected|success|ok)' })
    $usageValues = @($proxyLines | ForEach-Object {
            if ($_ -match '(?i)\btok_before=(?<value>\d+(?:\.\d+)?)') {
                [double]$Matches.value
            }
        })
    $usage = $null
    if ($usageValues.Count -gt 0) { $usage = ($usageValues | Measure-Object -Maximum).Maximum }
    $perfBucket = New-CacheMetricBucket
    foreach ($line in $perfLines) {
        $metric = [ordered]@{}
        foreach ($name in @('tok_before', 'tok_after', 'cache_read', 'cache_write', 'tok_out', 'total_ms', 'cache_hit_pct')) {
            if ($line -match ('(?i)\b' + [regex]::Escape($name) + '=(?<value>\d+(?:\.\d+)?)')) {
                $metric[$name] = $Matches.value
            }
        }
        Add-CacheMetric -Bucket $perfBucket -Metric ([pscustomobject]$metric)
    }

    return [pscustomobject]@{
        ProxyLineCount = $proxyLines.Count
        HelperLineCount = $helperLines.Count
        Helper5xxCount = $helper5xx.Count
        Proxy5xxCount = $proxy5xx.Count
        WsFallbackCount = $wsFallback.Count
        FramesFailedCount = $framesFailed.Count
        WsClientErrorCount = $wsClientErrors.Count
        CompressionTimeoutCount = $compressionTimeout.Count
        CompressionQuarantineCount = $compressionQuarantine.Count
        HelperSuccessCount = $helperSuccess.Count
        ProxySuccessCount = $proxySuccess.Count
        UpstreamUsageTokens = $usage
        PerfCacheMetric = $perfBucket
        Helper5xxRecovered = $helper5xx.Count -gt 0 -and $helperSuccess.Count -gt 0
        WsFallbackRecovered = $wsFallback.Count -gt 0 -and $proxySuccess.Count -gt 0
        WsClientErrorRecovered = $wsClientErrors.Count -gt 0 -and $proxySuccess.Count -gt 0
        EvidenceAvailable = ($proxyLines.Count -gt 0 -or $helperLines.Count -gt 0)
    }
}

function ConvertTo-UnifiedState {
    param([AllowNull()][object]$State)
    switch ([string]$State) {
        { $_.ToLowerInvariant() -eq 'green' } { return 'green' }
        { $_.ToLowerInvariant() -eq 'red' } { return 'red' }
        { $_.ToLowerInvariant() -eq 'gray' } { return 'gray' }
        default { return 'yellow' }
    }
}

function Get-GatewayTokenAccounting {
    $result = [ordered]@{
        input_before = 0
        input_after = 0
        saved = 0
        savings_percent = 0
        completed_samples = 0
        missing_samples = 0
        invalid_samples = 0
        has_sample = $false
        exact = $false
    }
    if (-not (Test-Path -LiteralPath $script:GatewayStatePath -PathType Leaf)) { return $result }
    try {
        $state = Get-Content -LiteralPath $script:GatewayStatePath -Raw -Encoding utf8 | ConvertFrom-Json
        $recent = @((Get-ObjectProperty -Object $state -Name 'recent'))
    }
    catch {
        $result.invalid_samples = 1
        return $result
    }
    $aggregate = Get-ObjectProperty -Object $state -Name 'token_accounting'
    if ($null -ne $aggregate -and $null -ne (Get-ObjectProperty -Object $aggregate -Name 'completed_samples')) {
        $aggregateHasBefore = $null -ne $aggregate.PSObject.Properties['input_before'] -and $null -ne (Get-ObjectProperty -Object $aggregate -Name 'input_before')
        $aggregateHasAfter = $null -ne $aggregate.PSObject.Properties['input_after'] -and $null -ne (Get-ObjectProperty -Object $aggregate -Name 'input_after')
        $aggregateHasSaved = $null -ne $aggregate.PSObject.Properties['saved'] -and $null -ne (Get-ObjectProperty -Object $aggregate -Name 'saved')
        $aggregateValuesValid = $true
        foreach ($name in @('input_before', 'input_after', 'saved', 'completed_samples', 'missing_samples', 'invalid_samples')) {
            $rawValue = Get-ObjectProperty -Object $aggregate -Name $name
            $value = ConvertTo-TokenStatsNumber $rawValue
            if ($null -ne $rawValue -and $null -eq $value) {
                $aggregateValuesValid = $false
            }
            if ($null -ne $value) { $result[$name] = $value }
        }
        if ($result.completed_samples -gt 0 -and -not ($aggregateHasBefore -and $aggregateHasAfter -and $aggregateHasSaved)) {
            $result.missing_samples = [Math]::Max(1, [int]$result.missing_samples)
        }
        if (-not $aggregateValuesValid -or (
                $aggregateHasBefore -and $aggregateHasAfter -and $aggregateHasSaved -and
                ($result.input_after -gt $result.input_before -or $result.saved -ne ($result.input_before - $result.input_after))
            )) {
            $result.invalid_samples = [Math]::Max(1, [int]$result.invalid_samples)
        }
        if ($result.input_before -gt 0) {
            $result.savings_percent = [Math]::Round((100.0 * $result.saved / $result.input_before), 2)
        }
        $result.has_sample = $result.completed_samples -gt 0 -or $result.invalid_samples -gt 0
        $result.exact = $result.completed_samples -gt 0 -and $result.invalid_samples -eq 0 -and $result.missing_samples -eq 0
        return $result
    }
    foreach ($entry in $recent) {
        $token = Get-ObjectProperty -Object $entry -Name 'token'
        if ((Get-ObjectProperty -Object $entry -Name 'token_invalid') -eq $true) {
            $result.has_sample = $true
            $result.invalid_samples++
            continue
        }
        $before = ConvertTo-StatsNumber (Get-ObjectProperty -Object $token -Name 'before')
        $after = ConvertTo-StatsNumber (Get-ObjectProperty -Object $token -Name 'after')
        $saved = ConvertTo-StatsNumber (Get-ObjectProperty -Object $token -Name 'saved')
        if ($null -eq $before -or $null -eq $after -or $null -eq $saved) {
            $result.missing_samples++
            continue
        }
        $result.has_sample = $true
        if ($before -lt 0 -or $after -lt 0 -or $saved -lt 0 -or $after -gt $before -or $saved -ne ($before - $after)) {
            $result.invalid_samples++
            continue
        }
        $result.completed_samples++
        $result.input_before += [double]$before
        $result.input_after += [double]$after
        $result.saved += [double]$saved
    }
    if ($result.input_before -gt 0) {
        $result.savings_percent = [Math]::Round((100.0 * $result.saved / $result.input_before), 2)
    }
    $result.exact = $result.completed_samples -gt 0 -and $result.invalid_samples -eq 0 -and $result.missing_samples -eq 0
    return $result
}

function Get-CacheEffectivenessDocument {
    param([AllowNull()][object]$Logs)

    $gateway = Get-GatewayCacheEffectiveness
    if ([string]$gateway.confidence -ne 'unverifiable') {
        return $gateway
    }

    $main = New-CacheMetricBucket
    $spawned = New-CacheMetricBucket
    $compress = New-CacheMetricBucket
    $bypass = New-CacheMetricBucket
    $perf = if ($null -ne $Logs) { Get-ObjectProperty -Object $Logs -Name 'PerfCacheMetric' } else { $null }
    if ($null -ne $perf -and [int](Get-ObjectProperty -Object $perf -Name 'requests') -gt 0) {
        $main = $perf
        $compress = $perf
        return [ordered]@{
            by_request_class = [ordered]@{ main = $main; spawned = $spawned }
            by_policy = [ordered]@{ compress = $compress; bypass = $bypass }
            confidence = 'estimated'
            reason_code = 'proxy_perf_metrics_only'
        }
    }
    return [ordered]@{
        by_request_class = [ordered]@{ main = $main; spawned = $spawned }
        by_policy = [ordered]@{ compress = $compress; bypass = $bypass }
        confidence = 'unverifiable'
        reason_code = 'no_cache_metrics'
    }
}

function New-EmptyCacheEffectivenessDocument {
    $emptyMain = New-CacheMetricBucket
    $emptySpawned = New-CacheMetricBucket
    $emptyCompress = New-CacheMetricBucket
    $emptyBypass = New-CacheMetricBucket
    return [ordered]@{
        by_request_class = [ordered]@{ main = $emptyMain; spawned = $emptySpawned }
        by_policy = [ordered]@{ compress = $emptyCompress; bypass = $emptyBypass }
        confidence = 'unverifiable'
        reason_code = 'no_cache_metrics'
    }
}

function New-UnifiedItem {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$ObservedAt,
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][string]$IssueCode,
        [AllowNull()][string]$BypassDetail
    )
    $item = [ordered]@{
        key = $Key
        label = $Label
        state = (ConvertTo-UnifiedState $State)
        summary = (ConvertTo-SafeText $Summary)
        detail = (ConvertTo-SafeText $Detail)
        observed_at = $ObservedAt
        source = $Source
    }
    if (-not [string]::IsNullOrWhiteSpace($IssueCode)) { $item.issue_code = $IssueCode }
    if (-not [string]::IsNullOrWhiteSpace($BypassDetail)) { $item.bypass_detail = (ConvertTo-SafeText $BypassDetail) }
    return [pscustomobject]$item
}

function Get-UnifiedStatusFingerprint {
    param(
        [Parameter(Mandatory)][string]$Overall,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][object[]]$ActiveIssues
    )

    $itemParts = @($Items | ForEach-Object {
            $key = [string](Get-ObjectProperty -Object $_ -Name 'key')
            $state = [string](Get-ObjectProperty -Object $_ -Name 'state')
            "${key}=${state}"
        })
    $issueParts = @($ActiveIssues | ForEach-Object {
            $code = [string](Get-ObjectProperty -Object $_ -Name 'code')
            $key = [string](Get-ObjectProperty -Object $_ -Name 'item_key')
            $state = [string](Get-ObjectProperty -Object $_ -Name 'state')
            "${code}=${key}=${state}"
        } | Sort-Object -Unique)
    $canonical = "schema_version=2|overall=$Overall|items=$([string]::Join(',', $itemParts))|issues=$([string]::Join(',', $issueParts))"
    return Get-Sha256Hex -Value $canonical
}

function Get-UnifiedStatus {
    param([Parameter(Mandatory)][object]$Snapshot)

    $observedAt = [DateTime]::UtcNow.ToString('o')
    $items = [System.Collections.Generic.List[object]]::new()
    $issueCodes = [System.Collections.Generic.List[string]]::new()
    $addItem = {
        param([object]$Item)
        [void]$items.Add($Item)
        $code = [string](Get-ObjectProperty -Object $Item -Name 'issue_code')
        if (-not [string]::IsNullOrWhiteSpace($code)) { [void]$issueCodes.Add($code) }
    }

    $gatewayLivez = $Snapshot.GatewayLivez
    $gatewayLivezOk = $null -ne $gatewayLivez -and $gatewayLivez.TransportOk -and $gatewayLivez.StatusCode -eq 200 -and -not $gatewayLivez.ParseError -and $null -ne $gatewayLivez.Body -and (Get-ObjectProperty $gatewayLivez.Body 'service') -eq 'policy-gateway' -and (Get-ObjectProperty $gatewayLivez.Body 'status') -eq 'healthy' -and (Get-ObjectProperty $gatewayLivez.Body 'alive') -eq $true
    if ($gatewayLivezOk) {
        & $addItem (New-UnifiedItem 'gateway-livez' 'Gateway livez' 'green' '运行正常' 'Policy Gateway /livez healthy/alive' $observedAt 'gateway /livez')
    }
    else {
        & $addItem (New-UnifiedItem 'gateway-livez' 'Gateway livez' 'red' '不可用' 'Policy Gateway /livez 不可达、非 2xx 或响应不健康' $observedAt 'gateway /livez' 'gateway-livez.failed')
    }

    $gatewayHealth = $Snapshot.GatewayHealth
    $gatewayHealthBody = if ($null -ne $gatewayHealth) { $gatewayHealth.Body } else { $null }
    $gatewayHealthOk = $null -ne $gatewayHealth -and $gatewayHealth.TransportOk -and $gatewayHealth.StatusCode -eq 200 -and -not $gatewayHealth.ParseError -and $null -ne $gatewayHealthBody -and (Get-ObjectProperty $gatewayHealthBody 'service') -eq 'policy-gateway' -and (Get-ObjectProperty $gatewayHealthBody 'status') -eq 'healthy' -and (Get-ObjectProperty $gatewayHealthBody 'ready') -eq $true
    if ($gatewayHealthOk) {
        & $addItem (New-UnifiedItem 'gateway-health' 'Gateway health' 'green' '已就绪' 'Policy Gateway /health healthy/ready' $observedAt 'gateway /health')
    }
    else {
        & $addItem (New-UnifiedItem 'gateway-health' 'Gateway health' 'red' '未就绪' 'Policy Gateway /health 不可达、非 2xx 或未 ready' $observedAt 'gateway /health' 'gateway-health.failed')
    }

    $livez = $Snapshot.Livez
    $livezOk = $null -ne $livez -and $livez.TransportOk -and $livez.StatusCode -eq 200 -and -not $livez.ParseError -and $null -ne $livez.Body -and (Get-ObjectProperty $livez.Body 'service') -eq 'headroom-proxy' -and (Get-ObjectProperty $livez.Body 'status') -eq 'healthy' -and (Get-ObjectProperty $livez.Body 'alive') -eq $true
    if ($livezOk) {
    & $addItem (New-UnifiedItem 'headroom-livez' 'Headroom livez' 'green' '运行正常' 'Headroom /livez healthy/alive' $observedAt 'headroom /livez')
    }
    else {
        & $addItem (New-UnifiedItem 'headroom-livez' 'Headroom livez' 'red' '不可用' 'Headroom /livez 不可达、非 2xx 或响应不健康' $observedAt 'headroom /livez' 'headroom-livez.failed')
    }

    $health = $Snapshot.Health
    $healthBody = if ($null -ne $health) { $health.Body } else { $null }
    $healthOk = $null -ne $health -and $health.TransportOk -and $health.StatusCode -eq 200 -and -not $health.ParseError -and $null -ne $healthBody -and (Get-ObjectProperty $healthBody 'service') -eq 'headroom-proxy' -and (Get-ObjectProperty $healthBody 'status') -eq 'healthy' -and (Get-ObjectProperty $healthBody 'ready') -eq $true
    if ($healthOk) {
        & $addItem (New-UnifiedItem 'headroom-health' 'Headroom health' 'green' '已就绪' 'Headroom /health healthy/ready' $observedAt 'headroom /health')
    }
    else {
        & $addItem (New-UnifiedItem 'headroom-health' 'Headroom health' 'red' '未就绪' 'Headroom /health 不可达、非 2xx 或未 ready' $observedAt 'headroom /health' 'headroom-health.failed')
    }

    $relay = $Snapshot.Relay
    $relayConfig = Get-ObjectProperty (Get-ObjectProperty $healthBody 'config') 'openai_api_url'
    $relayOk = $null -ne $relay -and $relay.Ok -and (Test-RelayUrl $relayConfig)
    if ($relayOk) {
        & $addItem (New-UnifiedItem 'relay' 'Relay 57321' 'green' '连接正常' '本地 Relay TCP 可达且 Headroom 配置指向 57321' $observedAt 'relay TCP + /health config')
    }
    else {
        & $addItem (New-UnifiedItem 'relay' 'Relay 57321' 'red' '连接异常' 'Relay 不可达或 Headroom 未指向本地 Relay' $observedAt 'relay TCP + /health config' 'relay.failed')
    }

    $route = $Snapshot.Route
    $routeState = if ($null -ne $route) { ConvertTo-UnifiedState $route.State } else { 'yellow' }
    $routeIssue = if ($routeState -eq 'red') { 'route.failed' } elseif ($routeState -ne 'green') { 'route.unconfirmed' } else { $null }
    $routeSummary = if ($routeState -eq 'green') { '已确认' } elseif ($routeState -eq 'red') { '路由不匹配' } else { '证据不足' }
    $routeDetail = if ($null -ne $route) { [string]$route.Detail } else { '无法读取客户端路由状态' }
    $routeBypassWarning = $null -ne $route -and (Get-ObjectProperty -Object $route -Name 'BypassWarning') -eq $true
    $routeBypassDetail = if ($routeBypassWarning) { [string](Get-ObjectProperty -Object $route -Name 'BypassDetail') } else { $null }
    if ($routeBypassWarning -and [string]::IsNullOrWhiteSpace($routeBypassDetail)) {
        $routeBypassDetail = '旁路警告：存在未经过 Headroom 的客户端请求。'
    }
    if ($routeBypassWarning) {
        # Keep the warning in the primary detail field as well as the
        # structured bypass_detail extension so simple status consumers do
        # not silently hide an active direct client.
        $routeDetail = "$routeDetail；$routeBypassDetail"
    }
    & $addItem (New-UnifiedItem 'route' '客户端路由' $routeState $routeSummary $routeDetail $observedAt 'monitor route/config/process' $routeIssue $routeBypassDetail)

    $processes = $Snapshot.Processes
    $ownerCount = if ($null -ne $processes) { [int]$processes.OwnerCount } else { 0 }
    $activeCodexCount = if ($null -ne $processes) { @($processes.ActiveCodex).Count } else { 0 }
    $standardCount = if ($null -ne $processes) { @($processes.StandardCodex).Count } else { 0 }
    if ($standardCount -gt 0 -and $ownerCount -eq 0) {
        & $addItem (New-UnifiedItem 'codex-connection' 'Codex 连接' 'red' '检测到旁路进程' '存在未由 Codex++ 管理的标准 Codex 进程' $observedAt 'process snapshot' 'codex-connection.bypass')
    }
    elseif ($ownerCount -gt 0 -or $activeCodexCount -gt 0) {
        & $addItem (New-UnifiedItem 'codex-connection' 'Codex 连接' 'green' '客户端在线' ("检测到 {0} 个活动 Codex 进程" -f ($ownerCount + $activeCodexCount)) $observedAt 'process snapshot')
    }
    else {
        & $addItem (New-UnifiedItem 'codex-connection' 'Codex 连接' 'yellow' '等待客户端' '未检测到活动 Codex 客户端，无法验证真实模型流量' $observedAt 'process snapshot' 'codex-connection.idle')
    }

    $traffic = $Snapshot.Traffic
    $delta = $Snapshot.TrafficDelta
    if ($null -ne $delta) {
        if ($delta.FailedTotal -gt 0) { $script:HasUnrecoveredModelFailure = $true }
        if ($delta.HttpCompleted -gt 0) {
            $script:HasSuccessfulModelRequest = $true
            if ($delta.FailedTotal -le 0) { $script:HasUnrecoveredModelFailure = $false }
        }
    }
    if ($null -eq $delta) {
        & $addItem (New-UnifiedItem 'api' 'HTTP API' 'yellow' '等待基线' '当前监控尚无可比的完成请求增量' $observedAt 'headroom /stats + monitor baseline' 'api.evidence_pending')
    }
    elseif ($delta.FailedTotal -gt 0) {
        & $addItem (New-UnifiedItem 'api' 'HTTP API' 'red' '出现失败' ("当前监控窗口发现 {0} 个失败请求" -f $delta.FailedTotal) $observedAt 'headroom /stats' 'api.request_failed')
    }
    elseif ($delta.HttpCompleted -gt 0) {
        & $addItem (New-UnifiedItem 'api' 'HTTP API' 'green' '有完成请求' ("当前窗口完成 {0} 个 HTTP 请求" -f $delta.HttpCompleted) $observedAt 'headroom /stats')
    }
    elseif ($script:HasSuccessfulModelRequest -and -not $script:HasUnrecoveredModelFailure -and $delta.InboundModel -le 0) {
        & $addItem (New-UnifiedItem 'api' 'HTTP API' 'green' '当前周期空闲' '已有成功模型请求且当前周期没有进行中的模型请求' $observedAt 'headroom /stats')
    }
    else {
        & $addItem (New-UnifiedItem 'api' 'HTTP API' 'yellow' '等待完成' '观察到模型请求进入但尚未完成，保留进行中警告' $observedAt 'headroom /stats' 'api.pending_completion')
    }

    $logs = $Snapshot.LogEvidence
    $transportState = 'green'
    $transportSummary = '无当前窗口异常'
    $transportDetail = 'helper/proxy 当前监控窗口未发现 5xx、WS fallback 或 client_error'
    $transportIssue = $null
    if ($logs.Helper5xxCount -gt 0 -and -not $logs.Helper5xxRecovered) {
        $transportState = 'red'; $transportSummary = 'helper 失败'; $transportDetail = "当前窗口发现 $($logs.Helper5xxCount) 个 helper 5xx，且未观察到后续成功"; $transportIssue = 'transport.helper_5xx'
    }
    elseif ($logs.Helper5xxCount -gt 0 -or $logs.WsClientErrorCount -gt 0 -or $logs.WsFallbackCount -gt 0 -or $logs.FramesFailedCount -gt 0) {
        $transportState = 'yellow'; $transportSummary = '出现过异常'; $transportDetail = "窗口证据：helper5xx=$($logs.Helper5xxCount), ws_fallback=$($logs.WsFallbackCount), frames_failed_total=$($logs.FramesFailedCount), ws:client_error=$($logs.WsClientErrorCount)；恢复/最终结果需以上游证据确认"; $transportIssue = if ($logs.Helper5xxCount -gt 0) { 'transport.helper_5xx' } elseif ($logs.WsClientErrorCount -gt 0) { 'transport.ws_client_error' } elseif ($logs.WsFallbackCount -gt 0) { 'transport.ws_fallback' } else { 'transport.frames_failed_total' }
    }
    elseif (-not $logs.EvidenceAvailable) {
        $transportState = 'yellow'; $transportSummary = '证据不足'; $transportDetail = '当前日志不可读或尚无带时间戳样本，不能把缺失当作正常'; $transportIssue = 'transport.evidence_missing'
    }
    & $addItem (New-UnifiedItem 'transport' '传输与错误' $transportState $transportSummary $transportDetail $observedAt 'proxy.log + codex-plus.log' $transportIssue)

    $kompress = Get-ObjectProperty (Get-ObjectProperty $healthBody 'checks') 'kompress'
    $warmupKompress = Get-ObjectProperty $Snapshot.Warmup.Body 'kompress'
    $brokerBody = Get-ObjectProperty $Snapshot.BrokerHealth 'Body'
    $brokerCounters = Get-ObjectProperty $brokerBody 'counters'
    $brokerReady = $null -ne $brokerBody -and (Get-ObjectProperty $brokerBody 'ready') -eq $true -and [string](Get-ObjectProperty $brokerBody 'status') -eq 'healthy'
    $brokerProvider = [string](Get-ObjectProperty $brokerBody 'provider')
    $brokerBackend = [string](Get-ObjectProperty $brokerBody 'backend')
    $brokerCircuitOpen = (Get-ObjectProperty $brokerBody 'circuit_open') -eq $true
    $brokerQueueLimit = ConvertTo-StatsNumber (Get-ObjectProperty $brokerBody 'queue_limit')
    $brokerFallbackTotal = (ConvertTo-StatsNumber (Get-ObjectProperty $brokerCounters 'passthrough')) ?? 0
    $brokerTimeoutTotal = (ConvertTo-StatsNumber (Get-ObjectProperty $brokerCounters 'timeout')) ?? 0
    $brokerQueueFullTotal = (ConvertTo-StatsNumber (Get-ObjectProperty $brokerCounters 'queue_full')) ?? 0
    $brokerRestartTotal = (ConvertTo-StatsNumber (Get-ObjectProperty $brokerCounters 'worker_restart')) ?? 0
    $brokerDeviceRemovalTotal = (ConvertTo-StatsNumber (Get-ObjectProperty $brokerCounters 'device_removal')) ?? 0
    $sourceStatus = [string](Get-ObjectProperty (Get-ObjectProperty $kompress 'info') 'source_status')
    if ([string]::IsNullOrWhiteSpace($sourceStatus)) { $sourceStatus = [string](Get-ObjectProperty (Get-ObjectProperty $warmupKompress 'info') 'source_status') }
    if ([string]::IsNullOrWhiteSpace($sourceStatus) -and [string]$Snapshot.CompressionPolicy -eq 'disabled') { $sourceStatus = 'deferred' }
    $compressionExecutor = $Snapshot.CompressionExecutor
    $quarantineActive = $null -ne $compressionExecutor -and [bool]$compressionExecutor.QuarantineActive
    $timedOutWorkers = if ($null -ne $compressionExecutor) { ConvertTo-StatsNumber $compressionExecutor.TimedOutWorkers } else { $null }
    $queueTimeoutsTotal = if ($null -ne $compressionExecutor) { ConvertTo-StatsNumber $compressionExecutor.QueueTimeoutsTotal } else { $null }
    $queueTimeoutsIncreased = $null -ne $compressionExecutor -and [bool]$compressionExecutor.QueueTimeoutsIncreased
    $currentCompressionFailure = -not $brokerReady -or $brokerCircuitOpen -or $quarantineActive -or ($null -ne $timedOutWorkers -and $timedOutWorkers -gt 0)
    $compressionWindowWarning = $queueTimeoutsIncreased -or $logs.CompressionTimeoutCount -gt 0 -or $logs.CompressionQuarantineCount -gt 0 -or $brokerTimeoutTotal -gt 0 -or $brokerQueueFullTotal -gt 0 -or $brokerDeviceRemovalTotal -gt 0
    $kompressState = 'green'; $kompressSummary = '就绪'; $kompressDetail = "broker provider=$brokerProvider, backend=$brokerBackend, queue_limit=$brokerQueueLimit, fallback=$brokerFallbackTotal, worker_restart=$brokerRestartTotal"; $kompressIssue = $null
    if ([string]$Snapshot.CompressionPolicy -eq 'disabled' -and -not $currentCompressionFailure) {
        $kompressState = 'gray'; $kompressSummary = '按策略禁用'; $kompressDetail = 'Headroom 当前以 --no-optimize 运行；Kompress 不参与请求路径，其他代理转发仍可用'; $kompressIssue = $null
    }
    elseif ($currentCompressionFailure) {
        $kompressState = 'red'; $kompressSummary = '运行时隔离或超时'; $kompressDetail = "broker_ready=$brokerReady, circuit_open=$brokerCircuitOpen, provider=$brokerProvider, backend=$brokerBackend, quarantine_active=$quarantineActive, timed_out_workers=$timedOutWorkers, worker_restart=$brokerRestartTotal, device_removal=$brokerDeviceRemovalTotal"; $kompressIssue = 'kompress.runtime_failure'
    }
    elseif ($compressionWindowWarning) {
        $kompressState = 'yellow'; $kompressSummary = '发生过降级'; $kompressDetail = "queue_timeouts_total=$queueTimeoutsTotal, broker_timeout=$brokerTimeoutTotal, queue_full=$brokerQueueFullTotal, fallback=$brokerFallbackTotal, worker_restart=$brokerRestartTotal, device_removal=$brokerDeviceRemovalTotal"; $kompressIssue = 'kompress.deferred_or_timeout'
    }
    elseif ($sourceStatus -eq 'deferred') {
        $kompressState = 'red'; $kompressSummary = '状态错误'; $kompressDetail = 'Headroom 仍报告 deferred；严格启动链不接受该状态。'; $kompressIssue = 'kompress.runtime_failure'
    }
    elseif ($null -eq $kompress -or (Get-ObjectProperty $kompress 'ready') -ne $true -or [string](Get-ObjectProperty $kompress 'status') -eq 'unhealthy') {
        if ($currentCompressionFailure) {
            $kompressState = 'red'; $kompressSummary = '运行时故障'; $kompressDetail = 'Kompress 压缩执行器错误'; $kompressIssue = 'kompress.runtime_failure'
        } else {
            $kompressState = 'yellow'; $kompressSummary = '模型未载入'; $kompressDetail = 'Kompress 模型未就绪但已被 --no-optimize 禁用，代理可继续工作'; $kompressIssue = 'kompress.deferred_or_timeout'
        }
    }
    & $addItem (New-UnifiedItem 'kompress' 'Kompress' $kompressState $kompressSummary $kompressDetail $observedAt 'broker /health + Headroom health/warmup + proxy log' $kompressIssue)

    $token = Get-GatewayTokenAccounting
    $tokenState = 'yellow'; $tokenSummary = '等待精确计量'; $tokenIssue = 'token-accounting.incomplete'
    if ($token.invalid_samples -gt 0) {
        $tokenState = 'red'; $tokenSummary = '计量数据矛盾'; $tokenDetail = '发现负数、前后关系不合法或节省数不一致的精确计量样本'; $tokenIssue = 'token-accounting.invalid'
    }
    elseif ($token.exact -and $token.saved -gt 0) {
        $tokenState = 'green'; $tokenSummary = '精确计量有效'; $tokenDetail = "压缩前 Token=$($token.input_before)，压缩后 Token=$($token.input_after)，实际节省 Token=$($token.saved)，实际节省百分比=$($token.savings_percent)%"; $tokenIssue = $null
    }
    elseif ($token.exact) {
        $tokenSummary = '暂无实际节省'; $tokenDetail = "压缩前 Token=$($token.input_before)，压缩后 Token=$($token.input_after)，实际节省 Token=$($token.saved)，实际节省百分比=$($token.savings_percent)%"
    }
    else {
        $tokenDetail = "压缩前 Token=$($token.input_before)，压缩后 Token=$($token.input_after)，实际节省 Token=$($token.saved)，实际节省百分比=$($token.savings_percent)%; 完成精确计量的请求数=$($token.completed_samples)，缺少精确计量的请求数=$($token.missing_samples)"
    }
    & $addItem (New-UnifiedItem 'token-accounting' 'Token accounting' $tokenState $tokenSummary $tokenDetail $observedAt 'gateway exact token headers' $tokenIssue)

    $prelaunchActive = $script:WatchMode -and -not $script:HasObservedOwner -and (([DateTime]::UtcNow - $script:MonitorStartedAt).TotalSeconds -lt $PrelaunchGraceSeconds)
    $listenerState = if (Test-StatusListenerHealthy) { 'green' } elseif ($script:WatchMode) { 'red' } else { 'yellow' }
    $listenerSummary = if ($listenerState -eq 'green' -and $prelaunchActive) { '启动宽限期；统一接口已监听' } elseif ($listenerState -eq 'green') { '统一接口已监听' } elseif ($script:WatchMode) { '统一接口不可用' } else { '一次性模式' }
    $listenerDetail = if ($listenerState -eq 'green' -and $prelaunchActive) { "prelaunch grace active（剩余约 $([Math]::Max(0, [int]($PrelaunchGraceSeconds - ([DateTime]::UtcNow - $script:MonitorStartedAt).TotalSeconds))) 秒）；GET http://127.0.0.1:18788/status" } elseif ($listenerState -eq 'green') { 'GET http://127.0.0.1:18788/status' } else { 'monitor 尚未提供可读取的 /status listener' }
    $listenerIssue = if ($listenerState -eq 'red') { 'monitor-core.listener_unavailable' } else { $null }
    & $addItem (New-UnifiedItem 'monitor-core' 'Monitor core' $listenerState $listenerSummary $listenerDetail $observedAt 'codexpp-headroom-monitor.ps1' $listenerIssue)

    $activeCodes = @($issueCodes | Select-Object -Unique)
    $now = [DateTime]::UtcNow
    foreach ($recovered in @($script:PreviousActiveIssueCodes | Where-Object { $_ -notin $activeCodes })) {
        [void]$script:RecentRecoveries.Add([pscustomobject]@{ code = [string]$recovered; recovered_at = $observedAt })
    }
    while ($script:RecentRecoveries.Count -gt 20) { $script:RecentRecoveries.RemoveAt(0) }
    $script:PreviousActiveIssueCodes = @($activeCodes)

    $overall = if (@($items | Where-Object { $_.state -eq 'red' }).Count -gt 0) { 'red' } elseif (@($items | Where-Object { $_.state -eq 'yellow' }).Count -gt 0) { 'yellow' } else { 'green' }
    $activeIssues = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty -Object $_ -Name 'issue_code')) } | ForEach-Object {
            [ordered]@{ code = [string]$_.issue_code; item_key = [string]$_.key; state = [string]$_.state; summary = [string]$_.summary; detail = [string]$_.detail; observed_at = [string]$_.observed_at }
        })
    $statusFingerprint = Get-UnifiedStatusFingerprint -Overall $overall -Items @($items) -ActiveIssues @($activeIssues)
    $cacheEffectiveness = Get-CacheEffectivenessDocument -Logs $logs
    $metrics = [ordered]@{
        traffic = ConvertTo-MonitorTrafficDocument -Traffic $Snapshot.Traffic
        traffic_delta = ConvertTo-MonitorTrafficDeltaDocument -TrafficDelta $Snapshot.TrafficDelta
        log_evidence = [ordered]@{ helper_5xx = $logs.Helper5xxCount; proxy_5xx = $logs.Proxy5xxCount; ws_fallback = $logs.WsFallbackCount; frames_failed_total = $logs.FramesFailedCount; ws_client_error = $logs.WsClientErrorCount; compression_timeout = $logs.CompressionTimeoutCount; compression_quarantine = $logs.CompressionQuarantineCount }
        compression_executor = [ordered]@{ quarantine_active = $quarantineActive; timed_out_workers = $timedOutWorkers; queue_timeouts_total = $queueTimeoutsTotal; queue_timeouts_increased = $queueTimeoutsIncreased }
        kompress_broker = [ordered]@{ ready = $brokerReady; provider = $brokerProvider; backend = $brokerBackend; circuit_open = $brokerCircuitOpen; queue_limit = $brokerQueueLimit; fallback_total = $brokerFallbackTotal; timeout_total = $brokerTimeoutTotal; queue_full_total = $brokerQueueFullTotal; worker_restart_total = $brokerRestartTotal; device_removal_total = $brokerDeviceRemovalTotal }
        token_accounting = [ordered]@{ input_before = $token.input_before; input_after = $token.input_after; saved = $token.saved; savings_percent = $token.savings_percent; completed_samples = $token.completed_samples; missing_samples = $token.missing_samples; invalid_samples = $token.invalid_samples; exact = $token.exact }
        cache_effectiveness = $cacheEffectiveness
        status_fingerprint = $statusFingerprint
        process = [ordered]@{ owner_count = $ownerCount; active_codex_count = $activeCodexCount; standard_codex_count = $standardCount }
    }
    return [pscustomobject][ordered]@{
        schema_version = 2
        generated_at = $observedAt
        stale_after_seconds = 15
        monitor = [ordered]@{
            pid = [int]$PID
            instance_id = $script:MonitorInstanceId
            script_path = $script:MonitorScriptPath
            source_sha256 = $script:MonitorSourceSha256
            runtime_root = $script:RuntimeRoot
            started_at = $script:MonitorStartedAt.ToString('o')
            mode = if ($script:WatchMode) { 'watch' } else { 'once' }
        }
        overall = $overall
        items = @($items)
        metrics = $metrics
        active_issues = $activeIssues
        recent_recoveries = @($script:RecentRecoveries)
    }
}

function Get-UnifiedStatusFallback {
    param([switch]$Prelaunch)

    $now = [DateTime]::UtcNow.ToString('o')
    $keys = @(
        @{ Key = 'gateway-livez'; Label = 'Gateway livez' },
        @{ Key = 'gateway-health'; Label = 'Gateway health' },
        @{ Key = 'headroom-livez'; Label = 'Headroom livez' },
        @{ Key = 'headroom-health'; Label = 'Headroom health' },
        @{ Key = 'relay'; Label = 'Relay 57321' },
        @{ Key = 'route'; Label = '客户端路由' },
        @{ Key = 'codex-connection'; Label = 'Codex 连接' },
        @{ Key = 'api'; Label = 'HTTP API' },
        @{ Key = 'transport'; Label = '传输与错误' },
        @{ Key = 'kompress'; Label = 'Kompress' },
        @{ Key = 'token-accounting'; Label = 'Token accounting' },
        @{ Key = 'monitor-core'; Label = 'Monitor core' }
    )
    if ($Prelaunch) {
        $items = @($keys | ForEach-Object {
                if ($_.Key -eq 'monitor-core') {
                    New-UnifiedItem $_.Key $_.Label 'green' '启动宽限期' "monitor listener 已启动；等待有效 Codex++ owner（最多 $PrelaunchGraceSeconds 秒）" $now 'monitor /status'
                }
                else {
                    New-UnifiedItem $_.Key $_.Label 'yellow' '等待首轮采集' 'prelaunch grace active；尚无该项的实时证据' $now 'monitor /status' "$($_.Key).evidence_pending"
                }
            })
        $activeIssues = @([ordered]@{ code = 'monitor-core.prelaunch_grace'; item_key = 'monitor-core'; state = 'green'; summary = '启动宽限期'; detail = '等待有效 Codex++ owner'; observed_at = $now })
        $metrics = [ordered]@{ prelaunch_grace_active = $true; prelaunch_grace_seconds = $PrelaunchGraceSeconds; cache_effectiveness = New-EmptyCacheEffectivenessDocument }
        $metrics.status_fingerprint = Get-UnifiedStatusFingerprint -Overall 'yellow' -Items @($items) -ActiveIssues @($activeIssues)
        return [pscustomobject][ordered]@{
            schema_version = 2
            generated_at = $now
            stale_after_seconds = 15
            monitor = [ordered]@{
                pid = [int]$PID
                instance_id = $script:MonitorInstanceId
                script_path = $script:MonitorScriptPath
                source_sha256 = $script:MonitorSourceSha256
                runtime_root = $script:RuntimeRoot
                started_at = $script:MonitorStartedAt.ToString('o')
                mode = if ($script:WatchMode) { 'watch' } else { 'once' }
            }
            overall = 'yellow'
            items = $items
            metrics = $metrics
            active_issues = $activeIssues
            recent_recoveries = @()
        }
    }
    $items = @($keys | ForEach-Object { New-UnifiedItem $_.Key $_.Label 'red' '统一监控尚未就绪' '等待 monitor 完成首轮采集；此响应仅用于明确不可用状态' $now 'monitor /status' 'monitor-core.unavailable' })
    $activeIssues = @([ordered]@{ code = 'monitor-core.unavailable'; item_key = 'monitor-core'; state = 'red'; summary = '统一监控尚未就绪'; detail = 'monitor 尚未完成首轮采集'; observed_at = $now })
    $metrics = [ordered]@{ cache_effectiveness = New-EmptyCacheEffectivenessDocument }
    $metrics.status_fingerprint = Get-UnifiedStatusFingerprint -Overall 'red' -Items @($items) -ActiveIssues @($activeIssues)
    return [pscustomobject][ordered]@{
        schema_version = 2
        generated_at = $now
        stale_after_seconds = 15
        monitor = [ordered]@{
            pid = [int]$PID
            instance_id = $script:MonitorInstanceId
            script_path = $script:MonitorScriptPath
            source_sha256 = $script:MonitorSourceSha256
            runtime_root = $script:RuntimeRoot
            started_at = $script:MonitorStartedAt.ToString('o')
            mode = if ($script:WatchMode) { 'watch' } else { 'once' }
        }
        overall = 'red'
        items = $items
        metrics = $metrics
        active_issues = $activeIssues
        recent_recoveries = @()
    }
}





function Test-StatusListenerHealthy {
    return $null -ne $script:StatusListener -and $script:StatusListener.State -eq 'Running'
}

function Write-StatusDocument {
    param([Parameter(Mandatory)][object]$Document)

    try {
        $json = $Document | ConvertTo-Json -Compress -Depth 12
        Write-AtomicUtf8Text -Path $script:StatusStatePath -Content $json
        return $true
    }
    catch {
        Write-MonitorLog -Level WARN -Message 'Unable to publish unified status document.'
        return $false
    }
}

function Start-StatusListener {
    if (Test-StatusListenerHealthy) { return }
    if ($null -ne $script:StatusListener) {
        try { Stop-Job -Job $script:StatusListener -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $script:StatusListener -Force -ErrorAction SilentlyContinue } catch { }
        $script:StatusListener = $null
    }
    try {
        if ($null -eq $script:UnifiedStatus) {
            $script:UnifiedStatus = Get-UnifiedStatusFallback -Prelaunch:($script:WatchMode -and -not $script:HasObservedOwner)
            [void](Write-StatusDocument -Document $script:UnifiedStatus)
        }
        if ($null -eq (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
            throw 'Start-ThreadJob is unavailable.'
        }
        $listenerScript = {
            param([int]$Port, [string]$DocumentPath)

            $listener = [Net.HttpListener]::new()
            try {
                [void]$listener.Prefixes.Add("http://127.0.0.1:$Port/")
                $listener.Start()
                $contextTask = $null
                while ($true) {
                    if ($null -eq $contextTask) {
                        $contextTask = $listener.GetContextAsync()
                    }
                    if (-not $contextTask.Wait(250)) {
                        continue
                    }
                    $context = $contextTask.GetAwaiter().GetResult()
                    $contextTask = $null
                    $path = $context.Request.Url.AbsolutePath.TrimEnd('/')
                    $method = [string]$context.Request.HttpMethod
                    $status = 200
                    $document = $null
                    $isStatusPath = $path -eq '/status'
                    $isPreflight = $method -eq 'OPTIONS' -and $isStatusPath
                    if ($isPreflight) {
                        $status = 204
                    }
                    elseif ($method -ne 'GET') {
                        $status = 405
                    }
                    elseif (-not $isStatusPath) {
                        $status = 404
                    }
                    else {
                        try {
                            if (Test-Path -LiteralPath $DocumentPath -PathType Leaf) {
                                $document = Get-Content -LiteralPath $DocumentPath -Raw | ConvertFrom-Json
                            }
                        }
                        catch {
                            $document = $null
                        }
                        if ($null -eq $document) { $status = 503 }
                    }

                    try {
                        $response = $context.Response
                        $response.Headers['Access-Control-Allow-Origin'] = '*'
                        $response.Headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
                        $response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
                        $response.StatusCode = $status
                        if ($isPreflight) {
                            $response.ContentLength64 = 0
                        }
                        elseif ($null -ne $document) {
                            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($document | ConvertTo-Json -Compress -Depth 12))
                            $response.ContentType = 'application/json; charset=utf-8'
                            $response.ContentLength64 = $bytes.Length
                            $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        else {
                            $response.ContentLength64 = 0
                        }
                    }
                    finally {
                        try { $context.Response.OutputStream.Close() } catch { }
                    }
                }
            }
            finally {
                try { $listener.Stop() } catch { }
                try { $listener.Close() } catch { }
            }
        }
        $script:StatusListener = Start-ThreadJob -ScriptBlock $listenerScript -ArgumentList $script:StatusPort, $script:StatusStatePath
        Start-Sleep -Milliseconds 75
        if (-not (Test-StatusListenerHealthy)) {
            throw 'Unified status listener job did not remain running.'
        }
        Write-MonitorLog -Level INFO -Message "Unified status listener thread job started on 127.0.0.1:$($script:StatusPort)."
    }
    catch {
        Write-MonitorLog -Level ERROR -Message 'Unable to start unified status listener thread job.'
        if ($null -ne $script:StatusListener) {
            try { Stop-Job -Job $script:StatusListener -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $script:StatusListener -Force -ErrorAction SilentlyContinue } catch { }
        }
        $script:StatusListener = $null
    }
}

function Stop-StatusListener {
    if ($null -eq $script:StatusListener) { return }
    try { Stop-Job -Job $script:StatusListener -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job -Job $script:StatusListener -Force -ErrorAction SilentlyContinue } catch { }
    $script:StatusListener = $null
}

function Pump-StatusListener {
    if (Test-StatusListenerHealthy) { return }
    if ($script:StatusListenerRestartCount -ge 2) { return }
    $script:StatusListenerRestartCount++
    Start-StatusListener
}

function Add-MonitorIssue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    [void]$List.Add([pscustomobject]@{
            Code = $Code
            Message = $Message
        })
}

function Add-MonitorWarning {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    [void]$List.Add([pscustomobject]@{
            Code = $Code
            Message = $Message
        })
}

function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Uri)

    $statusCode = 0
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec $script:HttpTimeoutSeconds
        $statusCode = [int]$response.StatusCode
        $body = $null
        $parseError = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            try {
                $body = $response.Content | ConvertFrom-Json
            }
            catch {
                $parseError = $true
            }
        }
        return [pscustomobject]@{
            TransportOk = $true
            StatusCode = $statusCode
            Body = $body
            ParseError = $parseError
        }
    }
    catch {
        return [pscustomobject]@{
            TransportOk = $false
            StatusCode = $statusCode
            Body = $null
            ParseError = $false
        }
    }
}

function Test-HeadroomBaseUrl {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    try {
        $uri = [Uri]([string]$Value)
        $hostName = $uri.Host.ToLowerInvariant()
        $hostIsLocal = $hostName -in @('127.0.0.1', 'localhost', '::1')
        $path = $uri.AbsolutePath.TrimEnd('/')
        return ($uri.Scheme -eq 'http' -and $hostIsLocal -and $uri.Port -eq 18787 -and $path -eq '/v1' -and [string]::IsNullOrWhiteSpace($uri.Query) -and [string]::IsNullOrWhiteSpace($uri.Fragment))
    }
    catch {
        return $false
    }
}

function Test-RelayUrl {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    try {
        $uri = [Uri]([string]$Value)
        $expectedRelay = 'http://' + $script:RelayHost + ':' + $script:RelayPort
        return ($uri.AbsoluteUri.TrimEnd('/') -eq $expectedRelay)
    }
    catch {
        return $false
    }
}

function ConvertTo-RouteLabel {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'unknown'
    }
    try {
        $uri = [Uri]([string]$Value)
        $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
        $path = $uri.AbsolutePath.TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = ''
        }
        return ("{0}://{1}{2}{3}" -f $uri.Scheme.ToLowerInvariant(), $uri.Host.ToLowerInvariant(), $port, $path)
    }
    catch {
        return 'invalid endpoint'
    }
}

function Get-CodexConfigSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            BaseUrl = $null
            IsLocalHeadroom = $false
            Error = 'config_missing'
        }
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw
        $provider = 'CodexPlusPlus'
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        if ($providerMatch.Success) {
            $provider = if ($providerMatch.Groups['double'].Success) { $providerMatch.Groups['double'].Value } else { $providerMatch.Groups['single'].Value }
        }
        $sectionPattern = '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)'
        $sectionMatch = [regex]::Match($content, $sectionPattern)
        if (-not $sectionMatch.Success) {
            return [pscustomobject]@{
                Exists = $true
                BaseUrl = $null
                IsLocalHeadroom = $false
                Error = 'provider_section_missing'
            }
        }

        $section = $sectionMatch.Groups['section'].Value
        $baseMatch = [regex]::Match($section, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        if (-not $baseMatch.Success) {
            return [pscustomobject]@{
                Exists = $true
                BaseUrl = $null
                IsLocalHeadroom = $false
                Error = 'base_url_missing'
            }
        }

        $url = if ($baseMatch.Groups['double'].Success) {
            $baseMatch.Groups['double'].Value
        }
        else {
            $baseMatch.Groups['single'].Value
        }
        return [pscustomobject]@{
            Exists = $true
            BaseUrl = $url
            IsLocalHeadroom = (Test-HeadroomBaseUrl -Value $url)
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $true
            BaseUrl = $null
            IsLocalHeadroom = $false
            Error = 'config_read_error'
        }
    }
}

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )

    $client = $null
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($script:TcpTimeoutMs)) {
            return [pscustomobject]@{ Ok = $false; Error = 'timeout' }
        }
        return [pscustomobject]@{ Ok = $client.Connected; Error = if ($client.Connected) { $null } else { 'not_connected' } }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Error = 'connect_error' }
    }
    finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Get-ProcessMetadataSafe {
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        $item = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        return [pscustomobject]@{
            ParentProcessId = [int]$item.ParentProcessId
            ExecutablePath = [string]$item.ExecutablePath
            CommandLine = [string]$item.CommandLine
        }
    }
    catch {
        return $null
    }
}

function Test-HeadroomOptimizationDisabled {
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
                ([string]$_.Name -ieq 'headroom.exe') -or ([string]$_.CommandLine -match '(?i)headroom.*\bproxy\b')
            })
        foreach ($process in $processes) {
            if ([string]$process.CommandLine -match '(?i)(?:^|\s)--no-optimize(?:\s|$)') {
                return $true
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Get-ProcessSnapshot {
    $result = [ordered]@{
        CodexPlusPlus = @()
        Manager = @()
        Codex = @()
        Errors = @()
    }
    $nameMap = @{
        CodexPlusPlus = 'codex-plus-plus'
        Manager = 'codex-plus-plus-manager'
        Codex = 'codex'
    }

    foreach ($key in $nameMap.Keys) {
        try {
            $result[$key] = @(Get-Process -Name $nameMap[$key] -ErrorAction SilentlyContinue)
        }
        catch {
            $result.Errors += $key
        }
    }

    [int]$commandLineReadableCount = 0
    [int]$commandLineErrorCount = 0
    [int]$parentProcessReadableCount = 0
    [int]$parentProcessErrorCount = 0
    $parentProcessIds = @{}
    $processPaths = @{}
    foreach ($key in @('CodexPlusPlus', 'Manager', 'Codex')) {
        foreach ($process in @($result[$key])) {
            $processId = [int]$process.Id
            $metadata = Get-ProcessMetadataSafe -ProcessId $processId
            if ($null -eq $metadata) {
                $commandLineErrorCount++
                $parentProcessErrorCount++
                continue
            }
            $parentProcessIds[[string]$processId] = [int]$metadata.ParentProcessId
            $parentProcessReadableCount++
            $processPaths[[string]$processId] = [string]$metadata.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($metadata.CommandLine)) {
                $commandLineErrorCount++
            }
            else {
                $commandLineReadableCount++
            }
        }
    }

    $standardCodex = @($result.Codex | Where-Object {
            try {
                $path = [string]$_.Path
                if ([string]::IsNullOrWhiteSpace($path)) {
                    return $false
                }
                return ($path -notmatch '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\resources\\codex\.exe$')
            }
            catch {
                return $false
            }
        })
    $officialCodex = @($result.Codex | Where-Object {
            try {
                $path = [string]$_.Path
                if ([string]::IsNullOrWhiteSpace($path) -and $processPaths.ContainsKey([string]$_.Id)) {
                    $path = [string]$processPaths[[string]$_.Id]
                }
                return ($path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\resources\\codex\.exe$')
            }
            catch {
                return $false
            }
        })

    $cppProcessIds = @($result.CodexPlusPlus + $result.Manager | ForEach-Object { [int]$_.Id })
    $independentCodex = @($result.Codex | Where-Object {
            $processId = [string]$_.Id
            if (-not $parentProcessIds.ContainsKey($processId)) {
                return $false
            }
            return ([int]$parentProcessIds[$processId] -notin $cppProcessIds)
        })
    $independentOfficialCodex = @($officialCodex | Where-Object {
            $processId = [string]$_.Id
            if (-not $parentProcessIds.ContainsKey($processId)) {
                return $false
            }
            return ([int]$parentProcessIds[$processId] -notin $cppProcessIds)
        })

    return [pscustomobject]@{
        CodexPlusPlus = @($result.CodexPlusPlus)
        Manager = @($result.Manager)
        Codex = @($result.Codex)
        ActiveCodex = @($result.Codex)
        OfficialCodex = $officialCodex
        IndependentCodex = $independentCodex
        IndependentOfficialCodex = $independentOfficialCodex
        ParentProcessIds = $parentProcessIds
        ProcessPaths = $processPaths
        StandardCodex = $standardCodex
        CommandLineReadableCount = $commandLineReadableCount
        CommandLineErrorCount = $commandLineErrorCount
        ParentProcessReadableCount = $parentProcessReadableCount
        ParentProcessErrorCount = $parentProcessErrorCount
        Errors = @($result.Errors)
        OwnerCount = @($result.CodexPlusPlus).Count + @($result.Manager).Count
    }
}

function Get-LegacyClientRouteObservation {
    param(
        [Parameter(Mandatory)][object]$CodexPlusPlusConfig,
        [Parameter(Mandatory)][object]$CodexConfig,
        [Parameter(Mandatory)][object]$Processes
    )

    $codexPlusPlusProcessCount = @($Processes.CodexPlusPlus).Count
    $managerProcessCount = @($Processes.Manager).Count
    $independentCodexProcessCount = @($Processes.IndependentCodex).Count
    $independentOfficialProcessCount = @($Processes.IndependentOfficialCodex).Count
    $cppConfigLocal = [bool]$CodexPlusPlusConfig.IsLocalHeadroom
    $codexConfigLocal = [bool]$CodexConfig.IsLocalHeadroom

    # Codex++ uses its own CODEX_HOME and therefore has an independent route
    # contract from the official `.codex` startup-gate/route-keeper state.
    # When that dedicated config and client are both active, a stale official
    # route-state must not turn a working Codex++ route red. The main snapshot
    # still validates Gateway/Headroom health separately.
    $dedicatedRouteActive = $cppConfigLocal -and $codexPlusPlusProcessCount -gt 0
    $dedicatedIndependentRemote = $independentCodexProcessCount -gt 0 -and $CodexConfig.Exists -and -not $codexConfigLocal
    $dedicatedBypassDetail = if ($dedicatedIndependentRemote) {
        ("旁路：检测到 {0} 个独立 Codex 进程使用非本地 base_url {1}；其请求不会经过 Headroom" -f $independentCodexProcessCount, (ConvertTo-RouteLabel $CodexConfig.BaseUrl))
    }
    else {
        $null
    }
    if ($dedicatedRouteActive) {
        return [pscustomobject]@{
            State = 'Green'
            RouteMismatch = $false
            RouteContractValid = $true
            RouteStateApplicable = $false
            CppReady = $true
            ActiveClient = $true
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $dedicatedIndependentRemote
            BypassDetail = $dedicatedBypassDetail
            Detail = ("Codex++ 专用配置已指向本地 Headroom，Codex++ 进程已运行（{0} 个）；官方 route-state 不适用于该专用 CODEX_HOME" -f $codexPlusPlusProcessCount)
        }
    }
    $routeState = $null
    if (Test-Path -LiteralPath $script:RouteStatePath -PathType Leaf) {
        try { $routeState = Get-Content -LiteralPath $script:RouteStatePath -Raw | ConvertFrom-Json } catch { $routeState = $null }
    }
    $routeStateFresh = $false
    $routeStateHashMatches = $false
    $routeStateKeeperValid = $false
    if ($null -ne $routeState) {
        try { $tsRaw = (Get-ObjectProperty -Object $routeState -Name 'timestamp_utc'); $tsVal = [DateTime]::MinValue; if ($null -ne $tsRaw) { $tsVal = [DateTime]$tsRaw; if ($tsVal.Kind -eq [DateTimeKind]::Local) { $tsVal = $tsVal.ToUniversalTime() } elseif ($tsVal.Kind -eq [DateTimeKind]::Unspecified) { $tsVal = [DateTime]::SpecifyKind($tsVal, [DateTimeKind]::Utc) } }; $routeStateFresh = ($tsVal -gt [DateTime]::UtcNow.AddSeconds(-$script:RouteStateMaxAgeSeconds)) -and ($tsVal -le [DateTime]::UtcNow.AddSeconds(5)) } catch { $routeStateFresh = $false }
        if (Test-Path -LiteralPath $script:CodexConfigPath -PathType Leaf) {
            try { $routeStateHashMatches = [string](Get-ObjectProperty -Object $routeState -Name 'config_sha256') -eq (Get-FileHash -LiteralPath $script:CodexConfigPath -Algorithm SHA256).Hash } catch { $routeStateHashMatches = $false }
        }
        try {
            $keeperPid = ConvertTo-StatsNumber (Get-ObjectProperty -Object $routeState -Name 'route_keeper_pid')
            $keeperStartedAt = [DateTime]::MinValue
            $keeperPath = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_script_path')
            $keeperMode = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_mode')
            $keeperConfigPath = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_config_path')
            $keeperSettingsPath = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_settings_path')
            $keeperSignalPath = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_ready_signal_path')
            $keeperProxyBaseUrl = [string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_proxy_base_url')
            $keeperStateValid = $null -ne $keeperPid -and [Math]::Floor($keeperPid) -eq $keeperPid -and [DateTime]::TryParse([string](Get-ObjectProperty -Object $routeState -Name 'route_keeper_started_at'), [ref]$keeperStartedAt)
            if ($keeperStateValid) { $keeperStartedAt = $keeperStartedAt.ToUniversalTime() }
            $keeperProcess = if ($keeperStateValid) { Get-Process -Id ([int]$keeperPid) -ErrorAction SilentlyContinue } else { $null }
            $keeperInfo = if ($keeperStateValid) { Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$keeperPid)" -ErrorAction SilentlyContinue } else { $null }
            $keeperCommand = if ($keeperInfo) { [string]$keeperInfo.CommandLine } else { '' }
            $officialState = [string](Get-ObjectProperty -Object $routeState -Name 'status') -eq 'official-bypass'
            $routeStateKeeperValid = if ($officialState) {
                $keeperStateValid -and $keeperProxyBaseUrl -eq $script:ProxyBaseUrl -and $keeperStartedAt -le [DateTime]::UtcNow.AddSeconds(5) -and $keeperPath.Equals($script:RouteKeeperPath, [StringComparison]::OrdinalIgnoreCase) -and $keeperMode -eq 'once' -and $keeperConfigPath -eq $script:CodexConfigPath -and $keeperSettingsPath -eq $script:RouteSettingsPath -and $keeperSignalPath -eq $script:RouteReadySignalPath
            }
            else {
                $keeperStateValid -and $keeperProxyBaseUrl -eq $script:ProxyBaseUrl -and $keeperStartedAt -le [DateTime]::UtcNow.AddSeconds(5) -and $keeperPath.Equals($script:RouteKeeperPath, [StringComparison]::OrdinalIgnoreCase) -and $keeperMode -eq 'watch' -and $keeperConfigPath -eq $script:CodexConfigPath -and $keeperSettingsPath -eq $script:RouteSettingsPath -and $keeperSignalPath -eq $script:RouteReadySignalPath -and $null -ne $keeperProcess -and [Math]::Abs(($keeperProcess.StartTime.ToUniversalTime() - $keeperStartedAt).TotalSeconds) -le 30 -and $keeperCommand -match ('(?i)' + [regex]::Escape($script:RouteKeeperPath)) -and $keeperCommand -match '(?i)(^|\s)-Watch(\s|$)' -and (Test-CommandLineParameter -CommandLine $keeperCommand -Name '-Mode' -ExpectedValue 'proxy') -and (Test-CommandLineParameter -CommandLine $keeperCommand -Name '-ConfigPath' -ExpectedValue $script:CodexConfigPath) -and (Test-CommandLineParameter -CommandLine $keeperCommand -Name '-SettingsPath' -ExpectedValue $script:RouteSettingsPath) -and (Test-CommandLineParameter -CommandLine $keeperCommand -Name '-ProxyBaseUrl' -ExpectedValue $script:ProxyBaseUrl) -and (Test-CommandLineParameter -CommandLine $keeperCommand -Name '-ReadySignalPath' -ExpectedValue $script:RouteReadySignalPath)
            }
        }
        catch { $routeStateKeeperValid = $false }
    }
    $routeStateStatus = if ($null -ne $routeState) { [string](Get-ObjectProperty -Object $routeState -Name 'status') } else { '' }
    $routeSchemaVersion = ConvertTo-StatsNumber (Get-ObjectProperty -Object $routeState -Name 'schema_version')
    $routeContractVersion = ConvertTo-StatsNumber (Get-ObjectProperty -Object $routeState -Name 'route_contract_version')
    $routeMode = [string](Get-ObjectProperty -Object $routeState -Name 'mode')
    $routeHttpMode = [string](Get-ObjectProperty -Object $routeState -Name 'http_mode')
    $routeWireApi = [string](Get-ObjectProperty -Object $routeState -Name 'wire_api')
    $routeSupportsWebSockets = Get-ObjectProperty -Object $routeState -Name 'supports_websockets'
    $proxyRouteMode = $routeMode -in @('pureapi', 'mixedapi', 'aggregate')
    $officialRouteMode = $routeMode -eq 'official'
    $routeContractValid = $null -ne $routeState -and $routeSchemaVersion -eq 2 -and $routeContractVersion -eq 2 -and $routeWireApi -eq 'responses' -and (($proxyRouteMode -and $routeHttpMode -eq 'responses' -and $routeSupportsWebSockets -eq $false) -or ($officialRouteMode -and $routeHttpMode -eq 'direct' -and $null -eq $routeSupportsWebSockets))
    if (-not $routeContractValid) {
        return [pscustomobject]@{
            State = 'Red'
            RouteMismatch = $true
            RouteContractValid = $false
            CppReady = $false
            ActiveClient = $codexPlusPlusProcessCount -gt 0 -or $independentCodexProcessCount -gt 0
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $false
            BypassDetail = $null
            Detail = 'route_contract_invalid: schema_version=2 and route contract fields do not match proxy/official mode'
        }
    }
    $routeStateHashMatchesForStatus = $routeStateFresh -and $routeStateHashMatches
        $routeStateValid = $routeStateFresh -and $routeStateHashMatches -and $routeStateKeeperValid -and ($routeStateStatus -in @('ready', 'official-bypass') -or ($routeStateStatus -eq 'reconciling' -and $routeStateHashMatchesForStatus))
    $officialBypass = $routeStateValid -and $routeStateStatus -eq 'official-bypass'
    $routeReady = $routeStateValid -and $routeStateStatus -eq 'ready'
    $cppReady = $routeReady -and $codexConfigLocal -and $cppConfigLocal -and $codexPlusPlusProcessCount -gt 0
    $independentRemote = -not $officialBypass -and $independentCodexProcessCount -gt 0 -and $CodexConfig.Exists -and -not $codexConfigLocal
    $activeClient = $codexPlusPlusProcessCount -gt 0 -or $independentCodexProcessCount -gt 0
    $bypassDetail = if ($independentRemote) {
        ("旁路：检测到 {0} 个独立 Codex 进程使用非本地 base_url {1}；其请求不会经过 Headroom" -f $independentCodexProcessCount, (ConvertTo-RouteLabel $CodexConfig.BaseUrl))
    }
    else {
        $null
    }

    if ($officialBypass) {
        return [pscustomobject]@{
            State = 'Yellow'
            RouteMismatch = $false
            RouteContractValid = $routeContractValid
            CppReady = $false
            ActiveClient = $activeClient
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $true
            BypassDetail = '纯官方账号模式按设计保持官方直连，未纳入 Headroom。'
            Detail = '官方账号旁路已确认；Headroom 健康不代表官方账号流量经过代理。'
        }
    }
    if ($cppReady) {
        return [pscustomobject]@{
            State = 'Green'
            RouteMismatch = $false
            RouteContractValid = $routeContractValid
            CppReady = $true
            ActiveClient = $activeClient
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $independentRemote
            BypassDetail = $bypassDetail
            Detail = ("官方 .codex 配置已指向 Headroom，Codex++ 进程已运行（{0} 个）" -f $codexPlusPlusProcessCount)
        }
    }
    if ($codexPlusPlusProcessCount -gt 0 -and -not $cppConfigLocal) {
        return [pscustomobject]@{
            State = 'Red'
            RouteMismatch = $true
            RouteContractValid = $routeContractValid
            CppReady = $false
            ActiveClient = $true
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $false
            BypassDetail = $null
            Detail = ("Codex++ 进程已运行，但专用配置未指向本地 Headroom（当前为 {0}）" -f (ConvertTo-RouteLabel $CodexPlusPlusConfig.BaseUrl))
        }
    }
    if ($independentRemote) {
        return [pscustomobject]@{
            State = 'Red'
            RouteMismatch = $true
            RouteContractValid = $routeContractValid
            CppReady = $false
            ActiveClient = $true
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $false
            BypassDetail = $null
            Detail = ("Codex++ 未运行，检测到 {0} 个独立 Codex 进程使用非本地 base_url {1}；实际请求不会经过 Headroom" -f $independentCodexProcessCount, (ConvertTo-RouteLabel $CodexConfig.BaseUrl))
        }
    }
    if (($independentCodexProcessCount -gt 0 -and $CodexConfig.Exists -and $codexConfigLocal -and $routeReady) -or ($codexPlusPlusProcessCount -gt 0 -and $CodexConfig.Exists -and $codexConfigLocal -and $routeStateStatus -eq 'ready') -or ($managerProcessCount -gt 0 -and $routeStateStatus -eq 'ready')) {
        if ($independentCodexProcessCount -gt 0) {
            $detail = ("独立 Codex 进程已运行并指向本地 Headroom（{0} 个）" -f $independentCodexProcessCount)
        } elseif ($codexPlusPlusProcessCount -gt 0) {
            $detail = "Codex++ 已通过 Headroom 代理"
        } else {
            $detail = "管理工具已就绪，路由通过 Headroom"
        }
        return [pscustomobject]@{
            State = 'Green'
            RouteMismatch = $false
            RouteContractValid = $routeContractValid
            CppReady = $false
            ActiveClient = $true
            IndependentCodexCount = $independentCodexProcessCount
            IndependentOfficialCodexCount = $independentOfficialProcessCount
            BypassWarning = $false
            BypassDetail = $null
            Detail = $detail
        }
    }
    if (-not $activeClient) {
        $detail = if ($cppConfigLocal) {
            'Codex++ 配置已指向 Headroom，但未检测到活动客户端；等待真实模型流量'
        }
        else {
            '未检测到活动客户端；服务健康不等于已代理'
        }
        return [pscustomobject]@{
            State = 'Gray'
            RouteMismatch = $false
            RouteContractValid = $routeContractValid
            CppReady = $false
            ActiveClient = $false
            IndependentCodexCount = 0
            IndependentOfficialCodexCount = 0
            BypassWarning = $false
            BypassDetail = $null
            Detail = $detail
        }
    }

    return [pscustomobject]@{
        State = 'Yellow'
        RouteMismatch = $false
        RouteContractValid = $routeContractValid
        CppReady = $false
        ActiveClient = $activeClient
        IndependentCodexCount = $independentCodexProcessCount
        IndependentOfficialCodexCount = $independentOfficialProcessCount
        BypassWarning = $false
        BypassDetail = $null
        Detail = '检测到活动客户端，但无法确认其已指向 Headroom'
    }
}

function Test-ManagedCodexProcessState {
    $state = $null
    if (Test-Path -LiteralPath $script:ManagedCodexStatePath -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $script:ManagedCodexStatePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }
    if ($null -eq $state -or [int](Get-ObjectProperty $state 'schema_version') -ne 1 -or [string](Get-ObjectProperty $state 'route_scope') -ne 'process') { return $false }
    $stateRoutePath = [string](Get-ObjectProperty $state 'route_state_path')
    try {
        if (-not [IO.Path]::GetFullPath($stateRoutePath).Equals([IO.Path]::GetFullPath($script:RouteStatePath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    catch { return $false }
    $entries = @((Get-ObjectProperty $state 'processes'))
    if ($entries.Count -ne 2) { return $false }
    foreach ($entry in $entries) {
        $processId = ConvertTo-StatsNumber (Get-ObjectProperty $entry 'pid')
        if ($null -eq $processId -or [Math]::Floor($processId) -ne $processId -or $processId -le 0) { return $false }
        $snapshot = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$processId)" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $snapshot) { return $false }
        try {
            $actualPath = [IO.Path]::GetFullPath((Get-MonitorProcessExecutablePath -ProcessId ([int]$processId)))
            $expectedPath = [IO.Path]::GetFullPath([string](Get-ObjectProperty $entry 'executable_path'))
        }
        catch { return $false }
        if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $process = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }
        try {
            $expectedStartedAt = ConvertTo-MonitorUtcDateTimeValue -Value (Get-ObjectProperty $entry 'started_at_utc')
            if ($null -eq $expectedStartedAt) { return $false }
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStartedAt).TotalSeconds) -gt 2) { return $false }
        }
        catch { return $false }
    }
    return $true
}

function Get-ClientRouteObservation {
    param(
        [Parameter(Mandatory)][object]$CodexPlusPlusConfig,
        [Parameter(Mandatory)][object]$CodexConfig,
        [Parameter(Mandatory)][object]$Processes
    )

    $activeClient = @($Processes.CodexPlusPlus).Count -gt 0 -or @($Processes.Manager).Count -gt 0
    $managedProcessesReady = Test-ManagedCodexProcessState
    $routeState = $null
    if (Test-Path -LiteralPath $script:RouteStatePath -PathType Leaf) {
        try { $routeState = Get-Content -LiteralPath $script:RouteStatePath -Raw | ConvertFrom-Json } catch { $routeState = $null }
    }

    $routeValid = $false
    if ($null -ne $routeState) {
        try {
            $timestamp = ConvertTo-MonitorUtcDateTimeValue -Value (Get-ObjectProperty $routeState 'timestamp_utc')
            if ($null -eq $timestamp) { throw 'route_timestamp_invalid' }
            $fresh = $timestamp -le [DateTime]::UtcNow.AddSeconds(5) -and $timestamp -gt [DateTime]::UtcNow.AddSeconds(-$script:RouteStateMaxAgeSeconds)
            $configHash = if (Test-Path -LiteralPath $script:CodexPlusPlusConfigPath -PathType Leaf) { (Get-FileHash -LiteralPath $script:CodexPlusPlusConfigPath -Algorithm SHA256).Hash } else { '' }
            $keeperPid = ConvertTo-StatsNumber (Get-ObjectProperty $routeState 'route_keeper_pid')
            $keeperProcess = if ($null -ne $keeperPid -and [Math]::Floor($keeperPid) -eq $keeperPid) { Get-Process -Id ([int]$keeperPid) -ErrorAction SilentlyContinue } else { $null }
            $keeperInfo = if ($null -ne $keeperProcess) { Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$keeperPid)" -ErrorAction SilentlyContinue } else { $null }
            $keeperCommand = if ($keeperInfo) { [string]$keeperInfo.CommandLine } else { '' }
            $routeValid = (
                $fresh -and
                [int](Get-ObjectProperty $routeState 'schema_version') -eq 3 -and
                [int](Get-ObjectProperty $routeState 'route_contract_version') -eq 3 -and
                [string](Get-ObjectProperty $routeState 'status') -eq 'ready' -and
                [string](Get-ObjectProperty $routeState 'route_scope') -eq 'process' -and
                [string](Get-ObjectProperty $routeState 'process_route_base_url') -eq $script:ProxyBaseUrl -and
                (Get-ObjectProperty $routeState 'config_mutated') -eq $false -and
                -not [string]::IsNullOrWhiteSpace($configHash) -and
                [string](Get-ObjectProperty $routeState 'config_sha256') -eq $configHash -and
                [string](Get-ObjectProperty $routeState 'route_keeper_config_path') -eq $script:CodexPlusPlusConfigPath -and
                [string](Get-ObjectProperty $routeState 'route_keeper_script_path') -eq $script:RouteKeeperPath -and
                [string](Get-ObjectProperty $routeState 'route_keeper_mode') -eq 'watch' -and
                $null -ne $keeperProcess -and
                $keeperCommand -match ('(?i)' + [regex]::Escape($script:RouteKeeperPath)) -and
                $keeperCommand -match '(?i)(^|\s)-Watch(\s|$)'
            )
        }
        catch { $routeValid = $false }
    }

    $independentOfficialCount = @($Processes.IndependentOfficialCodex).Count
    $bypassWarning = $independentOfficialCount -gt 0
    $bypassDetail = if ($bypassWarning) { "旁路警告：检测到 $independentOfficialCount 个不属于受管 Codex++ 进程树的官方 Codex 进程。" } else { $null }
    if ($routeValid -and $managedProcessesReady) {
        return [pscustomobject]@{
            State = 'Green'; RouteMismatch = $false; RouteContractValid = $true; CppReady = $true; ActiveClient = $true
            IndependentCodexCount = @($Processes.IndependentCodex).Count; IndependentOfficialCodexCount = $independentOfficialCount
            BypassWarning = $bypassWarning; BypassDetail = $bypassDetail
            Detail = '进程级 Headroom 路由、配置哈希和受管 Manager/Codex++ 进程身份已确认；供应商 Base URL 保持原值。'
        }
    }
    if ($routeValid -and -not $activeClient) {
        return [pscustomobject]@{
            State = 'Yellow'; RouteMismatch = $false; RouteContractValid = $true; CppReady = $false; ActiveClient = $false
            IndependentCodexCount = @($Processes.IndependentCodex).Count; IndependentOfficialCodexCount = $independentOfficialCount
            BypassWarning = $bypassWarning; BypassDetail = $bypassDetail
            Detail = '进程级路由已发布，等待受管 Codex++ 客户端启动。'
        }
    }
    return [pscustomobject]@{
        State = if ($activeClient) { 'Red' } else { 'Yellow' }
        RouteMismatch = $activeClient
        RouteContractValid = $routeValid
        CppReady = $false
        ActiveClient = $activeClient
        IndependentCodexCount = @($Processes.IndependentCodex).Count
        IndependentOfficialCodexCount = $independentOfficialCount
        BypassWarning = $bypassWarning
        BypassDetail = $bypassDetail
        Detail = if ($activeClient) { '检测到 Codex++，但进程级路由或受管进程身份未通过验证。' } else { '尚无可验证的进程级路由与受管客户端。' }
    }
}

function Get-MonitorSnapshot {
    $issues = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    $gatewayLivez = Get-JsonEndpoint -Uri "$script:GatewayBaseUrl/livez"
    $gatewayHealth = Get-JsonEndpoint -Uri "$script:GatewayBaseUrl/health"
    $livez = Get-JsonEndpoint -Uri "$script:HeadroomBaseUrl/livez"
    $health = Get-JsonEndpoint -Uri "$script:HeadroomBaseUrl/health"
    $brokerHealth = Get-JsonEndpoint -Uri "$script:BrokerBaseUrl/health"

    if (-not $brokerHealth.TransportOk -or $brokerHealth.StatusCode -ne 200 -or $brokerHealth.ParseError -or $null -eq $brokerHealth.Body) {
        Add-MonitorIssue -List $issues -Code 'kompress_broker_unreachable' -Message 'Kompress broker /health is unavailable.'
    }
    elseif ((Get-ObjectProperty $brokerHealth.Body 'service') -ne 'kompress-broker' -or (Get-ObjectProperty $brokerHealth.Body 'ready') -ne $true -or (Get-ObjectProperty $brokerHealth.Body 'status') -ne 'healthy') {
        Add-MonitorIssue -List $issues -Code 'kompress_broker_unhealthy' -Message 'Kompress broker is not healthy/ready.'
    }

    if (-not $gatewayLivez.TransportOk) {
        Add-MonitorIssue -List $issues -Code 'gateway_livez_unreachable' -Message 'Policy Gateway /livez is unreachable.'
    }
    elseif ($gatewayLivez.StatusCode -ne 200) {
        Add-MonitorIssue -List $issues -Code 'gateway_livez_http_status' -Message "Policy Gateway /livez returned HTTP $($gatewayLivez.StatusCode)."
    }
    elseif ($gatewayLivez.ParseError -or $null -eq $gatewayLivez.Body) {
        Add-MonitorIssue -List $issues -Code 'gateway_livez_invalid_json' -Message 'Policy Gateway /livez returned invalid JSON.'
    }
    elseif ((Get-ObjectProperty $gatewayLivez.Body 'service') -ne 'policy-gateway' -or (Get-ObjectProperty $gatewayLivez.Body 'status') -ne 'healthy' -or (Get-ObjectProperty $gatewayLivez.Body 'alive') -ne $true) {
        Add-MonitorIssue -List $issues -Code 'gateway_livez_unhealthy' -Message 'Policy Gateway /livez is not healthy/alive.'
    }

    if (-not $gatewayHealth.TransportOk) {
        Add-MonitorIssue -List $issues -Code 'gateway_health_unreachable' -Message 'Policy Gateway /health is unreachable.'
    }
    elseif ($gatewayHealth.StatusCode -ne 200) {
        Add-MonitorIssue -List $issues -Code 'gateway_health_http_status' -Message "Policy Gateway /health returned HTTP $($gatewayHealth.StatusCode)."
    }
    elseif ($gatewayHealth.ParseError -or $null -eq $gatewayHealth.Body) {
        Add-MonitorIssue -List $issues -Code 'gateway_health_invalid_json' -Message 'Policy Gateway /health returned invalid JSON.'
    }
    elseif ((Get-ObjectProperty $gatewayHealth.Body 'service') -ne 'policy-gateway' -or (Get-ObjectProperty $gatewayHealth.Body 'status') -ne 'healthy' -or (Get-ObjectProperty $gatewayHealth.Body 'ready') -ne $true) {
        Add-MonitorIssue -List $issues -Code 'gateway_health_unhealthy' -Message 'Policy Gateway /health is not healthy/ready.'
    }

    if (-not $livez.TransportOk) {
        Add-MonitorIssue -List $issues -Code 'headroom_livez_unreachable' -Message 'Headroom /livez is unreachable.'
    }
    elseif ($livez.StatusCode -ne 200) {
        Add-MonitorIssue -List $issues -Code 'headroom_livez_http_status' -Message "Headroom /livez returned HTTP $($livez.StatusCode)."
    }
    elseif ($livez.ParseError -or $null -eq $livez.Body) {
        Add-MonitorIssue -List $issues -Code 'headroom_livez_invalid_json' -Message 'Headroom /livez returned invalid JSON.'
    }
    else {
        if ((Get-ObjectProperty $livez.Body 'service') -ne 'headroom-proxy' -or (Get-ObjectProperty $livez.Body 'status') -ne 'healthy' -or (Get-ObjectProperty $livez.Body 'alive') -ne $true) {
            Add-MonitorIssue -List $issues -Code 'headroom_livez_unhealthy' -Message 'Headroom /livez is not healthy/alive.'
        }
    }

    $healthBody = $null
    $optimizationDisabled = Test-HeadroomOptimizationDisabled
    if (-not $health.TransportOk) {
        Add-MonitorIssue -List $issues -Code 'headroom_health_unreachable' -Message 'Headroom /health is unreachable.'
    }
    elseif ($health.StatusCode -ne 200) {
        Add-MonitorIssue -List $issues -Code 'headroom_health_http_status' -Message "Headroom /health returned HTTP $($health.StatusCode)."
    }
    elseif ($health.ParseError -or $null -eq $health.Body) {
        Add-MonitorIssue -List $issues -Code 'headroom_health_invalid_json' -Message 'Headroom /health returned invalid JSON.'
    }
    else {
        $healthBody = $health.Body
        if ((Get-ObjectProperty $healthBody 'service') -ne 'headroom-proxy' -or (Get-ObjectProperty $healthBody 'status') -ne 'healthy' -or (Get-ObjectProperty $healthBody 'ready') -ne $true) {
            Add-MonitorIssue -List $issues -Code 'health_unhealthy' -Message 'Headroom /health is not healthy/ready.'
        }

        $healthConfig = Get-ObjectProperty $healthBody 'config'
        $relayUrl = Get-ObjectProperty $healthConfig 'openai_api_url'
        if (-not (Test-RelayUrl -Value $relayUrl)) {
            Add-MonitorIssue -List $issues -Code 'health_relay_config' -Message 'Headroom /health config.openai_api_url is not the local relay.'
        }

        $checks = Get-ObjectProperty $healthBody 'checks'
        $kompress = Get-ObjectProperty $checks 'kompress'
        if ($null -eq $kompress) {
            Add-MonitorIssue -List $issues -Code 'health_kompress_missing' -Message 'Headroom /health omitted the required Kompress check.'
        }
        else {
            $kompressReady = Get-ObjectProperty $kompress 'ready'
            $kompressStatus = Get-ObjectProperty $kompress 'status'
            $kompressInfo = Get-ObjectProperty $kompress 'info'
            $sourceStatus = Get-ObjectProperty $kompressInfo 'source_status'
            if ($kompressReady -ne $true -or $kompressStatus -eq 'unhealthy' -or $sourceStatus -eq 'deferred') {
                Add-MonitorIssue -List $issues -Code 'kompress_not_ready' -Message 'Headroom Kompress is not strictly ready or is still deferred.'
            }
        }
    }

    $compressionExecutor = $null
    if ($null -ne $healthBody) {
        $runtime = Get-ObjectProperty $healthBody 'runtime'
        $compressionExecutor = Get-ObjectProperty $runtime 'compression_executor'
    }
    $queueTimeoutsTotal = ConvertTo-StatsNumber (Get-ObjectProperty $compressionExecutor 'queue_timeouts_total')
    $timedOutWorkers = ConvertTo-StatsNumber (Get-ObjectProperty $compressionExecutor 'timed_out_workers')
    $quarantineActive = (Get-ObjectProperty $compressionExecutor 'quarantine_active') -eq $true
    $queueTimeoutsIncreased = $false
    if ($null -ne $queueTimeoutsTotal) {
        if ($null -eq $script:CompressionQueueTimeoutBaseline) {
            $script:CompressionQueueTimeoutBaseline = $queueTimeoutsTotal
        }
        elseif ($queueTimeoutsTotal -gt $script:CompressionQueueTimeoutBaseline) {
            $queueTimeoutsIncreased = $true
            $script:CompressionQueueTimeoutBaseline = $queueTimeoutsTotal
        }
        elseif ($queueTimeoutsTotal -lt $script:CompressionQueueTimeoutBaseline) {
            $script:CompressionQueueTimeoutBaseline = $queueTimeoutsTotal
        }
    }

    $relay = Test-TcpEndpoint -HostName $script:RelayHost -Port $script:RelayPort
    if (-not $relay.Ok) {
        Add-MonitorIssue -List $issues -Code 'relay_unreachable' -Message "Relay TCP $script:RelayHost`:$script:RelayPort is unreachable."
    }

    $warmup = Get-JsonEndpoint -Uri "$script:HeadroomBaseUrl/debug/warmup"
    if ($warmup.TransportOk -and $warmup.StatusCode -eq 200 -and -not $warmup.ParseError -and $null -ne $warmup.Body) {
        $warmupKompress = Get-ObjectProperty $warmup.Body 'kompress'
        $warmupInfo = Get-ObjectProperty $warmupKompress 'info'
        $warmupSource = Get-ObjectProperty $warmupInfo 'source_status'
        $warmupStatus = Get-ObjectProperty $warmupKompress 'status'
        if ($warmupSource -eq 'deferred' -or $warmupStatus -eq 'unhealthy' -or ($optimizationDisabled -and $warmupStatus -eq 'null')) {
            Add-MonitorIssue -List $issues -Code 'warmup_not_ready' -Message 'Kompress warmup is deferred or unhealthy.'
        }
    }

    $stats = Get-JsonEndpoint -Uri "$script:HeadroomBaseUrl/stats"
    $traffic = if ($stats.TransportOk -and $stats.StatusCode -eq 200 -and -not $stats.ParseError) {
        Get-StatsTrafficObservation -Body $stats.Body
    }
    else {
        Get-StatsTrafficObservation -Body $null
    }
    $trafficObservation = if ($traffic.Available) {
        "$($traffic.Observation); paths=$($traffic.PathObservation)"
    }
    else {
        'HTTP=unknown, WS=unknown, inbound_model=unknown; paths=unknown'
    }
    $trafficDelta = $null
    $currentTraffic = $null
    if ($traffic.Available) {
        $currentTraffic = if ($traffic.TrafficKnown -and $null -ne $traffic.HttpCompleted -and $null -ne $traffic.InboundModel -and $null -ne $traffic.FailedTotal) {
            [pscustomobject]@{
                HttpCompleted = [double]$traffic.HttpCompleted
                InboundModel = [double]$traffic.InboundModel
                FailedTotal = [double]$traffic.FailedTotal
            }
        }
        else {
            $null
        }
        if ($null -eq $currentTraffic) {
            $script:TrafficBaseline = $null
        }
        elseif ($null -ne $script:TrafficBaseline -and ($currentTraffic.HttpCompleted -lt $script:TrafficBaseline.HttpCompleted -or $currentTraffic.InboundModel -lt $script:TrafficBaseline.InboundModel -or $currentTraffic.FailedTotal -lt $script:TrafficBaseline.FailedTotal)) {
            # Headroom counters reset or restarted; discard this sample and rebuild.
            $script:TrafficBaseline = $currentTraffic
            $trafficDelta = $null
        }
        elseif ($null -ne $script:TrafficBaseline) {
            $trafficDelta = [pscustomobject]@{
                HttpCompleted = $currentTraffic.HttpCompleted - $script:TrafficBaseline.HttpCompleted
                InboundModel = $currentTraffic.InboundModel - $script:TrafficBaseline.InboundModel
                FailedTotal = $currentTraffic.FailedTotal - $script:TrafficBaseline.FailedTotal
            }
            $script:TrafficBaseline = $currentTraffic
        }
        else {
            # The first complete sample establishes this process-local baseline.
            # It is intentionally not persisted across monitor restarts.
            $script:TrafficBaseline = $currentTraffic
        }
    }
    else {
        $script:TrafficBaseline = $null
    }
    if (-not $traffic.Available) {
        Add-MonitorWarning -List $warnings -Code 'stats_unavailable' -Message "Headroom /stats traffic observation unavailable; $trafficObservation."
    }
    elseif ($null -eq $trafficDelta) {
        Add-MonitorWarning -List $warnings -Code 'traffic_baseline_pending' -Message "Headroom /stats is available; waiting for a post-start traffic delta; $trafficObservation."
    }
    elseif (-not $traffic.TrafficKnown) {
        Add-MonitorWarning -List $warnings -Code 'traffic_fields_unavailable' -Message "Headroom /stats traffic fields are incomplete; $trafficObservation."
    }
    elseif ($trafficDelta.FailedTotal -gt 0) {
        Add-MonitorIssue -List $issues -Code 'traffic_failed' -Message "Headroom reported new failed requests; successful completion evidence is not sufficient; $trafficObservation."
    }
    elseif ($trafficDelta.HttpCompleted -le 0 -and $trafficDelta.InboundModel -le 0) {
        Add-MonitorWarning -List $warnings -Code 'traffic_unobserved' -Message "No new completed model request observed since monitor start; $trafficObservation; MCP compression is tracked separately."
    }
    elseif ($trafficDelta.HttpCompleted -le 0 -and $trafficDelta.InboundModel -gt 0) {
        Add-MonitorWarning -List $warnings -Code 'traffic_pending_only' -Message "Model-path inbound traffic was observed before a matching completion; request may still be running or completion counters may lag; $trafficObservation."
    }

    $codexPlusPlusConfig = Get-CodexConfigSnapshot -Path $script:CodexPlusPlusConfigPath
    $codexConfig = Get-CodexConfigSnapshot -Path $script:CodexConfigPath
    $processes = Get-ProcessSnapshot
    $route = Get-ClientRouteObservation -CodexPlusPlusConfig $codexPlusPlusConfig -CodexConfig $codexConfig -Processes $processes
    if ($route.RouteMismatch) {
        Add-MonitorIssue -List $issues -Code 'route_keeper_failed' -Message $route.Detail
    }
    elseif (-not $route.ActiveClient) {
        Add-MonitorWarning -List $warnings -Code 'client_route_idle' -Message 'No active Codex client route was observed; service health does not prove model traffic.'
    }
    elseif ($route.State -eq 'Yellow') {
        Add-MonitorWarning -List $warnings -Code 'client_route_unknown' -Message $route.Detail
    }
    if (@($processes.StandardCodex).Count -gt 0 -and @($processes.CodexPlusPlus).Count -eq 0) {
        Add-MonitorWarning -List $warnings -Code 'standard_codex_bypass' -Message 'A standard Codex process is running outside the managed Codex++ route; it is not modified by Headroom.'
    }
    if ($route.BypassWarning) {
        Add-MonitorWarning -List $warnings -Code 'independent_codex_bypass' -Message ([string]$route.BypassDetail)
    }

    $routeObservation = "state=$($route.State); $($route.Detail)"
    if ($route.BypassWarning) {
        $routeObservation += "; $($route.BypassDetail)"
    }
    $logEvidence = Get-LogWindowEvidence -SinceUtc $script:MonitorStartedAt

    return [pscustomobject]@{
        CriticalIssues = @($issues)
        Warnings = @($warnings)
        Processes = $processes
        ApiRequestObservation = $trafficObservation
        TrafficObservation = $trafficObservation
        Traffic = $traffic
        TrafficDelta = $trafficDelta
        RouteObservation = $routeObservation
        Route = $route
        GatewayLivez = $gatewayLivez
        GatewayHealth = $gatewayHealth
        BrokerHealth = $brokerHealth
        Livez = $livez
        Health = $health
        Relay = $relay
        Warmup = $warmup
        CompressionPolicy = if ($optimizationDisabled) { 'disabled' } else { 'enabled_or_unknown' }
        Stats = $stats
        LogEvidence = $logEvidence
        CompressionExecutor = [pscustomobject]@{
            QuarantineActive = $quarantineActive
            QueueTimeoutsTotal = $queueTimeoutsTotal
            QueueTimeoutsIncreased = $queueTimeoutsIncreased
            TimedOutWorkers = $timedOutWorkers
        }
        CodexPlusPlusConfig = $codexPlusPlusConfig
        CodexConfig = $codexConfig
        OwnerCount = [int]$processes.OwnerCount
    }
}

function Get-SnapshotFingerprint {
    param([Parameter(Mandatory)][object]$Snapshot)

    $parts = @($Snapshot.CriticalIssues | ForEach-Object { ConvertTo-SafeText $_.Code } | Sort-Object -Unique)
    if ($parts.Count -eq 0) {
        return 'healthy'
    }
    return [string]::Join('|', $parts)
}

function Get-SnapshotPopupMessage {
    param([Parameter(Mandatory)][object]$Snapshot)

    $messages = @($Snapshot.CriticalIssues | ForEach-Object { [string]$_.Message })
    $message = if ($messages.Count -eq 0) { 'Headroom monitor detected a problem.' } else { [string]::Join("`r`n", $messages[0..([Math]::Min($messages.Count - 1, 3))]) }
    if (@($Snapshot.CriticalIssues | Where-Object { $_.Code -in @('standard_codex_running', 'codexpp_running_bypass') }).Count -gt 0) {
        $message += "`r`n`r`nClose the conflicting process, then relaunch from D:\Desktop\Codex++.lnk or D:\Desktop\Codex++ 管理工具.lnk."
    }
    return $message
}

function Show-MonitorPopup {
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$Message
    )

    if ($NoPopup) {
        return
    }

    $now = Get-Date
    if ($script:LastPopupFingerprint -eq $Fingerprint -and $null -ne $script:LastPopupAt -and (($now - $script:LastPopupAt).TotalSeconds -lt $PopupCooldownSeconds)) {
        return
    }

    $script:LastPopupFingerprint = $Fingerprint
    $script:LastPopupAt = $now
    try {
        $wsh = New-Object -ComObject WScript.Shell
        [void]$wsh.Popup((ConvertTo-SafeText $Message), 15, 'Codex++ Headroom monitor', 0x30)
    }
    catch {
        Write-MonitorLog -Level WARN -Message 'Unable to show monitor popup.'
    }
}

function Write-SnapshotWarnings {
    param([Parameter(Mandatory)][object]$Snapshot)

    $warningParts = @($Snapshot.Warnings | ForEach-Object { ConvertTo-SafeText $_.Code } | Sort-Object -Unique)
    if ($warningParts.Count -eq 0) {
        $script:LastWarningFingerprint = $null
        $script:LastWarningAt = $null
        return
    }

    $fingerprint = [string]::Join('|', $warningParts)
    $now = Get-Date
    $shouldLog = ($script:LastWarningFingerprint -ne $fingerprint -or $null -eq $script:LastWarningAt -or (($now - $script:LastWarningAt).TotalSeconds -ge $PopupCooldownSeconds))
    if ($shouldLog) {
        Write-MonitorLog -Level WARN -Message ([string]::Join('; ', @($Snapshot.Warnings | ForEach-Object { $_.Message })))
        $script:LastWarningFingerprint = $fingerprint
        $script:LastWarningAt = $now
    }
}

function Handle-MonitorSnapshot {
    param([Parameter(Mandatory)][object]$Snapshot)

    $script:UnifiedStatus = Get-UnifiedStatus -Snapshot $Snapshot
    [void](Write-StatusDocument -Document $script:UnifiedStatus)
    Pump-StatusListener
    Write-SnapshotWarnings -Snapshot $Snapshot
    $fingerprint = Get-SnapshotFingerprint -Snapshot $Snapshot
    $critical = @($Snapshot.CriticalIssues)
    if ($critical.Count -eq 0) {
        if ($script:LastRecoveryStatus -ne 'healthy') {
            Write-MonitorLog -Level INFO -Message "Headroom healthy; $($Snapshot.RouteObservation); $($Snapshot.TrafficObservation)."
            Write-MonitorState -Fingerprint 'healthy' -RecoveryStatus 'healthy' -Traffic $Snapshot.Traffic -TrafficDelta $Snapshot.TrafficDelta
        }
        $script:LastFingerprint = 'healthy'
        $script:LastRecoveryStatus = 'healthy'
        return 0
    }

    $now = Get-Date
    $changed = $script:LastFingerprint -ne $fingerprint
    if ($changed) {
        Write-MonitorLog -Level ERROR -Message ([string]::Join('; ', @($critical | ForEach-Object { $_.Message })))
        Write-MonitorState -Fingerprint $fingerprint -RecoveryStatus 'failed' -Traffic $Snapshot.Traffic -TrafficDelta $Snapshot.TrafficDelta
        $script:LastFingerprint = $fingerprint
        $script:LastRecoveryStatus = 'failed'
    }

    # Let startup dependencies settle before showing a critical popup.
    $allowStartupPopup = (($now - $script:StartTime).TotalSeconds -ge $StartupPopupGraceSeconds)
    if ($allowStartupPopup) {
        Show-MonitorPopup -Fingerprint $fingerprint -Message (Get-SnapshotPopupMessage -Snapshot $Snapshot)
    }
    return 2
}

function Initialize-MonitorDedupe {
    $state = Read-MonitorState
    if ($null -eq $state) {
        return
    }
    $script:PreviousActiveIssueCodes = @($state.ActiveIssueCodes)
    if ($state.RecoveryStatus -eq 'failed') {
        $script:LastPopupFingerprint = $state.Fingerprint
        $script:LastPopupAt = $state.Timestamp
        $script:LastFingerprint = $state.Fingerprint
        $script:LastRecoveryStatus = 'failed'
    }
}

if ($ImportOnly) {
    return
}

$watchMode = $script:WatchMode
if ($Watch -and $Once) {
    Write-MonitorLog -Level ERROR -Message 'Use either -Watch or -Once, not both.'
    exit 3
}
if ($PollSeconds -lt 1 -or $PollSeconds -gt 60 -or $StartupGraceSeconds -lt 5 -or $StartupGraceSeconds -gt 600 -or $PrelaunchGraceSeconds -lt 5 -or $PrelaunchGraceSeconds -gt 600 -or $StartupPopupGraceSeconds -lt 5 -or $StartupPopupGraceSeconds -gt 120 -or $PopupCooldownSeconds -lt 10 -or $PopupCooldownSeconds -gt 3600) {
    Write-MonitorLog -Level ERROR -Message 'Invalid monitor timing parameters.'
    exit 3
}

$mutex = $null
$mutexHeld = $false
try {
    $mutex = [Threading.Mutex]::new($false, $script:HeadroomMonitorMutexName)
    try {
        $mutexHeld = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $mutexHeld = $true
    }
    if (-not $mutexHeld) {
        Write-MonitorLog -Level WARN -Message 'Another monitor instance owns the mutex; this invocation is busy.'
        exit 2
    }

    if ($watchMode) {
        Start-StatusListener
    }
    Initialize-MonitorDedupe
    if (-not $watchMode) {
        $snapshot = Get-MonitorSnapshot
        exit (Handle-MonitorSnapshot -Snapshot $snapshot)
    }

    $ownerMissingSince = $null
    while ($true) {
        $snapshot = Get-MonitorSnapshot
        if ($snapshot.OwnerCount -gt 0) {
            $script:HasObservedOwner = $true
            $script:PrelaunchGraceActive = $false
            $ownerMissingSince = $null
        }
        elseif (-not $script:HasObservedOwner) {
            $prelaunchElapsed = ([DateTime]::UtcNow - $script:MonitorStartedAt).TotalSeconds
            $script:PrelaunchGraceActive = $prelaunchElapsed -lt $PrelaunchGraceSeconds
            if (-not $script:PrelaunchGraceActive) {
                Write-MonitorLog -Level INFO -Message "No valid Codex++ owner appeared within the $PrelaunchGraceSeconds-second prelaunch grace; monitor exiting."
                $roundCode = Handle-MonitorSnapshot -Snapshot $snapshot
                Write-MonitorState -Fingerprint 'owner_missing_prelaunch' -RecoveryStatus 'exited' -Traffic $snapshot.Traffic -TrafficDelta $snapshot.TrafficDelta
                exit 0
            }
        }
        else {
            $script:PrelaunchGraceActive = $false
            if ($null -eq $ownerMissingSince) {
                $ownerMissingSince = Get-Date
            }
            if (((Get-Date) - $ownerMissingSince).TotalSeconds -ge $StartupGraceSeconds) {
                Write-MonitorLog -Level INFO -Message 'No Codex++ owner process remained within the grace period; monitor exiting.'
                $roundCode = Handle-MonitorSnapshot -Snapshot $snapshot
                Write-MonitorState -Fingerprint 'owner_missing' -RecoveryStatus 'exited' -Traffic $snapshot.Traffic -TrafficDelta $snapshot.TrafficDelta
                exit 0
            }
        }
        $roundCode = Handle-MonitorSnapshot -Snapshot $snapshot
        if ($null -ne $script:LastRecoveryStatus -and -not [string]::IsNullOrWhiteSpace([string]$script:LastRecoveryStatus)) {
            Write-MonitorState -Fingerprint ([string]$script:LastFingerprint) -RecoveryStatus ([string]$script:LastRecoveryStatus) -Traffic $snapshot.Traffic -TrafficDelta $snapshot.TrafficDelta
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
catch {
    Write-MonitorLog -Level ERROR -Message "Monitor internal error; exiting with code 3: $(ConvertTo-SafeText $_.Exception.Message)"
    if (-not $NoPopup) {
        Show-MonitorPopup -Fingerprint 'internal_error' -Message 'Codex++ Headroom monitor encountered an internal error.'
    }
    Write-MonitorState -Fingerprint 'internal_error' -RecoveryStatus 'error'
    exit 3
}
finally {
    Stop-StatusListener
    if ($mutexHeld -and $null -ne $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
