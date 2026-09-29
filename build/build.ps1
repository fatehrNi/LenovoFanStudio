<#
.SYNOPSIS
  构建 Legion Fan Studio：编译原生托盘 exe -> 组装可移植目录 -> 打 zip
.DESCRIPTION
  只用 Windows 自带的 .NET Framework csc.exe，产物是单个 exe + PowerShell 引擎目录，
  终端用户无需安装 .NET / Node / Python。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build\build.ps1
  powershell -ExecutionPolicy Bypass -File build\build.ps1 -Version 1.1.0 -SkipIcon
#>
[CmdletBinding()]
param(
  [string]$Version = '',
  [switch]$SkipIcon,
  [switch]$NoZip,
  [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir = Join-Path $root 'build'
$distRoot = Join-Path $root 'dist'

function Info($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Head($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

# ---------------------------------------------------------------- version
$versionFile = Join-Path $root 'VERSION'
if (-not $Version) {
  if (Test-Path -LiteralPath $versionFile) { $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim() }
  else { $Version = '1.0.0' }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "版本号格式应为 1.2.3，收到 '$Version'" }
$verParts = $Version.Split('.')

Head "构建 Legion Fan Studio v$Version ($Configuration)"
Info "仓库: $root"

# ---------------------------------------------------------------- toolchain
$psExePath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cscDir = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$csc = Join-Path $cscDir 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
  $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $csc)) { throw "找不到 csc.exe（.NET Framework 4.x 未安装？）" }
Info "编译器: $csc"

# ---------------------------------------------------------------- icon
$ico = Join-Path $root 'app\app.ico'
if (-not $SkipIcon -or -not (Test-Path -LiteralPath $ico)) {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) {
    & $py.Source (Join-Path $buildDir 'make_icon.py') $ico | ForEach-Object { Info $_ }
  } elseif (-not (Test-Path -LiteralPath $ico)) {
    Write-Warning '没有 python，且 app.ico 不存在：将使用默认图标'
  }
}

# ---------------------------------------------------------------- assembly info
$tmp = Join-Path $buildDir 'obj'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$asmInfo = Join-Path $tmp 'AssemblyInfo.cs'
$copyright = "Copyright © 2026 Legion Fan Studio contributors"
@"
using System.Reflection;
using System.Runtime.InteropServices;
[assembly: AssemblyTitle("Legion Fan Studio")]
[assembly: AssemblyProduct("Legion Fan Studio")]
[assembly: AssemblyDescription("Lenovo Legion Y9000P fan / power-limit manager (unofficial)")]
[assembly: AssemblyCompany("Legion Fan Studio")]
[assembly: AssemblyCopyright("$copyright")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: ComVisible(false)]
"@ | Set-Content -LiteralPath $asmInfo -Encoding UTF8

# ---------------------------------------------------------------- compile
$exeName = 'LegionFanStudio.exe'
$outExe = Join-Path $tmp $exeName
$cscArgs = @(
  '-nologo', '-target:winexe', '-optimize+', "-out:$outExe",
  '-r:System.dll', '-r:System.Core.dll', '-r:System.Drawing.dll', '-r:System.Windows.Forms.dll', '-r:System.Web.Extensions.dll',
  '-debug:pdbonly', '-platform:anycpu', '-warn:1', '-nowarn:1591', '-utf8output'
)
if (Test-Path -LiteralPath $ico) { $cscArgs += "-win32icon:$ico" }
$cscArgs += (Join-Path $root 'app\LegionFanStudio.cs')
$cscArgs += $asmInfo

Info "编译中…"
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path -LiteralPath $outExe)) { throw 'csc 没产出 exe' }
$ver = (Get-Item $outExe).VersionInfo
Info ("产物: {0}  {1}  ({2:N0} KB)" -f $exeName, $ver.FileVersion, ((Get-Item $outExe).Length / 1KB))

# ---------------------------------------------------------------- assemble dist
$appName = "LegionFanStudio-v$Version"
$stage = Join-Path $distRoot $appName
Head "组装可移植目录 $appName"
if (Test-Path -LiteralPath $stage) {
  # A shell whose cwd is inside dist, or a still-running tray instance, locks the
  # directory. Clear what we can and say exactly what to fix if we cannot.
  try {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
  } catch {
    Get-ChildItem -LiteralPath $stage -Force | ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
    if (Test-Path -LiteralPath (Join-Path $stage 'LegionFanStudio.exe')) {
      throw "无法清空 $stage —— 请先关闭正在运行的 LegionFanStudio.exe，并把终端目录移出 dist\"
    }
    Write-Warning "$stage 未能完全删除（被占用），已在现有内容上重建"
  }
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src\www') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'assets') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'docs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'tools') | Out-Null

Copy-Item $outExe (Join-Path $stage $exeName) -Force
Copy-Item (Join-Path $tmp 'LegionFanStudio.pdb') (Join-Path $stage 'LegionFanStudio.pdb') -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $ico) { Copy-Item $ico (Join-Path $stage 'assets\app.ico') -Force }

