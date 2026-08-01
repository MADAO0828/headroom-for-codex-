[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$RemoveSource,
    [switch]$RemoveLoaderSources,
    [string]$ProjectRoot = '',
    [string]$ProfileRoot = 'C:\Users\ma dao',
    [string]$ManifestPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RemoveSource -and -not $Execute) {
    throw 'remove_source_requires_execute'
}
if ($RemoveLoaderSources -and -not $RemoveSource) {
    throw 'remove_loader_sources_requires_remove_source'
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Join-Path $PSScriptRoot '..'
}
$projectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$profileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$appDataRoot = Join-Path $profileRoot 'AppData\Roaming\Codex++'
$privateRoot = Join-Path $projectRoot 'runtime\private\c-drive'
$backupRoot = Join-Path $projectRoot 'backups\c-drive'
$cacheHub = Join-Path $projectRoot 'runtime\cache\huggingface\hub'
$separator = [IO.Path]::DirectorySeparatorChar
$metadataPath = Join-Path $appDataRoot 'user_scripts.json'
$loaderKey = 'user:headroom-status-indicator.js'
if ($RemoveLoaderSources) {
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'loader_metadata_missing' }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
    $scriptKeyPresent = $metadata.ContainsKey('scripts') -and $metadata.scripts.ContainsKey($loaderKey)
    $marketKeyPresent = $metadata.ContainsKey('market') -and $metadata.market.ContainsKey($loaderKey)
    if ($scriptKeyPresent -or $marketKeyPresent) { throw 'loader_metadata_key_still_present' }
}

