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
$managerExe = [IO.Path]::GetFullPath('D:\program\Codex++\codex-plus-plus-manager.exe')
$clientExe = [IO.Path]::GetFullPath('D:\program\Codex++\codex-plus-plus.exe')
$managedCodexStatePath = Join-Path ([IO.Path]::GetTempPath()) ('managed-codex-state-' + [IO.Path]::GetRandomFileName() + '.json')
$script:ManagedFixture = $null
$script:ExactFixture = @()
$script:ProcessFixture = @{}

function Get-ManagedCodexState { return $script:ManagedFixture }
function Get-ExactExecutableProcesses {
    param([Parameter(Mandatory)][string[]]$ExecutablePaths)
    return @($script:ExactFixture)
}
function Get-ProcessExecutablePath {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not $script:ProcessFixture.ContainsKey([string]$ProcessId)) { return '' }
    return [string]$script:ProcessFixture[[string]$ProcessId].Path
}
function Get-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Id)
    if (-not $script:ProcessFixture.ContainsKey([string]$Id)) { return $null }
    return $script:ProcessFixture[[string]$Id]
}

Invoke-Expression (Get-FunctionText -Path $startPath -Name 'ConvertTo-UtcDateTimeValue')
Invoke-Expression (Get-FunctionText -Path $startPath -Name 'Test-ManagedCodexProcesses')

try {
    $managerStart = [DateTime]::UtcNow.AddSeconds(-2)
    $clientStart = [DateTime]::UtcNow.AddSeconds(-1)
    $script:ExactFixture = @(
        [pscustomobject]@{ ProcessId = 501; ExecutablePath = $managerExe },
        [pscustomobject]@{ ProcessId = 502; ExecutablePath = $clientExe }
    )
    $script:ProcessFixture = @{
        '501' = [pscustomobject]@{ Path = $managerExe; StartTime = $managerStart }
        '502' = [pscustomobject]@{ Path = $clientExe; StartTime = $clientStart }
    }
    $script:ManagedFixture = [pscustomobject]@{
        schema_version = 1
        processes = @(
            [pscustomobject]@{ pid = 501; executable_path = $managerExe; started_at_utc = $managerStart.ToString('o') },
            [pscustomobject]@{ pid = 502; executable_path = $clientExe; started_at_utc = $clientStart.ToString('o') }
        )
    }
    Assert-True -Condition (Test-ManagedCodexProcesses) -Message 'one exact Manager and one exact Client match managed state'

    $script:ExactFixture = @(
        [pscustomobject]@{ ProcessId = 501; ExecutablePath = $managerExe },
        [pscustomobject]@{ ProcessId = 502; ExecutablePath = $clientExe },
        [pscustomobject]@{ ProcessId = 503; ExecutablePath = $clientExe }
    )
    $script:ProcessFixture['503'] = [pscustomobject]@{ Path = $clientExe; StartTime = [DateTime]::UtcNow }
    Assert-True -Condition (-not (Test-ManagedCodexProcesses)) -Message 'duplicate exact Client invalidates managed state'

    $script:ExactFixture = @(
        [pscustomobject]@{ ProcessId = 501; ExecutablePath = $managerExe },
        [pscustomobject]@{ ProcessId = 503; ExecutablePath = $clientExe }
    )
    Assert-True -Condition (-not (Test-ManagedCodexProcesses)) -Message 'stale state PID does not become managed after client replacement'
}
finally {
    if (Test-Path -LiteralPath $managedCodexStatePath) { Remove-Item -LiteralPath $managedCodexStatePath -Force }
}

Write-Output 'managed-process-state.tests.ps1: PASS (3 fixtures)'
