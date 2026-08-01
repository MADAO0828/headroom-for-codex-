[CmdletBinding()]
param(
    [int]$OldPort = 18787,
    [int]$HeadroomPort = 18789,
    [int]$GatewayPort = 18787,
    [string]$StagePath = (Join-Path $PSScriptRoot 'headroom-activation-stage.json'),
    [string]$BackupMarkerPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\backups\headroom-integration-current\BACKUP_COMPLETE.marker'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'activation-lib.ps1')

if (-not (Test-ActivationPathWithinRoot -Path $StagePath -Root $PSScriptRoot)) {
    throw 'activation_stage_path_outside_deployment'
}
$statePath = Join-Path $PSScriptRoot ("headroom-state-{0}.json" -f $OldPort)
$hasPortSpecificState = Test-Path -LiteralPath $statePath -PathType Leaf
$stateReadPath = $statePath
$startScriptPath = Join-Path $PSScriptRoot 'start-headroom.ps1'
$launcherPath = Join-Path $PSScriptRoot 'headroom-launcher.py'
$pythonPath = 'C:\Users\ma dao\.headroom-venv\Scripts\python.exe'
$listenerPid = $null
$listener = $null
$parent = $null
$state = $null
$stateHash = Get-ActivationFileHash -Path $stateReadPath
$markerHash = Get-ActivationFileHash -Path $BackupMarkerPath
$errorCode = $null

if ($null -eq $markerHash) {
    $errorCode = 'backup_marker_missing'
}

$identity = [pscustomobject]@{ Ready = $false; ErrorCode = $null }
if ($null -eq $errorCode -and $hasPortSpecificState) {
    if ($null -eq $stateHash) {
        $errorCode = 'old_headroom_state_missing'
    }
    else {
        try { $state = Get-Content -LiteralPath $stateReadPath -Raw | ConvertFrom-Json } catch { $errorCode = 'old_headroom_state_invalid' }
    }
}

if ($null -eq $errorCode) {
    try { $listenerPid = Get-ActivationListenerPid -Port $OldPort } catch { $errorCode = $_.Exception.Message }
    if ($null -eq $errorCode -and $null -eq $listenerPid) { $errorCode = 'old_headroom_listener_missing' }
    if ($null -eq $errorCode) {
        $listener = Get-ActivationProcessSnapshot -ProcessId $listenerPid
        if ($null -eq $listener) { $errorCode = 'old_headroom_process_missing' }
    }
    if ($null -eq $errorCode) {
        $parentPid = 0
        if ($hasPortSpecificState) {
            [int]::TryParse([string](Get-ActivationProperty $state 'ParentPid'), [ref]$parentPid) | Out-Null
        }
        else {
            [int]::TryParse([string](Get-ActivationProperty $listener 'ParentProcessId'), [ref]$parentPid) | Out-Null
        }
        if ($parentPid -le 0) { $errorCode = 'old_headroom_parent_missing' }
        else { $parent = Get-ActivationProcessSnapshot -ProcessId $parentPid }
        if ($null -eq $errorCode -and $null -eq $parent) { $errorCode = 'old_headroom_parent_missing' }
    }
}

if ($null -eq $errorCode -and -not $hasPortSpecificState) {
    $candidate = New-ActivationHeadroomStateFromLive -ListenerPid $listenerPid -Listener $listener -Parent $parent -OldPort $OldPort -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startScriptPath -ExpectedPythonPath $pythonPath -Target 'http://127.0.0.1:57321' -StatePath $statePath
    if (-not $candidate.Ready) {
        $errorCode = $candidate.ErrorCode
        $identity = [pscustomobject]@{ Ready = $false; ErrorCode = $errorCode }
    }
    else {
        $identity = Test-ActivationOldHeadroomIdentity -State $candidate.State -ListenerPid $listenerPid -Listener $listener -Parent $parent -OldPort $OldPort -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startScriptPath -ExpectedPythonPath $pythonPath
        if (-not $identity.Ready) {
            $errorCode = $identity.ErrorCode
        }
        else {
            Write-ActivationAtomicJson -Path $statePath -Document $candidate.State
            $stateReadPath = $statePath
            $stateHash = Get-ActivationFileHash -Path $stateReadPath
            try { $state = Get-Content -LiteralPath $stateReadPath -Raw | ConvertFrom-Json } catch { $errorCode = 'old_headroom_state_invalid' }
            if ($null -eq $errorCode) {
                $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid $listenerPid -Listener $listener -Parent $parent -OldPort $OldPort -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startScriptPath -ExpectedPythonPath $pythonPath
                if (-not $identity.Ready) { $errorCode = $identity.ErrorCode }
            }
        }
    }
}
elseif ($null -eq $errorCode) {
    $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid $listenerPid -Listener $listener -Parent $parent -OldPort $OldPort -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startScriptPath -ExpectedPythonPath $pythonPath
    if (-not $identity.Ready) { $errorCode = $identity.ErrorCode }
}

$clientCheck = [pscustomobject]@{ Ready = $false; ErrorCode = 'client_process_snapshot_failed'; Processes = @() }
try {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object Name, CommandLine, ProcessId)
    $clientCheck = Test-ActivationClientsExited -Processes $processes
} catch {
    $errorCode = if ($null -eq $errorCode) { 'client_process_snapshot_failed' } else { $errorCode }
}
if (-not $clientCheck.Ready -and $null -eq $errorCode) { $errorCode = $clientCheck.ErrorCode }

$ready = ($null -eq $errorCode -and $identity.Ready -and $clientCheck.Ready)
$document = [ordered]@{
    stage_schema_version = 1
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    backup_marker_path = $BackupMarkerPath
    backup_marker_sha256 = $markerHash
    old_port = $OldPort
    headroom_port = $HeadroomPort
    gateway_port = $GatewayPort
    helper_port = 57321
    state_path = $stateReadPath
    state_sha256 = $stateHash
    old_state = $state
    old_listener = if ($listener) {
        [ordered]@{
            pid = [int]$listener.Id
            path = [string]$listener.Path
            commandline_sha256 = if ($listener.CommandLine) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$listener.CommandLine))).ToUpperInvariant() } else { $null }
        }
    } else { $null }
    identity = $identity
    clients = [ordered]@{ ready = $clientCheck.Ready; error_code = $clientCheck.ErrorCode; active_count = @($clientCheck.Processes).Count }
    ready_for_activation = $ready
    error_code = if ($ready) { $null } else { $errorCode }
}
Write-ActivationAtomicJson -Path $StagePath -Document $document
$document | ConvertTo-Json -Depth 12
if (-not $ready) { exit 2 }
