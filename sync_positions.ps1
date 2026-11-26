#Requires -Version 5.1
param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutJs = Join-Path $ScriptDir 'positions_live.js'
$OutJson = Join-Path $ScriptDir 'positions_live.json'
$OutJsOkBak = Join-Path $ScriptDir 'positions_live.ok.js.bak'
$OutJsonOkBak = Join-Path $ScriptDir 'positions_live.ok.json.bak'
$CredPath = Join-Path $env:USERPROFILE '.binance_api.env'
$BaseUrl = 'https://fapi.binance.com'  # 神舟直连币安
$RecvWindow = 60000
$LoopSleepSec = 30          # 每 30 秒同步一次（扣除请求耗时，固定节拍）
$MaxBackoffSec = 300
$script:BackoffSec = 0
$script:LastGoodJs = $null
$script:LastGoodJson = $null
foreach ($cand in @($OutJsonOkBak, $OutJson)) {
    if (-not (Test-Path -LiteralPath $cand)) { continue }
    try {
        $pj = Get-Content -LiteralPath $cand -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($pj -and $pj.account) {
            $script:LastGoodJson = (Get-Content -LiteralPath $cand -Raw)
            $jsCand = if ($cand -eq $OutJsonOkBak) { $OutJsOkBak } else { $OutJs }
            if (Test-Path -LiteralPath $jsCand) {
                $jr = Get-Content -LiteralPath $jsCand -Raw
                if ($jr -match 'account\s*:') { $script:LastGoodJs = $jr }
            }
            break
        }
    } catch {}
}

# ---- 代理自主探测（不依赖系统 ProxyEnable 开关）-----------------------------
# 系统代理开关被关掉时，.NET/Invoke-RestMethod 会走直连，而直连币安不通 -> 全体超时。
# 这里自己按顺序探测：注册表 ProxyServer -> 常见本机代理端口 -> 直连，用 /fapi/v1/ping 实测。
$script:ProxyUri = $null
$script:ProxyCheckedAt = [int64]0
function Get-ProxyCandidate {
    $cands = New-Object System.Collections.Generic.List[string]
    try {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($reg.ProxyServer) {
            $v = [string]$reg.ProxyServer
            if ($v -match '=') {
                $hit = ($v -split ';') | Where-Object { $_ -match '^\s*https=' } | Select-Object -First 1
                if (-not $hit) { $hit = ($v -split ';') | Where-Object { $_ -match '^\s*http=' } | Select-Object -First 1 }
                if ($hit) { $v = ($hit -split '=', 2)[1] }
            }
            $v = $v.Trim()
            if ($v -and $v -notmatch '^https?://') { $v = 'http://' + $v }
            if ($v) { $cands.Add($v) }
        }
    } catch {}
    foreach ($p in @('7897','7890','15236','7899','10809','1080','10916','20171')) {
        $cands.Add("http://127.0.0.1:$p")
        $cands.Add("http://localhost:$p")
    }
    return $cands
}
function Get-ProxyUri {
    $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($script:ProxyUri -and ($now - $script:ProxyCheckedAt) -lt 300000) { return $script:ProxyUri }
    foreach ($c in (Get-ProxyCandidate)) {
        try {
            $req = [System.Net.HttpWebRequest]::Create('https://fapi.binance.com/fapi/v1/ping')
            $req.Proxy = New-Object System.Net.WebProxy($c, $true)
            $req.Timeout = 6000
            $resp = $req.GetResponse(); $resp.Close()
            $script:ProxyUri = $c
            $script:ProxyCheckedAt = $now
            return $c
        } catch {}
    }
    $script:ProxyUri = $null
    $script:ProxyCheckedAt = $now
    return $null
}
# ---- 币安限流/封禁保护（2026-11-26）---------------------------------------------
# 418 = 当前出口 IP 已被币安封禁，429 = 即将被封。封禁期间再发任何请求（含 ping/time）都会让封禁升级。
# 做法：解析币安返回的 Retry-After / "banned until"，写入共享文件 binance_ban.json；
# 主账户、子账户、本地刷新服务（8788）都读这个文件，解封之前一律不再访问币安。
$SyncName = 'positions'
$BanFile = Join-Path $ScriptDir 'binance_ban.json'
$script:BanUntilMs = [int64]0
$script:RlBackoffSec = 0
$script:BanReportedFor = [int64]0
function Get-NowMs { return [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Get-BanUntilMs {
    $u = [int64]$script:BanUntilMs
    try {
        if (Test-Path -LiteralPath $BanFile) {
            $b = Get-Content -LiteralPath $BanFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $f = [int64]$b.untilMs
            if ($f -gt $u) { $u = $f }
        }
    } catch {}
    return $u
}
function Format-BanTime([int64]$ms) {
    return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToLocalTime().ToString('HH:mm:ss')
}
function Get-BanMessage([int64]$until) {
    return ('HTTP 418/429 币安限流封禁中，预计 {0} 解除；期间后台暂停所有请求' -f (Format-BanTime $until))
}
function Register-RateLimit($err, [string]$source) {
    $now = Get-NowMs
    $code = 0; $retry = 0; $body = ''
    try {
        $resp = $err.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            $ra = [string]$resp.Headers['Retry-After']
            if ($ra) { [void][int]::TryParse($ra, [ref]$retry) }
        }
    } catch {}
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = [string]$err.ErrorDetails.Message } } catch {}
    if ($code -ne 418 -and $code -ne 429) {
        if ([string]$err.Exception.Message -match '418|teapot') { $code = 418 } else { $code = 429 }
    }
    $until = [int64]0
    if ($body -match 'banned until (\d{12,})') { $until = [int64]$Matches[1] }
    if ($retry -gt 0) { $until = [Math]::Max($until, $now + [int64]$retry * 1000) }
    if ($until -le $now) {
        # 币安没给具体时间：418 从 2 分钟起、429 从 1 分钟起，连续触发翻倍，最长 30 分钟
        $base = 60
        if ($code -eq 418) { $base = 120 }
        if ($script:RlBackoffSec -lt $base) { $script:RlBackoffSec = $base }
        else { $script:RlBackoffSec = [Math]::Min(1800, [int]($script:RlBackoffSec * 2)) }
        $until = $now + [int64]$script:RlBackoffSec * 1000
    }
    $until = $until + 3000
    $existing = Get-BanUntilMs
    if ($until -gt $existing) {
        $script:BanUntilMs = $until
        try {
            $o = [ordered]@{ untilMs = $until; until = (Format-BanTime $until); code = $code; source = $source; at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); detail = $body }
            [System.IO.File]::WriteAllText($BanFile, ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    } else {
        $script:BanUntilMs = $existing
    }
    Write-Host ('RATELIMIT HTTP {0} -> pause until {1} retryAfter={2}s {3}' -f $code, (Format-BanTime $script:BanUntilMs), $retry, $body)
}

