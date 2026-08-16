[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-FunctionText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message "source parses: $Path"
    $node = @($ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name }, $true))[0]
    Assert-True -Condition ($null -ne $node) -Message "function exists: $Name"
    return $node.Extent.Text
}

$monitorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'codexpp-headroom-monitor.ps1'))
$monitorSource = Get-Content -LiteralPath $monitorPath -Raw
Assert-True -Condition ($monitorSource -match "official-dataplane" -and $monitorSource -match "official_dataplane") -Message 'status exposes an independent official_dataplane item and field'
Assert-True -Condition ($monitorSource -match 'classification = if \(\$confirmed\) \{ ''confirmed'' \} elseif \(\$tcp\.VortexSocketObserved -and -not \$gatewayCodexRequest\) \{ ''bypass'' \} else \{ ''unknown'' \}') -Message 'classification order is confirmed, bypass, unknown'
$functionNames = @(
    'Get-ObjectProperty',
    'ConvertTo-SafeText',
    'ConvertTo-StatsNumber',
    'Get-OfficialDesktopProcessInventory',
    'Get-OfficialDataplaneTcpEvidence',
    'Get-OfficialDataplaneMetricEntryInfo',
    'Get-OfficialDataplaneGatewayEvidence',
    'New-EmptyOfficialDataplaneDocument',
    'Get-OfficialDataplaneSnapshot'
)
foreach ($name in $functionNames) {
    Invoke-Expression (Get-FunctionText -Path $monitorPath -Name $name)
}

$script:OfficialDataplaneGatewayBaseline = $null

$officialProcess = [pscustomobject]@{
    ProcessId = 101
    ParentProcessId = 100
    Name = 'ChatGPT.exe'
    Kind = 'chatgpt'
    ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.727.6591.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
}
$confirmedState = [pscustomobject]@{
    counters = [pscustomobject]@{ total = 12; ok = 12; error = 0; timeout = 0 }
    recent = @(
        [pscustomobject]@{
            request_id = 'gw_confirmed_1'
            correlation_id = 'corr_confirmed_1'
            request_category = 'responses'
            upstream_target = 'headroom'
            upstream_targets = @('headroom')
            user_agent_class = 'chatgpt'
            entrypoint = 'chatgpt'
            source_hint = 'entrypoint_header'
            synthetic = $false
            path = '/v1/responses'
        }
    )
}
$gatewaySocket = [pscustomobject]@{ OwningProcess = 101; RemoteAddress = '127.0.0.1'; RemotePort = 18787; LocalPort = 50001; State = 'Established' }
$confirmed = Get-OfficialDataplaneSnapshot `
    -Processes ([pscustomobject]@{ OfficialDesktop = @($officialProcess) }) `
    -GatewayState $confirmedState `
    -TcpConnections @($gatewaySocket) `
    -PreviousCounters ([pscustomobject]@{ total = 11; ok = 11; error = 0; timeout = 0 }) `
    -ObservedAt '2026-08-02T04:00:00Z'
Assert-True -Condition ($confirmed.classification -eq 'confirmed') -Message 'official PID TCP + Gateway delta + upstream evidence confirms official dataplane'
Assert-True -Condition ($confirmed.gateway_socket_observed -and -not $confirmed.vortex_socket_observed) -Message 'confirmed fixture records gateway socket only'
Assert-True -Condition ($confirmed.gateway_request_ids -contains 'gw_confirmed_1' -and $confirmed.gateway_correlation_ids -contains 'corr_confirmed_1') -Message 'request and correlation IDs are exposed without request bodies'
Assert-True -Condition ($confirmed.upstream_targets -contains 'headroom') -Message 'upstream target is retained'
Assert-True -Condition ($confirmed.gateway_user_agent_classes -contains 'chatgpt' -and $confirmed.gateway_entrypoints -contains 'chatgpt') -Message 'safe Gateway UA and entrypoint classes are consumed'

# The official app-server keeps UI/telemetry sockets to Vortex while its
# model requests go through Gateway.  A codex entrypoint in gateway recent is
# durable dataplane evidence even when the TCP sample only sees Vortex.
$codexEntrypointProcess = $officialProcess | Select-Object *
$codexEntrypointProcess.ProcessId = 105
$codexEntryState = [pscustomobject]@{
    counters = [pscustomobject]@{ total = 20; ok = 20; error = 0; timeout = 0 }
    recent = @([pscustomobject]@{ category = 'responses'; path = '/v1/responses'; request_id = 'gw_codex_1'; correlation_id = 'corr_codex_1'; entrypoint = 'codex'; user_agent_class = 'codex'; source_hint = 'user_agent'; upstream_target = 'headroom'; result = 'ok' })
}
$codexEntrypoint = Get-OfficialDataplaneSnapshot `
    -Processes ([pscustomobject]@{ OfficialDesktop = @($codexEntrypointProcess) }) `
    -GatewayState $codexEntryState `
    -TcpConnections @([pscustomobject]@{ OwningProcess = 105; RemoteAddress = '127.0.0.1'; RemotePort = 12450; LocalPort = 50005; State = 'Established' }) `
    -PreviousCounters ([pscustomobject]@{ total = 19; ok = 19; error = 0; timeout = 0 }) `
    -ObservedAt '2026-08-02T04:00:02Z'
