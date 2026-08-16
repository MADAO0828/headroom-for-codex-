[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$syncScript = Join-Path $projectRoot 'scripts\Sync-HeadroomRuntimePatches.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('headroom-runtime-patch-sync-' + [IO.Path]::GetRandomFileName())
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-FixtureFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "assertion_failed:$Message" }
}

function Assert-Equal {
    param([AllowNull()][object]$Expected,[AllowNull()][object]$Actual,[Parameter(Mandatory)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "assertion_failed:$Message expected=[$Expected] actual=[$Actual]" }
}

function Invoke-PatchSyncFixture {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$StateReceipt,
        [switch]$DryRun
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($DryRun) {
            $output = @(& $syncScript -PatchRoot $SourceRoot -RuntimePackageRoot $TargetRoot -ReceiptPath $StateReceipt -DryRun 2>&1)
        }
        else {
            $output = @(& $syncScript -PatchRoot $SourceRoot -RuntimePackageRoot $TargetRoot -ReceiptPath $StateReceipt 2>&1)
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $exitCode = $LASTEXITCODE
    $receipt = if (Test-Path -LiteralPath $StateReceipt -PathType Leaf) {
        Get-Content -LiteralPath $StateReceipt -Raw | ConvertFrom-Json
    }
    else { $null }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Receipt = $receipt }
}

try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $patchRoot = Join-Path $fixtureRoot 'patch-root'
    $runtimePackageRoot = Join-Path $fixtureRoot 'runtime\site-packages\headroom'
    $receiptPath = Join-Path $fixtureRoot 'state\sync-receipt.json'
    $configPath = Join-Path $fixtureRoot 'config.toml'
    $sourceOpenAi = Join-Path $patchRoot 'proxy\handlers\openai.py'
    $sourceRemote = Join-Path $patchRoot 'transforms\kompress_remote.py'
    $targetOpenAi = Join-Path $runtimePackageRoot 'proxy\handlers\openai.py'
    $targetRemote = Join-Path $runtimePackageRoot 'transforms\kompress_remote.py'
    Write-FixtureFile -Path $sourceOpenAi -Content 'source-openai-v2`n'
    Write-FixtureFile -Path $sourceRemote -Content 'source-remote-v1`n'
    Write-FixtureFile -Path $targetOpenAi -Content 'runtime-openai-v1`n'
    Write-FixtureFile -Path $targetRemote -Content 'source-remote-v1`n'
    Write-FixtureFile -Path $configPath -Content 'model_provider = "unchanged"`n'

    $dryRun = Invoke-PatchSyncFixture -SourceRoot $patchRoot -TargetRoot $runtimePackageRoot -StateReceipt $receiptPath -DryRun
    Assert-Equal -Expected 1 -Actual $dryRun.ExitCode -Message 'drift dry-run is fail-closed'
    Assert-Equal -Expected 'drift' -Actual $dryRun.Receipt.status -Message 'drift receipt status'
    Assert-Equal -Expected 'runtime-openai-v1`n' -Actual ([IO.File]::ReadAllText($targetOpenAi)) -Message 'dry-run leaves target unchanged'

    $applied = Invoke-PatchSyncFixture -SourceRoot $patchRoot -TargetRoot $runtimePackageRoot -StateReceipt $receiptPath
    Assert-Equal -Expected 0 -Actual $applied.ExitCode -Message 'fixture sync succeeds'
    Assert-Equal -Expected 'synced' -Actual $applied.Receipt.status -Message 'sync receipt status'
    Assert-Equal -Expected ([IO.File]::ReadAllText($sourceOpenAi)) -Actual ([IO.File]::ReadAllText($targetOpenAi)) -Message 'drifted file synchronized'
    Assert-Equal -Expected 'model_provider = "unchanged"`n' -Actual ([IO.File]::ReadAllText($configPath)) -Message 'config is untouched'

    $inSync = Invoke-PatchSyncFixture -SourceRoot $patchRoot -TargetRoot $runtimePackageRoot -StateReceipt $receiptPath
    Assert-Equal -Expected 0 -Actual $inSync.ExitCode -Message 'in-sync preflight succeeds'
    Assert-Equal -Expected 'in_sync' -Actual $inSync.Receipt.status -Message 'in-sync receipt status'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$inSync.Receipt.manifest_sha256)) -Message 'manifest hash is recorded'

    $badRoot = Join-Path $fixtureRoot 'bad-fixture'
    $badPatchRoot = Join-Path $badRoot 'patch-root'
    $badRuntimeRoot = Join-Path $badRoot 'runtime\site-packages\headroom'
    $badReceiptPath = Join-Path $badRoot 'state\sync-receipt.json'
    $badSourceA = Join-Path $badPatchRoot 'proxy\handlers\a.py'
    $badSourceB = Join-Path $badPatchRoot 'proxy\handlers\b.py'
    $badTargetA = Join-Path $badRuntimeRoot 'proxy\handlers\a.py'
    $badTargetB = Join-Path $badRuntimeRoot 'proxy\handlers\b.py'
    Write-FixtureFile -Path $badSourceA -Content 'source-a-v2`n'
    Write-FixtureFile -Path $badSourceB -Content 'source-b-v2`n'
    Write-FixtureFile -Path $badTargetA -Content 'runtime-a-v1`n'
    [IO.Directory]::CreateDirectory($badTargetB) | Out-Null
    $copyFailure = Invoke-PatchSyncFixture -SourceRoot $badPatchRoot -TargetRoot $badRuntimeRoot -StateReceipt $badReceiptPath
    Assert-Equal -Expected 1 -Actual $copyFailure.ExitCode -Message 'target conflict fails closed'
    Assert-Equal -Expected 'failed' -Actual $copyFailure.Receipt.status -Message 'copy failure receipt status'
    Assert-Equal -Expected 'runtime-a-v1`n' -Actual ([IO.File]::ReadAllText($badTargetA)) -Message 'failed sync leaves earlier target unchanged'

    $startSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\headroom\codexpp-headroom\start-headroom.ps1') -Raw
    $ensureSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\headroom\codexpp-headroom\ensure-headroom.ps1') -Raw
    $rootStartSource = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Start-HeadroomForCodexPP.ps1') -Raw
    Assert-True -Condition ($startSource.Contains('patch_sync_manifest_sha256') -and $startSource.Contains('patch_sync_version')) -Message 'start contract binds patch sync manifest'
    Assert-True -Condition ($ensureSource.Contains('patch_sync_manifest_sha256') -and $ensureSource.Contains('patch_sync_version')) -Message 'ensure contract binds patch sync manifest'
    Assert-True -Condition $rootStartSource.Contains('runtime_patch_drift_requires_quiescence') -Message 'active drift has quiescence error'

    [pscustomobject]@{
        status = 'passed'
        drift_dry_run = $dryRun.Receipt.status
        active_drift_no_write = $true
        applied = $applied.Receipt.status
        in_sync = $inSync.Receipt.status
        copy_failure = $copyFailure.Receipt.status
        config_unchanged = $true
        contract_manifest_fields = $true
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
