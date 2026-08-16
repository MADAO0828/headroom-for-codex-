[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$keeperPath = Join-Path $PSScriptRoot 'codexpp-route-keeper.ps1'
$gatePath = Join-Path $PSScriptRoot 'codexpp-startup-gate.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual,[AllowNull()][object]$Expected,[Parameter(Mandatory)][string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "ASSERT FAILED: $Message (actual='$Actual' expected='$Expected')" }
}

function Get-FunctionText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message "$Name source parses"
    $node = @($ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name }, $true))[0]
    Assert-True -Condition ($null -ne $node) -Message "$Name exists"
    return $node.Extent.Text
}

# UTC fixtures cover explicit Z, historical +08:00 values, and legacy values
# without an offset (which are interpreted as UTC rather than local time).
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'ConvertTo-UtcDateTime')
$normal = ConvertTo-UtcDateTime -Value '2026-07-28T08:00:00.0000000Z'
$oldOffset = ConvertTo-UtcDateTime -Value '2026-07-28T16:00:00.0000000+08:00'
$legacy = ConvertTo-UtcDateTime -Value '2026-07-28T08:00:00.0000000'
Assert-Equal -Actual $normal.ToString('o') -Expected '2026-07-28T08:00:00.0000000Z' -Message 'normal UTC timestamp'
Assert-Equal -Actual $oldOffset.ToString('o') -Expected '2026-07-28T08:00:00.0000000Z' -Message 'old offset timestamp'
Assert-Equal -Actual $legacy.ToString('o') -Expected '2026-07-28T08:00:00.0000000Z' -Message 'legacy no-offset timestamp'

# The gate must reject missing and corrupt watcher evidence, while accepting a
# fresh signal carrying a valid UTC timestamp.
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'ConvertTo-UtcDateTime')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Test-ReadySignalContent')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Normalize-HeadroomBaseUrl')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Test-RelayPendingRoleContract')
$rolePendingManager = Test-RelayPendingRoleContract -Role manager -AllowRelayPending
$rolePendingCodex = Test-RelayPendingRoleContract -Role codex -AllowRelayPending
$rolePendingReadinessOnly = Test-RelayPendingRoleContract -Role manager -AllowRelayPending -ReadinessOnly
$roleStrictCodex = Test-RelayPendingRoleContract -Role codex
Assert-True -Condition $rolePendingManager -Message 'manager may publish pending route before launch'
Assert-True -Condition $rolePendingCodex -Message 'codex may carry pending route before launch'
Assert-True -Condition (-not $rolePendingReadinessOnly) -Message 'ReadinessOnly rejects pending route allowance'
Assert-True -Condition $roleStrictCodex -Message 'codex strict path remains valid without pending allowance'
$gatewayRoot = Normalize-HeadroomBaseUrl -Value 'http://127.0.0.1:18787'
$headroomRoot = Normalize-HeadroomBaseUrl -Value 'http://127.0.0.1:18789'
Assert-Equal -Actual ($gatewayRoot.TrimEnd('/') + '/v1') -Expected 'http://127.0.0.1:18787/v1' -Message 'Codex proxy base uses gateway'
Assert-Equal -Actual $headroomRoot -Expected 'http://127.0.0.1:18789' -Message 'health base uses Headroom'

