$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'

& (Join-Path $PSScriptRoot 'cleanup.ps1')
Start-Sleep -Seconds 2
$stale = netstat -ano | Select-String ':4765\s.*LISTENING'
if ($stale) { "!! 4765 仍有监听进程:"; $stale | ForEach-Object { "   $_" }; exit 1 }

"=== start panel with ITS OWN stdout/stderr files (no inherited pipe) ==="
Start-Process -FilePath $ps -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $root 'state\panel.out') `
  -RedirectStandardError (Join-Path $root 'state\panel.err') `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\panel.ps1`"", '-NoBrowser', '-Requests', '9')
Start-Sleep -Seconds 4

foreach ($p in @('/', '/api/live', '/api/config', '/api/log', '/api/history', '/api/nope')) {
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:4765$p" -UseBasicParsing -DisableKeepAlive -TimeoutSec 6
    "  {0,-14} {1}  {2,7}B  {3,5}ms" -f $p, $r.StatusCode, $r.RawContentLength, [int]$sw.ElapsedMilliseconds
  } catch { "  {0,-14} FAIL {1}" -f $p, $_.Exception.Message }
}
$b = '{"type":"reload","args":{}}'
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $b -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec 6
  "  POST /api/cmd   $($r.StatusCode) $($r.Content)"
} catch { "  POST /api/cmd   FAIL $($_.Exception.Message)" }
"=== panel.err (if any) ==="
$e = Get-Content -LiteralPath (Join-Path $root 'state\panel.err') -Raw -ErrorAction SilentlyContinue
if ($e) { $e } else { '(empty)' }
'PANEL_TEST_DONE'
