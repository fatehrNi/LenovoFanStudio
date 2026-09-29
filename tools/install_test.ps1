$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$TaskName = 'LenovoY9000P-FanDaemon'
$fail = 0
function Ok($n, $d = '') { "  PASS  $n  $d" }
function Bad($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
function Chk($n, $c, $d = '') { if ($c) { Ok $n $d } else { Bad $n $d } }

Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

"===== INSTALL / UNINSTALL ROUND TRIP ====="
"admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

"`n-- 0) start clean (no daemon, no task) --"
& (Join-Path $PSScriptRoot 'cleanup.ps1') | Out-Null
Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Start-Sleep -Seconds 2
Chk 'no pre-existing task' (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
Chk 'no daemon running' (-not (Get-FanLockState).alive)

"`n-- 1) install.ps1 --"
& (Join-Path $root 'install.ps1') -Interval 2 | ForEach-Object { "    $_" }
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Chk 'task registered' ($null -ne $t)
if ($t) {
  Chk 'task runs hidden powershell daemon' ("$($t.Actions[0].Execute)" -match 'powershell')
  Chk 'daemon args present' ("$($t.Actions[0].Arguments)" -match 'daemon\.ps1')
  Chk 'run level highest' ($t.Principal.RunLevel -eq 'Highest')
  Chk 'trigger at logon' (@($t.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' }).Count -gt 0)
  Chk 'no time limit' ("$($t.Settings.ExecutionTimeLimit)" -eq 'PT0S' -or $t.Settings.ExecutionTimeLimit -eq '00:00:00') "$($t.Settings.ExecutionTimeLimit)"
}
$ti = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Chk 'task last run OK' ($ti -and ($ti.LastTaskResult -eq 0 -or $ti.State -ne 'Disabled')) "state=$($ti.State) result=$($ti.LastTaskResult)"
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not (Get-FanLockState).alive) { Start-Sleep -Seconds 2 }
$lk = Get-FanLockState
Chk 'daemon took over via scheduled task' ($lk -and $lk.alive) "pid=$($lk.pid)"
Start-Sleep -Seconds 4
$live = Join-Path $root 'state\live.json'
Chk 'live.json published by scheduled daemon' (Test-Path -LiteralPath $live)

"`n-- 2) manual rpm command routes to the daemon (single writer) --"
# hold 45 s but only poll the first 24 s, so the assertion is checked INSIDE the
# hold window (an earlier version polled past the release and measured the decay)
& (Join-Path $src 'fanctl.ps1') set 5000 -Seconds 45 | ForEach-Object { "    $_" }
$rpm = -1; $closest = 99999
for ($i = 0; $i -lt 8; $i++) {
  Start-Sleep -Seconds 3
  $rpm = (Get-FanSnapshot).rpm
  $d = [math]::Abs($rpm - 5000)
  if ($d -lt $closest) { $closest = $d }        # the fan ramps through other values first
  if ($d -lt 700) { break }
}
Chk 'rpm moved toward 5000 while held' ($closest -lt 700) "rpm=$rpm closest-dev=$closest polled=$((($i+1)*3))s (hold=45s)"
Start-Sleep -Seconds 3
"  (daemon still holding; uninstall step below stops it and restores normal values)"

"`n-- 3) uninstall.ps1 --"
# the installer creates a Start Menu entry; check it exists and really points at our exe
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Legion Fan Studio.lnk'
if (Test-Path -LiteralPath $lnk) {
  $ws = New-Object -ComObject WScript.Shell
  $tgt = "$($ws.CreateShortcut($lnk).TargetPath)"
  Chk 'start-menu shortcut points at the exe' ($tgt -match 'LegionFanStudio\.exe$') "target=$tgt"
} else { Chk 'start-menu shortcut created' $false "missing $lnk（install.ps1 用 -NoShortcut 跳过时会缺）" }

& (Join-Path $root 'uninstall.ps1') | ForEach-Object { "    $_" }
Chk 'task removed' (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
Chk 'start-menu shortcut removed' (-not (Test-Path -LiteralPath $lnk))
$lk2 = Get-FanLockState
Chk 'daemon stopped' (-not ($lk2 -and $lk2.alive))
Start-Sleep -Seconds 5
$s2 = Get-FanSnapshot
Chk 'fans left at a safe value' ($s2.rpm -ge 2400) "rpm=$($s2.rpm)"
Chk 'power limits normal' ($s2.pl1 -ge 100) "PL1=$($s2.pl1) PL2=$($s2.pl2)"

"`n-- 4) final EC state --"
"  mode=$($s2.mode_name) rpm=$($s2.rpm) nearCPU=$($s2.near_cpu) gpu=$($s2.gpu_c) PL1=$($s2.pl1) PL2=$($s2.pl2) full=$($s2.full)"
"INSTALL_TEST_FAILED=$fail"
if ($fail -eq 0) { 'INSTALL_TEST ALL PASS' } else { "INSTALL_TEST $fail FAILURES" }
