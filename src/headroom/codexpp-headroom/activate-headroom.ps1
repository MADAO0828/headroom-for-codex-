[CmdletBinding()]
param(
    [string]$StagePath = (Join-Path $PSScriptRoot 'headroom-activation-stage.json'),
    [switch]$ConfirmActivation
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'activation-lib.ps1')

$activationStatePath = Join-Path $PSScriptRoot 'headroom-activation-state.json'
$startScriptPath = Join-Path $PSScriptRoot 'start-headroom.ps1'
$launcherPath = Join-Path $PSScriptRoot 'headroom-launcher.py'
$gatewayPath = Join-Path $PSScriptRoot 'gateway.py'
$pythonPath = 'C:\Users\ma dao\.headroom-venv\Scripts\python.exe'
$expectedStatePath = Join-Path $PSScriptRoot 'headroom-state-18787.json'
$legacyStatePath = Join-Path $PSScriptRoot 'headroom-state.json'
$activeHeadroomStatePath = Join-Path $PSScriptRoot 'headroom-state-18789.json'
$gatewayProcessStatePath = Join-Path $PSScriptRoot 'gateway-process-state.json'
$gatewayMetricsStatePath = Join-Path $PSScriptRoot 'gateway-metrics-state.json'
$expectedBackupMarkerPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\backups\headroom-integration-current\BACKUP_COMPLETE.marker'
$oldListenerPid = $null
$oldParentPid = $null
$newHeadroomPid = $null
$newGatewayPid = $null
$headroomAttemptStartedAtUtc = $null
$headroomBaselinePid = 0
$gatewayAttemptStartedAtUtc = $null
$gatewayBaselinePid = 0
$cleanupErrorCode = $null
$oldStopped = $false
$oldState = $null
$stage = $null
$rollbackStatus = 'not_started'
$errorCode = $null
$activationRunId = 'activation-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '-' + (Get-Random -Minimum 1000 -Maximum 9999)

function Write-ActivationState {
    param([Parameter(Mandatory)][string]$Status,[AllowNull()][string]$Code,[string]$Rollback = $rollbackStatus)
    $document = [ordered]@{
        activation_schema_version = 1
        run_id = $activationRunId
        status = $Status
        error_code = $Code
        rollback_status = $Rollback
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        stage_path = $StagePath
        old_port = if ($stage) { $stage.old_port } else { 18787 }
        headroom_port = if ($stage) { $stage.headroom_port } else { 18789 }
        gateway_port = if ($stage) { $stage.gateway_port } else { 18787 }
        helper_port = 57321
        headroom_state_path = $activeHeadroomStatePath
        gateway_process_state_path = $gatewayProcessStatePath
        gateway_metrics_state_path = $gatewayMetricsStatePath
        old_listener_pid = $oldListenerPid
        new_headroom_pid = $newHeadroomPid
        new_gateway_pid = $newGatewayPid
    }
    Write-ActivationAtomicJson -Path $activationStatePath -Document $document
}

function Write-GatewayProcessState {
    param([Parameter(Mandatory)][object]$Process,[Parameter(Mandatory)][int]$Port,[Parameter(Mandatory)][int]$HeadroomPort)
    $path = $gatewayProcessStatePath
    $processPath = [string]$Process.Path
    if ([string]::IsNullOrWhiteSpace($processPath)) {
        try { $processPath = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Process.Id)" -ErrorAction Stop | Select-Object -First 1 -ExpandProperty ExecutablePath) } catch { }
    }
    $document = [ordered]@{
        gateway_process_schema_version = 2
        route_contract_version = 3
        service = 'policy-gateway'
        state_role = 'gateway-process-identity'
        Pid = [int]$Process.Id
        Port = $Port
        HeadroomPort = $HeadroomPort
        HelperPort = 57321
        Path = $processPath
        StartedAt = [DateTime]::UtcNow.ToString('o')
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $directory = Split-Path -Parent $path
    $temporary = Join-Path $directory ('.gateway-process-state-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-StableActivationCode {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'activation_confirmation_required') { return 'activation_confirmation_required' }
    if ($message -match 'client_processes_active') { return 'client_processes_active' }
    if ($message -match 'activation_stage_') { return $message.Split(':')[0] }
    if ($message -match 'gateway_cleanup_failed') { return 'gateway_cleanup_failed' }
    if ($message -match 'old_headroom') { return $message.Split(':')[0] }
    if ($message -match 'backup|marker') { return 'backup_marker_invalid' }
    if ($message -match 'gateway') { return 'gateway_start_failed' }
    if ($message -match 'headroom') { return 'headroom_start_failed' }
    return 'activation_failed'
}

function Test-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Url,[Parameter(Mandatory)][string]$Service,[switch]$Ready)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -TimeoutSec 15
        if ([int]$response.StatusCode -ne 200) { return $false }
        $body = $response.Content | ConvertFrom-Json
        if ($body.service -ne $Service -or $body.status -ne 'healthy') { return $false }
        if ($Ready) { return ($body.ready -eq $true) }
        return ($body.alive -eq $true)
    } catch { return $false }
}

