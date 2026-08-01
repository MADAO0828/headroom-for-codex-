<##
.SYNOPSIS
Shared, side-effect-free validation helpers for Headroom activation scripts.

The functions in this file do not start, stop, or modify external processes.
They are also used by the offline fixture test.
##>

function ConvertTo-ActivationFullPath {
    param([Parameter(Mandatory)][string]$Path)
    try { return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $null }
}

function Test-ActivationPathWithinRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $candidate = ConvertTo-ActivationFullPath -Path $Path
    $rootPath = ConvertTo-ActivationFullPath -Path $Root
    if ([string]::IsNullOrWhiteSpace($candidate) -or [string]::IsNullOrWhiteSpace($rootPath)) { return $false }
    return $candidate.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($rootPath + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ActivationFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() } catch { return $null }
}

function Get-ActivationProperty {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-ActivationUtcDateTime {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { throw 'activation_time_missing' }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime
}

function Get-ActivationListenerPid {
    param([Parameter(Mandatory)][int]$Port)
    $lines = @(netstat -ano | Select-String -Pattern ("^\s*TCP\s+127\.0\.0\.1:{0}\s+.*LISTENING\s+(\d+)\s*$" -f $Port))
    if ($lines.Count -gt 1) { throw 'activation_listener_ambiguous' }
    if ($lines.Count -eq 0) { return $null }
    return [int]$lines[0].Matches[0].Groups[1].Value
}

function Get-ActivationProcessSnapshot {
    param([Parameter(Mandatory)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $path = [string]$process.Path
    $commandLine = ''
    $parentProcessId = 0
    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$cim.ExecutablePath }
        $commandLine = [string]$cim.CommandLine
        [int]::TryParse([string]$cim.ParentProcessId, [ref]$parentProcessId) | Out-Null
    } catch {
        $commandLine = ''
    }
    return [pscustomobject]@{
        Id = [int]$process.Id
        Name = [string]$process.Name
        Path = $path
        CommandLine = $commandLine
        StartTime = $process.StartTime
        ParentProcessId = $parentProcessId
    }
}

function Get-ActivationHeadroomCommandPattern {
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][int]$Port,
        [ValidateSet(1, 2)]
        [int]$ExpectedWorkers = 2,
        [string]$Target = 'http://127.0.0.1:57321'
    )
    $python = ConvertTo-ActivationFullPath -Path $PythonPath
    $launcher = ConvertTo-ActivationFullPath -Path $LauncherPath
    if ([string]::IsNullOrWhiteSpace($python) -or [string]::IsNullOrWhiteSpace($launcher)) { return '(?!)' }
    $python = [regex]::Escape($python.Replace('/', '\'))
    $launcher = [regex]::Escape($launcher.Replace('/', '\'))
    $targetPattern = [regex]::Escape($Target.TrimEnd('/')) + '(?:/)?'
    $segments = @(
        $python,
        $launcher,
        '(?:^|\s)proxy(?:\s|$)',
        ('(?:^|\s)--port\s+' + [regex]::Escape($Port.ToString()) + '(?:\s|$)'),
        ('(?:^|\s)--openai-api-url\s+' + $targetPattern + '(?:\s|$)'),
        ('(?:^|\s)--workers\s+' + [regex]::Escape($ExpectedWorkers.ToString()) + '(?:\s|$)')
    )
    return '(?is)' + ($segments -join '.*')
}

function Test-ActivationHeadroomSpawnIdentity {
    param(
        [AllowNull()][object]$Snapshot,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][int]$Port,
        [ValidateSet(1, 2)]
        [int]$ExpectedWorkers = 2,
        [string]$Target = 'http://127.0.0.1:57321',
        [AllowNull()][object]$NotBeforeUtc,
        [int]$BaselinePid = 0
    )
    if ($null -eq $Snapshot) { return $false }
    $pidValue = 0
    $pidProperty = Get-ActivationProperty -Object $Snapshot -Name 'Id'
    if ($null -eq $pidProperty) { $pidProperty = Get-ActivationProperty -Object $Snapshot -Name 'ProcessId' }
    if (-not [int]::TryParse([string]$pidProperty, [ref]$pidValue) -or $pidValue -le 0) { return $false }
    if ($BaselinePid -gt 0 -and $pidValue -eq $BaselinePid) { return $false }
    $name = ([string](Get-ActivationProperty -Object $Snapshot -Name 'Name')).ToLowerInvariant()
    $path = [string](Get-ActivationProperty -Object $Snapshot -Name 'Path')
    if ($name -notmatch '^python(?:\.exe)?$' -and $path -notmatch '(?i)(?:^|[\\/])python(?:\.exe)?$') { return $false }
    if ($null -ne $NotBeforeUtc) {
        try {
            $startedAt = ([DateTime]$Snapshot.StartTime).ToUniversalTime()
            $notBefore = ([DateTime]$NotBeforeUtc).ToUniversalTime()
            if ($startedAt -le $notBefore) { return $false }
        } catch { return $false }
    }
    $commandLine = [string](Get-ActivationProperty -Object $Snapshot -Name 'CommandLine')
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    return ($commandLine -match (Get-ActivationHeadroomCommandPattern -PythonPath $PythonPath -LauncherPath $LauncherPath -Port $Port -ExpectedWorkers $ExpectedWorkers -Target $Target))
}

function Get-ActivationHeadroomSpawnCandidates {
    param(
        [AllowNull()][object[]]$Processes,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][int]$Port,
        [ValidateSet(1, 2)]
        [int]$ExpectedWorkers = 2,
        [string]$Target = 'http://127.0.0.1:57321',
        [AllowNull()][object]$NotBeforeUtc,
        [int]$BaselinePid = 0
    )
    foreach ($process in @($Processes)) {
        if (Test-ActivationHeadroomSpawnIdentity -Snapshot $process -PythonPath $PythonPath -LauncherPath $LauncherPath -Port $Port -ExpectedWorkers $ExpectedWorkers -Target $Target -NotBeforeUtc $NotBeforeUtc -BaselinePid $BaselinePid) {
            $process
        }
    }
}

function Get-ActivationGatewayCommandPattern {
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][int]$Port
    )
    $python = ConvertTo-ActivationFullPath -Path $PythonPath
    $root = ConvertTo-ActivationFullPath -Path $ModuleRoot
    if ([string]::IsNullOrWhiteSpace($python) -or [string]::IsNullOrWhiteSpace($root)) { return '(?!)' }
    $segments = @(
        [regex]::Escape($python.Replace('/', '\')),
        '\s+-m\s+uvicorn(?=\s|$)',
        '\s+gateway:app(?=\s|$)',
        '\s+--host\s+127\.0\.0\.1(?=\s|$)',
        ('\s+--port\s+' + [regex]::Escape($Port.ToString()) + '(?=\s|$)'),
        ('\s+--app-dir\s+["'']?' + [regex]::Escape($root.Replace('/', '\')) + '["'']?(?=\s|$)')
    )
    return '(?is)' + ($segments -join '.*')
}

function Test-ActivationGatewaySpawnIdentity {
    param(
        [AllowNull()][object]$Snapshot,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][int]$Port,
        [AllowNull()][object]$NotBeforeUtc,
        [int]$BaselinePid = 0
    )
    if ($null -eq $Snapshot) { return $false }
    $pidValue = 0
    $pidProperty = Get-ActivationProperty -Object $Snapshot -Name 'Id'
    if ($null -eq $pidProperty) { $pidProperty = Get-ActivationProperty -Object $Snapshot -Name 'ProcessId' }
    if (-not [int]::TryParse([string]$pidProperty, [ref]$pidValue) -or $pidValue -le 0) { return $false }
    if ($BaselinePid -gt 0 -and $pidValue -eq $BaselinePid) { return $false }
    $name = ([string](Get-ActivationProperty -Object $Snapshot -Name 'Name')).ToLowerInvariant()
    if ($name -notmatch '^python(?:\.exe)?$') { return $false }
    $expectedPath = ConvertTo-ActivationFullPath -Path $PythonPath
    $actualPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty -Object $Snapshot -Name 'Path'))
    if ([string]::IsNullOrWhiteSpace($expectedPath) -or [string]::IsNullOrWhiteSpace($actualPath) -or -not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($null -ne $NotBeforeUtc) {
        try {
            if (([DateTime]$Snapshot.StartTime).ToUniversalTime() -le ([DateTime]$NotBeforeUtc).ToUniversalTime()) { return $false }
        } catch { return $false }
    }
    $commandLine = [string](Get-ActivationProperty -Object $Snapshot -Name 'CommandLine')
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    return ($commandLine -match (Get-ActivationGatewayCommandPattern -PythonPath $PythonPath -ModuleRoot $ModuleRoot -Port $Port))
}

function Get-ActivationGatewaySpawnCandidates {
    param(
        [AllowNull()][object[]]$Processes,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][int]$Port,
        [AllowNull()][object]$NotBeforeUtc,
        [int]$BaselinePid = 0
    )
    foreach ($process in @($Processes)) {
        if (Test-ActivationGatewaySpawnIdentity -Snapshot $process -PythonPath $PythonPath -ModuleRoot $ModuleRoot -Port $Port -NotBeforeUtc $NotBeforeUtc -BaselinePid $BaselinePid) {
            $process
        }
    }
}

function Resolve-ActivationStateReadPath {
    param(
        [Parameter(Mandatory)][string]$PortSpecificPath,
        [Parameter(Mandatory)][string]$LegacyPath,
        [Parameter(Mandatory)][int]$Port
    )
    if (Test-Path -LiteralPath $PortSpecificPath -PathType Leaf) {
        return [pscustomobject]@{
            Path = $PortSpecificPath
            Ready = $true
            ErrorCode = $null
            State = $null
            Source = 'port-specific'
        }
    }
    if (-not (Test-Path -LiteralPath $LegacyPath -PathType Leaf)) {
        return [pscustomobject]@{
            Path = $PortSpecificPath
            Ready = $false
            ErrorCode = 'old_headroom_state_missing'
            State = $null
            Source = 'missing'
        }
    }
    try {
        $legacyState = Get-Content -LiteralPath $LegacyPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            Path = $LegacyPath
            Ready = $false
            ErrorCode = 'old_headroom_state_invalid'
            State = $null
            Source = 'legacy-invalid'
        }
    }
    $legacyPort = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty -Object $legacyState -Name 'Port'), [ref]$legacyPort) -or $legacyPort -ne $Port) {
        return [pscustomobject]@{
            Path = $PortSpecificPath
            Ready = $false
            ErrorCode = 'old_headroom_state_port_mismatch'
            State = $null
            Source = 'legacy-port-mismatch'
        }
    }
    return [pscustomobject]@{
        Path = $LegacyPath
        Ready = $true
        ErrorCode = $null
        State = $legacyState
        Source = 'legacy'
    }
}

