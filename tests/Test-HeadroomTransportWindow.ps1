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
    Assert-True -Condition ($errors.Count -eq 0) -Message "parses: $Path"
    $node = @($ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name }, $true))[0]
    Assert-True -Condition ($null -ne $node) -Message "exists: $Name"
    return $node.Extent.Text
}

$monitorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\codexpp\Codex++\codexpp-headroom-monitor.ps1'))
foreach ($name in @('Get-ObjectProperty', 'ConvertTo-StatsNumber', 'Get-TransportObservation')) {
    Invoke-Expression (Get-FunctionText -Path $monitorPath -Name $name)
}

$recovered = Get-TransportObservation -Logs ([pscustomobject]@{
    Helper5xxCount = 3; Proxy5xxCount = 0; WsFallbackCount = 0; FramesFailedCount = 0; WsClientErrorCount = 0
    ProxySuccessCount = 12; Helper5xxRecovered = $true; WsFallbackRecovered = $false; WsClientErrorRecovered = $false; EvidenceAvailable = $true
})
Assert-True -Condition ($recovered.State -eq 'green' -and $recovered.Recovered -and $recovered.IssueCode -eq $null) -Message 'recovered helper 5xx is not left yellow'

$activeHelper = Get-TransportObservation -Logs ([pscustomobject]@{
    Helper5xxCount = 1; Proxy5xxCount = 0; WsFallbackCount = 0; FramesFailedCount = 0; WsClientErrorCount = 0
    ProxySuccessCount = 0; Helper5xxRecovered = $false; WsFallbackRecovered = $false; WsClientErrorRecovered = $false; EvidenceAvailable = $true
})
Assert-True -Condition ($activeHelper.State -eq 'red' -and $activeHelper.IssueCode -eq 'transport.helper_5xx') -Message 'unrecovered helper 5xx remains red'

$activeWebsocket = Get-TransportObservation -Logs ([pscustomobject]@{
    Helper5xxCount = 0; Proxy5xxCount = 0; WsFallbackCount = 1; FramesFailedCount = 0; WsClientErrorCount = 0
    ProxySuccessCount = 0; Helper5xxRecovered = $false; WsFallbackRecovered = $false; WsClientErrorRecovered = $false; EvidenceAvailable = $true
})
Assert-True -Condition ($activeWebsocket.State -eq 'yellow' -and $activeWebsocket.IssueCode -eq 'transport.ws_fallback') -Message 'unrecovered websocket fallback remains yellow'

$missing = Get-TransportObservation -Logs ([pscustomobject]@{
    Helper5xxCount = 0; Proxy5xxCount = 0; WsFallbackCount = 0; FramesFailedCount = 0; WsClientErrorCount = 0
    ProxySuccessCount = 0; Helper5xxRecovered = $false; WsFallbackRecovered = $false; WsClientErrorRecovered = $false; EvidenceAvailable = $false
})
Assert-True -Condition ($missing.State -eq 'yellow' -and $missing.IssueCode -eq 'transport.evidence_missing') -Message 'missing evidence remains yellow'

'Test-HeadroomTransportWindow.ps1: PASS (4 assertions)'
