[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$projectPath = Join-Path $PSScriptRoot 'CodexCliShim.csproj'

$json = dotnet run --project $projectPath --no-restore -- --headroom-shim-self-test app-server --analytics-default-enabled
if ($LASTEXITCODE -ne 0) { throw 'route_a_shim_self_test_failed' }
$result = $json | ConvertFrom-Json
if (-not $result.injected) { throw 'route_a_shim_did_not_inject' }
if (-not ($result.transformed_args -contains 'model_provider=headroom_runtime')) { throw 'route_a_shim_provider_missing' }
if (-not ($result.transformed_args -contains 'model_providers.headroom_runtime.base_url="http://127.0.0.1:18787/v1"')) { throw 'route_a_shim_base_url_missing' }
if ($result.config_write -or $result.settings_write -or $result.secrets_logged) { throw 'route_a_shim_side_effect_contract_failed' }

$noInjection = dotnet run --project $projectPath --no-restore -- --headroom-shim-self-test --version | ConvertFrom-Json
if ($noInjection.injected) { throw 'route_a_shim_injected_non_app_server' }

$shimPath = Join-Path $projectRoot 'runtime\official-route\shim\codex-cli-headroom-shim.exe'
if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
    $oldRealPath = $env:HEADROOM_REAL_CODEX_CLI_PATH
    try {
        $env:HEADROOM_REAL_CODEX_CLI_PATH = $shimPath
        $errorText = & $shimPath --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 78 -or $errorText -notmatch 'route_a_shim_recursion') { throw 'route_a_shim_recursion_guard_failed' }
    }
    finally {
        $env:HEADROOM_REAL_CODEX_CLI_PATH = $oldRealPath
    }
}

Write-Output 'route_a_shim_tests=PASS'
