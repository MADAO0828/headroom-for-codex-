[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('codex', 'manager')]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$ExePath,

    [string]$Arguments = '',
    [string]$GatewayBaseUrl = 'http://127.0.0.1:18787',
    [string]$HeadroomBaseUrl = 'http://127.0.0.1:18789',
    [string]$MonitorBaseUrl = 'http://127.0.0.1:18788',
    [string]$BrokerBaseUrl = 'http://127.0.0.1:18790',
    [string]$RuntimeRoot = '',
    [string]$EnsureScript = '',
    [string]$CodexHome = 'C:\Users\ma dao\.codex',
    [string]$ConfigPath = 'C:\Users\ma dao\.codex\config.toml',
    [string]$RouteKeeperPath = '',
    [string]$RouteSettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json',
    [ValidateSet('auto', 'official', 'proxy')]
    [string]$RouteMode = 'auto',
    [ValidateRange(1, 180)]
    [int]$ReadinessTimeoutSeconds = 120,
    [switch]$AllowRelayPending,
    [switch]$SkipEnsure,
    [switch]$ReadinessOnly,
    [string]$AuditPath = '',
    [string]$RouteReadySignalPath = '',
    [string]$RouteStatePath = '',
    [string]$RouteWatchStatePath = '',
    [string]$StartupResultPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path $projectRoot 'runtime' }
$runtimeStateRoot = Join-Path $RuntimeRoot 'state'
$runtimeLogRoot = Join-Path $RuntimeRoot 'logs'
$runtimePythonPath = Join-Path $RuntimeRoot 'python\Scripts\python.exe'
if ([string]::IsNullOrWhiteSpace($EnsureScript)) { $EnsureScript = Join-Path $projectRoot 'src\headroom\codexpp-headroom\ensure-headroom.ps1' }
if ([string]::IsNullOrWhiteSpace($RouteKeeperPath)) { $RouteKeeperPath = Join-Path $PSScriptRoot 'codexpp-route-keeper.ps1' }
if ([string]::IsNullOrWhiteSpace($RouteReadySignalPath)) { $RouteReadySignalPath = Join-Path $runtimeStateRoot 'codexpp-route-ready.signal' }
if ([string]::IsNullOrWhiteSpace($RouteStatePath)) { $RouteStatePath = Join-Path $runtimeStateRoot 'codexpp-route-state.json' }
if ([string]::IsNullOrWhiteSpace($RouteWatchStatePath)) { $RouteWatchStatePath = Join-Path $runtimeStateRoot 'codexpp-route-watch.json' }
if ([string]::IsNullOrWhiteSpace($StartupResultPath)) { $StartupResultPath = Join-Path $runtimeStateRoot 'startup-result.json' }
[IO.Directory]::CreateDirectory($runtimeStateRoot) | Out-Null
[IO.Directory]::CreateDirectory($runtimeLogRoot) | Out-Null
$script:EffectiveRouteMode = 'unknown'
$script:ProxyBaseUrl = ''
$script:ExpectedBaseUrl = ''
$script:ProcessRouteBaseUrl = ''
$script:RouteConfigHash = ''
$script:RouteConfigMutated = $false
$script:RelayHost = '127.0.0.1'
$script:RelayPort = 57321
$script:MonitorStatusUrl = ''
$script:OfficialBypassFreshnessSeconds = 90

if ([string]::IsNullOrWhiteSpace($AuditPath)) {
    $AuditPath = Join-Path $runtimeLogRoot 'codexpp-bootstrap.log'
}

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { 'unknown' } else { [string]$Value }
    $text = $text -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)sk-[A-Za-z0-9_-]{8,}', '<redacted>'
    $text = $text -replace '(?i)(bearer\s+)[^\s]+', '$1<redacted>'
    if ($text.Length -gt 300) {
        return $text.Substring(0, 297) + '...'
    }
    return $text
}

function Test-RelayPendingRoleContract {
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'manager')][string]$Role,
        [switch]$AllowRelayPending,
        [switch]$ReadinessOnly
    )

    if (-not $AllowRelayPending) { return $true }
    # Manager and Codex both need the process-scoped pending route during
    # launch. ReadinessOnly remains strict, and Codex must pass
    # Wait-CodexProcessReadiness after its process is created.
    return $Role -in @('manager', 'codex') -and -not $ReadinessOnly
}

function Write-StartupResult {
    param(
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$ErrorCode,
        [Parameter(Mandatory)][string]$Stage,
        [AllowNull()][string]$Reason = ''
    )

    $document = [ordered]@{
        schema_version = 1
        generated_at = [DateTime]::UtcNow.ToString('o')
        role = $Role
        status = $Status
        exit_code = $ExitCode
        error_code = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { ConvertTo-SafeText $ErrorCode }
        stage = ConvertTo-SafeText $Stage
        reason = ConvertTo-SafeText $Reason
    }
    $directory = Split-Path -Parent $StartupResultPath
    $temporary = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            [IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        $temporary = Join-Path $directory ('.startup-result-' + [IO.Path]::GetRandomFileName())
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $StartupResultPath, $true)
    }
    catch {
        Write-Audit -Level WARN -Event 'startup_result_write_failed' -Fields @{ path = $StartupResultPath; message = $_.Exception.Message }
    }
    finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Exit-Startup {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory)][string]$ErrorCode,
        [Parameter(Mandatory)][string]$Stage,
        [AllowNull()][string]$Reason = ''
    )

    Write-StartupResult -Status $Status -ExitCode $ExitCode -ErrorCode $ErrorCode -Stage $Stage -Reason $Reason
    exit $ExitCode
}

function ConvertTo-UtcDateTime {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $raw = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces
    if ($raw -notmatch '(?i)(?:z|[+-]\d{2}:?\d{2})$') {
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeUniversal
    }
    [DateTimeOffset]$parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    return $parsed.UtcDateTime
}

function Test-ReadySignalContent {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $timestamp = ConvertTo-UtcDateTime -Value (Get-Content -LiteralPath $Path -Raw)
        if ($null -eq $timestamp) { return $false }
        return $timestamp -gt [DateTime]::UtcNow.AddSeconds(-90) -and $timestamp -le [DateTime]::UtcNow.AddSeconds(5)
    }
    catch { return $false }
}

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-StatsNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    [double]$number = 0
    if (-not [double]::TryParse(([string]$Value).Trim(), [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or [Math]::Floor($number) -ne $number) { return $null }
    return [Math]::Max(0, $number)
}

function Write-Audit {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Event,
        [hashtable]$Fields = @{}
    )

    try {
        $parent = Split-Path -Parent $AuditPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent -Force)
        }
        $parts = @("$([DateTime]::UtcNow.ToString('o')) [$Level] role=$Role event=$Event")
        foreach ($key in ($Fields.Keys | Sort-Object)) {
            $parts += "$key=$(ConvertTo-SafeText $Fields[$key])"
        }
        [IO.File]::AppendAllText($AuditPath, ([string]::Join(' ', $parts) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Startup must not fail only because its audit sink is unavailable.
    }
}

function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Uri)

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 15
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
            StatusCode = [int]$response.StatusCode
            Body = $body
            ParseError = $parseError
        }
    }
    catch {
        return [pscustomobject]@{
            TransportOk = $false
            StatusCode = 0
            Body = $null
            ParseError = $false
            Error = (ConvertTo-SafeText $_.Exception.Message)
        }
    }
}

function Get-ConfigBaseUrl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; BaseUrl = $null; Error = 'config_missing' }
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $provider = if ($providerMatch.Success) {
            if ($providerMatch.Groups['double'].Success) { $providerMatch.Groups['double'].Value } else { $providerMatch.Groups['single'].Value }
        }
        else {
            'CodexPlusPlus'
        }
        $sectionPattern = '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)'
        $sectionMatch = [regex]::Match($content, $sectionPattern)
        if (-not $sectionMatch.Success) {
            return [pscustomobject]@{ Exists = $true; BaseUrl = $null; Error = 'provider_section_missing' }
        }
        $baseMatch = [regex]::Match($sectionMatch.Groups['section'].Value, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        if (-not $baseMatch.Success) {
            return [pscustomobject]@{ Exists = $true; BaseUrl = $null; Error = 'base_url_missing' }
        }
        $url = if ($baseMatch.Groups['double'].Success) { $baseMatch.Groups['double'].Value } else { $baseMatch.Groups['single'].Value }
        return [pscustomobject]@{ Exists = $true; BaseUrl = $url; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Exists = $true; BaseUrl = $null; Error = 'config_read_error' }
    }
}