function Invoke-BinanceGet([string]$url, $headers) {
    # 封禁期间不发任何请求（连代理探测的 ping 也不发），直接抛出限流错误
    $banU = Get-BanUntilMs
    if ($banU -gt (Get-NowMs)) { throw (Get-BanMessage $banU) }
    $px = Get-ProxyUri

    # 添加完整的浏览器请求头，避免被识别为机器人
    $fullHeaders = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0'
        'Accept' = 'application/json, text/plain, */*'
        'Accept-Language' = 'zh-CN,zh;q=0.9,en;q=0.8'
        'Accept-Encoding' = 'gzip, deflate, br'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
        'Sec-Fetch-Dest' = 'empty'
        'Sec-Fetch-Mode' = 'cors'
        'Sec-Fetch-Site' = 'same-origin'
        'Referer' = 'https://www.binance.com/'
        'Origin' = 'https://www.binance.com'
    }

    # 合并传入的headers（API密钥等）
    if ($headers) {
        foreach ($key in $headers.Keys) {
            $fullHeaders[$key] = $headers[$key]
        }
    }

    try {
        if ($px) {
            return Invoke-RestMethod -Method Get -Uri $url -Headers $fullHeaders -TimeoutSec 25 -Proxy ([uri]$px) -UseBasicParsing
        }
        return Invoke-RestMethod -Method Get -Uri $url -Headers $fullHeaders -TimeoutSec 25 -UseBasicParsing
    } catch {
        $em = $_.Exception.Message
        # 限流时不要清代理+重探（会额外狂打 ping，加重 418）；其它错误才清缓存
        if ($em -match '418|429|Too Many Requests|teapot') { Register-RateLimit $_ $SyncName }
        if ($em -notmatch '418|429|Too Many Requests|teapot') {
            $script:ProxyUri = $null
            $script:ProxyCheckedAt = [int64]0
        }
        throw
    }
}

# Realized PnL / commission / fee-rate cache. The income endpoint is heavy
# (weight 30 per symbol) so it refreshes every 10 minutes instead of every loop.
$RealizedCache = Join-Path $ScriptDir 'realized_cache.json'
$RealizedTtlSec = 120   # 实现盈亏兜底每 2 分钟重拉；钱包余额/持仓数量一变则下一轮立即重拉
# 手续费率几乎不变，单独缓存 1 小时（每个币种省一次 weight 20 的请求）
$FeeRateTtlSec = 3600
$script:FeeRateCache = @{}
$script:RealizedFp = $null


