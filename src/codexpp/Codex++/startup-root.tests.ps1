[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Read-Source {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $projectRoot $RelativePath
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "source exists: $RelativePath"
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Parser {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $projectRoot $RelativePath
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Message "PowerShell parser: $RelativePath"
}

$start = Read-Source -RelativePath 'scripts\Start-HeadroomForCodexPP.ps1'
$startupGate = Read-Source -RelativePath 'src\codexpp\Codex++\codexpp-startup-gate.ps1'
$routeKeeper = Read-Source -RelativePath 'src\codexpp\Codex++\codexpp-route-keeper.ps1'
$reconcile = Read-Source -RelativePath 'src\headroom\codexpp-headroom\reconcile-codexpp.ps1'
$headroomStart = Read-Source -RelativePath 'src\headroom\codexpp-headroom\start-headroom.ps1'
$headroomEnsure = Read-Source -RelativePath 'src\headroom\codexpp-headroom\ensure-headroom.ps1'
$headroomLauncher = Read-Source -RelativePath 'src\headroom\codexpp-headroom\headroom-launcher.py'
$installRuntime = Read-Source -RelativePath 'scripts\Install-HeadroomRuntime.ps1'
$monitor = Read-Source -RelativePath 'src\codexpp\Codex++\codexpp-headroom-monitor.ps1'
$manager = Read-Source -RelativePath 'src\codexpp\Codex++\codex-manager-bootstrap.vbs'
$wrapper = Read-Source -RelativePath 'src\codexpp\Codex++\codex-wrapper-bootstrap.vbs'
$legacy = Read-Source -RelativePath 'src\codexpp\Codex++\codexpp-simple-launcher.vbs'
$launch = Read-Source -RelativePath 'scripts\Launch-HeadroomForCodexPP.vbs'
$visibleLauncher = Read-Source -RelativePath 'scripts\Start-HeadroomWithProgress.ps1'

foreach ($path in @(
        'scripts\Start-HeadroomForCodexPP.ps1',
        'scripts\Start-HeadroomWithProgress.ps1',
        'src\codexpp\Codex++\codexpp-startup-gate.ps1',
        'src\codexpp\Codex++\codexpp-route-keeper.ps1',
        'src\headroom\codexpp-headroom\reconcile-codexpp.ps1',
        'src\headroom\codexpp-headroom\start-headroom.ps1',
        'src\codexpp\Codex++\codexpp-headroom-monitor.ps1')) {
    Assert-Parser -RelativePath $path
}

Assert-True -Condition ($launch -match '(?i)Start-HeadroomWithProgress\.ps1' -and $launch -match 'WScript\.ScriptFullName' -and $launch -match 'QuoteArg' -and $launch -match 'ShellExecute' -and $launch -match '"runas"' -and $launch -match ', 1' -and $launch -match 'WindowStyle Normal' -and $launch -notmatch 'WindowStyle Hidden' -and $launch -match '--phase-b' -and $start -match '\$PhaseB') -Message 'root VBS delegates to the visible elevated progress launcher and supports deferred PHASE-B activation'
Assert-True -Condition ($visibleLauncher -match 'Start-HeadroomForCodexPP\.ps1' -and $visibleLauncher -match 'headroom-start-result\.json' -and $visibleLauncher -match 'OverallTimeoutSeconds' -and $visibleLauncher -match 'Read-FreshStartResult' -and $visibleLauncher -match 'Read-Host' -and $visibleLauncher -match 'SuccessDisplaySeconds' -and $visibleLauncher -match 'NoPauseOnFailure') -Message 'visible launcher has bounded progress, stale-result protection, success auto-close and failure pause'
Assert-True -Condition ($start -match '\$BrokerPort\s*=\s*18790' -and $start -match '/readyz' -and $start -match 'HEADROOM_KOMPRESS_ENDPOINT') -Message 'broker fixed port and endpoint are hard gates'
Assert-True -Condition ($start -match 'kompress_broker\.app:app' -and $start -match 'source_hash' -and $start -match 'config_sha256' -and $start -match 'route_state') -Message 'module/hash/config/route evidence is required'
Assert-True -Condition ($start -match 'KompressEndpoint' -and $start -match "status.*-ne\s*'deferred'" -and $start -match 'Stop-ManagedProcessGracefully') -Message 'deferred readiness and graceful broker shutdown are covered'
Assert-True -Condition ($start -match 'Local\\HeadroomForCodexPP\.Start' -and $manager -match '-SkipEnsure' -and $manager -match 'codexpp-startup-gate') -Message 'startup mutex and manager gate ownership are explicit'
Assert-True -Condition ($start -match 'clientBootstrap' -and $start -match 'managed-codex-processes\.json' -and $start -match 'Confirm-DirectProcessRestart') -Message 'root entry restarts direct processes and launches both manager and client'
Assert-True -Condition ($start -match 'clientArgs\s*=\s*.*AllowRelayPending' -and $manager -match 'SkipEnsure.*AllowRelayPending' -and $wrapper -match 'allowRelayPending' -and $wrapper -match 'AllowRelayPending') -Message 'root manager/client bootstrap passes explicit pending mode only through startup arguments'
Assert-True -Condition ($start -match 'if\s*\(-not\s+\$ServicesOnly\)' -and $start -match 'Test-Ready\s+-ServiceScope:\$ServicesOnly') -Message 'services-only startup never restarts Codex++ and uses service-scope readiness'
Assert-True -Condition ($start -match '&\s+\$ensureScript' -and $start -notmatch 'pwsh\.exe[^\r\n]+-File\s+\$ensureScript') -Message 'root invokes the service ensure script in-process without a persistent native pipe'
Assert-True -Condition ($start -match 'Write-BrokerState\s+-ProcessId\s+\$listenerPid' -and $start -match 'broker_identity_publish_failed') -Message 'cold broker identity is published before managed validation'
Assert-True -Condition ($start -match 'kompress-broker-runtime\.json' -and $start -match 'invocation_path' -and $start -match 'StartsWith\(\$quotedInvocation') -Message 'broker runtime metrics and managed process identity are separate and venv invocation is verified'
Assert-True -Condition ($start -match 'function\s+Ensure-Monitor' -and $start -match 'Test-ManagedMonitorIdentity' -and $start -match 'monitor_port_conflict_unmanaged:18788' -and $start -match 'instance_id' -and $start -match 'started_at') -Message 'HTTP.sys-backed monitor has a managed identity gate'
Assert-True -Condition ($start -match 'function\s+Test-GatewayReadinessSnapshot' -and $start -match 'AllowRelayPending' -and $start -match 'readiness_failed_after_client') -Message 'root readiness has an explicit pre-client relay-pending phase and post-client full gate'
Assert-True -Condition ($start -match 'function\s+Wait-StrictReadiness' -and $start -match '\$postClientDeadline' -and $start -match 'Wait-StrictReadiness\s+-DeadlineUtc\s+\$postClientDeadline' -and $start -match 'Start-Sleep -Milliseconds 500') -Message 'post-client strict readiness waits within a bounded polling budget'
Assert-True -Condition ($start -match 'function\s+Test-RouteStateContract' -and $start -match 'route_state_contract_invalid_before_managed_state' -and $start -match 'managed_codex_state_identity_invalid_after_readiness') -Message 'root validates process route state and managed identity around state publication'
Assert-True -Condition ($start -match 'function\s+Invoke-PhaseBActivation' -and $start -match 'phase_b_requires_codexpp_quiescent' -and $start -match 'Remove-HeadroomAggregateRelay\.ps1' -and $start -match 'Register-HeadroomUserScript\.ps1' -and $start -match '\$PhaseB') -Message 'PHASE-B mutations are deferred behind an explicit quiescent-process gate'
Assert-True -Condition ($start -match 'function\s+Get-ConfigProtectedContract' -and $start -match 'function\s+Test-ConfigProtectedContract' -and $start -match 'manager_config_protected_contract_changed_during_startup' -and $start -match 'config_changed_after_manager') -Message 'manager metadata changes are allowed only when provider and Base URL protections remain unchanged'
Assert-True -Condition ($start -match 'function\s+ConvertTo-UtcDateTimeValue' -and $start -match 'DateTimeStyles\]::RoundtripKind' -and $start -match 'ConvertTo-UtcDateTimeValue\s+-Value\s+\$entry(?:\[0\])?\.started_at_utc') -Message 'managed state timestamps use typed UTC conversion without stringifying DateTime'
Assert-True -Condition ($start -match 'Get-ExactExecutableProcesses\s+-ExecutablePaths\s+@\(\$managerExe,\s*\$clientExe\)' -and $start -match 'currentProcesses\.Count\s+-ne\s*2' -and $start -match 'seenProcessIds') -Message 'managed state requires the complete exact Manager/Client process set'
Assert-True -Condition ($start -match 'function\s+Test-StaleRouteKeeperIdentity' -and $start -match 'function\s+Stop-StaleRouteKeeper' -and $start -match 'stale_route_keeper_identity_ambiguous' -and $start -match 'routeWatchStatePath' -and $start -match 'Get-ExactExecutableProcesses') -Message 'cold start reclaims only a verified stale route watcher'
$managedStateCallIndex = $start.IndexOf("if (-not `$managedAlready) {`n            Write-ManagedCodexState")
$postClientWaitIndex = $start.IndexOf("if (-not (Wait-StrictReadiness -DeadlineUtc `$postClientDeadline)) { throw 'readiness_failed_after_client' }")
$managerReadinessIndex = if ($postClientWaitIndex -ge 0) { $start.IndexOf('Invoke-ManagerReadiness', $postClientWaitIndex) } else { -1 }
Assert-True -Condition ($managedStateCallIndex -ge 0 -and $postClientWaitIndex -gt $managedStateCallIndex -and $managerReadinessIndex -gt $postClientWaitIndex) -Message 'managed state is published before bounded post-client strict readiness'
Assert-True -Condition ($start -match 'monitorOverall' -and $start -match 'AllowRelayPending\s*-and\s*\$monitorOverall\s*-in\s*@\(''red'', ''yellow''\)') -Message 'root prelaunch monitor allows red/yellow only with relay-pending allowance'
Assert-True -Condition ($startupGate -match 'function\s+Test-GatewayReadinessContract' -and $startupGate -match 'function\s+Wait-Readiness' -and $startupGate -match 'function\s+Test-RelayPendingRoleContract' -and $startupGate -match '\[ValidateSet\(''codex'', ''manager''\)\]\[string\]\$Role' -and $startupGate -match 'pending_mode_invalid' -and $startupGate -match 'ReadinessOnly') -Message 'startup gate scopes relay-pending allowance to manager/codex launch and rejects ReadinessOnly'
Assert-True -Condition ($startupGate -match 'function\s+Test-MonitorStatus' -and $startupGate -match 'Test-MonitorStatus\s+-Uri\s+\$script:MonitorStatusUrl\s+-AllowRelayPending') -Message 'startup gate propagates relay-pending allowance to monitor status only in prelaunch readiness'
Assert-True -Condition ($startupGate -match '\[switch\]\$AllowRelayPending' -and $startupGate -match 'Invoke-RouteKeeper\s+-AllowRelayPending' -and $startupGate -match 'Start-RouteKeeperWatch\s+-AllowRelayPending' -and $startupGate -match 'Test-RouteReadyState\s+-RequireSignal\s+-AllowRelayPending') -Message 'startup gate propagates explicit pending mode through route keeper and route-state checks'
Assert-True -Condition ($startupGate -match 'Wait-CodexProcessReadiness\s+-Process\s+\$process' -and $startupGate -match '\$Role\s*-eq\s*''codex''\s*-and\s*-not\s*\$officialBypass') -Message 'Codex pending launch remains strict on relay readiness after process creation'
Assert-True -Condition ($routeKeeper -match '\[switch\]\$AllowRelayPending' -and $routeKeeper -match '-Status\s+\$routeStatus' -and $routeKeeper -match "route_scope\s*=\s*'process'" -and $routeKeeper -match 'config_mutated\s*=\s*\$false') -Message 'route keeper publishes pending/ready process-scope state without config mutation'
Assert-True -Condition ($routeKeeper -match 'Get-HeadroomRouteReadiness' -and $routeKeeper -match 'helper\.ok' -and $routeKeeper -match 'status_code' -and $routeKeeper -match 'process-route-pending') -Message 'route keeper pending contract requires exact helper-missing Gateway health'
Assert-True -Condition ($start -match '&\s+\$ensureScript' -and $start -match '-KompressEndpoint\s+\$brokerUrl' -and $start -match '-AllowRelayPending') -Message 'root service ensure explicitly enables only the pre-client relay-pending phase'
Assert-True -Condition ($headroomEnsure -match 'function\s+Test-GatewaySnapshot' -and $headroomEnsure -match 'function\s+Test-GatewayHealthy' -and $headroomEnsure -match 'function\s+Ensure-PolicyGateway' -and $headroomEnsure -match '-AllowRelayPending') -Message 'ensure gateway has an explicit relay-pending contract'
Assert-True -Condition ($headroomEnsure -match 'status_code' -and $headroomEnsure -match 'headroom\.ok' -and $headroomEnsure -match 'helper\.ok') -Message 'ensure relay-pending contract requires helper missing and healthy Headroom checks'
Assert-True -Condition ($monitor -match 'monitor_source_sha256' -and $monitor -match 'monitor_script_path' -and $monitor -match 'runtime_root' -and $monitor -match 'monitor\s*=\s*\[ordered\]') -Message 'monitor publishes PID/path/hash/runtime identity in state and status'
Assert-True -Condition ($start -match 'QueryFullProcessImageName' -and $start -match 'ProcessQueryLimitedInformation' -and $start -match 'Get-ProcessExecutablePath\s+-ProcessId') -Message 'elevated Codex++ paths use the limited-information Windows API fallback'
Assert-True -Condition ($start -match 'quotedBrokerModuleRoot\s*=' -and $start -match '''--app-dir'',\s*\$quotedBrokerModuleRoot') -Message 'broker app-dir survives spaces in the project path'
Assert-True -Condition ($manager -notmatch 'launching manager UI' -and $manager -match ' -SkipEnsure') -Message 'manager is not launched before the gate'
Assert-True -Condition ($wrapper -match ' -Role codex ' -and $wrapper -match 'codexpp-startup-gate' -and $wrapper -match 'EnsureScript') -Message 'direct client wrapper still uses source gate and ensure path'
Assert-True -Condition ($wrapper -notmatch 'If Not WaitForActivationReady' -and $wrapper -match 'ReadStartupFailure\("codex"') -Message 'client wrapper uses the root gate instead of the retired activation marker'
Assert-True -Condition ($legacy -match 'Launch-HeadroomForCodexPP\.vbs' -and $legacy -notmatch 'codex-plus-plus\.exe') -Message 'legacy simple launcher delegates to root entry'
Assert-True -Condition ($start -match 'runtimeRoot\s*=\s*Join-Path\s+\$projectRoot\s+''runtime''' -and $start -match 'brokerPython\s*=\s*Join-Path\s+\$runtimePythonRoot\s+''Scripts\\python\.exe''' -and $start -match 'runtimeStateRoot' -and $start -match 'runtimeLogRoot') -Message 'managed runtime paths live under the project root'
Assert-True -Condition ($headroomStart -match 'HEADROOM_WORKSPACE_DIR' -and $headroomStart -match 'HEADROOM_CONFIG_DIR' -and $headroomEnsure -match 'HEADROOM_WORKSPACE_DIR' -and $headroomEnsure -match 'HEADROOM_CONFIG_DIR') -Message 'Headroom official workspace/config paths are pinned under the project root'
Assert-True -Condition ($start -match 'HEADROOM_WORKSPACE_DIR' -and $start -match 'HEADROOM_CONFIG_DIR') -Message 'Kompress broker inherits the project-root Headroom workspace/config paths'
Assert-True -Condition (($start + $headroomStart + $headroomEnsure + $manager + $wrapper) -notmatch '(?i)\.headroom-venv|runtime-artifacts|AppData\\Roaming\\Codex\+\+\\codexpp-(?:route|headroom)') -Message 'active startup chain has no legacy C-drive Headroom runtime path'
Assert-True -Condition ($start -match 'fastPathServicesOk\s*=\s*\$false' -and $start -match 'Port presence alone is not proof') -Message 'startup root does not trust a port-only fast path'
Assert-True -Condition ($headroomLauncher -match 'HEADROOM_KOMPRESS_ENDPOINT' -and $headroomLauncher -match 'broker owns remote warmup') -Message 'Headroom launcher does not create a duplicate local Kompress session'
Assert-True -Condition ($installRuntime -match '--no-index' -and $installRuntime -match 'requirements-lock\.txt' -and $installRuntime -match 'patch_hash_mismatch') -Message 'runtime can be rebuilt from the offline wheelhouse with verified patches'
Assert-True -Condition ($monitor -match 'ManagedCodexStatePath' -and $monitor -match 'kompress_broker\s*=' -and $monitor -match "schema_version'\)\s*-eq\s*3" -and $monitor -match "route_scope'\)\s*-eq\s*'process'" -and $monitor -match 'config_mutated') -Message 'monitor uses broker state and the process-route v3 contract'
Assert-True -Condition ($monitor -match 'function\s+ConvertTo-MonitorUtcDateTimeValue' -and $monitor -match 'DateTimeStyles\]::RoundtripKind') -Message 'monitor has a typed UTC timestamp conversion helper'
Assert-True -Condition ($monitor -match 'HeadroomMonitorProcessPathProbe' -and $monitor -match 'QueryFullProcessImageName' -and $monitor -match 'ProcessQueryLimitedInformation' -and $monitor -match 'function\s+Get-MonitorProcessExecutablePath' -and $monitor -match 'Get-MonitorProcessExecutablePath\s+-ProcessId' -and $monitor -match 'function\s+Get-MonitorExactCodexProcessInventory') -Message 'monitor has the native executable path fallback and exact Codex++ inventory'
Assert-True -Condition ($monitor -match 'function\s+Test-MonitorRouteKeeperIdentity' -and $monitor -match 'blank.*CommandLine|Elevated PowerShell' -and $monitor -match 'keeperIdentityValid') -Message 'monitor accepts verified elevated route keeper identity when command line is hidden'
$monitorTokens = $null
$monitorErrors = $null
$monitorAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'src\codexpp\Codex++\codexpp-headroom-monitor.ps1'), [ref]$monitorTokens, [ref]$monitorErrors)
$monitorUtcFunction = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-MonitorUtcDateTimeValue' }, $true))[0]
$managedProcessFunction = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ManagedCodexProcessState' }, $true))[0]
$routeFunction = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ClientRouteObservation' }, $true))[0]
Assert-True -Condition ($monitorErrors.Count -eq 0 -and $null -ne $monitorUtcFunction -and $null -ne $managedProcessFunction -and $null -ne $routeFunction -and $managedProcessFunction.Extent.Text -match 'ConvertTo-MonitorUtcDateTimeValue' -and $routeFunction.Extent.Text -match 'ConvertTo-MonitorUtcDateTimeValue' -and $managedProcessFunction.Extent.Text -notmatch '\[DateTimeOffset\]::Parse\(\[string\]' -and $routeFunction.Extent.Text -notmatch '\[DateTimeOffset\]::Parse\(\[string\]') -Message 'managed process and route freshness use typed UTC conversion'
Assert-True -Condition ($routeFunction.Extent.Text -notmatch 'IsLocalHeadroom|cppConfigLocal|codexConfigLocal') -Message 'active route observation never requires supplier Base URL mutation'

