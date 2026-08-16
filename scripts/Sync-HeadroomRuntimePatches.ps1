[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PatchRoot,
    [Parameter(Mandatory)][string]$RuntimePackageRoot,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SyncVersion = 1
$PatchRoot = [IO.Path]::GetFullPath($PatchRoot)
$RuntimePackageRoot = [IO.Path]::GetFullPath($RuntimePackageRoot)
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-Manifest {
    if (-not (Test-Path -LiteralPath $PatchRoot -PathType Container)) {
        throw 'patch_root_missing'
    }
    if (-not (Test-Path -LiteralPath $RuntimePackageRoot -PathType Container)) {
        throw 'runtime_package_root_missing'
    }

    $files = @(Get-ChildItem -LiteralPath $PatchRoot -Recurse -File | Where-Object {
            $_.FullName -notmatch '(?i)(\\|/)__pycache__(\\|/)' -and $_.Extension -eq '.py'
        } | Sort-Object FullName)
    if ($files.Count -eq 0) { throw 'patch_manifest_empty' }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($PatchRoot, $file.FullName).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('../', [StringComparison]::Ordinal)) {
            throw 'patch_manifest_path_invalid'
        }
        [void]$entries.Add([pscustomobject]@{
                path = $relative
                size = [int64]$file.Length
                sha256 = Get-Sha256 -Path $file.FullName
            })
    }

    $canonical = (($entries | ForEach-Object {
                '{0}|{1}|{2}' -f $_.path, $_.size, $_.sha256
            }) -join "`n")
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    $manifestHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes))).Replace('-', '')
    return [pscustomobject]@{
        version = $script:SyncVersion
        algorithm = 'sha256'
        entries = @($entries)
        manifest_sha256 = $manifestHash
    }
}

