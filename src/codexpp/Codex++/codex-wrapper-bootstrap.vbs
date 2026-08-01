Option Explicit
Dim shell, fso, projectRoot, runtimeRoot, runtimeStateRoot, runtimeLogRoot, gatePath, ensurePath, monitorPath, dashboardPath, routeKeeperPath, recorderPath, entryScriptPath, activeRunPath, recordPath, activationMarkerPath, exePath, logPath, startupResultPath, routeStatePath, routeWatchStatePath, routeReadySignalPath, codexHomePath, configPath, monitorPathMissing, dashboardPathMissing, routeKeeperPathMissing, exitCode, command, argumentString, launchError, runId, startupDetail, activationDetail, allowRelayPending, arg
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))))
runtimeRoot = fso.BuildPath(projectRoot, "runtime")
runtimeStateRoot = fso.BuildPath(runtimeRoot, "state")
runtimeLogRoot = fso.BuildPath(runtimeRoot, "logs")
gatePath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-startup-gate.ps1")
ensurePath = fso.BuildPath(projectRoot, "src\headroom\codexpp-headroom\ensure-headroom.ps1")
monitorPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-headroom-monitor.ps1")
dashboardPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-headroom-dashboard.ps1")
routeKeeperPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-route-keeper.ps1")
recorderPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\acceptance\codexpp-cold-start-recorder.ps1")
entryScriptPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\acceptance\codexpp-active-run-entry.ps1")
activeRunPath = fso.BuildPath(runtimeStateRoot, "acceptance\active-run.json")
exePath = "D:\program\Codex++\codex-plus-plus.exe"
codexHomePath = "C:\Users\ma dao\.codex-plus-plus-cli"
configPath = codexHomePath & "\config.toml"
logPath = fso.BuildPath(runtimeLogRoot, "codexpp-wrapper-bootstrap.log")
recordPath = fso.BuildPath(runtimeLogRoot, "codexpp-cold-start-events.jsonl")
activationMarkerPath = fso.BuildPath(runtimeStateRoot, "acceptance\headroom-activation-ready.json")
startupResultPath = fso.BuildPath(runtimeStateRoot, "startup-result.json")
routeStatePath = fso.BuildPath(runtimeStateRoot, "codexpp-route-state.json")
routeWatchStatePath = fso.BuildPath(runtimeStateRoot, "codexpp-route-watch.json")
routeReadySignalPath = fso.BuildPath(runtimeStateRoot, "codexpp-route-ready.signal")
runId = "wrapper-" & CStr(Year(Now())) & Right("0" & CStr(Month(Now())), 2) & Right("0" & CStr(Day(Now())), 2) & "-" & CStr(Int(Timer() * 1000))

Const ActivationMarkerMaxAgeSeconds = 180

Function QuoteArg(arg)
    QuoteArg = """" & arg & """"
End Function

Function JsonStringValue(document, fieldName)
    Dim re, matches, q
    q = Chr(34)
    Set re = New RegExp
    re.Global = False
    re.IgnoreCase = True
    re.Pattern = q & fieldName & q & "\s*:\s*" & q & "((\\.|[^" & q & "])*)" & q
    Set matches = re.Execute(document)
    If matches.Count = 0 Then
        JsonStringValue = ""
    Else
        JsonStringValue = matches(0).SubMatches(0)
    End If
End Function

Function JsonNumberValue(document, fieldName)
    Dim re, matches, q
    q = Chr(34)
    Set re = New RegExp
    re.Global = False
    re.IgnoreCase = True
    re.Pattern = q & fieldName & q & "\s*:\s*(-?[0-9]+)"
    Set matches = re.Execute(document)
    If matches.Count = 0 Then
        JsonNumberValue = ""
    Else
        JsonNumberValue = matches(0).SubMatches(0)
    End If
End Function