function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Get-LocalIsoNow {
    $now = Get-Date
    $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($now)
    $sign = if ($offset.TotalMinutes -ge 0) { '+' } else { '-' }
    $offAbs = [TimeSpan]::FromMinutes([Math]::Abs($offset.TotalMinutes))
    return ('{0}{1}{2:00}:{3:00}' -f $now.ToString('yyyy-MM-ddTHH:mm:ss'), $sign, [int]$offAbs.TotalHours, $offAbs.Minutes)
}

function Write-LiveError([string]$Message) {
    # 失败时绝不写空 payload（否则页面变成 --）。优先保留/恢复上一份成功快照。
    $updatedAt = Get-LocalIsoNow
    $escaped = $Message.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", ' ')
    $prev = $null
    $jsBase = $null
    # 每个候选独立 try：并发写入时某个文件被截断不能拖垮整条兜底链，
    # 否则会退化成"纯错误"覆盖掉好数据（2026-11-18 15:54 之后就是这样丢的）。
    foreach ($cand in @($OutJson, $OutJsonOkBak)) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
            $pj = Get-Content -LiteralPath $cand -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pj -and $pj.account) { $prev = $pj; break }
        } catch {}
    }
    try {
        if ($script:LastGoodJs -and ($script:LastGoodJs -match 'account\s*:')) {
            $jsBase = $script:LastGoodJs
        } elseif (Test-Path -LiteralPath $OutJsOkBak) {
            $jr = Get-Content -LiteralPath $OutJsOkBak -Raw
            if ($jr -match 'account\s*:') { $jsBase = $jr }
        } elseif (Test-Path -LiteralPath $OutJs) {
            $jr = Get-Content -LiteralPath $OutJs -Raw
            if ($jr -match 'account\s*:') { $jsBase = $jr }
        }
    } catch {}
    if (-not $prev -and $script:LastGoodJson) {
        try { $prev = $script:LastGoodJson | ConvertFrom-Json } catch {}
    }

    if ($prev -and $prev.account) {
        $payload = [ordered]@{
            updatedAt = if ($prev.updatedAt) { [string]$prev.updatedAt } else { $updatedAt }
            error     = $Message
            account   = $prev.account
            positions = $prev.positions
        }
        Write-Utf8NoBom -Path $OutJson -Content ($payload | ConvertTo-Json -Depth 8)
        if ($jsBase) {
            $jsKeep = $jsBase.TrimEnd().TrimEnd(';') + ";`n"
            $jsKeep += "if (window.__BINANCE_LIVE__) { window.__BINANCE_LIVE__.error = `"$escaped`"; window.__BINANCE_LIVE__.failAt = `"$updatedAt`"; }`n"
            Write-Utf8NoBom -Path $OutJs -Content $jsKeep
        }
        return
    }

    # 没有任何成功快照时才写纯错误
    $js = "window.__BINANCE_LIVE__ = { error: `"$escaped`", updatedAt: `"$updatedAt`" };`n"
    Write-Utf8NoBom -Path $OutJs -Content $js
    $obj = @{ error = $Message; updatedAt = $updatedAt } | ConvertTo-Json -Depth 5 -Compress
    Write-Utf8NoBom -Path $OutJson -Content $obj
}

function Read-Creds {
    if (-not (Test-Path -LiteralPath $CredPath)) {
        throw "Credential file missing: $CredPath"
    }
    $map = @{}
    Get-Content -LiteralPath $CredPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { return }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        $map[$k] = $v
    }
    if (-not $map['BINANCE_API_KEY'] -or -not $map['BINANCE_API_SECRET']) {
        throw 'BINANCE_API_KEY / BINANCE_API_SECRET missing in env file'
    }
    return $map
}

