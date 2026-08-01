Option Explicit

Dim shell, fso, dashboardPath, command, launchError
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

dashboardPath = "C:\Users\ma dao\AppData\Roaming\Codex++\codexpp-headroom-dashboard.ps1"
If Not fso.FileExists(dashboardPath) Then WScript.Quit 1

command = "pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & QuoteArg(dashboardPath)
On Error Resume Next
shell.Run command, 0, False
launchError = Err.Number
Err.Clear
On Error GoTo 0

If launchError <> 0 Then WScript.Quit 1
WScript.Quit 0

Function QuoteArg(value)
    Dim character, backslashes, position, result
    result = Chr(34)
    backslashes = 0

    For position = 1 To Len(value)
        character = Mid(value, position, 1)
        If character = "\" Then
            backslashes = backslashes + 1
        ElseIf character = Chr(34) Then
            If backslashes > 0 Then result = result & String(backslashes * 2, "\")
            result = result & "\" & Chr(34)
            backslashes = 0
        Else
            If backslashes > 0 Then result = result & String(backslashes, "\")
            result = result & character
            backslashes = 0
        End If
    Next

    If backslashes > 0 Then result = result & String(backslashes * 2, "\")
    QuoteArg = result & Chr(34)
End Function
