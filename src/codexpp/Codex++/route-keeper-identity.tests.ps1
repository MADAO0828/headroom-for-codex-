[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-FunctionText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message "source parses: $Path"
    $node = @($ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name }, $true))[0]
    Assert-True -Condition ($null -ne $node) -Message "function exists: $Name"
    return $node.Extent.Text
}

$monitorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'codexpp-headroom-monitor.ps1'))
$routeKeeperPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'codexpp-route-keeper.ps1'))
$script:RouteKeeperPath = $routeKeeperPath
Invoke-Expression (Get-FunctionText -Path $monitorPath -Name 'Get-ObjectProperty')
Invoke-Expression (Get-FunctionText -Path $monitorPath -Name 'ConvertTo-MonitorUtcDateTimeValue')
Invoke-Expression (Get-FunctionText -Path $monitorPath -Name 'Test-MonitorRouteKeeperIdentity')
function Get-MonitorProcessExecutablePath { param([Parameter(Mandatory)][int]$ProcessId) return 'D:\Program Files\PowerShell\7\pwsh.exe' }

$started = [DateTime]::UtcNow.AddSeconds(-2)
$state = [pscustomobject]@{
    route_keeper_mode = 'watch'
    route_keeper_script_path = $routeKeeperPath
    route_keeper_started_at = $started.ToString('o')
}
$process = [pscustomobject]@{ Id = 801; StartTime = $started }

Assert-True -Condition (Test-MonitorRouteKeeperIdentity -RouteState $state -KeeperProcess $process -KeeperInfo $null -CommandLine '') -Message 'blank elevated command line falls back to verified process identity'
Assert-True -Condition (Test-MonitorRouteKeeperIdentity -RouteState $state -KeeperProcess $process -KeeperInfo $null -CommandLine "pwsh.exe -File `"$routeKeeperPath`" -Watch") -Message 'readable command line with route keeper watch passes'
Assert-True -Condition (-not (Test-MonitorRouteKeeperIdentity -RouteState $state -KeeperProcess $process -KeeperInfo $null -CommandLine 'pwsh.exe -File D:\other.ps1 -Watch')) -Message 'readable foreign command line fails'
$wrongMode = [pscustomobject]@{ route_keeper_mode = 'once'; route_keeper_script_path = $routeKeeperPath; route_keeper_started_at = $started.ToString('o') }
Assert-True -Condition (-not (Test-MonitorRouteKeeperIdentity -RouteState $wrongMode -KeeperProcess $process -KeeperInfo $null -CommandLine '')) -Message 'non-watch route state fails'

Write-Output 'route-keeper-identity.tests.ps1: PASS (4 fixtures)'
