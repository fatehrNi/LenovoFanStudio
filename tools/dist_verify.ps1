$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $root 'dist\LegionFanStudio-v1.0.0'
$exe = Join-Path $dist 'LegionFanStudio.exe'
$ps = (Get-Command powershell.exe).Source
$fail = 0
function Chk($n, $c, $d = '') { if ($c) { "  PASS  $n  $d" } else { $script:fail++; "  FAIL  $n  $d" } }

"===== 打包产物硬件链路验证（dist\$） ====="
"admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
if (-not (Test-Path -LiteralPath $exe)) { throw "找不到 $exe，先跑 build\build.ps1" }

# 0) clean slate: stop repo daemon/panel and any exe instance
& (Join-Path $PSScriptRoot 'cleanup.ps1') | Out-Null
Get-Process -Name LegionFanStudio -ErrorAction SilentlyContinue | Stop-Process -Force
Get-ChildItem -LiteralPath (Join-Path $dist 'state') -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Start-Sleep -Seconds 2

"`n-- 1) dist 守护进程（独立数据目录）--"
$dv = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dist 'src\daemon.ps1'), '-Interval', '2')
$live = Join-Path $dist 'state\live.json'
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $live)) { Start-Sleep -Milliseconds 800 }
Chk 'dist daemon published live.json' (Test-Path -LiteralPath $live)
Start-Sleep -Seconds 6

"`n-- 2) 托盘 exe 读真实状态 --"
$s = & $exe --status 2>&1 | Out-String
Chk '--status exit 0' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
Chk '--status shows real rpm' ($s -match 'RPM' -and $s -notmatch '未托管') ($s.Trim())

"`n-- 3) 打包 exe 自检（含与守护进程的信报通路）--"
$t = & $exe --selftest 2>&1 | Out-String
Chk 'selftest ALL PASS' ($t -match 'SELFTEST ALL PASS') "exit=$LASTEXITCODE"
($t -split "`r?`n" | Where-Object { $_ -match 'FAIL|SKIP' -or $_ -match 'snap rpm|profile name|mailbox consumed|series' }) | ForEach-Object { "       $($_.Trim())" }

"`n-- 4) 面板从 dist 目录服务 --"
$pv = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dist 'src\panel.ps1'), '-NoBrowser')
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Seconds 1
  try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/live' -TimeoutSec 4; if ($r.daemon.running) { $ok = $true; break } } catch { }
}
Chk 'dist panel serving + sees daemon' $ok "rpm=$($r.live.snap.rpm)"

"`n-- 5) 一次真实的转速命令（只往高提，8 秒后交还曲线）--"
& (Join-Path $dist 'src\fanctl.ps1') set 5600 -Seconds 8 | Out-Null
$seen = -1
for ($i = 0; $i -lt 6; $i++) {
  Start-Sleep -Seconds 3
  $j = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/live' -TimeoutSec 6
  $seen = $j.live.snap.rpm
  if ([math]::Abs($seen - 5600) -lt 700) { break }
}
Chk 'dist command drove the fan' ([math]::Abs($seen - 5600) -lt 700) "rpm=$seen"
Start-Sleep -Seconds 12
$j2 = Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/live' -TimeoutSec 6
Chk 'released back to curve' ("$($j2.live.mode)" -eq 'auto') "mode=$($j2.live.mode) rpm=$($j2.live.snap.rpm)"

"`n-- 6) 收尾：停 dist 实例，恢复默认值，重新托管仓库版守护进程 --"
Invoke-RestMethod -Uri 'http://127.0.0.1:4765/api/cmd' -Method Post -Body '{"type":"reset","args":{}}' -ContentType 'application/json' -TimeoutSec 8 | Out-Null
Start-Sleep -Seconds 4
try { Stop-Process -Id $pv.Id -Force } catch { }
try { Stop-Process -Id $dv.Id -Force } catch { }
Start-Sleep -Seconds 2
& (Join-Path $PSScriptRoot 'cleanup.ps1') | Out-Null
$null = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'src\daemon.ps1'), '-Interval', '2')
Start-Sleep -Seconds 8
$null = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'src\panel.ps1'), '-NoBrowser')
Start-Sleep -Seconds 4
Import-Module (Join-Path $root 'src\LenovoFan.psm1') -Force -DisableNameChecking
$s2 = Get-FanSnapshot
"  最终 EC: $($s2.mode_name)  rpm=$($s2.rpm)  nearCPU=$($s2.near_cpu)°C  gpu=$($s2.gpu_c)°C  PL1=$($s2.pl1)W PL2=$($s2.pl2)W  full=$($s2.full)"
Chk 'fans at a normal value' ($s2.rpm -ge 2400) "rpm=$($s2.rpm)"
Chk 'power limits normal' ($s2.pl1 -ge 100) "PL1=$($s2.pl1)"
"DIST_VERIFY_FAILED=$fail"
if ($fail -eq 0) { 'DIST_VERIFY ALL PASS' } else { "DIST_VERIFY $fail FAILURES" }
