[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'activation-lib.ps1')
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-ActivationTrue {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { $failures.Add($Name) }
}

function Assert-ActivationEqual {
    param([object]$Actual,[object]$Expected,[string]$Name)
    if ([string]$Actual -ne [string]$Expected) { $failures.Add("$Name (actual=$Actual expected=$Expected)") }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('headroom-activation-fixture-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
try {
    $startScriptContent = Get-Content -LiteralPath (Join-Path $root 'start-headroom.ps1') -Raw
    $ensureScriptContent = Get-Content -LiteralPath (Join-Path $root 'ensure-headroom.ps1') -Raw
    $launcherVbsContent = Get-Content -LiteralPath (Join-Path $root 'start-headroom-launcher.vbs') -Raw
    $legacyVbsContent = Get-Content -LiteralPath (Join-Path $root 'headroom-18787.vbs') -Raw
    Assert-ActivationTrue -Condition ($startScriptContent -match 'HEADROOM_KOMPRESS_TIME_BUDGET_SECONDS' -and $startScriptContent -match 'HEADROOM_PIPELINE_BREAKER_THRESHOLD' -and $startScriptContent -match 'HEADROOM_WS_FAIL_OPEN_ON_COMPRESSION_FAILURE') -Name 'direct Headroom launch configures kompress time budget, pipeline breaker, and WS fail-open'
    Assert-ActivationTrue -Condition ($startScriptContent -match '-Environment \$environment') -Name 'direct Headroom launch passes its environment contract to the child process'
    Assert-ActivationTrue -Condition ($startScriptContent -match 'HEADROOM_KOMPRESS_ONNX_INTRA_THREADS\s*=\s*\$kompressIntraThreads' -and $startScriptContent -match 'HEADROOM_KOMPRESS_ONNX_INTER_THREADS\s*=\s*''1''') -Name 'direct Headroom launch applies measured ONNX CPU thread tuning'
    Assert-ActivationTrue -Condition ($ensureScriptContent -notmatch 'HEADROOM_KOMPRESS_ONNX_INTRA_THREADS\s*=') -Name 'ensure Headroom launch leaves ONNX intra threads at the runtime default'
    Assert-ActivationTrue -Condition ($startScriptContent -match 'HEADROOM_KOMPRESS_MAX_CONCURRENT\s*=\s*''1''') -Name 'direct Headroom launch serializes Kompress requests'
    Assert-ActivationTrue -Condition ($ensureScriptContent -match 'HEADROOM_KOMPRESS_MAX_CONCURRENT\s*=\s*''1''') -Name 'ensure Headroom launch serializes Kompress requests'
    Assert-ActivationTrue -Condition ($startScriptContent -match '\[ValidateSet\(1, 2\)\]' -and $startScriptContent -match '\$Workers\s*=\s*1' -and $startScriptContent -match "'--workers'," -and $startScriptContent -match '\$Workers') -Name 'direct Headroom launch uses a stable single-worker contract by default'
    Assert-ActivationTrue -Condition ($ensureScriptContent -match '\$Workers\s*=\s*1' -and $ensureScriptContent -match '-Workers \$Workers') -Name 'ensure Headroom propagates the stable worker contract'
    Assert-ActivationTrue -Condition ($startScriptContent -notmatch '(?i)--no-optimize|--disable-kompress') -Name 'direct Headroom launch does not disable optimization'
    Assert-ActivationTrue -Condition ($launcherVbsContent -match 'Launch-HeadroomForCodexPP\.vbs' -and $launcherVbsContent -notmatch 'start-headroom\.ps1|headroom\.exe|--no-optimize|--disable-kompress') -Name 'legacy launcher VBS delegates only to the root entry'
    Assert-ActivationTrue -Condition ($legacyVbsContent -match 'Launch-HeadroomForCodexPP\.vbs' -and $legacyVbsContent -notmatch 'start-headroom\.ps1|headroom\.exe|--no-optimize|--disable-kompress') -Name 'legacy VBS delegates only to the root entry'

    $launcherPath = Join-Path $fixtureRoot 'headroom-launcher.py'
    $startPath = Join-Path $fixtureRoot 'start-headroom.ps1'
    $statePath = Join-Path $fixtureRoot 'headroom-state.json'
    [IO.File]::WriteAllText($statePath, '{"status":"fixture"}')
    $pythonPath = Join-Path $fixtureRoot '.headroom-venv\Scripts\python.exe'
    $listenerPath = 'D:\Python314\python.exe'
    [IO.File]::WriteAllText($launcherPath, 'fixture')
    [IO.File]::WriteAllText($startPath, 'fixture')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $pythonPath)) | Out-Null
    [IO.File]::WriteAllText($pythonPath, 'fixture')
    $parentStart = [DateTime]::UtcNow.AddSeconds(-2)
    $listenerStart = $parentStart.AddMilliseconds(100)
    $managedCommand = ('"{0}" "{1}" proxy --host 127.0.0.1 --port 18787 --no-http2 --openai-api-url http://127.0.0.1:57321 --no-telemetry --workers 2' -f $pythonPath, $launcherPath)
    $state = [pscustomobject]@{
        Port = 18787
        Pid = 700
        ListenerPid = 700
        ListenerPath = $listenerPath
        ParentPid = 701
        ParentPath = $pythonPath
        Workers = 2
        Target = 'http://127.0.0.1:57321'
        StartedAt = $parentStart.ToString('o')
        ParentStartedAt = $parentStart.ToString('o')
        ListenerStartedAt = $listenerStart.ToString('o')
    }
    $listener = [pscustomobject]@{
        Id = 700
        Path = $listenerPath
        CommandLine = $managedCommand
        StartTime = $listenerStart
        ParentProcessId = 701
    }
    $parent = [pscustomobject]@{
        Id = 701
        Name = 'python.exe'
        Path = $pythonPath
        CommandLine = $managedCommand
        StartTime = $parentStart
    }
    $selfSnapshot = Get-ActivationProcessSnapshot -ProcessId ([int]$PID)
    Assert-ActivationTrue -Condition ($selfSnapshot -and $selfSnapshot.Id -eq [int]$PID) -Name 'snapshot ProcessId parameter binds on real process'

    $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationTrue -Condition $identity.Ready -Name 'matching old Headroom identity is accepted'
    Assert-ActivationEqual -Actual $identity.ErrorCode -Expected $null -Name 'matching identity has no error'

    $badState = $state | Select-Object *
    $badState.Port = 18789
    $identity = Test-ActivationOldHeadroomIdentity -State $badState -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationEqual -Actual $identity.ErrorCode -Expected 'old_headroom_state_port_mismatch' -Name 'port mismatch is rejected'

    $portSpecificStatePath = Join-Path $fixtureRoot 'headroom-state-18787.json'
    $legacyMismatchPath = Join-Path $fixtureRoot 'legacy-mismatch.json'
    Write-ActivationAtomicJson -Path $legacyMismatchPath -Document ([ordered]@{ Port = 18789; Pid = 700; ListenerPid = 700; ParentPid = 701; Target = 'http://127.0.0.1:57321' })
    $selection = Resolve-ActivationStateReadPath -PortSpecificPath $portSpecificStatePath -LegacyPath $legacyMismatchPath -Port 18787
    Assert-ActivationTrue -Condition (-not $selection.Ready -and $selection.ErrorCode -eq 'old_headroom_state_port_mismatch' -and $selection.Path -eq $portSpecificStatePath -and $null -eq $selection.State) -Name 'legacy 18789 state is rejected and never selected for 18787'
    $legacyMatchPath = Join-Path $fixtureRoot 'legacy-match.json'
    Write-ActivationAtomicJson -Path $legacyMatchPath -Document ([ordered]@{ Port = 18787; Pid = 700; ListenerPid = 700; ParentPid = 701; Target = 'http://127.0.0.1:57321' })
    $selection = Resolve-ActivationStateReadPath -PortSpecificPath $portSpecificStatePath -LegacyPath $legacyMatchPath -Port 18787
    Assert-ActivationTrue -Condition ($selection.Ready -and $selection.Source -eq 'legacy' -and $selection.Path -eq $legacyMatchPath) -Name 'matching legacy state is readable only as compatibility input'

    $candidate = New-ActivationHeadroomStateFromLive -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath -StatePath $portSpecificStatePath
    Assert-ActivationTrue -Condition $candidate.Ready -Name 'live listener and parent can produce a port-specific state'
    $identity = Test-ActivationOldHeadroomIdentity -State $candidate.State -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationTrue -Condition $identity.Ready -Name 'synthesized state passes strict identity before write'
    Write-ActivationAtomicJson -Path $portSpecificStatePath -Document $candidate.State
    $writtenState = Get-Content -LiteralPath $portSpecificStatePath -Raw | ConvertFrom-Json
    $identity = Test-ActivationOldHeadroomIdentity -State $writtenState -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationTrue -Condition $identity.Ready -Name 'atomic port-specific state passes strict identity after reread'
    $badLive = $listener | Select-Object *
    $badLive.CommandLine = $badLive.CommandLine -replace '--port 18787', '--port 18789'
    $candidate = New-ActivationHeadroomStateFromLive -ListenerPid 700 -Listener $badLive -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath -StatePath $portSpecificStatePath
    Assert-ActivationEqual -Actual $candidate.ErrorCode -Expected 'old_headroom_live_commandline_mismatch' -Name 'live identity mismatch blocks state synthesis'

    $badCommand = $listener | Select-Object *
    $badCommand.CommandLine = 'python.exe proxy --host 127.0.0.1 --port 18787'
    $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid 700 -Listener $badCommand -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationEqual -Actual $identity.ErrorCode -Expected 'old_headroom_commandline_mismatch' -Name 'launcher mismatch is rejected'

    $staleState = $state | Select-Object *
    $staleState.StartedAt = $parentStart.AddMinutes(-5).ToString('o')
    $identity = Test-ActivationOldHeadroomIdentity -State $staleState -ListenerPid 700 -Listener $listener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationEqual -Actual $identity.ErrorCode -Expected 'old_headroom_state_started_mismatch' -Name 'stale state timestamp is rejected'
    $reusedListener = $listener | Select-Object *
    $reusedListener.StartTime = $listenerStart.AddMinutes(1)
    $identity = Test-ActivationOldHeadroomIdentity -State $state -ListenerPid 700 -Listener $reusedListener -Parent $parent -OldPort 18787 -ExpectedLauncherPath $launcherPath -ExpectedStartScriptPath $startPath -ExpectedPythonPath $pythonPath
    Assert-ActivationEqual -Actual $identity.ErrorCode -Expected 'old_headroom_state_listener_started_mismatch' -Name 'reused listener timestamp is rejected'

    $attempt = [DateTime]::UtcNow.AddSeconds(-5)
    $spawnCommand = ('"{0}" "{1}" proxy --host 127.0.0.1 --port 18789 --no-http2 --openai-api-url http://127.0.0.1:57321 --no-telemetry --workers 2' -f $pythonPath, $launcherPath)
    $healthTimeoutProcess = [pscustomobject]@{ Id = 711; Name = 'python.exe'; Path = $pythonPath; CommandLine = $spawnCommand; StartTime = [DateTime]::UtcNow }
    $stateWriteFailureProcess = [pscustomobject]@{ Id = 712; Name = 'python.exe'; Path = $pythonPath; CommandLine = $spawnCommand; StartTime = [DateTime]::UtcNow }
    $baselineProcess = [pscustomobject]@{ Id = 710; Name = 'python.exe'; Path = $pythonPath; CommandLine = $spawnCommand; StartTime = [DateTime]::UtcNow }
    $oldPortProcess = [pscustomobject]@{ Id = 713; Name = 'python.exe'; Path = $pythonPath; CommandLine = ($spawnCommand -replace '--port 18789', '--port 18787'); StartTime = [DateTime]::UtcNow }
    $wrongTargetProcess = [pscustomobject]@{ Id = 714; Name = 'python.exe'; Path = $pythonPath; CommandLine = ($spawnCommand -replace '57321', '57322'); StartTime = [DateTime]::UtcNow }
    $spawned = @(Get-ActivationHeadroomSpawnCandidates -Processes @($healthTimeoutProcess, $stateWriteFailureProcess, $baselineProcess, $oldPortProcess, $wrongTargetProcess) -PythonPath $pythonPath -LauncherPath $launcherPath -Port 18789 -Target 'http://127.0.0.1:57321' -NotBeforeUtc $attempt -BaselinePid 710)
    Assert-ActivationEqual -Actual (($spawned | ForEach-Object Id) -join ',') -Expected '711,712' -Name 'health/state failures select only new strict 18789 processes'
    $remainingAfterHealthCleanup = @($spawned | Where-Object { $_.Id -ne 711 })
    $remainingAfterStateCleanup = @($remainingAfterHealthCleanup | Where-Object { $_.Id -ne 712 })
    Assert-ActivationEqual -Actual (@(Get-ActivationHeadroomSpawnCandidates -Processes $remainingAfterStateCleanup -PythonPath $pythonPath -LauncherPath $launcherPath -Port 18789 -Target 'http://127.0.0.1:57321' -NotBeforeUtc $attempt -BaselinePid 710).Count) -Expected 0 -Name 'health timeout and state write failure leave no strict residuals'
    Assert-ActivationTrue -Condition ((Get-Content -LiteralPath (Join-Path $root 'start-headroom.ps1') -Raw) -match 'Write-HeadroomStartupState\s+-Status ''failed''') -Name 'start writes failure state for cleanup discovery'
    Assert-ActivationTrue -Condition ((Get-Content -LiteralPath (Join-Path $root 'start-headroom.ps1') -Raw) -match 'Stop-SpawnedHeadroomProcess') -Name 'start cleanup requires strict spawned identity'
    $startSource = Get-Content -LiteralPath (Join-Path $root 'start-headroom.ps1') -Raw
    $ensureSource = Get-Content -LiteralPath (Join-Path $root 'ensure-headroom.ps1') -Raw
    $stopSource = Get-Content -LiteralPath (Join-Path $root 'stop-headroom.ps1') -Raw
    $stageSource = Get-Content -LiteralPath (Join-Path $root 'stage-headroom.ps1') -Raw
    $activateSource = Get-Content -LiteralPath (Join-Path $root 'activate-headroom.ps1') -Raw
    $activationBootstrapProbe = [regex]::Match($activateSource, '(?s)function Wait-NewServices\s*\{.*?(?=function Stop-TrackedProcess)').Value
    Assert-ActivationTrue -Condition ($startSource -match '\$statePath\s*=\s*Join-Path \$RuntimeStateRoot \("headroom-state-\{0\}\.json" -f \$Port\)' -and $startSource -match '\$candidate\s*=\s*\$statePath' -and $startSource -match '\$candidate\s*=\s*\$legacyStatePath') -Name 'start always writes project-runtime port-specific state and only reads legacy fallback'
    Assert-ActivationTrue -Condition ($startSource -notmatch '\$statePath\s*=\s*if \(\$Port\s*-eq\s*18787\)') -Name 'start never selects legacy path for new writes'
    Assert-ActivationTrue -Condition ($ensureSource -match '\$statePath\s*=\s*Join-Path \$RuntimeStateRoot \("headroom-state-\{0\}\.json" -f \$Port\)' -and $ensureSource -match '\$candidate\s*=\s*\$legacyStatePath') -Name 'ensure uses project-runtime port-specific state with legacy read fallback'
    Assert-ActivationTrue -Condition ($stopSource -match '\$statePath\s*=\s*Join-Path \$RuntimeStateRoot \("headroom-state-\{0\}\.json" -f \$Port\)' -and $stopSource -match '\$candidate\s*=\s*\$legacyStatePath') -Name 'stop uses project-runtime port-specific state with legacy read fallback'
    Assert-ActivationTrue -Condition ($stageSource -match '\$statePath\s*=\s*Join-Path \$PSScriptRoot \("headroom-state-\{0\}\.json" -f \$OldPort\)' -and $stageSource -match 'New-ActivationHeadroomStateFromLive' -and $stageSource -match 'Write-ActivationAtomicJson\s+-Path \$statePath' -and $stageSource -notmatch '\$stateReadPath\s*=\s*\$legacyStatePath') -Name 'stage migrates missing old state from strict live identity only'
    Assert-ActivationTrue -Condition ($activateSource -match "headroom-state-18787\.json" -and $activateSource -match "headroom-state\.json") -Name 'activation validates port-specific state with legacy compatibility'
    Assert-ActivationTrue -Condition ($activationBootstrapProbe -match '/livez' -and $activationBootstrapProbe -notmatch '/health|Test-HelperAvailable') -Name 'activation waits only for process livez before shortcut starts helper'

    $clients = Test-ActivationClientsExited -Processes @(
        [pscustomobject]@{ Id = 901; Name = 'codex-plus-plus-manager.exe'; CommandLine = 'manager' },
        [pscustomobject]@{ Id = 902; Name = 'codex-plus-plus.exe'; CommandLine = 'codex-plus-plus' },
        [pscustomobject]@{ Id = 903; Name = 'CODEX.EXE'; CommandLine = 'codex' },
        [pscustomobject]@{ Id = 904; Name = 'pwsh.exe'; CommandLine = 'pwsh -File C:\Tools\ChatGPT.exe -- Codex' },
        [pscustomobject]@{ Id = 905; Name = 'ChatGPT.exe'; CommandLine = 'ChatGPT --type=crashpad-handler C:\Tools\Codex\resources' },
        [pscustomobject]@{ Id = 906; Name = 'ChatGPT.exe'; CommandLine = 'ChatGPT --remote-debugging-port=9229' },
        [pscustomobject]@{ Id = 907; Name = 'ChatGPT.exe'; CommandLine = 'ChatGPT --type=renderer --lang=zh-CN' },
        [pscustomobject]@{ Id = 908; Name = 'ChatGPT.exe'; CommandLine = $null }
    )
    Assert-ActivationTrue -Condition (-not $clients.Ready) -Name 'active clients block activation'
    Assert-ActivationEqual -Actual $clients.ErrorCode -Expected 'client_processes_active' -Name 'client block has stable code'
    Assert-ActivationEqual -Actual (@($clients.Processes | ForEach-Object Id) -join ',') -Expected '901,902,903,906,908' -Name 'only exact clients and the ChatGPT desktop host block activation'
    $clients = Test-ActivationClientsExited -Processes @()
    Assert-ActivationTrue -Condition $clients.Ready -Name 'empty client fixture permits activation'

    Assert-ActivationTrue -Condition (Test-ActivationPathWithinRoot -Path (Join-Path $fixtureRoot 'child.json') -Root $fixtureRoot) -Name 'stage path inside root accepted'
    Assert-ActivationTrue -Condition (-not (Test-ActivationPathWithinRoot -Path (Join-Path ([IO.Path]::GetTempPath()) 'outside.json') -Root $fixtureRoot)) -Name 'stage path outside root rejected'

    $markerPath = Join-Path $fixtureRoot 'BACKUP_COMPLETE.marker'
    [IO.File]::WriteAllText($markerPath, 'fixture')
    $validStage = [pscustomobject]@{
        state_path = $statePath
        backup_marker_path = $markerPath
        old_port = 18787
        headroom_port = 18789
        gateway_port = 18787
        helper_port = 57321
    }
    $stageCheck = Test-ActivationStageFixedValues -Stage $validStage -ExpectedStatePath $statePath -ExpectedBackupMarkerPath $markerPath
    Assert-ActivationTrue -Condition $stageCheck.Ready -Name 'fixed activation stage values accepted'
    $tamperedStage = $validStage | Select-Object *
    $tamperedStage.gateway_port = 19999
    $stageCheck = Test-ActivationStageFixedValues -Stage $tamperedStage -ExpectedStatePath $statePath -ExpectedBackupMarkerPath $markerPath
    Assert-ActivationEqual -Actual $stageCheck.ErrorCode -Expected 'activation_stage_gateway_port_mismatch' -Name 'gateway port tamper is rejected'
    $tamperedStage = $validStage | Select-Object *
    $tamperedStage.state_path = (Join-Path $fixtureRoot 'tampered-state.json')
    $stageCheck = Test-ActivationStageFixedValues -Stage $tamperedStage -ExpectedStatePath $statePath -ExpectedBackupMarkerPath $markerPath
    Assert-ActivationEqual -Actual $stageCheck.ErrorCode -Expected 'activation_stage_state_path_mismatch' -Name 'state path tamper is rejected'

    $gatewayCommand = ('"{0}" -m uvicorn gateway:app --host 127.0.0.1 --port 18787 --app-dir "{1}" --no-access-log' -f $pythonPath, $fixtureRoot)
    $gatewaySpawn = [pscustomobject]@{ Id = 801; Name = 'python.exe'; Path = $pythonPath; CommandLine = $gatewayCommand; StartTime = [DateTime]::UtcNow }
    $gatewayBaseline = [pscustomobject]@{ Id = 800; Name = 'python.exe'; Path = $pythonPath; CommandLine = $gatewayCommand; StartTime = [DateTime]::UtcNow }
    $gatewayWrongRoot = [pscustomobject]@{ Id = 802; Name = 'python.exe'; Path = $pythonPath; CommandLine = ($gatewayCommand -replace [regex]::Escape($fixtureRoot), [regex]::Escape((Join-Path $fixtureRoot 'other'))); StartTime = [DateTime]::UtcNow }
    $gatewayCandidates = @(Get-ActivationGatewaySpawnCandidates -Processes @($gatewaySpawn, $gatewayBaseline, $gatewayWrongRoot) -PythonPath $pythonPath -ModuleRoot $fixtureRoot -Port 18787 -NotBeforeUtc $attempt -BaselinePid 800)
    Assert-ActivationEqual -Actual (($gatewayCandidates | ForEach-Object Id) -join ',') -Expected '801' -Name 'gateway cleanup selects only new strict identity'
    $tracked = Test-ActivationTrackedProcessIdentity -ProcessId ([int]$PID) -ExpectedPath ([string]$selfSnapshot.Path) -CommandPattern '.*'
    Assert-ActivationTrue -Condition $tracked.Ready -Name 'tracked process dry identity binds ProcessId'

    Write-ActivationAtomicJson -Path $statePath -Document ([ordered]@{ status = 'fixture'; error_code = $null })
    Assert-ActivationTrue -Condition (Test-Path -LiteralPath $statePath -PathType Leaf) -Name 'atomic state write creates fixture state'
    $stateDocument = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ActivationEqual -Actual $stateDocument.status -Expected 'fixture' -Name 'atomic state content is readable'

    foreach ($scriptName in @('start-headroom.ps1','ensure-headroom.ps1')) {
        $scriptText = Get-Content -LiteralPath (Join-Path $root $scriptName) -Raw
        Assert-ActivationTrue -Condition ($scriptText -match 'kompress_dependencies_unavailable' -and $scriptText -match 'kompress_broker_not_ready') -Name "$scriptName fails closed before proxy startup when Kompress is not ready"
        Assert-ActivationTrue -Condition ($scriptText -notmatch 'continuing with deferred compression') -Name "$scriptName does not accept deferred Kompress readiness"
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output 'activation_fixture_tests_ok'
