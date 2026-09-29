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
$script:Obj = @{}
foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD', 'LENOVO_CPU_METHOD', 'LENOVO_GPU_METHOD') { $script:Obj[$cn] = Get-Obj $cn }

function Show-Out($tag, $out) {
  if ($null -eq $out) { "  $tag => NULL"; return }
  $parts = foreach ($p in $out.Properties) {
    $v = $p.Value
    if ($v -is [byte[]]) { $v = 'hex[' + (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') + '] dec[' + ($v -join ',') + ']' }
    "$($p.Name)=$v"
  }
  "  $tag => " + ($parts -join '  ')
}
function Call([string]$cn, [string]$m, [hashtable]$in) {
  $cls = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $cn), $null)
  try {
    $ip = $script:Obj[$cn].GetMethodParameters($m)
    if ($null -eq $ip) { $ip = $cls.GetMethodParameters($m) }
    if ($null -eq $ip) { "  $cn.$m => cannot build in-params"; return }
    foreach ($k in $in.Keys) { try { $ip[$k] = $in[$k] } catch { "    set $k failed: $($_.Exception.Message)" } }
    Show-Out "$cn.$m $(($in.GetEnumerator() | ForEach-Object { $v = $_.Value; if ($v -is [byte[]]) { "$($_.Key)=[byte[$($v.Length)]]" } else { "$($_.Key)=$v" } }) -join ',')" ($script:Obj[$cn].InvokeMethod($m, $ip, $null))
  } catch { "  $cn.$m ERR $($_.Exception.Message)" }
}

"`n########## 1) pre-sized OUT buffers for byte[] returns ##########"
foreach ($n in 8, 16, 24, 32, 64) {
  Call 'LENOVO_FAN_METHOD' 'Fan_Get_Table' @{FanID = [byte]1; SensorID = [byte]1; FanTable = (New-Object byte[] $n); FanTableSize = [uint32]$n }
}
"  -- without SensorID --"
Call 'LENOVO_FAN_METHOD' 'Fan_Get_Table' @{FanID = [byte]1; FanTable = (New-Object byte[] 32) }
"  -- MaxSpeed --"
foreach ($n in 8, 16, 32) { Call 'LENOVO_FAN_METHOD' 'Fan_Get_MaxSpeed' @{Fan_ID = [byte]1; FanMaxSpeedTable = (New-Object byte[] $n); FanMaxSpeedSize = [uint32]$n } }

"`n########## 2) COM (WbemScripting) instance dispatch for zero-in methods ##########"
try {
  $locator = New-Object -ComObject WbemScripting.SWbemLocator
  $svc = $locator.ConnectServer('localhost', 'root\wmi')
  try { $svc.Security_.Privileges.Add(20, $true) | Out-Null } catch { }
  foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD') {
    $key = $script:Obj[$cn]['InstanceName']
    $op = "$cn.InstanceName=""$($key.Replace('\', '\\'))"""
    $inst = $svc.Get($op)
    "  instance: $op  -> $($null -ne $inst)"
    foreach ($m in 'GetCPUTemp', 'GetGPUTemp', 'GetSmartFanMode', 'GetFanCount', 'Fan_Get_FullSpeed') {
      try {
        $o = $inst.InvokeMethod($m, $null)
        $parts = @()
        foreach ($p in $o.Properties_) { $parts += "$($p.Name)=$($p.Value)" }
        "    [COM] $cn.$m => $($parts -join '  ')"
      } catch { "    [COM] $cn.$m ERR $($_.Exception.Message)" }
    }
  }
} catch { "  COM init ERR $($_.Exception.Message)" }

"`n########## 3) legacy Invoke-WmiMethod with NO args (zero-in) ##########"
foreach ($t in @(@('LENOVO_GAMEZONE_DATA', 'GetCPUTemp'), @('LENOVO_GAMEZONE_DATA', 'GetSmartFanMode'), @('LENOVO_FAN_METHOD', 'Fan_Get_FullSpeed'))) {
  try {
    $o = Invoke-WmiMethod -Namespace 'root\wmi' -ClassName $t[0] -Name $t[1] -ErrorAction Stop
    "  [WMI] $($t[0]).$($t[1]) => " + (($o | Get-Member -MemberType Properties | ForEach-Object { "$($_.Name)=$($o.($_.Name))" }) -join '  ')
  } catch { "  [WMI] $($t[0]).$($t[1]) ERR $($_.Exception.Message)" }
}

"`n########## 4) GetMethodParameters existence map (which methods have IN params) ##########"
$cn = 'LENOVO_GAMEZONE_DATA'
$cls = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $cn), $null)
foreach ($m in 'GetCPUTemp', 'GetSmartFanMode', 'SetSmartFanMode', 'GetFanCount', 'SetFanCooling', 'GetThermalMode', 'IsSupportSmartFan') {
  $ip1 = $null; try { $ip1 = $script:Obj[$cn].GetMethodParameters($m) } catch { $ip1 = "THROW:$($_.Exception.Message)" }
  $ip2 = $null; try { $ip2 = $cls.GetMethodParameters($m) } catch { $ip2 = "THROW:$($_.Exception.Message)" }
  $f = { param($x) if ($x -is [string]) { $x } elseif ($null -eq $x) { 'NULL' } else { ($x.Properties | ForEach-Object { "$($_.Name):$($_.CimType)" }) -join '/' } }
  "  $m  instance=>$((& $f $ip1))   class=>$((& $f $ip2))"
}
$cn = 'LENOVO_FAN_METHOD'
$cls = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $cn), $null)
foreach ($m in 'Fan_Get_FullSpeed', 'Fan_Set_FullSpeed', 'Fan_Get_Table', 'Fan_Set_Table', 'Fan_Get_MaxSpeed', 'Fan_Set_MaxSpeed', 'Fan_SetCurrentFanSpeed') {
  $ip1 = $null; try { $ip1 = $script:Obj[$cn].GetMethodParameters($m) } catch { $ip1 = "THROW" }
  $ip2 = $null; try { $ip2 = $cls.GetMethodParameters($m) } catch { $ip2 = "THROW" }
  $f = { param($x) if ($x -is [string]) { $x } elseif ($null -eq $x) { 'NULL' } else { ($x.Properties | ForEach-Object { "$($_.Name):$($_.CimType)in=$([bool]$_.Qualifiers['in'])out=$([bool]$_.Qualifiers['out'])" }) -join ' / ' } }
  "  $m  instance=>$((& $f $ip1))"
  "        class=>$((& $f $ip2))"
}
'PROBE9_DONE'
