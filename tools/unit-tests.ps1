# Offline unit checks for the pure logic in LenovoFan.psm1 (no admin / no EC writes)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'LenovoFan.psm1') -Force -DisableNameChecking

$fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name  $detail" }
}
function Expect($name, $actual, $want) {
  if ("$actual" -eq "$want") { "  PASS  $name = $actual" } else { $script:fail++; "  FAIL  $name got=$actual want=$want" }
}

"### Parse-FanCurve"
$p = Parse-FanCurve -Spec '66:3600,70:4200,74:4800,78:5400,82:6000,86:6400,90:6600,94:6600'
Expect 'points parsed' $p.Count 8
Expect 'first temp' $p[0].Temp 66
Expect 'last rpm' $p[7].Rpm 6600
$p2 = Parse-FanCurve -Spec '70:4000，66:3600'   # full-width comma + unordered
Expect 'reorders' ($p2[0].Temp) 66
try { Parse-FanCurve -Spec '70:4000,70:4500' | Out-Null; Check 'duplicate temp rejected' $false } catch { Check 'duplicate temp rejected' $true }
try { Parse-FanCurve -Spec '70:4000' | Out-Null; Check 'single point rejected' $false } catch { Check 'single point rejected' $true }
try { Parse-FanCurve -Spec '70-4000' | Out-Null; Check 'bad token rejected' $false } catch { Check 'bad token rejected' $true }

"### Resolve-FanCurve (interpolation + clamping)"
$cur = '66:3600,70:4200,74:4800,78:5400,82:6000,86:6400,90:6600,94:6600'
Expect 'below range -> first'  (Resolve-FanCurve -Steps $cur -Temp 50)  3600
Expect 'above range -> last'   (Resolve-FanCurve -Steps $cur -Temp 99)  6600
Expect 'exact point'           (Resolve-FanCurve -Steps $cur -Temp 70)  4200
Expect 'midpoint interpolate'  (Resolve-FanCurve -Steps $cur -Temp 68)  3900
Expect 'floor clamp'           (Resolve-FanCurve -Steps '20:100,30:200' -Temp 25 -Floor 2400) 2400
Expect 'ceiling clamp'         (Resolve-FanCurve -Steps '80:9000,90:9900' -Temp 85 -Ceiling 6600) 6600

"### Limit-FanRpm"
Expect 'clamps low'    (Limit-FanRpm -Rpm 100)  2400
Expect 'clamps high'   (Limit-FanRpm -Rpm 99999) 6600
Expect 'zero -> floor' (Limit-FanRpm -Rpm 0)  2400
Expect 'keeps valid'   (Limit-FanRpm -Rpm 4500) 4500

"### Get-FanControlTemp (load feed-forward)"
$cfg = Get-FanConfig
$def = New-DefaultConfig
Expect 'idle basis = nearcpu+offset' (Get-FanControlTemp -NearCpu 78 -CpuUtil 5 -Config $cfg) (78 + [double]$cfg.telemetry.cpu_offset + [math]::Min([double]$cfg.load_boost.max_add_c, (5 / 10) * [double]$cfg.load_boost.per_10pct_util))
$hot = Get-FanControlTemp -NearCpu 78 -CpuUtil 100 -Config $cfg
Expect 'full load boost capped' $hot (78 + [double]$cfg.load_boost.max_add_c)

