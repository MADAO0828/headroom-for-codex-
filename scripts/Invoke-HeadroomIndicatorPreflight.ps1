[CmdletBinding()]
param(
    [string]$IndicatorSource = '',
    [string]$MetadataPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json',
    [string]$UserScriptsDir = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts',
    [string]$StatusUrl = 'http://127.0.0.1:18788/status',
    [string[]]$CdpBaseUrl = @('http://127.0.0.1:9229'),
    [int]$TimeoutSeconds = 3,
    [string]$EvidencePath = '',
    [switch]$SkipCdp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 15) { throw 'timeout_seconds_out_of_range' }

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($IndicatorSource)) {
    $IndicatorSource = Join-Path $projectRoot 'src\codexpp\Codex++\headroom-status-indicator.js'
}
$indicatorSourceFull = [IO.Path]::GetFullPath($IndicatorSource)
$metadataFull = [IO.Path]::GetFullPath($MetadataPath)
$userScriptsDirFull = [IO.Path]::GetFullPath($UserScriptsDir)
$runtimeScriptFull = Join-Path $userScriptsDirFull 'headroom-status-indicator.js'

function Get-JsonMember {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SafeEndpointProbe {
    param([Parameter(Mandatory)][string]$Uri)
    $result = [ordered]@{
        endpoint = $Uri
        transport_ok = $false
        status_code = $null
        json_ok = $false
        body = $null
    }
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop
        $result.status_code = [int]$response.StatusCode
        $raw = [string]$response.Content
        try {
            $result.body = $raw | ConvertFrom-Json
            $result.json_ok = $true
        }
        catch {
            $result.body = $null
        }
        $result.transport_ok = $true
    }
    catch {
        $result.error_kind = $_.Exception.GetType().Name
    }
    return [pscustomobject]$result
}

function Get-SourceMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        sha256 = $null
        version = $null
        status_url = $null
        status_url_matches_expected = $false
    }
    if (-not $result.exists) { return [pscustomobject]$result }
    $result.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $versionMatch = [regex]::Match($line, 'const\s+SCRIPT_VERSION\s*=\s*"([^"]+)"')
        if ($null -eq $result.version -and $versionMatch.Success) { $result.version = $versionMatch.Groups[1].Value }
        $statusUrlMatch = [regex]::Match($line, 'const\s+STATUS_URL\s*=\s*"([^"]+)"')
        if ($null -eq $result.status_url -and $statusUrlMatch.Success) { $result.status_url = $statusUrlMatch.Groups[1].Value }
    }
    $result.status_url_matches_expected = [string]::Equals([string]$result.status_url, 'http://127.0.0.1:18788/status', [StringComparison]::Ordinal)
    return [pscustomobject]$result
}

function Get-RegistrationMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $key = 'user:headroom-status-indicator.js'
    $result = [ordered]@{
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        sha256 = $null
        json_ok = $false
        enabled = $false
        scripts_key_present = $false
        scripts_key_enabled = $false
        market_key_present = $false
        market_id = $null
        market_version = $null
        market_script_url = $null
    }
    if (-not $result.exists) { return [pscustomobject]$result }
    $result.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    try {
        $doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $result.json_ok = $true
        $scripts = Get-JsonMember -Object $doc -Name 'scripts'
        $market = Get-JsonMember -Object $doc -Name 'market'
        $scriptEntry = Get-JsonMember -Object $scripts -Name $key
        $marketEntry = Get-JsonMember -Object $market -Name $key
        $result.scripts_key_present = $null -ne $scriptEntry
        $result.scripts_key_enabled = $scriptEntry -eq $true
        $result.market_key_present = $null -ne $marketEntry
        $result.market_id = Get-JsonMember -Object $marketEntry -Name 'id'
        $result.market_version = Get-JsonMember -Object $marketEntry -Name 'version'
        $result.market_script_url = Get-JsonMember -Object $marketEntry -Name 'script_url'
        $result.enabled = (Get-JsonMember -Object $doc -Name 'enabled') -eq $true
    }
    catch {
        $result.json_ok = $false
    }
    return [pscustomobject]$result
}

function Get-RuntimeScriptMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        sha256 = $null
    }
    if ($result.exists) {
        $result.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    return [pscustomobject]$result
}

function Get-CdpPreflight {
    param([Parameter(Mandatory)][string[]]$BaseUrls)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($base in $BaseUrls) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $normalized = $base.TrimEnd('/')
        $probe = Get-SafeEndpointProbe -Uri "$normalized/json/version"
        $body = $probe.body
        [void]$rows.Add([ordered]@{
                endpoint = $normalized
                endpoint_reachable = [bool]$probe.transport_ok
                http_ok = [bool]($probe.transport_ok -and $probe.status_code -ge 200 -and $probe.status_code -lt 300)
                version_json_ok = [bool]($probe.transport_ok -and $probe.json_ok)
                protocol_version_present = -not [string]::IsNullOrWhiteSpace([string](Get-JsonMember -Object $body -Name 'Protocol-Version'))
                browser_present = -not [string]::IsNullOrWhiteSpace([string](Get-JsonMember -Object $body -Name 'Browser'))
                target_inspection_performed = $false
            })
    }
    return @($rows)
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceFull = [IO.Path]::GetFullPath($EvidencePath)
    $evidenceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'evidence')).TrimEnd('\','/')
    if (-not $evidenceFull.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'evidence_outside_project' }
}

$source = Get-SourceMetadata -Path $indicatorSourceFull
$registration = Get-RegistrationMetadata -Path $metadataFull
$runtime = Get-RuntimeScriptMetadata -Path $runtimeScriptFull
$statusProbe = Get-SafeEndpointProbe -Uri $StatusUrl
$statusBody = $statusProbe.body
$statusItems = Get-JsonMember -Object $statusBody -Name 'items'
$statusIssues = Get-JsonMember -Object $statusBody -Name 'active_issues'
$statusDocument = [ordered]@{
    endpoint = $StatusUrl
    transport_ok = [bool]$statusProbe.transport_ok
    http_ok = [bool]($statusProbe.transport_ok -and $statusProbe.status_code -ge 200 -and $statusProbe.status_code -lt 300)
    status_code = $statusProbe.status_code
    schema_version = Get-JsonMember -Object $statusBody -Name 'schema_version'
    overall = Get-JsonMember -Object $statusBody -Name 'overall'
    generated_at = Get-JsonMember -Object $statusBody -Name 'generated_at'
    item_count = if ($null -eq $statusItems) { 0 } else { @($statusItems).Count }
    active_issue_count = if ($null -eq $statusIssues) { 0 } else { @($statusIssues).Count }
}
$cdp = if ($SkipCdp) { @() } else { Get-CdpPreflight -BaseUrls $CdpBaseUrl }

$document = [ordered]@{
    schema = 'headroom-indicator-preflight/v1'
    read_only = $true
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    source = $source
    registration = [ordered]@{
        metadata = $registration
        runtime_script = $runtime
        source_runtime_hash_match = [bool]($source.sha256 -and $runtime.sha256 -and $source.sha256 -eq $runtime.sha256)
    }
    status = $statusDocument
    cdp = $cdp
    cdp_target_content_read = $false
}

$json = ($document | ConvertTo-Json -Depth 12)
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $evidenceFull)) | Out-Null
    [IO.File]::WriteAllText($evidenceFull, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
Write-Output $json
