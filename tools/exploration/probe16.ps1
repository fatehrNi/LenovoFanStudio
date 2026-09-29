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
function St([string]$tag) { "  {0,-28} mode={1} rpm={2}/{3} cpuT={4} nearCPU={5} gpuT={6} nearGPU={7} env={8} ram={9} PL1={10} PL2={11}" -f $tag, (ModeNow), (Rpm 1), (Rpm 2), (Lfc 'GetCPUTemperature'), (Lfc 'GetNearCPUTemperature'), (Lfc 'GetGPUTemperature'), (Lfc 'GetNearGPUTemperature'), (Lfc 'GetEnvironmentTemperature'), (Lfc 'GetRAMTemperature'), (Lfc 'GetPowerLimit1'), (Lfc 'GetPowerLimit2') }

"########## A) look for a trustworthy CPU temperature source ##########"
try {
  $all = (typeperf -qx) 2>$null
  "   counters containing temp/温度: " + (($all | Where-Object { $_ -match '(?i)temp|温度' } | Select-Object -First 12) -join ' ;; ')
} catch { "   typeperf ERR" }
try { "   root\wmi classes w/ thermal|temp: " + ((Get-CimClass -Namespace 'root\wmi' -ClassName '*Thermal*','*Temp*' | ForEach-Object CimClassName | Sort-Object -Unique) -join ', ') } catch { }
try { "   perf classes w/ Temp: " + ((Get-CimClass -Namespace root\cimv2 -ClassName 'Win32_Perf*Temp*' | ForEach-Object CimClassName | Sort-Object) -join ', ') } catch { }
try { $d = Get-CimInstance -Namespace 'root\wmi' -ClassName 'IntelThermal' -ErrorAction Stop; "   IntelThermal: " + ($d | ConvertTo-Json -Compress -Depth 2) } catch { "   IntelThermal: $($_.Exception.Message)" }
"   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.sm --format=csv,noheader) -join ' | ')"
St 'idle reference'
"   cpu util: $([int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter 'Name="_Total"').PercentProcessorTime)%  freq: $([int](Get-CimInstance Win32_PerfFormattedData_PerfOs_Processor -Filter 'Name="_Total"').PercentFrequency)%"

"`n########## B) does the EC fight our manual RPM, and how do we release it? ##########"
"   B0 baseline"; St '   baseline'
Both 3600
foreach ($t in 1..6) { Start-Sleep -Seconds 3; St "   manual 3600 +$($t*3)s" }
"   -> re-apply Fn+Q mode 3 (this is our planned 'release to BIOS')"
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null
foreach ($t in 1..6) { Start-Sleep -Seconds 3; St "   after mode3 +$($t*3)s" }
Both 5800
foreach ($t in 1..4) { Start-Sleep -Seconds 3; St "   manual 5800 +$($t*3)s" }
"   -> fullspeed true then false (alternate release path)"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $true } | Out-Null; Start-Sleep -Seconds 6; St '   fullspeed ON'
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false } | Out-Null
foreach ($t in 1..5) { Start-Sleep -Seconds 3; St "   after OFF +$($t*3)s" }
"   -> toggle mode 2 -> 3"
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]2 } | Out-Null; Start-Sleep -Seconds 5; St '   mode2'
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null; Start-Sleep -Seconds 5; St '   mode3'
Both 4500
Start-Sleep -Seconds 4; St '   manual 4500 (safe default)'

"`n########## C) power-limit control (the real 'bypass power plan' lever) ##########"
"   C0 $(St 'reference')"
"   set PL1=90 -> $(LfcSet 'SetPowerLimit1' 90)"; Start-Sleep -Seconds 3; St '   PL1=90'
"   set PL1=115 -> $(LfcSet 'SetPowerLimit1' 115)"; Start-Sleep -Seconds 3; St '   PL1=115'
"   set PL2=135 -> $(LfcSet 'SetPowerLimit2' 135)"; Start-Sleep -Seconds 3; St '   PL2=135'

"`n########## D) verify healthy end state ##########"
St 'final'
"   expected: mode=3 rpm~4500 PL1=115 PL2=135"
'PROBE16_DONE'
