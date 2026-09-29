$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$files = @('src/LenovoFan.psm1', 'src/fanctl.ps1', 'src/daemon.ps1', 'src/panel.ps1', 'src/menu.ps1',
           'install.ps1', 'uninstall.ps1', 'build/build.ps1', 'tools/unit-tests.ps1', 'tools/smoke.ps1',
           'tools/install_test.ps1', 'tools/final_verify.ps1', 'tools/dist_verify.ps1',
           'tools/fix-encoding.ps1', 'tools/elevrun.ps1', 'tools/cleanup.ps1', 'tools/syntax.ps1')
$out = & (Join-Path $root 'tools\syntax.ps1') -Files $files
$out | ForEach-Object { Write-Host $_ }
$fails = @($out | Select-String '^FAIL').Count
"SYNTAX fails=$fails files=$($files.Count)"
if ($fails) { exit 1 } else { exit 0 }