Assert-True -Condition ($routeFunction.Extent.Text -match '\$bypassWarning' -and $routeFunction.Extent.Text -match '\$independentOfficialCount' -and $routeFunction.Extent.Text -match '\$managedProcessesReady' -and $routeFunction.Extent.Text -match 'State\s*=\s*if') -Message 'route fixture contract keeps external official Codex warning-only and unmanaged Codex++ red'

$forbidden = @('File\.Replace', 'WriteAllText', 'WriteAllBytes', 'Set-Content', 'Out-File', 'Add-Content', 'Copy-Item', 'Move-Item', 'Set-TomlKeyLine', '(?im)^\s*base_url\s*=')
foreach ($pattern in $forbidden) {
    Assert-True -Condition (-not [regex]::IsMatch($reconcile, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) -Message "reconcile has no write primitive: $pattern"
}
Assert-True -Condition ($reconcile -match 'STATUS=READ_ONLY' -and $reconcile -match 'CONFIG_HASH_UNCHANGED') -Message 'reconcile emits read-only hash result'

# Exercise the readiness predicate with an in-memory endpoint fixture.  The
# deferred Kompress state must fail closed even when all transport endpoints
# otherwise report healthy.
$startPath = Join-Path $projectRoot 'scripts\Start-HeadroomForCodexPP.ps1'
$tokens = $null
$errors = $null
$startAst = [System.Management.Automation.Language.Parser]::ParseFile($startPath, [ref]$tokens, [ref]$errors)
foreach ($functionName in @('Get-PropertyValue', 'Get-ConfigProtectedContract', 'Test-ConfigProtectedContract', 'Test-GatewayReadinessSnapshot', 'Test-RouteStateContract', 'Update-RouteStateConfigHash', 'Wait-RouteStateContract', 'ConvertTo-UtcDateTimeValue', 'Test-Ready', 'Wait-StrictReadiness')) {
    $functionAst = @($startAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
    Assert-True -Condition ($null -ne $functionAst) -Message "readiness function exists: $functionName"
    Invoke-Expression $functionAst.Extent.Text
}
$waitFunctionAst = @($startAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-StrictReadiness' }, $true))[0]
Assert-True -Condition ($waitFunctionAst.Extent.Text -notmatch 'AllowRelayPending' -and $waitFunctionAst.Extent.Text -match 'Test-Ready' -and $waitFunctionAst.Extent.Text -match 'Start-Sleep -Milliseconds 500') -Message 'strict wait never accepts relay-pending readiness'
$jsonUtcValue = ('{"started_at_utc":"2026-08-01T04:00:00.0000000Z"}' | ConvertFrom-Json).started_at_utc
$jsonOffsetValue = ('{"started_at_utc":"2026-08-01T12:00:00.0000000+08:00"}' | ConvertFrom-Json).started_at_utc
$jsonUtcParsed = ConvertTo-UtcDateTimeValue -Value $jsonUtcValue
$jsonOffsetParsed = ConvertTo-UtcDateTimeValue -Value $jsonOffsetValue
$offsetParsed = ConvertTo-UtcDateTimeValue -Value ([DateTimeOffset]::Parse('2026-08-01T12:00:00.0000000+08:00'))
$expiredParsed = ConvertTo-UtcDateTimeValue -Value '2020-01-01T00:00:00.0000000Z'
Assert-True -Condition ($jsonUtcValue -is [DateTime] -and $jsonUtcValue.Kind -eq [DateTimeKind]::Utc -and $jsonUtcParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'ConvertFrom-Json UTC DateTime remains UTC'
Assert-True -Condition ($jsonOffsetValue -is [DateTime] -and $jsonOffsetValue.Kind -eq [DateTimeKind]::Local -and $jsonOffsetParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'ConvertFrom-Json local DateTime from UTC+8 is normalized to UTC'
Assert-True -Condition ($offsetParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'DateTimeOffset input uses UtcDateTime directly'
Assert-True -Condition (([DateTime]::UtcNow - $expiredParsed).TotalSeconds -gt 2) -Message 'expired timestamp remains outside the managed process start window'

$configProtectionFixture = Join-Path ([IO.Path]::GetTempPath()) ('headroom-config-protection-' + [IO.Path]::GetRandomFileName())
[IO.Directory]::CreateDirectory($configProtectionFixture) | Out-Null
try {
    $protectedConfigPath = Join-Path $configProtectionFixture 'config.toml'
    $protectedConfig = @'
model_provider = "CodexPlusPlus"
model = "fixture-model"
notify = "never"
[model_providers.CodexPlusPlus]
name = "fixture"
wire_api = "responses"
requires_openai_auth = true
base_url = "https://provider.example.invalid/v1"
experimental_bearer_token = "fixture-token"
'@
    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig, [Text.UTF8Encoding]::new($false))
    $protectedBefore = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition ($protectedBefore.Exists -and $null -eq $protectedBefore.Error -and $protectedBefore.BaseUrl -eq 'https://provider.example.invalid/v1') -Message 'protected config contract reads provider and Base URL without exposing credentials'
    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('notify = "never"', 'notify = "always"'), [Text.UTF8Encoding]::new($false))
    $protectedAfterMetadataChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterMetadataChange) -Message 'manager-owned metadata change does not invalidate protected config contract'
    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('base_url = "https://provider.example.invalid/v1"', 'base_url = "https://other.example.invalid/v1"'), [Text.UTF8Encoding]::new($false))
    $protectedAfterBaseUrlChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (-not (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterBaseUrlChange)) -Message 'Base URL change invalidates protected config contract'

    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('name = "fixture"', 'name = "manager-metadata"'), [Text.UTF8Encoding]::new($false))
    $protectedAfterProviderMetadataChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterProviderMetadataChange) -Message 'provider-section metadata change does not invalidate protected config contract'

    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('wire_api = "responses"', 'wire_api = "chat"'), [Text.UTF8Encoding]::new($false))
    $protectedAfterWireApiChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (-not (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterWireApiChange)) -Message 'wire_api change invalidates protected config contract'

    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('requires_openai_auth = true', 'requires_openai_auth = false'), [Text.UTF8Encoding]::new($false))
    $protectedAfterAuthChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (-not (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterAuthChange)) -Message 'requires_openai_auth change invalidates protected config contract'

    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('experimental_bearer_token = "fixture-token"', 'experimental_bearer_token = "rotated-fixture-token"'), [Text.UTF8Encoding]::new($false))
    $protectedAfterTokenValueChange = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterTokenValueChange) -Message 'bearer-token value rotation preserves presence contract without recording token'

    [IO.File]::WriteAllText($protectedConfigPath, $protectedConfig.Replace('experimental_bearer_token = "fixture-token"', '# bearer token removed'), [Text.UTF8Encoding]::new($false))
    $protectedAfterTokenRemoval = Get-ConfigProtectedContract -Path $protectedConfigPath
    Assert-True -Condition (-not (Test-ConfigProtectedContract -Before $protectedBefore -After $protectedAfterTokenRemoval)) -Message 'bearer-token field removal invalidates protected config contract'
}
finally {
    if (Test-Path -LiteralPath $configProtectionFixture) { Remove-Item -LiteralPath $configProtectionFixture -Recurse -Force -ErrorAction SilentlyContinue }
}

