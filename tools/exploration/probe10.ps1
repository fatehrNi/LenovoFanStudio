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

function Props($o) {
  if ($null -eq $o) { return 'NULL' }
  $p = @()
  foreach ($x in $o.Properties) {
    $v = $x.Value
    if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + '] len=' + $v.Length }
    $p += "$($x.Name)=$v"
  }
  if ($p.Count -eq 0) { return '(no properties)' }
  return $p -join '  '
}
function InvokeNull([string]$cn, [string]$m) {
  $o = if ($cn -eq 'GZ') { $GZ } else { $FM }
  [string]$s = $null
  try { $r = $o.InvokeMethod($m, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null); return Props $r } catch { $s = $_.Exception.Message }
  return "ERR $s"
}

"########## A) zero-in-param dispatch: pass NULL in-params (explicit casts) ##########"
"   GZ.GetCPUTemp       => $(InvokeNull 'GZ' 'GetCPUTemp')"
"   GZ.GetGPUTemp       => $(InvokeNull 'GZ' 'GetGPUTemp')"
"   GZ.GetSmartFanMode  => $(InvokeNull 'GZ' 'GetSmartFanMode')"
"   GZ.GetFanCount      => $(InvokeNull 'GZ' 'GetFanCount')"
"   GZ.GetFan1Speed     => $(InvokeNull 'GZ' 'GetFan1Speed')"
"   GZ.GetFan2Speed     => $(InvokeNull 'GZ' 'GetFan2Speed')"
"   GZ.GetVersion       => $(InvokeNull 'GZ' 'GetVersion')"
"   GZ.IsSupportSmartFan=> $(InvokeNull 'GZ' 'IsSupportSmartFan')"
"   FM.Fan_Get_FullSpeed=> $(InvokeNull 'FM' 'Fan_Get_FullSpeed')"
$pc = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath('__PARAMETERS')), $null)
try {
  $in = $pc.CreateInstance()
  "   GZ.GetCPUTemp via fresh __PARAMETERS => $(Props $GZ.InvokeMethod('GetCPUTemp', $in, $null))"
} catch { "   fresh __PARAMETERS ERR $($_.Exception.Message)" }
try { $locator = New-Object -ComObject WbemScripting.SWbemLocator } catch {}
try {
  $svc = (New-Object -ComObject WbemScripting.SWbemLocator).ConnectServer('localhost', 'root\wmi')
  $op = "LENOVO_GAMEZONE_DATA.InstanceName=`"$(([string]$GZ['InstanceName']).Replace('\', '\\'))`""
  $o = $svc.ExecMethod($op, 'GetCPUTemp')
  $p = @(); foreach ($x in $o.Properties_) { $p += "$($x.Name)=$($x.Value)" }
  "   COM ExecMethod(instance, no in) => $($p -join '  ')"
} catch { "   COM ExecMethod ERR $($_.Exception.Message)" }
try {
  $o = Invoke-WmiMethod -Namespace 'root\wmi' -Class 'LENOVO_GAMEZONE_DATA' -Name 'GetCPUTemp'
  "   Invoke-WmiMethod (no args)      => $(Props ($o | ForEach-Object { $_ } | Out-Null))$((($o | Get-Member -MemberType Properties) | ForEach-Object { "$($_.Name)=$($o.($_.Name))" }) -join '  ')"
} catch { "   Invoke-WmiMethod ERR $($_.Exception.Message)" }

"`n########## B) FAN_METHOD baseline ##########"
function FanRpm([byte]$f) { $ip = $FM.GetMethodParameters('Fan_GetCurrentFanSpeed'); $ip['FanID'] = $f; [int]$FM.InvokeMethod('Fan_GetCurrentFanSpeed', $ip, $null)['CurrentFanSpeed'] }
function SenT([byte]$s) { $ip = $FM.GetMethodParameters('Fan_GetCurrentSensorTemperature'); $ip['SensorID'] = $s; [int]$FM.InvokeMethod('Fan_GetCurrentSensorTemperature', $ip, $null)['CurrentSensorTemperature'] }
$sens = @(foreach ($s in 0, 1, 2, 3, 4, 5) { "s$s=$(SenT $s)" }) -join ' '
"   fan1=$(FanRpm 1) fan2=$(FanRpm 2) fan0=$(FanRpm 0) fan3=$(FanRpm 3)"
"   sensors: $sens"

"`n########## C) Fan_Get_Table: COM route (arrays may marshal better) ##########"
function TableViaNet([byte]$f, [byte]$s) {
  $ip = $FM.GetMethodParameters('Fan_Get_Table'); $ip['FanID'] = $f; $ip['SensorID'] = $s
  Props $FM.InvokeMethod('Fan_Get_Table', $ip, $null)
}
try {
  $svc = (New-Object -ComObject WbemScripting.SWbemLocator).ConnectServer('localhost', 'root\wmi')
  $op = "LENOVO_FAN_METHOD.InstanceName=`"$(([string]$FM['InstanceName']).Replace('\', '\\'))`""
  $inst = $svc.Get($op)
  foreach ($pair in @(@(1, 1), @(1, 3), @(2, 4), @(1, 0), @(2, 0))) {
    $in = $inst.Methods_.Item('Fan_Get_Table').InParameters.SpawnInstance_()
    $in.FanID = [byte]$pair[0]; $in.SensorID = [byte]$pair[1]
    $out = $svc.ExecMethod($op, 'Fan_Get_Table', $in)
    $p = @(); foreach ($x in $out.Properties_) {
      $v = $x.Value
      if ($v -isnot [string] -and $v -is [System.Collections.IEnumerable]) { $v = 'arr[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + ']' }
      $p += "$($x.Name)=$v"
    }
    "   COM fan=$($pair[0]) sensor=$($pair[1]) => $($p -join '  ')"
  }
} catch { "   COM table ERR $($_.Exception.Message)" }
"   .NET fan=1 sensor=1 => $(TableViaNet 1 1)"
"   .NET fan=1 sensor=3 => $(TableViaNet 1 3)"
"   .NET fan=2 sensor=4 => $(TableViaNet 2 4)"

"`n########## D) Fan_Set_FullSpeed on/off (self-restoring, no mode change) ##########"
try {
  $ip = $FM.GetMethodParameters('Fan_Set_FullSpeed'); $ip['Status'] = $true
  "   set ON  => $(Props $FM.InvokeMethod('Fan_Set_FullSpeed', $ip, $null))"
  Start-Sleep -Seconds 5
  "   after 5s: fan1=$(FanRpm 1) fan2=$(FanRpm 2)"
} catch { "   set ON ERR $($_.Exception.Message)" }
finally {
  try { $ip = $FM.GetMethodParameters('Fan_Set_FullSpeed'); $ip['Status'] = $false; $FM.InvokeMethod('Fan_Set_FullSpeed', $ip, $null) | Out-Null; "   set OFF done" } catch { "   set OFF ERR $($_.Exception.Message)" }
  Start-Sleep -Seconds 5
  function FanRpm2([byte]$f) { $ip = $FM.GetMethodParameters('Fan_GetCurrentFanSpeed'); $ip['FanID'] = $f; [int]$FM.InvokeMethod('Fan_GetCurrentFanSpeed', $ip, $null)['CurrentFanSpeed'] }
  "   final: fan1=$(FanRpm2 1) fan2=$(FanRpm2 2)"
}
'PROBE10_DONE'