function Resolve-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-PathWithin {
    param(
        [string]$Path,
        [string]$Root,
        [switch]$AllowRoot
    )
    $fullPath = Resolve-FullPath -Path $Path
    $fullRoot = (Resolve-FullPath -Path $Root).TrimEnd('\', '/')
    if ($AllowRoot -and $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $fullPath.StartsWith($fullRoot + $separator, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DestinationInsideProject {
    param([string]$Path)
    if (-not (Test-PathWithin -Path $Path -Root $projectRoot)) {
        throw "destination_outside_project:$(Resolve-FullPath -Path $Path)"
    }
    $current = Resolve-FullPath -Path $Path
    while ($null -ne $current -and $current.Length -gt $projectRoot.Length) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "destination_reparse_point:$current"
        }
        $current = Split-Path -Path $current -Parent
    }
}

function Assert-SourceMappingAllowed {
    param([pscustomobject]$Mapping)
    $source = Resolve-FullPath -Path $Mapping.source
    $profilePrefix = (Resolve-FullPath -Path $profileRoot).TrimEnd('\', '/') + $separator
    if (-not $source.StartsWith($profilePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "source_outside_profile:$source"
    }
    if ($source -match '(?i)\\(?:\.codex|\.deepseek|deepseek)(?:\\|$)') {
        throw "source_protected_unrelated_data:$source"
    }
    # Every mapping is explicit and exact.  No caller can broaden a mapping to
    # C:\Users\...\AppData\Roaming\Codex++ or another user-data root.
    $allowed = Resolve-FullPath -Path $Mapping.allowed_source
    if (-not $source.Equals($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        throw "source_not_in_allowlist:$source"
    }
}

function Assert-RemovableSource {
    param([pscustomobject]$Mapping)
    Assert-SourceMappingAllowed -Mapping $Mapping
    $resolved = (Resolve-Path -LiteralPath $Mapping.source -ErrorAction Stop).ProviderPath
    if ($resolved -in @((Resolve-FullPath -Path $profileRoot), (Resolve-FullPath -Path $appDataRoot))) {
        throw "source_too_broad:$resolved"
    }
    return $resolved
}

function Get-HashForText {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AclSummary {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        return [ordered]@{
            owner = [string]$acl.Owner
            acl_hash = Get-HashForText -Text ([string]$acl.Sddl)
            acl_status = 'verified'
        }
    }
    catch {
        return [ordered]@{
            owner = $null
            acl_hash = $null
            acl_status = 'unavailable'
            acl_error = $_.Exception.GetType().Name
        }
    }
}

function Get-PathSummary {
    param([string]$Path)
    $fullPath = Resolve-FullPath -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [ordered]@{ path=$fullPath; exists=$false; kind='missing'; size=$null; file_count=$null; sha256=$null; owner=$null; acl_hash=$null; acl_status='missing' }
    }
    $acl = Get-AclSummary -Path $fullPath
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $fullPath -Recurse -File -Force -ErrorAction SilentlyContinue)
        $totalBytes = [int64]0
        foreach ($file in $files) { $totalBytes += [int64]$file.Length }
        return [ordered]@{
            path=$fullPath; exists=$true; kind='directory'; size=$totalBytes; file_count=$files.Count; sha256=$null
            owner=$acl.owner; acl_hash=$acl.acl_hash; acl_status=$acl.acl_status
        }
    }
    $sha = $null
    try { $sha = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { $sha = $null }
    return [ordered]@{
        path=$fullPath; exists=$true; kind='file'; size=[int64]$item.Length; file_count=1; sha256=$sha
        owner=$acl.owner; acl_hash=$acl.acl_hash; acl_status=$acl.acl_status
    }
}

function Compare-FileMapping {
    param([pscustomobject]$Mapping)
    $source = Get-PathSummary -Path $Mapping.source
    $destination = Get-PathSummary -Path $Mapping.destination
    $hashEqual = $source.exists -and $destination.exists -and $source.kind -eq 'file' -and $destination.kind -eq 'file' -and
        $null -ne $source.sha256 -and $source.sha256.Equals($destination.sha256, [StringComparison]::OrdinalIgnoreCase)
    $status = if (-not $source.exists) { 'source_missing' } elseif ($hashEqual) { 'verified' } elseif (-not $destination.exists) { 'copy_required' } else { 'hash_mismatch' }
    return [ordered]@{
        status=$status; source=$source; destination=$destination; hash_equal=$hashEqual
        owner_equal=($source.owner -ne $null -and $destination.owner -ne $null -and $source.owner.Equals($destination.owner, [StringComparison]::OrdinalIgnoreCase))
        acl_available=($source.acl_status -eq 'verified' -and $destination.acl_status -in @('verified','missing'))
    }
}

function Compare-DirectoryMapping {
    param([pscustomobject]$Mapping)
    $source = Get-PathSummary -Path $Mapping.source
    $destination = Get-PathSummary -Path $Mapping.destination
    if (-not $source.exists) { return [ordered]@{status='source_missing'; source=$source; destination=$destination; hash_equal=$false; owner_equal=$false; acl_available=($source.acl_status -eq 'verified')} }
    if ($source.kind -ne 'directory') { throw "source_kind_mismatch:$($Mapping.source)" }
    if (-not $destination.exists) { return [ordered]@{status='copy_required'; source=$source; destination=$destination; hash_equal=$false; owner_equal=$false; acl_available=($source.acl_status -eq 'verified')} }
    if ($destination.kind -ne 'directory') { return [ordered]@{status='hash_mismatch'; source=$source; destination=$destination; hash_equal=$false; owner_equal=$false; acl_available=$false} }

    $sourceFiles = @(Get-ChildItem -LiteralPath $Mapping.source -Recurse -File -Force | Sort-Object FullName)
    $destinationFiles = @(Get-ChildItem -LiteralPath $Mapping.destination -Recurse -File -Force | Sort-Object FullName)
    $sourceRel = @($sourceFiles | ForEach-Object { [IO.Path]::GetRelativePath((Resolve-FullPath -Path $Mapping.source), $_.FullName) })
    $destinationRel = @($destinationFiles | ForEach-Object { [IO.Path]::GetRelativePath((Resolve-FullPath -Path $Mapping.destination), $_.FullName) })
    $sameSet = (($sourceRel -join "`n") -eq ($destinationRel -join "`n"))
    $mismatches = [System.Collections.Generic.List[string]]::new()
    if ($sameSet) {
        foreach ($file in $sourceFiles) {
            $relative = [IO.Path]::GetRelativePath((Resolve-FullPath -Path $Mapping.source), $file.FullName)
            $destFile = Join-Path $Mapping.destination $relative
            $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256).Hash
            if (-not $sourceHash.Equals($destinationHash, [StringComparison]::OrdinalIgnoreCase)) { [void]$mismatches.Add($relative) }
        }
    }
    $equal = $sameSet -and $mismatches.Count -eq 0
    return [ordered]@{
        status=if($equal){'verified'}else{'hash_mismatch'}; source=$source; destination=$destination; hash_equal=$equal
        mismatch_count=$mismatches.Count; mismatch_samples=@($mismatches | Select-Object -First 10)
        owner_equal=($source.owner -ne $null -and $destination.owner -ne $null -and $source.owner.Equals($destination.owner, [StringComparison]::OrdinalIgnoreCase))
        acl_available=($source.acl_status -eq 'verified' -and $destination.acl_status -eq 'verified')
    }
}

function Backup-DestinationBeforeReplace {
    param([string]$Destination)
    Assert-DestinationInsideProject -Path $Destination
    $relative = [IO.Path]::GetRelativePath($projectRoot, (Resolve-FullPath -Path $Destination))
    $safeName = ($relative -replace '[\\/:*?"<>|]', '_')
    $backupPath = Join-Path $projectRoot (Join-Path 'backups\migration-conflicts' ($safeName + '.bak'))
    Assert-DestinationInsideProject -Path $backupPath
    [IO.Directory]::CreateDirectory((Split-Path -Path $backupPath -Parent)) | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $backupPath -Recurse -Force
    return $backupPath
}

function Invoke-Mapping {
    param([pscustomobject]$Mapping)
    Assert-SourceMappingAllowed -Mapping $Mapping
    Assert-DestinationInsideProject -Path ([string]$Mapping.destination)
    $comparison = if ($Mapping.kind -eq 'file') { Compare-FileMapping -Mapping $Mapping } else { Compare-DirectoryMapping -Mapping $Mapping }
    $plannedAction = switch ($comparison.status) {
        'source_missing' { 'source_missing_review' }
        'verified' { 'none_already_verified' }
        default { if($Mapping.kind -eq 'file'){'copy_and_verify'}else{'copy_directory_and_verify'} }
    }
    $sourceRetained = ($Mapping.retention -eq 'retain_for_loader') -and -not $RemoveLoaderSources
    if ($Execute -and $comparison.status -eq 'source_missing' -and -not $sourceRetained) {
        $destinationSummary = Get-PathSummary -Path $Mapping.destination
        $backupCandidate = Join-Path $projectRoot (Join-Path 'backups\migration-conflicts' (([IO.Path]::GetRelativePath($projectRoot, (Resolve-FullPath -Path $Mapping.destination)) -replace '[\\/:*?"<>|]', '_') + '.bak'))
        $backupSummary = if (Test-Path -LiteralPath $backupCandidate) { Get-PathSummary -Path $backupCandidate } else { $null }
        if ($destinationSummary.exists -and (($Mapping.kind -eq 'file' -and $destinationSummary.kind -eq 'file') -or ($Mapping.kind -eq 'directory' -and $destinationSummary.kind -eq 'directory'))) {
            if ($null -ne $backupSummary -and $backupSummary.exists -and $backupSummary.kind -eq $destinationSummary.kind) {
                $comparison = [ordered]@{status='already_migrated';source=$comparison.source;destination=$destinationSummary;hash_equal=$true;owner_equal=$true;acl_available=$true;backup=$backupSummary}
            } else {
                throw "source_missing_without_verified_backup:$($Mapping.source)"
            }
        } else {
            throw "source_missing_destination_missing:$($Mapping.source)"
        }
    }
    if ($Execute -and $comparison.status -ne 'source_missing' -and $comparison.status -ne 'verified' -and $comparison.status -ne 'already_migrated') {
        $parent = Split-Path -Path $Mapping.destination -Parent
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        if (Test-Path -LiteralPath $Mapping.destination) { [void](Backup-DestinationBeforeReplace -Destination $Mapping.destination); Remove-Item -LiteralPath $Mapping.destination -Recurse -Force }
        if ($Mapping.kind -eq 'file') { Copy-Item -LiteralPath $Mapping.source -Destination $Mapping.destination -Force }
        else { Copy-Item -LiteralPath $Mapping.source -Destination $Mapping.destination -Recurse -Force }
        $comparison = if ($Mapping.kind -eq 'file') { Compare-FileMapping -Mapping $Mapping } else { Compare-DirectoryMapping -Mapping $Mapping }
        if ($comparison.status -ne 'verified') { throw "post_copy_verification_failed:$($Mapping.source)" }
    }
    if ($Execute -and $RemoveSource -and -not $sourceRetained -and $comparison.status -notin @('source_missing','already_migrated')) {
        # Re-read hashes immediately before deletion so a source that changed
        # during the copy window is never removed without a fresh verified copy.
        $finalComparison = if ($Mapping.kind -eq 'file') { Compare-FileMapping -Mapping $Mapping } else { Compare-DirectoryMapping -Mapping $Mapping }
        if ($finalComparison.status -ne 'verified') { throw "pre_remove_verification_failed:$($Mapping.source)" }
        $comparison = $finalComparison
        $resolvedSource = Assert-RemovableSource -Mapping $Mapping
        if ($Mapping.kind -eq 'file') { Remove-Item -LiteralPath $resolvedSource -Force }
        else { Remove-Item -LiteralPath $resolvedSource -Recurse -Force }
    }
    $sourceAction = if ($sourceRetained) { 'retain_source_for_user_script_loader' } elseif ($RemoveSource -and $Execute -and $comparison.status -eq 'verified') { 'source_removed' } else { 'source_retained_until_p10b' }
    return [ordered]@{
        label=$Mapping.label; kind=$Mapping.kind; retention=$Mapping.retention; source=$Mapping.source; destination=$Mapping.destination
        status=$comparison.status; planned_action=$plannedAction; source_action=$sourceAction; comparison=$comparison
    }
}

$directoryMappings = [System.Collections.Generic.List[object]]::new()
function Add-DirectoryMapping {
    param([string]$Label,[string]$Source,[string]$Destination,[string]$Retention='removable')
    [void]$directoryMappings.Add([pscustomobject]@{label=$Label;kind='directory';source=$Source;allowed_source=$Source;destination=$Destination;retention=$Retention})
}
Add-DirectoryMapping -Label 'user-profile-headroom' -Source (Join-Path $profileRoot '.headroom') -Destination (Join-Path $privateRoot 'user-profile\.headroom')
Add-DirectoryMapping -Label 'user-profile-headroom-venv' -Source (Join-Path $profileRoot '.headroom-venv') -Destination (Join-Path $backupRoot 'user-profile\.headroom-venv')
Add-DirectoryMapping -Label 'huggingface-kompress-cache' -Source (Join-Path $profileRoot '.cache\huggingface\hub\models--chopratejas--kompress-v2-base') -Destination (Join-Path $cacheHub 'models--chopratejas--kompress-v2-base')
Add-DirectoryMapping -Label 'huggingface-modernbert-cache' -Source (Join-Path $profileRoot '.cache\huggingface\hub\models--answerdotai--ModernBERT-base') -Destination (Join-Path $cacheHub 'models--answerdotai--ModernBERT-base')
Add-DirectoryMapping -Label 'codexpp-acceptance' -Source (Join-Path $appDataRoot 'acceptance') -Destination (Join-Path $privateRoot 'appdata-roaming\Codex++\acceptance')
Add-DirectoryMapping -Label 'codexpp-tests' -Source (Join-Path $appDataRoot 'tests') -Destination (Join-Path $privateRoot 'appdata-roaming\Codex++\tests')

# The AppData backups root also contains unrelated Codex client and UI backups.
# Only explicitly Headroom/activation/cold-start snapshots enter this package.
$headroomBackupNames = @(
    '20260729-100200-activation-handshake','20260729-102500-activation-marker-refresh','cold-start-battery-fix-20260728-152155418',
    'headroom-cold-start-runner-fix-20260728-203427558','headroom-coldstart-rootfix-20260728-235132','headroom-coldstart-rootfix-deploy-20260729-003511064',
    'headroom-integration-20260728-082812811','headroom-integration-current','headroom-integration-runtime-20260728-091444182',
    'headroom-integration-runtime-20260728-094649781','headroom-integration-runtime-20260728-094855032','headroom-integration-v2-20260728-090543743',
    'headroom-integration-v3-20260728-095609043','headroom-integration-v3-20260728-141532097','headroom-integration-v3-20260728-141603059',
    'headroom-project-sync-20260731'
)
foreach ($name in $headroomBackupNames) {
    Add-DirectoryMapping -Label ("codexpp-headroom-backup:$name") -Source (Join-Path $appDataRoot (Join-Path 'backups' $name)) -Destination (Join-Path $backupRoot (Join-Path 'appdata-roaming\Codex++\backups' $name))
}

$fileMappings = [System.Collections.Generic.List[object]]::new()
function Add-FileMapping {
    param([string]$Label,[string]$Source,[string]$Destination,[string]$Retention='removable')
    [void]$fileMappings.Add([pscustomobject]@{label=$Label;kind='file';source=$Source;allowed_source=$Source;destination=$Destination;retention=$Retention})
}
$rootFileNames = @(
    'add-firewall-rule-admin.vbs','add-firewall-rule.vbs','codex-manager-bootstrap.vbs','codex-wrapper-bootstrap.vbs','codex-wrapper.cmd','codex-wrapper.cs','codex-wrapper.exe','codexpp-headroom-dashboard.ps1',
    'codexpp-headroom-dashboard.ps1.bak-20260727-161400','codexpp-headroom-dashboard.ps1.bak2-20260727-163006','codexpp-headroom-monitor.ps1','codexpp-headroom-monitor.ps1.bak-20260727-161400','codexpp-headroom-monitor.ps1.bak2-20260727-163006',
    'codexpp-route-keeper.ps1','codexpp-route-keeper.ps1.bak2-20260727-163006','codexpp-route-ready.signal','codexpp-route-state.json','codexpp-route-watch.json','codexpp-simple-launcher.vbs',
    'codexpp-startup-chain.tests.ps1','codexpp-startup-gate.ps1','codexpp-startup-gate.ps1.bak-20260727-161400','codexpp-startup-gate.ps1.bak2-20260727-163006','headroom-dashboard-launcher.vbs',
    'headroom-status-indicator.js','headroom-status-indicator.js.bak-20260727-161400','headroom-status-indicator.js.bak2-20260727-163006','restore-manager-window.ps1','startup-result.json'
)
foreach ($fileName in $rootFileNames) {
    $retention = if ($fileName -eq 'headroom-status-indicator.js') { 'retain_for_loader' } else { 'removable' }
    Add-FileMapping -Label ("appdata-root:$fileName") -Source (Join-Path $appDataRoot $fileName) -Destination (Join-Path $privateRoot (Join-Path 'appdata-roaming\Codex++' $fileName)) -Retention $retention
}
foreach ($fileName in @('headroom-status-indicator.js','headroom-status-indicator.js.bak-20260727-152555')) {
    Add-FileMapping -Label ("user-script:$fileName") -Source (Join-Path $appDataRoot (Join-Path 'user_scripts' $fileName)) -Destination (Join-Path $privateRoot (Join-Path 'appdata-roaming\Codex++\user_scripts' $fileName)) -Retention 'retain_for_loader'
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($mapping in $directoryMappings) { [void]$results.Add((Invoke-Mapping -Mapping $mapping)) }
foreach ($mapping in $fileMappings) { [void]$results.Add((Invoke-Mapping -Mapping $mapping)) }

$unscopedBackupNames = @('20260729-014300-chatgpt-client','20260729-094800-chatgpt-main','route-warning-ui-v1-20260731')
$residual = @($results | Where-Object { $_.status -eq 'source_missing' -or $_.retention -eq 'retain_for_loader' -or $_.source_action -eq 'source_retained_until_p10b' })
$p10bActions = @(
    'After P14 and production smoke, rerun this manifest with -Execute -RemoveSource and review every source_action before deletion.',
    'Remove only verified removable Headroom mappings; never broaden to C:\Users\ma dao\.codex, DeepSeek, or the AppData Codex++ root.',
    'Keep loader indicator sources unless -RemoveLoaderSources is supplied after the Headroom metadata key is structurally removed and verified.',
    'Run Set-HeadroomDesktopEntry.ps1 -Execute -RemoveLegacy under the Desktop/task/firewall lock, then independently verify the shortcut, four named tasks and Headroom 18787 rule.'
)
$manifest = [ordered]@{
    schema_version=3; generated_at_utc=[DateTime]::UtcNow.ToString('o'); execute=[bool]$Execute; remove_source=[bool]$RemoveSource; remove_loader_sources=[bool]$RemoveLoaderSources
    project_root=$projectRoot; profile_root=$profileRoot; destination_root=$privateRoot
    results=@($results); residual_allowlist=@($residual | ForEach-Object { [ordered]@{label=$_.label;source=$_.source;reason=if($_.retention -eq 'retain_for_loader'){'user_script_loader'}else{$_.status}} })
    unscoped_backup_names=$unscopedBackupNames; planned_p10b_actions=$p10bActions
    rollback=[ordered]@{destination_conflicts='backups\migration-conflicts';desktop_task_firewall='backups\system-cutover';source_untouched_when_dry_run=$true}
}
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    Assert-DestinationInsideProject -Path $ManifestPath
    $manifestDirectory = Split-Path -Path (Resolve-FullPath -Path $ManifestPath) -Parent
    [IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
    [IO.File]::WriteAllText((Resolve-FullPath -Path $ManifestPath), (($manifest | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
}
[pscustomobject]$manifest
