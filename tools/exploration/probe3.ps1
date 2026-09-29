$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$log = 'E:\vibecoding\qoder\fans\logs\probe3.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null

"### elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
"### whoami: $(whoami)"

function Try-Call($label, [scriptblock]$body) {
  Write-Host "`n--- $label"
  try {
    $r = & $body
    if ($null -eq $r) { "    (no output)" }
    else { ($r | Out-String).TrimEnd() -split "`n" | ForEach-Object { "    $_" } }
  } catch {
    "    ERROR: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    if ($_.Exception.ErrorCode) { "    HRESULT: 0x{0:X8}" -f $_.Exception.ErrorCode }
  }
}

"=== instances of method classes ==="
foreach ($cn in 'LENOVO_FAN_METHOD','LENOVO_GAMEZONE_DATA','LENOVO_CPU_METHOD','LENOVO_GPU_METHOD','LENOVO_OTHER_METHOD','LENOVO_UTILITY_DATA') {
  Try-Call "Get-CimInstance $cn" { Get-CimInstance -Namespace 'root\wmi' -ClassName $cn | Out-String }
}

"=== LENOVO_FAN_METHOD reads (CIM) ==="
Try-Call 'Fan_Get_FullSpeed'      { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_Get_FullSpeed' -Arguments @{Status=$false} | Out-String }
Try-Call 'Fan_GetCurrentFanSpeed 0' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_GetCurrentFanSpeed' -Arguments @{FanID=[byte]0} | Out-String }
Try-Call 'Fan_GetCurrentFanSpeed 1' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_GetCurrentFanSpeed' -Arguments @{FanID=[byte]1} | Out-String }
Try-Call 'Fan_GetCurrentSensorTemperature 0' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_GetCurrentSensorTemperature' -Arguments @{SensorID=[byte]0} | Out-String }
Try-Call 'Fan_GetCurrentSensorTemperature 1' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_GetCurrentSensorTemperature' -Arguments @{SensorID=[byte]1} | Out-String }
Try-Call 'Fan_GetCurrentSensorTemperature 2' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_GetCurrentSensorTemperature' -Arguments @{SensorID=[byte]2} | Out-String }
Try-Call 'Fan_Get_MaxSpeed 0' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_Get_MaxSpeed' -Arguments @{Fan_ID=[byte]0} | Out-String }
Try-Call 'Fan_Get_MaxSpeed 1' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_Get_MaxSpeed' -Arguments @{Fan_ID=[byte]1} | Out-String }
foreach ($f in 0,1,2) { foreach ($s in 0,1,2,3) {
  Try-Call "Fan_Get_Table fan=$f sensor=$s" { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_FAN_METHOD' -MethodName 'Fan_Get_Table' -Arguments @{FanID=[byte]$f; SensorID=[byte]$s} |
      ForEach-Object { "size=$($_.FanTableSize) bytes=$((($_.FanTable) | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') dec=$((($_.FanTable)) -join ',')" } }
}}

"=== GameZone reads (CIM) ==="
Try-Call 'GetFanCount'      { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetFanCount' -Arguments @{Data=0} | Out-String }
Try-Call 'GetFan1Speed'     { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetFan1Speed' -Arguments @{Data=0} | Out-String }
Try-Call 'GetFan2Speed'     { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetFan2Speed' -Arguments @{Data=0} | Out-String }
Try-Call 'GetFanMaxSpeed'   { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetFanMaxSpeed' -Arguments @{Data=0} | Out-String }
Try-Call 'GetCPUTemp'       { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetCPUTemp' -Arguments @{Data=0} | Out-String }
Try-Call 'GetGPUTemp'       { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetGPUTemp' -Arguments @{Data=0} | Out-String }
Try-Call 'GetIRTemp'        { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetIRTemp' -Arguments @{Data=0} | Out-String }
Try-Call 'GetSmartFanMode'  { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetSmartFanMode' -Arguments @{Data=0} | Out-String }
Try-Call 'IsSupportSmartFan'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'IsSupportSmartFan' -Arguments @{Data=0} | Out-String }
Try-Call 'IsSupportFanCooling'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'IsSupportFanCooling' -Arguments @{Data=0} | Out-String }
Try-Call 'GetFanCoolingStatus'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetFanCoolingStatus' -Arguments @{Data=0} | Out-String }
Try-Call 'GetThermalTableID'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetThermalTableID' -Arguments @{Data=0} | Out-String }
Try-Call 'GetThermalMode'   { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetThermalMode' -Arguments @{Data=0} | Out-String }
Try-Call 'GetVersion'       { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetVersion' -Arguments @{Data=0} | Out-String }
Try-Call 'GetProductInfo'   { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetProductInfo' -Arguments @{Data=0} | Out-String }
Try-Call 'GetPowerChargeMode'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetPowerChargeMode' | Out-String }
Try-Call 'GetTriggerTemperatureValue'{ Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE_DATA' -MethodName 'GetTriggerTemperatureValue' -Arguments @{Data=0} | Out-String }

"=== legacy WMI (COM) fallback check ==="
Try-Call 'Get-WmiObject LENOVO_FAN_METHOD' { Get-WmiObject -Namespace 'root\wmi' -Class LENOVO_FAN_METHOD -List | Out-String }
Try-Call 'COM Fan_GetCurrentFanSpeed fan1' {
  $cls = ([wmiclass]"root\wmi:LENOVO_FAN_METHOD")
  $in = $cls.Put(); $in.FanID = 1
  $out = $cls.Fan_GetCurrentFanSpeed(1)
  $out | Out-String
}

"=== CPU/GPU power limits (read only) ==="
Try-Call 'CPU_Get_ShortTerm_PowerLimit' { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_CPU_METHOD' -MethodName 'CPU_Get_ShortTerm_PowerLimit' | Out-String }
Try-Call 'CPU_Get_LongTerm_PowerLimit'  { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_CPU_METHOD' -MethodName 'CPU_Get_LongTerm_PowerLimit' | Out-String }
Try-Call 'CPU_Get_Default_PowerLimit'   { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_CPU_METHOD' -MethodName 'CPU_Get_Default_PowerLimit' | Out-String }
Try-Call 'CPU_Get_Temperature_Control'  { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_CPU_METHOD' -MethodName 'CPU_Get_Temperature_Control' | Out-String }
Try-Call 'GPU_Get_cTGP_PowerLimit'      { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GPU_METHOD' -MethodName 'GPU_Get_cTGP_PowerLimit' | Out-String }
Try-Call 'GPU_Get_Temperature_Limit'    { Invoke-CimMethod -Namespace 'root\wmi' -ClassName 'LENOVO_GPU_METHOD' -MethodName 'GPU_Get_Temperature_Limit' | Out-String }

Stop-Transcript | Out-Null
"PROBE3_DONE"