function Get-ConfigHttpContract {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Exists = $false; BaseUrl = $null; SupportsWebsockets = $null; WireApi = $null; Error = 'config_missing' } }
    try {
        $content = Get-Content -LiteralPath $Path -Raw
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        if (-not $providerMatch.Success) { return [pscustomobject]@{ Exists = $true; BaseUrl = $null; SupportsWebsockets = $null; WireApi = $null; Error = 'root_model_provider_missing' } }
        $provider = if ($providerMatch.Groups['double'].Success) { $providerMatch.Groups['double'].Value } else { $providerMatch.Groups['single'].Value }
        $sectionMatch = [regex]::Match($content, '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) { return [pscustomobject]@{ Exists = $true; BaseUrl = $null; SupportsWebsockets = $null; WireApi = $null; Error = 'provider_section_missing' } }
        $section = $sectionMatch.Groups['section'].Value
        $baseMatch = [regex]::Match($section, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $supportMatch = [regex]::Match($section, '(?im)^\s*supports_websockets\s*=\s*(?<value>true|false)\s*(?:#.*)?$')
        $wireMatch = [regex]::Match($section, '(?im)^\s*wire_api\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        return [pscustomobject]@{
            Exists = $true
            BaseUrl = if ($baseMatch.Success) { if ($baseMatch.Groups['double'].Success) { $baseMatch.Groups['double'].Value } else { $baseMatch.Groups['single'].Value } } else { $null }
            SupportsWebsockets = if ($supportMatch.Success) { $supportMatch.Groups['value'].Value.ToLowerInvariant() -eq 'true' } else { $null }
            WireApi = if ($wireMatch.Success) { if ($wireMatch.Groups['double'].Success) { $wireMatch.Groups['double'].Value } else { $wireMatch.Groups['single'].Value } } else { $null }
            # `supports_websockets` is an optional provider capability in
            # Codex++ configs.  Proxy mode is still fail-closed below because
            # the published route-state must explicitly declare websocket
            # support disabled; a missing config key must not force a config
            # rewrite or block the process-scoped route.
            Error = if (-not $baseMatch.Success) { 'base_url_missing' } elseif (-not $wireMatch.Success) { 'wire_api_missing' } else { $null }
        }
    }
    catch { return [pscustomobject]@{ Exists = $true; BaseUrl = $null; SupportsWebsockets = $null; WireApi = $null; Error = 'config_read_error' } }
}

function Normalize-HeadroomBaseUrl {
    param([Parameter(Mandatory)][string]$Value)
    try {
        $uri = [Uri]$Value.TrimEnd('/')
        if ($uri.Scheme -ne 'http' -or $uri.Host.ToLowerInvariant() -notin @('127.0.0.1', 'localhost', '::1') -or [string]::IsNullOrWhiteSpace($uri.Query) -eq $false -or [string]::IsNullOrWhiteSpace($uri.Fragment) -eq $false -or $uri.AbsolutePath.Trim('/') -ne '') { throw 'invalid_headroom_base_url' }
        return $uri.AbsoluteUri.TrimEnd('/')
    }
    catch { throw 'invalid_headroom_base_url' }
}

function Test-LocalHeadroomUrl {
    param([Parameter(Mandatory)][string]$Value)
    try {
        $uri = [Uri]$Value
        $expected = [Uri]$script:ProxyBaseUrl
        return ($uri.AbsoluteUri.TrimEnd('/') -eq $expected.AbsoluteUri.TrimEnd('/') -and $uri.AbsolutePath.TrimEnd('/') -eq '/v1')
    }
    catch { return $false }
}

function Test-MonitorStatus {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$AllowRelayPending
    )
    $result = Get-JsonEndpoint -Uri $Uri
    if (-not $result.TransportOk) { return [pscustomobject]@{ Ready = $false; Reason = 'monitor_unreachable' } }
    if ($result.StatusCode -ne 200 -or $result.ParseError -or $null -eq $result.Body) { return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_unavailable' } }
    $schema = ConvertTo-StatsNumber (Get-ObjectProperty -Object $result.Body -Name 'schema_version')
    if ($schema -ne 2) { return [pscustomobject]@{ Ready = $false; Reason = 'monitor_schema_incompatible' } }
    $overall = Get-ObjectProperty -Object $result.Body -Name 'overall'
    $itemsProperty = $result.Body.PSObject.Properties['items']
    $metricsProperty = $result.Body.PSObject.Properties['metrics']
    $activeIssuesProperty = $result.Body.PSObject.Properties['active_issues']
    $recentRecoveriesProperty = $result.Body.PSObject.Properties['recent_recoveries']
    $items = $null
    $metrics = $null
    $activeIssues = $null
    $recentRecoveries = $null
    if ($null -ne $itemsProperty) { $items = $itemsProperty.Value }
    if ($null -ne $metricsProperty) { $metrics = $metricsProperty.Value }
    if ($null -ne $activeIssuesProperty) { $activeIssues = $activeIssuesProperty.Value }
    if ($null -ne $recentRecoveriesProperty) { $recentRecoveries = $recentRecoveriesProperty.Value }
    $validStates = @('green', 'yellow', 'red', 'gray')
    $expectedItemKeys = @(
        'gateway-livez',
        'gateway-health',
        'headroom-livez',
        'headroom-health',
        'relay',
        'route',
        'codex-connection',
        'api',
        'transport',
        'kompress',
        'token-accounting',
        'monitor-core'
    )
    if ($overall -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$overall) -or [string]$overall -notin $validStates) {
        return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
    }
    if ($overall -eq 'red' -and -not $AllowRelayPending) {
        return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_red' }
    }
    if ($overall -notin @('green', 'yellow', 'red')) {
        return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_not_ready' }
    }
    if ($items -isnot [System.Array] -or $items.Count -ne $expectedItemKeys.Count) {
        return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
    }
    for ($index = 0; $index -lt $expectedItemKeys.Count; $index++) {
        $item = $items[$index]
        if ($null -eq $item -or $item -isnot [pscustomobject]) {
            return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
        }
        foreach ($name in @('key', 'label', 'state', 'summary', 'detail', 'source')) {
            $property = $item.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
            }
        }
        $observedAtProperty = $item.PSObject.Properties['observed_at']
        if ($null -eq $observedAtProperty -or $null -eq $observedAtProperty.Value) {
            return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
        }
        if ([string]$item.key -ne $expectedItemKeys[$index] -or [string]$item.state -notin $validStates) {
            return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
        }
        $itemObservedAt = ConvertTo-UtcDateTime -Value $observedAtProperty.Value
        if ($null -eq $itemObservedAt) {
            return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
        }
    }
    if ($null -eq $metrics -or $metrics -isnot [pscustomobject] -or $activeIssues -isnot [System.Array] -or $recentRecoveries -isnot [System.Array]) {
        return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_invalid' }
    }
    $generatedAt = $null
    $staleAfter = ConvertTo-StatsNumber (Get-ObjectProperty -Object $result.Body -Name 'stale_after_seconds')
    $generatedAt = ConvertTo-UtcDateTime -Value (Get-ObjectProperty -Object $result.Body -Name 'generated_at')
    if ($staleAfter -le 0 -or $null -eq $generatedAt) { return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_contract_incomplete' } }
    $nowUtc = [DateTime]::UtcNow
    if ($generatedAt -gt $nowUtc.AddSeconds(5) -or $generatedAt -lt $nowUtc.AddSeconds(-1 * $staleAfter)) { return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_stale' } }
    if ($overall -in @('green', 'yellow') -or ($AllowRelayPending -and $overall -eq 'red')) {
        return [pscustomobject]@{ Ready = $true; Reason = if ($overall -eq 'red') { 'prelaunch_monitor_status_red' } else { 'ok' } }
    }
    return [pscustomobject]@{ Ready = $false; Reason = 'monitor_status_not_ready' }
}

function Test-HealthSnapshot {
    param(
        [Parameter(Mandatory)][object]$Livez,
        [Parameter(Mandatory)][object]$Health
    )

    if (-not $Livez.TransportOk -or $Livez.StatusCode -ne 200 -or $Livez.ParseError -or $null -eq $Livez.Body) {
        return [pscustomobject]@{ Ready = $false; Reason = 'livez_unavailable' }
    }
    if ($Livez.Body.service -ne 'headroom-proxy' -or $Livez.Body.status -ne 'healthy' -or $Livez.Body.alive -ne $true) {
        return [pscustomobject]@{ Ready = $false; Reason = 'livez_unhealthy' }
    }
    if (-not $Health.TransportOk -or $Health.StatusCode -ne 200 -or $Health.ParseError -or $null -eq $Health.Body) {
        return [pscustomobject]@{ Ready = $false; Reason = 'health_unavailable' }
    }
    if ($Health.Body.service -ne 'headroom-proxy' -or $Health.Body.status -ne 'healthy' -or $Health.Body.ready -ne $true) {
        return [pscustomobject]@{ Ready = $false; Reason = 'health_unready' }
    }
    $config = $Health.Body.PSObject.Properties['config']
    $relay = if ($config) { $Health.Body.config.PSObject.Properties['openai_api_url'] } else { $null }
    $expectedRelay = 'http://' + $script:RelayHost + ':' + $script:RelayPort
    if (-not $relay -or [string]$relay.Value -ne $expectedRelay) {
        return [pscustomobject]@{ Ready = $false; Reason = 'relay_config_invalid' }
    }
    $checks = $Health.Body.PSObject.Properties['checks']
    $kompress = if ($checks) { $Health.Body.checks.PSObject.Properties['kompress'] } else { $null }
    if ($null -eq $kompress -or $Health.Body.checks.kompress.enabled -ne $true -or $Health.Body.checks.kompress.ready -ne $true -or [string]$Health.Body.checks.kompress.status -eq 'deferred' -or [string](Get-ObjectProperty -Object (Get-ObjectProperty -Object $Health.Body.checks.kompress -Name 'info') -Name 'source_status') -eq 'deferred') {
        return [pscustomobject]@{ Ready = $false; Reason = 'kompress_not_ready' }
    }
    return [pscustomobject]@{ Ready = $true; Reason = 'healthy' }
}

function Test-GatewayReadinessContract {
    param(
        [Parameter(Mandatory)][object]$Live,
        [Parameter(Mandatory)][object]$Health,
        [switch]$AllowRelayPending
    )

    $liveReady = $Live.TransportOk -and $Live.StatusCode -eq 200 -and -not $Live.ParseError -and $null -ne $Live.Body -and (Get-ObjectProperty -Object $Live.Body -Name 'alive') -eq $true
    $healthReady = $Health.TransportOk -and $Health.StatusCode -eq 200 -and -not $Health.ParseError -and $null -ne $Health.Body -and (Get-ObjectProperty -Object $Health.Body -Name 'ready') -eq $true
    if ($liveReady -and $healthReady) { return $true }
    if (-not $AllowRelayPending -or -not $liveReady) { return $false }

    # The only pre-client degraded state we accept is a live Gateway whose
    # Headroom dependency is healthy and whose helper TCP/HTTP probe has no
    # status code because port 57321 is not listening yet.
    $checks = Get-ObjectProperty -Object $Health.Body -Name 'checks'
    $headroom = Get-ObjectProperty -Object $checks -Name 'headroom'
    $helper = Get-ObjectProperty -Object $checks -Name 'helper'
    return (
        $Health.TransportOk -and $Health.StatusCode -eq 503 -and -not $Health.ParseError -and $null -ne $Health.Body -and
        [string](Get-ObjectProperty -Object $Health.Body -Name 'service') -eq 'policy-gateway' -and
        [string](Get-ObjectProperty -Object $Health.Body -Name 'status') -eq 'degraded' -and
        (Get-ObjectProperty -Object $Health.Body -Name 'ready') -eq $false -and
        (Get-ObjectProperty -Object $headroom -Name 'ok') -eq $true -and
        (Get-ObjectProperty -Object $helper -Name 'ok') -eq $false -and
        $null -eq (Get-ObjectProperty -Object $helper -Name 'status_code')
    )
}

function Get-RouteModeFromSettings {
    $settingsPath = $RouteSettingsPath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return 'unknown' }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $activeId = [string]$settings.activeRelayId
        $profile = @($settings.relayProfiles | Where-Object { [string]$_.id -eq $activeId })
        if ($profile.Count -ne 1) { return 'unknown' }
        $mode = ([string]$profile[0].relayMode).Trim().ToLowerInvariant()
        $officialMixApiKey = Get-ObjectProperty -Object $profile[0] -Name 'officialMixApiKey'
        if ($mode -eq 'official' -and $officialMixApiKey -ne $true) { return 'official' }
        if ($mode -in @('pureapi', 'mixedapi', 'aggregate')) { return 'proxy' }
        return 'unknown'
    }
    catch { return 'unknown' }
}