function Get-HmacSha256Hex([string]$Secret, [string]$Payload) {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Payload))
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# 本机时钟可能比币安快（实测 +1.6s）。币安拒绝 timestamp 超前 >1000ms（code -1021 / HTTP 400），
# recvWindow 只管"落后"不管"超前"，所以必须用币安服务器时间。/fapi/v1/time 是公开接口，
# 这里取一次锚点并缓存 10 分钟，之后用本机时钟增量推算，避免每次签名多打一次请求。
$script:ServerTimeAnchor = [int64]0
$script:ServerTimeLocalAt = [int64]0
function Get-ServerTimeMs {
    $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($script:ServerTimeAnchor -gt 0 -and ($now - $script:ServerTimeLocalAt) -lt 600000) {
        if ($env:BINANCE_SYNC_DEBUG) { Write-Host "[time] cached anchor=$($script:ServerTimeAnchor) localAt=$($script:ServerTimeLocalAt) now=$now -> $(($script:ServerTimeAnchor + ($now - $script:ServerTimeLocalAt)))" }
        return ($script:ServerTimeAnchor + ($now - $script:ServerTimeLocalAt))
    }
    try {
        $px = Get-ProxyUri
        $url = "$BaseUrl/fapi/v1/time"
        if ($px) { $r = Invoke-RestMethod -Uri $url -TimeoutSec 10 -Proxy ([uri]$px) -UseBasicParsing }
        else     { $r = Invoke-RestMethod -Uri $url -TimeoutSec 10 -UseBasicParsing }
        $srv = [int64]$r.serverTime
        if ($env:BINANCE_SYNC_DEBUG) { Write-Host "[time] calibrate srv=$srv now=$now diff=$($srv-$now) px=$px" }
        if ($srv -gt 0) {
            # srv 是"收到响应时"的服务器时间，必须配"收到响应时"的本机时间。
            # 若用请求发出前的 $now 做锚点，RTT(约 1~2s) 会被算进后续推算，
            # 导致缓存分支的时间戳反超服务器 -> -1021 / HTTP 400。
            $script:ServerTimeAnchor = $srv
            $script:ServerTimeLocalAt = [int64][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            return $srv
        }
    } catch {
        if ($env:BINANCE_SYNC_DEBUG) { Write-Host "[time] calibrate FAILED: $($_.Exception.Message)" }
    }
    return ($now - 2000)   # 校时失败时保守回退：往前拨 2 秒，避免 -1021
}

function Invoke-SignedGet([string]$Path, [hashtable]$Creds, [hashtable]$ExtraQuery) {
    $timestamp = Get-ServerTimeMs
    $parts = New-Object System.Collections.Generic.List[string]
    if ($ExtraQuery) {
        foreach ($k in $ExtraQuery.Keys) {
            $parts.Add(('{0}={1}' -f $k, $ExtraQuery[$k]))
        }
    }
    $parts.Add("recvWindow=$RecvWindow")
    $parts.Add("timestamp=$timestamp")
    $qs = [string]::Join('&', $parts)
    $sig = Get-HmacSha256Hex -Secret $Creds['BINANCE_API_SECRET'] -Payload $qs
    $url = "$BaseUrl$Path`?$qs&signature=$sig"
    if ($env:BINANCE_SYNC_DEBUG) { Write-Host ("[sync] ts=$timestamp local=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) path=$Path") }
    # 注意：不能在 -Headers 里塞 Connection，.NET 会拒（Keep-Alive/Close 属性限制）。
    # 换代理节点后旧隧道会一直 451/403，所以失败时清掉 ServicePoint 连接池再重试一次。
    $headers = @{ 'X-MBX-APIKEY' = $Creds['BINANCE_API_KEY'] }
    try {
        return Invoke-BinanceGet -url $url -headers $headers
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '451|403|-2015') {
            try { $sp = [System.Net.ServicePointManager]::FindServicePoint([uri]$url); if ($sp) { $sp.Close() } } catch {}
            Start-Sleep -Milliseconds 400
            return Invoke-BinanceGet -url $url -headers $headers
        }
        throw
    }
}

# ---- realized pnl / commission helpers -------------------------------------
function Get-Rv($obj, [string]$name) {
    if ($null -eq $obj) { return 0.0 }
    $v = $null
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { $v = $obj[$name] }
    } else {
        $pp = $obj.PSObject.Properties[$name]
        if ($pp) { $v = $pp.Value }
    }
    $d = 0.0
    if ($null -ne $v) { [void][double]::TryParse([string]$v, [ref]$d) }
    return $d
}

function Get-SymStats($rmap, [string]$sym) {
    if (-not $rmap) { return $null }
    if ($rmap -is [System.Collections.IDictionary]) {
        if ($rmap.Contains($sym)) { return $rmap[$sym] }
        return $null
    }
    $pp = $rmap.PSObject.Properties[$sym]
    if ($pp) { return $pp.Value }
    return $null
}

function Read-RealizedCache {
    if (-not (Test-Path -LiteralPath $RealizedCache)) { return $null }
    try { return (Get-Content -LiteralPath $RealizedCache -Raw | ConvertFrom-Json) } catch { return $null }
}

