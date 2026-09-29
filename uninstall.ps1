<#
.SYNOPSIS
  卸载：停止并删除风扇守护计划任务，把转速写回安全默认值
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File uninstall.ps1            # 卸载（保留日志/配置）
  powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Purge     # 连日志和配置一起删
#>
[CmdletBinding()]
param(
  [string]$TaskName = 'LenovoY9000P-FanDaemon',
  [switch]$Purge,
  [switch]$KeepShortcuts
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = $PSScriptRoot
$src = Join-Path $root 'src'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限，正在提升……' -ForegroundColor Yellow
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TaskName `"$TaskName`""
  if ($Purge) { $a += ' -Purge' }
  if ($KeepShortcuts) { $a += ' -KeepShortcuts' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a
  exit 0
}
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking
Write-Host '== 卸载 ==' -ForegroundColor Cyan

# 1) ask the daemon to stop cleanly (it writes back exit_rpm on the way out)
$lk = Get-FanLockState
if ($lk -and $lk.alive) {
  $cmdFile = Join-Path $StateDir 'cmd.json'
  [pscustomobject]@{ id = Get-Random -Maximum 999999; type = 'stop'; args = @{} } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $cmdFile -Encoding UTF8
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline -and (Get-FanLockState).alive) { Start-Sleep -Milliseconds 400 }
  $lk2 = Get-FanLockState
  if ($lk2 -and $lk2.alive) {
    Write-Host '  守护进程未能干净退出，强制结束' -ForegroundColor Yellow
    Stop-Process -Id $lk2.pid -Force -ErrorAction SilentlyContinue
    # make sure the fans are not left somewhere silly
    try { Connect-FanWmi -Quiet | Out-Null; Set-FanTargetRpm -Rpm 4500 -SkipSafety | Out-Null } catch { }
  }
  Write-Host '  守护进程已停止' -ForegroundColor Green
} else { Write-Host '  守护进程未在运行' }

# 2) task
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "  计划任务已删除: $TaskName" -ForegroundColor Green
} else { Write-Host "  没有找到计划任务 $TaskName" }

# 3) leave EC in a normal state
try {
  Connect-FanWmi -Quiet | Out-Null
  Reset-FanNormal | Out-Null
  Write-Host '  已把转速/档位/满速锁恢复为正常值' -ForegroundColor Green
} catch { Write-Host "  恢复失败（可重启电脑交还 BIOS）: $($_.Exception.Message)" -ForegroundColor Yellow }

if (-not $KeepShortcuts) {
  # remove only shortcuts that actually point at our exe
  $ws = New-Object -ComObject WScript.Shell
  foreach ($f in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
    $lnk = Join-Path $f 'Legion Fan Studio.lnk'
    if (-not (Test-Path -LiteralPath $lnk)) { continue }
    try {
      $target = $ws.CreateShortcut($lnk).TargetPath
      if ("$target" -match 'LegionFanStudio\.exe$') {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "  已删除快捷方式: $lnk"
      } else { Write-Host "  保留 $lnk（它指向别的目标: $target）" }
    } catch { Write-Host "  快捷方式删除失败: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
}

if ($Purge) {
  foreach ($d in @((Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'config'))) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Write-Host "  已删除 $d" }
  }
}
Write-Host "`n提示：EC 会保持最后一次命令的转速，彻底交还给 BIOS 自动策略请重启电脑。" -ForegroundColor Cyan
'UNINSTALL_DONE'
