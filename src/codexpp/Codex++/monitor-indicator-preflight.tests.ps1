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
$preflightPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts\Invoke-HeadroomIndicatorPreflight.ps1'))
$indicatorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'headroom-status-indicator.js'))

foreach ($name in @('Get-ObjectProperty', 'ConvertTo-SafeText', 'ConvertTo-StatsNumber', 'Get-StatsTrafficObservation', 'Get-MonitorApiObservation')) {
    Invoke-Expression (Get-FunctionText -Path $monitorPath -Name $name)
}

$baseBody = [pscustomobject]@{
    requests = [pscustomobject]@{
        total = 54
        failed = 0
        by_model = [pscustomobject]@{ 'passthrough:models' = 53 }
    }
    proxy_inbound = [pscustomobject]@{
        total = 100
        completed = 99
        active = 1
        by_path = [pscustomobject]@{
            '/stats' = 20
            '/v1/responses' = 1
        }
    }
    codex_ws = [pscustomobject]@{}
}

$baselineTraffic = Get-StatsTrafficObservation -Body $baseBody
Assert-True -Condition ($baselineTraffic.HttpCompleted -eq 1) -Message 'completed model baseline is inferred from total minus passthrough'
Assert-True -Condition (-not $baselineTraffic.HasPendingModelInbound) -Message 'global inbound active does not prove model activity'

$idle = Get-MonitorApiObservation -Traffic $baselineTraffic -Delta ([pscustomobject]@{ HttpCompleted = 0; InboundModel = 0; FailedTotal = 0 }) -HasSuccessfulModelRequest $false -HasUnrecoveredModelFailure $false
Assert-True -Condition ($idle.State -eq 'green' -and $idle.Summary -eq '当前周期空闲') -Message 'completed baseline without active model evidence is idle, not pending'
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$idle.IssueCode)) -Message 'idle baseline has no pending issue code'

$activeBody = $baseBody | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$activeBody.proxy_inbound | Add-Member -NotePropertyName active_by_path -NotePropertyValue ([pscustomobject]@{ '/v1/responses' = 1 })
$activeTraffic = Get-StatsTrafficObservation -Body $activeBody
Assert-True -Condition $activeTraffic.HasPendingModelInbound -Message 'model-scoped active_by_path proves pending model activity'
$pending = Get-MonitorApiObservation -Traffic $activeTraffic -Delta ([pscustomobject]@{ HttpCompleted = 0; InboundModel = 1; FailedTotal = 0 }) -HasSuccessfulModelRequest $true -HasUnrecoveredModelFailure $false
Assert-True -Condition ($pending.State -eq 'yellow' -and $pending.IssueCode -eq 'api.pending_completion') -Message 'pending issue requires explicit model active evidence'
$pendingWithoutBaseline = Get-MonitorApiObservation -Traffic $activeTraffic -Delta $null -HasSuccessfulModelRequest $false -HasUnrecoveredModelFailure $false
Assert-True -Condition ($pendingWithoutBaseline.IssueCode -eq 'api.pending_completion') -Message 'explicit model active evidence is sufficient even before a delta baseline'

$unknown = Get-MonitorApiObservation -Traffic ([pscustomobject]@{ HttpCompleted = 0; HasPendingModelInbound = $false }) -Delta ([pscustomobject]@{ HttpCompleted = 0; InboundModel = 1; FailedTotal = 0 }) -HasSuccessfulModelRequest $false -HasUnrecoveredModelFailure $false
Assert-True -Condition ($unknown.IssueCode -eq 'api.evidence_pending' -and $unknown.IssueCode -ne 'api.pending_completion') -Message 'inbound delta without active evidence remains baseline, not pending'

$completed = Get-MonitorApiObservation -Traffic $baselineTraffic -Delta ([pscustomobject]@{ HttpCompleted = 1; InboundModel = 1; FailedTotal = 0 }) -HasSuccessfulModelRequest $false -HasUnrecoveredModelFailure $false
Assert-True -Condition ($completed.State -eq 'green' -and $completed.Summary -eq '有完成请求') -Message 'completion delta is green'

$failed = Get-MonitorApiObservation -Traffic $baselineTraffic -Delta ([pscustomobject]@{ HttpCompleted = 0; InboundModel = 1; FailedTotal = 1 }) -HasSuccessfulModelRequest $true -HasUnrecoveredModelFailure $false
Assert-True -Condition ($failed.State -eq 'red' -and $failed.IssueCode -eq 'api.request_failed') -Message 'failure delta remains red'

$preflightTokens = $null
$preflightErrors = $null
$preflightAst = [System.Management.Automation.Language.Parser]::ParseFile($preflightPath, [ref]$preflightTokens, [ref]$preflightErrors)
Assert-True -Condition ($preflightErrors.Count -eq 0 -and $null -ne $preflightAst) -Message 'indicator preflight parses'
Assert-True -Condition ((Get-Content -LiteralPath $preflightPath -Raw) -match '(?i)json/version') -Message 'preflight only uses the safe CDP version endpoint'
Assert-True -Condition ((Get-Content -LiteralPath $preflightPath -Raw) -notmatch '(?i)json/list|Runtime\.evaluate|Page\.getResourceContent|Network\.getResponseBody') -Message 'preflight does not inspect page/session content'
$indicatorSource = Get-Content -LiteralPath $indicatorPath -Raw
Assert-True -Condition ($indicatorSource -match 'SCRIPT_VERSION\s*=\s*"1\.0\.0\.12"') -Message 'indicator contract version is bumped'
Assert-True -Condition (($indicatorSource | Select-String -Pattern 'official-dataplane' -AllMatches).Matches.Count -ge 2) -Message 'indicator includes official-dataplane in schema and initial rows'

Write-Output 'monitor-indicator-preflight.tests.ps1: PASS (12 assertions)'
