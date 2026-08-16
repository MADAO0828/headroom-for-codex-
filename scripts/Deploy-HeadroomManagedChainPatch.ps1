[CmdletBinding()]
param(
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'D:\新建文件夹\headroom for codex++'
$built = Join-Path $projectRoot 'runtime\src\CodexPlusPlus-v1.2.47\target\release\codex-plus-plus.exe'
$prodDir = 'D:\program\Codex++'
$prodExe = Join-Path $prodDir 'codex-plus-plus.exe'
$backupRoot = Join-Path $projectRoot 'backups\deployed-binaries'
$plan = [ordered]@{
    schema = 'headroom-managed-chain-patch/v1'
    execute = [bool]$Execute
    built_exe = $built
    built_size = (Get-Item $built).Length
    built_version = (Get-Item $built).VersionInfo.ProductVersion
    built_sha256 = (Get-FileHash $built -Algorithm SHA256).Hash
    prod_exe = $prodExe
    prod_size = (Get-Item $prodExe).Length
    prod_version = (Get-Item $prodExe).VersionInfo.ProductVersion
    prod_sha256 = (Get-FileHash $prodExe -Algorithm SHA256).Hash
    injection_marker_present = $false
    backup_root = $backupRoot
    note = 'Replayable after manual Codex++ upgrades: rebuild release, re-run with -Execute.'
}
$bytes = [IO.File]::ReadAllBytes($built)
$plan.injection_marker_present = [Text.Encoding]::ASCII.GetString($bytes).Contains('access_token')
if (-not $plan.injection_marker_present) { throw 'injection_marker_missing_in_built_exe' }
if ($Execute) {
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $backupRoot ("codex-plus-plus.exe.prod-{0}.bak" -f $stamp)
    Copy-Item -LiteralPath $prodExe -Destination $backup -Force
    $plan.backup_path = $backup
    Copy-Item -LiteralPath $built -Destination $prodExe -Force
    $after = Get-FileHash -LiteralPath $prodExe -Algorithm SHA256
    $plan.deployed_sha256 = $after.Hash
    $plan.deployed_ok = ($after.Hash -eq $plan.built_sha256)
    if (-not $plan.deployed_ok) { throw 'deployed_hash_mismatch' }
}
$plan | ConvertTo-Json -Depth 4