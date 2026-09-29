<#
.SYNOPSIS
  本地可视化调参面板（零依赖：TcpListener + 单文件 HTML）
.DESCRIPTION
  刻意不用 HttpListener —— 它需要 urlacl 或管理员权限；TcpListener 绑 127.0.0.1 普通权限即可。
  面板不直接写 EC：读 state\live.json，命令写 state\cmd.json 交给守护进程消费，
  所以打开面板不需要管理员权限。实现了 HTTP/1.1 keep-alive + Expect:100-continue，
  避免 .NET/浏览器复用连接时请求丢失。
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [string]$Bind = '127.0.0.1',
  [switch]$NoBrowser,
  [int]$Requests = 0            # 处理 N 个请求后退出（0 = 常驻；自动化冒烟测试用）
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$src = Split-Path -Parent $PSCommandPath
$env:PSModulePath = "$src$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

$cfg = Get-FanConfig
if (-not $Port) { $Port = [int]$cfg.panel.port }
$liveFile = Join-Path $StateDir 'live.json'
$cmdFile = Join-Path $StateDir 'cmd.json'
$index = Join-Path $src 'www\index.html'
if (-not (Test-Path -LiteralPath $index)) { throw "缺少 $index" }

function Log($m) { Write-FanLog "[panel] $m" 'INFO' 'panel' }
function Read-JsonFile($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# ------------------------------------------------------------ HTTP plumbing
function Send-Raw($stream, [string]$text) { $b = [Text.Encoding]::ASCII.GetBytes($text); $stream.Write($b, 0, $b.Length) }
function Send-Resp($stream, [int]$code, [string]$ctype, [byte[]]$body, [bool]$keep = $false) {
  $status = switch ($code) { 200 { 'OK' } 400 { 'Bad Request' } 404 { 'Not Found' } 405 { 'Method Not Allowed' } 500 { 'Server Error' } default { 'OK' } }
  $head = "HTTP/1.1 $code $status`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: $(if ($keep) { 'keep-alive' } else { 'close' })`r`n`r`n"
  Send-Raw $stream $head
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}
function Send-Text($stream, [int]$code, [string]$text, [bool]$keep = $false, [string]$ctype = 'text/plain; charset=utf-8') {
  Send-Resp $stream $code $ctype ([Text.Encoding]::UTF8.GetBytes($text)) $keep
}
function Send-Json($stream, [int]$code, $obj, [bool]$keep = $false) {
  # PS 5.1: piping an empty collection makes ConvertTo-Json emit nothing, and a
  # null body then throws inside UTF8.GetBytes. Always emit valid JSON.
  $json = ($obj | ConvertTo-Json -Depth 12 -Compress)
  if ($null -eq $json -or "$json" -eq '') { $json = 'null' }
  Send-Text $stream $code ([string]$json) $keep 'application/json; charset=utf-8'
}

function Read-Chunk($ns, $buf, [int]$ms) {
  <# Non-blocking-ish read: a browser opens speculative connections and holds
     keep-alive sockets idle; a plain blocking Read() would stall the whole
     single-threaded loop and make later requests time out. #>
  try { $ar = $ns.BeginRead($buf, 0, $buf.Length, $null, $null) } catch { return $null }
  if (-not $ar.AsyncWaitHandle.WaitOne($ms, $false)) {
    try { $ns.Close() } catch { }
    return $null
  }
  try { $n = $ns.EndRead($ar) } catch { return $null }
  if ($n -le 0) { return $null }
  return [Text.Encoding]::ASCII.GetString($buf, 0, $n)
}

function Read-HttpRequest($ns, $buf) {
  <# One HTTP request (headers + Content-Length body). Answers
     Expect: 100-continue itself, else the client never sends the body. #>
  $txt = ''
  $sent100 = $false
  for ($g = 0; $g -lt 16; $g++) {
    $hidx = $txt.IndexOf("`r`n`r`n")
    if ($hidx -ge 0) {
      $cl = 0
      foreach ($hl in ($txt.Substring(0, $hidx) -split "`r`n")) { if ($hl -match '(?i)^content-length:\s*(\d+)') { $cl = [int]$matches[1] } }
      if ($txt.Length - ($hidx + 4) -ge $cl) { break }
      if (-not $sent100 -and $txt -match '(?i)^expect:\s*100-continue') {
        Send-Raw $ns "HTTP/1.1 100 Continue`r`n`r`n"; $ns.Flush(); $sent100 = $true
      }
    }
    $chunk = Read-Chunk $ns $buf 800
    if ($null -eq $chunk) { break }
    $txt += $chunk
    if ($txt.Length -gt 200000) { return $null }
  }
  $h = $txt.IndexOf("`r`n`r`n")
  if ($h -lt 0) { return $null }
  $headText = $txt.Substring(0, $h)
  $cl2 = 0
  foreach ($hl in ($headText -split "`r`n")) { if ($hl -match '(?i)^content-length:\s*(\d+)') { $cl2 = [int]$matches[1] } }
  $body = ''
  if ($cl2 -gt 0) {
    $body = $txt.Substring($h + 4)
    if ($body.Length -gt $cl2) { $body = $body.Substring(0, $cl2) }
  }
  return [pscustomobject]@{ Head = $headText; Body = $body }
}

# ------------------------------------------------------------ panel actions
function Get-LivePayload {
  $j = Read-JsonFile $liveFile
  $lk = Get-FanLockState
  $age = -1
  if ($j -and $j.snap -and $j.snap.time) { try { $age = [int](((Get-Date) - [datetime]::Parse($j.snap.time)).TotalSeconds) } catch { } }
  $payload = [ordered]@{
    daemon = [ordered]@{ running = [bool]($lk -and $lk.alive); pid = $(if ($lk) { $lk.pid } else { 0 }); who = $(if ($lk) { $lk.who } else { '' }) }
    live   = $j
    age_s  = $age
    ts     = (Get-Date -Format 'HH:mm:ss')
  }
  if (-not $j) {
    try {
      Connect-FanWmi -Quiet | Out-Null
      $s = Get-FanSnapshot
      if ($s.ok) {
        $c = Get-FanConfig
        $payload['live'] = [pscustomobject]@{
          snap = $s; profile = "$($c.active_profile)"; label = "$($c.profiles.($c.active_profile).label)"
          mode = 'direct'; last_target = -1; series = @(); uptime_s = 0; desired = (Get-FanDesiredRpm -Snap $s)
        }
        $payload['direct_read'] = $true
      } else { $payload['direct_error'] = "$($s.err)" }
    } catch { $payload['direct_error'] = $_.Exception.Message }
  }
  return $payload
}

$script:rid = 1000
function Invoke-CmdToDaemon([string]$type, [hashtable]$argH = @{}) {
  $script:rid++
  [pscustomobject]@{ id = $script:rid; type = $type; args = $argH; at = (Get-Date -Format 'o') } |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath "$cmdFile.tmp" -Encoding UTF8
  Move-Item -LiteralPath "$cmdFile.tmp" -Destination $cmdFile -Force
  Log "-> daemon: $type $(if ($argH.Count) { ($argH | ConvertTo-Json -Compress) })"
}
function Save-ProfileCurve([string]$profile, [string]$which, [string]$spec) {
  $c = Get-FanConfig
  if (-not $c.profiles.PSObject.Properties[$profile]) { throw "未知档位 $profile" }
  if ($which -notin 'cpu', 'gpu') { throw 'which 只能是 cpu / gpu' }
  Parse-FanCurve -Spec $spec | Out-Null            # validates, throws on bad input
  $c.profiles.$profile | Add-Member -NotePropertyName $which -NotePropertyValue $spec -Force
  Save-FanConfig -Config $c -Why 'panel:curve'
  Invoke-CmdToDaemon 'reload' @{}
}
function Save-Safety([hashtable]$kv) {
  $c = Get-FanConfig
  $allow = 'rpm_floor', 'rpm_ceiling', 'nearcpu_crit', 'gpu_crit', 'write_gap_ms', 'manual_timeout_s', 'exit_rpm', 'reassert_gap_s'
  foreach ($k in $kv.Keys) { if (($k -in $allow) -and ($null -ne $c.safety.PSObject.Properties[$k])) { $c.safety.$k = [int]$kv[$k] } }
  if ($c.safety.rpm_floor -lt 1500 -or $c.safety.rpm_floor -gt 6000) { throw 'rpm_floor 需在 1500-6000 之间' }
  if ($c.safety.rpm_ceiling -gt 6600) { $c.safety.rpm_ceiling = 6600 }
  if ($c.safety.rpm_ceiling -le $c.safety.rpm_floor) { throw 'rpm_ceiling 必须大于 rpm_floor' }
  Save-FanConfig -Config $c -Why 'panel:safety'
  Invoke-CmdToDaemon 'reload' @{}
}
function Save-LoadBoost([hashtable]$kv) {
  $c = Get-FanConfig
  if ($kv.ContainsKey('per_10pct_util')) { $c.load_boost.per_10pct_util = [double]$kv['per_10pct_util'] }
  if ($kv.ContainsKey('max_add_c')) { $c.load_boost.max_add_c = [double]$kv['max_add_c'] }
  if ($kv.ContainsKey('cpu_offset')) { $c.telemetry.cpu_offset = [double]$kv['cpu_offset'] }
  Save-FanConfig -Config $c -Why 'panel:load-boost'
  Invoke-CmdToDaemon 'reload' @{}
}

# ------------------------------------------------------------ dispatch
function Invoke-Dispatch($ns, [string]$method, [string]$path, [string]$body, [bool]$keep) {
  if ($path -eq '/') {
    Send-Resp $ns 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($index)) $keep
  }
  elseif ($path -eq '/api/live') { Send-Json $ns 200 (Get-LivePayload) $keep }
  elseif ($path -eq '/api/config') {
    $c = Get-FanConfig
    Send-Json $ns 200 ([pscustomobject]@{ config = $c; active = "$($c.active_profile)"; warnings = @(Get-FanCurveIssue -Config $c); daemon = [bool]((Get-FanLockState).alive) }) $keep
  }
  elseif ($path -eq '/api/history') {
    $lj = Read-JsonFile $liveFile
    if ($lj -and $lj.series) { $rows = @($lj.series) } else { $rows = @(Get-FanHistory -Tail 80) }
    Send-Json $ns 200 @{ rows = $rows; count = $rows.Count } $keep
  }
  elseif ($path -eq '/api/log') {
    # PS 5.1's `Get-Content -Tail -Encoding UTF8` HANGS on our CJK UTF-8 logs
    # (reproduced standalone, with no other process involved). Serve the
    # daemon's snapshot file, else the share-safe byte reader.
    $f = Join-Path $StateDir 'logtail.json'
    if (Test-Path -LiteralPath $f) { $raw = Read-JsonFile $f } else { $raw = @(Get-SharedTailLines -Path (Join-Path $LogDir 'fan.log') -Count 60) }
    $lines = @($raw)
    Send-Json $ns 200 @{ lines = $lines; count = $lines.Count } $keep
  }
  elseif ($path -eq '/api/cmd') {
    if ($method -ne 'POST') { Send-Text $ns 405 'POST only' $keep; return }
    try {
      $req = $body | ConvertFrom-Json
      $type = "$($req.type)".ToLower()
      $a = @{}
      if ($req.args) { foreach ($p in $req.args.PSObject.Properties) { $a[$p.Name] = $p.Value } }
      if ($type -eq 'curve') { Save-ProfileCurve -profile ([string]$a.profile) -which ([string]$a.which) -spec ([string]$a.spec) }
      elseif ($type -eq 'safety') { Save-Safety -kv $a }
      elseif ($type -eq 'boostcfg') { Save-LoadBoost -kv $a }
      elseif ($type -in @('profile', 'mode', 'rpm', 'boost', 'limit', 'reset', 'pause', 'resume', 'reload', 'stop')) { Invoke-CmdToDaemon $type $a }
      else { Send-Json $ns 400 ([pscustomobject]@{ ok = $false; error = "未知命令类型: $type" }) $keep; return }
      Send-Json $ns 200 ([pscustomobject]@{ ok = $true; type = $type }) $keep
    } catch {
      Log "cmd error: $($_.Exception.Message)"
      Send-Json $ns 400 ([pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" }) $keep
    }
  }
  else { Send-Text $ns 404 'not found' $keep }
}

# ------------------------------------------------------------ accept loop
$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Parse($Bind), $Port)
$listener.Start()
$url = "http://${Bind}:$Port/"
Log "listening on $url"
Write-Host "面板已启动: $url" -ForegroundColor Green
Write-Host 'Ctrl+C 退出。面板无需管理员权限（EC 写入由守护进程执行）。' -ForegroundColor Cyan
if (-not $NoBrowser) { try { Start-Process $url } catch { Log "打开浏览器失败: $($_.Exception.Message)" } }

$maxRequests = [int]$Requests
$served = 0
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    $ns = $null
    try {
      $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
      $ns = $client.GetStream()
      $buf = New-Object byte[] 32768
      $req = Read-HttpRequest $ns $buf
      if ($req) {
        $hl = $req.Head -split "`r`n"
        $segs = ($hl[0] -split ' ')
        if ($segs.Count -ge 2) {
        $method = $segs[0]
        $path = ($segs[1] -split '\?')[0]
        $t0 = Get-Date
        Log "$method $path"
        try {
          # one request per connection: reply with Connection: close and hang up,
          # so an idle speculative socket can never block the next client
          Invoke-Dispatch $ns $method $path $req.Body $false
          Log "<- $path done in $([int]((Get-Date) - $t0).TotalMilliseconds)ms"
        } catch {
          Log "<- $path FAILED in $([int]((Get-Date) - $t0).TotalMilliseconds)ms : $($_.Exception.Message)"
        }
        $served++
        }
      }
    } catch {
      Log "conn error: $($_.Exception.Message)"
    } finally {
      try { if ($ns) { $ns.Close() } } catch { }
      try { $client.Close() } catch { }
    }
    if ($maxRequests -gt 0 -and $served -ge $maxRequests) { break }
  }
} finally {
  try { $listener.Stop() } catch { }
  Log "stopped (served $served requests)"
}
