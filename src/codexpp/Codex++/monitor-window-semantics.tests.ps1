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
foreach ($name in @(
        'Get-ObjectProperty',
        'Test-MonitorObjectProperty',
        'Get-MonitorFirstProperty',
        'ConvertTo-StatsNumber',
        'ConvertTo-TokenStatsNumber',
        'Get-KompressBrokerCounterWindow',
        'Get-GatewayTokenAccounting',
        'Get-Sha256Hex',
        'Get-UnifiedStatusFingerprint'
    )) {
    Invoke-Expression (Get-FunctionText -Path $monitorPath -Name $name)
}

$emptyIssueFingerprint = Get-UnifiedStatusFingerprint -Overall 'green' -Items @([pscustomobject]@{ key = 'monitor-core'; state = 'green' }) -ActiveIssues @()
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($emptyIssueFingerprint)) -Message 'empty active issue collection is accepted'

$script:KompressBrokerCounterBaseline = $null
$first = Get-KompressBrokerCounterWindow -Counters ([pscustomobject]@{ queue_full = 9; timeout = 4; device_removal = 2 })
Assert-True -Condition ($first.BaselinePending -and -not $first.AnyIncreased) -Message 'first broker snapshot establishes a baseline without warning'
$same = Get-KompressBrokerCounterWindow -Counters ([pscustomobject]@{ queue_full = 9; timeout = 4; device_removal = 2 })
Assert-True -Condition (-not $same.AnyIncreased -and $same.DeltaAvailable) -Message 'unchanged broker counters do not warn'
$delta = Get-KompressBrokerCounterWindow -Counters ([pscustomobject]@{ queue_full = 10; timeout = 6; device_removal = 3 })
Assert-True -Condition ($delta.AnyIncreased -and $delta.Delta.queue_full -eq 1 -and $delta.Delta.timeout -eq 2 -and $delta.Delta.device_removal -eq 1) -Message 'new broker counter values warn with exact deltas'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('codexpp-monitor-fixture-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$script:GatewayStatePath = Join-Path $fixtureRoot 'gateway-metrics-state.json'
try {
    $v2Exact = [ordered]@{
        token_accounting = [ordered]@{
            schema_version = 2
            current = [ordered]@{ generation = 7; completed = 2; missing = 0; invalid = 0; input_before = 300; input_after = 200; saved = 100 }
            legacy = [ordered]@{ schema_version = 1; missing_samples = 4 }
            excluded = [ordered]@{ bypass = 3; error = 2; total = 5 }
        }
        recent = @()
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:GatewayStatePath, $v2Exact, [Text.UTF8Encoding]::new($false))
    $exact = Get-GatewayTokenAccounting
    Assert-True -Condition ($exact.exact -and $exact.schema_version -eq 2 -and $exact.generation -eq 7 -and $exact.input_before -eq 300 -and $exact.input_after -eq 200 -and $exact.saved -eq 100) -Message 'v2 exact current generation totals are read'
    Assert-True -Condition ($exact.legacy_missing -eq 4 -and $exact.excluded_bypass -eq 3 -and $exact.excluded_error -eq 2) -Message 'v2 legacy and excluded counts remain detail only'

    $v2Incomplete = [ordered]@{
        token_accounting = [ordered]@{
            schema_version = 2
            current = [ordered]@{ generation = 8; completed = 2; missing = 1; invalid = 0; input_before = 300; input_after = 200; saved = 100 }
            legacy = [ordered]@{ schema_version = 1; missing_samples = 0 }
            excluded = [ordered]@{ bypass = 1; error = 0; total = 1 }
        }
        recent = @()
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:GatewayStatePath, $v2Incomplete, [Text.UTF8Encoding]::new($false))
    $incomplete = Get-GatewayTokenAccounting
    Assert-True -Condition (-not $incomplete.exact -and $incomplete.missing -eq 1 -and $incomplete.invalid -eq 0) -Message 'v2 incomplete remains distinct from invalid'

    $v2Invalid = [ordered]@{
        token_accounting = [ordered]@{
            schema_version = 2
            current = [ordered]@{ generation = 9; completed = 2; missing = 0; invalid = 0; input_before = 300; input_after = 200; saved = 99 }
            legacy = [ordered]@{ schema_version = 1; missing_samples = 0 }
            excluded = [ordered]@{ bypass = 0; error = 0; total = 0 }
        }
        recent = @()
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:GatewayStatePath, $v2Invalid, [Text.UTF8Encoding]::new($false))
    $invalid = Get-GatewayTokenAccounting
    Assert-True -Condition (-not $invalid.exact -and $invalid.invalid -gt 0) -Message 'v2 relation mismatch is invalid'

    $v1 = [ordered]@{
        token_accounting = [ordered]@{ input_before = 120; input_after = 80; saved = 40; completed_samples = 1; missing_samples = 0; invalid_samples = 0 }
        recent = @()
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:GatewayStatePath, $v1, [Text.UTF8Encoding]::new($false))
    $legacy = Get-GatewayTokenAccounting
    Assert-True -Condition ($legacy.schema_version -eq 1 -and $legacy.exact -and $legacy.saved -eq 40) -Message 'v1 aggregate remains readable'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Write-Output 'monitor-window-semantics.tests.ps1: PASS (10 assertions)'
