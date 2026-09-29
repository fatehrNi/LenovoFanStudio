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
function Lfc($m) { CallW $LFC $m @{Data = [uint32]0} }
function Rpm([byte]$f) { Num (CallW $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f}) }
function ModeNow { Num (CallW $GZ 'GetSmartFanMode') }
function St([string]$tag) {
  "  {0,-26} mode={1} gzoneRpm={2}/{3} lfcRpm={4}/{5} cpuT={6} nearCPU={7} gpuT={8} PL1={9} PL2={10}" -f $tag, (ModeNow), (Rpm 1), (Rpm 2), (Num (Lfc 'GetFan1Speed')), (Num (Lfc 'GetFan2Speed')), (Num (Lfc 'GetCPUTemperature')), (Num (Lfc 'GetNearCPUTemperature')), (Num (Lfc 'GetGPUTemperature')), (Num (Lfc 'GetPowerLimit1')), (Num (Lfc 'GetPowerLimit2'))
}

"########## RECOVERY: hand fan control back to the EC ##########"
St 'as-is'
"  1) fullspeed true"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $true } | Out-Null; Start-Sleep -Seconds 6; St '   +'
"  2) fullspeed false"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false} | Out-Null; Start-Sleep -Seconds 6; St '   +'
"  3) LFC fans -> 255 (max duty)"
CallW $LFC 'SetFan1Speed' @{Data = [uint32]255 } | Out-Null
CallW $LFC 'SetFan2Speed' @{Data = [uint32]255 } | Out-Null
Start-Sleep -Seconds 6; St '   +'
"  4) re-apply Fn+Q mode 3 (野兽)"
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null
Start-Sleep -Seconds 8; St '   +'
"  5) cycle 1 -> 3"
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]1 } | Out-Null; Start-Sleep -Seconds 5; St '   mode1'
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null; Start-Sleep -Seconds 8; St '   mode3'
"  6) LFC fans -> 255 (keep cool) then mode 3 again"
CallW $LFC 'SetFan1Speed' @{Data = [uint32]255 } | Out-Null
CallW $LFC 'SetFan2Speed' @{Data = [uint32]255 } | Out-Null
Start-Sleep -Seconds 5; St '   +'
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null; Start-Sleep -Seconds 10; St '   final'
"  7) observe for 30 s without touching anything"
foreach ($t in 1..6) { Start-Sleep -Seconds 5; St "   t+$($t*5)s" }
"  expected healthy baseline (from earlier probes): gzoneRpm ~4400-4500, mode=3, PL1/PL2 = 115/135"
"  cpu load now: $((Get-CimInstance Win32_Processor).CurrentLoad)%  battery: $((Get-CimInstance Win32_Battery | Select-Object -First 1).BatteryStatus)"
'RECOVERY_DONE'