function New-ActivationHeadroomStateFromLive {
    param(
        [Parameter(Mandatory)][int]$ListenerPid,
        [Parameter(Mandatory)][object]$Listener,
        [Parameter(Mandatory)][object]$Parent,
        [Parameter(Mandatory)][int]$OldPort,
        [Parameter(Mandatory)][string]$ExpectedLauncherPath,
        [Parameter(Mandatory)][string]$ExpectedStartScriptPath,
        [Parameter(Mandatory)][string]$ExpectedPythonPath,
        [ValidateSet(1, 2)]
        [int]$ExpectedWorkers = 2,
        [string]$Target = 'http://127.0.0.1:57321',
        [string]$StatePath = ''
    )
    $fail = { param([string]$Code) return [pscustomobject]@{ Ready = $false; ErrorCode = $Code; State = $null } }
    if ($null -eq $Listener -or $null -eq $Parent) { return (& $fail 'old_headroom_live_identity_missing') }
    $listenerId = 0
    $parentId = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty -Object $Listener -Name 'Id'), [ref]$listenerId) -or $listenerId -ne $ListenerPid) { return (& $fail 'old_headroom_live_listener_pid_mismatch') }
    if (-not [int]::TryParse([string](Get-ActivationProperty -Object $Parent -Name 'Id'), [ref]$parentId) -or $parentId -le 0) { return (& $fail 'old_headroom_live_parent_missing') }
    $listenerParentId = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty -Object $Listener -Name 'ParentProcessId'), [ref]$listenerParentId) -or $listenerParentId -ne $parentId) { return (& $fail 'old_headroom_live_parent_pid_mismatch') }
    $listenerPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty -Object $Listener -Name 'Path'))
    $parentPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty -Object $Parent -Name 'Path'))
    $expectedPython = ConvertTo-ActivationFullPath -Path $ExpectedPythonPath
    if ([string]::IsNullOrWhiteSpace($listenerPath) -or $listenerPath -notmatch '(?i)(?:^|[\\/])python(?:\.exe)?$') { return (& $fail 'old_headroom_live_listener_interpreter_mismatch') }
    if ([string]::IsNullOrWhiteSpace($expectedPython) -or [string]::IsNullOrWhiteSpace($parentPath) -or -not $parentPath.Equals($expectedPython, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'old_headroom_live_parent_interpreter_mismatch') }
    if (-not (Test-Path -LiteralPath $ExpectedLauncherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ExpectedStartScriptPath -PathType Leaf)) { return (& $fail 'old_headroom_live_script_missing') }
    $commandPattern = Get-ActivationHeadroomCommandPattern -PythonPath $ExpectedPythonPath -LauncherPath $ExpectedLauncherPath -Port $OldPort -ExpectedWorkers $ExpectedWorkers -Target $Target
    $listenerCommand = [string](Get-ActivationProperty -Object $Listener -Name 'CommandLine')
    $parentCommand = [string](Get-ActivationProperty -Object $Parent -Name 'CommandLine')
    if ([string]::IsNullOrWhiteSpace($listenerCommand) -or $listenerCommand -notmatch $commandPattern) { return (& $fail 'old_headroom_live_commandline_mismatch') }
    if ([string]::IsNullOrWhiteSpace($parentCommand) -or $parentCommand -notmatch $commandPattern) { return (& $fail 'old_headroom_live_parent_commandline_mismatch') }
    try {
        $listenerStartedAt = ([DateTime]$Listener.StartTime).ToUniversalTime()
        $parentStartedAt = ([DateTime]$Parent.StartTime).ToUniversalTime()
        if ($listenerStartedAt -eq [DateTime]::MinValue -or $parentStartedAt -eq [DateTime]::MinValue -or $listenerStartedAt -lt $parentStartedAt) { return (& $fail 'old_headroom_live_start_time_invalid') }
        $state = [ordered]@{
            state_schema_version = 2
            route_contract_version = 2
            state_path = $StatePath
            state_role = 'active-headroom'
            http_mode = 'responses'
            wire_api = 'responses'
            supports_websockets = $false
            Pid = $ListenerPid
            ListenerPid = $ListenerPid
            ParentPid = $parentId
            Port = $OldPort
            Target = $Target
            StartedAt = $parentStartedAt.ToString('o')
            ListenerStartedAt = $listenerStartedAt.ToString('o')
            ListenerPath = $listenerPath
            ParentStartedAt = $parentStartedAt.ToString('o')
            ParentPath = $parentPath
            Workers = $ExpectedWorkers
        }
        return [pscustomobject]@{ Ready = $true; ErrorCode = $null; State = [pscustomobject]$state }
    }
    catch { return (& $fail 'old_headroom_live_start_time_invalid') }
}

