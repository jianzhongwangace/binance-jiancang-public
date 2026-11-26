#Requires -Version 5.1
# 本地刷新服务：给 file:// 打开的页面提供「一键刷新」能力（浏览器不能直接执行本地脚本）。
# 监听 127.0.0.1:8788，用 TcpListener 手写极简 HTTP，避免 HttpListener 需要的 URL ACL 权限。
#   GET /ping     服务探活
#   GET /refresh  触发一次主账户+子账户同步（异步，立即返回；币安封禁期间拒绝）
#   GET /status   查询是否在跑 / 上次结果 / 数据文件时间 / 封禁状态
#   GET /fapi/v1/premiumIndex  行情代理：由本机走代理代拉币安标记价
#   GET /fapi/v1/klines        K线代理：本机走代理代拉币安合约 K 线
#   GET /api/v3/klines         同上，现货 K 线
#
# 2026-11-26 修复：
#   1) 读请求加超时：以前浏览器开了连接却不发数据（预连接）时，ReadLine 会永久阻塞，整个服务卡死。
#   2) 上游超时从 10~12 秒降到 6 秒，失败结果短暂缓存，避免请求排队把服务拖死。
#   3) 服务器时间偏移缓存 10 分钟，不再每次拉标记价都额外打两次 /fapi/v1/time。
#   4) 代理不再只认系统代理开关：开关关掉时也会用注册表里的代理地址/常见本机代理端口。
#   5) 币安 418/429：读取 binance_ban.json（同步脚本共用），封禁期间不再访问币安，
#      直接给页面返回 429 + Retry-After，避免把封禁越拉越长。
#   6) 内部日志改写 refresh_server_events.log（refresh_server.log 被启动脚本的 > 重定向占用）。
param(
    [int]$Port = 8788
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir 'refresh_server_events.log'
$BanFile = Join-Path $ScriptDir 'binance_ban.json'
$script:Job = $null
$script:LastResult = $null
$script:LastError = ''
$script:QuoteCache = ''
$script:QuoteCacheAt = [int64]0
$script:UpCache = @{}
$script:UpFail = @{}
$script:BanUntilMs = [int64]0
$script:BanCheckedAt = [int64]0
$script:RlBackoffSec = 0
$script:SrvProxy = $null
$script:SrvProxyAt = [int64]0
$script:SrvTimeOffset = $null
$script:SrvTimeAt = [int64]0

function Get-NowMs { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Write-SrvLog([string]$m) {
    try {
        $line = ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m)
        [System.IO.File]::AppendAllText($LogFile, ($line + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Get-LiveStamp {
    $out = [ordered]@{}
    foreach ($n in @('positions_live.json', 'subaccount_live.json')) {
        $p = Join-Path $ScriptDir $n
        $t = ''
        $e = ''
        try {
            $o = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json
            $t = [string]$o.updatedAt
            $e = [string]$o.error
        } catch {}
        $out[$n] = [ordered]@{ updatedAt = $t; error = $e }
    }
    return $out
}

# ---- 币安封禁状态（与 sync_positions / sync_subaccount 共用 binance_ban.json）----
function Format-BanTime([int64]$ms) {
    return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToLocalTime().ToString('HH:mm:ss')
}
function Get-BanUntilMs {
    $now = Get-NowMs
    if (($now - $script:BanCheckedAt) -ge 2000) {
        $script:BanCheckedAt = $now
        try {
            if (Test-Path -LiteralPath $BanFile) {
                $b = Get-Content -LiteralPath $BanFile -Raw -ErrorAction Stop | ConvertFrom-Json
                $f = [int64]$b.untilMs
                if ($f -gt $script:BanUntilMs) { $script:BanUntilMs = $f }
            }
        } catch {}
    }
    return [int64]$script:BanUntilMs
}
function Test-Banned { return ((Get-BanUntilMs) -gt (Get-NowMs)) }
function Register-Ban($err, [int]$code) {
    $now = Get-NowMs
    $retry = 0; $body = ''
    try {
        $ra = [string]$err.Exception.Response.Headers['Retry-After']
        if ($ra) { [void][int]::TryParse($ra, [ref]$retry) }
    } catch {}
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = [string]$err.ErrorDetails.Message } } catch {}
    $until = [int64]0
    if ($body -match 'banned until (\d{12,})') { $until = [int64]$Matches[1] }
    if ($retry -gt 0) { $until = [Math]::Max($until, $now + [int64]$retry * 1000) }
    if ($until -le $now) {
        $base = 60
        if ($code -eq 418) { $base = 120 }
        if ($script:RlBackoffSec -lt $base) { $script:RlBackoffSec = $base }
        else { $script:RlBackoffSec = [Math]::Min(1800, [int]($script:RlBackoffSec * 2)) }
        $until = $now + [int64]$script:RlBackoffSec * 1000
    }
    $until = $until + 3000
    $script:BanCheckedAt = 0
    if ($until -gt (Get-BanUntilMs)) {
        $script:BanUntilMs = $until
        try {
            $o = [ordered]@{ untilMs = $until; until = (Format-BanTime $until); code = $code; source = 'refresh_server'; at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); detail = $body }
            [System.IO.File]::WriteAllText($BanFile, ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
    Write-SrvLog ('RATELIMIT HTTP {0} -> pause binance until {1} {2}' -f $code, (Format-BanTime (Get-BanUntilMs)), $body)
}

# ---- 代理：系统代理开关关掉时也能找到本机代理（只做本地 TCP 探测，不打币安）----
function Test-LocalPort([string]$hostName, [int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($hostName, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(300)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch {
        return $false
    } finally {
        try { $c.Close() } catch {}
    }
}
function Get-SrvProxy {
    $now = Get-NowMs
    if (($now - $script:SrvProxyAt) -lt 300000) { return $script:SrvProxy }
    $script:SrvProxyAt = $now
    $script:SrvProxy = $null
    $cands = New-Object System.Collections.Generic.List[string]
    try {
        $r = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($r.ProxyServer) {
            $v = [string]$r.ProxyServer
            if ($v -match '=') {
                $hit = ($v -split ';') | Where-Object { $_ -match '^\s*https=' } | Select-Object -First 1
                if (-not $hit) { $hit = ($v -split ';') | Where-Object { $_ -match '^\s*http=' } | Select-Object -First 1 }
                if ($hit) { $v = ($hit -split '=', 2)[1] } else { $v = '' }
            } else {
                $v = ($v -split ';')[0]
            }
            $v = $v.Trim()
            if ($v) {
                if ($v -notmatch '^https?://') { $v = 'http://' + $v }
                $cands.Add($v)
            }
        }
    } catch {}
    foreach ($p in @('7897', '7890', '15236', '7899', '10809', '1080', '10916', '20171')) { $cands.Add("http://127.0.0.1:$p") }
    foreach ($c in $cands) {
        try {
            $u = [uri]$c
            if (Test-LocalPort $u.Host $u.Port) { $script:SrvProxy = $u; break }
        } catch {}
    }
    return $script:SrvProxy
}

# ---- 统一的上游请求：封禁期间不出网；418/429 登记封禁 ----
function Invoke-Upstream([string]$url, [int]$timeoutSec) {
    $res = @{ ok = $false; body = ''; status = 0; banned = $false }
    if (Test-Banned) { $res.banned = $true; $res.status = 429; return $res }
    $a = @{ Uri = $url; TimeoutSec = $timeoutSec; UseBasicParsing = $true }
    $px = Get-SrvProxy
    if ($px) { $a['Proxy'] = $px }
    try {
        $resp = Invoke-WebRequest @a
        $res.status = [int]$resp.StatusCode
        $res.body = [string]$resp.Content
        $trimmed = $res.body.TrimStart()
        # 只接受 JSON（数组或对象）；上游返回 HTML 错误页时不能当成功
        $res.ok = ($res.status -eq 200 -and ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{')))
    } catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
        $res.status = $code
        if ($code -eq 418 -or $code -eq 429) {
            Register-Ban $_ $code
            $res.banned = $true
        } else {
            $script:SrvProxyAt = [int64]0   # 非限流错误：下次重新找代理
        }
        Write-SrvLog ('UPSTREAM fail {0} : {1}' -f $url, $_.Exception.Message)
    }
    return $res
}

# 币安服务器时间（缓存偏移 10 分钟）。页面 acceptQuote 需要快照 time 与 WS 推送同一时钟基准，
# 本机时钟偏快 ~1.6s，用本机时间会让 WS 实时推送被当成旧数据丢弃。
function Get-BinanceNowMs {
    $now = Get-NowMs
    if ($null -ne $script:SrvTimeOffset -and ($now - $script:SrvTimeAt) -lt 600000) { return ($now + [int64]$script:SrvTimeOffset) }
    $r = Invoke-Upstream 'https://fapi.binance.com/fapi/v1/time' 5
    if ($r.ok) {
        try {
            $v = [int64](($r.body | ConvertFrom-Json).serverTime)
            if ($v -gt 0) { $script:SrvTimeOffset = $v - $now; $script:SrvTimeAt = $now; return $v }
        } catch {}
    }
    return ($now - 2000)
}

# 行情代理：返回与 /fapi/v1/premiumIndex 同构的 JSON 数组；3 秒缓存。
function Get-PremiumIndexJson {
    $now = Get-NowMs
    if ($script:QuoteCache -and ($now - $script:QuoteCacheAt) -lt 3000) { return @{ ok = $true; body = $script:QuoteCache; banned = $false } }
    if (Test-Banned) { return @{ ok = $false; banned = $true } }
    $serverTime = Get-BinanceNowMs
    foreach ($u in @('https://fapi.binance.com/fapi/v1/premiumIndex', 'https://www.binance.com/fapi/v1/premiumIndex')) {
        $r = Invoke-Upstream $u 6
        if ($r.banned) { return @{ ok = $false; banned = $true } }
        if ($r.ok) {
            try {
                $arr = $r.body | ConvertFrom-Json
                foreach ($it in $arr) { if (-not $it.PSObject.Properties['time']) { $it | Add-Member -NotePropertyName time -NotePropertyValue $serverTime } }
                $json = $arr | ConvertTo-Json -Compress -Depth 5
                if ($json -notmatch '^\[') { $json = '[' + $json + ']' }
                $script:QuoteCache = $json
                $script:QuoteCacheAt = $now
                return @{ ok = $true; body = $json; banned = $false }
            } catch {
                Write-SrvLog ('QUOTE parse fail: ' + $_.Exception.Message)
            }
        }
    }
    return @{ ok = $false; banned = $false }
}

# 通用上游代理：仅白名单前缀；成功缓存 4 秒，失败缓存 5 秒（防止并发请求排队把服务拖死）。
function Get-UpstreamJson([string]$path, [string]$query) {
    $ups = @()
    if ($path -like '/fapi/*') {
        $ups += ('https://fapi.binance.com' + $path)
        $ups += ('https://www.binance.com' + $path)
    } elseif ($path -like '/api/v3/*') {
        $ups += ('https://api.binance.com' + $path)
        $ups += ('https://www.binance.com' + $path)
    } else {
        return @{ ok = $false; notFound = $true; banned = $false }
    }
    $key = $path + '?' + $query
    $now = Get-NowMs
    if ($script:UpCache.Count -gt 400) { $script:UpCache = @{} }
    if ($script:UpFail.Count -gt 400) { $script:UpFail = @{} }
    $c = $script:UpCache[$key]
    if ($c -and ($now - [int64]$c.at) -lt 4000) { return @{ ok = $true; body = $c.body; banned = $false } }
    if (Test-Banned) { return @{ ok = $false; banned = $true } }
    $f = $script:UpFail[$key]
    if ($f -and ($now - [int64]$f) -lt 5000) { return @{ ok = $false; banned = $false } }
    foreach ($u in $ups) {
        $url = $u
        if ($query) { $url = $u + '?' + $query }
        $r = Invoke-Upstream $url 6
        if ($r.banned) { return @{ ok = $false; banned = $true } }
        if ($r.ok) {
            $script:UpCache[$key] = @{ at = $now; body = $r.body }
            return @{ ok = $true; body = $r.body; banned = $false }
        }
    }
    $script:UpFail[$key] = $now
    return @{ ok = $false; banned = $false }
}

# 看门狗互保：看门狗负责拉起/更新本服务，本服务每分钟确认看门狗还活着，没了就拉起来
$script:WdCheckAt = [datetime]'2000-01-01'
function Ensure-Watchdog {
    try {
        $wd = Join-Path $ScriptDir 'watchdog.ps1'
        if (-not (Test-Path -LiteralPath $wd)) { return }
        $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('watchdog.ps1') })
        if ($running.Count -gt 0) { return }
        $lg = Join-Path $ScriptDir 'watchdog_stdout.log'
        $arg = '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $wd + '" >> "' + $lg + '" 2>&1'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $arg -WindowStyle Hidden -WorkingDirectory $ScriptDir
        Write-SrvLog 'watchdog not running -> started'
    } catch { Write-SrvLog ('watchdog check failed: ' + $_.Exception.Message) }
}
function Get-WatchdogStatus {
    try {
        $f = Join-Path $ScriptDir 'watchdog_status.json'
        if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Start-SyncJob {
    if ($script:Job) { return $false }
    if (Test-Banned) { return $false }
    $d = $ScriptDir
    $script:LastError = ''
    $script:Job = Start-Job -ScriptBlock {
        param($dir)
        $r = [ordered]@{ ok = $false; main = ''; sub = '' }
        try {
            $r.main = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'sync_positions.ps1') -Once 2>&1 | Out-String).Trim()
        } catch { $r.main = "EX: $($_.Exception.Message)" }
        try {
            $r.sub = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'sync_subaccount.ps1') -Once 2>&1 | Out-String).Trim()
        } catch { $r.sub = "EX: $($_.Exception.Message)" }
        $r.ok = (($r.main -match 'OK ') -or ($r.sub -match 'OK '))
        return $r
    } -ArgumentList $d
    Write-SrvLog 'SYNC started'
    return $true
}

function Complete-SyncJob {
    if (-not $script:Job) { return }
    $st = $script:Job.State
    if ($st -eq 'Completed' -or $st -eq 'Failed' -or $st -eq 'Stopped') {
        try { $script:LastResult = Receive-Job -Job $script:Job -ErrorAction SilentlyContinue } catch {}
        if (-not $script:LastResult) { $script:LastError = "job $st" }
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        Write-SrvLog ("SYNC done state=$st ok=" + $(if ($script:LastResult) { $script:LastResult.ok } else { 'n/a' }))
    }
}

function Send-Response($stream, [int]$code, [string]$reason, [string]$body, [bool]$noBody, [string]$extraHeaders = '') {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $code $reason`r`n")
    [void]$sb.Append("Content-Type: application/json; charset=utf-8`r`n")
    [void]$sb.Append("Content-Length: $($bytes.Length)`r`n")
    [void]$sb.Append("Access-Control-Allow-Origin: *`r`n")
    [void]$sb.Append("Access-Control-Allow-Methods: GET, OPTIONS`r`n")
    [void]$sb.Append("Access-Control-Allow-Headers: *`r`n")
    [void]$sb.Append("Access-Control-Expose-Headers: Retry-After`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    if ($extraHeaders) { [void]$sb.Append($extraHeaders) }
    [void]$sb.Append("Connection: close`r`n`r`n")
    $hb = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $stream.Write($hb, 0, $hb.Length)
    if (-not $noBody -and $bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
    $stream.Flush()
}

function Send-Banned($stream) {
    $u = Get-BanUntilMs
    $sec = [int][Math]::Max(1, [Math]::Ceiling(($u - (Get-NowMs)) / 1000.0))
    $b = [ordered]@{ ok = $false; error = 'binance rate limited (418/429)'; bannedUntil = (Format-BanTime $u); retryAfter = $sec } | ConvertTo-Json -Compress
    Send-Response $stream 429 'Too Many Requests' $b $false ("Retry-After: $sec`r`n")
}

function Handle-Request($client) {
    $stream = $null
    try {
        # 关键修复：读写超时。没有超时的话，一个只连不发的连接就能让整个服务永久卡住。
        $client.ReceiveTimeout = 3000
        $client.SendTimeout = 5000
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $stream.WriteTimeout = 5000
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
        $line = $reader.ReadLine()
        if (-not $line) { return }
        # 丢掉请求头
        $guard = 0
        while ($true) {
            $h = $reader.ReadLine()
            if ($null -eq $h -or $h -eq '') { break }
            $guard++
            if ($guard -gt 100) { break }
        }
        $parts = $line -split '\s+'
        $method = $parts[0]
        $path = '/'
        $rawQuery = ''
        if ($parts.Length -ge 2) {
            $target = $parts[1]
            $qi = $target.IndexOf('?')
            if ($qi -ge 0) { $path = $target.Substring(0, $qi); $rawQuery = $target.Substring($qi + 1) }
            else { $path = $target }
        }

        if ($method -eq 'OPTIONS') {
            Send-Response $stream 204 'No Content' '' $true
            return
        }

        switch ($path) {
            '/ping' {
                $b = [ordered]@{ ok = $true; service = 'binance-refresh'; time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); port = $Port } | ConvertTo-Json -Compress
                Send-Response $stream 200 'OK' $b $false
            }
            '/refresh' {
                $banned = Test-Banned
                $started = $false
                if (-not $banned) { $started = Start-SyncJob }
                $o = [ordered]@{ ok = (-not $banned); started = $started; running = ($null -ne $script:Job); banned = $banned }
                if ($banned) { $o['bannedUntil'] = (Format-BanTime (Get-BanUntilMs)) }
                Send-Response $stream 200 'OK' ($o | ConvertTo-Json -Compress) $false
            }
            '/status' {
                $files = Get-LiveStamp
                $banned = Test-Banned
                $b = [ordered]@{
                    ok          = $true
                    running     = ($null -ne $script:Job)
                    lastResult  = $script:LastResult
                    lastError   = $script:LastError
                    banned      = $banned
                    bannedUntil = $(if ($banned) { Format-BanTime (Get-BanUntilMs) } else { '' })
                    proxy       = $(if ($script:SrvProxy) { [string]$script:SrvProxy } else { '' })
                    watchdog    = (Get-WatchdogStatus)
                    files       = $files
                } | ConvertTo-Json -Compress -Depth 8
                Send-Response $stream 200 'OK' $b $false
            }
            '/fapi/v1/premiumIndex' {
                $q = Get-PremiumIndexJson
                if ($q.ok) {
                    Send-Response $stream 200 'OK' $q.body $false
                } elseif ($q.banned) {
                    Send-Banned $stream
                } else {
                    Send-Response $stream 502 'Bad Gateway' '{"ok":false,"error":"quote upstream unavailable"}' $false
                }
            }
            default {
                $up = Get-UpstreamJson $path $rawQuery
                if ($up.ok) {
                    Send-Response $stream 200 'OK' $up.body $false
                } elseif ($up.banned) {
                    Send-Banned $stream
                } elseif ($up.notFound) {
                    Send-Response $stream 404 'Not Found' '{"ok":false,"error":"not found"}' $false
                } else {
                    Send-Response $stream 502 'Bad Gateway' '{"ok":false,"error":"upstream unavailable"}' $false
                }
            }
        }
    } catch {
        $em = $_.Exception.Message
        # 读超时（预连接/半开连接）属正常现象，不刷日志
        if ($em -notmatch 'timed out|超时|period of time|没有正确答复') { Write-SrvLog ("REQ error: " + $em) }
    } finally {
        try { if ($stream) { $stream.Dispose() } } catch {}
        try { $client.Close() } catch {}
    }
}

# ---- 单实例：端口已被占用则直接退出 ----
$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Write-Host ("port $Port busy, refresh service may already be running: " + $_.Exception.Message)
    Write-SrvLog ("start skipped: port $Port busy")
    exit 0
}

Write-SrvLog ("service listening on 127.0.0.1:$Port")
Write-Host "refresh service started: http://127.0.0.1:$Port/ping"

try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            Handle-Request $client
        }
        Complete-SyncJob
        if (((Get-Date) - $script:WdCheckAt).TotalSeconds -ge 60) { $script:WdCheckAt = Get-Date; Ensure-Watchdog }
        Start-Sleep -Milliseconds 120
    }
} finally {
    try { $listener.Stop() } catch {}
    if ($script:Job) { try { Remove-Job -Job $script:Job -Force } catch {} }
    Write-SrvLog 'service stopped'
}
