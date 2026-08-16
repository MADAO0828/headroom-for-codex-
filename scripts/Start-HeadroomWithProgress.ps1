[CmdletBinding()]
param(
    [ValidateSet(1, 2)]
    [int]$Workers = 1,
    [switch]$PhaseB,
    [ValidateRange(15, 600)]
    [int]$ReadinessTimeoutSeconds = 120,
    [ValidateRange(30, 900)]
    [int]$OverallTimeoutSeconds = 420,
    [ValidateRange(0, 30)]
    [int]$SuccessDisplaySeconds = 3,
    [switch]$NoPauseOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$startScript = Join-Path $projectRoot 'scripts\Start-HeadroomForCodexPP.ps1'
$runtimeRoot = Join-Path $projectRoot 'runtime'
$stateRoot = Join-Path $runtimeRoot 'state'
$logRoot = Join-Path $runtimeRoot 'logs'
$resultPath = Join-Path $stateRoot 'headroom-start-result.json'
$routeStatePath = Join-Path $stateRoot 'codexpp-route-state.json'
$routeWatchStatePath = Join-Path $stateRoot 'codexpp-route-watch.json'
$timingPath = Join-Path $logRoot 'startup-timing.log'
$runId = [Guid]::NewGuid().ToString('N')
$childStdoutPath = Join-Path $logRoot ("visible-launch-$runId.stdout.log")
$childStderrPath = Join-Path $logRoot ("visible-launch-$runId.stderr.log")
$launchStartedUtc = [DateTime]::UtcNow
$oldResultHash = $null
$oldResultWriteUtc = $null

foreach ($directory in @($stateRoot, $logRoot)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

function Get-FileHashOrNull {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() }
    catch { return $null }
}

function Read-JsonOrNull {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Test-LoopbackPort {
    param([Parameter(Mandatory)][int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait([TimeSpan]::FromMilliseconds(250))) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Test-HttpReady {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 2 -UseBasicParsing
        return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
    }
    catch { return $false }
}

function Test-RouteStateReady {
    $state = Read-JsonOrNull -Path $routeStatePath
    $watch = Read-JsonOrNull -Path $routeWatchStatePath
    if ($null -eq $state -or $null -eq $watch) { return $false }
    # route-watch schema v2 has no `status` field; route-state is the source
    # of truth for readiness.  Reading a missing property under StrictMode
    # would throw and swallow the whole startup result, so probe it safely.
    $watchStatus = $null
    $watchStatusProp = $watch.PSObject.Properties['status']
    if ($null -ne $watchStatusProp) { $watchStatus = [string]$watchStatusProp.Value }
    $watchReady = $null -eq $watchStatus -or $watchStatus -in @('ready', 'running', 'healthy', '')
    return ([string]$state.status -eq 'ready' -and
        [string]$state.route_scope -eq 'process' -and
        [bool]$state.config_mutated -eq $false -and
        $watchReady)
}

function Get-ProgressState {
    $stage = 0
    $label = '启动 Headroom 子进程'
    $detail = '正在创建受管启动进程'

    if ($null -ne $script:child -and -not $script:child.HasExited) {
        $stage = 1
        $label = '等待 Kompress broker (18790)'
        $detail = 'broker 尚未 ready'
    }
    if (Test-LoopbackPort -Port 18790) {
        $stage = 2
        $label = '等待 Headroom proxy (18789)'
        $detail = 'Kompress broker 已监听'
    }
    if ((Test-LoopbackPort -Port 18789) -and (Test-HttpReady -Uri 'http://127.0.0.1:18789/livez')) {
        $stage = 3
        $label = '等待 Policy Gateway (18787)'
        $detail = 'Headroom livez 已通过'
    }
    if (Test-LoopbackPort -Port 18787) {
        $stage = 4
        $label = '等待状态监视器 (18788)'
        $detail = 'Gateway 已监听'
    }
    if (Test-LoopbackPort -Port 18788) {
        $stage = 5
        $label = '等待 route-state / route watcher'
        $detail = 'monitor 已监听'
    }
    if (Test-RouteStateReady) {
        $stage = 6
        $label = '等待 Relay / Manager / Client'
        $detail = '进程级 route-state 已 ready'
    }
    if ((Test-LoopbackPort -Port 57321) -and (Test-LoopbackPort -Port 57865)) {
        $stage = 7
        $label = '等待最终启动收据'
        $detail = 'Relay 与 Manager helper 已监听'
    }
    return [pscustomobject]@{ stage = $stage; label = $label; detail = $detail }
}

function Get-ProgressBar {
    param([Parameter(Mandatory)][int]$Stage)
    $width = 28
    $maxStage = 8
    $filled = [Math]::Min($width, [Math]::Max(0, [Math]::Floor(($Stage / $maxStage) * $width)))
    return ('#' * $filled) + ('.' * ($width - $filled))
}

function Show-Progress {
    param(
        [Parameter(Mandatory)][int]$Stage,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [Parameter(Mandatory)][int]$SpinnerIndex
    )
    $percent = [Math]::Min(99, [Math]::Max(0, [Math]::Floor(($Stage / 8) * 100)))
    $spinner = @('|', '/', '-', '\')[$SpinnerIndex % 4]
    $bar = Get-ProgressBar -Stage $Stage
    $line = "`r[$bar] {0,3}% {1} {2} ({3}s)" -f $percent, $spinner, $Label, [Math]::Round($ElapsedSeconds, 1)
    Write-Host ($line + ' ' * 8) -NoNewline
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host ("`n    $Detail")
    }
}

function Read-FreshStartResult {
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $resultPath -Force
    $hash = Get-FileHashOrNull -Path $resultPath
    $freshByTime = $item.LastWriteTimeUtc -ge $launchStartedUtc.AddSeconds(-2) -and
        ($null -eq $oldResultWriteUtc -or $item.LastWriteTimeUtc -gt $oldResultWriteUtc)
    $freshByHash = ($null -ne $hash -and $hash -ne $oldResultHash)
    if (-not ($freshByTime -or $freshByHash)) { return $null }
    return Read-JsonOrNull -Path $resultPath
}

function Write-ChildOutput {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Threading.Tasks.Task[string]]$Task)
    try {
        $text = $Task.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    }
    catch { }
}

if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    Write-Host "Headroom 启动脚本不存在：$startScript" -ForegroundColor Red
    if (-not $NoPauseOnFailure) { [void](Read-Host '按 Enter 关闭此窗口') }
    exit 1
}

