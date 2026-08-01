[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$MetadataPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json',
    [string]$BackupPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path $projectRoot 'backups\metadata\user_scripts.json.before-headroom-removal'
}
function Assert-ProjectPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = ([IO.Path]::GetFullPath($projectRoot)).TrimEnd('\','/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "backup_outside_project:$full" }
}
Assert-ProjectPath -Path $BackupPath
$metadataFull = [IO.Path]::GetFullPath($MetadataPath)
$text = [IO.File]::ReadAllText($metadataFull)
$doc = $text | ConvertFrom-Json -AsHashtable
$key = 'user:headroom-status-indicator.js'
if (-not $doc.ContainsKey('scripts') -or -not $doc.ContainsKey('market')) { throw 'metadata_schema_missing_sections' }
if (-not $doc.scripts.ContainsKey($key) -or -not $doc.market.ContainsKey($key)) { throw 'headroom_metadata_key_missing' }
$beforeScripts = @($doc.scripts.Keys | Sort-Object)
$beforeMarket = @($doc.market.Keys | Sort-Object)
$doc.scripts.Remove($key)
$doc.market.Remove($key)
$afterScripts = @($doc.scripts.Keys | Sort-Object)
$afterMarket = @($doc.market.Keys | Sort-Object)
$expected = @($beforeScripts | Where-Object { $_ -ne $key })
if (($afterScripts -join "`n") -ne ($expected -join "`n")) { throw 'scripts_key_preservation_failed' }
if ((@($beforeMarket | Where-Object { $_ -ne $key }) -join "`n") -ne ($afterMarket -join "`n")) { throw 'market_key_preservation_failed' }
$out = (($doc | ConvertTo-Json -Depth 20) + "`n")
$manifest = [ordered]@{ schema='headroom-user-script-key-removal/v1'; execute=[bool]$Execute; metadata_path=$metadataFull; backup_path=[IO.Path]::GetFullPath($BackupPath); removed_key=$key; before_scripts=$beforeScripts; after_scripts=$afterScripts; before_market=$beforeMarket; after_market=$afterMarket; original_sha256=(Get-FileHash -LiteralPath $metadataFull -Algorithm SHA256).Hash }
if ($Execute) {
    [IO.Directory]::CreateDirectory((Split-Path -Path ([IO.Path]::GetFullPath($BackupPath)) -Parent)) | Out-Null
    Copy-Item -LiteralPath $metadataFull -Destination $BackupPath -Force
    if ((Get-FileHash -LiteralPath $metadataFull -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash) { throw 'metadata_backup_hash_mismatch' }
    [IO.File]::WriteAllText($metadataFull, $out, [Text.UTF8Encoding]::new($false))
    $parsed = [IO.File]::ReadAllText($metadataFull) | ConvertFrom-Json -AsHashtable
    if ($parsed.scripts.ContainsKey($key) -or $parsed.market.ContainsKey($key)) { throw 'metadata_post_write_key_present' }
    $manifest.post_sha256=(Get-FileHash -LiteralPath $metadataFull -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 10
