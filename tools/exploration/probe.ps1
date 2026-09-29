$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

function Section($t) { Write-Host "`n================ $t ================" -ForegroundColor Cyan }

Section "OS"
(Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | ConvertTo-Json -Compress)

Section "CPU / GPU"
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, MaxClockSpeed | Format-List | Out-String
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion | Format-List | Out-String

Section "root\wmi : all classes (name + methods)"
$classes = Get-CimClass -Namespace 'root\wmi'
foreach ($c in $classes) {
  $m = ($c.CimClassMethods | ForEach-Object { $_.Name }) -join ','
  "{0,-42} methods[{1}]: {2}" -f $c.CimClassName, ($c.CimClassMethods | Measure-Object).Count, $m
}

Section "root\wmi : instances present"
foreach ($c in $classes) {
  $inst = Get-CimInstance -Namespace 'root\wmi' -ClassName $c.CimClassName
  $n = ($inst | Measure-Object).Count
  if ($n -gt 0) { "{0,-42} instances={1}" -f $c.CimClassName, $n }
}

Section "root\WMI thermal zones (MSAcpi_ThermalZoneTemperature)"
Get-CimInstance -Namespace 'root\wmi' -ClassName MSAcpi_ThermalZoneTemperature |
  Select-Object InstanceName, CurrentTemperature, ActiveTripPointCount |
  ForEach-Object { "{0,-22} raw={1}  ->  {2} C" -f $_.InstanceName, $_.CurrentTemperature, (($_.CurrentTemperature/10) - 273.15) }

Section "root\cimv2 fan / cooling"
"Win32_Fan:"; Get-CimInstance Win32_Fan | Format-List | Out-String
"Win32_CoolingDevice:"; Get-CimInstance Win32_CoolingDevice | Format-List | Out-String
"Win32_TemperatureProbe:"; Get-CimInstance Win32_TemperatureProbe | Format-List | Out-String
"root\cimv2 Win32_ThermalZone:"; Get-CimInstance root\cimv2 Win32_ThermalZone | Format-List | Out-String
"root\cimv2 Win32_PowerManagement?"

Section "Namespace root\ Lenovo-ish classes"
(Get-CimClass -Namespace 'root' -ClassName '*Lenovo*' | ForEach-Object CimClassName) -join ', '
(Get-CimClass -Namespace 'root' -ClassName '*Legion*' | ForEach-Object CimClassName) -join ', '

Section "Lenovo services / drivers"
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'len|wmi|ring|ntect|ec|io|smu|vantage|legion' } |
  Select-Object Name, State, StartMode, PathName | Format-Table -AutoSize | Out-String -Width 200

Section "Installed Lenovo software"
$paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $paths | Where-Object { $_.DisplayName -match 'Lenovo|Legion|Vantage|Nahimic|IO Driver|Energy Star' } |
  Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName | Format-Table -AutoSize | Out-String -Width 200

Section "ACPI tables present (WMI / EC)"
Get-CimInstance Win32_SystemEnclosure | Select-Object SKU, Manufacturer | Format-List | Out-String

Section "powercfg active scheme + cooling policy"
powercfg /getactivescheme
powercfg /q SCHEME_CURRENT SUB_PROCESSOR SYSCOOLPOL

Section "python libs"
python -c "import sys; print(sys.version)"
python -m pip list 2>$null | Select-String -Pattern 'wmi|win32|psutil|pynvml|comtypes|pywin' | Out-String

Write-Host "`nPROBE_DONE"
