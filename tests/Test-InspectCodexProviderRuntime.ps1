$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $root 'scripts\Inspect-CodexProviderRuntime.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('headroom-provider-runtime-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $settingsPath = Join-Path $temp 'settings.json'
    $configPath = Join-Path $temp 'codex-plus-plus.toml'
    $officialConfigPath = Join-Path $temp 'official.toml'
    [IO.File]::WriteAllText($settingsPath, (@{
        activeRelayId = 'relay-a'
        relayProfiles = @(@{
            id = 'relay-a'
            name = 'Fixture'
            relayMode = 'pureApi'
            upstreamBaseUrl = 'https://provider.example/v1'
        })
        codexAppStepwiseEnabled = $false
        codexAppStepwiseBaseUrl = 'https://stepwise.example/v1'
    } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($configPath, @'
model_provider = "fixture"

[model_providers.fixture]
wire_api = "responses"
requires_openai_auth = true
base_url = "http://127.0.0.1:18787/v1"
supports_websockets = false
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($officialConfigPath, @'
model_provider = "fixture"

[model_providers.fixture]
wire_api = "responses"
requires_openai_auth = true
base_url = "https://provider.example/v1"
supports_websockets = false
'@, [Text.UTF8Encoding]::new($false))
    $json = & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -SettingsPath $settingsPath -ConfigPath $configPath -OfficialConfigPath $officialConfigPath -NoProcessProbe | ConvertFrom-Json
    if ($json.schema -ne 'codex-provider-runtime-inspection/v1') { throw 'schema_mismatch' }
    if ($json.settings.active_relay_id -ne 'relay-a') { throw 'active_profile_mismatch' }
    if ($json.codex_plus_plus_config.base_url_class -ne 'loopback:18787') { throw 'client_route_class_mismatch' }
    if ($json.official_codex_config.base_url_class -ne 'external') { throw 'official_route_class_mismatch' }
    if ($json.runtime_reload_required -ne $null) { throw 'disabled_process_probe_not_marked' }
    $text = $json | ConvertTo-Json -Depth 12 -Compress
    if ($text -match '(?i)"(api[_-]?key|authorization|OPENAI_API_KEY)"\s*:') { throw 'secret_field_exposed' }
    Write-Output 'Test-InspectCodexProviderRuntime: PASS'
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