function Test-ActivationStageFixedValues {
    param(
        [Parameter(Mandatory)][object]$Stage,
        [Parameter(Mandatory)][string]$ExpectedStatePath,
        [Parameter(Mandatory)][string]$ExpectedBackupMarkerPath,
        [string]$ExpectedLegacyStatePath = ''
    )
    $fail = { param([string]$Code) return [pscustomobject]@{ Ready = $false; ErrorCode = $Code } }
    $statePath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $Stage 'state_path'))
    $expectedState = ConvertTo-ActivationFullPath -Path $ExpectedStatePath
    $markerPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $Stage 'backup_marker_path'))
    $expectedMarker = ConvertTo-ActivationFullPath -Path $ExpectedBackupMarkerPath
    $stateMatches = (-not [string]::IsNullOrWhiteSpace($statePath) -and -not [string]::IsNullOrWhiteSpace($expectedState) -and $statePath.Equals($expectedState, [StringComparison]::OrdinalIgnoreCase))
    if (-not $stateMatches -and -not [string]::IsNullOrWhiteSpace($ExpectedLegacyStatePath)) {
        $expectedLegacy = ConvertTo-ActivationFullPath -Path $ExpectedLegacyStatePath
        $stateMatches = (-not [string]::IsNullOrWhiteSpace($expectedLegacy) -and $statePath.Equals($expectedLegacy, [StringComparison]::OrdinalIgnoreCase))
    }
    if (-not $stateMatches) { return (& $fail 'activation_stage_state_path_mismatch') }
    if ([string]::IsNullOrWhiteSpace($markerPath) -or [string]::IsNullOrWhiteSpace($expectedMarker) -or -not $markerPath.Equals($expectedMarker, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'activation_stage_backup_path_mismatch') }
    $ports = @(
        @{ Name = 'old_port'; Expected = 18787 },
        @{ Name = 'headroom_port'; Expected = 18789 },
        @{ Name = 'gateway_port'; Expected = 18787 },
        @{ Name = 'helper_port'; Expected = 57321 }
    )
    foreach ($port in $ports) {
        $value = 0
        if (-not [int]::TryParse([string](Get-ActivationProperty $Stage $port.Name), [ref]$value) -or $value -ne $port.Expected) { return (& $fail ("activation_stage_{0}_mismatch" -f $port.Name)) }
    }
    return [pscustomobject]@{ Ready = $true; ErrorCode = $null }
}

