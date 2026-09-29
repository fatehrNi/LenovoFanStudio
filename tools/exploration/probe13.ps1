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
$GZ = Get-Obj 'LENOVO_GAMEZONE_DATA'
$FM = Get-Obj 'LENOVO_FAN_METHOD'
$OM = Get-Obj 'LENOVO_OTHER_METHOD'

function CallW($o, $m, [hashtable]$a = @{}) {
  if (-not $o) { return "NO-OBJECT" }
  try {
    $ip = $null
    try { $ip = $o.GetMethodParameters($m) } catch { }
    if ($null -ne $ip) { foreach ($k in $a.Keys) { try { $ip[$k] = $a[$k] } catch { } } }
    $r = if ($null -eq $ip) { $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null) } else { $o.InvokeMethod($m, $ip, [System.Management.InvokeMethodOptions]$null) }
    if ($null -eq $r) { return 'NULL' }
    $p = @()
    foreach ($x in $r.Properties) { $v = $x.Value; if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ']len=' + $v.Length }; $p += "$($x.Name)=$v" }
    if ($p.Count -eq 0) { return '(empty return)' }
    return ($p -join '  ')
  } catch { return "ERR $($_.Exception.Message)" }
}
function Num($s, $name) { if ($s -match "$name=(\-?\d+)") { return [int]$matches[1] } return -1 }
function Rpm([byte]$f) { Num (CallW $FM 'Fan_GetCurrentFanSpeed' @{FanID = $f}) 'CurrentFanSpeed' }
function Sen([byte]$s) { Num (CallW $FM 'Fan_GetCurrentSensorTemperature' @{SensorID = $s}) 'CurrentSensorTemperature' }
function ModeNow { Num (CallW $GZ 'GetSmartFanMode') 'Data' }
$ORIG = ModeNow

"########## 1) Lfc_thermal_interface (Lenovo thermal driver) ##########"
try {
  $cc = Get-CimClass -Namespace 'root\wmi' -ClassName 'Lfc_thermal_interface'
  "   methods: " + (($cc.CimClassMethods | ForEach-Object { "$($_.Name)($(($_.Parameters | ForEach-Object Name) -join ','))" }) -join '  ')
  $inst = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'Lfc_thermal_interface' -ErrorAction Stop)
  "   instances=$($inst.Count)"
  foreach ($i in ($inst | Select-Object -First 4)) { "     " + ($i | ConvertTo-Json -Compress -Depth 2) }
} catch { "   ERR $($_.Exception.Message)" }
try { $z = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop); "   MSAcpi zones=$($z.Count): " + (($z | ForEach-Object { "$($_.InstanceName)=$($_.CurrentTemperature)" }) -join ' ') } catch { "   MSAcpi ERR $($_.Exception.Message)" }
try { $p = @(Get-CimInstance -ClassName 'Win32_PerfFormattedData_Counters_ThermalZoneInformation' -ErrorAction Stop); "   perf thermal zones=$($p.Count): " + (($p | ForEach-Object { "$($_.Name)=$($_.Temperature)" }) -join ' ') } catch { "   perf thermal ERR $($_.Exception.Message)" }

"`n########## 2) which EC sensor tracks CPU? (load ramp, sensors 0..12) ##########"
$ids = 0..12
function Wide($tag) { "   {0,-14} {1}" -f $tag, (($ids | ForEach-Object { "s$_=$(Sen $_)" }) -join ' ') }
"   nvidia-smi: $((nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader) -join ' | ')"
Wide 'idle'
$jobs = 1..12 | ForEach-Object { Start-Job -ScriptBlock { $z = 0.0; for ($i = 0; $i -lt 40000000; $i++) { $z += [math]::Sqrt($i) } } }
foreach ($t in 1..5) { Start-Sleep -Seconds 6; Wide "load+$($t*6)s"; "     cpu load=$(@(Get-CimInstance Win32_Processor).CurrentLoad)% rpm=$(Rpm 1)/$(Rpm 2)" }
$jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
foreach ($t in 1..3) { Start-Sleep -Seconds 6; Wide "cool+$($t*6)s" }

"`n########## 3) Fan_SetCurrentFanSpeed — does RPM follow? (raise-only) ##########"
"   mode=$(ModeNow) baseline fan1=$(Rpm 1) fan2=$(Rpm 2)"
foreach ($m in 3, 2, 1) {
  "   --- smart fan mode $m ---"
  CallW $GZ 'SetSmartFanMode' @{Data = [uint32]$m} | Out-Null
  Start-Sleep -Seconds 2
  "   mode now=$(ModeNow) base fan1=$(Rpm 1) fan2=$(Rpm 2)"
  foreach ($v in 6400, 5000) {
    "     Fan_SetCurrentFanSpeed(fan1,$v) -> $(CallW $FM 'Fan_SetCurrentFanSpeed' @{CurrentFanSpeed = [uint16]$v; FanID = [byte]1})"
    Start-Sleep -Seconds 5
    "       fan1=$(Rpm 1) fan2=$(Rpm 2)  fullspeed=$(CallW $FM 'Fan_Get_FullSpeed')"
  }
}
"`n########## 4) fullspeed cross-check + fan identity ##########"
"     Fan_Set_FullSpeed(true) -> $(CallW $FM 'Fan_Set_FullSpeed' @{Status = $true})"
Start-Sleep -Seconds 6
"       fan1=$(Rpm 1) fan2=$(Rpm 2) fullspeed=$(CallW $FM 'Fan_Get_FullSpeed')"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false} | Out-Null
Start-Sleep -Seconds 6
"     after off: fan1=$(Rpm 1) fan2=$(Rpm 2)"

"`n########## 5) OTHER_METHOD (all with try) ##########"
foreach ($m in 'GetSupportThermalMode', 'GetCustomModeAbility', 'Set_Custom_Mode_Status', 'Get_Legion_Device_Support_Feature', 'Get_Device_Current_Support_Feature', 'Get_Support_LegionZone_Version', 'GetDeviceType') {
  "   $m -> $(CallW $OM $m)"
}

"`n########## cleanup ##########"
CallW $FM 'Fan_Set_FullSpeed' @{Status = $false} | Out-Null
CallW $GZ 'SetSmartFanMode' @{Data = [uint32]$ORIG} | Out-Null
Start-Sleep -Seconds 3
"   final mode=$(ModeNow) fan1=$(Rpm 1) fan2=$(Rpm 2) (orig mode $ORIG)"
'PROBE13_DONE'
