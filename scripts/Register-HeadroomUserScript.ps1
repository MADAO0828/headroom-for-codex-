[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$MetadataPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json',
    [string]$UserScriptsDir = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts',
    [string]$IndicatorSource = '',
    [string]$BackupPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($IndicatorSource)) {
    $IndicatorSource = Join-Path $projectRoot 'src\codexpp\Codex++\headroom-status-indicator.js'
}
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path $projectRoot 'backups\metadata\user_scripts.json.before-headroom-register'
}
function Assert-ProjectPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = ([IO.Path]::GetFullPath($projectRoot)).TrimEnd('\','/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "backup_outside_project:$full" }
}
Assert-ProjectPath -Path $BackupPath
$key = 'user:headroom-status-indicator.js'
$targetScript = Join-Path $UserScriptsDir 'headroom-status-indicator.js'

# The indicator only polls 127.0.0.1:18788/status and mounts UI; it must not
# be signed, patched, or contain credentials.  Guard against accidental use of
# a foreign source.
if (-not (Test-Path -LiteralPath $IndicatorSource -PathType Leaf)) { throw "indicator_source_missing:$IndicatorSource" }
$indicatorSha256 = (Get-FileHash -LiteralPath $IndicatorSource -Algorithm SHA256).Hash
if ($indicatorSha256 -ne 'E41586CBD204479CB53FDF21AE9570ACE005283607377DC87DF77118BBA88EF8') {
    # Source hash is recorded from the project snapshot; changing the script is
    # an explicit code change and must be reviewed, not silently registered.
    throw "indicator_source_hash_unexpected:$indicatorSha256"
}
$sourceVersion = $null
foreach ($line in [IO.File]::ReadAllLines($IndicatorSource)) {
    if ($line -match 'const\s+SCRIPT_VERSION\s*=\s*"([^"]+)"') { $sourceVersion = $Matches[1]; break }
}
if ([string]::IsNullOrWhiteSpace($sourceVersion)) { throw 'indicator_version_unreadable' }

if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) { throw "metadata_missing:$MetadataPath" }
$text = [IO.File]::ReadAllText($MetadataPath)
$doc = $text | ConvertFrom-Json -AsHashtable
if (-not $doc.ContainsKey('scripts') -or -not $doc.ContainsKey('market')) { throw 'metadata_schema_missing_sections' }

$existingScriptKey = $doc.scripts.ContainsKey($key)
$existingMarketKey = $doc.market.ContainsKey($key)
if ($existingScriptKey -and $doc.scripts[$key] -ne $true) { throw 'headroom_metadata_key_conflict_scripts' }
if ($existingMarketKey) {
    $existingMarket = $doc.market[$key]
    $existingMarketId = if ($existingMarket -is [System.Collections.IDictionary] -and $existingMarket.ContainsKey('id')) { [string]$existingMarket['id'] } else { '' }
    $existingMarketUrl = if ($existingMarket -is [System.Collections.IDictionary] -and $existingMarket.ContainsKey('script_url')) { [string]$existingMarket['script_url'] } else { '' }
    if ($existingMarketId -ne 'headroom-status-indicator' -or $existingMarketUrl -ne 'local://headroom-status-indicator.js') {
        throw 'headroom_metadata_key_conflict_market'
    }
}
$metadataAlreadyCorrect = $existingScriptKey -and $existingMarketKey

$beforeScripts = @($doc.scripts.Keys | Sort-Object)
$beforeMarket = @($doc.market.Keys | Sort-Object)
if (-not $existingScriptKey) { $doc.scripts[$key] = $true }
if (-not $existingMarketKey) {
    $doc.market[$key] = [ordered]@{
        id = 'headroom-status-indicator'
        name = 'Headroom Status Indicator'
        version = $sourceVersion
        script_url = 'local://headroom-status-indicator.js'
        homepage = ''
        installed_at = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }
}
$afterScripts = @($doc.scripts.Keys | Sort-Object)
$afterMarket = @($doc.market.Keys | Sort-Object)
$expectedScripts = @($beforeScripts + $key | Sort-Object -Unique)
$expectedMarket = @($beforeMarket + $key | Sort-Object -Unique)
if (($afterScripts -join "`n") -ne ($expectedScripts -join "`n")) { throw 'scripts_key_injection_failed' }
if (($afterMarket -join "`n") -ne ($expectedMarket -join "`n")) { throw 'market_key_injection_failed' }
$out = (($doc | ConvertTo-Json -Depth 20) + "`n")
$manifest = [ordered]@{
    schema = 'headroom-user-script-key-register/v1'
    execute = [bool]$Execute
    metadata_path = [IO.Path]::GetFullPath($MetadataPath)
    user_scripts_dir = [IO.Path]::GetFullPath($UserScriptsDir)
    indicator_source = [IO.Path]::GetFullPath($IndicatorSource)
    indicator_source_sha256 = $indicatorSha256
    indicator_version = $sourceVersion
    backup_path = [IO.Path]::GetFullPath($BackupPath)
    registered_key = $key
    before_scripts = $beforeScripts
    after_scripts = $afterScripts
    before_market = $beforeMarket
    after_market = $afterMarket
    original_sha256 = (Get-FileHash -LiteralPath $MetadataPath -Algorithm SHA256).Hash
    target_script = $targetScript
    metadata_write_performed = $false
    idempotent_existing_registration = $metadataAlreadyCorrect
}
if ($Execute) {
    if (-not $metadataAlreadyCorrect) {
        [IO.Directory]::CreateDirectory((Split-Path -Path ([IO.Path]::GetFullPath($BackupPath)) -Parent)) | Out-Null
        Copy-Item -LiteralPath $MetadataPath -Destination $BackupPath -Force
        if ((Get-FileHash -LiteralPath $MetadataPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash) { throw 'metadata_backup_hash_mismatch' }
        [IO.File]::WriteAllText($MetadataPath, $out, [Text.UTF8Encoding]::new($false))
        $parsed = [IO.File]::ReadAllText($MetadataPath) | ConvertFrom-Json -AsHashtable
        if (-not $parsed.scripts.ContainsKey($key) -or -not $parsed.market.ContainsKey($key)) { throw 'metadata_post_write_key_missing' }
        if (($parsed.market[$key].id -ne 'headroom-status-indicator') -or ($parsed.market[$key].script_url -ne 'local://headroom-status-indicator.js')) { throw 'metadata_post_write_value_invalid' }
        $manifest.metadata_write_performed = $true
    }
    $manifest.post_sha256 = (Get-FileHash -LiteralPath $MetadataPath -Algorithm SHA256).Hash
    # Copy the indicator file into the user-scripts directory the loader scans.
    [IO.Directory]::CreateDirectory($UserScriptsDir) | Out-Null
    Copy-Item -LiteralPath $IndicatorSource -Destination $targetScript -Force
    if ((Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash -ne $indicatorSha256) { throw 'indicator_copy_hash_mismatch' }
    $manifest.indicator_target_sha256 = (Get-FileHash -LiteralPath $targetScript -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 10