function Invoke-RouteKeeper {
    param([switch]$AllowRelayPending)
    if (-not (Test-Path -LiteralPath $RouteKeeperPath -PathType Leaf)) {
        Write-Audit -Level ERROR -Event 'route_keeper_missing' -Fields @{ path = $RouteKeeperPath }
        return $false
    }
    try {
        $beforeConfigHash = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash } else { '' }
        $keeperArguments = @(
            '-ConfigPath', $ConfigPath,
            '-SettingsPath', $RouteSettingsPath,
            '-ProxyBaseUrl', $script:ProxyBaseUrl,
            '-PythonPath', $runtimePythonPath,
            '-StatePath', $RouteStatePath,
            '-ReadySignalPath', $RouteReadySignalPath,
            '-WatchStatePath', $RouteWatchStatePath,
            '-Mode', $script:EffectiveRouteMode
        )
        if ($AllowRelayPending) { $keeperArguments += '-AllowRelayPending' }
        $keeperOutput = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $RouteKeeperPath @keeperArguments 2>&1)
        $status = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        $outputText = [string]::Join(' ', @($keeperOutput | ForEach-Object { ConvertTo-SafeText $_ }))
        if ($outputText.Length -gt 600) { $outputText = $outputText.Substring(0, 597) + '...' }
        $afterConfigHash = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash } else { '' }
        $script:RouteConfigHash = $afterConfigHash
        $script:RouteConfigMutated = ($beforeConfigHash -ne $afterConfigHash)
        if ($script:RouteConfigMutated) {
            Write-Audit -Level ERROR -Event 'route_config_mutation_detected' -Fields @{ config = $ConfigPath; before_hash = $beforeConfigHash; after_hash = $afterConfigHash; error_code = 'route_config_mutation_detected'; stage = 'route_keeper' }
            return $false
        }
        if ($status -eq 0 -and (Test-Path -LiteralPath $RouteStatePath -PathType Leaf)) {
            $routeState = Get-Content -LiteralPath $RouteStatePath -Raw | ConvertFrom-Json
            $script:ProcessRouteBaseUrl = [string](Get-ObjectProperty -Object $routeState -Name 'process_route_base_url')
            if ([string]::IsNullOrWhiteSpace($script:ProcessRouteBaseUrl) -and $script:EffectiveRouteMode -eq 'official') {
                $script:ProcessRouteBaseUrl = [string](Get-ConfigBaseUrl -Path $ConfigPath).BaseUrl
            }
            if ($script:EffectiveRouteMode -eq 'proxy' -and $script:ProcessRouteBaseUrl -ne $script:ProxyBaseUrl) {
                Write-Audit -Level ERROR -Event 'process_route_missing' -Fields @{ expected = $script:ProxyBaseUrl; actual = $script:ProcessRouteBaseUrl; error_code = 'process_route_missing'; stage = 'route_keeper' }
                return $false
            }
        }
        Write-Audit -Level $(if ($status -eq 0) { 'INFO' } else { 'ERROR' }) -Event 'route_keeper_completed' -Fields @{ exit_code = $status; mode = $script:EffectiveRouteMode; config = $ConfigPath; config_hash = $afterConfigHash; config_mutated = $script:RouteConfigMutated; process_route = $script:ProcessRouteBaseUrl; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port; output = $outputText; error_code = if ($status -eq 0) { '' } else { 'route_keeper_failed' }; stage = 'route_keeper' }
        return ($status -eq 0 -and -not $script:RouteConfigMutated)
    }
    catch {
        Write-Audit -Level ERROR -Event 'route_keeper_error' -Fields @{ message = $_.Exception.Message; mode = $RouteMode; error_code = 'route_keeper_invocation_error'; stage = 'route_keeper' }
        return $false
    }
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

