$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()
function Get-Obj([string]$cn) {
  $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn"))
  foreach ($o in $sr.Get()) { return $o }
  return $null
}
$GZ = Get-Obj 'LENOVO_GAMEZONE_DATA'
$FM = Get-Obj 'LENOVO_FAN_METHOD'
function Call0($o, $m) { $r = $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null); [int]$r['Data'] }
function Rpm([byte]$f) { $ip = $FM.GetMethodParameters('Fan_GetCurrentFanSpeed'); $ip['FanID'] = $f; [int]$FM.InvokeMethod('Fan_GetCurrentFanSpeed', $ip, $null)['CurrentFanSpeed'] }
function Sen([byte]$s) { $ip = $FM.GetMethodParameters('Fan_GetCurrentSensorTemperature'); $ip['SensorID'] = $s; [int]$FM.InvokeMethod('Fan_GetCurrentSensorTemperature', $ip, $null)['CurrentSensorTemperature'] }
function HexOf($o) { $b = $o['FanTable']; if (-not $b) { return 'EMPTY' }; 'hex[' + (($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + '] len=' + $b.Length + ' size=' + $o['FanTableSize'] }
function Snap([string]$tag) {
  $sens = @(foreach ($s in 0..6) { "s$s=$(Sen $s)" }) -join ' '
  "  {0,-22} mode={1} cpu={2} gpu={3} | fan1={4} fan2={5} | {6}" -f $tag, (Call0 $GZ 'GetSmartFanMode'), (Call0 $GZ 'GetCPUTemp'), (Call0 $GZ 'GetGPUTemp'), (Rpm 1), (Rpm 2), $sens
}

"########## 0) independent references ##########"
try { "   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader) -join ' | ')" } catch { "   nvidia-smi ERR $_" }
try { (Get-Counter -ListSet 'Thermal Zone Information' -ErrorAction Stop) | ForEach-Object { "   thermalzone countersets: $($_.PathsToDevice | Out-String)".Trim(); "   counter names: " + (($_.CounterNames | Where-Object { $_ -match 'Temperature' }) -join ', ') } } catch { "   no Thermal Zone counter set: $($_.Exception.Message)" }
try { $tz = Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop; $tz.CounterSamples | ForEach-Object { "   $($_.InstanceName) = $([math]::Round($_.CookedValue,1))" } } catch { "   (english path failed) $($_.Exception.Message)" }
try { $b = Get-CimInstance Win32_Battery | Select-Object -First 1; "   battery: $($b.EstimatedChargeRemaining)% status=$($b.BatteryStatus)" } catch { "   battery n/a" }

"`n########## 1) baseline ##########"
Snap 'idle'

"`n########## 2) CPU load ramp -> which EC sensor is CPU ##########"
$jobs = 1..10 | ForEach-Object { Start-Job -ScriptBlock { $z = 0; for ($i = 0; $i -lt 8000000; $i++) { $z += [math]::Sqrt($i) } } }
foreach ($t in 1..6) { Start-Sleep -Seconds 5; Snap "load+t$($t*5)s" }
$jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
foreach ($t in 1..3) { Start-Sleep -Seconds 5; Snap "cool+t$($t*5)s" }

"`n########## 3) custom mode: are fan tables readable then? ##########"
$prev = Call0 $GZ 'GetSmartFanMode'
"   current mode = $prev   (will restore at the end)"
$ip = $GZ.GetMethodParameters('SetSmartFanMode'); $ip['Data'] = [uint32]4
$null = $GZ.InvokeMethod('SetSmartFanMode', $ip, $null)
Start-Sleep -Seconds 2
Snap 'mode=4(custom)'
foreach ($pair in @(@(1, 0), @(1, 1), @(1, 2), @(1, 3), @(1, 4), @(2, 0), @(2, 1), @(2, 2), @(2, 3), @(2, 4))) {
  $t = $FM.GetMethodParameters('Fan_Get_Table'); $t['FanID'] = [byte]$pair[0]; $t['SensorID'] = [byte]$pair[1]
  $o = $FM.InvokeMethod('Fan_Get_Table', $t, $null)
  "   table fan=$($pair[0]) sensor=$($pair[1]) -> $(HexOf $o)"
}
$m = $FM.GetMethodParameters('Fan_Get_MaxSpeed'); $m['Fan_ID'] = [byte]1
"   maxspeed fan1 -> $(HexOf ($FM.InvokeMethod('Fan_Get_MaxSpeed', $m, $null)))"

"`n########## 4) per-fan direct RPM control (in custom mode) ##########"
function SetRpm([byte]$f, [uint16]$v) { $p = $FM.GetMethodParameters('Fan_SetCurrentFanSpeed'); $p['CurrentFanSpeed'] = $v; $p['FanID'] = $f; $r = $FM.InvokeMethod('Fan_SetCurrentFanSpeed', $p, $null); "ret=$($r['CurrentFanSpeed'])" }
try {
  "   set fan1=5200 -> $(SetRpm 1 5200)"
  foreach ($t in 1..4) { Start-Sleep -Seconds 3; Snap "f1-5200+t$($t*3)s" }
  "   set fan2=3000 -> $(SetRpm 2 3000)"
  foreach ($t in 1..4) { Start-Sleep -Seconds 3; Snap "f2-3000+t$($t*3)s" }
  "   set fan1=6500 -> $(SetRpm 1 6500)"
  foreach ($t in 1..3) { Start-Sleep -Seconds 3; Snap "f1-6500+t$($t*3)s" }
} catch { "   manual ERR $($_.Exception.Message)" }
finally {
  $ip = $GZ.GetMethodParameters('SetSmartFanMode'); $ip['Data'] = [uint32]$prev
  $null = $GZ.InvokeMethod('SetSmartFanMode', $ip, $null)
  Start-Sleep -Seconds 4
  Snap "restored mode=$prev"
}
'PROBE11_DONE'
