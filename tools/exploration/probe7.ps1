$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()

$script:Objs = @{}
foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD') {
  $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn"))
  foreach ($o in $sr.Get()) { $script:Objs[$cn] = $o; break }
}

function Out-All($tag, $out) {
  if ($null -eq $out) { "  $tag -> NULL"; return }
  $names = @()
  try { $names = @($out.Properties | ForEach-Object { $_.Name }) } catch {}
  $pairs = foreach ($n in $names) {
    $v = $out[$n]
    if ($v -is [byte[]]) { $v = 'hex=' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ' dec=' + ($v -join ',') }
    "$n=[$v]"
  }
  "  $tag -> props($(($out.Properties | Measure-Object).Count)): $($pairs -join '  ')"
}

function Call($cn, $m, $hs) {
  try { Out-All "$cn.$m $(($hs.Keys | Sort-Object) | ForEach-Object { "$_=$($hs[$_])" } | Out-String).Trim()" (Invoke-Method $cn $m $hs) }
  catch { "  $cn.$m ERR $($_.Exception.Message)" }
}
function Invoke-Method($cn, $m, $hs) { $script:Objs[$cn].InvokeMethod($m, $hs) }

"########## GameZone via InvokeMethod(name, hashtable) ##########"
Call 'LENOVO_GAMEZONE_DATA' 'GetVersion'        @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetProductInfo'    @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetFanCount'       @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetFan1Speed'      @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetFan2Speed'      @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetFanMaxSpeed'    @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetCPUTemp'        @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetGPUTemp'        @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetIRTemp'         @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetSmartFanMode'   @{}
Call 'LENOVO_GAMEZONE_DATA' 'IsSupportSmartFan' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetSmartFanSetting' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetThermalMode'    @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetThermalTableID' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetPowerChargeMode' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetTriggerTemperatureValue' @{}
Call 'LENOVO_GAMEZONE_DATA' 'IsSupportFanCooling' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetFanCoolingStatus' @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetCpuFrequency'   @{}
Call 'LENOVO_GAMEZONE_DATA' 'GetHardwareInfoSupportVersion' @{}
"  --- with explicit Data=0 (some builds require the in-key) ---"
Call 'LENOVO_GAMEZONE_DATA' 'GetSmartFanMode' @{Data = 0}
Call 'LENOVO_GAMEZONE_DATA' 'GetCPUTemp'      @{Data = 0}

"`n########## FAN_METHOD: ids ##########"
foreach ($f in 0, 1, 2, 3) { Call 'LENOVO_FAN_METHOD' 'Fan_GetCurrentFanSpeed' @{FanID = [byte]$f} }
foreach ($s in 0, 1, 2, 3, 4) { Call 'LENOVO_FAN_METHOD' 'Fan_GetCurrentSensorTemperature' @{SensorID = [byte]$s} }
Call 'LENOVO_FAN_METHOD' 'Fan_Get_FullSpeed' @{}

"`n########## FAN_METHOD: max speed tables ##########"
foreach ($f in 0, 1, 2, 3) { Call 'LENOVO_FAN_METHOD' 'Fan_Get_MaxSpeed' @{Fan_ID = [byte]$f} }

"`n########## FAN_METHOD: fan curves (the important part) ##########"
foreach ($f in 0, 1, 2, 3) {
  foreach ($s in 0, 1, 2, 3, 4) {
    Call 'LENOVO_FAN_METHOD' 'Fan_Get_Table' @{FanID = [byte]$f; SensorID = [byte]$s}
  }
}

"`n########## CPU/GPU EC power limits (beyond the Windows power plan) ##########"
foreach ($m in 'CPU_Get_Default_PowerLimit', 'CPU_Get_ShortTerm_PowerLimit', 'CPU_Get_LongTerm_PowerLimit', 'CPU_Get_Temperature_Control', 'CPU_Get_Cross_Loading_PowerLimit') {
  Call 'LENOVO_CPU_METHOD' $m @{}
}
foreach ($m in 'GPU_Get_cTGP_PowerLimit', 'GPU_Get_PPAB_PowerLimit', 'GPU_Get_Temperature_Limit', 'GPU_Get_Boost_Clock') {
  Call 'LENOVO_GPU_METHOD' $m @{}
}
'PROBE7_DONE'