function Test-ActivationTrackedProcessIdentity {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$CommandPattern
    )
    $snapshot = Get-ActivationProcessSnapshot -ProcessId $ProcessId
    if ($null -eq $snapshot) { return [pscustomobject]@{ Ready = $false; ErrorCode = 'tracked_process_missing'; Snapshot = $null } }
    $actualPath = ConvertTo-ActivationFullPath -Path ([string]$snapshot.Path)
    $knownPath = ConvertTo-ActivationFullPath -Path $ExpectedPath
    if ([string]::IsNullOrWhiteSpace($actualPath) -or [string]::IsNullOrWhiteSpace($knownPath) -or -not $actualPath.Equals($knownPath, [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Ready = $false; ErrorCode = 'tracked_process_identity_mismatch'; Snapshot = $snapshot } }
    if ([string]::IsNullOrWhiteSpace([string]$snapshot.CommandLine) -or $snapshot.CommandLine -notmatch $CommandPattern) { return [pscustomobject]@{ Ready = $false; ErrorCode = 'tracked_process_commandline_mismatch'; Snapshot = $snapshot } }
    return [pscustomobject]@{ Ready = $true; ErrorCode = $null; Snapshot = $snapshot }
}

function Test-ActivationClientsExited {
    param([AllowNull()][object[]]$Processes)
    $active = @()
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        $name = ([string](Get-ActivationProperty -Object $process -Name 'Name')).ToLowerInvariant()
        if ($name -eq 'chatgpt.exe') {
            $commandLine = [string](Get-ActivationProperty -Object $process -Name 'CommandLine')
            if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine -notmatch '(?i)(?:^|\s)--type(?:=|\s)') {
                $active += $process
            }
            continue
        }
        if ($name -in @('codex-plus-plus-manager.exe', 'codex-plus-plus.exe', 'codex.exe')) {
            $active += $process
        }
    }
    if ($active.Count -gt 0) {
        return [pscustomobject]@{ Ready = $false; ErrorCode = 'client_processes_active'; Processes = $active }
    }
    return [pscustomobject]@{ Ready = $true; ErrorCode = $null; Processes = @() }
}