Function JsonUnescape(value)
    Dim q
    q = Chr(34)
    value = Replace(value, "\" & q, q)
    value = Replace(value, "\\", "\")
    value = Replace(value, "\r", vbCr)
    value = Replace(value, "\n", vbLf)
    value = Replace(value, "\t", vbTab)
    JsonUnescape = value
End Function

Function ReadActivationMarker(ByRef markerState, ByRef markerRunId, ByRef markerErrorCode, ByRef markerFresh)
    Dim stream, document, schema, generatedAt, ageSeconds, re
    markerState = ""
    markerRunId = ""
    markerErrorCode = ""
    markerFresh = False
    On Error Resume Next
    If Not fso.FileExists(activationMarkerPath) Then
        Err.Clear
        On Error GoTo 0
        ReadActivationMarker = "missing"
        Exit Function
    End If
    Set stream = fso.OpenTextFile(activationMarkerPath, 1, False, -1)
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        ReadActivationMarker = "stale"
        Exit Function
    End If
    document = stream.ReadAll
    stream.Close
    schema = JsonNumberValue(document, "schema_version")
    markerState = LCase(JsonStringValue(document, "state"))
    markerRunId = JsonUnescape(JsonStringValue(document, "run_id"))
    markerErrorCode = JsonUnescape(JsonStringValue(document, "error_code"))
    generatedAt = JsonStringValue(document, "generated_at_utc")
    Set re = New RegExp
    re.Global = False
    re.IgnoreCase = True
    re.Pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}.*Z$"
    If schema <> "1" Or markerRunId = "" Or Not re.Test(generatedAt) Or (markerState <> "waiting" And markerState <> "ready" And markerState <> "failed") Then
        Err.Clear
        On Error GoTo 0
        ReadActivationMarker = "stale"
        Exit Function
    End If
    ageSeconds = DateDiff("s", fso.GetFile(activationMarkerPath).DateLastModified, Now())
    If Err.Number <> 0 Or ageSeconds < 0 Or ageSeconds > ActivationMarkerMaxAgeSeconds Then
        Err.Clear
        On Error GoTo 0
        ReadActivationMarker = "stale"
        Exit Function
    End If
    markerFresh = True
    Err.Clear
    On Error GoTo 0
    ReadActivationMarker = markerState
End Function

Function WaitForActivationReady(ByRef detail)
    Dim markerState, markerRunId, markerErrorCode, markerFresh, deadline
    detail = ""
    markerState = ReadActivationMarker(markerState, markerRunId, markerErrorCode, markerFresh)
    If markerState = "missing" Or markerState = "stale" Then
        WaitForActivationReady = True
        Exit Function
    End If
    If markerState = "ready" Then
        WaitForActivationReady = True
        Exit Function
    End If
    If markerState = "failed" Then
        If markerErrorCode = "" Then markerErrorCode = "unknown"
        detail = "activation_marker_failed run_id=" & markerRunId & " error_code=" & markerErrorCode
        WaitForActivationReady = False
        Exit Function
    End If

    deadline = DateAdd("s", ActivationMarkerMaxAgeSeconds, Now())
    Do While Now() < deadline
        WScript.Sleep 1000
        markerState = ReadActivationMarker(markerState, markerRunId, markerErrorCode, markerFresh)
        If markerState = "missing" Or markerState = "stale" Then
            WaitForActivationReady = True
            Exit Function
        End If
        If markerState = "ready" Then
            WaitForActivationReady = True
            Exit Function
        End If
        If markerState = "failed" Then
            If markerErrorCode = "" Then markerErrorCode = "unknown"
            detail = "activation_marker_failed run_id=" & markerRunId & " error_code=" & markerErrorCode
            WaitForActivationReady = False
            Exit Function
        End If
    Loop
    If markerRunId = "" Then markerRunId = "unknown"
    detail = "activation_marker_timeout run_id=" & markerRunId & " timeout_seconds=" & CStr(ActivationMarkerMaxAgeSeconds)
    WaitForActivationReady = False
End Function

Function ReadStartupFailure(expectedRole, ByRef detail)
    Dim stream, document, schema, role, status, generatedAt, errorCode, reason, ageSeconds, re
    detail = ""
    On Error Resume Next
    If Not fso.FileExists(startupResultPath) Then
        Err.Clear
        On Error GoTo 0
        ReadStartupFailure = False
        Exit Function
    End If
    Set stream = fso.OpenTextFile(startupResultPath, 1, False, -1)
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        ReadStartupFailure = False
        Exit Function
    End If
    document = stream.ReadAll
    stream.Close
    schema = JsonNumberValue(document, "schema_version")
    role = JsonStringValue(document, "role")
    status = JsonStringValue(document, "status")
    generatedAt = JsonStringValue(document, "generated_at")
    errorCode = JsonStringValue(document, "error_code")
    reason = JsonStringValue(document, "reason")
    Set re = New RegExp
    re.Global = False
    re.IgnoreCase = True
    re.Pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}.*Z$"
    If schema <> "1" Or role <> expectedRole Or status <> "failed" Or Not re.Test(generatedAt) Or errorCode = "" Then
        Err.Clear
        On Error GoTo 0
        ReadStartupFailure = False
        Exit Function
    End If
    ageSeconds = DateDiff("s", fso.GetFile(startupResultPath).DateLastModified, Now())
    If Err.Number <> 0 Or ageSeconds < 0 Or ageSeconds > 300 Then
        Err.Clear
        On Error GoTo 0
        ReadStartupFailure = False
        Exit Function
    End If
    detail = "error_code=" & JsonUnescape(errorCode) & " reason=" & JsonUnescape(reason)
    Err.Clear
    On Error GoTo 0
    ReadStartupFailure = True
