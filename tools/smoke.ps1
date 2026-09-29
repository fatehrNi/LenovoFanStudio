$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::DefaultConnectionLimit = 32
$TO = 15
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$state = Join-Path $root 'state'
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fail = 0
function Ok($n, $d = '') { "  PASS  $n  $d" }
function Bad($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
function Check($n, $c, $d = '') { if ($c) { Ok $n $d } else { Bad $n $d } }

"===== SMOKE TEST (running elevated) ====="
"admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

"`n-- 1) daemon: start detached --"
Remove-Item -LiteralPath (Join-Path $state 'live.json') -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$src\daemon.ps1`"", '-Interval', '2', '-Force'
Start-Sleep -Seconds 10
$live = Join-Path $state 'live.json'
Check 'live.json created' (Test-Path -LiteralPath $live)
if (Test-Path -LiteralPath $live) {
  $j = Get-Content -LiteralPath $live -Raw -Encoding UTF8 | ConvertFrom-Json
  Check 'daemon reports rpm'       ($j.snap.rpm -gt 1000) "rpm=$($j.snap.rpm)"
  Check 'daemon reports temps'     ($j.snap.near_cpu -gt 20) "nearCPU=$($j.snap.near_cpu) gpu=$($j.snap.gpu_c)"
  Check 'daemon reports power'     ($j.snap.pl1 -gt 0) "PL1=$($j.snap.pl1) PL2=$($j.snap.pl2)"
  Check 'daemon computed target'   ($j.last_target -ge 2400) "target=$($j.last_target) via $($j.desired.why)"
  Check 'daemon publishes series'  (@($j.series).Count -gt 1) "samples=$(($j.series | Measure-Object).Count)"
  Check 'daemon mode label'        ($j.mode -ne $null) "mode=$($j.mode) profile=$($j.profile)"
}
$lk = Get-FanLockState
Check 'lock file live'  ($lk -and $lk.alive) "pid=$($lk.pid) who=$($lk.who)"

"`n-- 2) fanctl status (as admin, daemon running) --"
$out = & (Join-Path $src 'fanctl.ps1') status 2>&1 | Out-String
Check 'status renders'  ($out -match 'RPM' -and $out -notmatch 'Exception') ("lines=" + (($out -split "`n" | Where-Object { $_.Trim() }).Count))
$out -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { "    $($_.Trim())" }

