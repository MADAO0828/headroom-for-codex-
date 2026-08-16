[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("headroom-candidate-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $manifest = Join-Path $tempRoot 'complex-source.json'
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\New-HeadroomCandidateManifest.ps1') `
        -CandidateKind complex -CandidateProfile source -OutputPath $manifest -ProjectRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'manifest_generation_failed' }

    $generated = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if ($generated.candidate_kind -ne 'complex') { throw 'generated_candidate_kind_mismatch' }
    if ($generated.candidate_profile -ne 'source') { throw 'generated_candidate_profile_mismatch' }

    $result = & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $manifest -ProjectRoot $ProjectRoot
    if ($LASTEXITCODE -ne 0) { throw 'manifest_validation_failed' }
    $parsed = $result | ConvertFrom-Json
    if ($parsed.status -ne 'pass') { throw 'manifest_validation_not_pass' }
    if ($parsed.candidate_kind -ne 'complex' -or $parsed.candidate_profile -ne 'source') {
        throw 'validator_candidate_contract_mismatch'
    }

    $tamperedPath = Join-Path $tempRoot 'tampered.json'
    $tampered = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $tampered.entries[0].sha256 = ('0' * 64)
    [IO.File]::WriteAllText($tamperedPath, (($tampered | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $tamperedPath -ProjectRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 2) { throw 'tampered_manifest_did_not_fail_closed' }

    $fixtureRoot = Join-Path $tempRoot 'fixture'
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs') -Force | Out-Null
    $fixtureFile = Join-Path $fixtureRoot 'docs\sample.txt'
    [IO.File]::WriteAllText($fixtureFile, "baseline`n", [Text.UTF8Encoding]::new($false))
    $fixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureFile).Hash.ToLowerInvariant()
    $fixtureEntry = [ordered]@{ path = 'docs/sample.txt'; size_bytes = (Get-Item -LiteralPath $fixtureFile).Length; sha256 = $fixtureHash }
    $fixtureCanonical = "docs/sample.txt`t$($fixtureEntry.size_bytes)`t$fixtureHash"
    $fixtureManifestHash = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fixtureCanonical)) | ForEach-Object { $_.ToString('x2') }) -join ''
    $fixtureManifest = Join-Path $fixtureRoot 'manifest.json'
    $fixtureObject = [ordered]@{version=1;algorithm='sha256';candidate_id='fixture';candidate_kind='complex';candidate_profile='source';entries=@($fixtureEntry);manifest_hash=$fixtureManifestHash}
    [IO.File]::WriteAllText($fixtureManifest, (($fixtureObject | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($fixtureFile, "changed-after-manifest`n", [Text.UTF8Encoding]::new($false))
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $fixtureManifest -ProjectRoot $fixtureRoot | Out-Null
    if ($LASTEXITCODE -ne 1) { throw 'changed_file_did_not_report_drift' }

    $legacyManifestPath = Join-Path $tempRoot 'legacy-kind.json'
    $legacyObject = [ordered]@{version=1;algorithm='sha256';candidate_id='legacy-fixture';candidate_kind='source';candidate_profile='source';entries=@($fixtureEntry);manifest_hash=$fixtureManifestHash}
    [IO.File]::WriteAllText($legacyManifestPath, (($legacyObject | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $legacyResult = & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $legacyManifestPath -ProjectRoot $fixtureRoot
    if ($LASTEXITCODE -ne 2) { throw 'legacy_kind_did_not_fail_closed' }
    $legacyParsed = $legacyResult | ConvertFrom-Json
    if ($legacyParsed.error_code -ne 'manifest_candidate_kind_legacy_value') {
        throw 'legacy_kind_error_not_diagnostic'
    }

    $legacyGenerationPath = Join-Path $tempRoot 'legacy-generation.json'
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\New-HeadroomCandidateManifest.ps1') `
        -CandidateKind source -CandidateProfile source -OutputPath $legacyGenerationPath -ProjectRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 2) { throw 'legacy_kind_generation_did_not_fail_closed' }

    $profileFixtureRoot = Join-Path $tempRoot 'profile-fixture'
    New-Item -ItemType Directory -Path (Join-Path $profileFixtureRoot 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $profileFixtureRoot 'private') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'docs\sample.txt'), "public`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'private\note.txt'), "profile-only`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'WORK.md'), "ledger`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'README.md'), "readme`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'HANDOFF.md'), "handoff`n", [Text.UTF8Encoding]::new($false))

    $sourceProfileManifest = Join-Path $tempRoot 'profile-source.json'
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\New-HeadroomCandidateManifest.ps1') `
        -CandidateKind simple -CandidateProfile source -OutputPath $sourceProfileManifest -ProjectRoot $profileFixtureRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'source_profile_generation_failed' }
    $sourceProfile = Get-Content -LiteralPath $sourceProfileManifest -Raw | ConvertFrom-Json
    if (-not (@($sourceProfile.entries.path) -contains 'private/note.txt')) {
        throw 'source_profile_file_set_mismatch'
    }
    $sourcePaths = @($sourceProfile.entries.path)
    if ($sourcePaths -contains 'WORK.md') { throw 'volatile_work_ledger_was_included' }
    $workExclusionReasons = @($sourceProfile.excluded_reasons | Where-Object { $_.path -eq 'WORK.md' })
    if ($workExclusionReasons.Count -ne 1 -or $workExclusionReasons[0].reason -ne 'volatile_work_ledger') {
        throw 'volatile_work_ledger_reason_missing'
    }
    if (-not ($sourcePaths -contains 'README.md') -or -not ($sourcePaths -contains 'HANDOFF.md')) {
        throw 'stable_project_docs_were_excluded'
    }
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'WORK.md'), "ledger changed after manifest`n", [Text.UTF8Encoding]::new($false))
    $workChangeResult = & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $sourceProfileManifest -ProjectRoot $profileFixtureRoot
    if ($LASTEXITCODE -ne 0) { throw 'volatile_work_ledger_change_caused_drift' }
    $workChangeParsed = $workChangeResult | ConvertFrom-Json
    if ($workChangeParsed.status -ne 'pass') { throw 'volatile_work_ledger_change_did_not_validate' }
    [IO.File]::WriteAllText((Join-Path $profileFixtureRoot 'README.md'), "readme changed after manifest`n", [Text.UTF8Encoding]::new($false))
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $sourceProfileManifest -ProjectRoot $profileFixtureRoot | Out-Null
    if ($LASTEXITCODE -ne 1) { throw 'stable_project_doc_change_did_not_report_drift' }

    $canaryProfileManifest = Join-Path $tempRoot 'profile-canary.json'
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\New-HeadroomCandidateManifest.ps1') `
        -CandidateKind simple -CandidateProfile canary -OutputPath $canaryProfileManifest -ProjectRoot $profileFixtureRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'canary_profile_generation_failed' }
    $canaryProfile = Get-Content -LiteralPath $canaryProfileManifest -Raw | ConvertFrom-Json
    if ($canaryProfile.candidate_profile -ne 'canary' -or -not (@($canaryProfile.entries.path) -contains 'private/note.txt')) {
        throw 'canary_profile_contract_mismatch'
    }
    $canaryPaths = @($canaryProfile.entries.path)
    if ($canaryPaths -contains 'WORK.md') { throw 'canary_work_ledger_was_included' }
    $canaryWorkReasons = @($canaryProfile.excluded_reasons | Where-Object { $_.path -eq 'WORK.md' })
    if ($canaryWorkReasons.Count -ne 1 -or $canaryWorkReasons[0].reason -ne 'volatile_work_ledger') {
        throw 'canary_work_ledger_reason_missing'
    }
    if (-not ($canaryPaths -contains 'README.md') -or -not ($canaryPaths -contains 'HANDOFF.md')) {
        throw 'canary_project_docs_were_excluded'
    }
    $canaryResult = & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $canaryProfileManifest -ProjectRoot $profileFixtureRoot
    if ($LASTEXITCODE -ne 0) { throw 'canary_profile_validation_failed' }

    $releaseProfileManifest = Join-Path $tempRoot 'profile-release.json'
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\New-HeadroomCandidateManifest.ps1') `
        -CandidateKind build -CandidateProfile release -OutputPath $releaseProfileManifest -ProjectRoot $profileFixtureRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'release_profile_generation_failed' }
    $releaseProfile = Get-Content -LiteralPath $releaseProfileManifest -Raw | ConvertFrom-Json
    if (@($releaseProfile.entries.path) -contains 'private/note.txt') {
        throw 'release_profile_file_set_mismatch'
    }
    $releasePaths = @($releaseProfile.entries.path)
    if ($releasePaths -contains 'WORK.md') { throw 'release_work_ledger_was_included' }
    $releaseWorkReasons = @($releaseProfile.excluded_reasons | Where-Object { $_.path -eq 'WORK.md' })
    if ($releaseWorkReasons.Count -ne 1 -or $releaseWorkReasons[0].reason -ne 'volatile_work_ledger') {
        throw 'release_work_ledger_reason_missing'
    }
    if (-not ($releasePaths -contains 'README.md') -or -not ($releasePaths -contains 'HANDOFF.md')) {
        throw 'release_project_docs_were_excluded'
    }
    $releaseResult = & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $releaseProfileManifest -ProjectRoot $profileFixtureRoot
    if ($LASTEXITCODE -ne 0) { throw 'release_profile_validation_failed' }
    $releaseParsed = $releaseResult | ConvertFrom-Json
    if ($releaseParsed.candidate_kind -ne 'build' -or $releaseParsed.candidate_profile -ne 'release') {
        throw 'release_profile_contract_mismatch'
    }

    $malformedPath = Join-Path $tempRoot 'malformed.json'
    $tampered.entries[0].path = 'C:/outside-project.txt'
    [IO.File]::WriteAllText($malformedPath, (($tampered | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    & $pwsh -NoProfile -File (Join-Path $ProjectRoot 'scripts\Validate-HeadroomCandidate.ps1') `
        -ManifestPath $malformedPath -ProjectRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 2) { throw 'malformed_manifest_did_not_fail_closed' }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'Test-HeadroomCandidateManifest: PASS'