function Test-ActivationOldHeadroomIdentity {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][int]$ListenerPid,
        [AllowNull()][object]$Listener,
        [Parameter(Mandatory)][int]$OldPort,
        [Parameter(Mandatory)][string]$ExpectedLauncherPath,
        [Parameter(Mandatory)][string]$ExpectedStartScriptPath,
        [AllowNull()][object]$Parent,
        [string]$ExpectedPythonPath = 'C:\Users\ma dao\.headroom-venv\Scripts\python.exe',
        [ValidateSet(1, 2)]
        [int]$ExpectedWorkers = 2
    )
    $fail = { param([string]$Code) return [pscustomobject]@{ Ready = $false; ErrorCode = $Code } }
    if ($null -eq $State -or $null -eq $Listener -or $null -eq $Parent) { return (& $fail 'old_headroom_identity_missing') }
    $statePort = 0; $statePid = 0; $stateListenerPid = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty $State 'Port'), [ref]$statePort) -or $statePort -ne $OldPort) { return (& $fail 'old_headroom_state_port_mismatch') }
    if (-not [int]::TryParse([string](Get-ActivationProperty $State 'Pid'), [ref]$statePid) -or $statePid -ne $ListenerPid) { return (& $fail 'old_headroom_state_pid_mismatch') }
    if (-not [int]::TryParse([string](Get-ActivationProperty $State 'ListenerPid'), [ref]$stateListenerPid) -or $stateListenerPid -ne $ListenerPid) { return (& $fail 'old_headroom_state_listener_mismatch') }
    $stateParentPid = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty $State 'ParentPid'), [ref]$stateParentPid) -or $stateParentPid -le 0) { return (& $fail 'old_headroom_state_parent_missing') }
    $parentId = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty $Parent 'Id'), [ref]$parentId) -or $parentId -ne $stateParentPid) { return (& $fail 'old_headroom_parent_pid_mismatch') }
    $listenerPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $Listener 'Path'))
    $stateListenerPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $State 'ListenerPath'))
    if ([string]::IsNullOrWhiteSpace($listenerPath) -or [string]::IsNullOrWhiteSpace($stateListenerPath) -or -not $listenerPath.Equals($stateListenerPath, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'old_headroom_listener_path_mismatch') }
    if ($listenerPath -notmatch '(?i)(?:^|[\\/])python(?:\.exe)?$') { return (& $fail 'old_headroom_listener_interpreter_mismatch') }
    $expectedPython = ConvertTo-ActivationFullPath -Path $ExpectedPythonPath
    $parentPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $Parent 'Path'))
    $stateParentPath = ConvertTo-ActivationFullPath -Path ([string](Get-ActivationProperty $State 'ParentPath'))
    if ([string]::IsNullOrWhiteSpace($expectedPython) -or [string]::IsNullOrWhiteSpace($parentPath) -or -not $parentPath.Equals($expectedPython, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'old_headroom_parent_interpreter_mismatch') }
    if ([string]::IsNullOrWhiteSpace($stateParentPath) -or -not $stateParentPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 'old_headroom_state_parent_path_mismatch') }
    $listenerParentPid = 0
    if (-not [int]::TryParse([string](Get-ActivationProperty $Listener 'ParentProcessId'), [ref]$listenerParentPid) -or $listenerParentPid -ne $stateParentPid) { return (& $fail 'old_headroom_listener_parent_mismatch') }
    if (-not (Test-Path -LiteralPath $ExpectedLauncherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ExpectedStartScriptPath -PathType Leaf)) { return (& $fail 'old_headroom_script_missing') }
    $stateTarget = [string](Get-ActivationProperty $State 'Target')
    if ($stateTarget -ne 'http://127.0.0.1:57321') { return (& $fail 'old_headroom_state_target_mismatch') }
    $stateWorkers = 0
    $stateWorkersProperty = $State.PSObject.Properties['Workers']
    if ($null -eq $stateWorkersProperty -or -not [int]::TryParse([string]$stateWorkersProperty.Value, [ref]$stateWorkers) -or $stateWorkers -ne $ExpectedWorkers) { return (& $fail 'old_headroom_state_workers_mismatch') }
    $commandPattern = Get-ActivationHeadroomCommandPattern -PythonPath $ExpectedPythonPath -LauncherPath $ExpectedLauncherPath -Port $OldPort -ExpectedWorkers $ExpectedWorkers -Target $stateTarget
    $listenerCommand = [string](Get-ActivationProperty $Listener 'CommandLine')
    $parentCommand = [string](Get-ActivationProperty $Parent 'CommandLine')
    if ([string]::IsNullOrWhiteSpace($listenerCommand) -or $listenerCommand -notmatch $commandPattern) { return (& $fail 'old_headroom_commandline_mismatch') }
    if ([string]::IsNullOrWhiteSpace($parentCommand) -or $parentCommand -notmatch $commandPattern) { return (& $fail 'old_headroom_parent_commandline_mismatch') }
    try {
        $stateStartedAt = ConvertTo-ActivationUtcDateTime (Get-ActivationProperty $State 'StartedAt')
        $stateListenerStartedAt = ConvertTo-ActivationUtcDateTime (Get-ActivationProperty $State 'ListenerStartedAt')
        $stateParentStartedAt = ConvertTo-ActivationUtcDateTime (Get-ActivationProperty $State 'ParentStartedAt')
        $listenerStartedAt = ([DateTime]$Listener.StartTime).ToUniversalTime()
        $parentStartedAt = ([DateTime]$Parent.StartTime).ToUniversalTime()
        if ([Math]::Abs(($stateStartedAt - $parentStartedAt).TotalSeconds) -gt 10) { return (& $fail 'old_headroom_state_started_mismatch') }
        if ([Math]::Abs(($stateParentStartedAt - $parentStartedAt).TotalSeconds) -gt 10) { return (& $fail 'old_headroom_state_parent_started_mismatch') }
        if ([Math]::Abs(($stateListenerStartedAt - $listenerStartedAt).TotalSeconds) -gt 10) { return (& $fail 'old_headroom_state_listener_started_mismatch') }
    } catch { return (& $fail 'old_headroom_state_time_invalid') }
    return [pscustomobject]@{ Ready = $true; ErrorCode = $null; ListenerPid = $ListenerPid }
}

function Write-ActivationAtomicJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Document)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $temporary = Join-Path $directory ('.activation-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($Document | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}