"`n-- 3) panel: start + endpoints --"
Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$src\panel.ps1`"", '-NoBrowser'
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 1
  try {
    $tc = New-Object Net.Sockets.TcpClient
    $tc.Connect('127.0.0.1', 4765); $tc.Close(); $ready = $true; break
  } catch { }
}
Check 'panel port accepting' $ready "waited=${i}s"
try {
  $idx = Invoke-WebRequest -Uri 'http://127.0.0.1:4765/' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO
  Check 'GET /' ($idx.StatusCode -eq 200) "bytes=$($idx.RawContentLength)"
  Check 'html has title' ($idx.Content -match 'Y9000P')
  $lv = Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Select-Object -ExpandProperty Content
  $lvj = $lv | ConvertFrom-Json
  Check 'GET /api/live' ($lvj.daemon.running -eq $true) "age=$($lvj.age_s)s rpm=$($lvj.live.snap.rpm)"
  Check 'live carries profiles for editor' ($lvj.live.profiles.performance.cpu -match ':')
  $cf = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/config' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'GET /api/config' ($cf.config.safety.rpm_ceiling -eq 6600) "ceiling=$($cf.config.safety.rpm_ceiling) active=$($cf.active)"
  $lg = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/log' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content
  Check 'GET /api/log' ($lg.Length -gt 5) "chars=$($lg.Length)"
  $bd = '{"type":"reload","args":{}}'
  $r = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $bd -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'POST /api/cmd reload' ($r.ok -eq $true)
  Start-Sleep -Seconds 4
  $lv2 = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'daemon consumed cmd + still alive' ($lv2.daemon.running -eq $true -and $lv2.live.snap.rpm -gt 1000) "rpm=$($lv2.live.snap.rpm)"
  $bad = ''
  try { $bad = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/nope' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).StatusCode }
  catch { $bad = "$($_.Exception.Response.StatusCode.value__)" }
  Check 'unknown path -> 404' ("$bad" -eq '404') "got=$bad"
} catch {
  Bad 'panel http' $_.Exception.Message
}

"`n-- 4) curve save through the panel API --"
try {
  $spec = '64:3400,68:4000,72:4500,76:5000,80:5600,84:6100,88:6500,92:6600'
  $body = @{ type = 'curve'; args = @{ profile = 'custom'; which = 'cpu'; spec = $spec } } | ConvertTo-Json -Compress
  $r = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'POST curve save accepted' ($r.ok -eq $true)
  Start-Sleep -Seconds 3
  $cfg2 = Get-FanConfig
  Check 'curve persisted to config' ("$($cfg2.profiles.custom.cpu)" -eq $spec) "got=$($cfg2.profiles.custom.cpu)"
  # invalid curve must be rejected
  $bad2 = @{ type = 'curve'; args = @{ profile = 'custom'; which = 'cpu'; spec = '70:4000,70:4500' } } | ConvertTo-Json -Compress
  $rejected = $false
  try { $x = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $bad2 -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json; $rejected = ($r.ok -eq $false) } catch { $rejected = $true }
  Check 'duplicate-temp curve rejected' $rejected
  # every config write must leave an audit trail (a flattened curve once sat
  # unnoticed at 5800 RPM for hours; nothing in the log said who changed it)
  Start-Sleep -Seconds 2
  $al = @(Get-SharedTailLines -Path (Join-Path $root 'logs\fan.log') -Count 60) | Where-Object { $_ -match '配置变更\[panel:curve\]' }
  Check 'curve write was audited in the log' (@($al).Count -gt 0) "lines=$( @($al).Count )"
  # restore the shipped custom curve so a test run does not leave a mutated config
  $spec0 = (New-DefaultConfig).profiles.custom.cpu
  $rb = @{ type = 'curve'; args = @{ profile = 'custom'; which = 'cpu'; spec = $spec0 } } | ConvertTo-Json -Compress
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $rb -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  Start-Sleep -Seconds 3
  Check 'custom curve restored after test' ("$((Get-FanConfig).profiles.custom.cpu)" -eq $spec0)
} catch { Bad 'curve save' $_.Exception.Message }

"`n-- 5) profile switch through the command inbox --"
try {
  $body = @{ type = 'profile'; args = @{ profile = 'balanced' } } | ConvertTo-Json -Compress
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  Start-Sleep -Seconds 8
  $lv3 = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'profile switch reached daemon' ("$($lv3.live.profile)" -eq 'balanced') "profile=$($lv3.live.profile) mode=$($lv3.live.snap.mode)"
  Check 'Fn+Q mode followed profile' ($lv3.live.snap.mode -eq 2) "ecMode=$($lv3.live.snap.mode)"
  # back to performance for the final state
  $body = @{ type = 'profile'; args = @{ profile = 'performance' } } | ConvertTo-Json -Compress
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  Start-Sleep -Seconds 8
  $lv4 = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'switch back to performance' ("$($lv4.live.profile)" -eq 'performance' -and $lv4.live.snap.mode -eq 3) "mode=$($lv4.live.snap.mode)"
} catch { Bad 'profile switch' $_.Exception.Message }

"`n-- 6) rpm command with hold + auto release --"
try {
  $body = @{ type = 'rpm'; args = @{ rpm = 5400; hold_s = 12 } } | ConvertTo-Json -Compress
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  Start-Sleep -Seconds 12
  $s1 = Get-FanSnapshot
  Check 'rpm hold reached target' ([math]::Abs($s1.rpm - 5400) -le 400) "actual=$($s1.rpm)"
  Start-Sleep -Seconds 14
  $s2 = Get-FanSnapshot
  $back = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'auto release back to curve' ("$($back.live.mode)" -ne 'hold') "mode=$($back.live.mode) rpm=$($s2.rpm) target=$($back.live.last_target)"
} catch { Bad 'rpm hold' $_.Exception.Message }

