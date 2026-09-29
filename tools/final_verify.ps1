$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psw = (Get-Command powershell.exe).Source
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

"################ FINAL VERIFICATION  $(Get-Date -Format 'yyyy-MM-dd HH:mm') ################"

"===== A) offline logic unit tests ====="
& (Join-Path $PSScriptRoot 'unit-tests.ps1') | Select-Object -Last 2

"`n===== B) hardware + UI end-to-end smoke ====="
& (Join-Path $PSScriptRoot 'cleanup.ps1') | Out-Null
Start-Sleep -Seconds 2
& (Join-Path $PSScriptRoot 'smoke.ps1') | Select-String -Pattern 'FAIL|SMOKE_RESULT|-- \d\)' | ForEach-Object { "  $_" }

"`n===== C) install / uninstall round trip ====="
& (Join-Path $PSScriptRoot 'cleanup.ps1') | Out-Null
Start-Sleep -Seconds 2
& (Join-Path $PSScriptRoot 'install_test.ps1') | Select-String -Pattern 'FAIL|PASS  task|PASS  daemon|PASS  rpm|PASS  fans|PASS  power|INSTALL_TEST|-- \d\)|final EC|mode=' | ForEach-Object { "  $_" }

"`n===== D) leave the product running, machine safe ====="
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'daemon\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Start-Process -FilePath $psw -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $root 'state\daemon.out') -RedirectStandardError (Join-Path $root 'state\daemon.err') `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\daemon.ps1`"", '-Interval', '2') | Out-Null
Start-Sleep -Seconds 10
$lk = Get-FanLockState
"  daemon: $(if ($lk -and $lk.alive) { "running pid=$($lk.pid) ($($lk.who))" } else { 'NOT running' })"
if (-not (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'panel\.ps1' })) {
  Start-Process -FilePath $psw -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $root 'state\panel.out') -RedirectStandardError (Join-Path $root 'state\panel.err') `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$src\panel.ps1`"", '-NoBrowser') | Out-Null
  Start-Sleep -Seconds 4
}
try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec 8; "  panel: serving (http://127.0.0.1:4765/)" } catch { "  panel: NOT serving - $($_.Exception.Message)" }
$s = Get-FanSnapshot
"  EC state: $($s.mode_name)  rpm=$($s.rpm)  nearCPU=$($s.near_cpu)°C  gpu=$($s.gpu_c)°C  PL1=$($s.pl1)W PL2=$($s.pl2)W  full=$($s.full)"
"  auto-start task installed: $([bool](Get-ScheduledTask -TaskName 'LenovoY9000P-FanDaemon' -ErrorAction SilentlyContinue))  (安装开机自启.cmd 可开启)"
'FINAL_VERIFY_DONE'