function Test-HelperAvailable {
    try {
        $response = Invoke-WebRequest -Uri 'http://127.0.0.1:57321/health' -Method Get -NoProxy -UseBasicParsing -TimeoutSec 3
        if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) { return $true }
        if ([int]$response.StatusCode -ne 404) { return $false }
    } catch { }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', 57321)
        if (-not $task.Wait(1000)) { return $false }
        return $task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion
    } catch { return $false } finally { $client.Dispose() }
}

function Wait-NewServices {
    param([Parameter(Mandatory)][int]$HeadroomPort,[Parameter(Mandatory)][int]$GatewayPort)
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $headroomLive = Test-JsonEndpoint -Url "http://127.0.0.1:$HeadroomPort/livez" -Service 'headroom-proxy'
        $gatewayLive = Test-JsonEndpoint -Url "http://127.0.0.1:$GatewayPort/livez" -Service 'policy-gateway'
        if ($headroomLive -and $gatewayLive) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Stop-TrackedProcess {
    param([AllowNull()][int]$ProcessId,[Parameter(Mandatory)][string]$ExpectedPath,[Parameter(Mandatory)][string]$CommandPattern)
    if ($null -eq $ProcessId -or $ProcessId -le 0) { return }
    $identity = Test-ActivationTrackedProcessIdentity -ProcessId $ProcessId -ExpectedPath $ExpectedPath -CommandPattern $CommandPattern
    if (-not $identity.Ready) { throw $identity.ErrorCode }
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
}

function Get-StrictNewHeadroomCandidates {
    $headroomPort = if ($stage) { [int]$stage.headroom_port } else { 18789 }
    if ($headroomPort -ne 18789 -or $null -eq $headroomAttemptStartedAtUtc) { return @() }
    $snapshots = @()
    $effectiveBaselinePid = $headroomBaselinePid
    if ($newHeadroomPid) {
        try {
            $snapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$newHeadroomPid)
            if ($snapshot) { $snapshots += $snapshot }
        } catch { }
    }
    $startupStatePath = Join-Path $PSScriptRoot ("headroom-startup-{0}.json" -f $headroomPort)
    if (Test-Path -LiteralPath $startupStatePath -PathType Leaf) {
        try {
            $startupState = Get-Content -LiteralPath $startupStatePath -Raw | ConvertFrom-Json
            $stateAttempt = ([DateTimeOffset]::Parse([string]$startupState.attempt_started_at_utc)).UtcDateTime
            $stateBaselinePid = 0
            if ($stateAttempt -ge $headroomAttemptStartedAtUtc -and [int]::TryParse([string]$startupState.baseline_listener_pid, [ref]$stateBaselinePid) -and $stateBaselinePid -gt 0) {
                $effectiveBaselinePid = $stateBaselinePid
            }
            $statePid = 0
            if ($stateAttempt -ge $headroomAttemptStartedAtUtc -and [int]::TryParse([string]$startupState.spawned_pid, [ref]$statePid) -and $statePid -gt 0) {
                $snapshot = Get-ActivationProcessSnapshot -ProcessId $statePid
                if ($snapshot) { $snapshots += $snapshot }
            }
            $stateListenerPid = 0
            if ($stateAttempt -ge $headroomAttemptStartedAtUtc -and [int]::TryParse([string]$startupState.listener_pid, [ref]$stateListenerPid) -and $stateListenerPid -gt 0) {
                $snapshot = Get-ActivationProcessSnapshot -ProcessId $stateListenerPid
                if ($snapshot) { $snapshots += $snapshot }
            }
        } catch { }
    }
    try {
        $processIds = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
        foreach ($processId in $processIds) {
            try {
                $snapshot = Get-ActivationProcessSnapshot -ProcessId $processId
                if ($snapshot) { $snapshots += $snapshot }
            } catch { }
        }
    } catch { }
    $unique = @{}
    foreach ($candidate in @(Get-ActivationHeadroomSpawnCandidates -Processes $snapshots -PythonPath $pythonPath -LauncherPath $launcherPath -Port $headroomPort -Target 'http://127.0.0.1:57321' -NotBeforeUtc $headroomAttemptStartedAtUtc -BaselinePid $effectiveBaselinePid)) {
        $candidatePid = [int]$candidate.Id
        if (-not $unique.ContainsKey($candidatePid)) {
            $unique[$candidatePid] = $candidate
            $candidate
        }
    }
}

