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
function Rpm([byte]$f) { Num (CallW $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f }) }
function ModeNow { Num (CallW $GZ 'GetSmartFanMode') }
function St([string]$t) { "  {0,-22} mode={1} rpm={2}/{3} nearCPU={4} gpuT={5} PL1={6} PL2={7}" -f $t, (ModeNow), (Rpm 1), (Rpm 2), (Lfc 'GetNearCPUTemperature'), (Lfc 'GetGPUTemperature'), (Lfc 'GetPowerLimit1'), (Lfc 'GetPowerLimit2') }

"########## RESTORE TO NORMAL (野兽模式 defaults: rpm 4500+, PL1=115, PL2=135) ##########"
St 'as-is'
"  1) fans -> 5000 (help clear the throttle)"
CallW $LFC 'SetFan1Speed' @{Data = [uint32]5000 } | Out-Null
CallW $LFC 'SetFan2Speed' @{Data = [uint32]5000 } | Out-Null
"  2) PL1 -> 115, PL2 -> 135"
CallW $LFC 'SetPowerLimit1' @{Data = [uint32]115 } | Out-Null
CallW $LFC 'SetPowerLimit2' @{Data = [uint32]135 } | Out-Null
"  3) fullspeed off + mode 3 asserted"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false } | Out-Null
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]3 } | Out-Null
Start-Sleep -Seconds 6
St '   +6s'
foreach ($t in 1..8) { Start-Sleep -Seconds 6; St "   +$((6 + $t * 6))s" }
"  4) settle fans to mode-3 idle value 4500"
CallW $LFC 'SetFan1Speed' @{Data = [uint32]4500 } | Out-Null
CallW $LFC 'SetFan2Speed' @{Data = [uint32]4500 } | Out-Null
foreach ($t in 1..4) { Start-Sleep -Seconds 6; St "   settled +$($t*6)s" }
"  reference healthy state: mode=3 rpm=4500/4500 nearCPU~78 PL1=115 PL2=135"
'RESTORE_DONE'
