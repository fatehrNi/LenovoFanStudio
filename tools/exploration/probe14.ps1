$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()
function Get-Obj([string]$cn) {
  try {
    $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn"))
    foreach ($o in $sr.Get()) { return $o }
  } catch { }
  return $null
}
$LFC = Get-Obj 'Lfc_thermal_interface'
$GZ = Get-Obj 'LENOVO_GAMEZONE_DATA'
$FM = Get-Obj 'LENOVO_FAN_METHOD'
if (-not $LFC) { 'NO Lfc_thermal_interface INSTANCE'; exit 1 }

function CallW($o, $m, [hashtable]$a = @{}) {
  if (-not $o) { return 'NO-OBJ' }
  try {
    $ip = $null
    try { $ip = $o.GetMethodParameters($m) } catch { }
    if ($null -ne $ip) { foreach ($k in $a.Keys) { try { $ip[$k] = $a[$k] } catch { } } }
    $r = if ($null -eq $ip) { $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null) } else { $o.InvokeMethod($m, $ip, [System.Management.InvokeMethodOptions]$null) }
    if ($null -eq $r) { return 'NULL' }
    $p = @(); foreach ($x in $r.Properties) { $v = $x.Value; if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ']' }; $p += "$($x.Name)=$v" }
    if ($p.Count -eq 0) { return '(empty)' }
    return ($p -join '  ')
  } catch { return "ERR $($_.Exception.Message)" }
}
function Num($s) { if ($s -match '(\-?\d+)') { return [int]$matches[1] } return -999 }
function Lfc($m, [hashtable]$a = @{Data = [uint32]0 }) { CallW $LFC $m $a }
function Rpm([byte]$f) { Num (CallW $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f}) }
function ModeNow { Num (CallW $GZ 'GetSmartFanMode') }
$ORIG = ModeNow

"########## 1) LFC reads ##########"
"   GetVersion                  -> $(Lfc 'GetVersion')"
"   GetPlatformVersion          -> $(Lfc 'GetPlatformVersion')"
foreach ($m in 'GetFan1Speed', 'GetFan2Speed', 'GetPowerLimit1', 'GetPowerLimit2', 'GetCPUTemperature', 'GetGPUTemperature', 'GetNearCPUTemperature', 'GetNearGPUTemperature', 'GetChargerTemperature', 'GetEnvironmentTemperature', 'GetSSDTemperature', 'GetRAMTemperature') {
  "   {0,-24} -> $(Lfc $m)"
}
"   GameZone rpm: fan1=$(Rpm 1) fan2=$(Rpm 2)  mode=$ORIG  s3=$(Num (CallW $FM 'Fan_GetCurrentSensorTemperature' @{SensorID=3})) s4=$(Num (CallW $FM 'Fan_GetCurrentSensorTemperature' @{SensorID=4}))"
"   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader) -join ' | ')"

"`n########## 2) SetFan1Speed / SetFan2Speed — units and independence ##########"
$b1 = Num (Lfc 'GetFan1Speed'); $b2 = Num (Lfc 'GetFan2Speed')
"   baseline GetFan1Speed=$b1 GetFan2Speed=$b2"
foreach ($v in 255, 200, 150, 100, 60) {
  "   SetFan1Speed($v) -> $(Lfc 'SetFan1Speed' @{Data = [uint32]$v}) ; SetFan2Speed($v) -> $(Lfc 'SetFan2Speed' @{Data = [uint32]$v})"
  Start-Sleep -Seconds 4
  "       get: fan1=$(Num (Lfc 'GetFan1Speed')) fan2=$(Num (Lfc 'GetFan2Speed'))   gamezone-rpm: $(Rpm 1)/$(Rpm 2)   cpu=$(Num (Lfc 'GetCPUTemperature'))"
}
"   --- asymmetric test: fan1=255 fan2=60 ---"
Lfc 'SetFan1Speed' @{Data = [uint32]255} | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]60 } | Out-Null
Start-Sleep -Seconds 5
"       get: fan1=$(Num (Lfc 'GetFan1Speed')) fan2=$(Num (Lfc 'GetFan2Speed'))  gamezone: $(Rpm 1)/$(Rpm 2)"
"   --- asymmetric test: fan1=60 fan2=255 ---"
Lfc 'SetFan1Speed' @{Data = [uint32]60 } | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]255} | Out-Null
Start-Sleep -Seconds 5
"       get: fan1=$(Num (Lfc 'GetFan1Speed')) fan2=$(Num (Lfc 'GetFan2Speed'))  gamezone: $(Rpm 1)/$(Rpm 2)"

"`n########## 3) does the EC fight back? (persist check, mode still writable?) ##########"
Lfc 'SetFan1Speed' @{Data = [uint32]180} | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]180} | Out-Null
foreach ($t in 1..5) { Start-Sleep -Seconds 3; "   t+$($t*3)s fan=$(Num (Lfc 'GetFan1Speed'))/$(Num (Lfc 'GetFan2Speed')) gamezone=$(Rpm 1)/$(Rpm 2) mode=$(ModeNow)" }

"`n########## 4) load response while we hold the fans (proves control) ##########"
Lfc 'SetFan1Speed' @{Data = [uint32]80} | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]80} | Out-Null
$jobs = 1..12 | ForEach-Object { Start-Job -ScriptBlock { $z = 0.0; for ($i = 0; $i -lt 40000000; $i++) { $z += [math]::Sqrt($i) } } }
foreach ($t in 1..4) { Start-Sleep -Seconds 6; "   load+$($t*6)s cpu=$(Num (Lfc 'GetCPUTemperature')) nearcpu=$(Num (Lfc 'GetNearCPUTemperature')) fan=$(Rpm 1)/$(Rpm 2)" }
"   -> now raise fans to 255 while still loaded"
Lfc 'SetFan1Speed' @{Data = [uint32]255} | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]255} | Out-Null
foreach ($t in 1..3) { Start-Sleep -Seconds 5; "   +$($t*5)s cpu=$(Num (Lfc 'GetCPUTemperature')) fan=$(Rpm 1)/$(Rpm 2)" }
$jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

"`n########## 5) power limits (read + write-back same value to prove the call) ##########"
$p1 = Num (Lfc 'GetPowerLimit1'); $p2 = Num (Lfc 'GetPowerLimit2')
"   GetPowerLimit1=$p1  GetPowerLimit2=$p2"
"   SetPowerLimit1($p1) -> $(Lfc 'SetPowerLimit1' @{Data = [uint32]$p1})   readback=$(Num (Lfc 'GetPowerLimit1'))"
"   SetPowerLimit2($p2) -> $(Lfc 'SetPowerLimit2' @{Data = [uint32]$p2})   readback=$(Num (Lfc 'GetPowerLimit2'))"

"`n########## cleanup ##########"
# ramp fans UP first (safe), then hand control back by re-applying the Fn+Q mode
Lfc 'SetFan1Speed' @{Data = [uint32]255 } | Out-Null
Lfc 'SetFan2Speed' @{Data = [uint32]255 } | Out-Null
Start-Sleep -Seconds 2
"   restore mode=$ORIG -> $(CallW $GZ 'SetSmartFanMode' @{Data = [uint32]$ORIG})"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false} | Out-Null
Start-Sleep -Seconds 6
"   final: mode=$(ModeNow) lfc=$(Num (Lfc 'GetFan1Speed'))/$(Num (Lfc 'GetFan2Speed')) gamezone=$(Rpm 1)/$(Rpm 2) cpu=$(Num (Lfc 'GetCPUTemperature'))"
"   (if gamezone rpm returned to ~4500 the EC has resumed automatic control)"
'PROBE14_DONE'
