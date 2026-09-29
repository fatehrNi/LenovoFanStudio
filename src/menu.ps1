<#
.SYNOPSIS
  中文交互菜单（双击 风扇控制.cmd 即可，不需要记命令）
#>
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$src = Split-Path -Parent $PSCommandPath
$fanctl = Join-Path $src 'fanctl.ps1'

function Run([string[]]$args2) {
  Write-Host ''
  & $fanctl @args2
  Write-Host ''
  Read-Host '  按回车返回菜单' | Out-Null
}
function Pick([string]$prompt, [hashtable]$map) {
  Write-Host ''
  Write-Host "  $prompt" -ForegroundColor Cyan
  foreach ($k in $map.Keys | Sort-Object) { "   [$k] $($map[$k].Text)" }
  Write-Host '   [0] 返回'
  $c = (Read-Host '  请选择').Trim()
  return $c
}

while ($true) {
  Clear-Host
  Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor DarkCyan
  Write-Host '   拯救者 Y9000P 2022 · 风扇转速控制中心   (EC 直控)' -ForegroundColor Cyan
  Write-Host '  ══════════════════════════════════════════════════' -ForegroundColor DarkCyan
  $s = & $fanctl status 2>&1
  $s | ForEach-Object { "  $_" }
  Write-Host ''
  Write-Host '   [1] 切换档位（安静/均衡/野兽/满速/自定义）'
  Write-Host '   [2] 手动指定转速（带自动恢复倒计时）'
  Write-Host '   [3] 满速冲刺（默认 20 秒后自动解除）'
  Write-Host '   [4] CPU 功耗墙 PL1/PL2（真正越过电源计划）'
  Write-Host '   [5] 查看 / 编辑风扇曲线'
  Write-Host '   [6] 守护进程 start / stop / status'
  Write-Host '   [7] 打开可视化面板'
  Write-Host '   [8] 实时监视（Ctrl+C 退出）'
  Write-Host '   [9] 端到端自检（只升不降，自动恢复）'
  Write-Host '   [r] 一键恢复正常值      [d] 诊断信息      [q] 退出'
  $c = (Read-Host '  请选择').Trim().ToLower()
  switch ($c) {
    '1' { $p = Read-Host '  档位 quiet/balanced/performance/max/custom' ; Run @('profile', $p) }
    '2' {
      $v = Read-Host '  目标转速 RPM（如 5200）'
      $sec = Read-Host '  持续秒数（回车 = 30，0 = 一直保持）'
      if (-not $sec) { $sec = 30 }
      Run @('set', $v, '-Seconds', $sec)
    }
    '3' { $sec = Read-Host '  满速秒数（回车 = 20）' ; if (-not $sec) { $sec = 20 } ; Run @('boost', $sec) }
    '4' {
      $p1 = Read-Host '  PL1 (W)，回车只看当前值'
      if ($p1) { $p2 = Read-Host '  PL2 (W)' ; Run @('limit', $p1, $p2) } else { Run @('limit') }
    }
    '5' {
      Run @('curve', 'show')
      if ((Read-Host '  要编辑曲线吗？y/n').Trim() -eq 'y') {
        $prof = Read-Host '  档位（建议 custom）'
        $which = Read-Host '  cpu / gpu'
        Write-Host '  输入 8 个点，形如  66:3600,70:4200,...,94:6600'
        $spec = Read-Host '  曲线'
        Run @('curve', 'set', $prof, $which, $spec)
      }
    }
    '6' { Run @('daemon', (Read-Host '  start / stop / status')) }
    '7' { & $fanctl panel | Out-Host ; Start-Sleep -Seconds 3 }
    '8' { & $fanctl watch ; Read-Host '  按回车返回' | Out-Null }
    '9' { Run @('test') }
    'r' { Run @('reset') }
    'd' { Run @('diag') }
    'q' { Write-Host '  再见 👋' -ForegroundColor Green ; exit 0 }
  }
}