$oldResultHash = Get-FileHashOrNull -Path $resultPath
if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    try { $oldResultWriteUtc = (Get-Item -LiteralPath $resultPath -Force).LastWriteTimeUtc } catch { }
}

Write-Host 'Headroom for Codex++ 可见启动器' -ForegroundColor Cyan
Write-Host "项目根目录: $projectRoot"
Write-Host "运行编号: $runId"
Write-Host '正在启动，服务子进程保持隐藏；本窗口显示启动阶段和失败原因。'

$pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $pwshCommand) {
    Write-Host '找不到 PowerShell 7 (pwsh.exe)。' -ForegroundColor Red
    if (-not $NoPauseOnFailure) { [void](Read-Host '按 Enter 关闭此窗口') }
    exit 1
}

$child = $null
$script:child = $null
$stdoutTask = $null
$stderrTask = $null
$exitCode = $null
$lastStage = -1
$spinnerIndex = 0
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

try {
    $childArgs = [Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $startScript, '-Workers', $Workers.ToString(), '-ReadinessTimeoutSeconds', $ReadinessTimeoutSeconds.ToString())) {
        [void]$childArgs.Add($arg)
    }
    if ($PhaseB) { [void]$childArgs.Add('-PhaseB') }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshCommand.Source
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($arg in $childArgs) { [void]$startInfo.ArgumentList.Add($arg) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $startInfo
    if (-not $child.Start()) { throw 'visible_launcher_child_start_failed' }
    $script:child = $child
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()

    $deadline = $launchStartedUtc.AddSeconds($OverallTimeoutSeconds)
    while (-not $child.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $progress = $null
        try {
            $progress = Get-ProgressState
        }
        catch {
            # Probe failures must degrade to "probe unavailable", never
            # swallow the launch result or terminate the progress loop.
            $progress = [pscustomobject]@{ stage = $lastStage; label = '启动中（进度探针暂不可用）'; detail = ($_.Exception.Message -replace '[\r\n]+', ' ') }
        }
        if ($progress.stage -ne $lastStage) {
            if ($lastStage -ge 0) { Write-Host '' }
            Write-Host ("[{0}s] {1}" -f [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1), $progress.label) -ForegroundColor Yellow
            Write-Host "    $($progress.detail)"
            $lastStage = $progress.stage
        }
        Show-Progress -Stage $progress.stage -Label $progress.label -Detail '' -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds -SpinnerIndex $spinnerIndex
        $spinnerIndex++
        Start-Sleep -Milliseconds 500
        $child.Refresh()
    }

    if (-not $child.HasExited) {
        Write-Host "`n启动总预算 $OverallTimeoutSeconds 秒已用尽；未强制终止子启动进程。" -ForegroundColor Red
        Write-Host '请查看下面的收据和日志；子进程可能仍在完成最后的 readiness 检查。'
        $exitCode = $null
    }
    else {
        $exitCode = $child.ExitCode
    }
}
catch {
    Write-Host "`n可见启动器异常：$($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($null -ne $child) {
        try { $child.Refresh() } catch { }
        if ($child.HasExited) {
            if ($null -ne $stdoutTask) { Write-ChildOutput -Path $childStdoutPath -Task $stdoutTask }
            if ($null -ne $stderrTask) { Write-ChildOutput -Path $childStderrPath -Task $stderrTask }
            $child.Dispose()
        }
    }
}

$result = Read-FreshStartResult
if ($null -ne $result -and [string]$result.status -eq 'succeeded' -and $exitCode -eq 0) {
    Write-Host "`n[$('#' * 28)] 100% 启动成功" -ForegroundColor Green
    Write-Host "阶段: $($result.stage)"
    Write-Host "收据: $resultPath"
    Write-Host "耗时: $([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) 秒"
    if ($SuccessDisplaySeconds -gt 0) { Start-Sleep -Seconds $SuccessDisplaySeconds }
    exit 0
}

Write-Host "`n启动未完成或失败。" -ForegroundColor Red
if ($null -ne $result) {
    Write-Host "status=$($result.status); stage=$($result.stage); error_code=$($result.error_code)"
    if (-not [string]::IsNullOrWhiteSpace([string]$result.detail)) { Write-Host "detail=$($result.detail)" }
}
else {
    Write-Host "本次未生成新的 headroom-start-result.json；child_exit_code=$exitCode"
}
Write-Host "收据: $resultPath"
Write-Host "子进程 stdout: $childStdoutPath"
Write-Host "子进程 stderr: $childStderrPath"
Write-Host "阶段日志: $timingPath"
if (-not $NoPauseOnFailure) { [void](Read-Host '按 Enter 关闭此窗口') }
exit 1
