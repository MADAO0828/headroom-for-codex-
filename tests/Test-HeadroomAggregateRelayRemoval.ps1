[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $projectRoot 'scripts\Remove-HeadroomAggregateRelay.ps1'

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "assertion_failed:$Message" }
}

function Assert-ParserPass {
    param([string]$Path)
    $parseTokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Path), [ref]$parseTokens, [ref]$parseErrors) | Out-Null
    Assert-True -Condition ($parseErrors.Count -eq 0) -Message ("parser:" + $Path)
}

Assert-ParserPass -Path $scriptPath
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
foreach ($needle in @('phase_b_guard_required','active_relay_points_to_target','backup_hash_mismatch','aggregate_profile_still_present','nonaggregate_profiles_changed','ConvertFrom-Json -AsHashtable','UTF8Encoding')) {
    Assert-True -Condition $scriptText.Contains($needle) -Message ("static:" + $needle)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('headroom-p30b-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $settingsPath = Join-Path $tempRoot 'settings.json'
    $backupPath = Join-Path $tempRoot 'settings.before-removal.json'
    $profileIds = @('relay-one','relay-two','relay-three','relay-four','relay-five','relay-six')
    $profiles = @(
        [ordered]@{ id='relay-one'; name='One'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://one.invalid'; authContents='FIXTURE_SECRET_ONE'; configContents='FIXTURE_CONFIG_ONE' },
        [ordered]@{ id='relay-two'; name='Two'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://two.invalid'; authContents='FIXTURE_SECRET_TWO'; configContents='FIXTURE_CONFIG_TWO' },
        [ordered]@{ id='relay-three'; name='Three'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://three.invalid'; authContents='FIXTURE_SECRET_THREE'; configContents='FIXTURE_CONFIG_THREE' },
        [ordered]@{ id='relay-four'; name='Four'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://four.invalid'; authContents='FIXTURE_SECRET_FOUR'; configContents='FIXTURE_CONFIG_FOUR' },
        [ordered]@{ id='relay-five'; name='Five'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://five.invalid'; authContents='FIXTURE_SECRET_FIVE'; configContents='FIXTURE_CONFIG_FIVE' },
        [ordered]@{ id='relay-six'; name='Six'; relayMode='pureApi'; protocol='responses'; upstreamBaseUrl='https://six.invalid'; authContents='FIXTURE_SECRET_SIX'; configContents='FIXTURE_CONFIG_SIX' },
        [ordered]@{ id='relay-aggregate-headroom'; name='Headroom Aggregate'; relayMode='official'; protocol='responses'; upstreamBaseUrl=''; authContents='FIXTURE_AGG_SECRET'; configContents='FIXTURE_AGG_CONFIG' }
    )
    $fixture = [ordered]@{
        relayProfiles = $profiles
        aggregateRelayProfiles = @([ordered]@{ id='relay-aggregate-headroom'; strategy='weightedRoundRobin'; members=@([ordered]@{ relayId='relay-one'; weight=1 }) })
        activeRelayId = 'relay-three'
        activeAggregateRelayId = ''
        relayApiKey = 'FIXTURE_TOP_LEVEL_SECRET'
    }
    [IO.File]::WriteAllText($settingsPath, (($fixture | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    $secretSamples = @('FIXTURE_SECRET_ONE','FIXTURE_SECRET_TWO','FIXTURE_SECRET_THREE','FIXTURE_SECRET_FOUR','FIXTURE_SECRET_FIVE','FIXTURE_SECRET_SIX','FIXTURE_AGG_SECRET','FIXTURE_TOP_LEVEL_SECRET')

    $dryRaw = (& $scriptPath -SettingsPath $settingsPath -BackupPath $backupPath -DryRun | Out-String)
    $dry = $dryRaw | ConvertFrom-Json
    Assert-True -Condition (-not [bool]$dry.execute) -Message 'dry_run_execute_false'
    Assert-True -Condition ([bool]$dry.dry_run) -Message 'dry_run_flag_true'
    Assert-True -Condition ([bool]$dry.changed) -Message 'dry_run_changed_true'
    Assert-True -Condition ($dry.status -eq 'planned') -Message 'dry_run_status_planned'
    Assert-True -Condition ($dry.aggregate_id -eq 'relay-aggregate-headroom') -Message 'dry_run_exact_id'
    Assert-True -Condition ($dry.aggregate_profile_match_count -eq 1) -Message 'dry_run_profile_match'
    Assert-True -Condition ($dry.aggregate_entry_match_count -eq 1) -Message 'dry_run_entry_match'
    Assert-True -Condition ($dry.active_relay_id_before -eq 'relay-three' -and $dry.active_relay_id_after -eq 'relay-three') -Message 'dry_run_active_nonaggregate_preserved'
    Assert-True -Condition ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -eq $beforeHash) -Message 'dry_run_live_fixture_unchanged'
    Assert-True -Condition (-not (Test-Path -LiteralPath $backupPath)) -Message 'dry_run_no_backup'
    foreach ($secretSample in $secretSamples) { Assert-True -Condition (-not $dryRaw.Contains($secretSample)) -Message ('dry_run_secret_redaction:' + $secretSample) }

    try {
        & $scriptPath -SettingsPath $settingsPath -BackupPath $backupPath -Execute | Out-Null
        throw 'execute_guard_missing'
    }
    catch {
        Assert-True -Condition ($_.Exception.Message -eq 'phase_b_guard_required') -Message 'phase_b_guard'
    }
    Assert-True -Condition ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -eq $beforeHash) -Message 'guard_fixture_unchanged'
    Assert-True -Condition (-not (Test-Path -LiteralPath $backupPath)) -Message 'guard_no_backup'

    $executeRaw = (& $scriptPath -SettingsPath $settingsPath -BackupPath $backupPath -Execute -PhaseB | Out-String)
    $execute = $executeRaw | ConvertFrom-Json
    Assert-True -Condition ([bool]$execute.execute -and [bool]$execute.phase_b_guard) -Message 'execute_phase_b_flags'
    Assert-True -Condition ([bool]$execute.write_performed) -Message 'execute_write_performed'
    Assert-True -Condition ($execute.status -eq 'succeeded') -Message 'execute_status_succeeded'
    Assert-True -Condition ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -eq $beforeHash) -Message 'backup_hash_matches_before'
    Assert-True -Condition ($execute.backup_sha256 -eq $beforeHash) -Message 'manifest_backup_hash_matches'
    foreach ($secretSample in $secretSamples) { Assert-True -Condition (-not $executeRaw.Contains($secretSample)) -Message ('execute_secret_redaction:' + $secretSample) }

    $post = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    $postProfiles = @($post.relayProfiles)
    Assert-True -Condition ($postProfiles.Count -eq 6) -Message 'post_profile_count_six'
    Assert-True -Condition ((@($postProfiles | ForEach-Object { [string]$_.id }) -join ',') -eq ($profileIds -join ',')) -Message 'post_original_profile_ids_preserved'
    foreach ($profileId in $profileIds) {
        $postProfile = @($postProfiles | Where-Object { [string]$_.id -eq $profileId })[0]
        $originalProfile = @($profiles | Where-Object { [string]$_.id -eq $profileId })[0]
        Assert-True -Condition ([string]$postProfile.name -eq [string]$originalProfile.name -and [string]$postProfile.relayMode -eq [string]$originalProfile.relayMode -and [string]$postProfile.authContents -eq [string]$originalProfile.authContents -and [string]$postProfile.configContents -eq [string]$originalProfile.configContents) -Message ('post_profile_semantics:' + $profileId)
    }
    Assert-True -Condition (@($post.aggregateRelayProfiles).Count -eq 0) -Message 'post_aggregate_entries_removed'
    Assert-True -Condition ([string]$post.activeRelayId -eq 'relay-three') -Message 'post_active_relay_preserved'
    Assert-True -Condition ([string]$post.activeAggregateRelayId -eq '') -Message 'post_active_aggregate_empty'
    Assert-True -Condition (([IO.File]::ReadAllText($settingsPath)).IndexOf('FIXTURE_AGG_SECRET', [StringComparison]::Ordinal) -lt 0) -Message 'post_aggregate_secret_not_left'

    $secondHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    $idempotentRaw = (& $scriptPath -SettingsPath $settingsPath -BackupPath $backupPath -Execute -PhaseB | Out-String)
    $idempotent = $idempotentRaw | ConvertFrom-Json
    Assert-True -Condition ($idempotent.status -eq 'already_absent') -Message 'idempotent_status'
    Assert-True -Condition (-not [bool]$idempotent.write_performed) -Message 'idempotent_no_write'
    Assert-True -Condition ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -eq $secondHash) -Message 'idempotent_hash_unchanged'
    foreach ($secretSample in $secretSamples) { Assert-True -Condition (-not $idempotentRaw.Contains($secretSample)) -Message ('idempotent_secret_redaction:' + $secretSample) }

    $liveSettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json'
    if (Test-Path -LiteralPath $liveSettingsPath -PathType Leaf) {
        $liveBeforeHash = (Get-FileHash -LiteralPath $liveSettingsPath -Algorithm SHA256).Hash
        $liveDryRaw = (& $scriptPath -SettingsPath $liveSettingsPath -BackupPath (Join-Path $projectRoot 'backups\codexpp-settings\settings.before-aggregate-removal-dryrun.json') -DryRun | Out-String)
        $liveDry = $liveDryRaw | ConvertFrom-Json
        Assert-True -Condition (-not [bool]$liveDry.execute) -Message 'live_dry_run_execute_false'
        Assert-True -Condition ((Get-FileHash -LiteralPath $liveSettingsPath -Algorithm SHA256).Hash -eq $liveBeforeHash) -Message 'live_settings_hash_unchanged'
        foreach ($secretSample in @('relayApiKey','authContents','configContents')) { Assert-True -Condition (-not $liveDryRaw.Contains($secretSample)) -Message ('live_dry_run_key_redaction:' + $secretSample) }
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'backups\codexpp-settings\settings.before-aggregate-removal-dryrun.json'))) -Message 'live_dry_run_no_backup'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

'PASS Test-HeadroomAggregateRelayRemoval'
