$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'

"########## A) daemon foreground run (capture the exception that kills iteration 1) ##########"
try {
  & (Join-Path $src 'daemon.ps1') -RunFor 12 -Interval 2 2>&1 | ForEach-Object {
    if ($_ -is [Management.Automation.ErrorRecord]) { "  ERR: $($_.Exception.Message)  @ line $($_.InvocationInfo.ScriptLineNumber)" }
    else { "  OUT: $_" }
  }
} catch { "  OUTER: $($_.Exception.Message)" }
"  exit code: $LASTEXITCODE"
"  live.json exists: $(Test-Path (Join-Path $root 'state\live.json'))"
"  --- daemon self-reported errors (fan.log) ---"
Get-Content -LiteralPath (Join-Path $root 'logs\fan.log') -Tail 14 -Encoding UTF8 | Where-Object { $_ -match '异常|本轮|退出' } | ForEach-Object { "    $_" }

"`n########## B) panel: raw-socket probes (one connection per request) ##########"
$panel = Start-Process -FilePath $ps -PassThru -WindowStyle Hidden -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\panel.ps1`"", '-NoBrowser', '-Requests', '8')
Start-Sleep -Seconds 5

function Probe([string]$req) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', 4765)
    $s = $c.GetStream()
    $s.ReadTimeout = 6000
    $b = [Text.Encoding]::ASCII.GetBytes($req)
    $s.Write($b, 0, $b.Length); $s.Flush()
    $buf = New-Object byte[] 65536
    $tot = 0
    while ($true) {
      try { $n = $s.Read($buf, $tot, $buf.Length - $tot) } catch { break }
      if ($n -le 0) { break }
      $tot += $n
      if ($tot -ge 40000) { break }
      if ($s.DataAvailable -eq $false) { Start-Sleep -Milliseconds 150; if (-not $s.DataAvailable) { break } }
    }
    $c.Close()
    $resp = [Text.Encoding]::UTF8.GetString($buf, 0, $tot)
    $first = ($resp -split "`r`n")[0]
    $cl = 0; if ($resp -match '(?i)content-length:\s*(\d+)') { $cl = [int]$matches[1] }
    "  {0,-34} {1,-22} body={2}/{3} bytes  {4}ms" -f $req.Split("`n")[0].Trim(), $first, $tot, $cl, [int]$sw.ElapsedMilliseconds
  } catch {
    "  {0,-34} EXC {1}  ({2}ms)" -f $req.Split("`n")[0].Trim(), $_.Exception.Message, [int]$sw.ElapsedMilliseconds
  }
}

$H = "Host: 127.0.0.1`r`nConnection: close`r`n`r`n"
Probe "GET /api/log HTTP/1.1`r`n$H"
Probe "GET /api/live HTTP/1.1`r`n$H"
Probe "GET /api/config HTTP/1.1`r`n$H"
Probe "GET /api/history HTTP/1.1`r`n$H"
Probe "GET / HTTP/1.1`r`n$H"
Probe "GET /api/nope HTTP/1.1`r`n$H"
$body = '{"type":"reload","args":{}}'
Probe "POST /api/cmd HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
Start-Sleep -Seconds 2
if (-not $panel.HasExited) { "  (panel still alive -> stopping)"; $panel.Kill() }
'DIAG2_DONE'
