[CmdletBinding()]
param(
    [switch]$Watch,
    [string]$ConfigPath = 'C:\Users\ma dao\.codex\config.toml',
    [string]$SettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json',
    [string]$ProxyBaseUrl = 'http://127.0.0.1:18787/v1',
    [string]$RuntimeRoot = '',
    [string]$PythonPath = '',
    [string]$BackupRoot = '',
    [string]$StatePath = '',
    [string]$ReadySignalPath = '',
    [string]$WatchStatePath = '',
    [ValidateSet('auto', 'official', 'proxy')]
    [string]$Mode = 'auto',
    [switch]$AllowRelayPending,
    [ValidateRange(100, 10000)]
    [int]$StableWaitMs = 750,
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 2,
    [ValidateRange(10, 3600)]
    [int]$OwnerGraceSeconds = 86400
)

# Route reconciliation is intentionally process-scoped.  This script may
# read provider/config state, but it never rewrites config.toml, auth, model,
# session, or provider definitions.  The startup gate consumes the published
# process_route_base_url and passes it to the child process as an environment
# override.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path $projectRoot 'runtime' }
$runtimeStateRoot = Join-Path $RuntimeRoot 'state'
if ([string]::IsNullOrWhiteSpace($PythonPath)) { $PythonPath = Join-Path $RuntimeRoot 'python\Scripts\python.exe' }
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $runtimeStateRoot 'codexpp-route-state.json' }
if ([string]::IsNullOrWhiteSpace($WatchStatePath)) { $WatchStatePath = Join-Path $runtimeStateRoot 'codexpp-route-watch.json' }
if ([string]::IsNullOrWhiteSpace($ReadySignalPath)) { $ReadySignalPath = Join-Path $runtimeStateRoot 'codexpp-route-ready.signal' }
[IO.Directory]::CreateDirectory($runtimeStateRoot) | Out-Null
$script:MutexName = 'Local\CodexPlusPlusHeadroomRouteKeeper'
$script:RouteKeeperScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
$script:RouteKeeperStartedAt = [DateTime]::UtcNow
$script:WatchMode = $Watch
$script:RouteStateSchemaVersion = 3
$script:RouteContractVersion = 3
$script:RouteMutex = $null
$script:RouteStateWriteFailed = $false
$script:RelayHost = '127.0.0.1'
$script:RelayPort = 57321
$script:LastMode = ''
$script:LastConfigHash = ''
$script:LastProvider = ''
$script:HealthProbeTimeoutSeconds = 20
$script:RouteHeartbeatIntervalSeconds = 20

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)
    $text = if ($null -eq $Value) { 'unknown' } else { [string]$Value }
    $text = $text -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)sk-[A-Za-z0-9_-]{8,}', '<redacted>'
    $text = $text -replace '(?i)(bearer\s+)[^\s]+', '$1<redacted>'
    if ($text.Length -gt 240) { return $text.Substring(0, 237) + '...' }
    return $text
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