"### shipped defaults are self-consistent (catches a bad curve shipped in code)"
Check 'default curves have no issue' (@(Get-FanCurveIssue -Config $def).Count -eq 0) "got=$( @(Get-FanCurveIssue -Config $def) -join ' | ')"
foreach ($pn in @($def.profiles.Keys)) {
  foreach ($side in 'cpu', 'gpu') {
    $ok = $true
    try { Parse-FanCurve -Spec $def.profiles[$pn][$side] | Out-Null } catch { $ok = $false }
    Check "default $pn.$side parses" $ok
  }
}
Check 'flat non-ceiling curve is flagged' (@(Get-FanCurveIssue -Config (@{ profiles = @{ t = @{ ceiling = 6600; cpu = '66:5800,70:5800,74:5800,78:5800,82:5800,86:5800,90:5800,94:5800'; gpu = '56:3600,62:4200,68:4800,74:5400,80:6000,85:6400,90:6600,95:6600' } } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)).Count -ge 1)
$flatCeil = @{ profiles = @{ t = @{ ceiling = 6600; cpu = '0:6600,20:6600,40:6600,60:6600,80:6600,100:6600,120:6600,130:6600'; gpu = '0:6600,20:6600,40:6600,60:6600,80:6600,100:6600,120:6600,130:6600' } } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Check 'ceiling-flat curve is not flagged' (@(Get-FanCurveIssue -Config $flatCeil).Count -eq 0) "got=$( @(Get-FanCurveIssue -Config $flatCeil) -join ' | ')"

"### config upgrade + self-heal (old files must keep working)"
$oldish = @{ version = 1; active_profile = 'quiet'; safety = @{ rpm_floor = 2400; rpm_ceiling = 6600 } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Merge-FanDefaults -Cfg $oldish -Def $def | Out-Null
Check 'missing safety key filled (max_hold_s)' ($null -ne $oldish.safety.max_hold_s)
Check 'missing profile filled (performance)' ($null -ne $oldish.profiles.performance.cpu)
Check 'user value not overwritten' $oldish.active_profile 'quiet'
$broken = (@{ profiles = @{ max = @{ ceiling = 6600; cpu = '0:6600,0:6600,0:6600'; gpu = '0:6600,0:6600,0:6600' } } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
Repair-FanConfigCurves -Cfg $broken -Def $def | Out-Null
$healed = $true
try { Parse-FanCurve -Spec $broken.profiles.max.cpu | Out-Null } catch { $healed = $false }
Check 'unparsable curve self-healed' $healed "still=$($broken.profiles.max.cpu)"

"### config round-trip"
$back = Get-FanConfig
Expect 'active profile' $back.active_profile 'performance'
Check 'profiles present' (@('quiet', 'balanced', 'performance', 'max', 'custom') | ForEach-Object { $back.profiles.PSObject.Properties[$_] } ).Count -eq 5
Expect 'rpm ceiling sane' $back.safety.rpm_ceiling 6600
Expect 'curve string readable' ((Parse-FanCurve -Spec $back.profiles.performance.cpu).Count) 8

"### Get-FanDesiredRpm maths (offline, against the shipped defaults)"
$fake = [pscustomobject]@{ near_cpu = 60; gpu_c = 55; cpu_util = 10; mode = 3 }
$d = Get-FanDesiredRpm -Profile 'performance' -Snap $fake -Config $def
Expect 'quiet-temps -> curve start' $d.rpm 3600
$fake2 = [pscustomobject]@{ near_cpu = 84; gpu_c = 60; cpu_util = 10; mode = 3 }
$d2 = Get-FanDesiredRpm -Profile 'performance' -Snap $fake2 -Config $def
Check 'hot cpu raises target' ($d2.rpm -gt $d.rpm) "got $($d2.rpm)"
$fake3 = [pscustomobject]@{ near_cpu = 95; gpu_c = 60; cpu_util = 10; mode = 3 }
$d3 = Get-FanDesiredRpm -Profile 'performance' -Snap $fake3 -Config $def
Expect 'crit temp -> ceiling' $d3.rpm $def.safety.rpm_ceiling
Expect 'crit reason' $d3.why '过温强制'
$fake4 = [pscustomobject]@{ near_cpu = 60; gpu_c = 90; cpu_util = 10; mode = 3 }
$d4 = Get-FanDesiredRpm -Profile 'performance' -Snap $fake4 -Config $def
Expect 'gpu crit -> ceiling' $d4.rpm $def.safety.rpm_ceiling
# the "满速" profile used to ship an unparsable curve; the engine must now reach the ceiling
$d5 = Get-FanDesiredRpm -Profile 'max' -Snap ([pscustomobject]@{ near_cpu = 40; gpu_c = 35; cpu_util = 5; mode = 3 }) -Config $def
Expect 'max profile -> ceiling even when cold' $d5.rpm 6600
$d6 = Get-FanDesiredRpm -Profile 'quiet' -Snap ([pscustomobject]@{ near_cpu = 45; gpu_c = 40; cpu_util = 5; mode = 1 }) -Config $def
Expect 'quiet profile cold -> curve start (2600)' $d6.rpm 2600

"### lock helpers (read-only; never call Enter-FanLock from an offline test)"
$tmpLock = Join-Path ([IO.Path]::GetTempPath()) ("fanlock-test-{0}.json" -f $PID)
Check 'missing lock -> null' ($null -eq (Read-FanLockFile -Path $tmpLock))
$me = Get-Process -Id $PID
Set-Content -LiteralPath $tmpLock -Value (@{ who = 'daemon:test'; pid = $me.Id; since = (Get-Date -Format 'o'); root = 'X:\somewhere' } | ConvertTo-Json -Compress) -Encoding ASCII
$rl = Read-FanLockFile -Path $tmpLock
Check 'live lock parsed' ($rl -and $rl.alive -and $rl.who -eq 'daemon:test') "who=$($rl.who) pid=$($rl.pid)"
Check 'lock carries its data root' ("$($rl.root)" -eq 'X:\somewhere') "root=$($rl.root)"
Set-Content -LiteralPath $tmpLock -Value (@{ who = 'daemon:dead'; pid = 999999; since = 'x'; root = '' } | ConvertTo-Json -Compress) -Encoding ASCII
$rd = Read-FanLockFile -Path $tmpLock
Check 'dead pid -> alive false' ($rd -and -not $rd.alive) "pid=$($rd.pid) alive=$($rd.alive)"
Set-Content -LiteralPath $tmpLock -Value 'not json at all {{{' -Encoding ASCII
Check 'garbage lock -> null' ($null -eq (Read-FanLockFile -Path $tmpLock))
Remove-Item -LiteralPath $tmpLock -Force -ErrorAction SilentlyContinue

"`nUNIT_RESULT failures=$fail"
if ($fail) { exit 1 } else { exit 0 }