# Rolling 89-day window (Binance caps income queries at 90 days back).
function Get-RealizedStats([hashtable]$Creds, [string[]]$Symbols, [bool]$Force = $false) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cache = Read-RealizedCache
    if ($cache -and $cache.at -and -not $Force) {
        $age = $now - [long]$cache.at
        # 缓存里缺了新开仓的币种也要重拉
        $missing = $false
        foreach ($s in $Symbols) { if (-not (Get-SymStats $cache.data $s)) { $missing = $true; break } }
        if (-not $missing -and $age -ge 0 -and $age -lt ($RealizedTtlSec * 1000)) { return $cache }
    }

    $start = [DateTimeOffset]::UtcNow.AddDays(-89).ToUnixTimeMilliseconds()
    $map = [ordered]@{}
    $okCount = 0
    $failCount = 0
    foreach ($sym in $Symbols) {
        try {
            $inc = Invoke-SignedGet -Path '/fapi/v1/income' -Creds $Creds -ExtraQuery @{ symbol = $sym; limit = 1000; startTime = $start }
            $rp = 0.0; $cm = 0.0; $ff = 0.0; $cnt = 0
            foreach ($r in $inc) {
                $cnt++
                $v = 0.0
                [void][double]::TryParse([string]$r.income, [ref]$v)
                $t = [string]$r.incomeType
                if ($t -eq 'REALIZED_PNL') { $rp += $v }
                elseif ($t -eq 'COMMISSION') { $cm += $v }
                elseif ($t -eq 'FUNDING_FEE') { $ff += $v }
            }
            $maker = 0.0; $taker = 0.0
            $fc = $script:FeeRateCache[$sym]
            if ($fc -and ($now - [int64]$fc.at) -lt ($FeeRateTtlSec * 1000)) {
                $maker = [double]$fc.maker; $taker = [double]$fc.taker
            } else {
                try {
                    $cr = Invoke-SignedGet -Path '/fapi/v1/commissionRate' -Creds $Creds -ExtraQuery @{ symbol = $sym }
                    [void][double]::TryParse([string]$cr.makerCommissionRate, [ref]$maker)
                    [void][double]::TryParse([string]$cr.takerCommissionRate, [ref]$taker)
                    $script:FeeRateCache[$sym] = @{ at = $now; maker = $maker; taker = $taker }
                } catch {
                    $prevRate = Get-SymStats $(if ($cache) { $cache.data } else { $null }) $sym
                    if ($prevRate) { $maker = Get-Rv $prevRate 'maker'; $taker = Get-Rv $prevRate 'taker' }
                }
            }
            $map[$sym] = [ordered]@{
                realized   = $rp
                commission = $cm
                funding    = $ff
                maker      = $maker
                taker      = $taker
                rows       = $cnt
            }
            $okCount++
            $failCount = 0
        } catch {
            $failCount++
            Write-Host ("WARN income {0} failed: {1}" -f $sym, $_.Exception.Message)
            # network / proxy trouble: stop early so pricing data is not held up for minutes
            if ($failCount -ge 2) { Write-Host 'WARN income aborted after 2 failures'; break }
        }
    }
    if ($okCount -eq 0) {
        if ($cache) { Write-Host 'WARN income all failed, keeping previous cache'; return $cache }
        return $null
    }
    $out = [ordered]@{ at = $now; data = $map }
    try { Write-Utf8NoBom -Path $RealizedCache -Content ($out | ConvertTo-Json -Depth 6) } catch {}
    return $out
}
# ---------------------------------------------------------------------------

function ConvertTo-JsNumber($n) {
    if ($null -eq $n) { return 'null' }
    $d = [double]$n
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 'null' }
    return ($d.ToString([System.Globalization.CultureInfo]::InvariantCulture))
}

