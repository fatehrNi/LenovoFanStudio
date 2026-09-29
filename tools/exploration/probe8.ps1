$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.Management
$scope = New-Object System.Management.ManagementScope 'root\wmi'
try { $scope.Options.EnablePrivileges = $true } catch {}
$scope.Connect()

$script:Obj = @{}
$script:Cls = @{}
foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD', 'LENOVO_CPU_METHOD', 'LENOVO_GPU_METHOD', 'LENOVO_OTHER_METHOD', 'LENOVO_MEMORY_METHOD', 'LENOVO_PANEL_METHOD', 'LENOVO_LIGHTING_METHOD') {
  try {
    $sr = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $cn"))
    $coll = $sr.Get()
    foreach ($o in $coll) { $script:Obj[$cn] = $o; break }
    $script:Cls[$cn] = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $cn), $null)
  } catch { "init $cn ERR $($_.Exception.Message)" }
}

function Show-Out($tag, $out) {
  if ($null -eq $out) { "  $tag => NULL-RETURN"; return }
  $parts = foreach ($p in $out.Properties) {
    $v = $p.Value
    if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + '] dec[' + ($v -join ',') + ']' }
    "$($p.Name)=$v"
  }
  "  $tag => " + ($parts -join '  ')
}

# strategy A: class GetMethodParameters -> instance InvokeMethod  (works for methods WITH in-params)
# strategy B: Methods[m].InParameters -> instance InvokeMethod     (works for methods with NO in-params)
# strategy C: CIM cmdlet without -Arguments                        (zero-in methods)
function Try-A([string]$cn, [string]$m, [hashtable]$in = @{}) {
  try {
    $ip = $script:Cls[$cn].GetMethodParameters($m)
    if ($null -eq $ip) { "  [A] $cn.$m : class GetMethodParameters=NULL"; return }
    foreach ($k in $in.Keys) { $ip[$k] = $in[$k] }
    Show-Out "[A] $cn.$m $(($in.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')" ($script:Obj[$cn].InvokeMethod($m, $ip, $null))
  } catch { "  [A] $cn.$m ERR $($_.Exception.Message)" }
}
function Try-B([string]$cn, [string]$m, [hashtable]$in = @{}) {
  try {
    $md = $script:Cls[$cn].Methods[$m]
    if ($null -eq $md) { "  [B] $cn.$m : method not in schema"; return }
    $ip = $md.InParameters
    if ($null -eq $ip) { "  [B] $cn.$m : InParameters=NULL"; return }
    foreach ($k in $in.Keys) { $ip[$k] = $in[$k] }
    Show-Out "[B] $cn.$m $(($in.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')" ($script:Obj[$cn].InvokeMethod($m, $ip, $null))
  } catch { "  [B] $cn.$m ERR $($_.Exception.Message)" }
}
function Try-C([string]$cn, [string]$m) {
  try { Show-Out "[C] CIM $cn.$m" (Invoke-CimMethod -Namespace 'root\wmi' -ClassName $cn -MethodName $m) }
  catch { "  [C] CIM $cn.$m ERR $($_.Exception.Message)" }
}

"########## zero-in-param methods ##########"
foreach ($m in 'GetCPUTemp', 'GetGPUTemp', 'GetSmartFanMode', 'GetFanCount', 'GetVersion', 'IsSupportSmartFan', 'GetPowerChargeMode') {
  Try-B 'LENOVO_GAMEZONE_DATA' $m; Try-A 'LENOVO_GAMEZONE_DATA' $m; Try-C 'LENOVO_GAMEZONE_DATA' $m
}
Try-B 'LENOVO_FAN_METHOD' 'Fan_Get_FullSpeed'; Try-A 'LENOVO_FAN_METHOD' 'Fan_Get_FullSpeed'; Try-C 'LENOVO_FAN_METHOD' 'Fan_Get_FullSpeed'

"`n########## FAN_METHOD: ids + tables (strategy A, proven) ##########"
foreach ($f in 0, 1, 2, 3) { Try-A 'LENOVO_FAN_METHOD' 'Fan_GetCurrentFanSpeed' @{FanID = [byte]$f} }
foreach ($s in 0, 1, 2, 3, 4) { Try-A 'LENOVO_FAN_METHOD' 'Fan_GetCurrentSensorTemperature' @{SensorID = [byte]$s} }
foreach ($f in 0, 1, 2, 3) { Try-A 'LENOVO_FAN_METHOD' 'Fan_Get_MaxSpeed' @{Fan_ID = [byte]$f} }
"`n  ---- curves ----"
foreach ($f in 0, 1, 2, 3) {
  foreach ($s in 0, 1, 2, 3, 4) { Try-A 'LENOVO_FAN_METHOD' 'Fan_Get_Table' @{FanID = [byte]$f; SensorID = [byte]$s} }
}

"`n########## EC power limits (strategy B/A) ##########"
foreach ($m in 'CPU_Get_Default_PowerLimit', 'CPU_Get_ShortTerm_PowerLimit', 'CPU_Get_LongTerm_PowerLimit', 'CPU_Get_Temperature_Control') { Try-B 'LENOVO_CPU_METHOD' $m; Try-C 'LENOVO_CPU_METHOD' $m }
foreach ($m in 'GPU_Get_cTGP_PowerLimit', 'GPU_Get_Temperature_Limit', 'GPU_Get_Boost_Clock') { Try-B 'LENOVO_GPU_METHOD' $m; Try-C 'LENOVO_GPU_METHOD' $m }
foreach ($m in 'GetSupportThermalMode', 'GetCustomModeAbility') { Try-B 'LENOVO_OTHER_METHOD' $m; Try-A 'LENOVO_OTHER_METHOD' $m @{mode = [uint32]0; Status = [uint32]0} }
'PROBE8_DONE'
