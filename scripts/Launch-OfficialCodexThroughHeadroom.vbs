Option Explicit

Dim shell, fso, projectRoot, scriptPath, args
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
scriptPath = fso.BuildPath(projectRoot, "scripts\Start-OfficialCodexThroughHeadroom.ps1")
If Not fso.FileExists(scriptPath) Then
    WScript.Echo "Official route A script not found: " & scriptPath
    WScript.Quit 1
End If

shell.CurrentDirectory = projectRoot
args = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " & QuoteArg(scriptPath)
shell.Run "pwsh.exe " & args, 1, False
WScript.Quit 0

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