$invalidTimestampAccepted = $true
try { [void](ConvertTo-UtcDateTimeValue -Value 'not-a-timestamp') } catch { $invalidTimestampAccepted = $false }
Assert-True -Condition (-not $invalidTimestampAccepted) -Message 'invalid timestamp is rejected'
$monitorUtcFunctionAst = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-MonitorUtcDateTimeValue' }, $true))[0]
Assert-True -Condition ($null -ne $monitorUtcFunctionAst) -Message 'monitor UTC helper AST exists'
Invoke-Expression $monitorUtcFunctionAst.Extent.Text
$monitorJsonUtcParsed = ConvertTo-MonitorUtcDateTimeValue -Value $jsonUtcValue
$monitorJsonOffsetParsed = ConvertTo-MonitorUtcDateTimeValue -Value $jsonOffsetValue
$monitorOffsetParsed = ConvertTo-MonitorUtcDateTimeValue -Value ([DateTimeOffset]::Parse('2026-08-01T12:00:00.0000000+08:00'))
$monitorExpiredParsed = ConvertTo-MonitorUtcDateTimeValue -Value '2020-01-01T00:00:00.0000000Z'
Assert-True -Condition ($monitorJsonUtcParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'monitor UTC DateTime remains UTC'
Assert-True -Condition ($monitorJsonOffsetParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'monitor UTC+8 DateTime normalizes to UTC'
Assert-True -Condition ($monitorOffsetParsed.ToString('o') -eq '2026-08-01T04:00:00.0000000Z') -Message 'monitor DateTimeOffset input uses UtcDateTime directly'
Assert-True -Condition (([DateTime]::UtcNow - $monitorExpiredParsed).TotalSeconds -gt 2) -Message 'monitor expired timestamp remains outside the freshness window'
$monitorInvalidTimestampAccepted = $true
try { [void](ConvertTo-MonitorUtcDateTimeValue -Value 'not-a-timestamp') } catch { $monitorInvalidTimestampAccepted = $false }
Assert-True -Condition (-not $monitorInvalidTimestampAccepted) -Message 'monitor invalid timestamp is rejected'
Assert-True -Condition ($null -eq (ConvertTo-MonitorUtcDateTimeValue -Value $null)) -Message 'monitor null timestamp remains invalid'
$monitorPathFunctionAst = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MonitorProcessExecutablePath' }, $true))[0]
Assert-True -Condition ($null -ne $monitorPathFunctionAst) -Message 'monitor process path helper AST exists'
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
Invoke-Expression $monitorPathFunctionAst.Extent.Text
$nativeCurrentPath = [string][HeadroomMonitorProcessPathProbe]::Read($PID)
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($nativeCurrentPath)) -Message 'native path probe resolves the current PowerShell process'
$existingGetCimFunction = Get-Command -Name 'Get-CimInstance' -CommandType Function -ErrorAction SilentlyContinue
$existingGetCimBody = if ($null -eq $existingGetCimFunction) { $null } else { $existingGetCimFunction.ScriptBlock }
$script:mockCimExecutablePath = $nativeCurrentPath
try {
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName,[string]$Filter)
        return [pscustomobject]@{ ExecutablePath = $script:mockCimExecutablePath }
    }
    $cimPath = Get-MonitorProcessExecutablePath -ProcessId $PID
    Assert-True -Condition ($cimPath -eq $nativeCurrentPath) -Message 'CIM executable path is used when available'
    $script:mockCimExecutablePath = ''
    $fallbackPath = Get-MonitorProcessExecutablePath -ProcessId $PID
    Assert-True -Condition ($fallbackPath -eq $nativeCurrentPath) -Message 'native fallback matches the current process path when CIM is empty'
    $invalidPath = Get-MonitorProcessExecutablePath -ProcessId -1
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($invalidPath)) -Message 'native fallback fails closed for an inaccessible process'
}
finally {
    Remove-Item -LiteralPath 'Function:\Get-CimInstance' -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingGetCimBody) { Set-Item -LiteralPath 'Function:\Get-CimInstance' -Value $existingGetCimBody -Force }
    Remove-Variable -Name 'mockCimExecutablePath' -Scope Script -ErrorAction SilentlyContinue
}
$routeContractFixture = Join-Path ([IO.Path]::GetTempPath()) ('headroom-route-contract-' + [IO.Path]::GetRandomFileName())
[IO.Directory]::CreateDirectory($routeContractFixture) | Out-Null
$routeStatePath = Join-Path $routeContractFixture 'route-state.json'
$routeConfigHash = 'fixture-route-config-hash'
try {
    $pendingRouteState = [ordered]@{ status = 'pending'; route_scope = 'process'; config_mutated = $false; config_sha256 = $routeConfigHash }
    [IO.File]::WriteAllText($routeStatePath, (($pendingRouteState | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition (Test-RouteStateContract -ExpectedConfigHash $routeConfigHash -AllowPending) -Message 'pending route state contract passes before final readiness'
    Assert-True -Condition (-not (Test-RouteStateContract -ExpectedConfigHash $routeConfigHash)) -Message 'pending route state is not final readiness'
    $readyRouteState = [ordered]@{ status = 'ready'; route_scope = 'process'; config_mutated = $false; config_sha256 = $routeConfigHash }
    [IO.File]::WriteAllText($routeStatePath, (($readyRouteState | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Assert-True -Condition (Test-RouteStateContract -ExpectedConfigHash $routeConfigHash) -Message 'ready route state contract passes final readiness'
}
finally {
    if (Test-Path -LiteralPath $routeContractFixture) { Remove-Item -LiteralPath $routeContractFixture -Recurse -Force -ErrorAction SilentlyContinue }
}

# P26 race fixture: route-state config hash lags the live config hash (the
# one-shot route keeper and a freshly launched Manager both update config
# metadata around the same moment).  Wait-RouteStateContract must poll and
# converge instead of failing on the first stale observation.
$raceFixture = Join-Path ([IO.Path]::GetTempPath()) ('headroom-route-race-' + [IO.Path]::GetRandomFileName())
[IO.Directory]::CreateDirectory($raceFixture) | Out-Null
$script:routeStatePath = Join-Path $raceFixture 'route-state.json'
$raceConfigPath = Join-Path $raceFixture 'config.toml'
$staleHash = 'stale-config-hash'
$freshHash = 'fresh-config-hash'
try {
    # Live config already has the fresh hash; route-state still carries the
    # stale hash (the route keeper has not published its refresh yet).
    [IO.File]::WriteAllText($raceConfigPath, ("[project]`nname = 'race-fixture'`n"), [Text.UTF8Encoding]::new($false))
    $staleState = [ordered]@{ status = 'pending'; route_scope = 'process'; config_mutated = $false; config_sha256 = $staleHash }
    [IO.File]::WriteAllText($script:routeStatePath, (($staleState | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $protectedBefore = [pscustomobject]@{ fingerprint = 'race-fixture-protected'; sha256 = $staleHash }
    function Test-ConfigProtectedContract { param($Before, $After) return $true }
    function Update-RouteStateConfigHash {
        param([string]$ConfigHash, [object]$ProtectedContract)
        # Simulate the route keeper publishing its refresh a little late.
        Start-Sleep -Milliseconds 600
        $updated = [ordered]@{ status = 'ready'; route_scope = 'process'; config_mutated = $false; config_sha256 = $ConfigHash }
        [IO.File]::WriteAllText($script:routeStatePath, (($updated | ConvertTo-Json -Depth 4) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return $true
    }
    $raceStarted = [DateTime]::UtcNow
    # Note: the production caller passes the live config hash as
    # ExpectedConfigHash (the route keeper publishes its own refresh; the
    # wait's refresh branch covers a hash that drifts again while polling);
    # this fixture deliberately passes a STALE expected hash so the wait's
    # internal refresh-fallback branch is exercised.  Both paths share the
    # same poll/converge loop.
    $waited = Wait-RouteStateContract -ExpectedConfigHash $staleHash -ConfigPath $raceConfigPath -ProtectedContractBefore $protectedBefore -TimeoutSeconds 2 -PollIntervalSeconds 0.2
    $raceElapsed = ([DateTime]::UtcNow - $raceStarted).TotalSeconds
    Assert-True -Condition ($waited) -Message 'route-state race converges via polling'
    Assert-True -Condition ($raceElapsed -ge 0.4) -Message 'polling actually waited for the delayed refresh'
}
finally {
    if (Test-Path -LiteralPath $raceFixture) { Remove-Item -LiteralPath $raceFixture -Recurse -Force -ErrorAction SilentlyContinue }
}
$monitorScript = Join-Path $projectRoot 'src\codexpp\Codex++\codexpp-headroom-monitor.ps1'
$runtimeRoot = Join-Path $projectRoot 'runtime'
$monitorCommandFunction = @($startAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ProjectMonitorCommandLine' }, $true))[0]
Assert-True -Condition ($null -ne $monitorCommandFunction) -Message 'monitor command-line identity function exists'
Invoke-Expression $monitorCommandFunction.Extent.Text
$quotedMonitorCommand = 'pwsh.exe -NoProfile -File "' + $monitorScript + '" -RuntimeRoot "' + $runtimeRoot + '" -Watch'
Assert-True -Condition (Test-ProjectMonitorCommandLine -CommandLine $quotedMonitorCommand) -Message 'project monitor command line is recognized'
Assert-True -Condition (-not (Test-ProjectMonitorCommandLine -CommandLine 'pwsh.exe -NoProfile -File "C:\legacy\codexpp-headroom-monitor.ps1" -Watch')) -Message 'foreign monitor command line is rejected'
$brokerUrl = 'http://127.0.0.1:18790'
$headroomUrl = 'http://127.0.0.1:18789'
$gatewayUrl = 'http://127.0.0.1:18787'
$monitorUrl = 'http://127.0.0.1:18788'
$script:ReadinessKompressDeferred = $true
$script:ReadinessMonitorOverall = 'yellow'
function Test-ManagedMonitorIdentity { return $true }
function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -like '*18790/readyz') { return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; Body = [pscustomobject]@{ service = 'kompress-broker'; ready = $true; provider = 'CPUExecutionProvider'; backend = 'onnx' } } }
    if ($Url -like '*18788/status') { return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; Body = [pscustomobject]@{ schema_version = 2; overall = $script:ReadinessMonitorOverall } } }
    if ($Url -like '*18787/livez' -or $Url -like '*18789/livez') { return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; Body = [pscustomobject]@{ alive = $true } } }
    $kompress = if ($script:ReadinessKompressDeferred) { [pscustomobject]@{ enabled = $true; ready = $true; status = 'deferred' } } else { [pscustomobject]@{ enabled = $true; ready = $true; status = 'ready' } }
    if ($Url -like '*18789/health') { return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; Body = [pscustomobject]@{ ready = $true; checks = [pscustomobject]@{ kompress = $kompress } } } }
    return [pscustomobject]@{ TransportOk = $true; StatusCode = 200; Body = [pscustomobject]@{ ready = $true } }
}
Assert-True -Condition (-not (Test-Ready)) -Message 'deferred Kompress readiness fails closed'
$script:ReadinessKompressDeferred = $false
Assert-True -Condition (Test-Ready) -Message 'ready Kompress readiness passes fixture'
$script:ReadinessMonitorOverall = 'red'
Assert-True -Condition (-not (Test-Ready)) -Message 'prelaunch red monitor fails without relay-pending allowance'
Assert-True -Condition (Test-Ready -AllowRelayPending) -Message 'prelaunch red monitor passes only with relay-pending allowance'
$script:ReadinessMonitorOverall = 'yellow'

$existingTestReadyFunction = Get-Command -Name 'Test-Ready' -CommandType Function -ErrorAction SilentlyContinue
$existingTestReadyBody = if ($null -eq $existingTestReadyFunction) { $null } else { $existingTestReadyFunction.ScriptBlock }
$script:strictReadinessCalls = 0
$script:strictReadinessSequence = @($false, $true)
try {
    function Test-Ready {
        $script:strictReadinessCalls++
        $index = $script:strictReadinessCalls - 1
        if ($index -lt $script:strictReadinessSequence.Count) { return [bool]$script:strictReadinessSequence[$index] }
        return [bool]$script:strictReadinessSequence[-1]
    }
    $lagDeadline = [DateTime]::UtcNow.AddSeconds(3)
    Assert-True -Condition (Wait-StrictReadiness -DeadlineUtc $lagDeadline) -Message 'strict readiness tolerates one monitor poll lag'
    Assert-True -Condition ($script:strictReadinessCalls -eq 2) -Message 'strict readiness retries after an initial red result'
    $script:strictReadinessCalls = 0
    $script:strictReadinessSequence = @($false)
    $timeoutDeadline = [DateTime]::UtcNow.AddMilliseconds(100)
    Assert-True -Condition (-not (Wait-StrictReadiness -DeadlineUtc $timeoutDeadline)) -Message 'strict readiness times out on persistent red'
    Assert-True -Condition ($script:strictReadinessCalls -ge 1) -Message 'strict readiness performs a bounded timeout probe'
}
finally {
    Remove-Item -LiteralPath 'Function:\Test-Ready' -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingTestReadyBody) { Set-Item -LiteralPath 'Function:\Test-Ready' -Value $existingTestReadyBody -Force }
    Remove-Variable -Name 'strictReadinessCalls','strictReadinessSequence' -Scope Script -ErrorAction SilentlyContinue
}

$pendingLive = [pscustomobject]@{ TransportOk = $true; StatusCode = 200; ParseError = $false; Body = [pscustomobject]@{ service = 'policy-gateway'; status = 'healthy'; alive = $true } }
$pendingHealth = [pscustomobject]@{
    TransportOk = $true
    StatusCode = 503
    ParseError = $false
    Body = [pscustomobject]@{
        service = 'policy-gateway'
        status = 'degraded'
        ready = $false
        checks = [pscustomobject]@{
            headroom = [pscustomobject]@{ ok = $true; status_code = 200 }
            helper = [pscustomobject]@{ ok = $false; status_code = $null }
        }
    }
}
$readyHealth = [pscustomobject]@{ TransportOk = $true; StatusCode = 200; ParseError = $false; Body = [pscustomobject]@{ service = 'policy-gateway'; status = 'healthy'; ready = $true } }
$helperFailureHealth = [pscustomobject]@{
    TransportOk = $true
    StatusCode = 503
    ParseError = $false
    Body = [pscustomobject]@{
        service = 'policy-gateway'
        status = 'degraded'
        ready = $false
        checks = [pscustomobject]@{
            headroom = [pscustomobject]@{ ok = $true; status_code = 200 }
            helper = [pscustomobject]@{ ok = $false; status_code = 500 }
        }
    }
}
Assert-True -Condition (Test-GatewayReadinessSnapshot -Live $pendingLive -Health $pendingHealth -AllowRelayPending) -Message 'phase-1 accepts only the expected missing-helper snapshot'
Assert-True -Condition (-not (Test-GatewayReadinessSnapshot -Live $pendingLive -Health $pendingHealth)) -Message 'phase-2 rejects helper-pending Gateway health'
Assert-True -Condition (Test-GatewayReadinessSnapshot -Live $pendingLive -Health $readyHealth) -Message 'phase-2 accepts fully ready Gateway health'
Assert-True -Condition (-not (Test-GatewayReadinessSnapshot -Live $pendingLive -Health $helperFailureHealth -AllowRelayPending)) -Message 'phase-1 rejects a reachable-but-unhealthy helper'

$ensurePath = Join-Path $projectRoot 'src\headroom\codexpp-headroom\ensure-headroom.ps1'
$ensureTokens = $null
$ensureErrors = $null
$ensureAst = [System.Management.Automation.Language.Parser]::ParseFile($ensurePath, [ref]$ensureTokens, [ref]$ensureErrors)
$gatewaySnapshotFunction = @($ensureAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-GatewaySnapshot' }, $true))[0]
Assert-True -Condition ($null -ne $gatewaySnapshotFunction) -Message 'ensure gateway snapshot function exists'
Invoke-Expression $gatewaySnapshotFunction.Extent.Text
$ensurePendingBody = [pscustomobject]@{
    service = 'policy-gateway'
    status = 'degraded'
    ready = $false
    checks = [pscustomobject]@{
        headroom = [pscustomobject]@{ ok = $true; status_code = 200 }
        helper = [pscustomobject]@{ ok = $false; status_code = $null }
    }
}
$ensureReadyBody = [pscustomobject]@{ service = 'policy-gateway'; status = 'healthy'; ready = $true }
$ensureHeadroomFailureBody = [pscustomobject]@{
    service = 'policy-gateway'
    status = 'degraded'
    ready = $false
    checks = [pscustomobject]@{
        headroom = [pscustomobject]@{ ok = $false; status_code = 503 }
        helper = [pscustomobject]@{ ok = $false; status_code = $null }
    }
}
$ensureHelperFailureBody = [pscustomobject]@{
    service = 'policy-gateway'
    status = 'degraded'
    ready = $false
    checks = [pscustomobject]@{
        headroom = [pscustomobject]@{ ok = $true; status_code = 200 }
        helper = [pscustomobject]@{ ok = $false; status_code = 500 }
    }
}
Assert-True -Condition (Test-GatewaySnapshot -Body $ensurePendingBody -StatusCode 503 -Kind health -AllowRelayPending) -Message 'ensure retains exact missing-helper Gateway snapshot in phase 1'
Assert-True -Condition (-not (Test-GatewaySnapshot -Body $ensurePendingBody -StatusCode 503 -Kind health)) -Message 'ensure rejects pending Gateway snapshot without phase-1 allowance'
Assert-True -Condition (Test-GatewaySnapshot -Body $ensureReadyBody -StatusCode 200 -Kind health) -Message 'ensure accepts fully healthy Gateway snapshot'
Assert-True -Condition (-not (Test-GatewaySnapshot -Body $ensureHeadroomFailureBody -StatusCode 503 -Kind health -AllowRelayPending)) -Message 'ensure rejects degraded Headroom dependency'
Assert-True -Condition (-not (Test-GatewaySnapshot -Body $ensureHelperFailureBody -StatusCode 503 -Kind health -AllowRelayPending)) -Message 'ensure rejects reachable-but-unhealthy helper'

$gatePath = Join-Path $projectRoot 'src\codexpp\Codex++\codexpp-startup-gate.ps1'
$gateTokens = $null
$gateErrors = $null
$gateAst = [System.Management.Automation.Language.Parser]::ParseFile($gatePath, [ref]$gateTokens, [ref]$gateErrors)
foreach ($functionName in @('Get-ObjectProperty', 'Test-GatewayReadinessContract')) {
    $functionAst = @($gateAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
    Assert-True -Condition ($null -ne $functionAst) -Message "startup gate readiness function exists: $functionName"
    Invoke-Expression $functionAst.Extent.Text
}
Assert-True -Condition (Test-GatewayReadinessContract -Live $pendingLive -Health $pendingHealth -AllowRelayPending) -Message 'startup gate phase-1 accepts the missing-helper snapshot'
Assert-True -Condition (-not (Test-GatewayReadinessContract -Live $pendingLive -Health $pendingHealth)) -Message 'startup gate phase-2 rejects helper-pending health'
Assert-True -Condition (Test-GatewayReadinessContract -Live $pendingLive -Health $readyHealth) -Message 'startup gate phase-2 accepts ready health'
Assert-True -Condition (-not (Test-GatewayReadinessContract -Live $pendingLive -Health $helperFailureHealth -AllowRelayPending)) -Message 'startup gate phase-1 rejects helper status 500'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('headroom-startup-root-' + [IO.Path]::GetRandomFileName())
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $config = Join-Path $fixture 'config.toml'
    [IO.File]::WriteAllText($config, @'
model_provider = "CodexPlusPlus"
[model_providers.CodexPlusPlus]
wire_api = "responses"
base_url = "http://127.0.0.1:18787/v1"
supports_websockets = false
[mcp_servers.headroom]
command = "C:\Python\python.exe"
args = ["C:\headroom-launcher.py", "mcp", "serve", "--proxy-url", "http://127.0.0.1:18787"]
'@, [Text.UTF8Encoding]::new($false))
    $before = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $output = & pwsh -NoLogo -NoProfile -File (Join-Path $projectRoot 'src\headroom\codexpp-headroom\reconcile-codexpp.ps1') -ConfigPath $config -ExpectedLauncherPath 'C:\headroom-launcher.py'
    Assert-True -Condition ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'STATUS=READ_ONLY' -and ($output -join "`n") -match 'COMPATIBLE=true') -Message 'read-only fixture passes'
    $after = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    Assert-True -Condition ($before -eq $after) -Message 'config fixture hash is unchanged'

    [IO.File]::WriteAllText($config, @'
model_provider = "CodexPlusPlus"
[model_providers.CodexPlusPlus]
wire_api = "responses"
base_url = "https://provider.example.invalid/v1"
'@, [Text.UTF8Encoding]::new($false))
    $nonProxyBefore = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $nonProxyOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $projectRoot 'src\headroom\codexpp-headroom\reconcile-codexpp.ps1') -ConfigPath $config
    Assert-True -Condition ($LASTEXITCODE -eq 0 -and ($nonProxyOutput -join "`n") -match 'COMPATIBLE=true') -Message 'read-only reconcile accepts an existing non-proxy provider Base URL'
    $nonProxyAfter = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    Assert-True -Condition ($nonProxyBefore -eq $nonProxyAfter) -Message 'non-proxy Base URL fixture remains byte-identical'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}

# P27a: the root entry must refresh a stale managed-process snapshot when the
# live set is exactly one Manager and one Client, instead of forcing a restart.
$p27aRefreshPattern = 'existingCodexProcesses\.Count -eq 2 -and \$managerCount -eq 1 -and \$clientCount -eq 1'
Assert-True -Condition ($start -match 'Get-ExactExecutableProcesses -ExecutablePaths @\(\$managerExe, \$clientExe\)' -and $start -match $p27aRefreshPattern -and $start -match 'Write-ManagedCodexState' -and $start -match 'Confirm-DirectProcessRestart') -Message 'root refreshes stale managed snapshot for an exact 2-process set instead of restarting'
Assert-True -Condition ($start.IndexOf('Write-ManagedCodexState', $start.IndexOf('managerCount')) -gt 0) -Message 'snapshot refresh occurs before the confirm-restart fallback'

# P27a: the monitor self-heals a stale managed-process snapshot only when the
# exact live set matches, and stays red otherwise.
Assert-True -Condition ($monitor -match 'function\s+Update-StaleManagedCodexState' -and $monitor -match 'Get-MonitorExactCodexProcessInventory' -and $monitor -match 'source_hashes' -and $monitor -match 'Write-AtomicUtf8Text\s+-Path\s+\$script:ManagedCodexStatePath') -Message 'monitor has a fail-closed stale snapshot refresher'
$monitorUpdateFunction = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-StaleManagedCodexState' }, $true))[0]
Assert-True -Condition ($null -ne $monitorUpdateFunction -and $monitorUpdateFunction.Extent.Text -match 'Count -ne 2' -and $monitorUpdateFunction.Extent.Text -match 'livePids' -and $monitorUpdateFunction.Extent.Text -match 'statePids' -and $monitorUpdateFunction.Extent.Text -match 'started_at_utc') -Message 'monitor stale refresher requires exact 2-process set and differing PIDs'
$routeFunction2 = @($monitorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ClientRouteObservation' }, $true))[0]
Assert-True -Condition ($routeFunction2.Extent.Text -match 'Update-StaleManagedCodexState' -and $routeFunction2.Extent.Text -match 'managedProcessesReady = Test-ManagedCodexProcessState' -and $routeFunction2.Extent.Text -match 'if \(-not \$managedProcessesReady -and \$activeClient\)') -Message 'route observation re-observes stale managed state before declaring red'

# Route pinning: Invoke-OfficialRoutePinning rewrites base_url ONLY inside
# the codex_local_access section of the official config (never a neighbouring
# provider), and reports pinned=true with the Gateway URL.  This is the
# managed-chain guarantee that the official dataplane goes through Headroom
# on every launch while the manager supplier base_url/key stay untouched.
$pinFunction = @($startAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-OfficialRoutePinning' }, $true))[0]
Assert-True -Condition ($null -ne $pinFunction -and $pinFunction.Extent.Text -match 'codex_local_access' -and $pinFunction.Extent.Text -match '18787' -and $pinFunction.Extent.Text -match 'WriteAllText' -and $pinFunction.Extent.Text -match '\[\^') -Message 'startup chain has a section-scoped official route pinning helper'
Assert-True -Condition ($start -match '\$null = Invoke-OfficialRoutePinning') -Message 'startup chain calls the official route pinning helper'
$pinCallIndex = $start.IndexOf('$null = Invoke-OfficialRoutePinning')
$contractSnapshotIndex = $start.IndexOf('$managerConfigProtectedBefore = Get-ConfigProtectedContract')
Assert-True -Condition ($pinCallIndex -gt 0 -and $contractSnapshotIndex -gt 0 -and $pinCallIndex -lt $contractSnapshotIndex) -Message 'pinning runs before the protected-contract snapshot so disk/contract/route-state agree'

Write-Output 'startup-root fixture tests: PASS'