function Get-ObjectProperty {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ConfigProtectedContract {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$FallbackPath = $null
    )
    $empty = [ordered]@{
        Exists = $false
        Provider = $null
        ProviderPresent = $false
        ProviderSectionSha256 = $null
        BaseUrlPresent = $false
        BaseUrl = $null
        WireApiPresent = $false
        WireApi = $null
        RequiresOpenAIAuthPresent = $false
        RequiresOpenAIAuth = $null
        ExperimentalBearerTokenPresent = $false
        ProtectedContractSha256 = $null
        Error = 'config_missing'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$empty }
    try {
        $content = [IO.File]::ReadAllText($Path)
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $usedFallback = $false
        if (-not $providerMatch.Success -and -not [string]::IsNullOrWhiteSpace($FallbackPath) -and (Test-Path -LiteralPath $FallbackPath -PathType Leaf)) {
            $content = [IO.File]::ReadAllText($FallbackPath)
            $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
            $usedFallback = $providerMatch.Success
        }
        if (-not $providerMatch.Success) { $empty.Exists = $true; $empty.Error = 'root_model_provider_missing'; return [pscustomobject]$empty }
        $provider = if ($providerMatch.Groups['double'].Success) { $providerMatch.Groups['double'].Value } else { $providerMatch.Groups['single'].Value }
        $sectionMatch = [regex]::Match($content, '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) { $empty.Exists = $true; $empty.Provider = $provider; $empty.ProviderPresent = $true; $empty.Error = 'provider_section_missing'; return [pscustomobject]$empty }
        $section = $sectionMatch.Groups['section'].Value
        $baseMatch = [regex]::Match($section, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $wireMatch = [regex]::Match($section, '(?im)^\s*wire_api\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $authMatch = [regex]::Match($section, '(?im)^\s*requires_openai_auth\s*=\s*(?<value>true|false)\s*(?:#.*)?$')
        $tokenMatch = [regex]::Match($section, '(?im)^\s*experimental_bearer_token\s*=')
        $basePresent = $baseMatch.Success
        $wirePresent = $wireMatch.Success
        $authPresent = $authMatch.Success
        $tokenPresent = $tokenMatch.Success
        $baseUrl = if ($basePresent) { if ($baseMatch.Groups['double'].Success) { $baseMatch.Groups['double'].Value } else { $baseMatch.Groups['single'].Value } } else { $null }
        $wireApi = if ($wirePresent) { if ($wireMatch.Groups['double'].Success) { $wireMatch.Groups['double'].Value } else { $wireMatch.Groups['single'].Value } } else { $null }
        $requiresAuth = if ($authPresent) { $authMatch.Groups['value'].Value.ToLowerInvariant() } else { $null }
        $canonical = @(
            "provider_present=1"
            "provider=$provider"
            "base_url_present=$([int][bool]$basePresent)"
            "base_url=$baseUrl"
            "wire_api_present=$([int][bool]$wirePresent)"
            "wire_api=$wireApi"
            "requires_openai_auth_present=$([int][bool]$authPresent)"
            "requires_openai_auth=$requiresAuth"
            "bearer_token_present=$([int][bool]$tokenPresent)"
        ) -join "`n"
        $fingerprint = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($canonical)))).Replace('-', '')
        return [pscustomobject]@{
            Exists = $true
            Provider = $provider
            ProviderPresent = $true
            ProviderSectionSha256 = $fingerprint
            BaseUrlPresent = $basePresent
            BaseUrl = $baseUrl
            WireApiPresent = $wirePresent
            WireApi = $wireApi
            RequiresOpenAIAuthPresent = $authPresent
            RequiresOpenAIAuth = $requiresAuth
            ExperimentalBearerTokenPresent = $tokenPresent
            ProtectedContractSha256 = $fingerprint
            UsedFallback = $usedFallback
            Error = if (-not $basePresent) { 'base_url_missing' } elseif (-not $wirePresent) { 'wire_api_missing' } else { $null }
        }
    }
    catch {
        $empty.Exists = $true
        $empty.Error = 'config_read_error'
        return [pscustomobject]$empty
    }
}

function Test-ConfigProtectedContract {
    param([Parameter(Mandatory)][object]$Before,[Parameter(Mandatory)][object]$After)
    if (-not $Before.Exists -or -not $After.Exists -or $null -ne $Before.Error -or $null -ne $After.Error) { return $false }
    return (
        [bool]$Before.ProviderPresent -eq [bool]$After.ProviderPresent -and
        [string]$Before.Provider -eq [string]$After.Provider -and
        [bool]$Before.BaseUrlPresent -eq [bool]$After.BaseUrlPresent -and
        [string]$Before.BaseUrl -eq [string]$After.BaseUrl -and
        [bool]$Before.WireApiPresent -eq [bool]$After.WireApiPresent -and
        [string]$Before.WireApi -eq [string]$After.WireApi -and
        [bool]$Before.RequiresOpenAIAuthPresent -eq [bool]$After.RequiresOpenAIAuthPresent -and
        [string]$Before.RequiresOpenAIAuth -eq [string]$After.RequiresOpenAIAuth -and
        [bool]$Before.ExperimentalBearerTokenPresent -eq [bool]$After.ExperimentalBearerTokenPresent
    )
}

function ConvertTo-StatsNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    [double]$number = 0
    if (-not [double]::TryParse(([string]$Value).Trim(), [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or [Math]::Floor($number) -ne $number) { return $null }
    return [Math]::Max(0, $number)
}

function ConvertTo-ErrorCode {
    param([AllowNull()][object]$Value)
    $code = if ($null -eq $Value) { 'unknown_error' } else { ([string]$Value).Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($code)) { return 'unknown_error' }
    $code = ($code -replace '[^a-z0-9]+', '_').Trim('_')
    if ($code.Length -gt 96) { $code = $code.Substring(0, 96).Trim('_') }
    if ([string]::IsNullOrWhiteSpace($code)) { return 'unknown_error' }
    return $code
}

function Replace-RouteFileAtomically {
    param([Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)][string]$DestinationPath)
    # Move(..., true) is used only for route evidence files.  ConfigPath is
    # explicitly rejected so a future caller cannot turn this into a config
    # replacement helper by accident.
    $destinationFull = [IO.Path]::GetFullPath($DestinationPath)
    $configFull = [IO.Path]::GetFullPath($ConfigPath)
    if ($destinationFull.Equals($configFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'route_config_write_forbidden' }
    [IO.File]::Move($SourcePath, $DestinationPath, $true)
}

function Write-RouteState {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Protocol,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Status,
        [string]$Reason = '',
        [string]$ConfigHash = '',
        [string]$ErrorCode = '',
        [string]$Stage = 'route_keeper',
        [string]$Provider = '',
        [string]$ProcessRouteBaseUrl = '',
        [AllowNull()][object]$ProtectedContract = $null
    )
    $script:RouteStateWriteFailed = $false
    try {
        $parent = Split-Path -Parent $StatePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $effectiveErrorCode = if ($Status -eq 'failed') {
            if ([string]::IsNullOrWhiteSpace($ErrorCode)) { ConvertTo-ErrorCode $Reason } else { ConvertTo-ErrorCode $ErrorCode }
        } else { '' }
        $protectedRecord = $null
        if ($null -ne $ProtectedContract) {
            $protectedRecord = [ordered]@{
                provider_present = [bool](Get-ObjectProperty $ProtectedContract 'ProviderPresent')
                provider = [string](Get-ObjectProperty $ProtectedContract 'Provider')
                base_url_present = [bool](Get-ObjectProperty $ProtectedContract 'BaseUrlPresent')
                base_url = [string](Get-ObjectProperty $ProtectedContract 'BaseUrl')
                wire_api_present = [bool](Get-ObjectProperty $ProtectedContract 'WireApiPresent')
                wire_api = [string](Get-ObjectProperty $ProtectedContract 'WireApi')
                requires_openai_auth_present = [bool](Get-ObjectProperty $ProtectedContract 'RequiresOpenAIAuthPresent')
                requires_openai_auth = [string](Get-ObjectProperty $ProtectedContract 'RequiresOpenAIAuth')
                bearer_token_present = [bool](Get-ObjectProperty $ProtectedContract 'ExperimentalBearerTokenPresent')
                fingerprint = [string](Get-ObjectProperty $ProtectedContract 'ProtectedContractSha256')
            }
        }
        $document = [ordered]@{
            schema_version = $script:RouteStateSchemaVersion
            route_contract_version = $script:RouteContractVersion
            timestamp_utc = [DateTime]::UtcNow.ToString('o')
            mode = $Mode
            protocol = $Protocol
            http_mode = if ($Mode -in @('pureapi', 'mixedapi', 'aggregate', 'proxy')) { 'responses' } else { 'direct' }
            wire_api = 'responses'
            supports_websockets = if ($Mode -in @('pureapi', 'mixedapi', 'aggregate', 'proxy')) { $false } else { $null }
            action = $Action
            status = $Status
            error_code = $effectiveErrorCode
            reason = ConvertTo-SafeText $Reason
            stage = ConvertTo-SafeText $Stage
            config_sha256 = ConvertTo-SafeText $ConfigHash
            config_path = $ConfigPath
            config_mutated = $false
            route_scope = 'process'
            config_protected_contract = $protectedRecord
            allow_relay_pending = [bool]$AllowRelayPending
            process_route_base_url = $ProcessRouteBaseUrl
            provider = $Provider
            proxy = if ($Mode -eq 'official') { 'not-required' } else { 'local-headroom' }
            route_keeper_pid = [int]$PID
            route_keeper_script_path = $script:RouteKeeperScriptPath
            route_keeper_started_at = $script:RouteKeeperStartedAt.ToString('o')
            route_keeper_mode = if ($script:WatchMode) { 'watch' } else { 'once' }
            route_keeper_config_path = $ConfigPath
            route_keeper_settings_path = $SettingsPath
            route_keeper_ready_signal_path = $ReadySignalPath
            route_state_path = $StatePath
            route_watch_state_path = $WatchStatePath
            route_keeper_proxy_base_url = $ProxyBaseUrl
            proxy_original = [ordered]@{
                captured = $false
                provider = ''
                present = $false
                value = $null
                capture_config_sha256 = ''
                forced_provider = ''
                forced_config_sha256 = ''
                restore_status = 'not-applicable-process-route'
            }
            proxy_original_by_provider = [ordered]@{}
        }
        $temp = Join-Path $parent ('.codexpp-route-state-' + [IO.Path]::GetRandomFileName())
        try {
            [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            Replace-RouteFileAtomically -SourcePath $temp -DestinationPath $StatePath
        }
        finally {
            if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }
    catch {
        $script:RouteStateWriteFailed = $true
        throw
    }
}

function Assert-RouteStateWritten {
    if ($script:RouteStateWriteFailed -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'route_state_write_failed' }
}

function Get-RelayMode {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Mode = 'unknown'; Protocol = 'unknown'; RequiresProxy = $false; Error = 'settings_missing' }
    }
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        $activeId = [string](Get-ObjectProperty $settings 'activeRelayId')
        $profiles = @((Get-ObjectProperty $settings 'relayProfiles'))
        $matches = @($profiles | Where-Object { [string](Get-ObjectProperty $_ 'id') -eq $activeId })
        if ([string]::IsNullOrWhiteSpace($activeId) -or $matches.Count -ne 1) {
            return [pscustomobject]@{ Valid = $false; Mode = 'unknown'; Protocol = 'unknown'; RequiresProxy = $false; Error = 'active_profile_missing_or_ambiguous' }
        }
        $profile = $matches[0]
        $rawMode = ([string](Get-ObjectProperty $profile 'relayMode')).Trim().ToLowerInvariant()
        $protocol = ([string](Get-ObjectProperty $profile 'protocol')).Trim().ToLowerInvariant()
        $officialMixApiKey = Get-ObjectProperty $profile 'officialMixApiKey'
        if ($rawMode -eq 'official' -and $officialMixApiKey -ne $true) {
            return [pscustomobject]@{ Valid = $true; Mode = 'official'; Protocol = $protocol; RequiresProxy = $false; Error = $null }
        }
        if ($rawMode -in @('pureapi', 'mixedapi', 'aggregate')) {
            return [pscustomobject]@{ Valid = $true; Mode = $rawMode; Protocol = $protocol; RequiresProxy = $true; Error = $null }
        }
        return [pscustomobject]@{ Valid = $false; Mode = 'unknown'; Protocol = $protocol; RequiresProxy = $false; Error = 'unsupported_relay_mode' }
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Mode = 'unknown'; Protocol = 'unknown'; RequiresProxy = $false; Error = 'settings_parse_error' }
    }
}

