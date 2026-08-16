[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$RemoveLegacy,
    [string]$ProjectRoot = '',
    [string]$DesktopRoot = 'D:\Desktop',
    [string]$ManifestPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($RemoveLegacy -and -not $Execute) { throw 'remove_legacy_requires_execute' }

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Join-Path $PSScriptRoot '..' }
$projectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$desktopRoot = [IO.Path]::GetFullPath($DesktopRoot)
$launcher = Join-Path $projectRoot 'scripts\Launch-HeadroomForCodexPP.vbs'
$shortcutPath = Join-Path $desktopRoot 'Headroom for Codex++.lnk'
$desktopLauncherArguments = '//B //Nologo "' + $launcher + '"'
$legacyShortcuts = @(
    (Join-Path $desktopRoot 'Codex++.lnk'),
    (Join-Path $desktopRoot 'Codex++ 管理工具.lnk')
)
$backupRoot = Join-Path $projectRoot 'backups\system-cutover'
$shortcutBackupRoot = Join-Path $backupRoot 'desktop-shortcuts'
$taskBackupRoot = Join-Path $backupRoot 'scheduled-tasks'
$firewallBackupPath = Join-Path $backupRoot 'firewall\Headroom-18787.json'
$taskNames = @(
    'CodexPlusPlus-Headroom-ColdStart',
    'CodexPlusPlus-Headroom-ColdStart-v3',
    'CodexPlusPlus-Headroom-ColdStart-v4',
    'CodexPlusPlus-Headroom-ColdStart-v8'
)

function Resolve-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-PathWithinProject {
    param([string]$Path)
    $full = Resolve-FullPath -Path $Path
    $root = (Resolve-FullPath -Path $projectRoot).TrimEnd('\', '/')
    return $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-ProjectPath {
    param([string]$Path)
    if (-not (Test-PathWithinProject -Path $Path)) { throw "backup_outside_project:$(Resolve-FullPath -Path $Path)" }
}

function Get-HashForText {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-FileSummary {
    param([string]$Path)
    $full = Resolve-FullPath -Path $Path
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [ordered]@{path=$full;exists=$false;sha256=$null;length=$null} }
    $hash = $null
    try { $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = $null }
    return [ordered]@{path=$full;exists=$true;sha256=$hash;length=[int64]$item.Length;last_write_utc=$item.LastWriteTimeUtc.ToString('o')}
}

function Get-ShortcutSummary {
    param([string]$Path)
    $file = Get-FileSummary -Path $Path
    if (-not $file.exists) { return [ordered]@{status='missing';file=$file;target=$null;arguments=$null;working_directory=$null;icon_location=$null;link_flags=$null;run_as_user=$false;metadata_hash=$null} }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Resolve-FullPath -Path $Path))
        $target = [string]$shortcut.TargetPath
        $arguments = [string]$shortcut.Arguments
        $working = [string]$shortcut.WorkingDirectory
        $icon = [string]$shortcut.IconLocation
        $bytes = [IO.File]::ReadAllBytes((Resolve-FullPath -Path $Path))
        $linkFlags = if ($bytes.Length -ge 0x18) { [BitConverter]::ToUInt32($bytes, 0x14) } else { $null }
        $runAsUser = $null -ne $linkFlags -and (($linkFlags -band 0x00001000) -ne 0)
        $metadata = [ordered]@{target=$target;arguments=$arguments;working_directory=$working;icon_location=$icon}
        return [ordered]@{status='present';file=$file;target=$target;arguments=$arguments;working_directory=$working;icon_location=$icon;link_flags=$linkFlags;run_as_user=$runAsUser;metadata_hash=(Get-HashForText -Text (($metadata | ConvertTo-Json -Compress)))}
    }
    catch {
        return [ordered]@{status='error';file=$file;target=$null;arguments=$null;working_directory=$null;icon_location=$null;link_flags=$null;run_as_user=$false;metadata_hash=$null;error=$_.Exception.GetType().Name}
    }
}

