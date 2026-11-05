Option Explicit
' Auto-start Binance position sync (main + subaccount). Direct fapi, no relay/node.
' ASCII-only on purpose: non-ASCII comments break when WScript parses as ANSI/GBK.
' Skips anything already running (guard by command-line marker).

Dim sh, fso, dir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

Function IsRunning(processName, marker)
  Dim wmi, items, p
  IsRunning = False
  On Error Resume Next
  Set wmi = GetObject("winmgmts:\\.\root\cimv2")
  Set items = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='" & processName & "'")
  For Each p In items
    If InStr(p.CommandLine, marker) > 0 Then
      IsRunning = True
      Exit For
    End If
  Next
  On Error GoTo 0
End Function

Sub StartHiddenPs(psFile, logFile)
  sh.CurrentDirectory = dir
  sh.Run "cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & psFile & """ > """ & logFile & """ 2>&1", 0, False
End Sub

Dim started1, started2
started1 = IsRunning("powershell.exe", "sync_positions.ps1")
started2 = IsRunning("powershell.exe", "sync_subaccount.ps1")

If Not started1 Then StartHiddenPs dir & "\sync_positions.ps1", dir & "\sync_positions.log"
If Not started2 Then StartHiddenPs dir & "\sync_subaccount.ps1", dir & "\sync_subaccount.log"

Dim ts
Set ts = fso.CreateTextFile(dir & "\auto_sync_last_run.txt", True)
ts.WriteLine "checked at " & Now
ts.WriteLine "positions already running: " & started1
ts.WriteLine "subaccount already running: " & started2
ts.Close