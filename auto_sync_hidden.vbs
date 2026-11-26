Option Explicit
' Login auto-start (HKCU Run). Starts watchdog.ps1, which keeps the sync scripts, the local refresh
' service (127.0.0.1:8788) and the GitHub publisher running, and restarts them automatically when
' their code changes. If watchdog.ps1 is missing, falls back to starting the scripts directly.
' ASCII-only on purpose: non-ASCII comments break when WScript parses as ANSI/GBK.

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
  sh.Run "cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & psFile & """ >> """ & logFile & """ 2>&1", 0, False
End Sub

Dim ts, wd
Set ts = fso.CreateTextFile(dir & "\auto_sync_last_run.txt", True)
ts.WriteLine "checked at " & Now

If fso.FileExists(dir & "\watchdog.ps1") Then
  wd = IsRunning("powershell.exe", "watchdog.ps1")
  If Not wd Then StartHiddenPs dir & "\watchdog.ps1", dir & "\watchdog_stdout.log"
  ts.WriteLine "watchdog already running: " & wd
  ts.WriteLine "watchdog starts/updates everything else"
Else
  Dim s1, s2, s3, s4
  s1 = IsRunning("powershell.exe", "sync_positions.ps1")
  s2 = IsRunning("powershell.exe", "sync_subaccount.ps1")
  s3 = IsRunning("powershell.exe", "publish_live_to_github.ps1")
  s4 = IsRunning("powershell.exe", "refresh_server.ps1")
  If Not s1 Then StartHiddenPs dir & "\sync_positions.ps1", dir & "\sync_positions.log"
  If Not s2 Then StartHiddenPs dir & "\sync_subaccount.ps1", dir & "\sync_subaccount.log"
  If Not s3 Then StartHiddenPs dir & "\publish_live_to_github.ps1", dir & "\publish_live_stdout.log"
  If Not s4 Then StartHiddenPs dir & "\refresh_server.ps1", dir & "\refresh_server.log"
  ts.WriteLine "positions already running: " & s1
  ts.WriteLine "subaccount already running: " & s2
  ts.WriteLine "publisher already running: " & s3
  ts.WriteLine "refresh service already running: " & s4
End If
ts.Close
