#Requires -Version 5.1
# 后台看门狗（2026-11-26）
# 登录 Windows 时由 HKCU Run -> auto_sync_hidden.vbs 启动并常驻；本地刷新服务也会每分钟确认它活着。
# 每 20 秒检查一次：
#   1) 同步脚本 / 本地刷新服务 / GitHub 发布脚本没在跑 -> 自动启动
#   2) 脚本文件比正在跑的进程新（代码改过）-> 先做语法检查，通过才自动重启换新代码；不通过就保留旧进程继续跑
#   3) 本地刷新服务 127.0.0.1:8788 连续 3 次 /ping 无响应 -> 强制重启
#   4) 同一个脚本跑了多份 -> 只留最早的一份
#   5) 看门狗自己的代码改过 -> 自动换成新版本
#   6) 防崩溃循环：同一脚本 10 分钟内最多重启 4 次
# 状态写 watchdog_status.json（网页经 8788/status 显示），日志写 watchdog.log。
$ErrorActionPreference = 'Continue'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Self = $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Dir 'watchdog.log'
$StatusFile = Join-Path $Dir 'watchdog_status.json'
$CheckSec = 20
$MyStart = Get-Date
$script:SelfBad = ''

# ---- 单实例 ----
$mutex = New-Object System.Threading.Mutex($false, 'Local\BinanceJiancangWatchdog')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

function Write-WdLog([string]$m) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
        }
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
        [System.IO.File]::AppendAllText($LogFile, ($line + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Test-ScriptSyntax([string]$path) {
    try {
        $tk = $null; $er = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$er)
        if ($er -and $er.Count -gt 0) { return ('line {0}: {1}' -f $er[0].Extent.StartLineNumber, $er[0].Message) }
        return ''
    } catch { return $_.Exception.Message }
}

function Start-Hidden([string]$psFile, [string]$logFile) {
    try {
        if ((Test-Path -LiteralPath $logFile) -and ((Get-Item -LiteralPath $logFile).Length -gt 5MB)) {
            Move-Item -LiteralPath $logFile -Destination ($logFile + '.old') -Force
        }
    } catch {}
    $arg = '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $psFile + '" >> "' + $logFile + '" 2>&1'
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $arg -WindowStyle Hidden -WorkingDirectory $Dir
}

function Test-RefreshPing {
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8788/ping')
        $req.Proxy = $null
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        $resp = $req.GetResponse()
        $ok = ([int]$resp.StatusCode -eq 200)
        $resp.Close()
        return $ok
    } catch { return $false }
}

$Managed = @(
    [ordered]@{ name = 'refresh_server.ps1';         log = 'refresh_server.log';      ping = $true },
    [ordered]@{ name = 'sync_positions.ps1';         log = 'sync_positions.log';      ping = $false },
    [ordered]@{ name = 'sync_subaccount.ps1';        log = 'sync_subaccount.log';     ping = $false },
    [ordered]@{ name = 'publish_live_to_github.ps1'; log = 'publish_live_stdout.log'; ping = $false }
)
$State = @{}
foreach ($m in $Managed) { $State[$m.name] = @{ starts = @(); pingFail = 0; badSyntaxFor = ''; last = '' } }

Write-WdLog ("watchdog started pid=$PID")
Start-Sleep -Seconds 3

while ($true) {
    # ---- 看门狗自身代码更新 ----
    try {
        $selfTime = (Get-Item -LiteralPath $Self).LastWriteTime
        if ($selfTime -gt $MyStart.AddSeconds(2)) {
            $serr = Test-ScriptSyntax $Self
            if (-not $serr) {
                Write-WdLog 'watchdog.ps1 updated -> relaunch'
                try { $mutex.ReleaseMutex() } catch {}
                Start-Hidden $Self (Join-Path $Dir 'watchdog_stdout.log')
                exit 0
            } elseif ($script:SelfBad -ne [string]$selfTime.Ticks) {
                $script:SelfBad = [string]$selfTime.Ticks
                Write-WdLog ('watchdog.ps1 syntax error, keep running old version: ' + $serr)
            }
        }
    } catch {}

    $procs = @()
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop) }
    catch { Write-WdLog ('process list failed: ' + $_.Exception.Message) }

    $items = New-Object System.Collections.ArrayList
    foreach ($m in $Managed) {
        $name = $m.name
        $st = $State[$name]
        $path = Join-Path $Dir $name
        $info = [ordered]@{ name = $name; running = $false; pid = 0; startedAt = ''; upToDate = $true; syntaxError = ''; action = '' }
        if (-not (Test-Path -LiteralPath $path)) { $info.action = 'missing'; [void]$items.Add($info); continue }

        # refresh_server 触发的 "-Once" 单次同步不算常驻进程
        $mine = @($procs | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($name) -and ($_.CommandLine -notmatch '\s-Once\b') -and $_.ProcessId -ne $PID } | Sort-Object CreationDate)
        if ($mine.Count -gt 1) {
            foreach ($x in $mine[1..($mine.Count - 1)]) {
                Write-WdLog ("$name duplicate pid=$($x.ProcessId) -> stop")
                Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue
            }
            $mine = @($mine[0])
        }

        $fileTime = (Get-Item -LiteralPath $path).LastWriteTime
        $reason = ''
        if ($mine.Count -eq 0) {
            $reason = 'not running'
        } else {
            $p = $mine[0]
            $info.running = $true
            $info.pid = [int]$p.ProcessId
            $info.startedAt = $p.CreationDate.ToString('yyyy-MM-ddTHH:mm:ss')
            if ($fileTime -gt $p.CreationDate.AddSeconds(2)) {
                $info.upToDate = $false
                $reason = 'code updated'
            } elseif ($m.ping) {
                if (Test-RefreshPing) { $st.pingFail = 0 }
                elseif (((Get-Date) - $p.CreationDate).TotalSeconds -gt 30) {
                    $st.pingFail = [int]$st.pingFail + 1
                    if ($st.pingFail -ge 3) { $reason = 'no response on 8788' }
                }
            }
        }

        if ($reason) {
            $err = Test-ScriptSyntax $path
            if ($err) {
                $info.syntaxError = $err
                $info.action = 'syntax error, kept old'
                if ($st.badSyntaxFor -ne [string]$fileTime.Ticks) {
                    $st.badSyntaxFor = [string]$fileTime.Ticks
                    Write-WdLog ("$name syntax error, not restarting: $err")
                }
            } else {
                $now = Get-Date
                $st.starts = @($st.starts | Where-Object { ($now - $_).TotalMinutes -lt 10 })
                if ($st.starts.Count -ge 4) {
                    $info.action = 'too many restarts, waiting'
                    if ($st.last -ne 'throttled') { Write-WdLog ("$name restarted 4 times in 10 min, pausing restarts") }
                    $st.last = 'throttled'
                } else {
                    foreach ($x in $mine) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
                    if ($mine.Count -gt 0) { Start-Sleep -Seconds 2 }
                    try {
                        Start-Hidden $path (Join-Path $Dir $m.log)
                        $st.starts = @($st.starts) + @($now)
                        $st.pingFail = 0
                        $st.last = 'started'
                        $info.action = "restarted: $reason"
                        Write-WdLog ("$name $reason -> started")
                    } catch {
                        $info.action = 'start failed'
                        Write-WdLog ("$name start failed: " + $_.Exception.Message)
                    }
                }
            }
        }
        [void]$items.Add($info)
    }

    try {
        $o = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); pid = $PID; items = $items }
        [System.IO.File]::WriteAllText($StatusFile, ($o | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    Start-Sleep -Seconds $CheckSec
}
