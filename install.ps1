<#
.SYNOPSIS
  安装：注册开机自启的「风扇守护进程」计划任务（最高权限，无 UAC 弹窗），并创建开始菜单快捷方式
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1              # 安装并立即启动
  powershell -ExecutionPolicy Bypass -File install.ps1 -Profile quiet -Interval 2
  powershell -ExecutionPolicy Bypass -File install.ps1 -NoStart
  powershell -ExecutionPolicy Bypass -File install.ps1 -DesktopShortcut -NoShortcut
#>
[CmdletBinding()]
param(
  [string]$Profile = '',
  [ValidateRange(1, 30)][int]$Interval = 2,
  [string]$TaskName = 'LenovoY9000P-FanDaemon',
  [switch]$NoStart,
  [switch]$WithPanel,
  [switch]$NoShortcut,          # 不创建开始菜单快捷方式
  [switch]$DesktopShortcut      # 同时在桌面创建快捷方式
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = $PSScriptRoot
$src = Join-Path $root 'src'
$appName = 'Legion Fan Studio'

function Find-FanExe {
  <# the tray exe: beside these scripts, else the newest build\build.ps1 output #>
  $c = New-Object System.Collections.ArrayList
  [void]$c.Add((Join-Path $root 'LegionFanStudio.exe'))
  $distDir = Join-Path $root 'dist'
  if (Test-Path -LiteralPath $distDir) {
    Get-ChildItem -LiteralPath $distDir -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'LegionFanStudio-v*' } | Sort-Object LastWriteTime -Descending |
      ForEach-Object { [void]$c.Add((Join-Path $_.FullName 'LegionFanStudio.exe')) }
  }
  foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path } }
  return $null
}
function New-FanShortcut {
  param([string]$Path, [string]$Target, [string]$Icon, [string]$WorkDir, [string]$Desc)
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($Path)
  $sc.TargetPath = $Target
  $sc.WorkingDirectory = $WorkDir
  if ($Icon) { $sc.IconLocation = "$Icon,0" }
  $sc.Description = $Desc
  $sc.Save()
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限来注册计划任务，正在提升……' -ForegroundColor Yellow
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Interval $Interval -TaskName `"$TaskName`""
  if ($Profile) { $a += " -Profile `"$Profile`"" }
  if ($NoStart) { $a += ' -NoStart' }
  if ($WithPanel) { $a += ' -WithPanel' }
  if ($NoShortcut) { $a += ' -NoShortcut' }
  if ($DesktopShortcut) { $a += ' -DesktopShortcut' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a
  exit 0
}

Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking
Write-Host "== Y9000P 风扇管理系统 · 安装 ==" -ForegroundColor Cyan

# 1) EC reachability check (fail fast, before touching the scheduler)
try { $info = Connect-FanWmi -Quiet; Write-Host "  EC 接口: $info" -ForegroundColor Green }
catch { throw "无法访问风扇 EC 接口：$($_.Exception.Message)`n  （请确认机型为拯救者 Y9000P 2022 / 82RF，且已用管理员运行）" }
$s = Get-FanSnapshot
if (-not $s.ok) { throw "读取 EC 失败：$($s.err)" }
Write-Host ("  当前: 档位 {0}  转速 {1} RPM  近CPU {2}°C  GPU {3}°C  PL1 {4}W" -f $s.mode_name, $s.rpm, $s.near_cpu, $s.gpu_c, $s.pl1)

# 2) config
if (-not (Test-Path -LiteralPath $ConfigFile)) { Save-FanConfig -Config (New-DefaultConfig) }
if ($Profile) {
  $cfg = Get-FanConfig
  if (-not $cfg.profiles.PSObject.Properties[$Profile]) { throw "未知档位 '$Profile'" }
  $cfg.active_profile = $Profile
  Save-FanConfig -Config $cfg -Why 'install'
}

# 3) scheduled task: at logon, highest privileges, never exit
$ps = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$dArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$src\daemon.ps1`" -Interval $Interval"
if ($Profile) { $dArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$src\daemon.ps1`" -Profile `"$Profile`" -Interval $Interval" }
$action = New-ScheduledTaskAction -Execute $ps -Argument $dArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -StartWhenAvailable -Priority 6
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
  Set-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
  Write-Host "  计划任务已更新: $TaskName" -ForegroundColor Green
} else {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description '拯救者 Y9000P 2022 风扇曲线闭环控制（EC 直控，绕过 Windows 电源计划）' | Out-Null
  Write-Host "  计划任务已创建: $TaskName" -ForegroundColor Green
}
Write-Host "  触发: 登录时   权限: 最高（无 UAC 弹窗）   刷新间隔: ${Interval}s"

# 4) start now
if (-not $NoStart) {
  Start-ScheduledTask -TaskName $TaskName
  Write-Host '  已启动守护进程，等待首轮数据……' -ForegroundColor Cyan
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $st = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $lk = Get-FanLockState
    if ($lk -and $lk.alive) { Write-Host "  守护进程运行中 (pid=$($lk.pid))" -ForegroundColor Green; break }
  }
  if (-not ((Get-FanLockState).alive)) { Write-Host '  未能在 20 秒内确认运行，请查看 logs\fan.log' -ForegroundColor Yellow }
}

if ($WithPanel) {
  Start-Process -FilePath $ps -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$src\panel.ps1`"" | Out-Null
  Write-Host '  面板已启动' -ForegroundColor Green
}

# 5) shortcuts: the tray app has no window, so without a named entry people look for
#    an exe that is actually inside dist\LegionFanStudio-vX.Y.Z\
if (-not $NoShortcut) {
  try {
    $exe = Find-FanExe
    if (-not $exe) {
      Write-Host '  没找到 LegionFanStudio.exe（托盘程序）：先跑 build\build.ps1，再重新运行 install.ps1' -ForegroundColor Yellow
    } else {
      $ico = Join-Path (Split-Path -Parent $exe) 'assets\app.ico'
      if (-not (Test-Path -LiteralPath $ico)) { $ico = $exe }
      $wd = Split-Path -Parent $exe
      $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) ($appName + '.lnk')
      New-FanShortcut -Path $lnk -Target $exe -Icon $ico -WorkDir $wd -Desc '拯救者风扇管理托盘程序（EC 直控）'
      Write-Host "  开始菜单已创建: $appName（搜索「Legion」即可启动）" -ForegroundColor Green
      if ($DesktopShortcut) {
        $dlnk = Join-Path ([Environment]::GetFolderPath('Desktop')) ($appName + '.lnk')
        New-FanShortcut -Path $dlnk -Target $exe -Icon $ico -WorkDir $wd -Desc '拯救者风扇管理托盘程序（EC 直控）'
        Write-Host "  桌面已创建: $dlnk" -ForegroundColor Green
      }
    }
  } catch { Write-Host "  快捷方式创建失败（不影响功能）: $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host @"

完成。常用命令：
  托盘程序  开始菜单搜「Legion Fan Studio」，或 dist\LegionFanStudio-vX.Y.Z\LegionFanStudio.cmd
  面板      双击 风扇面板.cmd   或  src\fanctl.ps1 panel
  看状态    src\fanctl.ps1 status
  换档位    src\fanctl.ps1 profile quiet|balanced|performance|max|custom
  临时满速  src\fanctl.ps1 boost 20
  功耗墙    src\fanctl.ps1 limit 125 145
  停止      uninstall.ps1 或  src\fanctl.ps1 daemon stop
卸载        powershell -ExecutionPolicy Bypass -File uninstall.ps1
"@ -ForegroundColor Cyan