"`n-- 6b) command payload integrity (regression: empty args once floored the fans) --"
try {
  $before = Get-FanSnapshot
  $body = @{ type = 'rpm'; args = @{ rpm = 4700; hold_s = 24 } } | ConvertTo-Json -Compress
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  $seen = -1
  for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Seconds 3
    $seen = (Get-FanSnapshot).rpm
    if ([math]::Abs($seen - 4700) -lt 700) { break }
  }
  Check 'rpm command delivers args intact' ([math]::Abs($seen - 4700) -lt 700) "rpm=$seen (from $($before.rpm))"

  # malformed command (no args at all) must be IGNORED, never become a minimum-speed write
  $mid = Get-FanSnapshot
  $bad = '{"type":"rpm","args":{}}'
  Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/cmd' -Method POST -Body $bad -ContentType 'application/json' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO | Out-Null
  Start-Sleep -Seconds 10
  $after = Get-FanSnapshot
  $floor = [int](Get-FanConfig).safety.rpm_floor
  Check 'malformed rpm command rejected' ($after.rpm -gt ($floor + 300)) "rpm=$($after.rpm) floor=$floor"
  $fl = @(Get-SharedTailLines -Path (Join-Path $root 'logs\fan.log') -Count 40)
  Check 'rejection was logged' (@($fl | Where-Object { $_ -match 'rpm 命令缺少' }).Count -gt 0)
  Start-Sleep -Seconds 16
  $back = (Invoke-WebRequest -Uri 'http://127.0.0.1:4765/api/live' -UseBasicParsing -DisableKeepAlive -TimeoutSec $TO).Content | ConvertFrom-Json
  Check 'hold expired, curve resumed' ("$($back.live.mode)" -eq 'auto') "mode=$($back.live.mode)"
} catch { Bad 'command integrity' $_.Exception.Message }

"`n-- 6c) idle write churn: a stable machine must not be re-written every 30s --"
try {
  # Regression: the old unconditional heartbeat re-sent the SAME rpm to the EC every
  # reassert_gap_s. Each write restarts the physical ramp (measured: fan falls to
  # ~2600 and takes 6-12s to climb back), so the laptop revved down/up forever.
  Start-Sleep -Seconds 6                      # let any pending hold expire first
  $t0 = Get-Date
  $w0 = Get-FanSnapshot
  Start-Sleep -Seconds 50
  $w1 = Get-FanSnapshot
  $lines = @(Get-SharedTailLines -Path (Join-Path $root 'logs\fan.log') -Count 150)
  $ci = [Globalization.CultureInfo]::InvariantCulture
  $writes = @($lines | Where-Object {
    $_ -match '目标转速 ->' -and $_.Length -ge 19 -and
    [datetime]::ParseExact($_.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $ci) -ge $t0.AddSeconds(-1)
  })
  $stable = [math]::Abs($w0.near_cpu - $w1.near_cpu) -le 3 -and [math]::Abs($w0.gpu_c - $w1.gpu_c) -le 3
  Check 'temps were stable during the window' $stable "nearCPU $($w0.near_cpu)->$($w1.near_cpu) gpu $($w0.gpu_c)->$($w1.gpu_c)"
  Check 'no idle EC re-write in 50s (<=2)' ($writes.Count -le 2) "writes=$($writes.Count)"
} catch { Bad 'idle churn' $_.Exception.Message }

"`n-- 7) final state + history file --"
$hist = Join-Path $root 'logs\history.csv'
Check 'history.csv written' ((Test-Path -LiteralPath $hist) -and ((Get-Content -LiteralPath $hist).Count -gt 3)) "lines=$(if (Test-Path -LiteralPath $hist) { (Get-Content -LiteralPath $hist).Count } else { 0 })"
$s = Get-FanSnapshot
"  最终: mode=$($s.mode_name) rpm=$($s.rpm) nearCPU=$($s.near_cpu)°C gpu=$($s.gpu_c)°C PL1=$($s.pl1)W PL2=$($s.pl2)W full=$($s.full)"
"SMOKE_FAILED=$fail"
if ($fail -eq 0) { 'SMOKE_RESULT ALL PASS' } else { "SMOKE_RESULT $fail FAILURES" }
