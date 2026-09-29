$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

"=== 1) stop the thrashing daemon ==="
& (Join-Path $PSScriptRoot 'cleanup.ps1')
Start-Sleep -Seconds 2
Connect-FanWmi -Quiet | Out-Null
function Snap([string]$t) {
  $s = Get-FanSnapshot
  "  {0,-24} rpm={1,5} nearCPU={2,3} gpu={3,3} PL1={4,3} PL2={5,3} full={6} mode={7}" -f $t, $s.rpm, $s.near_cpu, $s.gpu_c, $s.pl1, $s.pl2, $s.full, $s.mode
}
Snap 'after kill'

"`n=== 2) cool it down with full speed 20 s ==="
Set-FanFullSpeed -On $true | Out-Null
foreach ($i in 1..5) { Start-Sleep -Seconds 4; Snap "  full +$($i*4)s" }
Set-FanFullSpeed -On $false | Out-Null
Start-Sleep -Seconds 6
Snap 'after fullspeed off'

"`n=== 3) does a single RPM write still track? ==="
foreach ($v in 4500, 5600, 4500) {
  Set-FanTargetRpm -Rpm $v | Out-Null
  Start-Sleep -Seconds 6
  Snap "  wrote $v +6s"
  Start-Sleep -Seconds 6
  Snap "  wrote $v +12s"
}

"`n=== 4) leave it safe + report ==="
Set-FanTargetRpm -Rpm 4500 | Out-Null
Set-FanMode -Mode 3 | Out-Null
Set-FanPowerLimit -Pl1 115 -Pl2 135 | Out-Null
Start-Sleep -Seconds 8
Snap 'final'
"DONE"
