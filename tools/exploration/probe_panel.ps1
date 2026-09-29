$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$logf = Join-Path $root 'logs\panel.log'

# start a fresh panel that exits after 8 requests
Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\panel.ps1`"", '-NoBrowser', '-Requests', '8') | Out-Null
Start-Sleep -Seconds 4

function Probe([string]$label, [string]$req) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', 4765)
    $s = $c.GetStream(); $s.ReadTimeout = 5000
    $b = [Text.Encoding]::ASCII.GetBytes($req); $s.Write($b, 0, $b.Length); $s.Flush()
    $buf = New-Object byte[] 131072; $tot = 0
    while ($tot -lt $buf.Length) {
      try { $n = $s.Read($buf, $tot, $buf.Length - $tot) } catch { break }
      if ($n -le 0) { break }
      $tot += $n
      if (-not $s.DataAvailable) { Start-Sleep -Milliseconds 120; if (-not $s.DataAvailable) { break } }
    }
    $c.Close()
    $resp = [Text.Encoding]::UTF8.GetString($buf, 0, $tot)
    $cl = 0; if ($resp -match '(?i)content-length:\s*(\d+)') { $cl = [int]$matches[1] }
    "  {0,-14} got={1,6}B declared={2,6}B  {3,5}ms  status={4}" -f $label, $tot, $cl, [int]$sw.ElapsedMilliseconds, (($resp -split "`r`n")[0])
  } catch {
    "  {0,-14} EXC {1} ({2}ms)" -f $label, $_.Exception.Message, [int]$sw.ElapsedMilliseconds
  }
}
$H = "Host: 127.0.0.1`r`nConnection: close`r`n`r`n"
"=== raw socket probes (no admin) ==="
Probe 'GET /' "GET / HTTP/1.1`r`n$H"
Probe 'GET /api/config' "GET /api/config HTTP/1.1`r`n$H"
Probe 'GET /api/log' "GET /api/log HTTP/1.1`r`n$H"
Probe 'GET /api/history' "GET /api/history HTTP/1.1`r`n$H"
Probe 'GET /api/live' "GET /api/live HTTP/1.1`r`n$H"
Probe 'GET /404' "GET /nope HTTP/1.1`r`n$H"
$body = '{"type":"reload","args":{}}'
Probe 'POST /api/cmd' "POST /api/cmd HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"

Start-Sleep -Seconds 2
"=== panel.log tail ==="
$logLines = @(); try { $fs=[IO.File]::Open($logf,'Open','Read','ReadWrite'); $sr=New-Object IO.StreamReader($fs,[Text.UTF8Encoding]::new($false)); while(-not $sr.EndOfStream){$logLines+=$sr.ReadLine()}; $fs.Dispose() } catch {}; $logLines | Select-Object -Last 18 | ForEach-Object { "  $_" }
'PANEL_PROBE_DONE'
