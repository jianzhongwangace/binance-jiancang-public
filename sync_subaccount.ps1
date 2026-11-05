#Requires -Version 5.1
param([switch]$Once)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutJs = Join-Path $ScriptDir 'subaccount_live.js'
$OutJson = Join-Path $ScriptDir 'subaccount_live.json'
$OutJsOkBak = Join-Path $ScriptDir 'subaccount_live.ok.js.bak'
$OutJsonOkBak = Join-Path $ScriptDir 'subaccount_live.ok.json.bak'
$CredPath = Join-Path $env:USERPROFILE '.binance_subaccount.env'
$BaseUrl = 'https://fapi.binance.com'  # 神舟直连币安
$RecvWindow = 60000
$LoopSleepSec = 30          # was 5; stagger vs main (25s)
$MaxBackoffSec = 300
$script:BackoffSec = 0

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
function Invoke-BinanceGet([string]$url, $headers) {
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
        if ($em -notmatch '418|429|Too Many Requests|teapot') {
            $script:ProxyUri = $null
            $script:ProxyCheckedAt = [int64]0
        }
        throw
    }
}

# realized pnl / commission cache: income endpoint is heavy, refresh every 10 min
$RealCache = Join-Path $ScriptDir 'subaccount_realized_cache.json'
$RealTtl = 600
function Write-Utf8([string]$Path,[string]$Content) { [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false))) }
function NowIso { (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
function Read-Creds {
  if (!(Test-Path -LiteralPath $CredPath)) { throw "Credential file missing: $CredPath" }
  $m=@{}; Get-Content -LiteralPath $CredPath | ForEach-Object { $x=$_.Trim(); if (!$x -or $x.StartsWith('#')) { return }; $i=$x.IndexOf('='); if($i -gt 0){$m[$x.Substring(0,$i).Trim()]=$x.Substring($i+1).Trim()} }
  if (!$m.BINANCE_API_KEY -or !$m.BINANCE_API_SECRET) { throw 'BINANCE_API_KEY / BINANCE_API_SECRET missing' }
  return $m
}
function Hmac([string]$Secret,[string]$Text) { $h=New-Object System.Security.Cryptography.HMACSHA256; $h.Key=[Text.Encoding]::UTF8.GetBytes($Secret); return (([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-','').ToLowerInvariant()) }
function SignedGet([string]$Path,$Creds,[string]$Extra='') {
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $q=if($Extra){"$Extra&recvWindow=$RecvWindow&timestamp=$ts"}else{"recvWindow=$RecvWindow&timestamp=$ts"}; $sig=Hmac $Creds.BINANCE_API_SECRET $q
  $url="$BaseUrl$Path`?$q&signature=$sig"
  # 不要设置 Connection 头（.NET 禁止）；代理换节点后旧隧道会 451/403，失败时清连接池重试一次
  $h=@{'X-MBX-APIKEY'=$Creds.BINANCE_API_KEY}
  try { Invoke-BinanceGet -url $url -headers $h }
  catch {
    if ($_.Exception.Message -match '451|403|-2015') { try { $sp=[Net.ServicePointManager]::FindServicePoint([uri]$url); if($sp){$sp.Close()} } catch {}; Start-Sleep -Milliseconds 400; Invoke-BinanceGet -url $url -headers $h }
    else { throw }
  }
}
function Get-NumVal($o,[string]$n){ if($null -eq $o){return 0.0}; $v=$null; if($o -is [System.Collections.IDictionary]){ if($o.Contains($n)){$v=$o[$n]} } else { $pp=$o.PSObject.Properties[$n]; if($pp){$v=$pp.Value} }; $d=0.0; if($null -ne $v){[void][double]::TryParse([string]$v,[ref]$d)}; return $d }
function SymStats($m,[string]$s){ if(-not $m){return $null}; if($m -is [System.Collections.IDictionary]){ if($m.Contains($s)){return $m[$s]}; return $null }; $pp=$m.PSObject.Properties[$s]; if($pp){return $pp.Value}; return $null }
function RealStats($Creds,[string[]]$Syms) {
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if(Test-Path -LiteralPath $RealCache){
    try { $old=Get-Content -LiteralPath $RealCache -Raw|ConvertFrom-Json
      if($old -and $old.at -and ($now-[long]$old.at) -ge 0 -and ($now-[long]$old.at) -lt ($RealTtl*1000)){ return $old }
    } catch {}
  }
  $start=[DateTimeOffset]::UtcNow.AddDays(-89).ToUnixTimeMilliseconds()
  $map=[ordered]@{}; $ok=0; $fail=0
  foreach($s in $Syms){
    try {
      $inc=SignedGet '/fapi/v1/income' $Creds "symbol=$s&limit=1000&startTime=$start"
      $rp=0.0;$cm=0.0;$ff=0.0
      foreach($r in $inc){ $v=0.0; [void][double]::TryParse([string]$r.income,[ref]$v); $t=[string]$r.incomeType
        if($t -eq 'REALIZED_PNL'){$rp+=$v} elseif($t -eq 'COMMISSION'){$cm+=$v} elseif($t -eq 'FUNDING_FEE'){$ff+=$v} }
      $mk=0.0;$tk=0.0
      try { $cr=SignedGet '/fapi/v1/commissionRate' $Creds "symbol=$s"; [void][double]::TryParse([string]$cr.makerCommissionRate,[ref]$mk); [void][double]::TryParse([string]$cr.takerCommissionRate,[ref]$tk) } catch {}
      $map[$s]=[ordered]@{realized=$rp;commission=$cm;funding=$ff;maker=$mk;taker=$tk}
      $ok++
    } catch { $fail++; Write-Host "WARN income $s $($_.Exception.Message)"; if($fail -ge 2){Write-Host 'WARN income aborted'; break} }
  }
  if($ok -eq 0){ if(Test-Path -LiteralPath $RealCache){ try{return (Get-Content -LiteralPath $RealCache -Raw|ConvertFrom-Json)}catch{} }; return $null }
  $o=[ordered]@{at=$now;data=$map}
  try { Write-Utf8 $RealCache ($o|ConvertTo-Json -Depth 6) } catch {}
  return $o
}
function Write-ErrorFile([string]$Message) {
  $prev = $null
  foreach ($cand in @($OutJson, $OutJsonOkBak)) {
    if (-not (Test-Path -LiteralPath $cand)) { continue }
    try {
      $pj = Get-Content -LiteralPath $cand -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($pj -and $pj.account) { $prev = $pj; break }
    } catch {}
  }
  if ($prev -and $prev.account) {
    $o = [ordered]@{
      updatedAt = if ($prev.updatedAt) { [string]$prev.updatedAt } else { (NowIso) }
      error = $Message
      account = $prev.account
      positions = $prev.positions
    }
    $j = $o | ConvertTo-Json -Depth 8
    Write-Utf8 $OutJson $j
    Write-Utf8 $OutJs ('window.__BINANCE_SUBACCOUNT__=' + $j + ';')
    return
  }
  $o=[ordered]@{updatedAt=(NowIso);error=$Message}
  Write-Utf8 $OutJson ($o|ConvertTo-Json -Compress)
  Write-Utf8 $OutJs ('window.__BINANCE_SUBACCOUNT__='+($o|ConvertTo-Json -Compress)+';')
}
function Sync-Once {
  $c=Read-Creds; $a=SignedGet '/fapi/v2/account' $c; $ps=SignedGet '/fapi/v2/positionRisk' $c
  $positions=[ordered]@{}
  foreach($p in $ps){$amt=[double]$p.positionAmt;if([Math]::Abs($amt) -le 0){continue};$positions[$p.symbol]=[ordered]@{entryPrice=[double]$p.entryPrice;quantity=[Math]::Abs($amt);positionAmt=$amt;side=if($amt -lt 0){'short'}else{'long'};leverage=[double]$p.leverage;liqPrice=[double]$p.liquidationPrice;markPrice=[double]$p.markPrice;unRealizedProfit=[double]$p.unRealizedProfit;initialMargin=([double]$p.notional/[Math]::Max(1,[double]$p.leverage));notional=[double]$p.notional;mode=([string]$p.marginType)} }
  $syms=@($positions.Keys); $st=RealStats $c $syms; $rm=$null; if($st){$rm=$st.data}
  $trp=0.0; $tcm=0.0
  foreach($s in $syms){ $ss=SymStats $rm $s
    if($ss){ $tk=Get-NumVal $ss 'taker'; $mk=Get-NumVal $ss 'maker'; $fr=0.0; if($tk -gt 0){$fr=$tk}else{$fr=$mk}
      $positions[$s]['realizedPnl']=Get-NumVal $ss 'realized'; $positions[$s]['feePaid']=Get-NumVal $ss 'commission'; $positions[$s]['fundingFee']=Get-NumVal $ss 'funding'; $positions[$s]['feeRate']=$fr
      $trp+=[double]$positions[$s]['realizedPnl']; $tcm+=[double]$positions[$s]['feePaid']
    } else { $positions[$s]['realizedPnl']=$null; $positions[$s]['feePaid']=$null; $positions[$s]['fundingFee']=$null; $positions[$s]['feeRate']=$null } }
  $o=[ordered]@{updatedAt=(NowIso);account=[ordered]@{walletBalance=[double]$a.totalWalletBalance;totalWalletBalance=[double]$a.totalWalletBalance;totalUnrealizedProfit=[double]$a.totalUnrealizedProfit;totalMarginBalance=[double]$a.totalMarginBalance;totalPositionInitialMargin=[double]$a.totalPositionInitialMargin;availableBalance=[double]$a.availableBalance;totalRealizedPnl=$trp;totalFeePaid=$tcm};positions=$positions}
  $j=$o|ConvertTo-Json -Depth 8; Write-Utf8 $OutJson $j; Write-Utf8 $OutJs ('window.__BINANCE_SUBACCOUNT__='+$j+';'); try{Write-Utf8 $OutJsonOkBak $j; Write-Utf8 $OutJsOkBak ('window.__BINANCE_SUBACCOUNT__='+$j+';')}catch{}; $script:BackoffSec = 0; Write-Host "OK subaccount positions=$($positions.Count) at $($o.updatedAt)"
}
try {
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  # stagger vs main account sync (main starts ~2s then loops 25s)
  Start-Sleep -Seconds 8
  while ($true) {
    try { Sync-Once }
    catch {
      $msg = $_.Exception.Message
      Write-Host "ERR $msg"
      if ($msg -match '418|429|Too Many Requests|teapot') {
        if ($script:BackoffSec -le 0) { $script:BackoffSec = 30 }
        else { $script:BackoffSec = [Math]::Min($MaxBackoffSec, [int]($script:BackoffSec * 2)) }
        Write-Host ("BACKOFF {0}s after rate limit" -f $script:BackoffSec)
      }
      Write-ErrorFile $msg
    }
    if ($Once) { break }
    $sleepSec = $LoopSleepSec
    if ($script:BackoffSec -gt 0) { $sleepSec = $script:BackoffSec }
    Start-Sleep -Seconds $sleepSec
  }
} catch { Write-ErrorFile $_.Exception.Message; throw }

