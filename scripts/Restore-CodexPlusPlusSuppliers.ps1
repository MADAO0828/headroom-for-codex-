[CmdletBinding()]
param(
    [string]$SourcePath = 'C:\Users\ma dao\.codex-session-delete\settings.json.correct-backup-20260801',
    [string]$TargetPath = 'C:\Users\ma dao\.codex-session-delete\settings.json',
    [string]$BackupPath = '',
    [string]$ReceiptPath = '',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Document([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "settings_file_missing:$path"
    }
    try {
        return [IO.File]::ReadAllText($path) | ConvertFrom-Json -Depth 100
    } catch {
        throw "settings_json_invalid:$path"
    }
}

function Get-ProfileList([object]$document, [string]$label, [switch]$Strict) {
    $profileProperty = $document.PSObject.Properties['relayProfiles']
    if ($null -eq $profileProperty) { throw "relay_profiles_missing:$label" }
    $profiles = @($document.relayProfiles)
    if ($profiles.Count -lt 1) { throw "relay_profiles_empty:$label" }
    $ids = @($profiles | ForEach-Object { [string]$_.id })
    if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw "relay_profile_id_missing:$label" }
    if ((@($ids | Sort-Object -Unique)).Count -ne $ids.Count) { throw "relay_profile_id_duplicate:$label" }
    if ($Strict) {
        if ($profiles.Count -lt 3) { throw "relay_profiles_too_few:$label" }
        $aggregate = @($profiles | Where-Object { [string]$_.id -eq 'relay-aggregate-headroom' -or [string]$_.relayMode -eq 'aggregate' })
        if ($aggregate.Count -gt 0) { throw "aggregate_profile_not_allowed:$label" }
        foreach ($profile in $profiles) {
            foreach ($requiredName in @('id', 'name', 'upstreamBaseUrl', 'relayMode', 'configContents', 'authContents')) {
                if ($null -eq $profile.PSObject.Properties[$requiredName]) { throw ('relay_profile_field_missing:{0}:{1}' -f $label, $requiredName) }
            }
        }
    }
    return $profiles
}

function Get-HostSummary([string]$url) {
    try {
        $uri = [Uri]$url
        return $uri.Scheme + '://' + $uri.Host + ':' + $uri.Port
    } catch {
        return '<invalid>'
    }
}

function Get-SafeSummary([object]$document, [string]$label, [string]$path, [switch]$Strict) {
    $profiles = @(Get-ProfileList $document $label -Strict:$Strict)
    $items = @($profiles | ForEach-Object {
        [ordered]@{
            id = [string]$_.id
            name = [string]$_.name
            upstream_host = Get-HostSummary ([string]$_.upstreamBaseUrl)
            relay_mode = [string]$_.relayMode
            config_present = -not [string]::IsNullOrWhiteSpace([string]$_.configContents)
            auth_present = -not [string]::IsNullOrWhiteSpace([string]$_.authContents)
        }
    })
    return [ordered]@{
        label = $label
        path = $path
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        bytes = (Get-Item -LiteralPath $path).Length
        profile_count = $profiles.Count
        profile_ids = @($profiles | ForEach-Object { [string]$_.id })
        active_relay_id = if ($document.PSObject.Properties['activeRelayId']) { [string]$document.activeRelayId } else { '' }
        active_aggregate_relay_id = if ($document.PSObject.Properties['activeAggregateRelayId']) { [string]$document.activeAggregateRelayId } else { '' }
        profiles = $items
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $BackupPath = Join-Path $projectRoot (Join-Path 'backups\supplier-recovery' ("settings.before-restore-$stamp.json"))
}
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $projectRoot 'evidence\supplier-recovery-20260803.json'
}

$sourceDocument = Get-Document $SourcePath
$targetDocument = Get-Document $TargetPath
$sourceSummary = Get-SafeSummary $sourceDocument 'source' $SourcePath -Strict
$targetSummary = Get-SafeSummary $targetDocument 'target_before' $TargetPath
$targetDirectory = Split-Path -Parent $TargetPath
$managerProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('codex-plus-plus-manager.exe', 'codex-plus-plus.exe') })

$receipt = [ordered]@{
    schema = 'codexpp-supplier-recovery/v1'
    execute = [bool]$Execute
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    source = $sourceSummary
    target_before = $targetSummary
    manager_processes_observed = @($managerProcesses | ForEach-Object { [ordered]@{ name = $_.Name; pid = [int]$_.ProcessId; started = [string]$_.CreationDate } })
    backup_path = $BackupPath
    receipt_path = $ReceiptPath
    status = 'dry_run'
    warning = if ($managerProcesses.Count -gt 0) { 'manager_or_client_running;_settings_file_replacement_does_not_restart_or_stop_processes' } else { '' }
}

if ($Execute) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $BackupPath)) | Out-Null
    Copy-Item -LiteralPath $TargetPath -Destination $BackupPath -Force
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TargetPath).Hash
    $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BackupPath).Hash
    if ($beforeHash -ne $backupHash) { throw 'pre_restore_backup_hash_mismatch' }

    $tempPath = Join-Path $targetDirectory ('.' + (Split-Path -Leaf $TargetPath) + '.restore.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $tempPath -Force
        Move-Item -LiteralPath $tempPath -Destination $TargetPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }

    $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TargetPath).Hash
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourcePath).Hash
    if ($afterHash -ne $sourceHash) { throw 'post_restore_hash_mismatch' }
    $verifiedDocument = Get-Document $TargetPath
    $verifiedSummary = Get-SafeSummary $verifiedDocument 'target_after' $TargetPath
    Start-Sleep -Seconds 2
    $stableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TargetPath).Hash
    if ($stableHash -ne $sourceHash) { throw 'target_changed_after_restore' }
    $receipt.status = 'succeeded'
    $receipt.target_after = $verifiedSummary
    $receipt.stable_sha256 = $stableHash
}

$receipt.completed_at_utc = [DateTime]::UtcNow.ToString('o')
$receiptJson = ($receipt | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
[IO.Directory]::CreateDirectory((Split-Path -Parent $ReceiptPath)) | Out-Null
[IO.File]::WriteAllText($ReceiptPath, $receiptJson + "`n", [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 20