End Function

Sub AppendLog(message)
    Dim stream
    On Error Resume Next
    Set stream = fso.OpenTextFile(logPath, 8, True, 0)
    If Err.Number = 0 Then
        stream.WriteLine Now() & " " & message
        stream.Close
    End If
    Err.Clear
    On Error GoTo 0
End Sub

Sub RecordEntryEvent(entryName)
    Dim recorderCommand, recorderError
    If Not fso.FileExists(entryScriptPath) Then
        Call AppendLog("active-run entry script missing; using independent recorder (non-fatal): " & entryScriptPath)
        If fso.FileExists(recorderPath) Then
            recorderCommand = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(recorderPath) & " -RunId " & QuoteArg(runId) & " -EntryEvent " & QuoteArg(entryName) & " -Phase entry -OutputPath " & QuoteArg(recordPath)
            On Error Resume Next
            shell.Run recorderCommand, 0, False
            Err.Clear
            On Error GoTo 0
        End If
        Exit Sub
    End If
    recorderCommand = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(entryScriptPath) & " -ActiveRunPath " & QuoteArg(activeRunPath) & " -EntryEvent " & QuoteArg(entryName) & " -FallbackRunId " & QuoteArg(runId) & " -FallbackOutputPath " & QuoteArg(recordPath) & " -RecorderPath " & QuoteArg(recorderPath)
    On Error Resume Next
    shell.Run recorderCommand, 0, False
    recorderError = Err.Number
    If recorderError <> 0 Then Call AppendLog("acceptance recorder launch request failed: " & CStr(recorderError))
    Err.Clear
    On Error GoTo 0
End Sub

' The root launcher already gates broker, Headroom, Gateway, monitor and route
' readiness. The legacy activation marker belonged to the old C-drive
' cold-start task chain and must not block the project-root launch.

Call RecordEntryEvent("codex-wrapper-bootstrap")

monitorPathMissing = Not fso.FileExists(monitorPath)
dashboardPathMissing = Not fso.FileExists(dashboardPath)
routeKeeperPathMissing = Not fso.FileExists(routeKeeperPath)

If Not fso.FileExists(gatePath) Then
    Call AppendLog("startup gate missing: " & gatePath)
    shell.Popup "Codex++ startup gate script not found." & vbCrLf & "Expected at: " & gatePath, 0, "Codex++ launch failed", 16
    WScript.Quit 1
End If

If Not fso.FileExists(exePath) Then
    Call AppendLog("codex executable missing: " & exePath)
    shell.Popup "Codex++ executable not found." & vbCrLf & "Expected at: " & exePath, 0, "Codex++ launch failed", 16
    WScript.Quit 1
End If

If monitorPathMissing Then
    Call AppendLog("monitor script missing (non-fatal): " & monitorPath)
End If
If dashboardPathMissing Then
    Call AppendLog("dashboard script missing (non-fatal): " & dashboardPath)
End If
If routeKeeperPathMissing Then
    Call AppendLog("route keeper script missing (non-fatal): " & routeKeeperPath)
End If

