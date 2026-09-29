param([Parameter(Mandatory)][string]$Script, [switch]$NoWait)
# Elevates and runs a script from this repo, capturing its own transcript log.
$ErrorActionPreference = 'Stop'
$full = (Resolve-Path $Script).Path
$argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$full`"")
$p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru -WindowStyle Hidden
if (-not $NoWait) { $p.WaitForExit() }
"started pid=$($p.Id)"
