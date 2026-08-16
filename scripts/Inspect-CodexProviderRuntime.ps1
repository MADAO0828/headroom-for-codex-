[CmdletBinding()]
param(
    [string]$SettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json',
    [string]$ConfigPath = 'C:\Users\ma dao\.codex-plus-plus-cli\config.toml',
    [string]$OfficialConfigPath = 'C:\Users\ma dao\.codex\config.toml',
    [string]$OutputPath = '',
    [switch]$NoProcessProbe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FileSha256Safe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return $null }
}

function Get-UrlClass {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'missing' }
    try {
        $uri = [Uri]$Value
        if ($uri.Host -in @('127.0.0.1', 'localhost', '::1')) { return "loopback:$($uri.Port)" }
        $address = $null
        if ([Net.IPAddress]::TryParse($uri.Host, [ref]$address)) {
            if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
                $bytes = $address.GetAddressBytes()
                if (($bytes[0] -eq 10) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) { return 'private_ip' }
            }
        }
        return 'external'
    }
    catch { return 'invalid' }
}

function Get-ActiveConfigSummary {
    param([Parameter(Mandatory)][string]$Path)
    $empty = [ordered]@{
        exists = $false
        sha256 = $null
        provider = $null
        base_url_class = 'missing'
        wire_api = $null
        supports_websockets = $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$empty }
    $empty.exists = $true
    $empty.sha256 = Get-FileSha256Safe -Path $Path
    try {
        $content = [IO.File]::ReadAllText($Path)
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*["''](?<provider>[^"'']+)["'']')
        if (-not $providerMatch.Success) { return [pscustomobject]$empty }
        $provider = $providerMatch.Groups['provider'].Value
        $sectionMatch = [regex]::Match($content, '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) { $empty.provider = $provider; return [pscustomobject]$empty }
        $section = $sectionMatch.Groups['section'].Value
        $base = [regex]::Match($section, '(?im)^\s*base_url\s*=\s*["''](?<value>[^"'']+)["'']').Groups['value'].Value
        $wire = [regex]::Match($section, '(?im)^\s*wire_api\s*=\s*["''](?<value>[^"'']+)["'']').Groups['value'].Value
        $supportsMatch = [regex]::Match($section, '(?im)^\s*supports_websockets\s*=\s*(?<value>true|false)')
        $empty.provider = $provider
        $empty.base_url_class = Get-UrlClass -Value $base
        $empty.wire_api = if ($wire) { $wire } else { $null }
        $empty.supports_websockets = if ($supportsMatch.Success) { $supportsMatch.Groups['value'].Value -eq 'true' } else { $null }
        return [pscustomobject]$empty
    }
    catch { return [pscustomobject]$empty }
}

function Get-ActiveProfileSummary {
    param([Parameter(Mandatory)][string]$Path)
    $empty = [ordered]@{
        exists = $false
        sha256 = $null
        active_relay_id = $null
        active_relay_name = $null
        active_relay_mode = $null
        active_upstream_class = 'missing'
        stepwise_enabled = $false
        stepwise_base_url_class = 'missing'
        profile_count = 0
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$empty }
    $empty.exists = $true
    $empty.sha256 = Get-FileSha256Safe -Path $Path
    try {
        $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $profiles = @($settings.relayProfiles)
        $activeId = [string]$settings.activeRelayId
        $active = @($profiles | Where-Object { [string]$_.id -eq $activeId })
        $empty.active_relay_id = if ($activeId) { $activeId } else { $null }
        $empty.profile_count = $profiles.Count
        if ($active.Count -eq 1) {
            $empty.active_relay_name = [string]$active[0].name
            $empty.active_relay_mode = [string]$active[0].relayMode
            $empty.active_upstream_class = Get-UrlClass -Value ([string]$active[0].upstreamBaseUrl)
        }
        $empty.stepwise_enabled = [bool]$settings.codexAppStepwiseEnabled
        $empty.stepwise_base_url_class = Get-UrlClass -Value ([string]$settings.codexAppStepwiseBaseUrl)
        return [pscustomobject]$empty
    }
    catch { return [pscustomobject]$empty }
}

function Get-ProcessRouteSummary {
    param([Parameter(Mandatory)][int[]]$Ports)
    $official = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq 'codex.exe' -and [string]$_.CommandLine -match '(?i)\bapp-server\b') -or
        ($_.Name -ieq 'ChatGPT.exe')
    })
    $rows = @(foreach ($process in $official) {
        $connections = @(Get-NetTCPConnection -OwningProcess ([int]$process.ProcessId) -ErrorAction SilentlyContinue)
        $counts = [ordered]@{}
        foreach ($port in $Ports) {
            $counts["port_$port"] = @($connections | Where-Object { [int]$_.RemotePort -eq $port }).Count
        }
        [pscustomobject]@{
            pid = [int]$process.ProcessId
            parent_pid = [int]$process.ParentProcessId
            name = [string]$process.Name
            connection_counts = [pscustomobject]$counts
        }
    })
    $routePorts = @(18787, 18789, 57321, 57322)
    $vortexPorts = @(7897, 12450)
    $hasRoute = $false
    $hasVortex = $false
    foreach ($row in $rows) {
        foreach ($port in $routePorts) { if ([int]$row.connection_counts."port_$port" -gt 0) { $hasRoute = $true } }
        foreach ($port in $vortexPorts) { if ([int]$row.connection_counts."port_$port" -gt 0) { $hasVortex = $true } }
    }
    [pscustomobject]@{
        official_process_count = $rows.Count
        processes = @($rows)
        official_dataplane = if ($hasRoute) { 'candidate_local_route_observed' } elseif ($hasVortex) { 'bypass_vortex_observed' } else { 'unknown' }
        route_correlation_proven = $false
        note = 'Socket presence is not request correlation; official_dataplane is confirmed only by Gateway/Headroom/egress correlation and SSE terminal evidence.'
    }
}

$profile = Get-ActiveProfileSummary -Path $SettingsPath
$clientConfig = Get-ActiveConfigSummary -Path $ConfigPath
$officialConfig = Get-ActiveConfigSummary -Path $OfficialConfigPath
$runtime = if ($NoProcessProbe) {
    [pscustomobject]@{ official_process_count = $null; processes = @(); official_dataplane = 'not_probed'; route_correlation_proven = $false; note = 'process probe disabled' }
} else {
    Get-ProcessRouteSummary -Ports @(7897, 12450, 57321, 57322, 18787, 18789)
}
$document = [ordered]@{
    schema = 'codex-provider-runtime-inspection/v1'
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    settings = $profile
    codex_plus_plus_config = $clientConfig
    official_codex_config = $officialConfig
    runtime = $runtime
    runtime_reload_required = if ($null -eq $runtime.official_process_count) { $null } else { $runtime.official_process_count -gt 0 }
    provider_switch_interpretation = if ($runtime.official_process_count -gt 0) {
        'file_switch_is_not_runtime_switch; restart_required'
    } else {
        'file_switch_will_apply_on_next_launch'
    }
    secrets_logged = $false
    session_body_logged = $false
}
$json = $document | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tmp = Join-Path $parent ('.provider-runtime-' + [IO.Path]::GetRandomFileName())
    [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $OutputPath, $true)
}
$json