' Start monitor before the gate so proxy cold starts can satisfy the
' gate's 18788/status contract. The monitor owns its mutex; a concurrent
' bootstrap therefore exits without creating a second monitor instance.
If Not monitorPathMissing Then
    command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(monitorPath) & " -RuntimeRoot " & QuoteArg(runtimeRoot) & " -Watch"
    On Error Resume Next
    shell.Run command, 0, False
    launchError = Err.Number
    If launchError <> 0 Then Call AppendLog("monitor launch request failed: " & CStr(launchError))
    Err.Clear
    On Error GoTo 0
    WScript.Sleep 750
End If

shell.CurrentDirectory = fso.GetParentFolderName(exePath)
shell.Environment("Process")("ELECTRON_DEFAULT_LOCALE") = "zh-CN"
shell.Environment("Process")("LANG") = "zh-CN"

' The startup gate owns route reconciliation, Headroom readiness, and the
' Codex++ launch. This bootstrapper must not create a second route keeper.
argumentString = ""
allowRelayPending = False
For Each arg In WScript.Arguments
    If LCase(CStr(arg)) = "-allowrelaypending" Then allowRelayPending = True
Next
If monitorPathMissing Then
    argumentString = argumentString & " -SkipMonitor"
End If
If dashboardPathMissing Then
    argumentString = argumentString & " -SkipDashboard"
End If
If allowRelayPending Then
    argumentString = argumentString & " -AllowRelayPending"
End If

command = "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & QuoteArg(gatePath) & " -Role codex -ExePath " & QuoteArg(exePath) & " -CodexHome " & QuoteArg(codexHomePath) & " -ConfigPath " & QuoteArg(configPath) & " -RuntimeRoot " & QuoteArg(runtimeRoot) & " -RouteKeeperPath " & QuoteArg(routeKeeperPath) & " -EnsureScript " & QuoteArg(ensurePath) & " -BrokerBaseUrl http://127.0.0.1:18790 -GatewayBaseUrl http://127.0.0.1:18787 -HeadroomBaseUrl http://127.0.0.1:18789 -MonitorBaseUrl http://127.0.0.1:18788 -RouteStatePath " & QuoteArg(routeStatePath) & " -RouteWatchStatePath " & QuoteArg(routeWatchStatePath) & " -RouteReadySignalPath " & QuoteArg(routeReadySignalPath) & " -AuditPath " & QuoteArg(logPath) & " -StartupResultPath " & QuoteArg(startupResultPath) & " -SkipEnsure" & argumentString
Call AppendLog("launching: " & command)
exitCode = shell.Run(command, 0, True)
Call AppendLog("startup gate exit code " & CStr(exitCode))

If exitCode <> 0 Then
    Dim message
    If ReadStartupFailure("codex", startupDetail) Then
        message = "Codex++ launch failed: " & startupDetail
    Else
        Select Case exitCode
            Case 2: message = "Codex++ launch failed (exit code 2): Headroom is not ready or not running."
            Case 3: message = "Codex++ launch failed (exit code 3): Route or process startup check failed."
            Case 4: message = "Codex++ launch failed (exit code 4): Headroom health check or relay config failed."
            Case 5: message = "Codex++ launch failed (exit code 5): Codex process exited or relay port unreachable."
            Case Else: message = "Codex++ launch failed (exit code " & CStr(exitCode) & "). See log for details."
        End Select
    End If
    Call AppendLog(message)
    shell.Popup message, 0, "Codex++ launch failed", 16
    WScript.Quit exitCode
End If

' Start status consumers only after the startup gate has confirmed the
' Codex++ process and Relay readiness. The monitor/dashboard each have their
' own mutex, so direct and manager paths cannot create duplicate instances.
If fso.FileExists(monitorPath) Then
    command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(monitorPath) & " -RuntimeRoot " & QuoteArg(runtimeRoot) & " -Watch"
    On Error Resume Next
    shell.Run command, 0, False
    launchError = Err.Number
    Err.Clear
    On Error GoTo 0
End If
If fso.FileExists(dashboardPath) Then
    command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(dashboardPath)
    On Error Resume Next
    shell.Run command, 0, False
    launchError = Err.Number
    Err.Clear
    On Error GoTo 0
End If
WScript.Quit 0
