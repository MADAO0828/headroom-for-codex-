[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Execute,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$tempRoot = [Environment]::GetEnvironmentVariable('TEMP')
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    $tempRoot = [IO.Path]::GetTempPath()
}
$projectRootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$projectRuntimeLogRoot = Join-Path $projectRootFull 'runtime\logs'
$projectRuntimeStateRoot = Join-Path $projectRootFull 'runtime\state'
$projectMonitorRoots = @(
    (Join-Path $projectRootFull 'runtime\monitor-diag'),
    (Join-Path $projectRootFull 'runtime\monitor-diagnostic'),
    (Join-Path $projectRootFull 'runtime\monitor-diagnostic2'),
    (Join-Path $projectRootFull 'runtime\monitor-diagnostic3')
)
$allowedRoots = @(
    'C:\Users\ma dao\.headroom',
    'C:\Users\ma dao\.headroom\logs',
    'C:\Users\ma dao\.headroom\codexpp-headroom',
    'C:\Users\ma dao\AppData\Roaming\Codex++',
    $projectRuntimeLogRoot,
    $projectRuntimeStateRoot
) + @(
    (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'),
    (Join-Path $ProjectRoot 'runtime-artifacts\logs'),
    (Join-Path $ProjectRoot 'runtime-artifacts\state'),
    $tempRoot
) + $projectMonitorRoots | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
$protectedRoots = @(
    (Join-Path $projectRootFull 'runtime\private'),
    (Join-Path $projectRootFull 'runtime\cache'),
    (Join-Path $projectRootFull 'runtime\providers'),
    (Join-Path $projectRootFull 'runtime\models'),
    (Join-Path $projectRootFull 'backups'),
    (Join-Path $projectRootFull 'evidence'),
    (Join-Path $projectRootFull 'src\codexpp')
) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }

function Test-AllowedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in $allowedRoots) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-ProtectedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in $protectedRoots) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$patterns = @(
    @{ Root = 'C:\Users\ma dao\.headroom\logs'; Filter = '*' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.log' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.stdout.log' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.stderr.log' },
    # Runtime counters and process/startup snapshots are evidence inputs for
    # the monitor; clear them with the logs so the next acceptance window
    # starts from zero.  Source scripts and backups do not match these names.
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = 'gateway-metrics-state.json' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = 'gateway-process-state.json' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = 'headroom-state-*.json' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = 'headroom-startup-*.json' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = 'headroom-startup-result-*.json' },
    @{ Root = 'C:\Users\ma dao\.headroom'; Filter = 'proxy_savings.json' },
    @{ Root = 'C:\Users\ma dao\.headroom'; Filter = 'savings_events.jsonl' },
    @{ Root = 'C:\Users\ma dao\.headroom\mcp-standalone'; Filter = 'savings_events.jsonl' },
    @{ Root = 'C:\Users\ma dao\.headroom\mcp-standalone'; Filter = 'session_stats.jsonl' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*.log' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*-state.json' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*-status.json' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = 'codexpp-route-state.json' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = 'codexpp-route-watch.json' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = 'codexpp-route-ready.signal' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = 'startup-result.json' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = '*.log' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = '*.stdout.txt' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = '*.stderr.txt' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = 'gateway-metrics-state.json' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = 'gateway-process-state.json' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = 'headroom-state-*.json' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = 'headroom-startup-*.json' },
    @{ Root = (Join-Path $ProjectRoot 'src\headroom\codexpp-headroom'); Filter = 'headroom-activation-*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\logs'); Filter = '*' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = '*.log' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'gateway*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'headroom*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'monitor*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'route*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'startup*.json' },
    @{ Root = (Join-Path $ProjectRoot 'runtime-artifacts\state'); Filter = 'gate-*.json' },
    @{ Root = $projectRuntimeLogRoot; Filter = '*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'gateway-metrics-state.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'gateway-process-state.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'headroom-state*.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'headroom-start*.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'headroom-start-result.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'kompress-broker-state.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'kompress-broker-runtime.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'broker*.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'codexpp-route-state.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'codexpp-route-watch.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'codexpp-route-ready.signal'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'startup-result.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'managed-codex-processes.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'codexpp-headroom-monitor-state.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = 'codexpp-headroom-monitor-status.json'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.headroom-*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.gateway-*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.kompress-*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.codexpp-route-*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.startup-*'; Recurse = $true },
    @{ Root = $projectRuntimeStateRoot; Filter = '.managed-codex-*'; Recurse = $true },
    @{ Root = $tempRoot; Filter = 'codexpp-headroom-monitor.log' },
    @{ Root = $tempRoot; Filter = 'codexpp-manager-bootstrap.log' },
    @{ Root = $tempRoot; Filter = 'codexpp-wrapper-bootstrap.log' },
    @{ Root = $tempRoot; Filter = 'codexpp-bootstrap.log' }
) + @(
    foreach ($monitorRoot in $projectMonitorRoots) {
        @{ Root = $monitorRoot; Filter = '*.log'; Recurse = $true }
        @{ Root = $monitorRoot; Filter = 'codexpp-headroom-monitor-state.json'; Recurse = $true }
        @{ Root = $monitorRoot; Filter = 'codexpp-headroom-monitor-status.json'; Recurse = $true }
        @{ Root = $monitorRoot; Filter = 'stderr.log'; Recurse = $true }
        @{ Root = $monitorRoot; Filter = 'stdout.log'; Recurse = $true }
    }
)

$targets = @(
    foreach ($entry in $patterns) {
        if (-not (Test-Path -LiteralPath $entry.Root -PathType Container)) { continue }
        $getChildItem = @{
            LiteralPath = $entry.Root
            Filter = $entry.Filter
            File = $true
            Force = $true
            ErrorAction = 'SilentlyContinue'
        }
        if ($entry.Recurse) { $getChildItem.Recurse = $true }
        Get-ChildItem @getChildItem
    }
) | Where-Object {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw ('reparse_point_not_allowed: ' + $_.FullName)
    }
    if (-not (Test-AllowedPath -Path $_.FullName)) { return $false }
    if (Test-ProtectedPath -Path $_.FullName) {
        throw ('protected_path_matched: ' + $_.FullName)
    }
    return $true
} | Sort-Object FullName -Unique

