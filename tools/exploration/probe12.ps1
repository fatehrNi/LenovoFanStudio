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
$OM = Get-Obj 'LENOVO_OTHER_METHOD'
$CU = Get-Obj 'LENOVO_UTILITY_DATA'

function Call0($o, $m) { $r = $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null); if ($null -eq $r) { return 'NULL' }; $p = @(); foreach ($x in $r.Properties) { $v = $x.Value; if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ']' }; $p += "$($x.Name)=$v" }; ($p -join '  ') }
function Call1($o, $m, [hashtable]$a) {
  $ip = $o.GetMethodParameters($m)
  if ($null -eq $ip) { return "(no in-params for $m)" }
  foreach ($k in $a.Keys) { try { $ip[$k] = $a[$k] } catch { return "set $k failed: $($_.Exception.Message)" } }
  $r = $o.InvokeMethod($m, $ip, $null)
  if ($null -eq $r) { return 'RETURN-NULL' }
  $p = @(); foreach ($x in $r.Properties) { $v = $x.Value; if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ']len=' + $v.Length }; $p += "$($x.Name)=$v" }
  ($p -join '  ')
}
function Rpm([byte]$f) { [int](Call1 $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f} | ForEach-Object { if ($_ -match 'CurrentFanSpeed=(\d+)') { $matches[1] } }) }
function HexTable([byte]$f, [byte]$s) { Call1 $FM 'Fan_Get_Table' @{FanID = $f; SensorID = $s} }
function ModeNow { $v = Call0 $GZ 'GetSmartFanMode'; if ($v -match 'Data=(\d+)') { [int]$matches[1] } else { -1 } }
$ORIG = ModeNow

"########## 0) references ##########"
"   nvidia-smi gpu: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader) -join ' | ')"
"   EC s3=$(Call1 $FM 'Fan_GetCurrentSensorTemperature' @{SensorID=3}) s4=$(Call1 $FM 'Fan_GetCurrentSensorTemperature' @{SensorID=4})"
try { $tz = Get-Counter -ListSet *thermal* -ErrorAction Stop; $tz | ForEach-Object { "   counterset: $($_.SetName)" } } catch { "   no thermal counterset" }
try { (Get-CimClass -Namespace 'root\wmi' -ClassName '*Thermal*' | ForEach-Object CimClassName) -join ', ' | ForEach-Object { "   root\wmi thermal classes: $_" } } catch {}

"`n########## A) which Fn+Q modes does this EC accept? ##########"
"   current mode = $ORIG"
foreach ($m in 1, 2, 3, 4) {
  "   SetSmartFanMode($m) -> $(Call1 $GZ 'SetSmartFanMode' @{Data = [uint32]$m})  readback=$(ModeNow)"
  Start-Sleep -Milliseconds 800
}
Call1 $GZ 'SetSmartFanMode' @{Data = [uint32]$ORIG} | Out-Null

"`n########## B) OTHER_METHOD capabilities ##########"
foreach ($i in 0..6) { "   GetSupportThermalMode(mode=$i)   -> $(Call1 $OM 'GetSupportThermalMode' @{mode = [uint32]$i})" }
foreach ($i in 0..6) { "   GetCustomModeAbility(Ability=$i) -> $(Call1 $OM 'GetCustomModeAbility' @{Ability = [uint32]$i})" }
foreach ($i in 0, 1, 2, 4, 8) { "   Get_Legion_Device_Support_Feature(Status=$i) -> $(Call1 $OM 'Get_Legion_Device_Support_Feature' @{Status = [uint32]$i})" }
foreach ($i in 0, 1, 2) { "   Get_Device_Current_Support_Feature(Flag=$i)    -> $(Call1 $OM 'Get_Device_Current_Support_Feature' @{Flag = [uint32]$i})" }
"   Get_Support_LegionZone_Version -> $(Call1 $OM 'Get_Support_LegionZone_Version' @{Version = [uint32]0})"
"   UTILITY GetIfSupportOrVersion(0) -> $(Call1 $CU 'GetIfSupportOrVersion' @{datatype = [uint32]0})"
"   UTILITY GetIfSupportOrVersion(1) -> $(Call1 $CU 'GetIfSupportOrVersion' @{datatype = [uint32]1})"
"   IsSupportFanCooling -> $(Call0 $GZ 'IsSupportFanCooling')  GetFanCoolingStatus -> $(Call0 $GZ 'GetFanCoolingStatus')"
"   GetThermalTableID -> $(Call0 $GZ 'GetThermalTableID')   GetThermalMode -> $(Call0 $GZ 'GetThermalMode')"
"   GetIntelligentSubMode -> $(Call0 $GZ 'GetIntelligentSubMode')"

"`n########## C) custom-mode status switch + fan tables ##########"
function TryTables($tag) {
  foreach ($pair in @(@(1, 1), @(1, 3), @(2, 1), @(2, 3))) { "     [$tag] table fan=$($pair[0]) sensor=$($pair[1]) -> $(HexTable $pair[0] $pair[1])" }
  "     [$tag] maxspeed fan1 -> $(Call1 $FM 'Fan_Get_MaxSpeed' @{Fan_ID = [byte]1})"
}
"   tables in normal state:"; TryTables 'base'
foreach ($st in 1, 2, 3) {
  "   Set_Custom_Mode_Status($st) -> $(Call1 $OM 'Set_Custom_Mode_Status' @{Status = [byte]$st})  mode=$(ModeNow)"
  Start-Sleep -Seconds 1
  TryTables "cms=$st"
  "   SetCurrentFanSpeed(fan1,6000) -> $(Call1 $FM 'Fan_SetCurrentFanSpeed' @{CurrentFanSpeed = [uint16]6000; FanID = [byte]1})"
  Start-Sleep -Seconds 4
  "   rpm now: fan1=$(Rpm 1) fan2=$(Rpm 2)"
}
Call1 $OM 'Set_Custom_Mode_Status' @{Status = [byte]0} | Out-Null

"`n########## D) per-fan RPM in each accepted mode ##########"
foreach ($m in 1, 2, 3) {
  Call1 $GZ 'SetSmartFanMode' @{Data = [uint32]$m} | Out-Null
  Start-Sleep -Seconds 1
  "   mode=$m (readback $(ModeNow))  baseline fan1=$(Rpm 1) fan2=$(Rpm 2)"
  "     set fan1=6000 -> $(Call1 $FM 'Fan_SetCurrentFanSpeed' @{CurrentFanSpeed = [uint16]6000; FanID = [byte]1})"
  Start-Sleep -Seconds 5
  "     after 5s fan1=$(Rpm 1) fan2=$(Rpm 2)"
  "     set fan2=6000 -> $(Call1 $FM 'Fan_SetCurrentFanSpeed' @{CurrentFanSpeed = [uint16]6000; FanID = [byte]2})"
  Start-Sleep -Seconds 5
  "     after 5s fan1=$(Rpm 1) fan2=$(Rpm 2)"
}

"`n########## E) (deferred) Fan_Set_Table / Set_MaxSpeed writes ##########"
"   skipped: table encoding unknown and original tables cannot be read back on this BIOS,"
"   so writing them blind is not reversible. Software-side RPM control is used instead."

"`n########## cleanup ##########"
"   fullspeed off -> $(Call1 $FM 'Fan_Set_FullSpeed' @{Status = $false})"
Call1 $GZ 'SetSmartFanMode' @{Data = [uint32]$ORIG} | Out-Null
Start-Sleep -Seconds 3
"   final: mode=$(ModeNow) fan1=$(Rpm 1) fan2=$(Rpm 2)  (original mode was $ORIG)"
'PROBE12_DONE'
