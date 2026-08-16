[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SettingsPath,
    [Parameter(Mandatory)][string]$BackupPath,
    [string]$AggregateId = 'relay-aggregate-headroom',
    [switch]$DryRun,
    [switch]$Execute,
    [Alias('AllowPhaseB','ConfirmPhaseB')][switch]$PhaseB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DryRun -and $Execute) { throw 'dry_run_execute_conflict' }
if ($PhaseB -and -not $Execute) { throw 'phase_b_requires_execute' }
if ($Execute -and -not $PhaseB) { throw 'phase_b_guard_required' }
if ([string]::IsNullOrWhiteSpace($AggregateId)) { throw 'aggregate_id_missing' }

$settingsFull = [IO.Path]::GetFullPath($SettingsPath)
$backupFull = [IO.Path]::GetFullPath($BackupPath)
if (-not (Test-Path -LiteralPath $settingsFull -PathType Leaf)) { throw "settings_missing:$settingsFull" }
if ([StringComparer]::OrdinalIgnoreCase.Equals($settingsFull, $backupFull)) { throw 'backup_path_equals_settings' }

function Get-DocumentValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $Document.Contains($Key) -or $null -eq $Document[$Key]) { return '' }
    return [string]$Document[$Key]
}

function Get-EntryId {
    param([AllowNull()][object]$Entry)
    if ($null -eq $Entry) { return '' }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('id') -and $null -ne $Entry['id']) { return [string]$Entry['id'] }
        if ($Entry.Contains('relayId') -and $null -ne $Entry['relayId']) { return [string]$Entry['relayId'] }
        return ''
    }
    $idProperty = $Entry.PSObject.Properties['id']
    if ($null -ne $idProperty -and $null -ne $idProperty.Value) { return [string]$idProperty.Value }
    $relayProperty = $Entry.PSObject.Properties['relayId']
    if ($null -ne $relayProperty -and $null -ne $relayProperty.Value) { return [string]$relayProperty.Value }
    return ''
}

function Get-IdList {
    param([object[]]$Entries)
    return @($Entries | ForEach-Object { Get-EntryId -Entry $_ })
}

$documentText = [IO.File]::ReadAllText($settingsFull)
$document = $documentText | ConvertFrom-Json -AsHashtable
if ($null -eq $document -or $document -isnot [System.Collections.IDictionary]) { throw 'settings_schema_not_object' }
if (-not $document.Contains('relayProfiles')) { throw 'relay_profiles_missing' }

