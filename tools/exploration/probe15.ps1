$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()
function Get-Obj([string]$cn) {
  try { $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn")); foreach ($o in $sr.Get()) { return $o } } catch { }
  return $null
}
$LFC = Get-Obj 'Lfc_thermal_interface'
$GZ = Get-Obj 'LENOVO_GAMEZONE_DATA'
$FM = Get-Obj 'LENOVO_FAN_METHOD'

function CallW($o, $m, [hashtable]$a = @{}) {
  if (-not $o) { return 'NO-OBJ' }
  try {
    $ip = $null; try { $ip = $o.GetMethodParameters($m) } catch { }
    if ($null -ne $ip) { foreach ($k in $a.Keys) { try { $ip[$k] = $a[$k] } catch { } } }
    $r = if ($null -eq $ip) { $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null) } else { $o.InvokeMethod($m, $ip, [System.Management.InvokeMethodOptions]$null) }
    if ($null -eq $r) { return 'NULL' }
    $p = @(); foreach ($x in $r.Properties) { $p += "$($x.Name)=$($x.Value)" }
    return ($p -join '  ')
  } catch { return "ERR $($_.Exception.Message)" }
}
function Num($s) { if ($s -match '(\-?\d+)') { return [int]$matches[1] } return -999 }
function Lfc($m) { Num (CallW $LFC $m @{Data = [uint32]0 }) }
function LfcSet($m, [int]$v) { CallW $LFC $m @{Data = [uint32]$v } }
function Rpm([byte]$f) { Num (CallW $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f }) }
function ModeNow { Num (CallW $GZ 'GetSmartFanMode') }
$FLOOR = 3000   # never command anything slower than this
$CEIL = 6800

function St([string]$tag) {
  "  {0,-24} mode={1} gRpm={2}/{3} lfcRpm={4}/{5} cpuT={6} nearCPU={7} gpuT={8} PL1={9} PL2={10}" -f $tag, (ModeNow), (Rpm 1), (Rpm 2), (Lfc 'GetFan1Speed'), (Lfc 'GetFan2Speed'), (Lfc 'GetCPUTemperature'), (Lfc 'GetNearCPUTemperature'), (Lfc 'GetGPUTemperature'), (Lfc 'GetPowerLimit1'), (Lfc 'GetPowerLimit2')
}
function Clamp([int]$v) { [math]::Max($FLOOR, [math]::Min($CEIL, $v)) }

"########## 1) POST-REBOOT HEALTH (read only) ##########"
St 'after reboot'
"   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader) -join ' | ')"
"   power plan: $((powercfg /getactivescheme) -join ' ')"
"   cpu load: $([int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter 'Name=""_Total""').PercentProcessorTime)%"
$b1 = Rpm 1; $b2 = Rpm 2
if ($b1 -lt 3500 -or $b2 -lt 3500) {
  "   !! 读数仍偏低 -> 立即拉高到 5000 并交还 BIOS"
  LfcSet 'SetFan1Speed' (Clamp 5000) | Out-Null; LfcSet 'SetFan2Speed' (Clamp 5000) | Out-Null
  Start-Sleep -Seconds 4
  CallW $GZ 'SetSmartFanMode' @{Data = [uint32](ModeNow) } | Out-Null
  Start-Sleep -Seconds 4; St '   nudged'
}

"`n########## 2) SAFE RPM WRITE TEST (raise only, always restored) ##########"
$origMode = ModeNow
if ($origMode -lt 1) { $origMode = 3 }
try {
  "   baseline fan1=$b1 fan2=$b2  (mode $origMode)"
  $t1 = Clamp ([math]::Max(5200, $b1 + 700))
  "   set fan1 = $t1 RPM  (>= baseline, safe direction) -> $(LfcSet 'SetFan1Speed' $t1)"
  foreach ($t in 1..3) { Start-Sleep -Seconds 3; St "   fan1=$t1 +$($t*3)s" }
  $t2 = Clamp ([math]::Max(6000, $b2 + 1200))
  "   set fan2 = $t2 RPM -> $(LfcSet 'SetFan2Speed' $t2)"
  foreach ($t in 1..3) { Start-Sleep -Seconds 3; St "   fan2=$t2 +$($t*3)s" }
  "   --- asymmetric hold: fan1=$t1 fan2=$t2 (independent?) ---"
  foreach ($t in 1..2) { Start-Sleep -Seconds 4; St "   asym +$($t*4)s" }
  "   --- small step test: fan1 -> $([int]($t1*0.85)) (still above floor) ---"
  $t3 = Clamp ([int]($t1 * 0.85))
  LfcSet 'SetFan1Speed' $t3 | Out-Null
  foreach ($t in 1..3) { Start-Sleep -Seconds 3; St "   fan1=$t3 +$($t*3)s" }
} catch {
  "   TEST ERROR: $($_.Exception.Message)"
} finally {
  "   --- restore: write baseline-ish RPM, then re-apply Fn+Q mode ---"
  LfcSet 'SetFan1Speed' (Clamp $b1) | Out-Null
  LfcSet 'SetFan2Speed' (Clamp $b2) | Out-Null
  Start-Sleep -Seconds 3
  CallW $GZ 'SetSmartFanMode' @{Data = [uint32]$origMode } | Out-Null
  Start-Sleep -Seconds 6
  St 'restored'
  foreach ($t in 1..4) { Start-Sleep -Seconds 5; St "   settle +$($t*5)s" }
  "   PL1 back to 115? gRpm back to ~4500?  (see above)"
}
"`n########## 3) final snapshot ##########"
St 'final'
$pl1 = Lfc 'GetPowerLimit1'
if ($pl1 -lt 100) {
  "   PL1=$pl1 仍被限制 -> 尝试恢复 115/135 (野兽模式默认)"
  LfcSet 'SetPowerLimit1' 115 | Out-Null
  LfcSet 'SetPowerLimit2' 135 | Out-Null
  Start-Sleep -Seconds 4
  St '   after PL restore'
}
'PROBE15_DONE'