function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec $script:HealthProbeTimeoutSeconds
        $body = $null
        $parseError = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            try { $body = $response.Content | ConvertFrom-Json } catch { $parseError = $true }
        }
        return [pscustomobject]@{ TransportOk = $true; StatusCode = [int]$response.StatusCode; Body = $body; ParseError = $parseError }
    }
    catch { return [pscustomobject]@{ TransportOk = $false; StatusCode = 0; Body = $null; ParseError = $false } }
}

function Test-LocalRelayEndpoint {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $uri = [Uri]$Value
        return $uri.Scheme -eq 'http' -and $uri.Host.ToLowerInvariant() -in @('127.0.0.1', 'localhost', '::1') -and $uri.Port -eq $script:RelayPort -and [string]::IsNullOrWhiteSpace($uri.UserInfo) -and [string]::IsNullOrWhiteSpace($uri.Query) -and [string]::IsNullOrWhiteSpace($uri.Fragment) -and $uri.AbsolutePath.TrimEnd('/') -eq ''
    }
    catch { return $false }
}

function Get-HeadroomRouteReadiness {
    param([switch]$AllowRelayPending)

    $base = $ProxyBaseUrl.TrimEnd('/')
    # Removing `/v1` from a normalized base leaves one trailing slash. Trim it
    # before appending health paths; otherwise the loopback gateway receives
    # `//livez`/`//health` and correctly returns 404.
    $root = if ($base.EndsWith('/v1')) { $base.Substring(0, $base.Length - 3) } else { $base }
    $root = $root.TrimEnd('/')
    $livez = Get-JsonEndpoint -Uri ($root + '/livez')
    $health = Get-JsonEndpoint -Uri ($root + '/health')
    if (-not $livez.TransportOk -or $livez.StatusCode -ne 200 -or $livez.ParseError -or $null -eq $livez.Body -or $livez.Body.status -ne 'healthy' -or $livez.Body.alive -ne $true) {
        return [pscustomobject]@{ Ready = $false; Pending = $false; Reason = 'gateway_livez_not_ready' }
    }
    if (-not $health.TransportOk -or $health.ParseError -or $null -eq $health.Body) {
        return [pscustomobject]@{ Ready = $false; Pending = $false; Reason = 'gateway_health_unavailable' }
    }
    $config = $health.Body.PSObject.Properties['config']
    $relay = if ($config) { $health.Body.config.PSObject.Properties['openai_api_url'] } else { $null }
    if ($null -ne $relay -and -not (Test-LocalRelayEndpoint ([string]$relay.Value))) {
        return [pscustomobject]@{ Ready = $false; Pending = $false; Reason = 'relay_config_invalid' }
    }
    if ($health.StatusCode -eq 200 -and $health.Body.status -eq 'healthy' -and $health.Body.ready -eq $true) {
        return [pscustomobject]@{ Ready = $true; Pending = $false; Reason = 'ready' }
    }
    if (-not $AllowRelayPending) {
        return [pscustomobject]@{ Ready = $false; Pending = $false; Reason = 'gateway_health_not_ready' }
    }

    # During the explicit pre-client phase, preserve only the exact Gateway
    # state caused by helper 57321 not listening. Headroom itself must still
    # be healthy; arbitrary 503s, malformed checks, and helper error codes
    # remain fail-closed.
    $checks = $health.Body.PSObject.Properties['checks']
    $headroom = if ($checks) { $health.Body.checks.PSObject.Properties['headroom'] } else { $null }
    $helper = if ($checks) { $health.Body.checks.PSObject.Properties['helper'] } else { $null }
    $pending = $health.StatusCode -eq 503 -and
        $health.Body.status -eq 'degraded' -and
        $health.Body.ready -eq $false -and
        $null -ne $headroom -and $health.Body.checks.headroom.ok -eq $true -and
        $null -ne $helper -and $health.Body.checks.helper.ok -eq $false -and
        $null -eq $health.Body.checks.helper.status_code
    if ($pending) {
        return [pscustomobject]@{ Ready = $true; Pending = $true; Reason = 'helper_pending' }
    }
    return [pscustomobject]@{ Ready = $false; Pending = $false; Reason = 'gateway_health_not_ready' }
}

