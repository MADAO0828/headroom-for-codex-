<##
.SYNOPSIS
    Small, read-only WinForms status window for the local Headroom/Codex++ path.

.PARAMETER NoShow
    Perform one bounded status check without creating a window. Intended for smoke tests.

.PARAMETER Once
    Perform one bounded status check and exit. The normal invocation keeps the window open.

.PARAMETER Probe
    Perform one bounded status check without acquiring the dashboard mutex. Used by the GUI runspace.

.PARAMETER ImportOnly
    Load dashboard functions without probing the monitor or creating UI. Used by offline contract tests.
##>
[CmdletBinding()]
param(
    [switch]$NoShow,
    [switch]$Once,
    [switch]$Probe,
    [switch]$ImportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UnifiedStatusUrl = 'http://127.0.0.1:18788/status'
$script:HttpTimeoutSeconds = 3
$script:TempRoot = [Environment]::GetEnvironmentVariable('TEMP')
if ([string]::IsNullOrWhiteSpace($script:TempRoot)) {
    $script:TempRoot = [IO.Path]::GetTempPath()
}
$script:DashboardLogPath = Join-Path $script:TempRoot 'codexpp-headroom-dashboard.log'
$script:MutexName = 'Local\CodexPlusPlusHeadroomDashboard'
$script:DashboardScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
$script:RowControls = @{}
$script:ProbePowerShell = $null
$script:ProbeRunspace = $null
$script:ProbeAsyncResult = $null
$script:ProbePollTimer = $null
$script:LastLoggedFingerprint = $null
$script:RecoveryAttempts = 0
$script:RecoveryPending = $false
$script:RefreshButton = $null
$script:StatusLabel = $null
$script:LastCheckLabel = $null
$script:DescriptionLabel = $null
$script:DashboardForm = $null
$script:RefreshTimer = $null

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { '未知' } else { [string]$Value }
    $text = $text -replace '[\r\n\t]+', ' '
    $text = $text -replace '(?i)sk-[A-Za-z0-9_-]{8,}', '<redacted>'
    if ($text.Length -gt 240) {
        return $text.Substring(0, 237) + '...'
    }
    return $text
}


function Write-DashboardLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    try {
        $parent = Split-Path -Parent $script:DashboardLogPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent -Force)
        }
        $line = "$(Get-Date -Format o) [$Level] $(ConvertTo-SafeText $Message)`r`n"
        [IO.File]::AppendAllText($script:DashboardLogPath, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # A status window must remain usable when its optional log is unavailable.
    }
}

function Get-SnapshotFingerprint {
    param([Parameter(Mandatory)][object]$Snapshot)

    $provided = Get-ObjectProperty -Object $Snapshot -Name 'Fingerprint'
    if (-not [string]::IsNullOrWhiteSpace([string]$provided)) {
        return [string]$provided
    }
    $unified = Get-ObjectProperty -Object $Snapshot -Name 'UnifiedStatus'
    $statusFingerprint = Get-ObjectProperty -Object (Get-ObjectProperty -Object $unified -Name 'metrics') -Name 'status_fingerprint'
    if (-not [string]::IsNullOrWhiteSpace([string]$statusFingerprint)) {
        return [string]$statusFingerprint
    }
    $parts = @([string]$Snapshot.OverallState)
    foreach ($row in @($Snapshot.Rows)) {
        $parts += @([string]$row.Key, [string]$row.State)
    }
    return ($parts -join '|')
}