# Mirror the monitor's current thirteen-item /status contract (including
# official-dataplane).  Kompress deferred is warning-only (overall yellow),
# while overall red must fail closed.
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Get-ObjectProperty')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'ConvertTo-StatsNumber')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Test-MonitorStatus')
$monitorKeys = @(
    'gateway-livez', 'gateway-health', 'headroom-livez', 'headroom-health',
    'relay', 'route', 'official-dataplane', 'codex-connection', 'api', 'transport', 'kompress',
    'token-accounting', 'monitor-core'
)
$observedAt = [DateTime]::UtcNow.ToString('o')
$monitorItems = @($monitorKeys | ForEach-Object {
    $state = if ($_ -eq 'kompress') { 'yellow' } else { 'green' }
    [pscustomobject]@{
        key = $_
        label = $_
        state = $state
        summary = 'fixture'
        detail = 'fixture'
        source = 'offline fixture'
        observed_at = $observedAt
    }
})
$emptyIssues = [object[]]@()
$script:MonitorFixture = [pscustomobject][ordered]@{
    schema_version = 2
    generated_at = $observedAt
    stale_after_seconds = 90
    overall = 'yellow'
    items = $monitorItems
    metrics = [pscustomobject]@{}
    active_issues = $emptyIssues
    recent_recoveries = $emptyIssues
}
function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Uri)
    [pscustomobject]@{ TransportOk = $true; StatusCode = 200; ParseError = $false; Body = $script:MonitorFixture }
}
$yellowStatus = Test-MonitorStatus -Uri 'http://fixture/status'
Assert-True -Condition $yellowStatus.Ready -Message '13-item yellow monitor status is ready'
$script:MonitorFixture.overall = 'red'
$redStatus = Test-MonitorStatus -Uri 'http://fixture/status'
Assert-True -Condition (-not $redStatus.Ready) -Message 'red monitor status fails closed'
$redPendingStatus = Test-MonitorStatus -Uri 'http://fixture/status' -AllowRelayPending
Assert-True -Condition ($redPendingStatus.Ready -and $redPendingStatus.Reason -eq 'prelaunch_monitor_status_red') -Message 'prelaunch pending monitor accepts red status with explicit allowance'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('codexpp-startup-fixture-' + [IO.Path]::GetRandomFileName())
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
try {
    $signalPath = Join-Path $fixtureRoot 'route-ready.signal'
    Assert-True -Condition (-not (Test-ReadySignalContent -Path $signalPath)) -Message 'missing ready signal fails closed'
    [IO.File]::WriteAllText($signalPath, "not-a-timestamp`n", [Text.UTF8Encoding]::new($false))
    Assert-True -Condition (-not (Test-ReadySignalContent -Path $signalPath)) -Message 'corrupt ready signal fails closed'
    [IO.File]::WriteAllText($signalPath, ([DateTime]::UtcNow.ToString('o') + "`n"), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition (Test-ReadySignalContent -Path $signalPath) -Message 'fresh ready signal passes'

Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'ConvertTo-SafeText')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Write-StartupResult')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Get-ConfigHttpContract')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Get-ConfigProtectedContract')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Test-ConfigProtectedContract')
$configFixturePath = Join-Path $fixtureRoot 'config.toml'
[IO.File]::WriteAllText($configFixturePath, @'
model_provider = "CodexPlusPlus"
[model_providers.CodexPlusPlus]
wire_api = "responses"
base_url = "http://127.0.0.1:18787/v1"
service_tier = "default"
'@, [Text.UTF8Encoding]::new($false))
$configFixture = Get-ConfigHttpContract -Path $configFixturePath
Assert-True -Condition ($configFixture.Error -eq $null -and $configFixture.WireApi -eq 'responses' -and $null -eq $configFixture.SupportsWebsockets) -Message 'optional supports_websockets does not block proxy config contract'
$gateProtectedFixture = Get-ConfigProtectedContract -Path $configFixturePath
Assert-True -Condition ($gateProtectedFixture.Error -eq $null -and $gateProtectedFixture.WireApi -eq 'responses') -Message 'startup gate protected contract is readable'

# A Codex launch may enter with a pending route, but the post-launch relay
# gate must fail closed while helper 57321 is absent. Use this test process
# only as a live process fixture; no production executable or port is started.
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Test-ProcessSnapshot')
Invoke-Expression (Get-FunctionText -Path $gatePath -Name 'Wait-CodexProcessReadiness')
$RouteStatePath = Join-Path $fixtureRoot 'missing-route-state.json'
$ConfigPath = $configFixturePath
$ReadinessTimeoutSeconds = 0
$script:RelayHost = '127.0.0.1'
$script:RelayPort = 57321
function Write-Audit { param([string]$Level,[string]$Event,[hashtable]$Fields) }
function Test-RelayPort { return $false }
$readinessProcess = [Diagnostics.Process]::GetCurrentProcess()
try {
    $codexPendingTimeout = Wait-CodexProcessReadiness -Process $readinessProcess
    Assert-True -Condition (-not $codexPendingTimeout) -Message 'Codex pending launch fails when relay 57321 remains unavailable'
}
finally {
    $readinessProcess.Dispose()
}

# Route keeper pending/ready contract: helper-missing is publishable only with
# the explicit pending switch, and the published process route never mutates
# the supplier config.
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Get-ObjectProperty')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Get-ConfigProtectedContract')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Test-LocalRelayEndpoint')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Get-HeadroomRouteReadiness')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Replace-RouteFileAtomically')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Get-RouteStateDocument')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Write-RouteState')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Write-RouteHeartbeat')
Invoke-Expression (Get-FunctionText -Path $keeperPath -Name 'Assert-RouteStateWritten')
$ProxyBaseUrl = 'http://127.0.0.1:18787/v1'
$AllowRelayPending = $true
$ConfigPath = $configFixturePath
$SettingsPath = Join-Path $fixtureRoot 'settings.json'
$StatePath = Join-Path $fixtureRoot 'route-state.json'
$ReadySignalPath = Join-Path $fixtureRoot 'route-ready.signal'
$WatchStatePath = Join-Path $fixtureRoot 'route-watch.json'
$Mode = 'proxy'
$script:RelayPort = 57321
$script:HealthProbeTimeoutSeconds = 1
$script:RouteStateSchemaVersion = 3
$script:RouteContractVersion = 3
$script:RouteStateWriteFailed = $false
$script:RouteKeeperStartedAt = [DateTime]::UtcNow
$script:RouteKeeperScriptPath = $keeperPath
$script:WatchMode = $false
$script:RouteFixture = 'pending'
$heartbeatProtected = Get-ConfigProtectedContract -Path $configFixturePath
Assert-True -Condition ($heartbeatProtected.Error -eq $null -and $heartbeatProtected.WireApi -eq 'responses') -Message 'route keeper protected contract fixture is readable'
function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Uri)
    if ($Uri -like '*/livez') {
        return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; ParseError = $false; Body = [pscustomobject]@{ service = 'policy-gateway'; status = 'healthy'; alive = $true } }
    }
    $helper = if ($script:RouteFixture -eq 'ready') { [pscustomobject]@{ ok = $true; status_code = 200 } } elseif ($script:RouteFixture -eq 'malformed') { [pscustomobject]@{ ok = $false; status_code = 500 } } else { [pscustomobject]@{ ok = $false; status_code = $null } }
    $healthStatus = if ($script:RouteFixture -eq 'ready') { 200 } else { 503 }
    $healthBody = if ($script:RouteFixture -eq 'ready') {
        [pscustomobject]@{ service = 'policy-gateway'; status = 'healthy'; ready = $true; config = [pscustomobject]@{ openai_api_url = 'http://127.0.0.1:57321' }; checks = [pscustomobject]@{ headroom = [pscustomobject]@{ ok = $true }; helper = $helper } }
    } else {
        [pscustomobject]@{ service = 'policy-gateway'; status = 'degraded'; ready = $false; config = [pscustomobject]@{ openai_api_url = 'http://127.0.0.1:57321' }; checks = [pscustomobject]@{ headroom = [pscustomobject]@{ ok = $true }; helper = $helper } }
    }
    return [pscustomobject]@{ TransportOk = $true; StatusCode = $healthStatus; ParseError = $false; Body = $healthBody }
}
$pendingReadiness = Get-HeadroomRouteReadiness -AllowRelayPending
Assert-True -Condition ($pendingReadiness.Ready -and $pendingReadiness.Pending -and $pendingReadiness.Reason -eq 'helper_pending') -Message 'route keeper accepts exact helper-missing snapshot as pending'
$strictPending = Get-HeadroomRouteReadiness
Assert-True -Condition (-not $strictPending.Ready) -Message 'route keeper rejects helper-missing snapshot without pending switch'
$script:RouteFixture = 'ready'
$readyReadiness = Get-HeadroomRouteReadiness -AllowRelayPending
Assert-True -Condition ($readyReadiness.Ready -and -not $readyReadiness.Pending -and $readyReadiness.Reason -eq 'ready') -Message 'route keeper promotes helper-ready snapshot to ready'
$script:RouteFixture = 'malformed'
$malformedReadiness = Get-HeadroomRouteReadiness -AllowRelayPending
Assert-True -Condition (-not $malformedReadiness.Ready) -Message 'route keeper rejects malformed/reachable helper failure'
$script:RouteFixture = 'pending'
$configBefore = (Get-FileHash -LiteralPath $configFixturePath -Algorithm SHA256).Hash
Write-RouteState -Mode 'pureapi' -Protocol 'responses' -Action 'process-route-pending' -Status 'pending' -Reason 'helper pending fixture' -ConfigHash $configBefore -Provider 'CodexPlusPlus' -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $heartbeatProtected
Assert-RouteStateWritten
$pendingState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
Assert-True -Condition ([string]$pendingState.status -eq 'pending' -and [string]$pendingState.route_scope -eq 'process' -and [bool]$pendingState.config_mutated -eq $false -and [string]$pendingState.process_route_base_url -eq $ProxyBaseUrl -and [bool]$pendingState.allow_relay_pending) -Message 'pending route state is process-scoped and config immutable'
$configAfter = (Get-FileHash -LiteralPath $configFixturePath -Algorithm SHA256).Hash
Assert-Equal -Actual $configAfter -Expected $configBefore -Message 'pending route state leaves config hash unchanged'
$script:RouteFixture = 'ready'
Write-RouteState -Mode 'pureapi' -Protocol 'responses' -Action 'process-route' -Status 'ready' -Reason 'helper ready fixture' -ConfigHash $configBefore -Provider 'CodexPlusPlus' -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $heartbeatProtected
$readyState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
Assert-True -Condition ([string]$readyState.status -eq 'ready' -and [string]$readyState.route_scope -eq 'process') -Message 'single route refresh publishes ready state'
$script:WatchMode = $true
Write-RouteState -Mode 'pureapi' -Protocol 'responses' -Action 'process-route' -Status 'ready' -Reason 'heartbeat fixture' -ConfigHash $configBefore -Provider 'CodexPlusPlus' -ProcessRouteBaseUrl $ProxyBaseUrl -ProtectedContract $heartbeatProtected
$heartbeatSnapshot = [pscustomobject]@{ Ready = $true; Hash = $configBefore; Provider = 'CodexPlusPlus'; BaseUrl = $ProxyBaseUrl; Protected = $heartbeatProtected }
$metadataConfig = (Get-Content -LiteralPath $configFixturePath -Raw).Replace('service_tier = "default"', 'service_tier = "updated"')
[IO.File]::WriteAllText($configFixturePath, $metadataConfig, [Text.UTF8Encoding]::new($false))
$metadataHash = (Get-FileHash -LiteralPath $configFixturePath -Algorithm SHA256).Hash
$metadataProtected = Get-ConfigProtectedContract -Path $configFixturePath
$metadataSnapshot = [pscustomobject]@{ Ready = $true; Hash = $metadataHash; Provider = 'CodexPlusPlus'; BaseUrl = $ProxyBaseUrl; Protected = $metadataProtected }
Assert-True -Condition (Write-RouteHeartbeat -Snapshot $metadataSnapshot -EffectiveMode 'proxy') -Message 'ordinary provider metadata drift refreshes route-state hash atomically'
$metadataState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
Assert-Equal -Actual $metadataState.config_sha256 -Expected $metadataHash -Message 'heartbeat stores updated ordinary metadata hash'
$heartbeatSnapshot = $metadataSnapshot
$configBefore = $metadataHash
$heartbeatProtected = $metadataProtected
$protectedMutationConfig = $metadataConfig.Replace('wire_api = "responses"', 'wire_api = "chat"')
[IO.File]::WriteAllText($configFixturePath, $protectedMutationConfig, [Text.UTF8Encoding]::new($false))
$protectedMutationHash = (Get-FileHash -LiteralPath $configFixturePath -Algorithm SHA256).Hash
$protectedMutation = Get-ConfigProtectedContract -Path $configFixturePath
$protectedMutationSnapshot = [pscustomobject]@{ Ready = $true; Hash = $protectedMutationHash; Provider = 'CodexPlusPlus'; BaseUrl = $ProxyBaseUrl; Protected = $protectedMutation }
Assert-True -Condition (-not (Write-RouteHeartbeat -Snapshot $protectedMutationSnapshot -EffectiveMode 'proxy')) -Message 'protected wire_api mutation rejects heartbeat'
[IO.File]::WriteAllText($configFixturePath, $metadataConfig, [Text.UTF8Encoding]::new($false))
$heartbeatStableFields = @('status', 'route_scope', 'config_mutated', 'config_sha256', 'provider', 'process_route_base_url', 'route_keeper_pid', 'route_keeper_script_path', 'route_keeper_mode')
for ($cycle = 1; $cycle -le 3; $cycle++) {
    $cycleState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $cycleState.timestamp_utc = '2020-01-01T00:00:00.0000000Z'
    [IO.File]::WriteAllText($StatePath, (($cycleState | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition (Write-RouteHeartbeat -Snapshot $heartbeatSnapshot -EffectiveMode 'proxy') -Message "route heartbeat cycle $cycle writes atomically"
    $heartbeatState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $heartbeatTimestamp = ConvertTo-UtcDateTime (Get-ObjectProperty $heartbeatState 'timestamp_utc')
    Assert-True -Condition ($null -ne $heartbeatTimestamp -and $heartbeatTimestamp -gt [DateTime]::UtcNow.AddSeconds(-30)) -Message "route heartbeat cycle $cycle is fresh"
    foreach ($field in $heartbeatStableFields) {
        Assert-Equal -Actual (Get-ObjectProperty $heartbeatState $field) -Expected (Get-ObjectProperty $cycleState $field) -Message "route heartbeat cycle $cycle preserves $field"
    }
}
$staleKeeperState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$staleKeeperState.route_keeper_pid = [int]$PID + 100000
[IO.File]::WriteAllText($StatePath, (($staleKeeperState | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Assert-True -Condition (-not (Write-RouteHeartbeat -Snapshot $heartbeatSnapshot -EffectiveMode 'proxy')) -Message 'stale keeper identity rejects heartbeat'
$configAfterHeartbeat = (Get-FileHash -LiteralPath $configFixturePath -Algorithm SHA256).Hash
Assert-Equal -Actual $configAfterHeartbeat -Expected $configBefore -Message 'route heartbeat leaves config hash unchanged'
$startupResultPath = Join-Path $fixtureRoot 'startup-result.json'
    $Role = 'codex'
    Write-StartupResult -Status 'failed' -ExitCode 3 -ErrorCode 'readiness_failed' -Stage 'readiness' -Reason 'bearer sk-test-secret was unavailable'
    Assert-True -Condition (Test-Path -LiteralPath $startupResultPath -PathType Leaf) -Message 'startup result is atomically materialized'
    $startupResult = Get-Content -LiteralPath $startupResultPath -Raw | ConvertFrom-Json
    foreach ($field in @('schema_version', 'generated_at', 'role', 'status', 'exit_code', 'error_code', 'stage', 'reason')) {
        Assert-True -Condition ($null -ne $startupResult.PSObject.Properties[$field]) "startup result field $field"
    }
    Assert-Equal -Actual $startupResult.schema_version -Expected 1 -Message 'startup result schema version'
    Assert-Equal -Actual $startupResult.role -Expected 'codex' -Message 'startup result role'
    Assert-Equal -Actual $startupResult.status -Expected 'failed' -Message 'startup result status'
    Assert-Equal -Actual $startupResult.error_code -Expected 'readiness_failed' -Message 'startup result stable error code'
    Assert-True -Condition ([string]$startupResult.reason -notmatch '(?i)bearer\s+sk-test-secret|sk-test-secret') -Message 'startup result reason is redacted'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

$keeperSource = Get-Content -LiteralPath $keeperPath -Raw
$gateSource = Get-Content -LiteralPath $gatePath -Raw
$wrapperSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'codex-wrapper-bootstrap.vbs') -Raw
$managerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'codex-manager-bootstrap.vbs') -Raw
Assert-True -Condition ($keeperSource -match 'error_code\s*=') -Message 'route state keeps error_code'
Assert-True -Condition ($keeperSource -match 'stage\s*=') -Message 'route state keeps stage'
Assert-True -Condition ($keeperSource -match 'Test-ActiveProxyContract') -Message 'proxy-compliant config bypasses unknown snapshot rejection'
Assert-True -Condition ($keeperSource -match 'function\s+Write-RouteHeartbeat' -and $keeperSource -match 'config_mutated' -and $keeperSource -match 'route_keeper_pid' -and $keeperSource -match 'Replace-RouteFileAtomically' -and $keeperSource -match 'RouteHeartbeatIntervalSeconds') -Message 'route keeper heartbeat validates identity/config and writes atomically'
Assert-True -Condition ($keeperSource -match 'Write-RouteHeartbeat\s+-Snapshot\s+\$snapshot\s+-EffectiveMode\s+\$effectiveMode' -and $keeperSource -match '\[Math\]::Min\(\$PollSeconds,\s*\$script:RouteHeartbeatIntervalSeconds\)') -Message 'watch loop schedules bounded route heartbeats'
Assert-True -Condition ((@($gateSource -split "`r?`n" | Where-Object { $_ -match '^\s*exit\s+' }).Count -eq 1) -and ($gateSource -match 'function Exit-Startup') -and ($gateSource -match 'Exit-Startup\s+-ExitCode 3')) -Message 'startup gate routes explicit exits through result helper'
Assert-True -Condition ($gateSource -match 'schema_version\s*=\s*1' -and $gateSource -match 'generated_at\s*=\s*\[DateTime\]::UtcNow' -and $gateSource -match 'StartupResultPath') -Message 'startup result contract is UTC and configurable'
Assert-True -Condition ($wrapperSource -match 'ReadStartupFailure' -and $wrapperSource -match 'startup-result\.json' -and $wrapperSource -match 'schema_version' -and $wrapperSource -match 'DateDiff\("s"') -Message 'direct wrapper validates fresh startup result before fallback'
Assert-True -Condition ($managerSource -match 'ReadStartupFailure' -and $managerSource -match 'startup-result\.json' -and $managerSource -match 'schema_version' -and $managerSource -match 'DateDiff\("s"') -Message 'manager bootstrap validates fresh startup result before fallback'
Assert-True -Condition ($gateSource -notmatch 'Get-Date\s+-Format') -Message 'startup audit timestamps are UTC'
Assert-True -Condition ($gateSource -match "HeadroomBaseUrl = 'http://127\.0\.0\.1:18789'") -Message 'Headroom defaults to 18789'
Assert-True -Condition ($gateSource -match "GatewayBaseUrl = 'http://127\.0\.0\.1:18787'") -Message 'gateway defaults to 18787'
Assert-True -Condition ($gateSource -match "MonitorBaseUrl = 'http://127\.0\.0\.1:18788'") -Message 'monitor remains on 18788'
Assert-True -Condition ($gateSource -match '\$script:ProxyBaseUrl = \(Normalize-HeadroomBaseUrl -Value \$GatewayBaseUrl\)') -Message 'route keeper proxy derives from gateway'
Assert-True -Condition ($gateSource -notmatch '\$script:ProxyBaseUrl = \(Normalize-HeadroomBaseUrl -Value \$HeadroomBaseUrl\)') -Message 'Headroom is not used as Codex base'
Assert-True -Condition ($gateSource -match '-File \$EnsureScript -Port \$gatewayPort -HeadroomPort \$headroomPort') -Message 'ensure receives gateway/headroom ports'
Assert-True -Condition ($gateSource -match 'gateway_port = \$gatewayPort' -and $gateSource -match 'headroom_port = \$headroomPort') -Message 'ensure audit records both ports'
Assert-True -Condition ($gateSource -match 'headroom_port = \(\[Uri\]\$root\)\.Port' -and $gateSource -match 'monitor_port =') -Message 'readiness audit records Headroom and monitor ports'

Write-Output 'codexpp startup-chain tests: PASS'
