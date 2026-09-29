$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()

function Get-FirstObj([string]$cn) {
  $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn"))
  $coll = $sr.Get()
  if ($coll.Count -lt 1) { throw "no instance for $cn" }
  foreach ($o in $coll) { return $o }
}

foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD') {
  "==================== $cn ===================="
  $o = Get-FirstObj $cn
  "path          = $($o.Path.Path)"
  "Methods null? = $($null -eq $o.Methods)   count=$(if ($o.Methods) { $o.Methods.Count } else { 'n/a' })"
  try { $o.Get() } catch { ".Get() threw: $($_.Exception.Message)" }
  "after Get(): count=$(if ($o.Methods) { $o.Methods.Count } else { 'n/a' })"
  "class of obj  = $($o.GetType().FullName)"
  "ClassPath     = $($o.ClassPath)"
  foreach ($m in 'GetSmartFanMode', 'GetCPUTemp', 'Fan_GetCurrentFanSpeed') {
    $has = if ($o.Methods) { [bool]$o.Methods[$m] } else { 'methods-null' }
    $gmp = try { $ip = $o.GetMethodParameters($m); if ($ip) { ($ip.Properties | ForEach-Object { $_.Name }) -join ',' } else { 'NULL' } } catch { "threw: $($_.Exception.Message)" }
    "  method '$m' inMethods=$has GetMethodParameters=[$gmp]"
  }
}

"`n########## strategies to call LENOVO_GAMEZONE_DATA.GetSmartFanMode ##########"
$GZ = 'LENOVO_GAMEZONE_DATA'
$inst = Get-FirstObj $GZ

'--- S1 instance.GetMethodParameters + instance.InvokeMethod'
try {
  $ip = $inst.GetMethodParameters('GetSmartFanMode')
  if ($ip) { $ip['Data'] = [uint32]0; $out = $inst.InvokeMethod('GetSmartFanMode', $ip, $null); "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ') } else { '  GetMethodParameters returned NULL' }
} catch { "  ERR $($_.Exception.Message)" }

'--- S2 class schema + instance invoke'
try {
  $cls = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $GZ), $null)
  $ip = $cls.GetMethodParameters('GetSmartFanMode')
  "  class in-params: " + (($ip.Properties | ForEach-Object { "$($_.Name):$($_.CimType)" }) -join ' ')
  $ip['Data'] = [uint32]0
  $out = $inst.InvokeMethod('GetSmartFanMode', $ip, $null)
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S3 InvokeMethod(name, hashtable)'
try {
  $out = $inst.InvokeMethod('GetSmartFanMode', @{ Data = [uint32]0 })
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S4 InvokeMethod(name, object[])'
try {
  $out = $inst.InvokeMethod('GetSmartFanMode', @([uint32]0))
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S5 fresh ManagementObject via ClassPath + Options'
try {
  $opts = New-Object System.Management.ObjectGetOptions
  $opts.EnablePrivileges = $true
  $mo = New-Object System.Management.ManagementObject('root\wmi', "$GZ.InstanceName=""ACPI\\PNP0C14\\GMZN_0""", $opts)
  "  methods=$(if ($mo.Methods) { $mo.Methods.Count } else { 'null' })"
  $ip = $mo.GetMethodParameters('GetSmartFanMode'); $ip['Data'] = [uint32]0
  $out = $mo.InvokeMethod('GetSmartFanMode', $ip, $null)
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S6 legacy [WmiClass] adapter GetMethodParameters + ExecMethod (class level, elevated)'
try {
  $wc = [WmiClass]"root\wmi:$GZ"
  $ip = $wc.GetMethodParameters('GetSmartFanMode')
  "  in: " + (($ip.Properties | ForEach-Object { "$($_.Name)" }) -join ',')
  $ip['Data'] = [uint32]0
  $out = $wc.ExecMethod('GetSmartFanMode', $ip)
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S7 legacy [WmiClass] one-liner method call'
try {
  $wc = [WmiClass]"root\wmi:$GZ"
  $out = $wc.GetSmartFanMode(0)
  "  OK -> " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

'--- S8 Get-CimInstance piped to Invoke-CimMethod (elevated)'
try {
  $out = Get-CimInstance -Namespace 'root\wmi' -ClassName $GZ | Invoke-CimMethod -MethodName 'GetSmartFanMode' -Arguments @{ Data = 0 }
  "  OK -> " + (($out | Get-Member -MemberType Properties | ForEach-Object { "$($_.Name)=$($out.($_.Name))" }) -join '  ')
} catch { "  ERR $($_.Exception.Message)" }

"`n########## fan method sanity (known good) ##########"
$finst = Get-FirstObj 'LENOVO_FAN_METHOD'
try {
  $ip = $finst.GetMethodParameters('Fan_GetCurrentFanSpeed'); $ip['FanID'] = [byte]1
  $out = $finst.InvokeMethod('Fan_GetCurrentFanSpeed', $ip, $null)
  "  fan1 RPM = $($out['CurrentFanSpeed'])  (methods count=$(if ($finst.Methods) { $finst.Methods.Count } else { 'null' }))"
} catch { "  ERR $($_.Exception.Message)" }
'PROBE6_DONE'
