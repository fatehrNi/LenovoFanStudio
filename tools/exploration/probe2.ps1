$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
function Section($t) { Write-Host "`n================ $t ================" }

Section "root\wmi classes WITH methods"
foreach ($c in (Get-CimClass -Namespace 'root\wmi')) {
  if ($c.CimClassMethods.Count -gt 0 -and $c.CimClassName -notmatch '^(CIM_|MS|Win32_|__|Kernel|Port|MSFT|Processor|Idle|Battery|Wmi|Esif|WiFi|Intel|HDAudio|Lfc)') {
    "### $($c.CimClassName)"
    foreach ($m in $c.CimClassMethods) {
      $p = ($m.Qualifiers['ValueMap'].Value -join '|')
      $pp = ($m.Parameters | ForEach-Object { "$($_.Name):$($_.CimType)" }) -join ', '
      "    - $($m.Name)($pp)  qualifiers=$($m.Qualifiers.Keys -join ',')  ValueMap=$p"
    }
  }
}

Section "GameZone data classes (properties)"
foreach ($c in (Get-CimClass -Namespace 'root\wmi' -ClassName 'LENOVO_GAMEZONE*')) {
  "### $($c.CimClassName)"
  ($c.CimClassProperties | ForEach-Object { "$($_.Name):$($_.CimType)" }) -join '  '
  $inst = Get-CimInstance -Namespace 'root\wmi' -ClassName $c.CimClassName
  "    instances=$(($inst|Measure-Object).Count)"
  if ($inst) { $inst | Select-Object -First 6 | Format-List | Out-String }
}

Section "Win32_Service Lenovo-ish"
Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Lenovo|LFC|GameZone|IOService|Vantage|EnergyManager|hotkeys' } |
  Select-Object Name, State, StartMode, PathName | Format-List | Out-String

Section "Drivers"
Get-CimInstance Win32_SystemDriver | Where-Object { $_.PathName -match 'Lenovo|NTect|io|LFC' -or $_.Name -match 'len|LFC|NTect|WmiAcpi' } |
  Select-Object Name, State, StartMode, PathName | Format-List | Out-String

Section "Thermal zones"
Get-CimInstance -Namespace 'root\wmi' -ClassName MSAcpi_ThermalZoneTemperature |
  ForEach-Object { "{0} raw={1} = {2} C" -f $_.InstanceName, $_.CurrentTemperature, (($_.CurrentTemperature/10)-273.15) }

Section "ACPI WMI devices (Win32_PnPEntity)"
Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'WMI|ACPI|Lenovo|SM Bus|Embedded' } |
  Select-Object Name, DeviceID, Manufacturer, Status | Format-Table -AutoSize | Out-String -Width 160

Write-Host "`nPROBE2_DONE"
