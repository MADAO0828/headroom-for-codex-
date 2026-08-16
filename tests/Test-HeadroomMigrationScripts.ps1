[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "assertion_failed:$Message" }
}

function Assert-ParserPass {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Path), [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True -Condition ($errors.Count -eq 0) -Message ("parser:" + $Path)
}

$movePath = Join-Path $projectRoot 'scripts\Move-HeadroomRuntimeToProject.ps1'
$desktopPath = Join-Path $projectRoot 'scripts\Set-HeadroomDesktopEntry.ps1'
Assert-ParserPass -Path $movePath
Assert-ParserPass -Path $desktopPath

$moveText = Get-Content -LiteralPath $movePath -Raw
$desktopText = Get-Content -LiteralPath $desktopPath -Raw
foreach ($needle in @('remove_source_requires_execute','Get-FileHash','Get-Acl','retain_for_loader','unscoped_backup_names','Assert-DestinationInsideProject')) {
    Assert-True -Condition ($moveText.Contains($needle)) -Message ("move_static:" + $needle)
}
foreach ($needle in @('remove_legacy_requires_execute','Get-ScheduledTask','Get-NetFirewallRule','Export-ScheduledTask','backups\\system-cutover','planned_actions','SLDF_RUNAS_USER','0x00001000','desktop_shortcut_runas_flag_missing','desktopLauncherArguments','--phase-b')) {
    Assert-True -Condition ($desktopText.Contains($needle)) -Message ("desktop_static:" + $needle)
}

try {
    & $movePath -RemoveSource -ErrorAction Stop | Out-Null
    throw 'move_remove_gate_missing'
}
catch {
    Assert-True -Condition ($_.Exception.Message -eq 'remove_source_requires_execute') -Message 'move_remove_gate'
}
try {
    & $desktopPath -RemoveLegacy -ErrorAction Stop | Out-Null
    throw 'desktop_remove_gate_missing'
}
catch {
    Assert-True -Condition ($_.Exception.Message -eq 'remove_legacy_requires_execute') -Message 'desktop_remove_gate'
}

$moveDryRun = & $movePath
Assert-True -Condition (-not [bool]$moveDryRun.execute) -Message 'move_dry_run_execute_false'
Assert-True -Condition (-not [bool]$moveDryRun.remove_source) -Message 'move_dry_run_remove_false'
Assert-True -Condition (@($moveDryRun.results).Count -gt 0) -Message 'move_dry_run_results'
$desktopDryRun = & $desktopPath
Assert-True -Condition (-not [bool]$desktopDryRun.execute) -Message 'desktop_dry_run_execute_false'
Assert-True -Condition (-not [bool]$desktopDryRun.remove_legacy) -Message 'desktop_dry_run_remove_false'
Assert-True -Condition (@($desktopDryRun.scheduled_tasks).Count -eq 4) -Message 'desktop_task_inventory_count'

'PASS Test-HeadroomMigrationScripts'