function ConvertTo-JsString([string]$s) {
    if ($null -eq $s) { return '""' }
    $escaped = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", ' ')
    return "`"$escaped`""
}

function Sync-Once {
    $creds = Read-Creds
    # /fapi/v2/account carries total* balances + per-position initialMargin / isolatedWallet
    # positionRisk carries markPrice / liquidationPrice / isolatedMargin / notional
    $account = Invoke-SignedGet -Path '/fapi/v2/account' -Creds $creds -ExtraQuery @{}
    $positions = Invoke-SignedGet -Path '/fapi/v2/positionRisk' -Creds $creds -ExtraQuery @{}
    $balances = Invoke-SignedGet -Path '/fapi/v2/balance' -Creds $creds -ExtraQuery @{}

    $usdtBal = $balances | Where-Object { $_.asset -eq 'USDT' } | Select-Object -First 1

    $totalWalletBalance = [double]$account.totalWalletBalance
    $totalUnrealizedProfit = [double]$account.totalUnrealizedProfit
    $totalMarginBalance = [double]$account.totalMarginBalance
    $totalPositionInitialMargin = [double]$account.totalPositionInitialMargin
    $availableBalance = [double]$account.availableBalance
    $crossWalletBalance = [double]$account.totalCrossWalletBalance
    if ($usdtBal) {
        # balance endpoint availableBalance is authoritative for withdrawable/free
        $availableBalance = [double]$usdtBal.availableBalance
        if ([double]$usdtBal.crossWalletBalance -ne 0) {
            $crossWalletBalance = [double]$usdtBal.crossWalletBalance
        }
    }

    # Index account.positions by symbol (one-way mode: single entry per symbol)
    $acctPos = @{}
    foreach ($ap in $account.positions) {
        $amt = 0.0
        [void][double]::TryParse([string]$ap.positionAmt, [ref]$amt)
        if ([Math]::Abs($amt) -le 0) { continue }
        $acctPos[[string]$ap.symbol] = $ap
    }

    $posMap = [ordered]@{}
    foreach ($p in $positions) {
        $amt = 0.0
        [void][double]::TryParse([string]$p.positionAmt, [ref]$amt)
        if ([Math]::Abs($amt) -le 0) { continue }

        $sym = [string]$p.symbol
        $ap = $acctPos[$sym]

        $entry = [double]$p.entryPrice
        $lev = [double]$p.leverage
        $liq = [double]$p.liquidationPrice
        $mark = [double]$p.markPrice
        $upnl = [double]$p.unRealizedProfit
        $notional = [double]$p.notional

        $isoMargin = 0.0
        [void][double]::TryParse([string]$p.isolatedMargin, [ref]$isoMargin)

        $isoWallet = 0.0
        if ($ap -and $null -ne $ap.isolatedWallet) {
            [void][double]::TryParse([string]$ap.isolatedWallet, [ref]$isoWallet)
        }
        if ($isoWallet -eq 0 -and $null -ne $p.isolatedWallet) {
            [void][double]::TryParse([string]$p.isolatedWallet, [ref]$isoWallet)
        }
        # Binance: isolatedMargin = isolatedWallet + unRealizedProfit
        if ($isoWallet -eq 0 -and $isoMargin -ne 0) {
            $isoWallet = $isoMargin - $upnl
        }

        $initMargin = 0.0
        if ($ap) {
            [void][double]::TryParse([string]$ap.positionInitialMargin, [ref]$initMargin)
            if ($initMargin -eq 0) {
                [void][double]::TryParse([string]$ap.initialMargin, [ref]$initMargin)
            }
        }
        if ($initMargin -eq 0) {
            [void][double]::TryParse([string]$p.positionInitialMargin, [ref]$initMargin)
        }
        if ($initMargin -eq 0 -and $lev -gt 0) {
            $initMargin = [Math]::Abs($notional) / $lev
        }

        $mt = ([string]$p.marginType).ToLowerInvariant()
        $mode = if ($mt -eq 'isolated') { 'isolated' } else { 'cross' }
        $side = if ($amt -ge 0) { 'long' } else { 'short' }

        # margin = initial margin (ROE basis). Do NOT use isolatedMargin (includes uPnL).
        $margin = $initMargin

        $posMap[$sym] = [ordered]@{
            entryPrice            = $entry
            quantity              = [Math]::Abs($amt)
            positionAmt           = $amt
            side                  = $side
            leverage              = $lev
            liqPrice              = $liq
            margin                = $margin
            initialMargin         = $initMargin
            isolatedWallet        = $isoWallet
            isolatedMargin        = $isoMargin
            notional              = $notional
            mode                  = $mode
            markPrice             = $mark
            unRealizedProfit      = $upnl
        }
    }

    # 实现盈亏 / 手续费 / 资金费：兜底 2 分钟；钱包余额或持仓数量变化（成交、资金费结算）时立即重拉
    $symList = @($posMap.Keys)
    $fpParts = New-Object System.Collections.Generic.List[string]
    $fpParts.Add([string]$account.totalWalletBalance)
    foreach ($k in ($symList | Sort-Object)) { $fpParts.Add(('{0}:{1}' -f $k, $posMap[$k].positionAmt)) }
    $fp = [string]::Join('|', $fpParts)
    $forceRealized = ($null -ne $script:RealizedFp -and $script:RealizedFp -ne $fp)
    if ($forceRealized) { Write-Host 'REALIZED refresh: wallet/position changed' }
    $realized = $null
    try {
        $realized = Get-RealizedStats -Creds $creds -Symbols $symList -Force $forceRealized
        if ($realized) { $script:RealizedFp = $fp }
    } catch {
        Write-Host ("WARN realized stats failed: {0}" -f $_.Exception.Message)
    }
    $rmap = $null
    if ($realized) { $rmap = $realized.data }
    foreach ($sym in $symList) {
        $st = Get-SymStats $rmap $sym
        if ($st) {
            $tk = Get-Rv $st 'taker'
            $mk = Get-Rv $st 'maker'
            $feeRate = if ($tk -gt 0) { $tk } else { $mk }
            $posMap[$sym]['realizedPnl'] = Get-Rv $st 'realized'
            $posMap[$sym]['feePaid'] = Get-Rv $st 'commission'
            $posMap[$sym]['fundingFee'] = Get-Rv $st 'funding'
            $posMap[$sym]['feeRate'] = $feeRate
        } else {
            # no data yet: emit null so the page shows '--' instead of a fake 0
            $posMap[$sym]['realizedPnl'] = $null
            $posMap[$sym]['feePaid'] = $null
            $posMap[$sym]['fundingFee'] = $null
            $posMap[$sym]['feeRate'] = $null
        }
    }
    $totalRealized = 0.0; $totalFee = 0.0
    foreach ($sym in $symList) {
        if ($null -ne $posMap[$sym]['realizedPnl']) { $totalRealized += [double]$posMap[$sym]['realizedPnl'] }
        if ($null -ne $posMap[$sym]['feePaid']) { $totalFee += [double]$posMap[$sym]['feePaid'] }
    }

    $updatedAt = Get-LocalIsoNow
    $payload = [ordered]@{
        updatedAt = $updatedAt
        account   = [ordered]@{
            walletBalance               = $totalWalletBalance
            totalWalletBalance          = $totalWalletBalance
            totalUnrealizedProfit       = $totalUnrealizedProfit
            totalMarginBalance          = $totalMarginBalance
            totalPositionInitialMargin  = $totalPositionInitialMargin
            availableBalance            = $availableBalance
            crossWalletBalance          = $crossWalletBalance
            totalRealizedPnl            = $totalRealized
            totalFeePaid                = $totalFee
        }
        positions = $posMap
    }

    $json = $payload | ConvertTo-Json -Depth 8
    Write-Utf8NoBom -Path $OutJson -Content $json

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('window.__BINANCE_LIVE__ = {')
    [void]$sb.Append((' updatedAt: {0},' -f (ConvertTo-JsString $updatedAt)))
    [void]$sb.Append(' account: {')
    [void]$sb.Append((' walletBalance: {0},' -f (ConvertTo-JsNumber $totalWalletBalance)))
    [void]$sb.Append((' totalWalletBalance: {0},' -f (ConvertTo-JsNumber $totalWalletBalance)))
    [void]$sb.Append((' totalUnrealizedProfit: {0},' -f (ConvertTo-JsNumber $totalUnrealizedProfit)))
    [void]$sb.Append((' totalMarginBalance: {0},' -f (ConvertTo-JsNumber $totalMarginBalance)))
    [void]$sb.Append((' totalPositionInitialMargin: {0},' -f (ConvertTo-JsNumber $totalPositionInitialMargin)))
    [void]$sb.Append((' availableBalance: {0},' -f (ConvertTo-JsNumber $availableBalance)))
    [void]$sb.Append((' crossWalletBalance: {0},' -f (ConvertTo-JsNumber $crossWalletBalance)))
    [void]$sb.Append((' totalRealizedPnl: {0},' -f (ConvertTo-JsNumber $totalRealized)))
    [void]$sb.Append((' totalFeePaid: {0}' -f (ConvertTo-JsNumber $totalFee)))
    [void]$sb.Append(' }, positions: {')
    $first = $true
    foreach ($sym in $posMap.Keys) {
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        $o = $posMap[$sym]
        [void]$sb.Append((' "{0}": {{' -f $sym))
        [void]$sb.Append((' entryPrice: {0},' -f (ConvertTo-JsNumber $o.entryPrice)))
        [void]$sb.Append((' quantity: {0},' -f (ConvertTo-JsNumber $o.quantity)))
        [void]$sb.Append((' positionAmt: {0},' -f (ConvertTo-JsNumber $o.positionAmt)))
        [void]$sb.Append((' side: {0},' -f (ConvertTo-JsString $o.side)))
        [void]$sb.Append((' leverage: {0},' -f (ConvertTo-JsNumber $o.leverage)))
        [void]$sb.Append((' liqPrice: {0},' -f (ConvertTo-JsNumber $o.liqPrice)))
        [void]$sb.Append((' margin: {0},' -f (ConvertTo-JsNumber $o.margin)))
        [void]$sb.Append((' initialMargin: {0},' -f (ConvertTo-JsNumber $o.initialMargin)))
        [void]$sb.Append((' isolatedWallet: {0},' -f (ConvertTo-JsNumber $o.isolatedWallet)))
        [void]$sb.Append((' isolatedMargin: {0},' -f (ConvertTo-JsNumber $o.isolatedMargin)))
        [void]$sb.Append((' notional: {0},' -f (ConvertTo-JsNumber $o.notional)))
        [void]$sb.Append((' mode: {0},' -f (ConvertTo-JsString $o.mode)))
        [void]$sb.Append((' markPrice: {0},' -f (ConvertTo-JsNumber $o.markPrice)))
        [void]$sb.Append((' unRealizedProfit: {0},' -f (ConvertTo-JsNumber $o.unRealizedProfit)))
        [void]$sb.Append((' realizedPnl: {0},' -f (ConvertTo-JsNumber $o.realizedPnl)))
        [void]$sb.Append((' feePaid: {0},' -f (ConvertTo-JsNumber $o.feePaid)))
        [void]$sb.Append((' fundingFee: {0},' -f (ConvertTo-JsNumber $o.fundingFee)))
        [void]$sb.Append((' feeRate: {0}' -f (ConvertTo-JsNumber $o.feeRate)))
        [void]$sb.Append(' }')
    }
    [void]$sb.Append(' } };')
    [void]$sb.Append("`n")
    $jsBody = $sb.ToString()
    Write-Utf8NoBom -Path $OutJs -Content $jsBody
    try { Write-Utf8NoBom -Path $OutJsOkBak -Content $jsBody } catch {}
    try { Write-Utf8NoBom -Path $OutJsonOkBak -Content $json } catch {}
    $script:LastGoodJs = $jsBody
    $script:LastGoodJson = $json
    $script:BackoffSec = 0

    Write-Host ("OK symbols={0} wallet={1:N4} uPnL={2:N4} equity={3:N4} available={4:N4} rPnl={5:N4} fee={6:N4} at {7}" -f $posMap.Count, $totalWalletBalance, $totalUnrealizedProfit, $totalMarginBalance, $availableBalance, $totalRealized, $totalFee, $updatedAt)
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

# stagger vs subaccount (sub sleeps 30s + 8s initial offset)
Start-Sleep -Seconds 2
while ($true) {
    # 封禁中：一直等到解封，不发任何请求（只在进入封禁时写一次错误状态给页面看）
    $banU = Get-BanUntilMs
    $nowMs = Get-NowMs
    if ($banU -gt $nowMs) {
        if ($script:BanReportedFor -ne $banU) {
            $script:BanReportedFor = $banU
            try { Write-LiveError -Message (Get-BanMessage $banU) } catch {}
        }
        $waitSec = [int][Math]::Ceiling(($banU - $nowMs) / 1000.0)
        Write-Host ('WAIT banned until {0} ({1}s), no requests sent' -f (Format-BanTime $banU), $waitSec)
        if ($Once) { break }
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($waitSec, 600)))
        continue
    }
    $cycleStart = Get-Date
    try {
        Sync-Once
        $script:RlBackoffSec = 0
    } catch {
        $msg = $_.Exception.Message
        try {
            $ex = $_.Exception
            if ($ex.Response) {
                $sr = New-Object IO.StreamReader($ex.Response.GetResponseStream())
                $body = $sr.ReadToEnd()
                if ($body) { $msg = "$msg | $body" }
            }
        } catch {}
        Write-Host ("ERR {0}" -f $msg)
        # 限流：已在 Invoke-BinanceGet 里登记封禁时间；错误信息带上「预计解除时间」给页面显示
        if ($msg -match '418|429|Too Many Requests|teapot') {
            $bu = Get-BanUntilMs
            if ($bu -gt (Get-NowMs)) {
                if ($msg -notmatch '封禁中') { $msg = (Get-BanMessage $bu) + ' | ' + $msg }
                $script:BanReportedFor = $bu
            }
        }
        # 无论何种错误都不写空数据（Write-LiveError 会保留上一份成功快照）
        try { Write-LiveError -Message $msg } catch { Write-Host ("ERR write failed: {0}" -f $_.Exception.Message) }
    }
    if ($Once) { break }
    $elapsedMs = [int]((Get-Date) - $cycleStart).TotalMilliseconds
    Start-Sleep -Milliseconds ([Math]::Max(1000, $LoopSleepSec * 1000 - $elapsedMs))
}