function Get-StrictNewGatewayCandidates {
    $gatewayPort = 18787
    if ($null -eq $gatewayAttemptStartedAtUtc) { return @() }
    $snapshots = @()
    if ($newGatewayPid) {
        try {
            $snapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$newGatewayPid)
            if ($snapshot) { $snapshots += $snapshot }
        } catch { }
    }
    try {
        $processIds = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
        foreach ($processId in $processIds) {
            try {
                $snapshot = Get-ActivationProcessSnapshot -ProcessId $processId
                if ($snapshot) { $snapshots += $snapshot }
            } catch { }
        }
    } catch { }
    $unique = @{}
    foreach ($candidate in @(Get-ActivationGatewaySpawnCandidates -Processes $snapshots -PythonPath $pythonPath -ModuleRoot $PSScriptRoot -Port $gatewayPort -NotBeforeUtc $gatewayAttemptStartedAtUtc -BaselinePid $gatewayBaselinePid)) {
        $candidatePid = [int]$candidate.Id
        if (-not $unique.ContainsKey($candidatePid)) {
            $unique[$candidatePid] = $candidate
            $candidate
        }
    }
}

function Stop-NewProcesses {
    $gatewayPort = 18787
    $gatewayCleanupFailed = $false
    $gatewayPattern = Get-ActivationGatewayCommandPattern -PythonPath $pythonPath -ModuleRoot $PSScriptRoot -Port $gatewayPort
    if ($newGatewayPid) {
        $snapshot = $null
        try { $snapshot = Get-ActivationProcessSnapshot -ProcessId $newGatewayPid } catch { }
        if ($snapshot -and $gatewayBaselinePid -ne [int]$newGatewayPid -and -not (Test-ActivationGatewaySpawnIdentity -Snapshot $snapshot -PythonPath $pythonPath -ModuleRoot $PSScriptRoot -Port $gatewayPort -NotBeforeUtc $gatewayAttemptStartedAtUtc -BaselinePid $gatewayBaselinePid)) {
            $gatewayCleanupFailed = $true
        }
    }
    foreach ($candidate in @(Get-StrictNewGatewayCandidates)) {
        try {
            Stop-TrackedProcess -ProcessId ([int]$candidate.Id) -ExpectedPath $pythonPath -CommandPattern $gatewayPattern
        } catch {
            $gatewayCleanupFailed = $true
        }
    }
    if ($gatewayCleanupFailed) { throw 'gateway_cleanup_failed' }

    $headroomPort = if ($stage) { [int]$stage.headroom_port } else { 18789 }
    $headroomPattern = Get-ActivationHeadroomCommandPattern -PythonPath $pythonPath -LauncherPath $launcherPath -Port $headroomPort -Target 'http://127.0.0.1:57321'
    foreach ($candidate in @(Get-StrictNewHeadroomCandidates)) {
        try {
            Stop-TrackedProcess -ProcessId ([int]$candidate.Id) -ExpectedPath ([string]$candidate.Path) -CommandPattern $headroomPattern
        } catch { }
    }
}