function Test-RouteReadyState {
    param(
        [switch]$RequireSignal,
        [switch]$AllowRelayPending
    )
    $statePath = $RouteStatePath
    $signalPath = $RouteReadySignalPath
    $watchPid = $null
    try {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }
        if ($RequireSignal -and -not (Test-ReadySignalContent -Path $signalPath)) { return $false }
        if ($RequireSignal) {
            $signalFresh = ((Get-Item -LiteralPath $signalPath).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(-90))
            if (-not $signalFresh) { return $false }
            if (-not (Test-Path -LiteralPath $RouteWatchStatePath -PathType Leaf)) { return $false }
            $watchState = Get-Content -LiteralPath $RouteWatchStatePath -Raw | ConvertFrom-Json
            $watchPid = ConvertTo-StatsNumber (Get-ObjectProperty -Object $watchState -Name 'pid')
            if ($null -eq $watchPid -or $watchPid -lt 1 -or [Math]::Floor($watchPid) -ne $watchPid) { return $false }
            $watchProcess = Get-Process -Id ([int]$watchPid) -ErrorAction SilentlyContinue
            if ($null -eq $watchProcess) { return $false }
            if ($watchProcess.ProcessName -notin @('pwsh', 'powershell')) { return $false }
            $watchPath = [string](Get-ObjectProperty -Object $watchState -Name 'route_keeper_path')
            $watchMode = [string](Get-ObjectProperty -Object $watchState -Name 'mode')
            $watchConfig = [string](Get-ObjectProperty -Object $watchState -Name 'config_path')
            $watchSettings = [string](Get-ObjectProperty -Object $watchState -Name 'settings_path')
            $watchSignal = [string](Get-ObjectProperty -Object $watchState -Name 'ready_signal_path')
            $watchProxyBaseUrl = [string](Get-ObjectProperty -Object $watchState -Name 'proxy_base_url')
            if ($watchPath -ne $RouteKeeperPath -or $watchMode -ne $script:EffectiveRouteMode -or $watchConfig -ne $ConfigPath -or $watchSettings -ne $RouteSettingsPath -or $watchSignal -ne $RouteReadySignalPath -or $watchProxyBaseUrl -ne $script:ProxyBaseUrl) { return $false }
            if ($AllowRelayPending -and (Get-ObjectProperty -Object $watchState -Name 'allow_relay_pending') -ne $true) { return $false }
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$watchPid)" -ErrorAction SilentlyContinue
            $commandLine = if ($processInfo) { [string]$processInfo.CommandLine } else { '' }
            $escapedKeeperPath = [regex]::Escape([IO.Path]::GetFullPath($RouteKeeperPath))
            if ($commandLine -notmatch "(?i)$escapedKeeperPath" -or $commandLine -notmatch '(?i)(^|\s)-Watch(\s|$)' -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-Mode' -ExpectedValue $script:EffectiveRouteMode) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ConfigPath' -ExpectedValue $ConfigPath) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-SettingsPath' -ExpectedValue $watchSettings) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ProxyBaseUrl' -ExpectedValue $script:ProxyBaseUrl) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ReadySignalPath' -ExpectedValue $RouteReadySignalPath) -or ($AllowRelayPending -and $commandLine -notmatch '(?i)(^|\s)-AllowRelayPending(\s|$)')) { return $false }
            $watchStartedAt = ConvertTo-UtcDateTime -Value (Get-ObjectProperty -Object $watchState -Name 'started_at_utc')
            if ($null -eq $watchStartedAt) { return $false }
            $processStartedAt = $watchProcess.StartTime.ToUniversalTime()
            if ([Math]::Abs(($processStartedAt - $watchStartedAt).TotalSeconds) -gt 30) { return $false }
            if ($watchStartedAt -gt [DateTime]::UtcNow.AddSeconds(5)) { return $false }
        }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $stateSchema = ConvertTo-StatsNumber (Get-ObjectProperty -Object $state -Name 'schema_version')
        $stateContract = ConvertTo-StatsNumber (Get-ObjectProperty -Object $state -Name 'route_contract_version')
        if ($stateSchema -lt 2 -or $stateContract -lt 2) { return $false }
        $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
        $configContract = Get-ConfigHttpContract -Path $ConfigPath
        if (-not $configContract.Exists -or $configContract.Error -ne $null) { return $false }
        $stateTimestamp = ConvertTo-UtcDateTime -Value (Get-ObjectProperty -Object $state -Name 'timestamp_utc')
        $fresh = $null -ne $stateTimestamp -and $stateTimestamp -le [DateTime]::UtcNow.AddSeconds(5)
        $stateStatus = [string](Get-ObjectProperty -Object $state -Name 'status')
        $pendingState = $AllowRelayPending -and $stateStatus -eq 'pending'
        if ($pendingState -and (Get-ObjectProperty -Object $state -Name 'allow_relay_pending') -ne $true) { return $false }
        if ($script:EffectiveRouteMode -eq 'proxy') {
            if ([string](Get-ObjectProperty -Object $state -Name 'http_mode') -ne 'responses' -or [string](Get-ObjectProperty -Object $state -Name 'wire_api') -ne 'responses' -or (Get-ObjectProperty -Object $state -Name 'supports_websockets') -ne $false) { return $false }
            $processRoute = [string](Get-ObjectProperty -Object $state -Name 'process_route_base_url')
            $routeScope = [string](Get-ObjectProperty -Object $state -Name 'route_scope')
            $configMutated = Get-ObjectProperty -Object $state -Name 'config_mutated'
            if ($processRoute -ne $script:ProxyBaseUrl -or $routeScope -ne 'process' -or $configMutated -ne $false -or $configContract.Error -ne $null -or $configContract.WireApi -ne 'responses') { return $false }
        }
        if ([string](Get-ObjectProperty -Object $state -Name 'config_sha256') -ne $configHash) { return $false }
        $stateKeeperPid = ConvertTo-StatsNumber (Get-ObjectProperty -Object $state -Name 'route_keeper_pid')
        $stateKeeperMode = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_mode')
        if (-not $RequireSignal -and $stateStatus -eq 'official-bypass') {
            $officialFresh = $fresh -and $stateTimestamp -ge [DateTime]::UtcNow.AddSeconds(-1 * $script:OfficialBypassFreshnessSeconds)
            if ($stateKeeperMode -ne 'once' -or [string](Get-ObjectProperty -Object $state -Name 'mode') -ne 'official' -or (Get-RouteModeFromSettings) -ne 'official' -or $null -eq $stateKeeperPid -or $stateKeeperPid -lt 1 -or [Math]::Floor($stateKeeperPid) -ne $stateKeeperPid -or [string](Get-ObjectProperty -Object $state -Name 'route_keeper_proxy_base_url') -ne $script:ProxyBaseUrl) { return $false }
            $stateKeeperPath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_script_path')
            if ([string]::IsNullOrWhiteSpace($stateKeeperPath) -or -not [IO.Path]::GetFullPath($stateKeeperPath).Equals([IO.Path]::GetFullPath($RouteKeeperPath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
            if ([string](Get-ObjectProperty -Object $state -Name 'route_keeper_config_path') -ne $ConfigPath -or [string](Get-ObjectProperty -Object $state -Name 'route_keeper_settings_path') -ne $RouteSettingsPath -or [string](Get-ObjectProperty -Object $state -Name 'route_keeper_ready_signal_path') -ne $RouteReadySignalPath) { return $false }
            return $officialFresh
        }
        if ($RequireSignal -and ($null -eq $stateKeeperPid -or $stateKeeperPid -ne $watchPid)) { return $false }
        $stateKeeperPath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_script_path')
        $stateKeeperMode = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_mode')
        $stateConfigPath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_config_path')
        $stateSettingsPath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_settings_path')
        $stateSignalPath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_ready_signal_path')
        if ($stateStatus -notin @('ready', 'official-bypass') -and -not $pendingState) { return $false }
        if ($null -eq $stateKeeperPid -or $stateKeeperPid -lt 1 -or [Math]::Floor($stateKeeperPid) -ne $stateKeeperPid -or [string]::IsNullOrWhiteSpace($stateKeeperPath)) { return $false }
        if (-not [IO.Path]::GetFullPath($stateKeeperPath).Equals([IO.Path]::GetFullPath($RouteKeeperPath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($stateKeeperMode -ne 'watch' -or $stateConfigPath -ne $ConfigPath -or $stateSettingsPath -ne $RouteSettingsPath -or $stateSignalPath -ne $RouteReadySignalPath -or [string](Get-ObjectProperty -Object $state -Name 'route_keeper_proxy_base_url') -ne $script:ProxyBaseUrl) { return $false }
        $stateKeeperProcess = Get-Process -Id ([int]$stateKeeperPid) -ErrorAction SilentlyContinue
        if ($null -eq $stateKeeperProcess) { return $false }
        $stateKeeperStartedAt = ConvertTo-UtcDateTime -Value (Get-ObjectProperty -Object $state -Name 'route_keeper_started_at')
        if ($null -eq $stateKeeperStartedAt) { return $false }
        if ($stateKeeperStartedAt -gt [DateTime]::UtcNow.AddSeconds(5) -or $stateKeeperStartedAt -le [DateTime]::UtcNow.AddSeconds(-120) -or [Math]::Abs(($stateKeeperProcess.StartTime.ToUniversalTime() - $stateKeeperStartedAt).TotalSeconds) -gt 30) { return $false }
        $stateKeeperInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$stateKeeperPid)" -ErrorAction SilentlyContinue
        $stateKeeperCommand = if ($stateKeeperInfo) { [string]$stateKeeperInfo.CommandLine } else { '' }
        if ([string]::IsNullOrWhiteSpace($stateKeeperCommand) -or $stateKeeperCommand -notmatch ('(?i)' + [regex]::Escape([IO.Path]::GetFullPath($RouteKeeperPath))) -or $stateKeeperCommand -notmatch '(?i)(^|\s)-Watch(\s|$)' -or -not (Test-CommandLineParameter -CommandLine $stateKeeperCommand -Name '-Mode' -ExpectedValue 'proxy') -or -not (Test-CommandLineParameter -CommandLine $stateKeeperCommand -Name '-ConfigPath' -ExpectedValue $ConfigPath) -or -not (Test-CommandLineParameter -CommandLine $stateKeeperCommand -Name '-SettingsPath' -ExpectedValue $stateSettingsPath) -or -not (Test-CommandLineParameter -CommandLine $stateKeeperCommand -Name '-ProxyBaseUrl' -ExpectedValue $script:ProxyBaseUrl) -or -not (Test-CommandLineParameter -CommandLine $stateKeeperCommand -Name '-ReadySignalPath' -ExpectedValue $RouteReadySignalPath)) { return $false }
        return $fresh
    }
    catch { return $false }
}

function Remove-StaleRouteEvidence {
    foreach ($path in @($RouteStatePath, $RouteReadySignalPath)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Stop-RouteKeeperWatch {
    $targets = [System.Collections.Generic.List[int]]::new()
    try {
        if (Test-Path -LiteralPath $RouteWatchStatePath -PathType Leaf) {
            $state = Get-Content -LiteralPath $RouteWatchStatePath -Raw | ConvertFrom-Json
            $statePath = [string](Get-ObjectProperty -Object $state -Name 'route_keeper_path')
            $stateMode = [string](Get-ObjectProperty -Object $state -Name 'mode')
            $stateConfig = [string](Get-ObjectProperty -Object $state -Name 'config_path')
            $stateSettings = [string](Get-ObjectProperty -Object $state -Name 'settings_path')
            $stateSignal = [string](Get-ObjectProperty -Object $state -Name 'ready_signal_path')
            $stateProxyBaseUrl = [string](Get-ObjectProperty -Object $state -Name 'proxy_base_url')
            $pidValue = ConvertTo-StatsNumber (Get-ObjectProperty -Object $state -Name 'pid')
            $stateMatches = $statePath.Equals($RouteKeeperPath, [StringComparison]::OrdinalIgnoreCase) -and $stateMode -eq 'proxy' -and $stateConfig -eq $ConfigPath -and $stateSettings -eq $RouteSettingsPath -and $stateSignal -eq $RouteReadySignalPath -and $stateProxyBaseUrl -eq $script:ProxyBaseUrl
            if ($stateMatches -and $null -ne $pidValue -and [Math]::Floor($pidValue) -eq $pidValue) { [void]$targets.Add([int]$pidValue) }
        }
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $commandLine = [string](Get-ObjectProperty -Object $_ -Name 'CommandLine')
            $commandLine -match ('(?i)' + [regex]::Escape([IO.Path]::GetFullPath($RouteKeeperPath))) -and $commandLine -match '(?i)(^|\s)-Watch(\s|$)' -and (Test-CommandLineParameter -CommandLine $commandLine -Name '-Mode' -ExpectedValue 'proxy') -and (Test-CommandLineParameter -CommandLine $commandLine -Name '-ConfigPath' -ExpectedValue $ConfigPath) -and (Test-CommandLineParameter -CommandLine $commandLine -Name '-SettingsPath' -ExpectedValue $RouteSettingsPath) -and (Test-CommandLineParameter -CommandLine $commandLine -Name '-ProxyBaseUrl' -ExpectedValue $script:ProxyBaseUrl) -and (Test-CommandLineParameter -CommandLine $commandLine -Name '-ReadySignalPath' -ExpectedValue $RouteReadySignalPath)
        })
        foreach ($processInfo in $processes) {
            $candidatePid = ConvertTo-StatsNumber (Get-ObjectProperty -Object $processInfo -Name 'ProcessId')
            if ($null -ne $candidatePid -and [Math]::Floor($candidatePid) -eq $candidatePid -and -not $targets.Contains([int]$candidatePid)) { [void]$targets.Add([int]$candidatePid) }
        }
        foreach ($targetPid in @($targets)) {
            $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
            if ($null -eq $process -or $process.ProcessName -notin @('pwsh', 'powershell')) { continue }
            $info = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
            $commandLine = if ($info) { [string](Get-ObjectProperty -Object $info -Name 'CommandLine') } else { '' }
            if ($commandLine -notmatch ('(?i)' + [regex]::Escape([IO.Path]::GetFullPath($RouteKeeperPath))) -or $commandLine -notmatch '(?i)(^|\s)-Watch(\s|$)' -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-Mode' -ExpectedValue 'proxy') -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ConfigPath' -ExpectedValue $ConfigPath) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-SettingsPath' -ExpectedValue $RouteSettingsPath) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ProxyBaseUrl' -ExpectedValue $script:ProxyBaseUrl) -or -not (Test-CommandLineParameter -CommandLine $commandLine -Name '-ReadySignalPath' -ExpectedValue $RouteReadySignalPath)) { continue }
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ([DateTime]::UtcNow -lt $deadline -and $null -ne (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 100 }
            if ($null -ne (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) { throw 'route_keeper_watch_stop_timeout' }
        }
        if (Test-Path -LiteralPath $RouteWatchStatePath -PathType Leaf) {
            $remaining = Get-Content -LiteralPath $RouteWatchStatePath -Raw | ConvertFrom-Json
            $remainingPid = ConvertTo-StatsNumber (Get-ObjectProperty -Object $remaining -Name 'pid')
            if ($null -ne $remainingPid -and $targets.Contains([int]$remainingPid)) { Remove-Item -LiteralPath $RouteWatchStatePath -Force -ErrorAction Stop }
        }
        return $true
    }
    catch {
        Write-Audit -Level ERROR -Event 'route_keeper_watch_stop_error' -Fields @{ message = $_.Exception.Message }
        return $false
    }
}

function Start-RouteKeeperWatch {
    param([switch]$AllowRelayPending)
    $watch = $null
    if (-not (Test-Path -LiteralPath $RouteKeeperPath -PathType Leaf)) {
        Write-Audit -Level ERROR -Event 'route_keeper_watch_missing' -Fields @{ path = $RouteKeeperPath }
        return $false
    }
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = 'pwsh.exe'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        [void]$info.ArgumentList.Add('-NoLogo')
        [void]$info.ArgumentList.Add('-NoProfile')
        [void]$info.ArgumentList.Add('-WindowStyle')
        [void]$info.ArgumentList.Add('Hidden')
        [void]$info.ArgumentList.Add('-ExecutionPolicy')
        [void]$info.ArgumentList.Add('Bypass')
        [void]$info.ArgumentList.Add('-File')
        [void]$info.ArgumentList.Add($RouteKeeperPath)
        [void]$info.ArgumentList.Add('-Watch')
        [void]$info.ArgumentList.Add('-Mode')
        [void]$info.ArgumentList.Add($script:EffectiveRouteMode)
        [void]$info.ArgumentList.Add('-ConfigPath')
        [void]$info.ArgumentList.Add($ConfigPath)
        [void]$info.ArgumentList.Add('-SettingsPath')
        [void]$info.ArgumentList.Add($RouteSettingsPath)
        [void]$info.ArgumentList.Add('-PythonPath')
        [void]$info.ArgumentList.Add($runtimePythonPath)
        [void]$info.ArgumentList.Add('-ProxyBaseUrl')
        [void]$info.ArgumentList.Add($script:ProxyBaseUrl)
        [void]$info.ArgumentList.Add('-StatePath')
        [void]$info.ArgumentList.Add($RouteStatePath)
        [void]$info.ArgumentList.Add('-ReadySignalPath')
        [void]$info.ArgumentList.Add($RouteReadySignalPath)
        [void]$info.ArgumentList.Add('-WatchStatePath')
        [void]$info.ArgumentList.Add($RouteWatchStatePath)
        if ($AllowRelayPending) { [void]$info.ArgumentList.Add('-AllowRelayPending') }

        $watch = [Diagnostics.Process]::Start($info)
        if ($null -eq $watch) { return $false }
        $watchParent = Split-Path -Parent $RouteWatchStatePath
        if (-not (Test-Path -LiteralPath $watchParent)) { [IO.Directory]::CreateDirectory($watchParent) | Out-Null }
        $watchDocument = [ordered]@{ schema_version = 3; route_contract_version = 3; route_scope = 'process'; http_mode = if ($script:EffectiveRouteMode -eq 'proxy') { 'responses' } else { 'direct' }; supports_websockets = if ($script:EffectiveRouteMode -eq 'proxy') { $false } else { $null }; process_route_base_url = $script:ProcessRouteBaseUrl; config_mutated = $false; pid = $watch.Id; started_at_utc = [DateTime]::UtcNow.ToString('o'); timestamp_utc = [DateTime]::UtcNow.ToString('o'); stage = 'watch'; route_keeper_path = $RouteKeeperPath; mode = $script:EffectiveRouteMode; config_path = $ConfigPath; settings_path = $RouteSettingsPath; proxy_base_url = $script:ProxyBaseUrl; ready_signal_path = $RouteReadySignalPath; watch_state_path = $RouteWatchStatePath; allow_relay_pending = [bool]$AllowRelayPending }
        $watchTemp = Join-Path $watchParent ('.route-watch-' + [IO.Path]::GetRandomFileName())
        [IO.File]::WriteAllText($watchTemp, (($watchDocument | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $RouteWatchStatePath -PathType Leaf) {
            $watchBackup = Join-Path $watchParent ('.route-watch-backup-' + [IO.Path]::GetRandomFileName())
            try { [IO.File]::Replace($watchTemp, $RouteWatchStatePath, $watchBackup, $true) } finally { if (Test-Path -LiteralPath $watchBackup -PathType Leaf) { Remove-Item -LiteralPath $watchBackup -Force -ErrorAction SilentlyContinue } }
        } else { [IO.File]::Move($watchTemp, $RouteWatchStatePath) }
        Write-Audit -Level INFO -Event 'route_keeper_watch_started' -Fields @{ pid = $watch.Id; mode = $script:EffectiveRouteMode; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port; stage = 'watch' }
        return $true
    }
    catch {
        if ($null -ne $watch) { try { if (-not $watch.HasExited) { Stop-Process -Id $watch.Id -Force -ErrorAction SilentlyContinue } } catch { } }
        Write-Audit -Level ERROR -Event 'route_keeper_watch_error' -Fields @{ message = $_.Exception.Message; mode = $script:EffectiveRouteMode; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port; error_code = 'route_keeper_watch_error'; stage = 'watch' }
        return $false
    }
}

function Invoke-Ensure {
    if ($SkipEnsure) {
        Write-Audit -Level INFO -Event 'ensure_skipped'
        return $true
    }
    if (-not (Test-Path -LiteralPath $EnsureScript -PathType Leaf)) {
        Write-Audit -Level ERROR -Event 'ensure_missing' -Fields @{ path = $EnsureScript }
        return $false
    }

    try {
        $gatewayPort = 18787
        $headroomPort = 18789
        try { $gatewayPort = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port } catch { $gatewayPort = 18787 }
        try { $headroomPort = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port } catch { $headroomPort = 18789 }
        $ensureLog = Join-Path $runtimeLogRoot 'codexpp-ensure-debug.log'
        [System.IO.File]::AppendAllText($ensureLog, "Invoke-Ensure: starting`n")
        & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $EnsureScript -Port $gatewayPort -HeadroomPort $headroomPort -PythonPath $runtimePythonPath -RuntimeStateRoot $runtimeStateRoot -RuntimeLogRoot $runtimeLogRoot -KompressEndpoint $BrokerBaseUrl 2>&1 | ForEach-Object { [System.IO.File]::AppendAllText($ensureLog, "  $_`n") }
        $status = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        [System.IO.File]::AppendAllText($ensureLog, "Invoke-Ensure: exited with $status`n")
        Write-Audit -Level INFO -Event 'ensure_completed' -Fields @{ exit_code = $status; gateway = $GatewayBaseUrl; gateway_port = $gatewayPort; headroom = $HeadroomBaseUrl; headroom_port = $headroomPort; stage = 'ensure' }
        if ($status -ne 0) {
            Write-Audit -Level ERROR -Event 'ensure_failed' -Fields @{ exit_code = $status; gateway = $GatewayBaseUrl; gateway_port = $gatewayPort; headroom = $HeadroomBaseUrl; headroom_port = $headroomPort; error_code = 'ensure_failed'; stage = 'ensure' }
            return $false
        }
        return $true
    }
    catch {
        Write-Audit -Level ERROR -Event 'ensure_error' -Fields @{ message = $_.Exception.Message }
        return $false
    }
}

function Wait-Readiness {
    param(
        [Parameter(Mandatory)][string]$ExpectedBaseUrl,
        [switch]$AllowRelayPending
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    $lastReason = 'not_checked'
    do {
        $config = Get-ConfigBaseUrl -Path $ConfigPath
        $root = Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl
        $brokerRoot = Normalize-HeadroomBaseUrl -Value $BrokerBaseUrl
        $gatewayRoot = Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl
        $broker = Get-JsonEndpoint -Uri ($brokerRoot + '/readyz')
        $gatewayLive = Get-JsonEndpoint -Uri ($gatewayRoot + '/livez')
        $gatewayHealth = Get-JsonEndpoint -Uri ($gatewayRoot + '/health')
        $livez = Get-JsonEndpoint -Uri ($root + '/livez')
        $health = Get-JsonEndpoint -Uri ($root + '/health')
        $healthState = Test-HealthSnapshot -Livez $livez -Health $health
        $brokerReady = $broker.TransportOk -and $broker.StatusCode -eq 200 -and $null -ne $broker.Body -and $broker.Body.ready -eq $true -and [string]$broker.Body.service -eq 'kompress-broker' -and -not [string]::IsNullOrWhiteSpace([string]$broker.Body.provider) -and -not [string]::IsNullOrWhiteSpace([string]$broker.Body.backend)
        $gatewayReady = Test-GatewayReadinessContract -Live $gatewayLive -Health $gatewayHealth -AllowRelayPending:$AllowRelayPending
        $monitorState = if ($script:EffectiveRouteMode -eq 'proxy') { Test-MonitorStatus -Uri $script:MonitorStatusUrl -AllowRelayPending:$AllowRelayPending } else { [pscustomobject]@{ Ready = $true; Reason = 'not-required' } }
        $configReady = ($config.Exists -and $config.Error -eq $null -and -not [string]::IsNullOrWhiteSpace([string]$config.BaseUrl))
        if ($script:EffectiveRouteMode -eq 'proxy') {
            $configReady = $configReady -and $script:ProcessRouteBaseUrl -eq $ExpectedBaseUrl -and -not $script:RouteConfigMutated -and (Test-RouteReadyState -AllowRelayPending:$AllowRelayPending)
        }
        else {
            $configReady = $configReady -and $config.BaseUrl -eq $ExpectedBaseUrl
        }
        if ($brokerReady -and $gatewayReady -and $healthState.Ready -and $configReady -and $monitorState.Ready) {
            Write-Audit -Level INFO -Event 'readiness_passed' -Fields @{ base_url = $config.BaseUrl; config = $ConfigPath; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri]$root).Port; monitor_port = ([Uri](Normalize-HeadroomBaseUrl -Value $MonitorBaseUrl)).Port; relay_pending_allowed = [bool]$AllowRelayPending; stage = 'readiness' }
            return $true
        }
        $lastReason = if (-not $brokerReady) { 'broker_not_ready' } elseif (-not $gatewayReady) { 'gateway_not_ready' } elseif (-not $configReady) { "config_$($config.Error ?? 'base_url_mismatch')" } elseif (-not $monitorState.Ready) { [string]$monitorState.Reason } else { [string]$healthState.Reason }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    Write-Audit -Level ERROR -Event 'readiness_failed' -Fields @{ reason = $lastReason; config = $ConfigPath; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port; monitor_port = ([Uri](Normalize-HeadroomBaseUrl -Value $MonitorBaseUrl)).Port; error_code = 'readiness_failed'; stage = 'readiness' }
    return $false
}

function Get-Win32ErrorCode {
    param([Parameter(Mandatory)][object]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    if ($exception -is [ComponentModel.Win32Exception]) {
        return [int]$exception.NativeErrorCode
    }
    return 0
}

function Test-ElevationRequiredError {
    param([Parameter(Mandatory)][object]$ErrorRecord)

    $nativeCode = Get-Win32ErrorCode -ErrorRecord $ErrorRecord
    if ($nativeCode -eq 740) {
        return $true
    }
    $message = ConvertTo-SafeText $ErrorRecord.Exception.Message
    return ($message -match '(?i)(requires? elevation|operation requires elevation|需要提升)')
}

function Start-RoleProcess {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo)

    try {
        return [Diagnostics.Process]::Start($StartInfo)
    }
    catch {
        if ($Role -notin @('manager', 'codex') -or -not (Test-ElevationRequiredError -ErrorRecord $_)) {
            throw
        }

        $nativeCode = Get-Win32ErrorCode -ErrorRecord $_
        Write-Audit -Level WARN -Event 'elevation_required' -Fields @{ native_error = $nativeCode; method = 'ShellExecute.Verb=runas' }

        $previousHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
        $previousLocale = [Environment]::GetEnvironmentVariable('ELECTRON_DEFAULT_LOCALE', 'Process')
        $previousLang = [Environment]::GetEnvironmentVariable('LANG', 'Process')
        try {
            # ShellExecute/runas does not honor ProcessStartInfo.EnvironmentVariables.
            # Set the parent process environment only for the elevated child launch.
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $CodexHome, 'Process')
            [Environment]::SetEnvironmentVariable('ELECTRON_DEFAULT_LOCALE', 'zh-CN', 'Process')
            [Environment]::SetEnvironmentVariable('LANG', 'zh-CN', 'Process')

            $elevatedInfo = [Diagnostics.ProcessStartInfo]::new()
            $elevatedInfo.FileName = $ExePath
            $elevatedInfo.WorkingDirectory = Split-Path -Parent $ExePath
            $elevatedInfo.UseShellExecute = $true
            $elevatedInfo.Verb = 'runas'
            $elevatedInfo.Arguments = $Arguments
            $elevatedProcess = [Diagnostics.Process]::Start($elevatedInfo)
            if ($null -eq $elevatedProcess) {
                throw 'Elevated Process.Start returned no process.'
            }
            $script:LaunchElevation = 'runas'
            Write-Audit -Level INFO -Event 'launch_elevated_succeeded' -Fields @{ pid = $elevatedProcess.Id; exe = $ExePath; codex_home = $CodexHome; config = $ConfigPath; elevation = 'runas' }
            return $elevatedProcess
        }
        catch {
            Write-Audit -Level ERROR -Event 'launch_elevated_failed' -Fields @{ native_error = (Get-Win32ErrorCode -ErrorRecord $_); message = $_.Exception.Message; elevation = 'runas' }
            throw
        }
        finally {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousHome, 'Process')
            [Environment]::SetEnvironmentVariable('ELECTRON_DEFAULT_LOCALE', $previousLocale, 'Process')
            [Environment]::SetEnvironmentVariable('LANG', $previousLang, 'Process')
        }
    }
}

function Test-ProcessSnapshot {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    $processId = 0
    try {
        $processId = [int]$Process.Id
    }
    catch {
        return [pscustomobject]@{ Known = $false; Alive = $false; ExitCode = $null; Reason = 'pid_unavailable' }
    }

    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            $exitCode = $null
            try { $exitCode = [int]$Process.ExitCode } catch { }
            return [pscustomobject]@{ Known = $true; Alive = $false; ExitCode = $exitCode; Reason = 'process_exited' }
        }
        return [pscustomobject]@{ Known = $true; Alive = $true; ExitCode = $null; Reason = 'process_running' }
    }
    catch {
        # Elevated GUI processes can reject reads through the original Process object.
        try {
            [void](Get-Process -Id $processId -ErrorAction Stop)
            return [pscustomobject]@{ Known = $true; Alive = $true; ExitCode = $null; Reason = 'process_lookup_alive' }
        }
        catch {
            return [pscustomobject]@{ Known = $false; Alive = $false; ExitCode = $null; Reason = 'process_not_observable' }
        }
    }
}

