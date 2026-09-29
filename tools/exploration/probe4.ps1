$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Management
$log = 'E:\vibecoding\qoder\fans\logs\probe4.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null

"elevated=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

$script:Scope = New-Object System.Management.ManagementScope 'root\wmi'
$script:Scope.Options.EnablePrivileges = $true
$script:Scope.Connect()

function Invoke-LenovoMethod {
  param([string]$ClassName, [string]$MethodName, [hashtable]$Params = @{})
  $mp   = New-Object System.Management.ManagementPath($ClassName)
  $cls  = New-Object System.Management.ManagementClass($script:Scope, $mp, $null)
  $in   = $cls.GetMethodParameters($MethodName)
  foreach ($k in $Params.Keys) { $in[$k] = $Params[$k] }
  return $cls.InvokeMethod($MethodName, $in, $null)
}

function Show($label, [string]$class, [string]$method, [hashtable]$margs) {
  Write-Host "`n--- $label"
  try {
    $o = Invoke-LenovoMethod -ClassName $class -MethodName $method -Params $margs
    if ($null -eq $o) { "    (null output)" ; return }
    foreach ($p in $o.Properties) {
      $v = $p.Value
      if ($v -is [byte[]]) { $v = "hex=" + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + " dec=" + ($v -join ',') }
      "    {0} = {1}" -f $p.Name, $v
    }
  } catch {
    "    ERROR $($_.Exception.GetType().Name): $($_.Exception.Message)"
  }
}

$FM = 'LENOVO_FAN_METHOD'
$GZ = 'LENOVO_GAMEZONE_DATA'

"=== FAN: identity ==="
Show 'Fan_Get_FullSpeed'  $FM 'Fan_Get_FullSpeed' @{}
Show 'Fan_Get_CurrentSpeed fan0' $FM 'Fan_GetCurrentFanSpeed' @{FanID=[byte]0}
Show 'Fan_Get_CurrentSpeed fan1' $FM 'Fan_GetCurrentFanSpeed' @{FanID=[byte]1}
Show 'Fan_Get_CurrentSpeed fan2' $FM 'Fan_GetCurrentFanSpeed' @{FanID=[byte]2}
foreach ($s in 0,1,2,3) { Show "Fan_Get_CurrentSensorTemp sensor$s" $FM 'Fan_GetCurrentSensorTemperature' @{SensorID=[byte]$s} }
Show 'Fan_Get_MaxSpeed fan0' $FM 'Fan_Get_MaxSpeed' @{Fan_ID=[byte]0}
Show 'Fan_Get_MaxSpeed fan1' $FM 'Fan_Get_MaxSpeed' @{Fan_ID=[byte]1}

"=== FAN: tables ==="
foreach ($f in 0,1,2) { foreach ($s in 0,1,2,3) { Show "Fan_Get_Table fan=$f sensor=$s" $FM 'Fan_Get_Table' @{FanID=[byte]$f; SensorID=[byte]$s} } }

"=== GAMEZONE: identity / modes ==="
Show 'GetVersion'          $GZ 'GetVersion' @{}
Show 'GetProductInfo'      $GZ 'GetProductInfo' @{}
Show 'GetFanCount'         $GZ 'GetFanCount' @{}
Show 'GetFan1Speed'        $GZ 'GetFan1Speed' @{}
Show 'GetFan2Speed'        $GZ 'GetFan2Speed' @{}
Show 'GetFanMaxSpeed'      $GZ 'GetFanMaxSpeed' @{}
Show 'GetCPUTemp'          $GZ 'GetCPUTemp' @{}
Show 'GetGPUTemp'          $GZ 'GetGPUTemp' @{}
Show 'GetIRTemp'           $GZ 'GetIRTemp' @{}
Show 'IsSupportSmartFan'   $GZ 'IsSupportSmartFan' @{}
Show 'GetSmartFanMode'     $GZ 'GetSmartFanMode' @{}
Show 'GetSmartFanSetting'  $GZ 'GetSmartFanSetting' @{}
Show 'IsSupportFanCooling' $GZ 'IsSupportFanCooling' @{}
Show 'GetFanCoolingStatus' $GZ 'GetFanCoolingStatus' @{}
Show 'GetThermalTableID'   $GZ 'GetThermalTableID' @{}
Show 'GetThermalMode'      $GZ 'GetThermalMode' @{}
Show 'GetPowerChargeMode'  $GZ 'GetPowerChargeMode' @{}
Show 'GetTriggerTemperatureValue' $GZ 'GetTriggerTemperatureValue' @{}
Show 'GetIntelligentSubMode' $GZ 'GetIntelligentSubMode' @{}

"=== OTHER_METHOD: capabilities ==="
Show 'Get_Legion_Device_Support_Feature' 'LENOVO_OTHER_METHOD' 'Get_Legion_Device_Support_Feature' @{Status=[uint32]0}
Show 'Get_Device_Current_Support_Feature' 'LENOVO_OTHER_METHOD' 'Get_Device_Current_Support_Feature' @{Flag=[uint32]0}
Show 'GetSupportThermalMode' 'LENOVO_OTHER_METHOD' 'GetSupportThermalMode' @{mode=[uint32]0}
Show 'GetCustomModeAbility'  'LENOVO_OTHER_METHOD' 'GetCustomModeAbility' @{Ability=[uint32]0}
Show 'Get_Support_LegionZone_Version' 'LENOVO_OTHER_METHOD' 'Get_Support_LegionZone_Version' @{Version=[uint32]0}
Show 'GetDeviceType' 'LENOVO_OTHER_METHOD' 'GetDeviceType' @{}

"=== POWER LIMITS (read only) ==="
Show 'CPU_Get_Default_PowerLimit' 'LENOVO_CPU_METHOD' 'CPU_Get_Default_PowerLimit' @{}
Show 'CPU_Get_ShortTerm_PowerLimit' 'LENOVO_CPU_METHOD' 'CPU_Get_ShortTerm_PowerLimit' @{}
Show 'CPU_Get_LongTerm_PowerLimit' 'LENOVO_CPU_METHOD' 'CPU_Get_LongTerm_PowerLimit' @{}
Show 'CPU_Get_Temperature_Control' 'LENOVO_CPU_METHOD' 'CPU_Get_Temperature_Control' @{}
Show 'CPU_Get_Cross_Loading_PowerLimit' 'LENOVO_CPU_METHOD' 'CPU_Get_Cross_Loading_PowerLimit' @{}
Show 'GPU_Get_cTGP_PowerLimit' 'LENOVO_GPU_METHOD' 'GPU_Get_cTGP_PowerLimit' @{}
Show 'GPU_Get_Temperature_Limit' 'LENOVO_GPU_METHOD' 'GPU_Get_Temperature_Limit' @{}
Show 'GPU_Get_PPAB_PowerLimit' 'LENOVO_GPU_METHOD' 'GPU_Get_PPAB_PowerLimit' @{}

"=== thermal zones via CIM ==="
try { Get-CimInstance -Namespace 'root\wmi' -ClassName MSAcpi_ThermalZoneTemperature | ForEach-Object { "    $($_.InstanceName) = $($_.CurrentTemperature) ($([math]::Round(($_.CurrentTemperature/10)-273.15,1)) C)" } } catch { "    ERROR $_" }

Stop-Transcript | Out-Null
"PROBE4_DONE"