function Test-OldParentIdentity {
    param([AllowNull()][object]$Process,[AllowNull()][object]$State)
    if ($null -eq $Process -or $null -eq $State) { return $false }
    $expectedPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $State 'ParentPath'))
    $actualPath = ConvertTo-ActivationFullPath -Path ([string]$Process.Path)
    if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($actualPath) -or -not $expectedPath.Equals($actualPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $expectedStart = [DateTime]::MinValue
    try { $expectedStart = ([DateTimeOffset]::Parse([string](Get-ActivationProperty $State 'ParentStartedAt'))).UtcDateTime } catch { return $false }
    try { if ([Math]::Abs(($Process.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds) -gt 10) { return $false } } catch { return $false }
    return ([string]$Process.CommandLine -match '(?i)headroom-launcher\.py')
}

function Restore-OldHeadroom {
    if (-not $oldStopped) { $rollbackStatus = 'old_headroom_unchanged'; return }
    if ($null -eq $stage) { $rollbackStatus = 'old_headroom_restore_not_possible'; return }
    $rollbackStatus = 'starting_old_headroom'
    try {
        $env:HEADROOM_MODE = 'cache'
        $env:HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
        $env:HEADROOM_SKIP_UPSTREAM_CHECK = '1'
        $env:HEADROOM_TELEMETRY = 'off'
        & $startScriptPath -Port ([int]$stage.old_port) *>$null
        if (-not (Test-JsonEndpoint -Url ("http://127.0.0.1:{0}/livez" -f $stage.old_port) -Service 'headroom-proxy')) { throw 'rollback_old_headroom_unhealthy' }
        $rollbackStatus = 'old_headroom_restored'
    } catch {
        $rollbackStatus = 'old_headroom_restore_failed'
        throw
    }
}

if (-not $ConfirmActivation) {
    Write-ActivationState -Status 'blocked' -Code 'activation_confirmation_required'
    throw 'activation_confirmation_required'
}
if (-not (Test-ActivationPathWithinRoot -Path $StagePath -Root $PSScriptRoot)) {
    Write-ActivationState -Status 'blocked' -Code 'activation_stage_path_outside_deployment'
    throw 'activation_stage_path_outside_deployment'
}

try {
    if (-not (Test-Path -LiteralPath $StagePath -PathType Leaf)) { throw 'activation_stage_missing' }
    $stage = Get-Content -LiteralPath $StagePath -Raw | ConvertFrom-Json
    if ([int]$stage.stage_schema_version -ne 1 -or $stage.ready_for_activation -ne $true) { throw 'activation_stage_not_ready' }
    $stageFixed = Test-ActivationStageFixedValues -Stage $stage -ExpectedStatePath $expectedStatePath -ExpectedLegacyStatePath $legacyStatePath -ExpectedBackupMarkerPath $expectedBackupMarkerPath
    if (-not $stageFixed.Ready) { throw [string]$stageFixed.ErrorCode }
    if (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $gatewayPath -PathType Leaf)) { throw 'activation_deployment_missing' }
    if ((Get-ActivationFileHash -Path ([string]$stage.backup_marker_path)) -ne [string]$stage.backup_marker_sha256) { throw 'activation_stage_backup_changed' }
    if ((Get-ActivationFileHash -Path ([string]$stage.state_path)) -ne [string]$stage.state_sha256) { throw 'activation_stage_state_changed' }
    $oldState = Get-Content -LiteralPath ([string]$stage.state_path) -Raw | ConvertFrom-Json
    $oldListenerPid = Get-ActivationListenerPid -Port ([int]$stage.old_port)
    if ($null -eq $oldListenerPid) { throw 'old_headroom_listener_missing' }
    $oldListener = Get-ActivationProcessSnapshot -ProcessId $oldListenerPid
    $oldParentPidForIdentity = 0
    $oldParentForIdentity = $null
    if ([int]::TryParse([string](Get-ActivationProperty $oldState 'ParentPid'), [ref]$oldParentPidForIdentity) -and $oldParentPidForIdentity -gt 0) {
        $oldParentForIdentity = Get-ActivationProcessSnapshot -ProcessId $oldParentPidForIdentity
    }
    $identity = Test-ActivationOldHeadroomIdentity -State $oldState -ListenerPid $oldListenerPid -Listener $oldListener -Parent $oldParentForIdentity -OldPort ([int]$stage.old_port) -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startScriptPath -ExpectedPythonPath $pythonPath
    if (-not $identity.Ready) { throw [string]$identity.ErrorCode }
    $clientProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object Name, CommandLine, ProcessId)
    $clients = Test-ActivationClientsExited -Processes $clientProcesses
    if (-not $clients.Ready) { throw [string]$clients.ErrorCode }

    # Stop only the identity-matched old Headroom listener after all gates pass.
    $oldHeadroomPattern = Get-ActivationHeadroomCommandPattern -PythonPath $pythonPath -LauncherPath $launcherPath -Port ([int]$stage.old_port) -Target 'http://127.0.0.1:57321'
    Stop-TrackedProcess -ProcessId $oldListenerPid -ExpectedPath ([string]$oldListener.Path) -CommandPattern $oldHeadroomPattern
    $oldStopped = $true
    $oldParentPid = [int](Get-ActivationProperty $oldState 'ParentPid')
    if ($oldParentPid -gt 0) {
        $oldParent = Get-ActivationProcessSnapshot -ProcessId $oldParentPid
        if (Test-OldParentIdentity -Process $oldParent -State $oldState) {
            try { Stop-Process -Id $oldParentPid -Force -ErrorAction Stop } catch { }
        }
    }
    $freeDeadline = (Get-Date).AddSeconds(10)
    while ((Get-ActivationListenerPid -Port ([int]$stage.old_port)) -and (Get-Date) -lt $freeDeadline) { Start-Sleep -Milliseconds 200 }
    if (Get-ActivationListenerPid -Port ([int]$stage.old_port)) { throw 'old_headroom_port_not_free' }

    $headroomAttemptStartedAtUtc = [DateTime]::UtcNow
    $headroomBaselinePid = Get-ActivationListenerPid -Port ([int]$stage.headroom_port)
    & $startScriptPath -Port ([int]$stage.headroom_port) *>$null
    $newHeadroomPid = Get-ActivationListenerPid -Port ([int]$stage.headroom_port)
    if ($null -eq $newHeadroomPid) { throw 'headroom_start_failed' }
    $env:HEADROOM_URL = "http://127.0.0.1:$([int]$stage.headroom_port)"
    $env:HELPER_URL = 'http://127.0.0.1:57321'
    $env:POLICY_GATEWAY_STATE_PATH = $gatewayMetricsStatePath
    $gatewayAttemptStartedAtUtc = [DateTime]::UtcNow
    $gatewayBaselinePid = Get-ActivationListenerPid -Port ([int]$stage.gateway_port)
    if ($null -ne $gatewayBaselinePid) { throw 'gateway_baseline_listener_present' }
    $gatewayArgs = @('-m','uvicorn','gateway:app','--app-dir',$PSScriptRoot,'--host','127.0.0.1','--port',([int]$stage.gateway_port).ToString(),'--no-access-log')
    $gatewayProcess = Start-Process -FilePath $pythonPath -ArgumentList $gatewayArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $PSScriptRoot "gateway-$([int]$stage.gateway_port).stdout.log") -RedirectStandardError (Join-Path $PSScriptRoot "gateway-$([int]$stage.gateway_port).stderr.log")
    $newGatewayPid = [int]$gatewayProcess.Id
    Write-GatewayProcessState -Process $gatewayProcess -Port ([int]$stage.gateway_port) -HeadroomPort ([int]$stage.headroom_port)
    if (-not (Wait-NewServices -HeadroomPort ([int]$stage.headroom_port) -GatewayPort ([int]$stage.gateway_port))) { throw 'activation_readiness_failed' }
    $rollbackStatus = 'not_required'
    Write-ActivationState -Status 'active' -Code $null
    exit 0
} catch {
    $errorCode = Get-StableActivationCode -ErrorRecord $_
    try { Stop-NewProcesses } catch { $cleanupErrorCode = Get-StableActivationCode -ErrorRecord $_ }
    if ($cleanupErrorCode) { $errorCode = $cleanupErrorCode }
    try { Restore-OldHeadroom } catch { $rollbackStatus = 'old_headroom_restore_failed' }
    try { Write-ActivationState -Status 'failed' -Code $errorCode -Rollback $rollbackStatus } catch { }
    throw $errorCode
}