# engine + panel + docs
Copy-Item (Join-Path $root 'src\*.ps1') (Join-Path $stage 'src') -Force
Copy-Item (Join-Path $root 'src\*.psm1') (Join-Path $stage 'src') -Force
Copy-Item (Join-Path $root 'src\*.txt') (Join-Path $stage 'src') -Force
Copy-Item (Join-Path $root 'src\www\*') (Join-Path $stage 'src\www') -Force -Recurse
Copy-Item (Join-Path $root 'install.ps1') $stage -Force
Copy-Item (Join-Path $root 'uninstall.ps1') $stage -Force
Copy-Item (Join-Path $root 'README.md') $stage -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'LICENSE') $stage -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'CHANGELOG.md') $stage -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'CONTRIBUTING.md') $stage -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'docs\*.md') (Join-Path $stage 'docs') -Force -ErrorAction SilentlyContinue
$Version | Set-Content -LiteralPath (Join-Path $stage 'VERSION') -Encoding ASCII
foreach ($t in 'unit-tests.ps1', 'smoke.ps1', 'syntax.ps1', 'fix-encoding.ps1') {
  if (Test-Path -LiteralPath (Join-Path $root "tools\$t")) { Copy-Item (Join-Path $root "tools\$t") (Join-Path $stage 'tools') -Force }
}

# launchers (ASCII only so they survive any codepage)
@'
@echo off
rem Launch the tray app (fans keep their last EC value until you start the daemon)
start "" "%~dp0LegionFanStudio.exe"
'@ | Set-Content -LiteralPath (Join-Path $stage 'LegionFanStudio.cmd') -Encoding ASCII
@'
@echo off
rem Environment self-check, does not touch the fans
"%~dp0LegionFanStudio.exe" --selftest
echo.
pause
'@ | Set-Content -LiteralPath (Join-Path $stage 'selftest.cmd') -Encoding ASCII
@'
@echo off
rem Command line tool: status / profile / set / boost / limit / curve / daemon / panel / test / diag
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\fanctl.ps1" %*
'@ | Set-Content -LiteralPath (Join-Path $stage 'fanctl.cmd') -Encoding ASCII

# Chinese-named launchers: the two actions a first-time user actually needs.
# Content stays pure ASCII (cmd.exe cannot handle a BOM on line 1, and chcp 65001
# would mangle the Chinese output PowerShell writes with the OEM codepage).
@'
@echo off
rem Start the fan daemon - the single EC writer (asks for admin once)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\fanctl.ps1" daemon start
pause
'@ | Set-Content -LiteralPath (Join-Path $stage '启动守护进程.cmd') -Encoding ASCII
@'
@echo off
rem Restore normal fan values: release full-speed, re-apply Fn+Q, write a safe RPM
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\fanctl.ps1" reset
pause
'@ | Set-Content -LiteralPath (Join-Path $stage '恢复正常.cmd') -Encoding ASCII

# Ship PRISTINE defaults, not the dev copy (test runs mutate config\config.json).
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'config') | Out-Null
Import-Module (Join-Path $root 'src\LenovoFan.psm1') -Force -DisableNameChecking
$cfgJson = New-DefaultConfig | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText((Join-Path $stage 'config\config.json'), $cfgJson, (New-Object Text.UTF8Encoding $false))
Info "shipped pristine config.json ($([int]($cfgJson.Length / 1KB)) KB)"

$shipped = Get-ChildItem -LiteralPath $stage -Recurse -File
Info ("文件 {0} 个，合计 {1:N0} KB" -f $shipped.Count, (($shipped | Measure-Object Length -Sum).Sum / 1KB))

# Mirror the exe beside the scripts on this machine, so the Start-Menu/Desktop shortcut and
# the running daemon share ONE data root (an exe inside dist\ has its own config/logs/state
# and would report "no daemon" while the repo daemon is the one actually driving the fans).
try {
  Copy-Item -LiteralPath (Join-Path $stage 'LegionFanStudio.exe') -Destination (Join-Path $root 'LegionFanStudio.exe') -Force
  $icoSrc = Join-Path $stage 'assets\app.ico'
  if (Test-Path -LiteralPath $icoSrc) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'assets') | Out-Null
    Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $root 'assets\app.ico') -Force
  }
  Info "本机托盘程序已更新: $(Join-Path $root 'LegionFanStudio.exe')（开始菜单/桌面快捷方式指向这里）"
} catch { Warn "根目录托盘程序更新失败（不影响 dist 产物）: $($_.Exception.Message)" }

# ---------------------------------------------------------------- smoke the build
Head '构建后自检（不改动风扇）'
$srv = $null
try {
  $out = & (Join-Path $stage $exeName) --selftest 2>&1 | Out-String
  Info ('exit=' + $LASTEXITCODE)
  ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 30) | ForEach-Object { Info "  $_" }
  if ($LASTEXITCODE -ne 0) { throw "selftest 失败（退出码 $LASTEXITCODE）" }
} catch {
  Write-Warning "selftest 未能通过：$($_.Exception.Message)"
  Write-Warning '继续产出，但请手动检查。'
}

# ---------------------------------------------------------------- zip
if (-not $NoZip) {
  Head '打包 zip'
  $zip = Join-Path $distRoot "$appName.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
  $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
  Info ("{0}  ({1:N0} KB)" -f $zip, ((Get-Item $zip).Length / 1KB))
  Info "SHA256 $sha"
  $sha | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
}

Write-Host "`n完成。发布目录：$stage" -ForegroundColor Green
Write-Host "试用：双击 LegionFanStudio.cmd（或运行 selftest.cmd 自检）" -ForegroundColor Green
