param(
  [switch]$Once,
  [int]$MinIntervalSec = 240,   # 4 minutes default (3-5 min window)
  [int]$LoopSleepSec = 60
)
$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dir) { $Dir = "C:\Users\Administrator\Desktop\binance-jiancang-public" }
Set-Location $Dir

$Owner = "jianzhongwangace"
$Repo = "binance-jiancang-public"
$Branch = "master"
$LiveFiles = @(
  "positions_live.js",
  "positions_live.json",
  "subaccount_live.js",
  "subaccount_live.json"
)
# Optional HTML files only when PublishHtml switch used elsewhere; default live-only
$StateFile = Join-Path $Dir "publish_live_state.json"
$LogFile = Join-Path $Dir "publish_live.log"

function Write-Log([string]$msg) {
  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Clear-ProxyEnv {
  foreach ($n in @("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","ALL_PROXY","all_proxy")) {
    Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable($n, $null, "Process")
  }
}

function Get-GithubToken {
  $env:GIT_TERMINAL_PROMPT = "0"
  $input = "protocol=https`nhost=github.com`n`n"
  $out = $input | & git credential fill 2>$null
  if ($LASTEXITCODE -ne 0) { throw "git credential fill failed (no stored GitHub creds)" }
  $pass = ($out | Where-Object { $_ -like "password=*" } | Select-Object -First 1)
  if (-not $pass) { throw "no password in credential helper" }
  return $pass.Substring("password=".Length)
}

function Invoke-GhApi {
  param(
    [string]$Method,
    [string]$Path,
    [object]$Body = $null,
    [string]$Token
  )
  Clear-ProxyEnv
  $headers = @{
    Authorization = "Bearer $Token"
    Accept = "application/vnd.github+json"
    "User-Agent" = "binance-jiancang-publish"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
  $uri = "https://api.github.com$Path"
  $params = @{
    Uri = $uri
    Method = $Method
    Headers = $headers
    UseBasicParsing = $true
    TimeoutSec = 60
  }
  if ($null -ne $Body) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    $params.ContentType = "application/json; charset=utf-8"
    $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
  }
  return Invoke-RestMethod @params
}

function Get-FileSha256([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Read-State {
  if (Test-Path -LiteralPath $StateFile) {
    try { return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ lastPublishUnix = 0; fileHashes = @{} }
}

function Write-State($state) {
  ($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Publish-Once {
  Clear-ProxyEnv
  $state = Read-State
  $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $elapsed = $now - [int64]$state.lastPublishUnix
  if ($elapsed -lt $MinIntervalSec) {
    Write-Log ("skip throttle elapsed={0}s need={1}s" -f $elapsed, $MinIntervalSec)
    return $false
  }

  $changed = @()
  $hashes = @{}
  if ($state.fileHashes) {
    foreach ($p in $state.fileHashes.PSObject.Properties) {
      if ($p.Name -in @('IsFixedSize','IsReadOnly','IsSynchronized','Keys','Values','SyncRoot','Count')) { continue }
      if ($p.Name -match '^(positions_live|subaccount_live)\.(js|json)$') {
        $hashes[$p.Name] = [string]$p.Value
      }
    }
  }
  foreach ($f in $LiveFiles) {
    $p = Join-Path $Dir $f
    if (-not (Test-Path -LiteralPath $p)) { throw "missing $f" }
    $h = Get-FileSha256 $p
    if (-not $hashes.ContainsKey($f) -or $hashes[$f] -ne $h) { $changed += $f }
    $hashes[$f] = $h
  }
  if ($changed.Count -eq 0) {
    Write-Log "skip no content change"
    return $false
  }

  # Safety: refuse if any live file looks like env/secrets
  foreach ($f in $changed) {
    $raw = Get-Content -LiteralPath (Join-Path $Dir $f) -Raw -Encoding UTF8
    if ($raw -match 'BINANCE_API_KEY|APISECRET|apiSecret|BEGIN (RSA |OPENSSH )?PRIVATE KEY') {
      throw "refusing to publish secret-like content in $f"
    }
  }

  $token = Get-GithubToken
  $ref = Invoke-GhApi -Method GET -Path "/repos/$Owner/$Repo/git/ref/heads/$Branch" -Token $token
  $commitSha = $ref.object.sha
  $commit = Invoke-GhApi -Method GET -Path "/repos/$Owner/$Repo/git/commits/$commitSha" -Token $token
  $baseTree = $commit.tree.sha

  $treeItems = @()
  foreach ($f in $LiveFiles) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Dir $f))
    $b64 = [Convert]::ToBase64String($bytes)
    $blob = Invoke-GhApi -Method POST -Path "/repos/$Owner/$Repo/git/blobs" -Token $token -Body @{
      content = $b64
      encoding = "base64"
    }
    $treeItems += @{
      path = $f
      mode = "100644"
      type = "blob"
      sha = $blob.sha
    }
  }

  $tree = Invoke-GhApi -Method POST -Path "/repos/$Owner/$Repo/git/trees" -Token $token -Body @{
    base_tree = $baseTree
    tree = $treeItems
  }

  $msg = "auto(live): refresh public snapshots ({0})" -f (($changed -join ", "))
  $newCommit = Invoke-GhApi -Method POST -Path "/repos/$Owner/$Repo/git/commits" -Token $token -Body @{
    message = $msg
    tree = $tree.sha
    parents = @($commitSha)
  }

  Invoke-GhApi -Method PATCH -Path "/repos/$Owner/$Repo/git/refs/heads/$Branch" -Token $token -Body @{
    sha = $newCommit.sha
    force = $false
  } | Out-Null

  $hashObj = [ordered]@{}
  foreach ($k in $hashes.Keys) { $hashObj[$k] = [string]$hashes[$k] }
  $state = [pscustomobject]@{
    lastPublishUnix = $now
    lastCommit = $newCommit.sha
    lastFiles = @($changed)
    fileHashes = [pscustomobject]$hashObj
  }
  Write-State $state
  Write-Log ("PUSH_OK commit={0} files={1}" -f $newCommit.sha, ($changed -join ","))
  return $true
}

Write-Log "publisher start Once=$Once MinIntervalSec=$MinIntervalSec"
if ($Once) {
  try {
    [void](Publish-Once)
    exit 0
  } catch {
    Write-Log ("PUSH_ERR {0}" -f $_.Exception.Message)
    exit 1
  }
}

while ($true) {
  try { [void](Publish-Once) } catch { Write-Log ("PUSH_ERR {0}" -f $_.Exception.Message) }
  Start-Sleep -Seconds $LoopSleepSec
}
