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

$startPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\scripts\Start-HeadroomForCodexPP.ps1'))
$routeKeeper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'codexpp-route-keeper.ps1'))
Invoke-Expression (Get-FunctionText -Path $startPath -Name 'Test-StaleRouteKeeperIdentity')

$validState = [pscustomobject]@{
    route_keeper_script_path = $routeKeeper
    route_keeper_mode = 'watch'
}
$validProcess = [pscustomobject]@{
    Id = 701
    Path = 'D:\Program Files\PowerShell\7\pwsh.exe'
}
$validCommand = "pwsh.exe -File `"$routeKeeper`" -Watch -ConfigPath C:\Users\fixture\config.toml"
Assert-True -Condition (Test-StaleRouteKeeperIdentity -State $validState -Process $validProcess -CommandLine $validCommand) -Message 'project route watcher identity is accepted'

$wrongScript = [pscustomobject]@{
    route_keeper_script_path = 'D:\other\route-keeper.ps1'
    route_keeper_mode = 'watch'
}
Assert-True -Condition (-not (Test-StaleRouteKeeperIdentity -State $wrongScript -Process $validProcess -CommandLine $validCommand)) -Message 'foreign route watcher script is rejected'

$wrongProcess = [pscustomobject]@{
    Id = 702
    Path = 'D:\program\Codex++\codex-plus-plus.exe'
}
Assert-True -Condition (-not (Test-StaleRouteKeeperIdentity -State $validState -Process $wrongProcess -CommandLine $validCommand)) -Message 'non-PowerShell process is rejected'

$watchState = [pscustomobject]@{
    route_keeper_path = $routeKeeper
    mode = 'proxy'
}
Assert-True -Condition (Test-StaleRouteKeeperIdentity -State $watchState -Process $validProcess -CommandLine $validCommand) -Message 'legacy watch-state identity is accepted'

Write-Output 'stale-route-keeper.tests.ps1: PASS (4 fixtures)'
