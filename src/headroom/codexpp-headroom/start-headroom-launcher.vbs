Option Explicit
Dim shell, fso, projectRoot, launcher, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))))
launcher = fso.BuildPath(projectRoot, "scripts\Launch-HeadroomForCodexPP.vbs")
If Not fso.FileExists(launcher) Then WScript.Quit 1
command = Chr(34) & "wscript.exe" & Chr(34) & " //B //Nologo " & Chr(34) & launcher & Chr(34)
WScript.Quit shell.Run(command, 0, True)