function Get-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-UtcTimestamp {
    param([AllowNull()][object]$Value)

    $parsed = [DateTime]::MinValue
    if ($Value -is [DateTime]) {
        $parsed = [DateTime]$Value
        if ($parsed.Kind -eq [DateTimeKind]::Unspecified) {
            $parsed = [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
        }
    }
    else {
        try {
            $parsed = [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch {
            return $null
        }
    }
    return $parsed.ToUniversalTime()
}

function Get-ErrorFingerprint {
    param([AllowNull()][string]$Message)

    $text = [string]$Message
    if ($text -match '(?i)HTTP\s+(?<status>\d{3})') { return "transport|http-$($Matches.status)" }
    if ($text -match '过期') { return 'schema|stale' }
    if ($text -match '不兼容|schema|字段|item') { return 'schema|invalid' }
    if ($text -match '不可达|unreachable') { return 'transport|unreachable' }
    return 'transport|invalid'
}



function New-StatusRow {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][ValidateSet('Green', 'Red', 'Yellow', 'Gray')][string]$State,
        [Parameter(Mandatory)][string]$Detail,
        [AllowNull()][string]$BypassDetail
    )

    return [pscustomobject]@{
        Key = $Key
        Label = $Label
        State = $State
        Detail = (ConvertTo-SafeText $Detail)
        BypassDetail = if ([string]::IsNullOrWhiteSpace($BypassDetail)) { '' } else { ConvertTo-SafeText $BypassDetail }
    }
}

function New-ErrorSnapshot {
    param([string]$Message)

    $rows = @(
        (New-StatusRow -Key 'gateway-livez' -Label 'Gateway livez' -State Red -Detail $Message),
        (New-StatusRow -Key 'gateway-health' -Label 'Gateway health' -State Red -Detail $Message),
        (New-StatusRow -Key 'headroom-livez' -Label 'Headroom livez' -State Red -Detail $Message),
        (New-StatusRow -Key 'headroom-health' -Label 'Headroom health' -State Red -Detail $Message),
        (New-StatusRow -Key 'relay' -Label 'Relay' -State Red -Detail $Message),
        (New-StatusRow -Key 'route' -Label '客户端路由' -State Red -Detail $Message),
        (New-StatusRow -Key 'codex-connection' -Label 'Codex 连接' -State Red -Detail $Message),
        (New-StatusRow -Key 'api' -Label 'HTTP API' -State Red -Detail $Message),
        (New-StatusRow -Key 'transport' -Label '传输与错误' -State Red -Detail $Message),
        (New-StatusRow -Key 'kompress' -Label 'Kompress' -State Red -Detail $Message),
        (New-StatusRow -Key 'token-accounting' -Label 'Token accounting' -State Red -Detail $Message),
        (New-StatusRow -Key 'monitor-core' -Label 'Monitor core' -State Red -Detail $Message)
    )
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName Summary -NotePropertyValue '统一接口不可用' -Force
        $row | Add-Member -NotePropertyName ObservedAt -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    }
    return [pscustomobject]@{
        OverallState = 'Red'
        CheckedAt = (Get-Date).ToUniversalTime().ToString('o')
        Description = (ConvertTo-SafeText $Message)
        Rows = $rows
        Traffic = $null
        Fingerprint = Get-ErrorFingerprint -Message $Message
        UnifiedStatus = $null
    }
}











