[CmdletBinding()]
param(
    [ValidateSet(1, 2)]
    [int]$Workers = 1,
    [switch]$ServicesOnly,
    [int]$ReadinessTimeoutSeconds = 120,
    [ValidateRange(1024, 65535)]
    [int]$BrokerPort = 18790
)

$ErrorActionPreference = 'Stop'

if (-not ('HeadroomProcessPathProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HeadroomProcessPathProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(
        IntPtr process,
        uint flags,
        StringBuilder executablePath,
        ref uint size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static string Read(int processId)
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)processId);
        if (handle == IntPtr.Zero) return String.Empty;
        try
        {
            uint size = 32768;
            var executablePath = new StringBuilder((int)size);
            return QueryFullProcessImageName(handle, 0, executablePath, ref size)
                ? executablePath.ToString()
                : String.Empty;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
# The repository is the single source of truth for the managed proxy.  The
# external Codex++ bootstrap remains an integration point, but Headroom and
# Gateway code/state must not silently come from an older user-cache copy.
$runtimeHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom'
$runtimeCodexSource = Join-Path $projectRoot 'src\codexpp\Codex++'
$runtimeRoot = Join-Path $projectRoot 'runtime'
$runtimeStateRoot = Join-Path $runtimeRoot 'state'
$runtimeLogRoot = Join-Path $runtimeRoot 'logs'
$runtimeCacheRoot = Join-Path $runtimeRoot 'cache'
$runtimePrivateRoot = Join-Path $runtimeRoot 'private'
$runtimePythonRoot = Join-Path $runtimeRoot 'python'
$ensureScript = Join-Path $runtimeHeadroom 'ensure-headroom.ps1'
$startupGate = Join-Path $runtimeCodexSource 'codexpp-startup-gate.ps1'
$managerBootstrap = Join-Path $runtimeCodexSource 'codex-manager-bootstrap.vbs'
$clientBootstrap = Join-Path $runtimeCodexSource 'codex-wrapper-bootstrap.vbs'
$managerExe = 'D:\program\Codex++\codex-plus-plus-manager.exe'
$clientExe = 'D:\program\Codex++\codex-plus-plus.exe'
$managerCodexHome = 'C:\Users\ma dao\.codex-plus-plus-cli'
$managerConfig = Join-Path $managerCodexHome 'config.toml'
$routeKeeper = Join-Path $runtimeCodexSource 'codexpp-route-keeper.ps1'
$monitorScript = Join-Path $projectRoot 'src\codexpp\Codex++\codexpp-headroom-monitor.ps1'
$resultPath = Join-Path $runtimeStateRoot 'headroom-start-result.json'
$brokerModuleRoot = Join-Path $projectRoot 'src'
$brokerPython = Join-Path $runtimePythonRoot 'Scripts\python.exe'
$brokerStatePath = Join-Path $runtimeStateRoot 'kompress-broker-state.json'
$brokerRuntimeStatePath = Join-Path $runtimeStateRoot 'kompress-broker-runtime.json'
$brokerLogRoot = $runtimeLogRoot
$routeStatePath = Join-Path $runtimeStateRoot 'codexpp-route-state.json'
$routeWatchStatePath = Join-Path $runtimeStateRoot 'codexpp-route-watch.json'
$routeReadySignalPath = Join-Path $runtimeStateRoot 'codexpp-route-ready.signal'
$startupResultPath = Join-Path $runtimeStateRoot 'startup-result.json'
$managedCodexStatePath = Join-Path $runtimeStateRoot 'managed-codex-processes.json'
$monitorStatePath = Join-Path $runtimeStateRoot 'codexpp-headroom-monitor-state.json'
$monitorStatusStatePath = Join-Path $runtimeStateRoot 'codexpp-headroom-monitor-status.json'
$gatewayUrl = 'http://127.0.0.1:18787'
$headroomUrl = 'http://127.0.0.1:18789'
$monitorUrl = 'http://127.0.0.1:18788'
$brokerUrl = "http://127.0.0.1:$BrokerPort"
$startMutex = [Threading.Mutex]::new($false, 'Local\HeadroomForCodexPP.Start')
$startMutexHeld = $false
$previousKompressEndpoint = [Environment]::GetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', 'Process')
$sourceHashesBefore = @{}
$managerConfigHashBefore = ''

foreach ($requiredDirectory in @($runtimeRoot, $runtimeStateRoot, $runtimeLogRoot, $runtimeCacheRoot, $runtimePrivateRoot)) {
    [IO.Directory]::CreateDirectory($requiredDirectory) | Out-Null
}

function Write-StartResult {
    param(
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorCode,
        [string]$Detail = ''
    )

    $document = [ordered]@{
        schema_version = 1
        status = $Status
        stage = $Stage
        error_code = $ErrorCode
        detail = ($Detail -replace '[\r\n\t]+', ' ').Substring(0, [Math]::Min(500, ($Detail -replace '[\r\n\t]+', ' ').Length))
        workers = $Workers
        gateway_url = $gatewayUrl
        headroom_url = $headroomUrl
        monitor_url = $monitorUrl
        broker_url = $brokerUrl
        broker_port = $BrokerPort
        broker_module_hash = if ($sourceHashesBefore.ContainsKey('broker')) { $sourceHashesBefore['broker'] } else { '' }
        config_sha256 = if (Test-Path -LiteralPath $managerConfig -PathType Leaf) { try { (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash } catch { '' } } else { '' }
        route_state_path = $routeStatePath
        project_root = $projectRoot
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $parent = Split-Path -Parent $resultPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.headroom-start-result-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $resultPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ListenerPid {
    param([Parameter(Mandatory)][int]$Port)
    $connections = @(Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue)
    $pids = @($connections | ForEach-Object { [int]$_.OwningProcess } | Select-Object -Unique)
    if ($pids.Count -gt 1) { throw "multiple_listeners:$Port" }
    if ($pids.Count -eq 0) { return $null }
    return [int]$pids[0]
}

function Get-ProcessCommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $snapshot) { return '' }
        return [string]$snapshot.CommandLine
    }
    catch { return '' }
}

function Get-ProcessExecutablePath {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        $cimPath = if ($null -eq $snapshot) { '' } else { [string]$snapshot.ExecutablePath }
        if (-not [string]::IsNullOrWhiteSpace($cimPath)) { return $cimPath }
    }
    catch { }
    try { return [string][HeadroomProcessPathProbe]::Read($ProcessId) } catch { return '' }
}