function Test-HeadroomReady {
    param([switch]$AllowRelayPending)
    return (Get-HeadroomRouteReadiness -AllowRelayPending:$AllowRelayPending).Ready
}

function Test-ReadySignal {
    if ([string]::IsNullOrWhiteSpace($ReadySignalPath)) { return $true }
    if (-not (Test-Path -LiteralPath $ReadySignalPath -PathType Leaf)) { return $false }
    try {
        $timestamp = ConvertTo-UtcDateTime (Get-Content -LiteralPath $ReadySignalPath -Raw)
        return $null -ne $timestamp -and $timestamp -gt [DateTime]::UtcNow.AddSeconds(-90) -and $timestamp -le [DateTime]::UtcNow.AddSeconds(5)
    }
    catch { return $false }
}

function ConvertTo-ConfigText {
    param([Parameter(Mandatory)][string]$Path,[AllowNull()][string]$FallbackPath = $null)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'config_missing' }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    # Under Codex++ aggregate mode the Manager's config.toml may carry no
    # model_provider section; the active supplier contract lives in the
    # official home.  Fall back so route-mode reconciliation and the
    # protected contract remain verifiable.
    $providerProbe = [regex]::Matches($text, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
    if ($providerProbe.Count -ne 1 -and -not [string]::IsNullOrWhiteSpace($FallbackPath) -and (Test-Path -LiteralPath $FallbackPath -PathType Leaf)) {
        return Get-Content -LiteralPath $FallbackPath -Raw -ErrorAction Stop
    }
    return $text
}

