$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Management
$log = 'E:\vibecoding\qoder\fans\logs\probe5.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
"elevated=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

function Dump($label) {
  Write-Host "`n--- $label"
  foreach ($p in $args) { }
}

"=== A) class qualifiers / provider ==="
foreach ($cn in 'LENOVO_FAN_METHOD','LENOVO_GAMEZONE_DATA','LENOVO_OTHER_METHOD') {
  Write-Host "`n### $cn"
  $cc = Get-CimClass -Namespace 'root\wmi' -ClassName $cn
  foreach ($q in $cc.CimClassQualifiers) { "    {0} = {1}" -f $q.Name, (($q.Value | Out-String).Trim() -replace "`r?`n", ' | ') }
}

"=== B) instances (elevated) ==="
foreach ($cn in 'LENOVO_FAN_METHOD','LENOVO_GAMEZONE_DATA','LENOVO_UTILITY_DATA') {
  Write-Host "`n### $cn"
  try {
    $inst = @(Get-CimInstance -Namespace 'root\wmi' -ClassName $cn -ErrorAction Stop)
    "    count=$($inst.Count)"
    $inst | Select-Object -First 3 | ForEach-Object { "    " + ($_ | ConvertTo-Json -Compress -Depth 3) }
  } catch { "    ERR: $($_.Exception.Message)" }
  try {
    $mo = @(Get-WmiObject -Namespace 'root\wmi' -Class $cn -ErrorAction Stop)
    "    (legacy) count=$($mo.Count) path=$(($mo | Select-Object -First 1 | ForEach-Object { $_.__PATH }))"
  } catch { "    (legacy) ERR: $($_.Exception.Message)" }
}

$FM = 'LENOVO_FAN_METHOD'
"=== C) strategy tests on Fan_GetCurrentFanSpeed(FanID=1) ==="

Write-Host "`n# C1 instance-level System.Management"
try {
  $scope = New-Object System.Management.ManagementScope 'root\wmi'
  $scope.Options.EnablePrivileges = $true
  $scope.Connect()
  $searcher = New-Object System.Management.ManagementObjectSearcher($scope, (New-Object System.Management.ObjectQuery "SELECT * FROM $FM"))
  $coll = $searcher.Get()
  "    found=$($coll.Count)"
  foreach ($o in $coll) {
    "    path=$($o.Path.Path)"
    $in = $o.GetMethodParameters('Fan_GetCurrentFanSpeed')
    "    inprops=$(($in.Properties | ForEach-Object { "$($_.Name):$($_.CimType)" }) -join ' ')"
    $in['FanID'] = [byte]1
    $out = $o.InvokeMethod('Fan_GetCurrentFanSpeed', $in, $null)
    "    OUT: " + (($out.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
  }
} catch { "    ERR: $($_.Exception.Message)" }

Write-Host "`n# C2 class-level with explicit in-props printed"
try {
  $scope = New-Object System.Management.ManagementScope 'root\wmi'
  $scope.Options.EnablePrivileges = $true
  $scope.Connect()
  $cls = New-Object System.Management.ManagementClass($scope, (New-Object System.Management.ManagementPath $FM), $null)
  $m = $cls.Methods['Fan_GetCurrentFanSpeed']
  "    method qualifiers: " + (($m.Qualifiers | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
  $in = $cls.GetMethodParameters('Fan_GetCurrentFanSpeed')
  "    in-params: " + (($in.Properties | ForEach-Object { "$($_.Name):$($_.CimType) in=$($_.Qualifiers['In']) out=$($_.Qualifiers['Out'])" }) -join ' | ')
} catch { "    ERR: $($_.Exception.Message)" }

Write-Host "`n# C3 Invoke-WmiMethod (legacy cmdlet, class)"
try { Invoke-WmiMethod -Namespace 'root\wmi' -Class $FM -Name 'Fan_GetCurrentFanSpeed' -ArgumentList @([byte]1) | ForEach-Object { $_ | Get-Member -MemberType Properties | ForEach-Object { "    $($_.Name)=$($_.Value)" } } } catch { "    ERR: $($_.Exception.Message)" }
Write-Host "`n# C4 Invoke-WmiMethod (legacy cmdlet, named args)"
try { Invoke-WmiMethod -Namespace 'root\wmi' -Class $FM -Name 'Fan_GetCurrentFanSpeed' -Arguments @{FanID=[byte]1} } catch { "    ERR: $($_.Exception.Message)" }
Write-Host "`n# C5 Invoke-CimMethod piped from instance"
try { Get-CimInstance -Namespace 'root\wmi' -ClassName $FM | Invoke-CimMethod -MethodName 'Fan_GetCurrentFanSpeed' -Arguments @{FanID=[byte]1} } catch { "    ERR: $($_.Exception.Message)" }
Write-Host "`n# C6 Invoke-CimMethod class-level elevated"
try { Invoke-CimMethod -Namespace 'root\wmi' -ClassName $FM -MethodName 'Fan_GetCurrentFanSpeed' -Arguments @{FanID=[byte]1} } catch { "    ERR: $($_.Exception.Message)" }
Write-Host "`n# C7 raw WMI Service COM (WbemScripting.SWbemServices.ExecMethod on class path)"
try {
  $svc = New-Object -ComObject WbemScripting.SWbemLocator
  $s = $svc.ConnectServer('.', 'root\wmi')
  try { $s.Security_.Privileges.Add(20, $true) } catch {}
  $o = $s.Get('LENOVO_FAN_METHOD')
  $inParams = $o.Methods_.Item('Fan_GetCurrentFanSpeed').InParameters.SpawnInstance_()
  $inParams.FanID = 1
  $outParams = $s.ExecMethod('LENOVO_FAN_METHOD', 'Fan_GetCurrentFanSpeed', $inParams)
  "    OUT: " + (($outParams.Properties_ | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
} catch { "    ERR: $($_.Exception.Message)" }

Write-Host "`n# C8 python wmi module availability"
python -c "import wmi, sys; print('wmi OK', wmi.__file__)" 2>&1 | ForEach-Object { "    $_" }
python -c "import win32api; print('pywin32 OK')" 2>&1 | ForEach-Object { "    $_" }

Stop-Transcript | Out-Null
"PROBE5_DONE"
