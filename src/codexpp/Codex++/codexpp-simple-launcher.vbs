Option Explicit

Dim shell, fso, projectRoot, rootLauncher, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Legacy compatibility entry: delegate to the repository root launcher so
' this shortcut cannot bypass broker/readiness/config gates.
projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))))
rootLauncher = fso.BuildPath(projectRoot, "scripts\Launch-HeadroomForCodexPP.vbs")
If Not fso.FileExists(rootLauncher) Then
    WScript.Echo "Root launcher missing: " & rootLauncher
    WScript.Quit 1
End If

command = QuoteArg("wscript.exe") & " //B //Nologo " & QuoteArg(rootLauncher)
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