function Get-TaskSummary {
    param([string]$TaskName)
    try {
        $tasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue)
        if ($tasks.Count -eq 0) { return [ordered]@{name=$TaskName;status='missing';state=$null;principal=$null;run_level=$null;action_count=0;action_hash=$null} }
        if ($tasks.Count -gt 1) { return [ordered]@{name=$TaskName;status='ambiguous';state=$null;principal=$null;run_level=$null;action_count=$tasks.Count;action_hash=$null} }
        $task = $tasks[0]
        $actionText = @($task.Actions | ForEach-Object { "{0}|{1}|{2}" -f $_.Execute,$_.Arguments,$_.WorkingDirectory }) -join "`n"
        return [ordered]@{name=$TaskName;status='present';state=[string]$task.State;principal=[string]$task.Principal.UserId;run_level=[string]$task.Principal.RunLevel;action_count=@($task.Actions).Count;action_hash=(Get-HashForText -Text $actionText)}
    }
    catch {
        return [ordered]@{name=$TaskName;status='error';state=$null;principal=$null;run_level=$null;action_count=0;action_hash=$null;error=$_.Exception.GetType().Name}
    }
}

function Get-FirewallSummary {
    try {
        $rules = @(Get-NetFirewallRule -DisplayName 'Headroom 18787' -ErrorAction SilentlyContinue)
        if ($rules.Count -eq 0) { return [ordered]@{status='missing';display_name='Headroom 18787';rule_count=0;rules=@()} }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($rule in $rules) {
            $filters = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
            foreach ($portFilter in $filters) {
                $row = [ordered]@{display_name=[string]$rule.DisplayName;enabled=[string]$rule.Enabled;direction=[string]$rule.Direction;action=[string]$rule.Action;profile=[string]$rule.Profile;protocol=[string]$portFilter.Protocol;local_port=[string]$portFilter.LocalPort;remote_port=[string]$portFilter.RemotePort}
                $row.rule_hash = Get-HashForText -Text (($row | ConvertTo-Json -Compress))
                [void]$rows.Add($row)
            }
        }
        $expected = @($rows | Where-Object { $_.protocol -eq 'TCP' -and $_.local_port -eq '18787' -and $_.direction -eq 'Inbound' -and $_.action -eq 'Allow' })
        $status = if ($rows.Count -eq 1 -and $expected.Count -eq 1) { 'present' } else { 'ambiguous' }
        return [ordered]@{status=$status;display_name='Headroom 18787';rule_count=$rows.Count;rules=@($rows)}
    }
    catch {
        return [ordered]@{status='error';display_name='Headroom 18787';rule_count=0;rules=@();error=$_.Exception.GetType().Name}
    }
}

foreach ($required in @($launcher, $desktopRoot)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "required_path_missing:$required" }
}

$targetSummary = Get-ShortcutSummary -Path $shortcutPath
$targetWscript = Resolve-FullPath -Path (Join-Path $env:WINDIR 'System32\wscript.exe')
$targetConfigured = $targetSummary.status -eq 'present' -and
    [string]$targetSummary.target -and [IO.Path]::GetFullPath([string]$targetSummary.target).Equals($targetWscript, [StringComparison]::OrdinalIgnoreCase) -and
    [string]$targetSummary.arguments -match [regex]::Escape($launcher) -and
    [string]$targetSummary.arguments -notmatch '(?i)--phase-b' -and
    [string]$targetSummary.working_directory -and [IO.Path]::GetFullPath([string]$targetSummary.working_directory).Equals($projectRoot, [StringComparison]::OrdinalIgnoreCase) -and
    [bool]$targetSummary.run_as_user
$targetPlanStatus = if ($targetSummary.status -eq 'error') { 'error' } elseif ($targetConfigured) { 'already_configured' } elseif ($targetSummary.status -eq 'missing') { 'create_required' } else { 'update_required' }