function Get-UnifiedStatusResponse {
    $handler = $null
    $client = $null
    $cancel = $null
    try {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $cancel = [Threading.CancellationTokenSource]::new()
        $cancel.CancelAfter([Math]::Max(1000, $script:HttpTimeoutSeconds * 1000))
        $task = $client.GetAsync($script:UnifiedStatusUrl, $cancel.Token)
        if (-not $task.Wait([Math]::Max(1500, ($script:HttpTimeoutSeconds * 1000) + 500))) {
            throw '统一监控接口请求超时'
        }
        $response = $task.GetAwaiter().GetResult()
        $bodyTask = $response.Content.ReadAsStringAsync()
        if (-not $bodyTask.Wait([Math]::Max(1500, ($script:HttpTimeoutSeconds * 1000) + 500))) {
            throw '统一监控接口响应读取超时'
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $bodyTask.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($null -ne $cancel) { $cancel.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
    }
}

function Get-DashboardSnapshot {
    try {
        $response = Get-UnifiedStatusResponse
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            return New-ErrorSnapshot -Message "统一监控接口 HTTP $([int]$response.StatusCode)"
        }
        $status = $response.Content | ConvertFrom-Json
        $required = @('schema_version', 'generated_at', 'stale_after_seconds', 'overall', 'items', 'metrics', 'active_issues', 'recent_recoveries')
        foreach ($name in $required) {
            if ($null -eq $status.PSObject.Properties[$name]) { return New-ErrorSnapshot -Message '监控数据不兼容' }
        }
        $expectedKeys = @('gateway-livez', 'gateway-health', 'headroom-livez', 'headroom-health', 'relay', 'route', 'codex-connection', 'api', 'transport', 'kompress', 'token-accounting', 'monitor-core')
        $itemRequired = @('key', 'label', 'state', 'summary', 'detail', 'observed_at', 'source')
        $validStates = @('green', 'yellow', 'red', 'gray')
        $items = @($status.items)
        $schemaVersionValid = $false
        if ($null -ne $status.schema_version -and $status.schema_version -is [ValueType] -and $status.schema_version -isnot [bool]) {
            try { $schemaVersionValid = ([double]$status.schema_version -eq 2) } catch { $schemaVersionValid = $false }
        }
        if (-not $schemaVersionValid -or $items.Count -ne $expectedKeys.Count -or [string]$status.overall -notin $validStates) {
            return New-ErrorSnapshot -Message '监控数据不兼容'
        }
        if ($null -eq $status.metrics -or $status.metrics -is [string] -or $status.metrics -is [System.Array] -or $status.active_issues -isnot [System.Array] -or $status.recent_recoveries -isnot [System.Array]) {
            return New-ErrorSnapshot -Message '监控数据不兼容'
        }
        $staleAfter = [double]0
        $staleAfterParsed = [double]::TryParse(([string]$status.stale_after_seconds).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$staleAfter)
        if (-not $staleAfterParsed -or [double]::IsNaN($staleAfter) -or [double]::IsInfinity($staleAfter) -or $staleAfter -lt 1 -or $staleAfter -gt 300) {
            return New-ErrorSnapshot -Message '监控数据不兼容'
        }
        $nowUtc = [DateTime]::UtcNow
        for ($i = 0; $i -lt $expectedKeys.Count; $i++) {
            $item = $items[$i]
            if ($null -eq $item -or $item -is [string]) { return New-ErrorSnapshot -Message '监控数据不兼容' }
            foreach ($name in $itemRequired) {
                if ($null -eq $item.PSObject.Properties[$name]) { return New-ErrorSnapshot -Message '监控数据不兼容' }
            }
            if ([string]$item.key -ne $expectedKeys[$i] -or [string]$item.state -notin $validStates) {
                return New-ErrorSnapshot -Message '监控数据不兼容'
            }
            $observedAt = ConvertTo-UtcTimestamp -Value $item.observed_at
            if ($null -eq $observedAt -or $observedAt -gt $nowUtc.AddSeconds(5)) {
                return New-ErrorSnapshot -Message '监控数据不兼容'
            }
        }
        $generatedAt = ConvertTo-UtcTimestamp -Value $status.generated_at
        if ($null -eq $generatedAt -or $generatedAt -gt $nowUtc.AddSeconds(5)) {
            return New-ErrorSnapshot -Message '监控数据不兼容'
        }
        $age = ($nowUtc - $generatedAt).TotalSeconds
        if ($age -gt $staleAfter) {
            return New-ErrorSnapshot -Message '统一监控接口已过期'
        }
        $statusFingerprintProperty = $status.metrics.PSObject.Properties['status_fingerprint']
        if ($null -ne $statusFingerprintProperty -and [string]$statusFingerprintProperty.Value -notmatch '^[0-9a-fA-F]{64}$') {
            return New-ErrorSnapshot -Message '监控数据不兼容'
        }
        $rows = @($status.items | ForEach-Object {
                $state = switch ([string]$_.state) {
                    'green' { 'Green'; break }
                    'red' { 'Red'; break }
                    'gray' { 'Gray'; break }
                    default { 'Yellow' }
                }
                $bypassDetail = [string](Get-ObjectProperty -Object $_ -Name 'bypass_detail')
                $row = New-StatusRow -Key ([string]$_.key) -Label ([string]$_.label) -State $state -Detail ([string]$_.detail) -BypassDetail $bypassDetail
                $row | Add-Member -NotePropertyName Summary -NotePropertyValue ([string]$_.summary) -Force
                $row | Add-Member -NotePropertyName ObservedAt -NotePropertyValue ([string]$_.observed_at) -Force
                $row
            })
        $overall = switch ([string]$status.overall) {
            'green' { 'Green'; break }
            'red' { 'Red'; break }
            'gray' { 'Gray'; break }
            default { 'Yellow' }
        }
        $active = @($status.active_issues | ForEach-Object { [string]$_.code })
        $description = if ($active.Count -gt 0) { "active_issues=$([string]::Join(',', $active))" } else { '统一监控未发现活动 issue' }
        $fingerprint = [string](Get-ObjectProperty -Object $status.metrics -Name 'status_fingerprint')
        if ([string]::IsNullOrWhiteSpace($fingerprint)) {
            $fingerprint = Get-SnapshotFingerprint -Snapshot ([pscustomobject]@{
                    OverallState = $overall
                    Rows = $rows
                    Fingerprint = $null
                    UnifiedStatus = $null
                })
        }
        return [pscustomobject]@{
            OverallState = $overall
            CheckedAt = [string]$status.generated_at
            Description = $description
            Rows = $rows
            Traffic = $status.metrics.traffic
            UnifiedStatus = $status
            Fingerprint = $fingerprint
        }
    }
    catch {
        Write-DashboardLog -Level ERROR -Message ("unified status check failed: " + $_.Exception.Message)
        return New-ErrorSnapshot -Message '统一监控接口不可达或响应无效'
    }
}

function Get-StateDisplay {
    param([string]$State)

    switch ($State) {
        'Green' { return '正常' }
        'Red' { return '故障' }
        'Yellow' { return '警告' }
        'Gray' { return '按策略延迟' }
        default { return '未知' }
    }
}

function Get-StateColor {
    param([string]$State)

    switch ($State) {
        'Green' { return [Drawing.Color]::FromArgb(0, 128, 0) }
        'Red' { return [Drawing.Color]::FromArgb(192, 0, 0) }
        'Yellow' { return [Drawing.Color]::FromArgb(184, 134, 11) }
        'Gray' { return [Drawing.Color]::FromArgb(128, 128, 128) }
        default { return [Drawing.Color]::DimGray }
    }
}

function Apply-Snapshot {
    param([Parameter(Mandatory)][object]$Snapshot)

    if ($null -eq $script:DashboardForm -or $script:DashboardForm.IsDisposed) {
        return
    }
    $script:StatusLabel.Text = "总状态：$(Get-StateDisplay $Snapshot.OverallState)"
    $script:StatusLabel.ForeColor = Get-StateColor $Snapshot.OverallState
    $script:LastCheckLabel.Text = "最后检查：$($Snapshot.CheckedAt)"
    $script:DescriptionLabel.Text = [string]$Snapshot.Description
    foreach ($row in @($Snapshot.Rows)) {
        if (-not $script:RowControls.ContainsKey([string]$row.Key)) {
            continue
        }
        $controls = $script:RowControls[[string]$row.Key]
        $controls.Dot.Text = '●'
        $controls.Dot.ForeColor = Get-StateColor ([string]$row.State)
        $summary = [string](Get-ObjectProperty -Object $row -Name 'Summary')
        $detail = [string]$row.Detail
        $bypassDetail = [string](Get-ObjectProperty -Object $row -Name 'BypassDetail')
        $observedAt = [string](Get-ObjectProperty -Object $row -Name 'ObservedAt')
        $detailText = if ([string]::IsNullOrWhiteSpace($bypassDetail)) { "$summary；$detail" } else { "$summary；$detail；$bypassDetail" }
        $controls.Detail.Text = if ([string]::IsNullOrWhiteSpace($observedAt)) { $detailText } else { "$detailText [$observedAt]" }
    }
    $fingerprint = Get-SnapshotFingerprint -Snapshot $Snapshot
    if ($fingerprint -ne $script:LastLoggedFingerprint) {
        Write-DashboardLog -Level INFO -Message ("overall=$($Snapshot.OverallState); $($Snapshot.Description)")
        $script:LastLoggedFingerprint = $fingerprint
    }
}

function Stop-ProbeResources {
    if ($null -ne $script:ProbePollTimer) {
        try { $script:ProbePollTimer.Stop() } catch { }
        try { $script:ProbePollTimer.Dispose() } catch { }
        $script:ProbePollTimer = $null
    }
    if ($null -ne $script:ProbePowerShell) {
        try {
            if ($null -ne $script:ProbeAsyncResult -and -not $script:ProbeAsyncResult.IsCompleted) {
                $script:ProbePowerShell.Stop()
            }
        }
        catch { }
        try { $script:ProbePowerShell.Dispose() } catch { }
        $script:ProbePowerShell = $null
    }
    if ($null -ne $script:ProbeRunspace) {
        try { $script:ProbeRunspace.Close() } catch { }
        try { $script:ProbeRunspace.Dispose() } catch { }
        $script:ProbeRunspace = $null
    }
    $script:ProbeAsyncResult = $null
}

function Complete-DashboardCheck {
    if ($null -eq $script:ProbeAsyncResult -or -not $script:ProbeAsyncResult.IsCompleted) {
        return
    }

    try {
        $output = @($script:ProbePowerShell.EndInvoke($script:ProbeAsyncResult) | ForEach-Object { [string]$_ })
        $json = ($output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw '探测没有返回状态。'
        }
        $snapshot = $json | ConvertFrom-Json
        Apply-Snapshot -Snapshot $snapshot
    }
    catch {
        Write-DashboardLog -Level ERROR -Message ("status probe failed: " + $_.Exception.Message)
        Apply-Snapshot -Snapshot (New-ErrorSnapshot -Message '状态检查线程失败。')
        if ($script:RecoveryAttempts -lt 1) {
            # A transient monitor restart gets one bounded retry.  Do not
            # create an unbounded dashboard/recovery loop on persistent 502s.
            $script:RecoveryAttempts++
            $script:RecoveryPending = $true
            Write-DashboardLog -Level WARN -Message 'status probe recovery scheduled (attempt 1 of 1).'
        }
    }
    finally {
        Stop-ProbeResources
        if ($null -ne $script:RefreshButton -and -not $script:RefreshButton.IsDisposed) {
            $script:RefreshButton.Enabled = $true
        }
    }
}

function Start-DashboardCheck {
    if ($null -eq $script:DashboardForm -or $script:DashboardForm.IsDisposed -or $null -ne $script:ProbeAsyncResult) {
        return
    }
    $script:RecoveryPending = $false
    $script:RefreshButton.Enabled = $false
    $script:StatusLabel.Text = '总状态：检查中...'
    $script:StatusLabel.ForeColor = [Drawing.Color]::DimGray

    try {
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $powershell = [Management.Automation.PowerShell]::Create()
        $powershell.Runspace = $runspace
        $quotedPath = "'" + $script:DashboardScriptPath.Replace("'", "''") + "'"
        [void]$powershell.AddScript("& $quotedPath -Probe")
        $script:ProbeRunspace = $runspace
        $script:ProbePowerShell = $powershell
        $script:ProbeAsyncResult = $powershell.BeginInvoke()

        if ($null -eq $script:ProbePollTimer) {
            $pollTimer = [Windows.Forms.Timer]::new()
            $pollTimer.Interval = 100
            $pollTimer.Add_Tick({ Complete-DashboardCheck })
            $script:ProbePollTimer = $pollTimer
        }
        $script:ProbePollTimer.Start()
    }
    catch {
        Write-DashboardLog -Level ERROR -Message ("status probe startup failed: " + $_.Exception.Message)
        Stop-ProbeResources
        Apply-Snapshot -Snapshot (New-ErrorSnapshot -Message '状态检查线程启动失败。')
        $script:RefreshButton.Enabled = $true
    }
}

$mutex = $null
$mutexHeld = $false
try {
    if ($ImportOnly) { return }

    if ($Probe) {
        $snapshot = Get-DashboardSnapshot
        $snapshot | ConvertTo-Json -Depth 6 -Compress
        return
    }

    $mutex = [Threading.Mutex]::new($false, $script:MutexName)
    $mutexHeld = $mutex.WaitOne(0)
    if (-not $mutexHeld) {
        Write-DashboardLog -Level WARN -Message 'Another dashboard instance owns the mutex; this invocation is busy.'
        if ($Probe -or $NoShow -or $Once) { exit 2 }
        return
    }

    if ($NoShow -or $Once) {
        $snapshot = Get-DashboardSnapshot
        $snapshot | ConvertTo-Json -Depth 6 -Compress
        Write-DashboardLog -Level INFO -Message ("one-shot overall=$($snapshot.OverallState); $($snapshot.Description)")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $form = [Windows.Forms.Form]::new()
    $script:DashboardForm = $form
    $form.Text = 'Headroom 状态监视器'
    $form.ClientSize = [Drawing.Size]::new(440, 580)
    $form.MinimumSize = [Drawing.Size]::new(440, 580)
    $form.MaximumSize = [Drawing.Size]::new(440, 580)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true

    $statusLabel = [Windows.Forms.Label]::new()
    $script:StatusLabel = $statusLabel
    $statusLabel.Location = [Drawing.Point]::new(12, 10)
    $statusLabel.Size = [Drawing.Size]::new(416, 26)
    $statusLabel.Font = [Drawing.Font]::new('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
    $statusLabel.Text = '总状态：检查中...'
    $statusLabel.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($statusLabel)

    $lastCheckLabel = [Windows.Forms.Label]::new()
    $script:LastCheckLabel = $lastCheckLabel
    $lastCheckLabel.Location = [Drawing.Point]::new(12, 40)
    $lastCheckLabel.Size = [Drawing.Size]::new(416, 20)
    $lastCheckLabel.Text = '最后检查：等待中'
    $form.Controls.Add($lastCheckLabel)

    $descriptionLabel = [Windows.Forms.Label]::new()
    $script:DescriptionLabel = $descriptionLabel
    $descriptionLabel.Location = [Drawing.Point]::new(12, 62)
    $descriptionLabel.Size = [Drawing.Size]::new(416, 22)
    $descriptionLabel.AutoEllipsis = $true
    $descriptionLabel.Text = '正在读取本机 Headroom 状态...'
    $form.Controls.Add($descriptionLabel)

    $table = [Windows.Forms.TableLayoutPanel]::new()
    $table.Location = [Drawing.Point]::new(12, 92)
    $table.Size = [Drawing.Size]::new(416, 400)
    $table.ColumnCount = 3
    $table.RowCount = 12
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 30))
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 154))
    [void]$table.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    for ($i = 0; $i -lt 12; $i++) {
        [void]$table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 33))
    }
    $initialRows = @(
        @{ Key = 'gateway-livez'; Label = 'Gateway livez' },
        @{ Key = 'gateway-health'; Label = 'Gateway health' },
        @{ Key = 'headroom-livez'; Label = 'Headroom livez' },
        @{ Key = 'headroom-health'; Label = 'Headroom health' },
        @{ Key = 'relay'; Label = 'Relay' },
        @{ Key = 'route'; Label = '客户端路由' },
        @{ Key = 'codex-connection'; Label = 'Codex 连接' },
        @{ Key = 'api'; Label = 'HTTP API' },
        @{ Key = 'transport'; Label = '传输与错误' },
        @{ Key = 'kompress'; Label = 'Kompress' },
        @{ Key = 'token-accounting'; Label = 'Token accounting' },
        @{ Key = 'monitor-core'; Label = 'Monitor core' }
    )
    foreach ($item in $initialRows) {
        $dot = [Windows.Forms.Label]::new()
        $dot.Text = '●'
        $dot.Font = [Drawing.Font]::new('Segoe UI Symbol', 12, [Drawing.FontStyle]::Regular)
        $dot.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
        $dot.Dock = [Windows.Forms.DockStyle]::Fill
        $dot.ForeColor = [Drawing.Color]::DimGray
        $name = [Windows.Forms.Label]::new()
        $name.Text = $item.Label
        $name.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $name.Dock = [Windows.Forms.DockStyle]::Fill
        $detail = [Windows.Forms.Label]::new()
        $detail.Text = '检查中...'
        $detail.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $detail.Dock = [Windows.Forms.DockStyle]::Fill
        [void]$table.Controls.Add($dot)
        [void]$table.Controls.Add($name)
        [void]$table.Controls.Add($detail)
        $script:RowControls[$item.Key] = @{ Dot = $dot; Detail = $detail }
    }
    $form.Controls.Add($table)

    $refreshButton = [Windows.Forms.Button]::new()
    $script:RefreshButton = $refreshButton
    $refreshButton.Text = '立即刷新'
    $refreshButton.Location = [Drawing.Point]::new(250, 510)
    $refreshButton.Size = [Drawing.Size]::new(84, 28)
    $refreshButton.Add_Click({ Start-DashboardCheck })
    $form.Controls.Add($refreshButton)

    $exitButton = [Windows.Forms.Button]::new()
    $exitButton.Text = '退出窗口'
    $exitButton.Location = [Drawing.Point]::new(344, 510)
    $exitButton.Size = [Drawing.Size]::new(84, 28)
    $exitButton.Add_Click({ $script:DashboardForm.Close() })
    $form.Controls.Add($exitButton)
    $form.AcceptButton = $refreshButton
    $form.CancelButton = $exitButton

    $timer = [Windows.Forms.Timer]::new()
    $script:RefreshTimer = $timer
    $timer.Interval = 3000
    $timer.Add_Tick({ Start-DashboardCheck })
    $timer.Start()
    $form.Add_Shown({ Start-DashboardCheck })
    $form.Add_FormClosed({
        if ($null -ne $script:RefreshTimer) {
            $script:RefreshTimer.Stop()
            $script:RefreshTimer.Dispose()
        }
        Stop-ProbeResources
    })

    # Explicitly show the form so a hidden PowerShell console does not hide the dashboard window.
    $form.Show()
    [Windows.Forms.Application]::Run($form)
}
catch {
    Write-DashboardLog -Level ERROR -Message ("dashboard startup failed: " + $_.Exception.Message)
    if ($NoShow -or $Once) {
        Write-Output 'dashboard startup failed'
    }
}
finally {
    if ($mutexHeld -and $null -ne $mutex) {
        try { [void]$mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
