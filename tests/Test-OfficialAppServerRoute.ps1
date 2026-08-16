[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $projectRoot 'scripts\Start-OfficialCodexThroughHeadroom.ps1'
$receiptPath = Join-Path $projectRoot 'runtime\state\official-route-a-start.json'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message 'official route launcher exists'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
Assert-True -Condition ($errors.Count -eq 0) -Message 'official route launcher parses without errors'

$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
foreach ($needle in @(
        '--inspect-brk=127.0.0.1:',
        'CODEX_APP_SERVER_CHATGPT_BASE_URL',
        'CODEX_APP_SERVER_OPENAI_BASE_URL',
        'Runtime.runIfWaitingForDebugger',
        'Wait-OfficialAppServerRoute',
        'UseRouteCIngress',
        '18787',
        'protected_files_unchanged'
    )) {
    Assert-True -Condition $source.Contains($needle) -Message "launcher contains $needle"
}

$output = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -DryRun -NoPause -ReadinessTimeoutSeconds 3 -OfficialRouteWaitSeconds 1 2>&1)
$exitCode = $LASTEXITCODE
Assert-True -Condition ($exitCode -eq 0) -Message "dry-run exits zero (output=$($output -join "`n"))"
Assert-True -Condition (Test-Path -LiteralPath $receiptPath -PathType Leaf) -Message 'dry-run writes a receipt'
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True -Condition ([string]$receipt.status -eq 'dry_run_ready') -Message 'dry-run status is explicit'
Assert-True -Condition ([string]$receipt.ingress_base_url -eq 'http://127.0.0.1:18787/v1') -Message 'dry-run ingress is the production Gateway'
Assert-True -Condition ([bool]$receipt.config_write -eq $false -and [bool]$receipt.settings_write -eq $false -and [bool]$receipt.vortex_write -eq $false) -Message 'dry-run has no protected writes'

Write-Output 'official app-server route launcher tests: PASS'
