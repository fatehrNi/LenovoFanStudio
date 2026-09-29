$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'

# restart the panel (it only reads files, no admin needed) so it picks up the module fix
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'panel\.ps1' } | ForEach-Object {
  "stopping old panel pid=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
Start-Process -FilePath $ps -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $root 'state\panel.out') -RedirectStandardError (Join-Path $root 'state\panel.err') `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\panel.ps1`"", '-NoBrowser') | Out-Null
Start-Sleep -Seconds 5

"=== /api/log shape ==="
try {
  $d = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/log' -TimeoutSec 10
  "  lines type : $($d.lines.GetType().Name)"
  "  lines count: $($d.lines.Count)  declared=$($d.count)"
  "  first line : $($d.lines[0])"
  "  last line  : $($d.lines[-1])"
} catch { "  FAIL $($_.Exception.Message)" }

"=== /api/live ==="
try {
  $l = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/live' -TimeoutSec 10
  "  daemon running=$($l.daemon.running) pid=$($l.daemon.pid) rpm=$($l.live.snap.rpm) target=$($l.live.last_target)"
  "  mode=$($l.live.snap.mode_name) nearCPU=$($l.live.snap.near_cpu) gpu=$($l.live.snap.gpu_c) PL1=$($l.live.snap.pl1)"
  "  profile=$($l.live.profile) engine=$($l.live.mode) series=$($l.live.series.Count)"
} catch { "  FAIL $($_.Exception.Message)" }

"=== /api/history shape ==="
try {
  $h = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/history' -TimeoutSec 10
  "  rows type=$($h.rows.GetType().Name) count=$($h.count)"
} catch { "  FAIL $($_.Exception.Message)" }
'RELOAD_DONE'