function Get-ModuleHash {
    param([Parameter(Mandatory)][string[]]$Paths)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in ($Paths | Sort-Object)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        [void]$parts.Add(([IO.Path]::GetFullPath($path).ToLowerInvariant() + ':' + $hash))
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($parts -join "`n"))
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes))).Replace('-', '')
}

function Get-ManagedSourceHashes {
    $hashes = @{}
    $hashes['startup_gate'] = Get-ModuleHash -Paths @($startupGate)
    $hashes['route_keeper'] = Get-ModuleHash -Paths @($routeKeeper)
    $hashes['monitor'] = Get-ModuleHash -Paths @($monitorScript)
    $hashes['gateway'] = Get-ModuleHash -Paths @((Join-Path $runtimeHeadroom 'gateway.py'))
    $hashes['broker'] = Get-ModuleHash -Paths @(
        (Join-Path $brokerModuleRoot 'kompress_broker\app.py'),
        (Join-Path $brokerModuleRoot 'kompress_broker\worker.py')
    )
    foreach ($key in $hashes.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$hashes[$key])) { throw "source_hash_missing:$key" }
    }
    return $hashes
}

function Test-SourceHashesUnchanged {
    param([Parameter(Mandatory)][hashtable]$Expected)
    $actual = Get-ManagedSourceHashes
    foreach ($key in $Expected.Keys) {
        if (-not $actual.ContainsKey($key) -or $actual[$key] -ne $Expected[$key]) { return $false }
    }
    return $true
}

function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 15
        $body = $null
        try { if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) { $body = $response.Content | ConvertFrom-Json } } catch { }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $body; TransportOk = $true }
    }
    catch {
        return [pscustomobject]@{ StatusCode = 0; Body = $null; TransportOk = $false }
    }
}

function Get-PropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-GatewayReadinessSnapshot {
    param(
        [Parameter(Mandatory)][object]$Live,
        [Parameter(Mandatory)][object]$Health,
        [switch]$AllowRelayPending
    )

    $liveReady = $Live.TransportOk -and $Live.StatusCode -eq 200 -and $null -ne $Live.Body -and (Get-PropertyValue -Object $Live.Body -Name 'alive') -eq $true
    $healthReady = $Health.TransportOk -and $Health.StatusCode -eq 200 -and $null -ne $Health.Body -and (Get-PropertyValue -Object $Health.Body -Name 'ready') -eq $true
    if ($liveReady -and $healthReady) { return $true }
    if (-not $AllowRelayPending -or -not $liveReady) { return $false }

    # Before Manager/client launch, a live Gateway may report only the
    # expected missing helper dependency.  Accept that exact degraded
    # snapshot, never an arbitrary 503 or a reachable-but-unhealthy helper.
    $checks = Get-PropertyValue -Object $Health.Body -Name 'checks'
    $headroom = Get-PropertyValue -Object $checks -Name 'headroom'
    $helper = Get-PropertyValue -Object $checks -Name 'helper'
    return (
        $Health.TransportOk -and $Health.StatusCode -eq 503 -and $null -ne $Health.Body -and
        [string](Get-PropertyValue -Object $Health.Body -Name 'service') -eq 'policy-gateway' -and
        [string](Get-PropertyValue -Object $Health.Body -Name 'status') -eq 'degraded' -and
        (Get-PropertyValue -Object $Health.Body -Name 'ready') -eq $false -and
        (Get-PropertyValue -Object $headroom -Name 'ok') -eq $true -and
        (Get-PropertyValue -Object $helper -Name 'ok') -eq $false -and
        $null -eq (Get-PropertyValue -Object $helper -Name 'status_code')
    )
}

