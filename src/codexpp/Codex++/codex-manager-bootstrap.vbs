Option Explicit
Dim shell, fso, projectRoot, runtimeRoot, runtimeStateRoot, runtimeLogRoot, gatePath, monitorPath, dashboardPath, routeKeeperPath, recorderPath, entryScriptPath, activeRunPath, recordPath, exePath, logPath, restoreScript, startupResultPath, routeStatePath, routeWatchStatePath, routeReadySignalPath, codexHomePath, configPath, monitorPathMissing, dashboardPathMissing, routeKeeperPathMissing, exitCode, command, argumentString, launchError, runId, startupDetail
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))))
runtimeRoot = fso.BuildPath(projectRoot, "runtime")
runtimeStateRoot = fso.BuildPath(runtimeRoot, "state")
runtimeLogRoot = fso.BuildPath(runtimeRoot, "logs")
gatePath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-startup-gate.ps1")
monitorPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-headroom-monitor.ps1")
dashboardPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-headroom-dashboard.ps1")
routeKeeperPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\codexpp-route-keeper.ps1")
recorderPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\acceptance\codexpp-cold-start-recorder.ps1")
entryScriptPath = fso.BuildPath(projectRoot, "src\codexpp\Codex++\acceptance\codexpp-active-run-entry.ps1")
activeRunPath = fso.BuildPath(runtimeStateRoot, "acceptance\active-run.json")
exePath = "D:\program\Codex++\codex-plus-plus-manager.exe"
codexHomePath = "C:\Users\ma dao\.codex-plus-plus-cli"
configPath = codexHomePath & "\config.toml"
restoreScript = fso.BuildPath(projectRoot, "src\codexpp\Codex++\restore-manager-window.ps1")
logPath = fso.BuildPath(runtimeLogRoot, "codexpp-manager-bootstrap.log")
recordPath = fso.BuildPath(runtimeLogRoot, "codexpp-cold-start-events.jsonl")
startupResultPath = fso.BuildPath(runtimeStateRoot, "startup-result.json")
routeStatePath = fso.BuildPath(runtimeStateRoot, "codexpp-route-state.json")
routeWatchStatePath = fso.BuildPath(runtimeStateRoot, "codexpp-route-watch.json")
routeReadySignalPath = fso.BuildPath(runtimeStateRoot, "codexpp-route-ready.signal")
runId = "manager-" & CStr(Year(Now())) & Right("0" & CStr(Month(Now())), 2) & Right("0" & CStr(Day(Now())), 2) & "-" & CStr(Int(Timer() * 1000))

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

Call RecordEntryEvent("codex-manager-bootstrap")

monitorPathMissing = Not fso.FileExists(monitorPath)
dashboardPathMissing = Not fso.FileExists(dashboardPath)
routeKeeperPathMissing = Not fso.FileExists(routeKeeperPath)

If Not fso.FileExists(gatePath) Then
    Call AppendLog("startup gate missing: " & gatePath)
    shell.Popup "Codex++ Manager startup gate script not found.", 0, "Codex++ launch failed", 16
    WScript.Quit 1
End If
If Not fso.FileExists(exePath) Then
    Call AppendLog("manager executable missing: " & exePath)
    shell.Popup "Codex++ Manager executable not found.", 0, "Codex++ launch failed", 16
    WScript.Quit 1
End If
If Not fso.FileExists(restoreScript) Then
    Call AppendLog("restore script missing: " & restoreScript)
    shell.Popup "Codex++ Manager restore script not found.", 0, "Codex++ launch failed", 16
    WScript.Quit 1
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

' The startup gate owns the preflight and launches Manager only after broker,
' Headroom, Gateway, monitor, route-state and config-hash checks pass.  The
' -SkipEnsure flag is intentional: the root entry already owns service
' lifecycle and this step must not create a second ensure chain.
command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(gatePath) & " -Role manager -ExePath " & QuoteArg(exePath) & " -CodexHome " & QuoteArg(codexHomePath) & " -ConfigPath " & QuoteArg(configPath) & " -RuntimeRoot " & QuoteArg(runtimeRoot) & " -RouteKeeperPath " & QuoteArg(routeKeeperPath) & " -BrokerBaseUrl http://127.0.0.1:18790 -GatewayBaseUrl http://127.0.0.1:18787 -HeadroomBaseUrl http://127.0.0.1:18789 -MonitorBaseUrl http://127.0.0.1:18788 -RouteStatePath " & QuoteArg(routeStatePath) & " -RouteWatchStatePath " & QuoteArg(routeWatchStatePath) & " -RouteReadySignalPath " & QuoteArg(routeReadySignalPath) & " -AuditPath " & QuoteArg(logPath) & " -StartupResultPath " & QuoteArg(startupResultPath) & " -SkipEnsure -AllowRelayPending"
Call AppendLog("starting manager readiness check: " & command)
exitCode = shell.Run(command, 0, True)
Call AppendLog("manager readiness exit code " & CStr(exitCode))

If exitCode <> 0 Then
    Dim message
    If ReadStartupFailure("manager", startupDetail) Then
        message = "Codex++ Manager self-check failed: " & startupDetail
    Else
        Select Case exitCode
            Case 2: message = "Codex++ Manager self-check failed (code 2): Headroom is not ready."
            Case 3: message = "Codex++ Manager self-check failed (code 3): route or process contract failed."
            Case 4: message = "Codex++ Manager self-check failed (code 4): Headroom health or relay setup failed."
            Case 5: message = "Codex++ Manager self-check failed (code 5): relay port is unreachable."
            Case Else: message = "Codex++ Manager self-check failed (code " & CStr(exitCode) & "). Check the log."
        End Select
    End If
    Call AppendLog(message)
    shell.Popup message, 0, "Codex++ launch failed", 16
    WScript.Quit exitCode
End If

' Restore the manager window that was moved off-screen
command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(restoreScript)
On Error Resume Next
shell.Run command, 0, False
Err.Clear
On Error GoTo 0

' Start status consumers only after the startup gate has confirmed the
' Codex++ process and Relay readiness.
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

' Start the restore script in watch mode (keeps manager window on screen)
command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(restoreScript) & " -Watch"
On Error Resume Next
shell.Run command, 0, False
Err.Clear
On Error GoTo 0
WScript.Quit 0