Assert-True -Condition ($codexEntrypoint.classification -eq 'confirmed') -Message 'codex gateway entrypoint + upstream evidence confirms dataplane despite Vortex UI socket'
Assert-True -Condition ($codexEntrypoint.basis -contains 'gateway_codex_entrypoint') -Message 'codex entrypoint is recorded in basis'
Assert-True -Condition ($codexEntrypoint.vortex_socket_observed) -Message 'Vortex UI socket is still surfaced'

$bypassProcess = $officialProcess | Select-Object *
$bypassProcess.ProcessId = 102
$vortexSocket = [pscustomobject]@{ OwningProcess = 102; RemoteAddress = '127.0.0.1'; RemotePort = 7897; LocalPort = 50002; State = 'Established' }
$bypass = Get-OfficialDataplaneSnapshot `
    -Processes ([pscustomobject]@{ OfficialDesktop = @($bypassProcess) }) `
    -GatewayState ([pscustomobject]@{ counters = [pscustomobject]@{ total = 8; ok = 8; error = 0; timeout = 0 }; recent = @() }) `
    -TcpConnections @($vortexSocket) `
    -PreviousCounters ([pscustomobject]@{ total = 8; ok = 8; error = 0; timeout = 0 }) `
    -ObservedAt '2026-08-02T04:00:01Z'
Assert-True -Condition ($bypass.classification -eq 'bypass') -Message 'Vortex socket without Gateway confirmation is bypass'
Assert-True -Condition ($bypass.basis -contains 'official_pid_tcp_vortex_7897') -Message 'bypass basis records Vortex socket'
Assert-True -Condition (-not ($bypass.basis -contains 'official_pid_tcp_18787')) -Message 'bypass does not infer a Gateway socket'

$vortex12450Process = $officialProcess | Select-Object *
$vortex12450Process.ProcessId = 104
$vortex12450Socket = [pscustomobject]@{ OwningProcess = 104; RemoteAddress = '127.0.0.1'; RemotePort = 12450; LocalPort = 50004; State = 'Established' }
$vortex12450 = Get-OfficialDataplaneSnapshot `
    -Processes ([pscustomobject]@{ OfficialDesktop = @($vortex12450Process) }) `
    -GatewayState ([pscustomobject]@{ counters = [pscustomobject]@{ total = 0; ok = 0; error = 0; timeout = 0 }; recent = @() }) `
    -TcpConnections @($vortex12450Socket) `
    -PreviousCounters ([pscustomobject]@{ total = 0; ok = 0; error = 0; timeout = 0 }) `
    -ObservedAt '2026-08-02T04:00:01Z'
Assert-True -Condition ($vortex12450.classification -eq 'bypass') -Message 'SakuraCat/Vortex 12450 socket is bypass'
Assert-True -Condition ($vortex12450.vortex_ports -contains 12450) -Message '12450 is retained as a Vortex evidence port'
Assert-True -Condition ($vortex12450.basis -contains 'official_pid_tcp_vortex_12450') -Message '12450 bypass basis is explicit'

$unknownProcess = $officialProcess | Select-Object *
$unknownProcess.ProcessId = 103
$unknown = Get-OfficialDataplaneSnapshot `
    -Processes ([pscustomobject]@{ OfficialDesktop = @($unknownProcess) }) `
    -GatewayState ([pscustomobject]@{ recent = @([pscustomobject]@{ category = 'v1_other'; path = '/v1/models'; request_id = 'gw_probe' }) }) `
    -TcpConnections @() `
    -ObservedAt '2026-08-02T04:00:02Z'
Assert-True -Condition ($unknown.classification -eq 'unknown') -Message 'missing counters and sockets remain unknown'
Assert-True -Condition ($unknown.gateway_request_ids.Count -eq 0) -Message 'v1/models probe is filtered from official evidence'

$filtered = Get-OfficialDataplaneMetricEntryInfo -Entry ([pscustomobject]@{ request_category = 'responses'; path = '/health' })
Assert-True -Condition (-not $filtered.Eligible -and $filtered.Reason -eq 'internal_probe_path') -Message 'health endpoint is excluded'
$synthetic = Get-OfficialDataplaneMetricEntryInfo -Entry ([pscustomobject]@{ request_category = 'responses'; path = '/v1/responses'; synthetic = $true; synthetic_run_id = 'syn_fixture' })
Assert-True -Condition (-not $synthetic.Eligible -and $synthetic.Synthetic) -Message 'synthetic model request is excluded from official attribution'

$script:OfficialDataplaneGatewayBaseline = $null
$first = Get-OfficialDataplaneGatewayEvidence -GatewayState $confirmedState
Assert-True -Condition ($first.BaselinePending -and -not $first.CounterDelta.available -and $null -eq $first.CounterDelta.total) -Message 'first Gateway sample establishes a baseline'
$secondState = $confirmedState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$secondState.counters.total = 13
$secondState.counters.ok = 13
$second = Get-OfficialDataplaneGatewayEvidence -GatewayState $secondState
Assert-True -Condition ($second.CounterDelta.available -and $second.CounterDelta.total -eq 1) -Message 'subsequent Gateway sample reports a same-window counter delta'

Write-Output 'official-dataplane-monitor.tests.ps1: PASS (18 assertions)'