function Test-RelayPort {
    $client = $null
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $connect = $client.ConnectAsync($script:RelayHost, $script:RelayPort)
        if (-not $connect.Wait(500)) {
            return $false
        }
        return ($connect.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Wait-CodexProcessReadiness {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    $routeStatePath = $RouteStatePath
    try {
        if (Test-Path -LiteralPath $routeStatePath -PathType Leaf) {
            $routeState = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json
            $routeHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
            $routeTimestamp = ConvertTo-UtcDateTime -Value (Get-ObjectProperty -Object $routeState -Name 'timestamp_utc')
            $routeFresh = $null -ne $routeTimestamp -and $routeTimestamp -gt [DateTime]::UtcNow.AddSeconds(-90) -and $routeTimestamp -le [DateTime]::UtcNow.AddSeconds(5)
            if ([string](Get-ObjectProperty -Object $routeState -Name 'status') -eq 'official-bypass' -and [string](Get-ObjectProperty -Object $routeState -Name 'config_sha256') -eq $routeHash -and $routeFresh) {
                Write-Audit -Level INFO -Event 'launch_readiness_passed' -Fields @{ reason = 'official_bypass'; pid = $Process.Id }
                return $true
            }
        }
    }
    catch {
        # Continue with strict Relay readiness when route state cannot be read.
    }

    $processId = 0
    try { $processId = [int]$Process.Id } catch { }
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    $lastReason = 'not_checked'
    do {
        $snapshot = Test-ProcessSnapshot -Process $Process
        if ($snapshot.Known -and -not $snapshot.Alive) {
            Write-Audit -Level ERROR -Event 'launch_readiness_failed' -Fields @{ reason = $snapshot.Reason; pid = $processId; process_known = $snapshot.Known; process_alive = $snapshot.Alive; exit_code = $snapshot.ExitCode; relay = ($script:RelayHost + ':' + $script:RelayPort) }
            return $false
        }

        if ($snapshot.Known -and $snapshot.Alive -and (Test-RelayPort)) {
            Write-Audit -Level INFO -Event 'launch_readiness_passed' -Fields @{ pid = $processId; relay = ($script:RelayHost + ':' + $script:RelayPort) }
            return $true
        }

        $lastReason = if (-not $snapshot.Known) { $snapshot.Reason } else { 'relay_unavailable' }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    Write-Audit -Level ERROR -Event 'launch_readiness_failed' -Fields @{ reason = $lastReason; pid = $processId; process_known = $snapshot.Known; process_alive = $snapshot.Alive; exit_code = $snapshot.ExitCode; relay = ($script:RelayHost + ':' + $script:RelayPort) }
    return $false
}

$script:LaunchElevation = 'none'
Write-Audit -Level INFO -Event 'bootstrap_start' -Fields @{ exe = $ExePath; config = $ConfigPath; codex_home = $CodexHome; gateway = $GatewayBaseUrl; headroom = $HeadroomBaseUrl; monitor = $MonitorBaseUrl; arguments_present = (-not [string]::IsNullOrWhiteSpace($Arguments)) }

try {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        Write-Audit -Level ERROR -Event 'executable_missing' -Fields @{ exe = $ExePath }
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'executable_missing' -Stage 'bootstrap' -Reason "executable missing: $ExePath"
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Audit -Level ERROR -Event 'config_missing' -Fields @{ config = $ConfigPath }
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'config_missing' -Stage 'bootstrap' -Reason "config missing: $ConfigPath"
    }
    if (-not (Test-RelayPendingRoleContract -Role $Role -AllowRelayPending:$AllowRelayPending -ReadinessOnly:$ReadinessOnly)) {
        Write-Audit -Level ERROR -Event 'pending_mode_invalid' -Fields @{ role = $Role; readiness_only = [bool]$ReadinessOnly }
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'pending_mode_invalid' -Stage 'bootstrap' -Reason 'AllowRelayPending is restricted to manager or codex launch and is unavailable for ReadinessOnly'
    }

    $settingsRouteMode = Get-RouteModeFromSettings
    $script:EffectiveRouteMode = if ($RouteMode -eq 'auto') { $settingsRouteMode } else { $RouteMode }
    if ($script:EffectiveRouteMode -notin @('official', 'proxy')) {
        Write-Audit -Level ERROR -Event 'route_mode_unknown' -Fields @{ requested = $RouteMode; detected = $settingsRouteMode }
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_mode_unknown' -Stage 'route' -Reason "route mode is unavailable (requested=$RouteMode detected=$settingsRouteMode)"
    }

    $script:ProxyBaseUrl = (Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl).TrimEnd('/') + '/v1'
    $script:MonitorStatusUrl = (Normalize-HeadroomBaseUrl -Value $MonitorBaseUrl).TrimEnd('/') + '/status'
    $script:ExpectedBaseUrl = if ($script:EffectiveRouteMode -eq 'proxy') { $script:ProxyBaseUrl } else { (Get-ConfigBaseUrl -Path $ConfigPath).BaseUrl }
    if ($script:EffectiveRouteMode -eq 'proxy' -and -not (Invoke-Ensure)) {
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'ensure_failed' -Stage 'ensure' -Reason 'Headroom or policy gateway ensure failed'
    }

    $officialBypass = $false
    $routeWatchStartedByGate = $false
    if (-not (Stop-RouteKeeperWatch)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_watch_stop_failed' -Stage 'route_watch' -Reason 'existing route watcher could not be stopped' }
    Start-Sleep -Milliseconds 1500
    if (-not $ReadinessOnly) { Remove-StaleRouteEvidence }
    if ($script:EffectiveRouteMode -eq 'official') {
        if (-not (Invoke-RouteKeeper)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_keeper_failed' -Stage 'route' -Reason 'route keeper failed for official mode' }
        if (-not (Test-RouteReadyState)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_not_ready' -Stage 'route' -Reason 'official route readiness contract was not satisfied' }
        $officialBypass = $true
    }
    else {
        if (-not (Invoke-RouteKeeper -AllowRelayPending:$AllowRelayPending)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_keeper_failed' -Stage 'route' -Reason 'route keeper failed for proxy mode' }
        if (-not (Start-RouteKeeperWatch -AllowRelayPending:$AllowRelayPending)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_watch_start_failed' -Stage 'route_watch' -Reason 'route watcher could not be started' }
        $routeWatchStartedByGate = $true
        # Readiness validates the watch contract. Starting it after the
        # readiness check made every proxy-mode gate reject its own one-shot
        # route state before the watcher could publish the required watch state.
        # The manager bootstrap runs before the client creates relay 57321.
        # Its pre-launch check may accept only the exact missing-helper
        # snapshot. ReadinessOnly remains strict; a Codex launch may carry
        # the pending route only until Wait-CodexProcessReadiness confirms
        # relay 57321 after the process is created.
        $allowRelayPending = [bool]$AllowRelayPending
        if (-not (Wait-Readiness -ExpectedBaseUrl $script:ExpectedBaseUrl -AllowRelayPending:$allowRelayPending)) { Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'readiness_failed' -Stage 'readiness' -Reason 'gateway, Headroom, or monitor readiness contract was not satisfied' }
        $routeDeadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            if (Test-RouteReadyState -RequireSignal -AllowRelayPending:$allowRelayPending) { break }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $routeDeadline)
        if (-not (Test-RouteReadyState -RequireSignal -AllowRelayPending:$allowRelayPending)) {
            Write-Audit -Level ERROR -Event 'route_watch_not_ready' -Fields @{ reason = 'route watcher signal/process/schema contract not confirmed before deadline'; error_code = 'route_watch_not_ready'; stage = 'watch' }
            if ($routeWatchStartedByGate) { [void](Stop-RouteKeeperWatch) }
            Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'route_watch_not_ready' -Stage 'watch' -Reason 'route watcher signal/process/schema contract not confirmed before deadline'
        }
    }
    if ($ReadinessOnly) {
        Write-Audit -Level INFO -Event 'readiness_only_complete' -Fields @{ route_mode = $script:EffectiveRouteMode; watcher_required = ($script:EffectiveRouteMode -eq 'proxy') }
        Exit-Startup -ExitCode 0 -Status succeeded -ErrorCode 'ok' -Stage 'readiness' -Reason 'readiness-only startup check passed'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExePath
    $startInfo.WorkingDirectory = Split-Path -Parent $ExePath
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = $Arguments
    # AppX activation does not inherit this environment reliably; keep the
    # canonical home explicit for direct Codex++ launches, while official
    # desktop AppX uses the same C:\Users\ma dao\.codex config on disk.
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    $startInfo.EnvironmentVariables['ELECTRON_DEFAULT_LOCALE'] = 'zh-CN'
    $startInfo.EnvironmentVariables['LANG'] = 'zh-CN'
    # Keep any Headroom MCP child launched by Codex++ on the project-root
    # workspace even when the client inherits the canonical C: config. These
    # are process-scoped runtime variables; the supplier config and Base URL
    # remain untouched.
    $projectHeadroomWorkspace = Join-Path $RuntimeRoot 'private\headroom-workspace'
    $projectHeadroomConfig = Join-Path $RuntimeRoot 'private\headroom-config'
    $startInfo.EnvironmentVariables['HEADROOM_WORKSPACE_DIR'] = $projectHeadroomWorkspace
    $startInfo.EnvironmentVariables['HEADROOM_CONFIG_DIR'] = $projectHeadroomConfig
    $startInfo.EnvironmentVariables['HEADROOM_RUNTIME_ROOT'] = $RuntimeRoot
    $startInfo.EnvironmentVariables['HEADROOM_KOMPRESS_ENDPOINT'] = 'http://127.0.0.1:18790'
    $startInfo.EnvironmentVariables['HEADROOM_TELEMETRY'] = 'off'
    $startInfo.EnvironmentVariables['HF_HOME'] = Join-Path $RuntimeRoot 'cache\huggingface'
    $startInfo.EnvironmentVariables['TRANSFORMERS_CACHE'] = Join-Path $RuntimeRoot 'cache\huggingface\transformers'
    # Route selection is process-scoped.  The canonical config remains
    # untouched; the child receives an explicit local API base and a small
    # audit contract that route-aware clients can consume.
    if ($script:EffectiveRouteMode -eq 'proxy') {
        $startInfo.EnvironmentVariables['OPENAI_BASE_URL'] = $script:ProcessRouteBaseUrl
        $startInfo.EnvironmentVariables['OPENAI_API_BASE_URL'] = $script:ProcessRouteBaseUrl
        $startInfo.EnvironmentVariables['CODEX_BASE_URL'] = $script:ProcessRouteBaseUrl
        $startInfo.EnvironmentVariables['CODEXPP_BASE_URL'] = $script:ProcessRouteBaseUrl
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_BASE_URL'] = $script:ProcessRouteBaseUrl
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_SCOPE'] = 'process'
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_MODE'] = 'proxy'
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_CONFIG_SHA256'] = $script:RouteConfigHash
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_CONFIG_MUTATED'] = '0'
    }
    else {
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_SCOPE'] = 'process'
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_MODE'] = 'official'
        $startInfo.EnvironmentVariables['CODEXPP_ROUTE_CONFIG_MUTATED'] = '0'
    }
    $process = Start-RoleProcess -StartInfo $startInfo
    if ($null -eq $process) {
        throw 'Process.Start returned no process.'
    }
    Write-Audit -Level INFO -Event 'launch_succeeded' -Fields @{ pid = $process.Id; exe = $ExePath; codex_home = $CodexHome; config = $ConfigPath; base_url = $script:ExpectedBaseUrl; gateway = $GatewayBaseUrl; gateway_port = ([Uri](Normalize-HeadroomBaseUrl -Value $GatewayBaseUrl)).Port; headroom = $HeadroomBaseUrl; headroom_port = ([Uri](Normalize-HeadroomBaseUrl -Value $HeadroomBaseUrl)).Port; elevation = $script:LaunchElevation }
    Start-Sleep -Milliseconds 500
    try {
        $process.Refresh()
        Write-Audit -Level INFO -Event 'launch_observed' -Fields @{ pid = $process.Id; alive = (-not $process.HasExited); exit_code = if ($process.HasExited) { $process.ExitCode } else { 'running' } }
    }
    catch {
        Write-Audit -Level WARN -Event 'launch_observation_unavailable' -Fields @{ pid = $process.Id; message = $_.Exception.Message }
    }
    if ($Role -eq 'codex' -and -not $officialBypass -and -not (Wait-CodexProcessReadiness -Process $process)) {
        Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'codex_process_not_ready' -Stage 'launch' -Reason 'Codex process did not satisfy relay readiness'
    }
    Exit-Startup -ExitCode 0 -Status succeeded -ErrorCode 'ok' -Stage 'launch' -Reason 'startup completed successfully'
}
catch {
    Write-Audit -Level ERROR -Event 'bootstrap_error' -Fields @{ message = $_.Exception.Message; error_code = 'startup_gate_failure'; stage = 'startup_gate' }
    Exit-Startup -ExitCode 3 -Status failed -ErrorCode 'startup_gate_failure' -Stage 'startup_gate' -Reason $_.Exception.Message
}