$profiles = @($document['relayProfiles'])
$profileIdsBefore = @(Get-IdList -Entries $profiles)
if (@($profileIdsBefore | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'relay_profile_id_missing' }

$aggregateEntries = @()
$aggregatePropertyPresent = $document.Contains('aggregateRelayProfiles')
if ($aggregatePropertyPresent -and $null -ne $document['aggregateRelayProfiles']) {
    $aggregateEntries = @($document['aggregateRelayProfiles'])
}
$aggregateEntryIdsBefore = @(Get-IdList -Entries $aggregateEntries)

$targetProfiles = @($profiles | Where-Object { (Get-EntryId -Entry $_) -eq $AggregateId })
$targetEntries = @($aggregateEntries | Where-Object { (Get-EntryId -Entry $_) -eq $AggregateId })
$remainingProfiles = @($profiles | Where-Object { (Get-EntryId -Entry $_) -ne $AggregateId })
$remainingEntries = @($aggregateEntries | Where-Object { (Get-EntryId -Entry $_) -ne $AggregateId })
$activeRelayIdBefore = Get-DocumentValue -Document $document -Key 'activeRelayId'
$activeAggregateRelayIdBefore = Get-DocumentValue -Document $document -Key 'activeAggregateRelayId'
$activeAggregateRelayIdAfter = $activeAggregateRelayIdBefore
if ($activeAggregateRelayIdBefore -eq $AggregateId) { $activeAggregateRelayIdAfter = '' }

$activeRelayConflict = $activeRelayIdBefore -eq $AggregateId
$changeRequired = ($targetProfiles.Count -gt 0) -or ($targetEntries.Count -gt 0) -or ($activeAggregateRelayIdBefore -eq $AggregateId)
$originalSha256 = (Get-FileHash -LiteralPath $settingsFull -Algorithm SHA256).Hash
$status = if ($activeRelayConflict) { 'blocked_active_relay_target' } elseif ($changeRequired) { 'planned' } else { 'already_absent' }

$manifest = [ordered]@{
    schema = 'headroom-aggregate-relay-removal/v1'
    phase = 'PHASE-A'
    execute = [bool]$Execute
    dry_run = (-not [bool]$Execute)
    phase_b_guard = [bool]$PhaseB
    settings_path = $settingsFull
    backup_path = $backupFull
    aggregate_id = $AggregateId
    original_sha256 = $originalSha256
    backup_required = [bool]$changeRequired
    backup_hash_expected = if ($changeRequired) { $originalSha256 } else { '' }
    profile_ids_before = $profileIdsBefore
    profile_ids_after = @(Get-IdList -Entries $remainingProfiles)
    aggregate_profile_match_count = $targetProfiles.Count
    aggregate_entry_match_count = $targetEntries.Count
    aggregate_entry_ids_before = $aggregateEntryIdsBefore
    active_relay_id_before = $activeRelayIdBefore
    active_relay_id_after = $activeRelayIdBefore
    active_aggregate_relay_id_before = $activeAggregateRelayIdBefore
    active_aggregate_relay_id_after = $activeAggregateRelayIdAfter
    preserved_profile_count = $remainingProfiles.Count
    preserved_profile_ids = @(Get-IdList -Entries $remainingProfiles)
    changed = [bool]$changeRequired
    write_performed = $false
    status = $status
    blocked_reason = if ($activeRelayConflict) { 'active_relay_points_to_aggregate; choose_a_nonaggregate_profile_before_phase_b' } else { '' }
    note = 'Only the exact aggregate id is removed; nonaggregate profiles and active nonaggregate selection are preserved.'
}

if ($Execute -and $activeRelayConflict) { throw 'active_relay_points_to_target' }

if ($Execute -and $changeRequired) {
    [IO.Directory]::CreateDirectory((Split-Path -Path $backupFull -Parent)) | Out-Null
    Copy-Item -LiteralPath $settingsFull -Destination $backupFull -Force
    $backupSha256 = (Get-FileHash -LiteralPath $backupFull -Algorithm SHA256).Hash
    if ($backupSha256 -ne $originalSha256) { throw 'backup_hash_mismatch' }

    $document['relayProfiles'] = @($remainingProfiles)
    if ($aggregatePropertyPresent) {
        if ($null -eq $document['aggregateRelayProfiles']) {
            $document['aggregateRelayProfiles'] = $null
        } else {
            $document['aggregateRelayProfiles'] = @($remainingEntries)
        }
    }
    if ($document.Contains('activeAggregateRelayId') -and $activeAggregateRelayIdBefore -eq $AggregateId) {
        $document['activeAggregateRelayId'] = ''
    }

    $serialized = (($document | ConvertTo-Json -Depth 40) + "`n")
    try {
        [IO.File]::WriteAllText($settingsFull, $serialized, [Text.UTF8Encoding]::new($false))
        $postDocument = [IO.File]::ReadAllText($settingsFull) | ConvertFrom-Json -AsHashtable
        $postProfiles = @($postDocument['relayProfiles'])
        $postAggregateEntries = if ($postDocument.Contains('aggregateRelayProfiles') -and $null -ne $postDocument['aggregateRelayProfiles']) { @($postDocument['aggregateRelayProfiles']) } else { @() }
        if (@($postProfiles | Where-Object { (Get-EntryId -Entry $_) -eq $AggregateId }).Count -ne 0) { throw 'aggregate_profile_still_present' }
        if (@($postAggregateEntries | Where-Object { (Get-EntryId -Entry $_) -eq $AggregateId }).Count -ne 0) { throw 'aggregate_entry_still_present' }
        if ([string](Get-DocumentValue -Document $postDocument -Key 'activeRelayId') -ne $activeRelayIdBefore) { throw 'active_relay_changed' }
        if ([string](Get-DocumentValue -Document $postDocument -Key 'activeAggregateRelayId') -ne $activeAggregateRelayIdAfter) { throw 'active_aggregate_relay_id_invalid' }
        $postProfileIds = @(Get-IdList -Entries $postProfiles)
        if (($postProfileIds -join "`n") -ne ((Get-IdList -Entries $remainingProfiles) -join "`n")) { throw 'nonaggregate_profiles_changed' }
        $manifest.write_performed = $true
        $manifest.post_sha256 = (Get-FileHash -LiteralPath $settingsFull -Algorithm SHA256).Hash
        $manifest.backup_sha256 = $backupSha256
        $manifest.status = 'succeeded'
    }
    catch {
        $caught = $_
        try { Copy-Item -LiteralPath $backupFull -Destination $settingsFull -Force } catch { throw "post_write_restore_failed:$($caught.Exception.Message)" }
        throw $caught
    }
}

$manifest | ConvertTo-Json -Depth 12
