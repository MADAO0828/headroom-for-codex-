[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SettingsPath,
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read the settings document without printing any secret values.
$text = [IO.File]::ReadAllText($SettingsPath)
$doc = $text | ConvertFrom-Json

if ($doc.PSObject.Properties['relayProfiles'] -eq $null -or @($doc.relayProfiles).Count -eq 0) { throw 'relayProfiles_missing' }

$existingIds = @($doc.relayProfiles | ForEach-Object { [string]$_.id })
$aggregateId = 'relay-aggregate-headroom'
if ($existingIds -contains $aggregateId) { throw "aggregate_already_exists:$aggregateId" }

# Member ids: all existing non-aggregate profiles (keep their config untouched).
$members = @($doc.relayProfiles | Where-Object { [string]$_.relayMode -ne 'aggregate' } | ForEach-Object {
    [ordered]@{ profileId = [string]$_.id; weight = 1 }
})
if ($members.Count -eq 0) { throw 'no_member_profiles' }

$previousActiveRelayId = [string]$doc.activeRelayId
$previousActiveAggregateRelayId = if ($doc.PSObject.Properties['activeAggregateRelayId']) { [string]$doc.activeAggregateRelayId } else { '' }

$aggregateProfile = [ordered]@{
    id = $aggregateId
    name = 'Headroom 聚合代理'
    upstreamBaseUrl = ''
    protocol = 'responses'
    relayMode = 'aggregate'
    officialMixApiKey = $false
    testModel = ''
    configContents = ''
    authContents = ''
    useCommonConfig = $true
    contextSelection = [ordered]@{ mcpServers = @(); skills = @(); plugins = @() }
    contextSelectionInitialized = $false
    contextWindow = ''
    autoCompactLimit = ''
    modelInsertMode = 'patch'
    modelList = ''
    modelWindows = ''
    modelVlm = ''
    vlmModel = ''
    vlmBaseUrl = ''
    sub2apiEnabled = $false
    aggregate = [ordered]@{
        strategy = 'conversationRoundRobin'
        members = @($members)
    }
}

$aggregateEntry = [ordered]@{
    id = $aggregateId
    name = 'Headroom 聚合代理'
    strategy = 'conversationRoundRobin'
    members = @($members | ForEach-Object { [ordered]@{ relayId = [string]$_.profileId; weight = [int]$_.weight } })
}

$plan = [ordered]@{
    schema = 'headroom-aggregate-relay/v1'
    execute = [bool]$Execute
    settings_path = $SettingsPath
    backup_path = $BackupPath
    aggregate_id = $aggregateId
    member_profile_ids = @($members | ForEach-Object { [string]$_.profileId })
    member_count = $members.Count
    previous_active_relay_id = $previousActiveRelayId
    previous_active_aggregate_relay_id = $previousActiveAggregateRelayId
    new_active_relay_id = $aggregateId
    new_active_aggregate_relay_id = $aggregateId
    original_sha256 = (Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash
    note = 'Existing relay profiles are NOT modified; only an aggregate profile and activation are added.'
}

if ($Execute) {
    # Backup first (caller passes a project-root backup path).
    [IO.Directory]::CreateDirectory((Split-Path -Parent $BackupPath)) | Out-Null
    Copy-Item -LiteralPath $SettingsPath -Destination $BackupPath -Force
    if ((Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash) { throw 'backup_hash_mismatch' }

    # Append the aggregate profile to relayProfiles.
    $newProfiles = @($doc.relayProfiles | ForEach-Object { $_ })
    $newProfiles += $aggregateProfile
    $doc.relayProfiles = @($newProfiles)

    # Replace aggregateRelayProfiles with the single aggregate entry.
    if ($doc.PSObject.Properties['aggregateRelayProfiles']) {
        $doc.aggregateRelayProfiles = @($aggregateEntry)
    } else {
        $doc | Add-Member -NotePropertyName aggregateRelayProfiles -NotePropertyValue @($aggregateEntry)
    }

    # Activate the aggregate.
    $doc.activeRelayId = $aggregateId
    if ($doc.PSObject.Properties['activeAggregateRelayId']) {
        $doc.activeAggregateRelayId = $aggregateId
    } else {
        $doc | Add-Member -NotePropertyName activeAggregateRelayId -NotePropertyValue $aggregateId
    }

    $out = ($doc | ConvertTo-Json -Depth 40)
    [IO.File]::WriteAllText($SettingsPath, $out, [Text.UTF8Encoding]::new($false))

    # Validate: parse back, confirm the six original profiles are byte-identical in id/name/relayMode,
    # and the aggregate is active.
    $parsed = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    if ([string]$parsed.activeRelayId -ne $aggregateId) { throw 'active_relay_not_aggregate' }
    $aggInProfiles = @($parsed.relayProfiles | Where-Object { [string]$_.id -eq $aggregateId })
    if ($aggInProfiles.Count -ne 1 -or [string]$aggInProfiles[0].relayMode -ne 'aggregate') { throw 'aggregate_profile_missing' }
    $aggEntries = @($parsed.aggregateRelayProfiles | Where-Object { [string]$_.id -eq $aggregateId })
    if ($aggEntries.Count -ne 1) { throw 'aggregate_entry_missing' }
    $plan.post_sha256 = (Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash
}

$plan | ConvertTo-Json -Depth 12
