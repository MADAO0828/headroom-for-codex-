[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$registerScript = Join-Path $projectRoot 'scripts\Register-HeadroomUserScript.ps1'
$indicatorSource = Join-Path $projectRoot 'src\codexpp\Codex++\headroom-status-indicator.js'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "assertion_failed:$Message" }
}

$tempRoot = Join-Path (Join-Path $projectRoot 'runtime\isolated') ('headroom-register-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $metadataPath = Join-Path $tempRoot 'user_scripts.json'
    $scriptsDir = Join-Path $tempRoot 'user_scripts'
    $backupPath = Join-Path $tempRoot 'before.json'
    $document = [ordered]@{
        scripts = [ordered]@{
            'user:existing.js' = $true
            'user:headroom-status-indicator.js' = $true
        }
        market = [ordered]@{
            'user:existing.js' = [ordered]@{ id = 'existing'; script_url = 'local://existing.js' }
            'user:headroom-status-indicator.js' = [ordered]@{ id = 'headroom-status-indicator'; script_url = 'local://headroom-status-indicator.js'; version = '1.0.0.12' }
        }
    }
    [IO.File]::WriteAllText($metadataPath, (($document | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash

    $dryRun = ((& pwsh.exe -NoLogo -NoProfile -File $registerScript -MetadataPath $metadataPath -UserScriptsDir $scriptsDir -IndicatorSource $indicatorSource -BackupPath $backupPath | Out-String).Trim() | ConvertFrom-Json)
    Assert-True -Condition (-not [bool]$dryRun.execute) -Message 'dry_run_execute_false'
    Assert-True -Condition ([bool]$dryRun.idempotent_existing_registration) -Message 'existing_registration_is_idempotent'

    $execute = & pwsh.exe -NoLogo -NoProfile -File $registerScript -Execute -MetadataPath $metadataPath -UserScriptsDir $scriptsDir -IndicatorSource $indicatorSource -BackupPath $backupPath | ConvertFrom-Json
    Assert-True -Condition ([bool]$execute.idempotent_existing_registration) -Message 'execute_reports_idempotent_registration'
    Assert-True -Condition (-not [bool]$execute.metadata_write_performed) -Message 'execute_does_not_rewrite_matching_metadata'
    Assert-True -Condition ((Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash -eq $beforeHash) -Message 'metadata_hash_unchanged'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $scriptsDir 'headroom-status-indicator.js') -PathType Leaf) -Message 'indicator_copied'
    'PASS Test-HeadroomUserScriptRegistration'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