$legacyResults = [System.Collections.Generic.List[object]]::new()
foreach ($legacyPath in $legacyShortcuts) { [void]$legacyResults.Add([ordered]@{path=$legacyPath;summary=(Get-ShortcutSummary -Path $legacyPath);planned_action=if((Test-Path -LiteralPath $legacyPath -PathType Leaf) -and $RemoveLegacy){'remove_on_execute'}else{'retain_until_p10b'}}) }

$taskResults = [System.Collections.Generic.List[object]]::new()
foreach ($taskName in $taskNames) { $summary = Get-TaskSummary -TaskName $taskName; [void]$taskResults.Add([ordered]@{name=$taskName;summary=$summary;planned_action=if($summary.status -eq 'present' -and $RemoveLegacy){'unregister_on_execute'}else{'retain_until_p10b'}}) }
$firewall = Get-FirewallSummary
$firewallPlan = if ($firewall.status -eq 'present' -and $RemoveLegacy) { 'remove_on_execute' } elseif ($firewall.status -eq 'missing') { 'missing' } elseif ($firewall.status -eq 'present') { 'retain_until_p10b' } else { 'review_before_execute' }

if ($Execute) {
    if (@($taskResults | Where-Object { $_.summary.status -in @('error','ambiguous') }).Count -gt 0) { throw 'scheduled_task_preflight_failed' }
    if ($firewall.status -in @('error','ambiguous')) { throw "firewall_preflight_failed:$($firewall.status)" }
    foreach ($directory in @($shortcutBackupRoot, $taskBackupRoot, (Split-Path -Path $firewallBackupPath -Parent))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

    foreach ($legacy in $legacyResults) {
        $legacyPath = [string]$legacy.path
        if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { continue }
        $backupPath = Join-Path $shortcutBackupRoot ([IO.Path]::GetFileName($legacyPath))
        Copy-Item -LiteralPath $legacyPath -Destination $backupPath -Force
        if ((Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash) { throw "shortcut_backup_hash_mismatch:$legacyPath" }
        if ($RemoveLegacy) { Remove-Item -LiteralPath $legacyPath -Force }
    }

    if (-not $targetConfigured) {
        if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
            $targetBackup = Join-Path $shortcutBackupRoot 'Headroom for Codex++.lnk.previous'
            Copy-Item -LiteralPath $shortcutPath -Destination $targetBackup -Force
            if ((Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $targetBackup -Algorithm SHA256).Hash) { throw 'target_shortcut_backup_hash_mismatch' }
        }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $targetWscript
        $shortcut.Arguments = $desktopLauncherArguments
        $shortcut.WorkingDirectory = $projectRoot
        $shortcut.IconLocation = 'D:\program\Codex++\codex-plus-plus-manager.exe,0'
        $shortcut.Description = 'Start Headroom, Codex++ Manager and Codex++ through the verified project-root route'
        $shortcut.Save()
        # The shortcut must launch elevated on a plain double-click so the
        # runas in Launch-HeadroomForCodexPP.vbs always succeeds regardless of
        # the invoking shell's integrity.  WScript.Shell.CreateShortcut cannot
        # express "run as administrator", so set SLDF_RUNAS_USER (0x00001000)
        # in the ShellLinkHeader LinkFlags (offset 0x14, little-endian) after
        # Save().  This is the documented .lnk flag Windows reads to prompt
        # for elevation on launch; it survives Explorer and COM reads.
        $lnkBytes = [IO.File]::ReadAllBytes($shortcutPath)
        if ($lnkBytes.Length -lt 0x18) { throw 'shortcut_too_small_for_runas_flag' }
        $linkFlags = [BitConverter]::ToUInt32($lnkBytes, 0x14)
        $linkFlags = $linkFlags -bor 0x00001000
        $lnkBytes[0x14] = [byte]($linkFlags -band 0xFF)
        $lnkBytes[0x15] = [byte](($linkFlags -shr 8) -band 0xFF)
        $lnkBytes[0x16] = [byte](($linkFlags -shr 16) -band 0xFF)
        $lnkBytes[0x17] = [byte](($linkFlags -shr 24) -band 0xFF)
        [IO.File]::WriteAllBytes($shortcutPath, $lnkBytes)
        $verified = Get-ShortcutSummary -Path $shortcutPath
        if ($verified.status -ne 'present' -or -not [IO.Path]::GetFullPath([string]$verified.target).Equals($targetWscript, [StringComparison]::OrdinalIgnoreCase) -or [string]$verified.arguments -notmatch [regex]::Escape($launcher) -or [string]$verified.arguments -match '(?i)--phase-b') { throw 'desktop_shortcut_verification_failed' }
        $finalLnkBytes = [IO.File]::ReadAllBytes($shortcutPath)
        $finalLinkFlags = [BitConverter]::ToUInt32($finalLnkBytes, 0x14)
        if (($finalLinkFlags -band 0x00001000) -eq 0) { throw 'desktop_shortcut_runas_flag_missing' }
    }

    foreach ($taskEntry in $taskResults) {
        if ($taskEntry.summary.status -ne 'present') { continue }
        $xml = Export-ScheduledTask -TaskName $taskEntry.name -TaskPath '\'
        $xmlPath = Join-Path $taskBackupRoot ($taskEntry.name + '.xml')
        [IO.File]::WriteAllText($xmlPath, ($xml.Replace("`r`n", "`n").Replace("`r", "`n")), [Text.UTF8Encoding]::new($false))
        if ($RemoveLegacy) { Unregister-ScheduledTask -TaskName $taskEntry.name -TaskPath '\' -Confirm:$false }
    }
    if ($firewall.status -eq 'present') {
        [IO.File]::WriteAllText($firewallBackupPath, (($firewall | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
        if ($RemoveLegacy) { Remove-NetFirewallRule -DisplayName 'Headroom 18787' }
    }
}

$plannedActions = @(
    "Ensure $shortcutPath points to project launcher $launcher.",
    'Remove only the two named legacy desktop shortcuts when -Execute -RemoveLegacy is explicitly supplied.',
    'Export and optionally unregister only the four exact CodexPlusPlus-Headroom-ColdStart task names.',
    'Export and optionally remove only the exact Headroom 18787 inbound TCP/18787 firewall rule; ambiguous matches block execution.',
    'Rollback backups are written under backups\\system-cutover before any replacement/removal.'
)
$manifest = [ordered]@{
    schema_version=2; generated_at_utc=[DateTime]::UtcNow.ToString('o'); execute=[bool]$Execute; remove_legacy=[bool]$RemoveLegacy
    project_root=$projectRoot; desktop_root=$desktopRoot; launcher=$launcher
    shortcut=[ordered]@{path=$shortcutPath;status=$targetPlanStatus;summary=$targetSummary;planned_action=if($targetPlanStatus -eq 'already_configured'){'none'}else{'create_or_update_on_execute'}}
    legacy_shortcuts=@($legacyResults); scheduled_tasks=@($taskResults); firewall=[ordered]@{summary=$firewall;planned_action=$firewallPlan}
    planned_actions=$plannedActions; rollback=[ordered]@{root=$backupRoot;desktop=$shortcutBackupRoot;tasks=$taskBackupRoot;firewall=$firewallBackupPath}
}
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    Assert-ProjectPath -Path $ManifestPath
    $manifestPathFull = Resolve-FullPath -Path $ManifestPath
    [IO.Directory]::CreateDirectory((Split-Path -Path $manifestPathFull -Parent)) | Out-Null
    [IO.File]::WriteAllText($manifestPathFull, (($manifest | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
}
[pscustomobject]$manifest
