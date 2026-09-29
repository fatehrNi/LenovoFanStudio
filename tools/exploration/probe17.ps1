$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()
function Get-Obj([string]$cn) { try { $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn")); foreach ($o in $sr.Get()) { return $o } } catch { } return $null }
$LFC = Get-Obj 'Lfc_thermal_interface'; $GZ = Get-Obj 'LENOVO_GAMEZONE_DATA'; $FM = Get-Obj 'LENOVO_FAN_METHOD'
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
function Both([int]$v) { LfcSet 'SetFan1Speed' $v | Out-Null; LfcSet 'SetFan2Speed' $v | Out-Null }
function St([string]$tag) { "  {0,-26} mode={1} rpm={2}/{3} cpuT={4} nearCPU={5} gpuT={6} PL1={7} PL2={8}" -f $tag, (ModeNow), (Rpm 1), (Rpm 2), (Lfc 'GetCPUTemperature'), (Lfc 'GetNearCPUTemperature'), (Lfc 'GetGPUTemperature'), (Lfc 'GetPowerLimit1'), (Lfc 'GetPowerLimit2') }

"########## A) trustworthy CPU temp source hunt ##########"
try { $all = (typeperf -qx) 2>$null; "   temp-ish counters:`n     " + (($all | Where-Object { $_ -match '(?i)temp|温度' } | Select-Object -First 15) -join "`n     ") } catch { "   typeperf ERR" }
try { "   root\wmi thermal-ish: " + ((Get-CimClass -Namespace 'root\wmi' -ClassName '*hermal*','*emp*' | ForEach-Object CimClassName | Sort-Object -Unique) -join ', ') } catch { }
foreach ($c in 'IntelThermal', 'ISCT_Dynamic_Fan_Speed_Algo', 'MSAcpi_ThermalZoneTemperature') { try { $x = Get-CimInstance -Namespace 'root\wmi' -ClassName $c -ErrorAction Stop; "   ${c}: $($x | ConvertTo-Json -Compress -Depth 1)" } catch { "   ${c}: $($_.Exception.Message)" } }
"   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader) -join ' | ')"
St 'reference (idle)'
$j = Start-Job { $z = 0.0; for ($i = 0; $i -lt 90000000; $i++) { $z += [math]::Sqrt($i) } }
foreach ($t in 1..4) { Start-Sleep -Seconds 6; St "1-thread load +$($t*6)s" }
$j | Stop-Job -ErrorAction SilentlyContinue; $j | Remove-Job -Force -ErrorAction SilentlyContinue
foreach ($t in 1..3) { Start-Sleep -Seconds 6; St "recovery +$($t*6)s" }

"`n########## B) does EC fight a manual RPM that differs from auto? ##########"
St 'before'
Both 3300
foreach ($t in 1..10) { Start-Sleep -Seconds 4; St "manual 3300 +$($t*4)s" }
"   -> re-apply Fn+Q mode (release attempt #1)"
CallW $GZ 'SetSmartFanMode' @{Data = [uint32](ModeNow) } | Out-Null
foreach ($t in 1..6) { Start-Sleep -Seconds 4; St "after mode reapply +$($t*4)s" }

"`n########## C) power limits round-trip ##########"
$p1 = Lfc 'GetPowerLimit1'; $p2 = Lfc 'GetPowerLimit2'
"   current PL1=$p1 PL2=$p2"
"   PL1 -> $([math]::Max(35, $p1 - 30)): $(LfcSet 'SetPowerLimit1' ([math]::Max(35, $p1 - 30)))"; Start-Sleep -Seconds 3; St '   lowered'
"   PL1 -> $p1 (restore): $(LfcSet 'SetPowerLimit1' $p1)"; Start-Sleep -Seconds 3
"   PL2 -> $p2 (reassert): $(LfcSet 'SetPowerLimit2' $p2)"; Start-Sleep -Seconds 3; St '   restored'

"`n########## D) leave the machine in a good state ##########"
Both 4500
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false } | Out-Null
Start-Sleep -Seconds 5
St 'final'
'PROBE17_DONE'