function Write-Manifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
    [IO.File]::WriteAllText($manifestPath, (($Document | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

$fileEntries = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $hash = $null
    $hashError = $null
    try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    catch { $hashError = 'locked_or_unreadable' }
    [void]$fileEntries.Add([ordered]@{
        path = $file.FullName
        length = [int64]$file.Length
        sha256 = $hash
        read_error = $hashError
        backup_path = $null
        backup_sha256 = $null
        removed = $false
        remove_error = $null
    })
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
$manifestPath = Join-Path $ProjectRoot ('evidence\runtime-clear-' + $runId + '.json')
$backupRoot = if ($Execute) { Join-Path $ProjectRoot ('backups\runtime-clear-' + $runId) } else { $null }
$manifest = [ordered]@{
    schema_version = 2
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    execute = $Execute.IsPresent
    status = if ($Execute) { 'prepared' } else { 'dry-run' }
    backup_root = $backupRoot
    protected_roots = @($protectedRoots)
    allowlist = @($patterns | ForEach-Object {
        [ordered]@{ root = [IO.Path]::GetFullPath($_.Root); filter = $_.Filter; recurse = [bool]$_.Recurse }
    })
    files = @($fileEntries)
}

if (-not $Execute) {
    Write-Manifest -Document $manifest
    foreach ($file in $targets) {
        Write-Output ('would-remove: ' + $file.FullName)
    }
    Write-Output ('dry-run: ' + @($targets).Count + ' files; use -Execute after services are stopped')
    return
}

$unreadable = @($fileEntries | Where-Object { $_.read_error })
if ($unreadable.Count -gt 0) {
    $manifest.status = 'blocked_unreadable'
    $manifest.error = 'one_or_more_targets_locked_or_unreadable'
    Write-Manifest -Document $manifest
    throw ('cannot_backup_locked_targets: ' + ($unreadable.path -join ', '))
}

try {
    if (@($fileEntries).Count -gt 0) {
        New-Item -ItemType Directory -Path (Join-Path $backupRoot 'files') -Force | Out-Null
    }
    $backupIndex = 0
    foreach ($entry in $fileEntries) {
        $safePath = ($entry.path -replace '[:\\/]+', '_').Trim('_')
        if ($safePath.Length -gt 180) { $safePath = $safePath.Substring($safePath.Length - 180) }
        $backupName = ('{0:D4}-{1}' -f $backupIndex, $safePath)
        $entry.backup_path = Join-Path $backupRoot ('files\' + $backupName)
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.backup_path) -Force | Out-Null
        Copy-Item -LiteralPath $entry.path -Destination $entry.backup_path -Force -ErrorAction Stop
        $entry.backup_sha256 = (Get-FileHash -LiteralPath $entry.backup_path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($entry.backup_sha256 -ne $entry.sha256) {
            throw ('backup_hash_mismatch: ' + $entry.path)
        }
        $backupIndex++
    }
    $manifest.status = 'backed_up'
    Write-Manifest -Document $manifest
}
catch {
    $manifest.status = 'backup_failed'
    $manifest.error = $_.Exception.Message
    Write-Manifest -Document $manifest
    throw
}

$removeFailures = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $fileEntries) {
    if (-not $PSCmdlet.ShouldProcess($entry.path, 'Remove Headroom runtime log/state artifact')) {
        $entry.remove_error = 'should_process_skipped'
        continue
    }
    try {
        Remove-Item -LiteralPath $entry.path -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $entry.path -PathType Leaf) {
            throw 'target_still_exists_after_remove'
        }
        $entry.removed = $true
        Write-Output ('removed: ' + $entry.path)
    }
    catch {
        $entry.remove_error = $_.Exception.Message
        [void]$removeFailures.Add($entry.path)
    }
}

$manifest.removed_count = @($fileEntries | Where-Object { $_.removed }).Count
$manifest.remaining_paths = @($fileEntries | Where-Object { -not $_.removed } | ForEach-Object { $_.path })
if ($removeFailures.Count -gt 0) {
    $manifest.status = 'remove_failed'
    $manifest.error = 'one_or_more_targets_not_removed'
    Write-Manifest -Document $manifest
    throw ('remove_failed: ' + ($removeFailures -join ', '))
}

$manifest.status = if ($fileEntries.Count -eq 0) { 'completed_empty' } else { 'completed' }
$manifest.completed_at_utc = [DateTime]::UtcNow.ToString('o')
Write-Manifest -Document $manifest