function Get-ProviderId {
    param([Parameter(Mandatory)][string]$Text)
    $matches = [regex]::Matches($Text, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
    if ($matches.Count -ne 1) { throw 'root_model_provider_missing_or_duplicated' }
    $provider = if ($matches[0].Groups['double'].Success) { $matches[0].Groups['double'].Value } else { $matches[0].Groups['single'].Value }
    if ([string]::IsNullOrWhiteSpace($provider)) { throw 'invalid_model_provider' }
    return $provider
}

function Get-ProviderSection {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Provider)
    $match = [regex]::Match($Text, '(?ims)^\s*\[model_providers\.' + [regex]::Escape($Provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)')
    if (-not $match.Success) { throw 'provider_section_missing' }
    return $match.Groups['section'].Value
}

function Get-ActiveProviderBaseUrl {
    param([Parameter(Mandatory)][string]$Text)
    $provider = Get-ProviderId $Text
    $section = Get-ProviderSection -Text $Text -Provider $provider
    $matches = [regex]::Matches($section, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
    if ($matches.Count -gt 1) { throw 'active_provider_base_url_missing_or_duplicated' }
    if ($matches.Count -eq 0) { return $null }
    $value = if ($matches[0].Groups['double'].Success) { $matches[0].Groups['double'].Value } else { $matches[0].Groups['single'].Value }
    return $value
}

function Get-ActiveProviderSupportsWebsockets {
    param([Parameter(Mandatory)][string]$Text)
    $provider = Get-ProviderId $Text
    $section = Get-ProviderSection -Text $Text -Provider $provider
    $matches = [regex]::Matches($section, '(?im)^\s*supports_websockets\s*=\s*(?<value>true|false)\s*(?:#.*)?$')
    if ($matches.Count -gt 1) { throw 'supports_websockets_missing_or_duplicated' }
    if ($matches.Count -eq 0) { return [pscustomobject]@{ Present = $false; Value = $null } }
    return [pscustomobject]@{ Present = $true; Value = ($matches[0].Groups['value'].Value.ToLowerInvariant() -eq 'true') }
}

function Get-ActiveProviderWireApi {
    param([Parameter(Mandatory)][string]$Text)
    $provider = Get-ProviderId $Text
    $section = Get-ProviderSection -Text $Text -Provider $provider
    $matches = [regex]::Matches($section, '(?im)^\s*wire_api\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
    if ($matches.Count -gt 1) { throw 'wire_api_missing_or_duplicated' }
    if ($matches.Count -eq 0) { return $null }
    $value = if ($matches[0].Groups['double'].Success) { $matches[0].Groups['double'].Value } else { $matches[0].Groups['single'].Value }
    return $value
}

function Test-ActiveProxyContract {
    try {
        $text = ConvertTo-ConfigText -Path $ConfigPath -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        $provider = Get-ProviderId $text
        $base = Get-ActiveProviderBaseUrl $text
        $supports = Get-ActiveProviderSupportsWebsockets $text
        $wire = Get-ActiveProviderWireApi $text
        return $base -eq $ProxyBaseUrl -and $supports.Present -and $supports.Value -eq $false -and $wire -eq 'responses'
    }
    catch { return $false }
}

function Get-ConfigSnapshot {
    try {
        $text = ConvertTo-ConfigText -Path $ConfigPath -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        $provider = Get-ProviderId $text
        $hash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
        $protected = Get-ConfigProtectedContract -Path $ConfigPath -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        if (-not $protected.Exists -or $null -ne $protected.Error) { throw $protected.Error }
        return [pscustomobject]@{
            Ready = $true
            Hash = $hash
            Provider = $provider
            BaseUrl = Get-ActiveProviderBaseUrl $text
            Supports = Get-ActiveProviderSupportsWebsockets $text
            WireApi = Get-ActiveProviderWireApi $text
            Protected = $protected
        }
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Hash = ''; Provider = ''; BaseUrl = $null; Supports = [pscustomobject]@{ Present = $false; Value = $null }; WireApi = $null; Protected = $null; Error = (ConvertTo-ErrorCode $_.Exception.Message) }
    }
}

function Get-RouteStateDocument {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-RouteStateProtectedContract {
    param([Parameter(Mandatory)][object]$Snapshot)
    $state = Get-RouteStateDocument
    if ($null -eq $state) { return $null }
    $stateProtected = Get-ObjectProperty $state 'config_protected_contract'
    if ($null -eq $stateProtected) { return $null }
    $snapshotProtected = Get-ObjectProperty $Snapshot 'Protected'
    if ($null -eq $snapshotProtected) { return $false }
    return [string]$stateProtected.fingerprint -eq [string](Get-ObjectProperty $snapshotProtected 'ProtectedContractSha256')
}

function Write-RouteHeartbeat {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$EffectiveMode
    )

    $state = Get-RouteStateDocument
    if ($null -eq $state) { return $false }
    $expectedStatus = if ($EffectiveMode -eq 'official') { 'official-bypass' } else { 'ready' }
    $expectedProcessRouteBaseUrl = if ($EffectiveMode -eq 'official') { [string]$Snapshot.BaseUrl } else { $ProxyBaseUrl }
    $stateKeeperPid = ConvertTo-StatsNumber (Get-ObjectProperty $state 'route_keeper_pid')
    $stateProtected = Get-ObjectProperty $state 'config_protected_contract'
    $snapshotProtected = Get-ObjectProperty $Snapshot 'Protected'
    $stateMatches = (
        [int](Get-ObjectProperty $state 'schema_version') -eq $script:RouteStateSchemaVersion -and
        [int](Get-ObjectProperty $state 'route_contract_version') -eq $script:RouteContractVersion -and
        [string](Get-ObjectProperty $state 'status') -eq $expectedStatus -and
        [string](Get-ObjectProperty $state 'route_scope') -eq 'process' -and
        (Get-ObjectProperty $state 'config_mutated') -eq $false -and
        [string](Get-ObjectProperty $state 'provider') -eq [string]$Snapshot.Provider -and
        [string](Get-ObjectProperty $state 'process_route_base_url') -eq $expectedProcessRouteBaseUrl -and
        $null -ne $stateKeeperPid -and [int]$stateKeeperPid -eq [int]$PID -and
        [string](Get-ObjectProperty $state 'route_keeper_script_path') -eq $script:RouteKeeperScriptPath -and
        [string](Get-ObjectProperty $state 'route_keeper_mode') -eq 'watch' -and
        [string](Get-ObjectProperty $state 'route_keeper_config_path') -eq $ConfigPath -and
        [string](Get-ObjectProperty $state 'route_keeper_settings_path') -eq $SettingsPath -and
        [string](Get-ObjectProperty $state 'route_keeper_ready_signal_path') -eq $ReadySignalPath -and
        [string](Get-ObjectProperty $state 'route_state_path') -eq $StatePath -and
        [string](Get-ObjectProperty $state 'route_watch_state_path') -eq $WatchStatePath -and
        [string](Get-ObjectProperty $state 'route_keeper_proxy_base_url') -eq $ProxyBaseUrl
    )
    if (-not $stateMatches) { return $false }
    # A missing contract is accepted only for a legacy state whose full hash
    # still matches.  On ordinary metadata drift the watcher will fall back
    # to Ensure-RouteOnce, which publishes the new contract before the next
    # heartbeat.  New state always carries the field-level contract.
    if ($null -ne $stateProtected) {
        if ($null -eq $snapshotProtected -or [string]$stateProtected.fingerprint -ne [string](Get-ObjectProperty $snapshotProtected 'ProtectedContractSha256')) { return $false }
    }
    elseif ([string](Get-ObjectProperty $state 'config_sha256') -ne [string]$Snapshot.Hash) {
        return $false
    }

    $state.timestamp_utc = [DateTime]::UtcNow.ToString('o')
    $state.config_sha256 = [string]$Snapshot.Hash
    $state.config_protected_contract = if ($null -ne $snapshotProtected) {
        [ordered]@{
            provider_present = [bool](Get-ObjectProperty $snapshotProtected 'ProviderPresent')
            provider = [string](Get-ObjectProperty $snapshotProtected 'Provider')
            base_url_present = [bool](Get-ObjectProperty $snapshotProtected 'BaseUrlPresent')
            base_url = [string](Get-ObjectProperty $snapshotProtected 'BaseUrl')
            wire_api_present = [bool](Get-ObjectProperty $snapshotProtected 'WireApiPresent')
            wire_api = [string](Get-ObjectProperty $snapshotProtected 'WireApi')
            requires_openai_auth_present = [bool](Get-ObjectProperty $snapshotProtected 'RequiresOpenAIAuthPresent')
            requires_openai_auth = [string](Get-ObjectProperty $snapshotProtected 'RequiresOpenAIAuth')
            bearer_token_present = [bool](Get-ObjectProperty $snapshotProtected 'ExperimentalBearerTokenPresent')
            fingerprint = [string](Get-ObjectProperty $snapshotProtected 'ProtectedContractSha256')
        }
    } else { $null }
    $state.provider = [string]$Snapshot.Provider
    $state.route_keeper_pid = [int]$PID
    $state.route_keeper_script_path = $script:RouteKeeperScriptPath
    $state.route_keeper_started_at = $script:RouteKeeperStartedAt.ToString('o')
    $state.route_keeper_mode = 'watch'
    $state.route_keeper_config_path = $ConfigPath
    $state.route_keeper_settings_path = $SettingsPath
    $state.route_keeper_ready_signal_path = $ReadySignalPath
    $state.route_state_path = $StatePath
    $state.route_watch_state_path = $WatchStatePath
    $state.route_keeper_proxy_base_url = $ProxyBaseUrl
    $parent = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = Join-Path $parent ('.codexpp-route-heartbeat-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Replace-RouteFileAtomically -SourcePath $temp -DestinationPath $StatePath
        return $true
    }
    catch {
        $script:RouteStateWriteFailed = $true
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-OfficialRestoreSource {
    # Kept as a compatibility/read-only helper for older callers.  It never
    # writes the profile or config content.
    try {
        if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $null }
        $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        $activeId = [string](Get-ObjectProperty $settings 'activeRelayId')
        $profiles = @((Get-ObjectProperty $settings 'relayProfiles'))
        $matches = @($profiles | Where-Object { [string](Get-ObjectProperty $_ 'id') -eq $activeId })
        if ($matches.Count -ne 1) { return $null }
        $contents = [string](Get-ObjectProperty $matches[0] 'configContents')
        if ([string]::IsNullOrWhiteSpace($contents)) { return $null }
        $provider = Get-ProviderId $contents
        $supports = Get-ActiveProviderSupportsWebsockets $contents
        return [pscustomobject]@{ Provider = $provider; Present = [bool]$supports.Present; Value = if ($supports.Present) { [bool]$supports.Value } else { $null } }
    }
    catch { return $null }
}

function Write-ReadySignal {
    if ([string]::IsNullOrWhiteSpace($ReadySignalPath)) { return }
    $parent = Split-Path -Parent $ReadySignalPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = Join-Path $parent ('.route-ready-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, ([DateTime]::UtcNow.ToString('o') + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Replace-RouteFileAtomically -SourcePath $temp -DestinationPath $ReadySignalPath
    }
    finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Write-WatchState {
    if (-not $Watch) { return }
    $parent = Split-Path -Parent $WatchStatePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $document = [ordered]@{
        schema_version = 2
        route_contract_version = $script:RouteContractVersion
        route_scope = 'process'
        pid = [int]$PID
        started_at_utc = $script:RouteKeeperStartedAt.ToString('o')
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        route_keeper_path = $script:RouteKeeperScriptPath
        mode = $Mode
        config_path = $ConfigPath
        settings_path = $SettingsPath
        proxy_base_url = $ProxyBaseUrl
        ready_signal_path = $ReadySignalPath
        allow_relay_pending = [bool]$AllowRelayPending
    }
    $temp = Join-Path $parent ('.route-watch-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Replace-RouteFileAtomically -SourcePath $temp -DestinationPath $WatchStatePath
    }
    finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Test-ClientOwnerPresent {
    foreach ($name in @('codex-plus-plus','codex-plus-plus-manager','ChatGPT','codex')) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Ensure-RouteOnce {
    $relayMode = Get-RelayMode
    if (-not $relayMode.Valid) {
        Write-RouteState -Mode 'unknown' -Protocol $relayMode.Protocol -Action 'fail-closed' -Status 'failed' -Reason $relayMode.Error -ErrorCode $relayMode.Error
        throw $relayMode.Error
    }
    # A watcher may start in proxy mode and later observe a manager provider
    # switch to an official profile (or the reverse).  Reconcile against the
    # active profile in watch mode; one-shot invocations still honor -Mode as
    # an explicit fail-closed request.
    $effectiveRequestedMode = $Mode
    if ($Watch) { $effectiveRequestedMode = if ($relayMode.RequiresProxy) { 'proxy' } else { 'official' } }
    if ($effectiveRequestedMode -eq 'official' -and $relayMode.RequiresProxy) { throw 'requested_official_bypass_but_active_profile_requires_proxy' }
    if ($effectiveRequestedMode -eq 'proxy' -and -not $relayMode.RequiresProxy) { throw 'requested_proxy_but_active_profile_is_official' }
    $snapshot = Get-ConfigSnapshot
    if (-not $snapshot.Ready) {
        Write-RouteState -Mode $relayMode.Mode -Protocol $relayMode.Protocol -Action 'fail-closed' -Status 'failed' -Reason $snapshot.Error -ErrorCode $snapshot.Error
        throw $snapshot.Error
    }
    if ($effectiveRequestedMode -eq 'official') { $relayMode = [pscustomobject]@{ Valid = $true; Mode = 'official'; Protocol = $relayMode.Protocol; RequiresProxy = $false; Error = $null } }
    if (-not $relayMode.RequiresProxy) {
        if ($snapshot.BaseUrl -eq $ProxyBaseUrl) {
            Write-RouteState -Mode 'official' -Protocol $relayMode.Protocol -Action 'fail-closed' -Status 'failed' -Reason 'official_bypass_config_is_local' -ConfigHash $snapshot.Hash -Provider $snapshot.Provider -ProcessRouteBaseUrl '' -ProtectedContract $snapshot.Protected
            throw 'official_bypass_config_is_local'
        }
        Write-RouteState -Mode 'official' -Protocol $relayMode.Protocol -Action 'validate' -Status 'official-bypass' -Reason 'official account mode remains direct; config was not modified' -ConfigHash $snapshot.Hash -Provider $snapshot.Provider -ProcessRouteBaseUrl $snapshot.BaseUrl -ProtectedContract $snapshot.Protected
        Assert-RouteStateWritten
        Write-Result $relayMode 'validate' 'official-bypass' $snapshot.Hash
        return
    }
    $headroomReadiness = Get-HeadroomRouteReadiness -AllowRelayPending:$AllowRelayPending
    if (-not $headroomReadiness.Ready) {
        Write-RouteState -Mode $relayMode.Mode -Protocol $relayMode.Protocol -Action 'fail-closed' -Status 'failed' -Reason $headroomReadiness.Reason -ErrorCode $headroomReadiness.Reason -ConfigHash $snapshot.Hash -Provider $snapshot.Provider -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $snapshot.Protected
        throw $headroomReadiness.Reason
    }
    if ($snapshot.WireApi -ne 'responses') {
        Write-RouteState -Mode $relayMode.Mode -Protocol $relayMode.Protocol -Action 'fail-closed' -Status 'failed' -Reason 'config_wire_api_incompatible' -ErrorCode 'config_wire_api_incompatible' -ConfigHash $snapshot.Hash -Provider $snapshot.Provider -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $snapshot.Protected
        throw 'config_wire_api_incompatible'
    }
    $routeStatus = if ($headroomReadiness.Pending) { 'pending' } else { 'ready' }
    $routeAction = if ($headroomReadiness.Pending) { 'process-route-pending' } else { 'process-route' }
    $routeReason = if ($headroomReadiness.Pending) { 'Gateway live; helper 57321 pending, process route override published without config mutation' } else { 'Headroom/Gateway ready; process route override published without config mutation' }
    Write-RouteState -Mode $relayMode.Mode -Protocol $relayMode.Protocol -Action $routeAction -Status $routeStatus -Reason $routeReason -ConfigHash $snapshot.Hash -Provider $snapshot.Provider -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $snapshot.Protected
    Assert-RouteStateWritten
    Write-Result $relayMode $routeAction $routeStatus $snapshot.Hash
}

function Write-Result {
    param([object]$Mode,[string]$Action,[string]$Status,[string]$ConfigHash = '')
    Write-Output "ROUTE_MODE=$($Mode.Mode)"
    Write-Output "ROUTE_PROTOCOL=$($Mode.Protocol)"
    Write-Output "ROUTE_REQUIRES_PROXY=$([int][bool]$Mode.RequiresProxy)"
    Write-Output "ROUTE_ACTION=$Action"
    Write-Output "ROUTE_SCOPE=process"
    Write-Output "ROUTE_STATUS=$Status"
    if ($ConfigHash) { Write-Output "CONFIG_SHA256=$ConfigHash" }
}

function Test-ReadyStateForWatch {
    $state = Get-RouteStateDocument
    if ($null -eq $state) { return $false }
    $status = [string](Get-ObjectProperty $state 'status')
    $timestamp = ConvertTo-UtcDateTime (Get-ObjectProperty $state 'timestamp_utc')
    return $status -in @('ready', 'official-bypass') -and $null -ne $timestamp -and $timestamp -gt [DateTime]::UtcNow.AddSeconds(-120)
}

$mutex = [Threading.Mutex]::new($false, $script:MutexName)
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { Write-Output 'ROUTE_STATUS=busy'; exit 2 }
    if (-not $Watch) {
        try {
            Ensure-RouteOnce
            Write-ReadySignal
            exit 0
        }
        catch {
            try { Write-RouteState -Mode 'unknown' -Protocol 'unknown' -Action 'fail-closed' -Status 'failed' -Reason $_.Exception.Message -ErrorCode (ConvertTo-ErrorCode $_.Exception.Message) } catch { }
            Write-Output 'ROUTE_STATUS=failed'
            Write-Error (ConvertTo-SafeText $_.Exception.Message)
            exit 1
        }
    }
    Write-WatchState
    $lastHash = ''
    $lastMode = ''
    $lastHeartbeatAt = [DateTime]::MinValue
    $ownerMissingSince = $null
    while ($true) {
        try {
            $snapshot = Get-ConfigSnapshot
            $relayMode = Get-RelayMode
            $effectiveMode = if ($Mode -eq 'auto') { if ($relayMode.RequiresProxy) { 'proxy' } else { 'official' } } else { $Mode }
            if (-not $snapshot.Ready -or -not $relayMode.Valid) { throw (if ($snapshot.Ready) { $relayMode.Error } else { $snapshot.Error }) }
            $hashChanged = $snapshot.Hash -ne $lastHash
            $modeChanged = $effectiveMode -ne $lastMode
            if ($hashChanged -or $modeChanged) {
                $protectedMatches = Test-RouteStateProtectedContract -Snapshot $snapshot
                if ($protectedMatches -eq $false) { throw 'config_protected_contract_changed' }
                $heartbeatUpdated = $false
                if ($hashChanged -and -not $modeChanged) {
                    $heartbeatUpdated = Write-RouteHeartbeat -Snapshot $snapshot -EffectiveMode $effectiveMode
                }
                if (-not $heartbeatUpdated) {
                    Ensure-RouteOnce
                }
                Write-ReadySignal
                $lastHash = $snapshot.Hash
                $lastMode = $effectiveMode
                $lastHeartbeatAt = [DateTime]::UtcNow
            }
            elseif (-not (Test-ReadyStateForWatch)) {
                Ensure-RouteOnce
                Write-ReadySignal
                $lastHeartbeatAt = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $lastHeartbeatAt).TotalSeconds -ge $script:RouteHeartbeatIntervalSeconds) {
                if (-not (Write-RouteHeartbeat -Snapshot $snapshot -EffectiveMode $effectiveMode)) {
                    Ensure-RouteOnce
                    Write-ReadySignal
                }
                $lastHeartbeatAt = [DateTime]::UtcNow
            }
        }
        catch {
            try { Write-RouteState -Mode 'unknown' -Protocol 'unknown' -Action 'fail-closed' -Status 'failed' -Reason $_.Exception.Message -ErrorCode (ConvertTo-ErrorCode $_.Exception.Message) } catch { }
            if ($script:RouteStateWriteFailed) { exit 1 }
        }
        if (Test-ClientOwnerPresent) { $ownerMissingSince = $null }
        elseif ($null -eq $ownerMissingSince) { $ownerMissingSince = [DateTime]::UtcNow }
        elseif ((([DateTime]::UtcNow) - $ownerMissingSince).TotalSeconds -ge $OwnerGraceSeconds) { exit 0 }
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, $script:RouteHeartbeatIntervalSeconds))
    }
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
