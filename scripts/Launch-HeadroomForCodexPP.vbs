Option Explicit

Dim shell, shellApplication, fso, projectRoot, startScript, pwshPath, arguments
Set shell = CreateObject("WScript.Shell")
Set shellApplication = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

' Resolve the repository from this file so the launcher is portable and does
' not depend on a copied C:\ deployment.  The only public entry point is the
' PowerShell start script in the repository root.
projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
startScript = fso.BuildPath(projectRoot, "scripts\Start-HeadroomForCodexPP.ps1")
pwshPath = "pwsh.exe"

If Not fso.FileExists(startScript) Then
    WScript.Echo "Headroom start script not found: " & startScript
    WScript.Quit 1
End If

shell.CurrentDirectory = projectRoot
arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(startScript) & " -Workers 1"

' Codex++ Manager and the client may already run at high integrity. Launch the
' single managed entry at the same level so it can verify and gracefully
' restart only the two exact executable paths. The PowerShell gate still asks
' once before replacing a direct process.
On Error Resume Next
shellApplication.ShellExecute pwshPath, arguments, projectRoot, "runas", 0
If Err.Number <> 0 Then
    WScript.Echo "Unable to start Headroom with administrator rights."
    WScript.Quit 1
End If
On Error GoTo 0
WScript.Quit 0

Function QuoteArg(value)
    ' The current paths contain spaces; double embedded quotes defensively so
    ' fixture tests can exercise the same command construction.
    QuoteArg = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