function Write-BrokerState {
    param([Parameter(Mandatory)][int]$ProcessId)
    $directory = Split-Path -Parent $brokerStatePath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $document = [ordered]@{
        schema_version = 1
        service = 'kompress-broker'
        state_role = 'managed-process-identity'
        pid = $ProcessId
        port = $BrokerPort
        executable_path = (Get-ProcessExecutablePath -ProcessId $ProcessId)
        invocation_path = [IO.Path]::GetFullPath($brokerPython)
        command_line = (Get-ProcessCommandLine -ProcessId $ProcessId)
        module = 'kompress_broker.app:app'
        module_hash = [string]$sourceHashesBefore['broker']
        endpoint = $brokerUrl
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $temp = Join-Path $directory ('.kompress-broker-state-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $brokerStatePath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BrokerState {
    if (-not (Test-Path -LiteralPath $brokerStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $brokerStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-ManagedBrokerIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    $state = Get-BrokerState
    if ($null -eq $state) { return $false }
    if ([int]$state.port -ne $BrokerPort -or [int]$state.pid -ne $ProcessId) { return $false }
    if ([string]$state.module -ne 'kompress_broker.app:app' -or [string]$state.module_hash -ne [string]$sourceHashesBefore['broker']) { return $false }
    $commandLine = Get-ProcessCommandLine -ProcessId $ProcessId
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    $expectedInvocation = [IO.Path]::GetFullPath($brokerPython)
    $quotedInvocation = '"' + $expectedInvocation + '"'
    if (-not [string]::Equals([string]$state.invocation_path, $expectedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not $commandLine.StartsWith($quotedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $actualExecutable = Get-ProcessExecutablePath -ProcessId $ProcessId
    if (-not [string]::Equals([string]$state.executable_path, $actualExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $commandLine -match '(?i)kompress_broker\.app:app' -and $commandLine -match ('(?i)--port\s+' + [regex]::Escape($BrokerPort.ToString()))
}

function Test-BrokerProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    $commandLine = Get-ProcessCommandLine -ProcessId $ProcessId
    $executablePath = Get-ProcessExecutablePath -ProcessId $ProcessId
    if ([string]::IsNullOrWhiteSpace($commandLine) -or [string]::IsNullOrWhiteSpace($executablePath)) { return $false }
    $expectedPython = [IO.Path]::GetFullPath($brokerPython)
    try { $actualPython = [IO.Path]::GetFullPath($executablePath) } catch { return $false }
    $quotedInvocation = '"' + $expectedPython + '"'
    if (-not $commandLine.StartsWith($quotedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $parentPath = ''
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $snapshot) { $parentPath = Get-ProcessExecutablePath -ProcessId ([int]$snapshot.ParentProcessId) }
    }
    catch { }
    $executableMatches = [string]::Equals($actualPython, $expectedPython, [StringComparison]::OrdinalIgnoreCase)
    $parentMatches = -not [string]::IsNullOrWhiteSpace($parentPath) -and [string]::Equals([IO.Path]::GetFullPath($parentPath), $expectedPython, [StringComparison]::OrdinalIgnoreCase)
    return (
        ($executableMatches -or $parentMatches) -and
        $commandLine -match '(?i)kompress_broker\.app:app' -and
        $commandLine -match ('(?i)--port\s+' + [regex]::Escape($BrokerPort.ToString())) -and
        $commandLine.Replace('/', '\').IndexOf($projectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Stop-ManagedProcessGracefully {
    param([Parameter(Mandatory)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    try {
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(3000)) {
                Stop-Process -Id $ProcessId -Force -ErrorAction Stop
                [void]$process.WaitForExit(3000)
            }
        }
        return $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}

function Get-MonitorState {
    if (-not (Test-Path -LiteralPath $monitorStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $monitorStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-ProjectMonitorCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $normalized = $CommandLine.Replace('/', '\')
    $expected = [IO.Path]::GetFullPath($monitorScript).Replace('/', '\')
    if ($normalized.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    return $normalized -match '(?i)(?:^|\s)-File(?:\s|$)'
}

function Get-ProjectMonitorProcesses {
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $executablePath = [string]$snapshot.ExecutablePath
        $commandLine = [string]$snapshot.CommandLine
        if ([string]::IsNullOrWhiteSpace($executablePath) -or [IO.Path]::GetFileName($executablePath) -notin @('pwsh.exe', 'powershell.exe')) { continue }
        if (Test-ProjectMonitorCommandLine -CommandLine $commandLine) { [void]$matches.Add($snapshot) }
    }
    return @($matches)
}

function Test-ManagedMonitorIdentity {
    $state = Get-MonitorState
    if ($null -eq $state -or [int]$state.schema_version -ne 2) { return $false }
    try { $expectedMonitorSourceSha256 = (Get-FileHash -LiteralPath $monitorScript -Algorithm SHA256).Hash.ToUpperInvariant() } catch { return $false }
    $processId = 0
    if (-not [int]::TryParse([string]$state.monitor_pid, [ref]$processId) -or $processId -le 0) { return $false }
    try {
        $stateScriptPath = [IO.Path]::GetFullPath([string]$state.monitor_script_path)
        $stateRuntimeRoot = [IO.Path]::GetFullPath([string]$state.runtime_root)
    }
    catch { return $false }
    if (-not [string]::Equals($stateScriptPath, [IO.Path]::GetFullPath($monitorScript), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals($stateRuntimeRoot, [IO.Path]::GetFullPath($runtimeRoot), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([string]$state.monitor_source_sha256 -ne $expectedMonitorSourceSha256 -or [string]$state.monitor_mode -ne 'watch') { return $false }

    $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $snapshot -or -not (Test-ProjectMonitorCommandLine -CommandLine ([string]$snapshot.CommandLine))) { return $false }
    $normalizedCommandLine = ([string]$snapshot.CommandLine).Replace('/', '\')
    if ($normalizedCommandLine.IndexOf(([IO.Path]::GetFullPath($runtimeRoot).Replace('/', '\')), [StringComparison]::OrdinalIgnoreCase) -lt 0 -or $normalizedCommandLine -notmatch '(?i)(?:^|\s)-RuntimeRoot(?:\s|$)') { return $false }
    $status = Get-JsonEndpoint -Url ($monitorUrl + '/status')
    if (-not $status.TransportOk -or $status.StatusCode -ne 200 -or $null -eq $status.Body) { return $false }
    $identity = Get-PropertyValue -Object $status.Body -Name 'monitor'
    if ($null -eq $identity -or [int](Get-PropertyValue -Object $identity -Name 'pid') -ne $processId) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'instance_id') -ne [string]$state.monitor_instance_id) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'started_at') -ne [string]$state.monitor_started_at) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'source_sha256') -ne $expectedMonitorSourceSha256) { return $false }
    try {
        $statusScriptPath = [IO.Path]::GetFullPath([string](Get-PropertyValue -Object $identity -Name 'script_path'))
        $statusRuntimeRoot = [IO.Path]::GetFullPath([string](Get-PropertyValue -Object $identity -Name 'runtime_root'))
    }
    catch { return $false }
    return (
        [string]::Equals($statusScriptPath, [IO.Path]::GetFullPath($monitorScript), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($statusRuntimeRoot, [IO.Path]::GetFullPath($runtimeRoot), [StringComparison]::OrdinalIgnoreCase)
    )
}

function Ensure-Monitor {
    if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) { throw "monitor_script_missing:$monitorScript" }
    if ((Test-Listener -Port 18788) -and (Test-ManagedMonitorIdentity)) { return }

    $projectMonitors = @(Get-ProjectMonitorProcesses)
    if ((Test-Listener -Port 18788) -and $projectMonitors.Count -eq 0) { throw 'monitor_port_conflict_unmanaged:18788' }
    foreach ($snapshot in $projectMonitors) {
        if (-not (Stop-ManagedProcessGracefully -ProcessId ([int]$snapshot.ProcessId))) { throw "monitor_shutdown_failed:$($snapshot.ProcessId)" }
    }
    $releaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Test-Listener -Port 18788) -and [DateTime]::UtcNow -lt $releaseDeadline) { Start-Sleep -Milliseconds 250 }
    if (Test-Listener -Port 18788) { throw 'monitor_port_release_timeout:18788' }

    foreach ($path in @($monitorStatePath, $monitorStatusStatePath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $monitorArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -RuntimeRoot `"$runtimeRoot`" -Watch -NoPopup -PollSeconds 5 -StartupGraceSeconds 120 -PrelaunchGraceSeconds 180"
    $monitorProcess = Start-Process -FilePath 'pwsh.exe' -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Listener -Port 18788) -and (Test-ManagedMonitorIdentity)) { return }
        try { $monitorProcess.Refresh(); if ($monitorProcess.HasExited) { throw 'monitor_process_exited' } } catch { if ($_.Exception.Message -eq 'monitor_process_exited') { throw } }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne (Get-Process -Id $monitorProcess.Id -ErrorAction SilentlyContinue)) { [void](Stop-ManagedProcessGracefully -ProcessId $monitorProcess.Id) }
    throw 'monitor_ready_timeout'
}

function Test-BrokerReady {
    $probe = Get-JsonEndpoint -Url ($brokerUrl + '/readyz')
    if (-not $probe.TransportOk -or $probe.StatusCode -ne 200 -or $null -eq $probe.Body) { return $false }
    return (
        [string]$probe.Body.service -eq 'kompress-broker' -and
        $probe.Body.ready -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string]$probe.Body.provider) -and
        -not [string]::IsNullOrWhiteSpace([string]$probe.Body.backend)
    )
}

function Ensure-KompressBroker {
    if (-not (Test-Path -LiteralPath $brokerPython -PathType Leaf)) { throw "broker_python_missing:$brokerPython" }
    foreach ($path in @(
            (Join-Path $brokerModuleRoot 'kompress_broker\app.py'),
            (Join-Path $brokerModuleRoot 'kompress_broker\worker.py'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "broker_module_missing:$path" }
    }

    $listenerPid = Get-ListenerPid -Port $BrokerPort
    if ($null -ne $listenerPid) {
        if (-not (Test-ManagedBrokerIdentity -ProcessId $listenerPid)) {
            throw "broker_port_conflict_unmanaged:$BrokerPort"
        }
        if (Test-BrokerReady) { return }
        if (-not (Stop-ManagedProcessGracefully -ProcessId $listenerPid)) { throw 'broker_shutdown_failed' }
    }

    [IO.Directory]::CreateDirectory($brokerLogRoot) | Out-Null
    $stdoutPath = Join-Path $brokerLogRoot "kompress-broker-$BrokerPort.stdout.log"
    $stderrPath = Join-Path $brokerLogRoot "kompress-broker-$BrokerPort.stderr.log"
    $environment = @{
        KOMPRESS_BROKER_STATE_PATH = $brokerRuntimeStatePath
        KOMPRESS_PROVIDER_BACKEND = 'cpu'
        KOMPRESS_WORKER_PYTHON = $brokerPython
        KOMPRESS_WORKER_STDERR_PATH = (Join-Path $brokerLogRoot 'kompress-worker.stderr.log')
        PYTHONPATH = $brokerModuleRoot
        HEADROOM_KOMPRESS_ENDPOINT = $brokerUrl
        HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
        HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = '12'
        HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
        HEADROOM_ONNX_CPU_ARENA = '1'
        HF_HOME = (Join-Path $runtimeCacheRoot 'huggingface')
        TRANSFORMERS_CACHE = (Join-Path $runtimeCacheRoot 'huggingface\transformers')
        HEADROOM_CACHE_DIR = (Join-Path $runtimeCacheRoot 'headroom')
        HEADROOM_RUNTIME_ROOT = $runtimeRoot
        HEADROOM_WORKSPACE_DIR = (Join-Path $runtimePrivateRoot 'headroom-workspace')
        HEADROOM_CONFIG_DIR = (Join-Path $runtimePrivateRoot 'headroom-config')
    }
    $quotedBrokerModuleRoot = '"' + $brokerModuleRoot + '"'
    $arguments = @('-m', 'uvicorn', 'kompress_broker.app:app', '--app-dir', $quotedBrokerModuleRoot, '--host', '127.0.0.1', '--port', $BrokerPort.ToString(), '--no-access-log')
    $process = Start-Process -FilePath $brokerPython -ArgumentList $arguments -WorkingDirectory $projectRoot -Environment $environment -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $listenerPid = Get-ListenerPid -Port $BrokerPort
        if ($null -ne $listenerPid -and (Test-BrokerReady)) { break }
        try { $process.Refresh(); if ($process.HasExited) { throw 'broker_process_exited' } } catch { if ($_.Exception.Message -eq 'broker_process_exited') { throw } }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $listenerPid -or -not (Test-BrokerReady) -or -not (Test-BrokerProcessIdentity -ProcessId $listenerPid)) {
        if ($null -ne $listenerPid -and (Test-BrokerProcessIdentity -ProcessId $listenerPid)) { [void](Stop-ManagedProcessGracefully -ProcessId $listenerPid) }
        throw 'broker_ready_timeout'
    }
    Write-BrokerState -ProcessId $listenerPid
    if (-not (Test-ManagedBrokerIdentity -ProcessId $listenerPid)) {
        [void](Stop-ManagedProcessGracefully -ProcessId $listenerPid)
        throw 'broker_identity_publish_failed'
    }
}

function Test-Ready {
    param(
        [switch]$ServiceScope,
        [switch]$AllowRelayPending
    )
    $brokerReady = Get-JsonEndpoint "$brokerUrl/readyz"
    $headroomLive = Get-JsonEndpoint "$headroomUrl/livez"
    $headroomHealth = Get-JsonEndpoint "$headroomUrl/health"
    $gatewayLive = Get-JsonEndpoint "$gatewayUrl/livez"
    $gatewayHealth = Get-JsonEndpoint "$gatewayUrl/health"
    $monitorStatus = Get-JsonEndpoint "$monitorUrl/status"
    $kompress = if ($headroomHealth.Body -and $headroomHealth.Body.PSObject.Properties['checks'] -and $headroomHealth.Body.checks.PSObject.Properties['kompress']) { $headroomHealth.Body.checks.kompress } else { $null }
    $kompressSourceStatus = [string](Get-PropertyValue -Object (Get-PropertyValue -Object $kompress -Name 'info') -Name 'source_status')
    $kompressReady = $null -ne $kompress -and (Get-PropertyValue -Object $kompress -Name 'enabled') -eq $true -and (Get-PropertyValue -Object $kompress -Name 'ready') -eq $true -and [string](Get-PropertyValue -Object $kompress -Name 'status') -ne 'deferred' -and $kompressSourceStatus -ne 'deferred'
    $gatewayReady = Test-GatewayReadinessSnapshot -Live $gatewayLive -Health $gatewayHealth -AllowRelayPending:$AllowRelayPending
    $monitorContractReady = $monitorStatus.TransportOk -and $monitorStatus.StatusCode -eq 200 -and $null -ne $monitorStatus.Body -and [int](Get-PropertyValue -Object $monitorStatus.Body -Name 'schema_version') -eq 2 -and (Test-ManagedMonitorIdentity)
    $monitorOverall = [string](Get-PropertyValue -Object $monitorStatus.Body -Name 'overall')
    # Pre-client startup may observe red while Gateway/helper/route owners
    # are intentionally absent. Identity and schema remain mandatory; only
    # the explicit pending phase may accept red/yellow overall status.
    $monitorReady = $monitorContractReady -and (
        $monitorOverall -in @('green', 'yellow') -or
        ($AllowRelayPending -and $monitorOverall -in @('red', 'yellow'))
    )
    return (
        $brokerReady.TransportOk -and $brokerReady.StatusCode -eq 200 -and $null -ne $brokerReady.Body -and (Get-PropertyValue -Object $brokerReady.Body -Name 'ready') -eq $true -and
        $headroomLive.TransportOk -and $headroomLive.StatusCode -eq 200 -and $null -ne $headroomLive.Body -and (Get-PropertyValue -Object $headroomLive.Body -Name 'alive') -eq $true -and
        $headroomHealth.TransportOk -and $headroomHealth.StatusCode -eq 200 -and $null -ne $headroomHealth.Body -and (Get-PropertyValue -Object $headroomHealth.Body -Name 'ready') -eq $true -and $kompressReady -and
        $gatewayReady -and
        $monitorReady
    )
}

function Wait-StrictReadiness {
    param([Parameter(Mandatory)][DateTime]$DeadlineUtc)

    $deadline = $DeadlineUtc.ToUniversalTime()
    do {
        if (Test-Ready) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ($true)
    return $false
}

function Test-Listener {
    param([Parameter(Mandatory)][int]$Port)
    return $null -ne (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq $Port)
}

function Invoke-ManagerReadiness {
    if (-not (Test-Path -LiteralPath $startupGate -PathType Leaf)) {
        throw "startup_gate_missing:$startupGate"
    }
    if (-not (Test-Path -LiteralPath $managerExe -PathType Leaf)) {
        throw "manager_executable_missing:$managerExe"
    }
    if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) {
        throw "manager_config_missing:$managerConfig"
    }
    if (-not (Test-Path -LiteralPath $routeKeeper -PathType Leaf)) {
        throw "route_keeper_missing:$routeKeeper"
    }

    # The manager may already be open.  ReadinessOnly refreshes the watcher
    # and process-scoped route without launching a second manager or mutating
    # the supplier configuration.
    & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $startupGate `
        -Role manager `
        -ExePath $managerExe `
        -CodexHome $managerCodexHome `
        -ConfigPath $managerConfig `
        -RouteKeeperPath $routeKeeper `
        -RuntimeRoot $runtimeRoot `
        -BrokerBaseUrl $brokerUrl `
        -GatewayBaseUrl $gatewayUrl `
        -HeadroomBaseUrl $headroomUrl `
        -MonitorBaseUrl $monitorUrl `
        -EnsureScript $ensureScript `
        -RouteReadySignalPath $routeReadySignalPath `
        -RouteStatePath $routeStatePath `
        -RouteWatchStatePath $routeWatchStatePath `
        -RouteSettingsPath 'C:\Users\ma dao\.codex-session-delete\settings.json' `
        -StartupResultPath $startupResultPath `
        -AuditPath (Join-Path $runtimeLogRoot 'codexpp-manager-bootstrap.log') `
        -ReadinessOnly `
        -SkipEnsure `
        -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
        throw "manager_readiness_failed:$LASTEXITCODE"
    }
}

function Get-ExactExecutableProcesses {
    param([Parameter(Mandatory)][string[]]$ExecutablePaths)
    $expected = @{}
    $expectedNames = @{}
    foreach ($path in $ExecutablePaths) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $fullPath = [IO.Path]::GetFullPath($path)
            $expected[$fullPath.ToLowerInvariant()] = $true
            $expectedNames[[IO.Path]::GetFileName($fullPath).ToLowerInvariant()] = $true
        }
    }
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $processName = [string]$snapshot.Name
        if ([string]::IsNullOrWhiteSpace($processName) -or -not $expectedNames.ContainsKey($processName.ToLowerInvariant())) { continue }
        $path = [string]$snapshot.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-ProcessExecutablePath -ProcessId ([int]$snapshot.ProcessId) }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try { $normalized = [IO.Path]::GetFullPath($path).ToLowerInvariant() } catch { continue }
        if ($expected.ContainsKey($normalized)) {
            [void]$matches.Add([pscustomobject]@{
                    ProcessId = [int]$snapshot.ProcessId
                    ParentProcessId = [int]$snapshot.ParentProcessId
                    ExecutablePath = [IO.Path]::GetFullPath($path)
                    CommandLine = [string]$snapshot.CommandLine
                })
        }
    }
    return @($matches)
}

function Get-ManagedCodexState {
    if (-not (Test-Path -LiteralPath $managedCodexStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $managedCodexStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-RouteStateContract {
    param(
        [Parameter(Mandatory)][string]$ExpectedConfigHash,
        [switch]$AllowPending
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedConfigHash) -or -not (Test-Path -LiteralPath $routeStatePath -PathType Leaf)) { return $false }
    try {
        $routeState = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json
        $allowedStatuses = if ($AllowPending) { @('ready', 'pending', 'official-bypass') } else { @('ready', 'official-bypass') }
        if ([string]$routeState.status -notin $allowedStatuses) { return $false }
        if ([string]$routeState.route_scope -ne 'process' -or [bool]$routeState.config_mutated) { return $false }
        return [string]$routeState.config_sha256 -eq $ExpectedConfigHash
    }
    catch { return $false }
}

function ConvertTo-UtcDateTimeValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue)) { return $null }
    $parsed = [DateTime]::Parse($textValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $parsed.ToUniversalTime()
}

function Test-ManagedCodexProcesses {
    $state = Get-ManagedCodexState
    if ($null -eq $state -or [int]$state.schema_version -ne 1) { return $false }
    foreach ($entry in @($state.processes)) {
        $processId = 0
        if (-not [int]::TryParse([string]$entry.pid, [ref]$processId) -or $processId -le 0) { return $false }
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $snapshot) { return $false }
        try {
            $actualPath = [IO.Path]::GetFullPath((Get-ProcessExecutablePath -ProcessId $processId))
            $expectedPath = [IO.Path]::GetFullPath([string]$entry.executable_path)
        }
        catch { return $false }
        if (-not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }
        try {
            $expectedStarted = ConvertTo-UtcDateTimeValue -Value $entry.started_at_utc
            if ($null -eq $expectedStarted) { return $false }
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStarted).TotalSeconds) -gt 2) { return $false }
        }
        catch { return $false }
    }
    return @($state.processes).Count -eq 2
}

function Confirm-DirectProcessRestart {
    $shell = New-Object -ComObject WScript.Shell
    $choice = $shell.Popup(
        'Codex++ is running outside the managed Headroom launch chain. Restart Manager and Codex++ through Headroom now?',
        0,
        'Headroom for Codex++',
        49
    )
    return $choice -eq 1
}

function Stop-ExactExecutableProcesses {
    param([Parameter(Mandatory)][object[]]$Snapshots)
    foreach ($snapshot in $Snapshots) {
        $processId = [int]$snapshot.ProcessId
        $expectedPath = [IO.Path]::GetFullPath([string]$snapshot.ExecutablePath)
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        [void]$process.CloseMainWindow()
        try { [void]$process.WaitForExit(8000) } catch { }
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            $current = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $current) { continue }
            try { $currentPath = [IO.Path]::GetFullPath((Get-ProcessExecutablePath -ProcessId $processId)) } catch { throw "codex_process_identity_lost:$processId" }
            if (-not [string]::Equals($currentPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw "codex_process_identity_changed:$processId" }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
    }
}

function Write-ManagedCodexState {
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))) {
        $process = Get-Process -Id ([int]$snapshot.ProcessId) -ErrorAction Stop
        [void]$entries.Add([ordered]@{
            pid = [int]$snapshot.ProcessId
            executable_path = [IO.Path]::GetFullPath([string]$snapshot.ExecutablePath)
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        })
    }
    if ($entries.Count -ne 2) { throw 'managed_codex_process_count_invalid' }
    $document = [ordered]@{
        schema_version = 1
        route_scope = 'process'
        route_state_path = $routeStatePath
        source_hashes = $sourceHashesBefore
        processes = @($entries)
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = Join-Path $runtimeStateRoot ('.managed-codex-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $managedCodexStatePath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Focus-ManagedCodexWindow {
    $state = Get-ManagedCodexState
    if ($null -eq $state) { return }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($entry in @($state.processes)) {
        if ([string]$entry.executable_path -like '*codex-plus-plus.exe') {
            [void]$shell.AppActivate([int]$entry.pid)
            return
        }
    }
}

try {
    try {
        $startMutexHeld = $startMutex.WaitOne([TimeSpan]::FromSeconds(15))
    }
    catch [Threading.AbandonedMutexException] {
        $startMutexHeld = $true
    }
    if (-not $startMutexHeld) { throw 'startup_mutex_busy' }
    $sourceHashesBefore = Get-ManagedSourceHashes
    $managedAlready = $false
    if (-not $ServicesOnly) {
        $managedAlready = Test-ManagedCodexProcesses
        $existingCodexProcesses = @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))
        if ($existingCodexProcesses.Count -gt 0 -and -not $managedAlready) {
            if (-not (Confirm-DirectProcessRestart)) { throw 'direct_process_restart_cancelled' }
            Stop-ExactExecutableProcesses -Snapshots $existingCodexProcesses
            Remove-Item -LiteralPath $managedCodexStatePath -Force -ErrorAction SilentlyContinue
        }
    }
    [Environment]::SetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', $brokerUrl, 'Process')

    # The broker is a hard gate.  Headroom is never allowed to start against
    # the helper directly or while the provider canary is deferred.
    Ensure-KompressBroker

    if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
        throw "ensure_script_missing:$ensureScript"
    }

    # The ensure script is idempotent and refuses unmanaged port conflicts.
    & $ensureScript `
        -Port 18787 `
        -HeadroomPort 18789 `
        -Workers $Workers `
        -PythonPath $brokerPython `
        -RuntimeStateRoot $runtimeStateRoot `
        -RuntimeLogRoot $runtimeLogRoot `
        -KompressEndpoint $brokerUrl `
        -AllowRelayPending

    Ensure-Monitor
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Ready -ServiceScope:$ServicesOnly -AllowRelayPending) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Ready -ServiceScope:$ServicesOnly -AllowRelayPending)) {
        throw 'readiness_failed'
    }

    if (-not $ServicesOnly) {
        if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) { throw "manager_config_missing:$managerConfig" }
        $managerConfigHashBefore = (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($managerConfigHashBefore)) { throw 'manager_config_hash_unavailable' }
        if (-not (Test-Path -LiteralPath $managerBootstrap -PathType Leaf)) {
            throw "manager_bootstrap_missing:$managerBootstrap"
        }
        if (-not $managedAlready) {
            if (-not (Test-Path -LiteralPath $clientBootstrap -PathType Leaf)) { throw "client_bootstrap_missing:$clientBootstrap" }
            $managerArgs = "//B //Nologo `"$managerBootstrap`""
            Start-Process -FilePath 'wscript.exe' -ArgumentList $managerArgs -WindowStyle Hidden | Out-Null
            $managerDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            while (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe)).Count -eq 0 -and [DateTime]::UtcNow -lt $managerDeadline) { Start-Sleep -Milliseconds 500 }
            if (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe)).Count -ne 1) { throw 'manager_process_not_observed' }
            $clientArgs = "//B //Nologo `"$clientBootstrap`" -AllowRelayPending"
            Start-Process -FilePath 'wscript.exe' -ArgumentList $clientArgs -WindowStyle Hidden | Out-Null
            $clientDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            while (@(Get-ExactExecutableProcesses -ExecutablePaths @($clientExe)).Count -eq 0 -and [DateTime]::UtcNow -lt $clientDeadline) { Start-Sleep -Milliseconds 500 }
            if (@(Get-ExactExecutableProcesses -ExecutablePaths @($clientExe)).Count -ne 1) { throw 'client_process_not_observed' }
        }
        # Publish exact Manager/client identity before the final monitor gate
        # so the monitor can distinguish a missing state file from an actual
        # unmanaged process. Route state may still be pending here, but it
        # must remain process-scoped, immutable, and hash-bound.
        if (-not (Test-RouteStateContract -ExpectedConfigHash $managerConfigHashBefore -AllowPending)) { throw 'route_state_contract_invalid_before_managed_state' }
        if (-not $managedAlready) {
            Write-ManagedCodexState
        }
        if (-not (Test-ManagedCodexProcesses)) { throw 'managed_codex_state_identity_invalid_before_final_readiness' }

        # The relay is mandatory once a client is expected. The monitor may
        # need one poll to observe the freshly published managed state, so
        # wait within the existing startup budget while keeping this strict:
        # no AllowRelayPending and no red/yellow acceptance.
        $postClientDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
        if (-not (Wait-StrictReadiness -DeadlineUtc $postClientDeadline)) { throw 'readiness_failed_after_client' }
        Invoke-ManagerReadiness
        if (-not (Test-SourceHashesUnchanged -Expected $sourceHashesBefore)) { throw 'source_hash_changed_during_startup' }
        if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) { throw 'manager_config_missing_after_start' }
        $configHashAfter = (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($configHashAfter)) { throw 'manager_config_hash_unavailable' }
        if ($configHashAfter -ne $managerConfigHashBefore) { throw 'manager_config_changed_during_startup' }
        if (-not (Test-RouteStateContract -ExpectedConfigHash $configHashAfter)) { throw 'route_state_not_ready_or_config_hash_mismatch' }
        if (-not (Test-ManagedCodexProcesses)) { throw 'managed_codex_state_identity_invalid_after_readiness' }
        if ($managedAlready) { Focus-ManagedCodexWindow }
    }

    $startStage = if ($ServicesOnly) { 'services_ready' } elseif ($managedAlready) { 'already_managed' } else { 'manager_and_client_launched' }
    Write-StartResult -Status succeeded -Stage $startStage -ErrorCode ''
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    Write-StartResult -Status failed -Stage 'startup' -ErrorCode 'headroom_start_failed' -Detail $message
    Write-Error $message
    exit 1
}
finally {
    if ($startMutexHeld) {
        try { $startMutex.ReleaseMutex() } catch { }
    }
    $startMutex.Dispose()
    [Environment]::SetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', $previousKompressEndpoint, 'Process')
}