function Get-TargetPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $target = [IO.Path]::GetFullPath((Join-Path $RuntimePackageRoot ($RelativePath -replace '/', '\')))
    $rootWithSeparator = $RuntimePackageRoot.TrimEnd('\') + '\'
    if (-not $target.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'runtime_target_path_invalid'
    }
    return $target
}

function Get-DriftEntries {
    param([Parameter(Mandatory)][object]$Manifest)
    $drift = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Manifest.entries) {
        $target = Get-TargetPath -RelativePath ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "runtime_target_missing:$($entry.path)"
        }
        $targetInfo = Get-Item -LiteralPath $target
        if ([string]$targetInfo.Extension -ne '.py') {
            throw "runtime_target_not_python:$($entry.path)"
        }
        $targetHash = Get-Sha256 -Path $target
        if ([int64]$targetInfo.Length -ne [int64]$entry.size -or $targetHash -ne [string]$entry.sha256) {
            [void]$drift.Add([pscustomobject]@{
                    path = [string]$entry.path
                    target = $target
                    source = Join-Path $PatchRoot (($entry.path -replace '/', '\'))
                    expected_sha256 = [string]$entry.sha256
                    actual_sha256 = $targetHash
                })
        }
    }
    return @($drift)
}

function Write-Receipt {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Drift,
        [Parameter(Mandatory)][bool]$Applied,
        [Parameter(Mandatory)][string]$RollbackStatus
    )

    $receiptParent = Split-Path -Parent $ReceiptPath
    [IO.Directory]::CreateDirectory($receiptParent) | Out-Null
    $safeDetail = ($Detail -replace '[\r\n\t]+', ' ')
    $document = [ordered]@{
        schema = 'headroom-runtime-patch-sync/v1'
        sync_version = $script:SyncVersion
        status = $Status
        error_code = $ErrorCode
        detail = $safeDetail.Substring(0, [Math]::Min(500, $safeDetail.Length))
        dry_run = [bool]$DryRun
        applied = $Applied
        rollback_status = $RollbackStatus
        manifest_version = $Manifest.version
        manifest_algorithm = $Manifest.algorithm
        manifest_sha256 = $Manifest.manifest_sha256
        file_count = @($Manifest.entries).Count
        drift_count = @($Drift).Count
        drift_paths = @($Drift | ForEach-Object { [string]$_.path } | Sort-Object)
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = Join-Path $receiptParent ('.headroom-runtime-patch-sync-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $ReceiptPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]$document
}

$manifest = $null
$drift = @()
$transactionRoot = $null
$appliedEntries = [System.Collections.Generic.List[object]]::new()
$rollbackStatus = 'not_needed'

try {
    $manifest = Get-Manifest
    $drift = @(Get-DriftEntries -Manifest $manifest)
    if ($drift.Count -eq 0) {
        $receipt = Write-Receipt -Status 'in_sync' -ErrorCode '' -Detail '' -Manifest $manifest -Drift $drift -Applied:$false -RollbackStatus $rollbackStatus
        $receipt | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }

    if ($DryRun) {
        $receipt = Write-Receipt -Status 'drift' -ErrorCode 'runtime_patch_drift' -Detail 'runtime package differs from project patch manifest' -Manifest $manifest -Drift $drift -Applied:$false -RollbackStatus $rollbackStatus
        $receipt | ConvertTo-Json -Depth 8 -Compress
        exit 1
    }

    $transactionRoot = Join-Path $RuntimePackageRoot ('.headroom-patch-sync-' + [IO.Path]::GetRandomFileName())
    $stageRoot = Join-Path $transactionRoot 'stage'
    $backupRoot = Join-Path $transactionRoot 'backup'
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null

    foreach ($entry in $drift) {
        $relative = [string]$entry.path
        $source = [string]$entry.source
        $stage = Join-Path $stageRoot ($relative -replace '/', '\')
        $stageParent = Split-Path -Parent $stage
        [IO.Directory]::CreateDirectory($stageParent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $stage -Force
        if ((Get-Sha256 -Path $stage) -ne [string]$entry.expected_sha256) {
            throw "staged_hash_mismatch:$relative"
        }
        $backup = Join-Path $backupRoot ($relative -replace '/', '\')
        $backupParent = Split-Path -Parent $backup
        [IO.Directory]::CreateDirectory($backupParent) | Out-Null
        Copy-Item -LiteralPath ([string]$entry.target) -Destination $backup -Force
        $entry | Add-Member -NotePropertyName stage -NotePropertyValue $stage
        $entry | Add-Member -NotePropertyName backup -NotePropertyValue $backup
    }

    foreach ($entry in $manifest.entries) {
        $source = Join-Path $PatchRoot (([string]$entry.path) -replace '/', '\')
        if ((Get-Sha256 -Path $source) -ne [string]$entry.sha256) {
            throw "source_changed_during_sync:$($entry.path)"
        }
    }

    foreach ($entry in $drift) {
        [IO.File]::Move([string]$entry.stage, [string]$entry.target, $true)
        [void]$appliedEntries.Add($entry)
    }

    foreach ($entry in $manifest.entries) {
        $target = Get-TargetPath -RelativePath ([string]$entry.path)
        if ((Get-Sha256 -Path $target) -ne [string]$entry.sha256) {
            throw "runtime_hash_mismatch_after_sync:$($entry.path)"
        }
    }

    $receipt = Write-Receipt -Status 'synced' -ErrorCode '' -Detail '' -Manifest $manifest -Drift $drift -Applied:$true -RollbackStatus 'not_needed'
    $receipt | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
catch {
    $errorCode = [string]$_.Exception.Message
    if ($appliedEntries.Count -gt 0) {
        $rollbackStatus = 'attempted'
        try {
            foreach ($entry in ($appliedEntries | Sort-Object path -Descending)) {
                [IO.File]::Move([string]$entry.backup, [string]$entry.target, $true)
            }
            $rollbackStatus = 'succeeded'
        }
        catch {
            $rollbackStatus = 'failed'
            $errorCode = "$errorCode;rollback_failed"
        }
    }
    if ($null -eq $manifest) {
        $manifest = [pscustomobject]@{
            version = $script:SyncVersion
            algorithm = 'sha256'
            entries = @()
            manifest_sha256 = ''
        }
    }
    try {
        $receipt = Write-Receipt -Status 'failed' -ErrorCode $errorCode -Detail $errorCode -Manifest $manifest -Drift $drift -Applied:($appliedEntries.Count -gt 0) -RollbackStatus $rollbackStatus
        $receipt | ConvertTo-Json -Depth 8 -Compress
    }
    catch {
        Write-Output ("runtime_patch_sync_receipt_failed:{0}" -f $_.Exception.Message)
    }
    exit 1
}
finally {
    if ($null -ne $transactionRoot -and (Test-Path -LiteralPath $transactionRoot)) {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
