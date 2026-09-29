<#
.SYNOPSIS
  联想拯救者 Y9000P 2022 · 风扇转速管理命令行（EC 层，绕过 Windows 电源计划）
.DESCRIPTION
  读写固件 WMI 接口 root\wmi\LENOVO_FAN_METHOD + Lfc_thermal_interface。
  与电源计划无关：Windows 的"系统散热方式/最大处理器状态"不参与风扇控制，
  本工具直接命令 EC 的目标转速，并可在 EC 层覆盖 CPU 功耗墙 PL1/PL2。
.EXAMPLE
  fanctl.ps1 status                    # 当前温度/转速/档位
  fanctl.ps1 daemon start              # 启动曲线闭环守护（会请求管理员）
  fanctl.ps1 profile quiet             # 切到安静档
  fanctl.ps1 set 5500 -Seconds 30      # 手动 5500 RPM，30 秒后交还曲线
  fanctl.ps1 boost 20                  # 满速 20 秒后自动解除
  fanctl.ps1 limit 125 145             # EC 层功耗墙（覆盖电源计划）
  fanctl.ps1 panel                     # 打开可视化调参面板
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$src = Split-Path -Parent $PSCommandPath
$env:PSModulePath = "$src$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

function ArgAt([object[]]$r, [int]$i) { if ($r.Count -gt $i) { "$($r[$i])" } else { $null } }
function FlagVal([object[]]$r, [string]$name, [string]$def = '') {
  for ($i = 0; $i -lt $r.Count; $i++) {
    if ("$($r[$i])" -eq $name -and $i + 1 -lt $r.Count) { return "$($r[$i + 1])" }
    if ("$($r[$i])" -like "$name=*") { return ("$($r[$i])").Split('=', 2)[1] }
  }
  return $def
}
function HasFlag([object[]]$r, [string]$name) { @($r | Where-Object { "$_" -eq $name }).Count -gt 0 }
function IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Send-FanCmd {
  <# route a control request to the running daemon (it is the single EC writer) #>
  param([string]$Type, [hashtable]$ArgH = @{})
  $f = Join-Path $StateDir 'cmd.json'
  $id = [int](Get-Random -Maximum 999999)
  [pscustomobject]@{ id = $id; type = $Type; args = $ArgH; at = (Get-Date -Format 'o') } |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath "$f.tmp" -Encoding UTF8
  Move-Item -LiteralPath "$f.tmp" -Destination $f -Force
  Write-Host "已投递命令给守护进程：$Type $($ArgH | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Green
  $deadline = (Get-Date).AddSeconds(8)
  while ((Test-Path -LiteralPath $f) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  if (Test-Path -LiteralPath $f) { Write-Host '守护进程 8 秒内未消费该命令（可能未运行）' -ForegroundColor Yellow }
}
function Require-AdminOrDaemon {
  $lk = Get-FanLockState
  if ($lk -and $lk.alive) { return $lk }          # daemon will do the writing
  if (IsAdmin) { return $null }
  Write-Host '需要管理员权限，正在提升……' -ForegroundColor Yellow
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Command"
  foreach ($r in $Rest) { if ($r) { $a += " `"$r`"" } }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a
  exit 0
}
function Show-SnapshotTable($s) {
  if (-not $s.ok) { Write-Host "读取失败: $($s.err)" -ForegroundColor Red; return }
  $bar = { param($v, $max) ('█' * [int][math]::Max(0, [math]::Min(30, ($v / $max) * 30))) }
  "  时间        : $($s.time)"
  "  Fn+Q 档位   : $($s.mode_name)"
  "  满速锁定    : $(if ($s.full) { 'ON' } else { 'off' })"
  "  CPU 风扇    : {0,5} RPM {1}" -f $s.rpm, (& $bar $s.rpm 6600)
  "  近 CPU 温度 : {0,3} °C   (Tj 上限参考 {1} °C)" -f $s.near_cpu, $s.tj
  "  GPU 温度    : {0,3} °C   (近 GPU {1} °C)" -f $s.gpu_c, $s.near_gpu
  "  内存/环境   : {0,3} °C / {1,3} °C" -f $s.ram_c, $s.env_c
  "  功耗墙      : PL1={0}W PL2={1}W   CPU 占用 {2}%" -f $s.pl1, $s.pl2, $s.cpu_util
}

# ------------------------------------------------------------------ commands
function Cmd-Status([object[]]$r) {
  $s = Get-FanSnapshot
  if (HasFlag $r '-Json') { return ($s | ConvertTo-Json -Depth 5) }
  $lk = Get-FanLockState
  if ($lk -and $lk.alive) { "  守护进程: 运行中 (pid=$($lk.pid), $($lk.who))" } else { '  守护进程: 未运行（转速由 BIOS 自动档控制，除非手动写过）' }
  $other = Get-FanOtherCopyLock
  if ($other -and -not ($lk -and $lk.alive)) {
    Write-Host "  ! 另一份安装在托管: $($other.who) pid=$($other.pid) 数据目录 $($other.root)" -ForegroundColor Yellow
    Write-Host '    同一台机器只能有一个 EC 写入者；要改用本份，请先在那份里 stop。' -ForegroundColor Yellow
  }
  Show-SnapshotTable $s
  if ($s.ok) {
    $cfg = Get-FanConfig
    $d = Get-FanDesiredRpm -Snap $s
    "  曲线目标    : {0} RPM  ← 档位 {1}（依据 {2}，CPU基准 {3}°C / GPU {4}°C）" -f $d.rpm, $d.profile, $d.why, $d.cpu_temp_basis, $d.gpu_temp
    foreach ($m in @(Get-FanCurveIssue -Config $cfg)) { Write-Host "  ! $m" -ForegroundColor Yellow }
  }
}

function Cmd-Watch([object[]]$r) {
  $iv = [double](FlagVal $r '-Interval' '2')
  $cfg = Get-FanConfig
  $hist = New-Object 'System.Collections.Generic.Queue[object]'
  Write-Host "每 $iv 秒刷新（Ctrl+C 退出）" -ForegroundColor Cyan
  while ($true) {
    $s = Get-FanSnapshot
    if ($s.ok) {
      $d = Get-FanDesiredRpm -Snap $s
      if ($hist.Count -ge 24) { $hist.Dequeue() | Out-Null }
      $hist.Enqueue([pscustomobject]@{ t = $s.time.Substring(11); rpm = $s.rpm; tgt = $d.rpm; cpu = $s.near_cpu; gpu = $s.gpu_c; pl1 = $s.pl1 })
      Clear-Host
      Show-SnapshotTable $s
      ''
      '  时间     转速   目标   近CPU   GPU   PL1'
      foreach ($h in $hist) { '  {0}  {1,5}  {2,5}  {3,4}C  {4,3}C  {5,3}W' -f $h.t, $h.rpm, $h.tgt, $h.cpu, $h.gpu, $h.pl1 }
      "  (Ctrl+C 退出；当前档位 $($cfg.active_profile))"
    } else { Write-Host "  读取失败: $($s.err)" -ForegroundColor Red }
    Start-Sleep -Seconds $iv
  }
}

function Cmd-Mode([object[]]$r) {
  $v = ArgAt $r 0
  if (-not $v) { "  当前 Fn+Q 档位: $(Get-FanMode) ($($ModeNames[[int](Get-FanMode)]))"; return }
  if ((Require-AdminOrDaemon)) { Send-FanCmd 'mode' @{ mode = [int]$v }; return }
  $back = Set-FanMode -Mode ([int]$v)
  "  设置后读回: $back ($($ModeNames[[int]$back]))"
}

function Cmd-Profile([object[]]$r) {
  $name = ArgAt $r 0
  $cfg = Get-FanConfig
  if (-not $name -or $name -in 'list', 'ls') {
    '  可用档位（config\config.json → profiles）:'
    foreach ($p in $cfg.profiles.PSObject.Properties) {
      $v = $p.Value
      $mark = if ("$($cfg.active_profile)" -eq $p.Name) { '*' } else { ' ' }
      "   {0} {1,-12} {2,-6} 上限 {3,4} RPM  模式 {4}" -f $mark, $p.Name, $v.label, $v.ceiling, $v.mode
    }
    return
  }
  if (-not $cfg.profiles.PSObject.Properties[$name]) { throw "未知档位 '$name'" }
  Set-FanActiveProfile -Name $name | Out-Null
  $lk = Require-AdminOrDaemon
  if ($lk) { Send-FanCmd 'profile' @{ profile = $name }; "  已请求守护进程切到 $name"; return }
  $p = $cfg.profiles.$name
  if ($p.mode) { Set-FanMode -Mode ([int]$p.mode) | Out-Null }
  $s = Get-FanSnapshot
  $d = Get-FanDesiredRpm -Profile $name -Snap $s
  Set-FanTargetRpm -Rpm $d.rpm | Out-Null
  "  档位 -> $name ($($p.label))  当前目标 $($d.rpm) RPM"
  Show-SnapshotTable (Get-FanSnapshot)
}

function Cmd-Set([object[]]$r) {
  $rpm = ArgAt $r 0
  if (-not $rpm) { throw '用法: set <RPM> [-Seconds N]   例如 set 5500 -Seconds 30' }
  $sec = [int](FlagVal $r '-Seconds' '0')
  $cfg = Get-FanConfig
  $v = Limit-FanRpm -Rpm ([int]$rpm) -Floor ([int]$cfg.safety.rpm_floor) -Ceiling ([int]$cfg.safety.rpm_ceiling)
  if ($v -ne [int]$rpm) { Write-Host "  已夹到安全区间: $v RPM（允许 $($cfg.safety.rpm_floor)-$($cfg.safety.rpm_ceiling)）" -ForegroundColor Yellow }
  $lk = Require-AdminOrDaemon
  if ($lk) { Send-FanCmd 'rpm' @{ rpm = $v; hold_s = $sec }; return }
  Set-FanTargetRpm -Rpm $v | Out-Null
  if ($sec -gt 0) {
    Write-Host "  ${sec}s 后恢复曲线控制（Ctrl+C 取消倒计时，但转速会保持最后值）" -ForegroundColor Cyan
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
      $s = Get-FanSnapshot
      "   {0}  实际 {1} RPM / 目标 {2}   近CPU {3}°C  GPU {4}°C" -f (Get-Date -Format 'HH:mm:ss'), $s.rpm, $v, $s.near_cpu, $s.gpu_c
      Start-Sleep -Seconds 2
    }
    $s = Get-FanSnapshot
    $d = Get-FanDesiredRpm -Snap $s
    Set-FanTargetRpm -Rpm $d.rpm | Out-Null
    "  已恢复曲线目标 $($d.rpm) RPM"
  } else {
    Start-Sleep -Seconds 5
    Show-SnapshotTable (Get-FanSnapshot)
  }
}

function Cmd-Boost([object[]]$r) {
  $sec = [int](ArgAt $r 0); if (-not $sec) { $sec = [int](FlagVal $r '-Seconds' '20') }
  if ($sec -lt 0) { $sec = 0 }
  $lk = Require-AdminOrDaemon
  if ($lk) { Send-FanCmd 'boost' @{ sec = $sec }; return }
  Set-FanFullSpeed -On $true | Out-Null
  if ($sec -eq 0) { '  满速已开启（用 boost 0 之外的值或 reset 关闭）'; return }
  Write-Host "  满速 $sec 秒（Ctrl+C 可提前结束并自动解除）" -ForegroundColor Cyan
  try {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
      $s = Get-FanSnapshot
      "   {0}  {1} RPM  近CPU {2}°C  GPU {3}°C" -f (Get-Date -Format 'HH:mm:ss'), $s.rpm, $s.near_cpu, $s.gpu_c
      Start-Sleep -Seconds 2
    }
  } finally {
    Set-FanFullSpeed -On $false | Out-Null
    $cfg = Get-FanConfig
    $s = Get-FanSnapshot
    if (-not (Get-FanLockState)) { Set-FanTargetRpm -Rpm ([int]$cfg.safety.exit_rpm) | Out-Null }
    Write-Host '  满速已解除' -ForegroundColor Green
  }
  Start-Sleep -Seconds 3
  Show-SnapshotTable (Get-FanSnapshot)
}

function Cmd-Limit([object[]]$r) {
  $p1 = ArgAt $r 0; $p2 = ArgAt $r 1
  if (-not $p1 -and -not $p2) {
    $s = Get-FanSnapshot
    "  当前 EC 功耗墙: PL1=$($s.pl1)W  PL2=$($s.pl2)W"
    $cfg = Get-FanConfig
    "  配置目标值   : PL1=$($cfg.power.pl1)W  PL2=$($cfg.power.pl2)W  (keep_pl=$($cfg.power.keep_pl))"
    '  用法: limit <PL1> [PL2]   limit keep on|off'
    return
  }
  if ($p1 -eq 'keep') {
    $cfg = Get-FanConfig
    $cfg.power.keep_pl = ("$($p2)" -match '^(on|1|true)$')
    Save-FanConfig -Config $cfg -Why 'fanctl:limit-keep'
    "  keep_pl = $($cfg.power.keep_pl)"; return
  }
  $lk = Require-AdminOrDaemon
  if ($lk) { Send-FanCmd 'limit' @{ pl1 = [int]$p1; pl2 = $(if ($p2) { [int]$p2 } else { 0 }) }; return }
  $null = Set-FanPowerLimit -Pl1 $(if ($p1) { [int]$p1 } else { 0 }) -Pl2 $(if ($p2) { [int]$p2 } else { 0 })
  Start-Sleep -Seconds 2
  "  写后读回: PL1=$(Get-FanPl1)W PL2=$(Get-FanPl2)W"
}

function Cmd-Curve([object[]]$r) {
  $sub = ArgAt $r 0; $cfg = Get-FanConfig
  $prof = ArgAt $r 1
  if (-not $prof -or -not $cfg.profiles.PSObject.Properties[$prof]) {
    if ($sub -in 'show', 'list', $null, '') { $prof = $cfg.active_profile } else { throw "用法: curve show|set|export|import [profile] [cpu|gpu] [spec]（profile 可选: $(($cfg.profiles.PSObject.Properties.Name) -join ', ')）" }
  }
  $p = $cfg.profiles.$prof
  switch ($sub) {
    { $null -eq $_ -or $_ -in 'show', 'ls' } {
      "  档位 $($p.label) ($prof)  上限 $($p.ceiling) RPM  Fn+Q 模式 $($p.mode)"
      '  CPU 曲线 (近CPU温度+负载预判 -> RPM)'
      (Parse-FanCurve -Spec $p.cpu) | ForEach-Object { '     {0,5} °C -> {1,4} RPM' -f $_.Temp, $_.Rpm }
      '  GPU 曲线'
      (Parse-FanCurve -Spec $p.gpu) | ForEach-Object { '     {0,5} °C -> {1,4} RPM' -f $_.Temp, $_.Rpm }
      "  当前实测: $(Get-FanNearCpuC)°C / $(Get-FanGpuC)°C -> 目标 $((Get-FanDesiredRpm -Profile $prof).rpm) RPM"
    }
    'set' {
      $which = ArgAt $r 2; $spec = ArgAt $r 3
      if ($which -notin 'cpu', 'gpu') { throw '用法: curve set <profile> cpu|gpu "66:3600,70:4200,...,94:6600"' }
      if (-not $spec) { throw '缺少曲线内容。示例: curve set custom cpu "66:3600,72:4200,78:4800,82:5400,86:6000,90:6400,94:6600,98:6600"' }
      $pts = Parse-FanCurve -Spec $spec          # validates
      $cfg.profiles.$prof | Add-Member -NotePropertyName $which -NotePropertyValue (Format-FanCurve -Points $pts) -Force
      Save-FanConfig -Config $cfg -Why 'fanctl:curve-set'
      Write-Host "  已写入 $prof.$which（$($pts.Count) 个点）" -ForegroundColor Green
      Send-FanCmd 'reload' @{}
      (Parse-FanCurve -Spec $cfg.profiles.$prof.$which) | ForEach-Object { '     {0,5} °C -> {1,4} RPM' -f $_.Temp, $_.Rpm }
    }
    'export' {
      $out = ArgAt $r 2
      $obj = [pscustomobject]@{ profile = $prof; cpu = $p.cpu; gpu = $p.gpu; ceiling = $p.ceiling; mode = $p.mode; label = $p.label }
      $json = $obj | ConvertTo-Json -Depth 4
      if ($out) { [IO.File]::WriteAllText((Join-Path (Get-Location) $out), $json, (New-Object Text.UTF8Encoding $false)); "  已导出 -> $out" } else { $json }
    }
    'import' {
      $file = ArgAt $r 2
      if (-not (Test-Path -LiteralPath $file)) { throw "找不到文件 $file" }
      $obj = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
      $name = if ($obj.profile) { "$($obj.profile)" } else { 'custom' }
      if ($name -eq $prof -and -not $cfg.profiles.PSObject.Properties[$name]) { $name = 'custom' }
      if (-not $cfg.profiles.PSObject.Properties[$name]) {
        $cfg.profiles | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ label = '导入' ; mode = 3 ; ceiling = 6600 ; hysteresis = 2 ; cpu = $obj.cpu ; gpu = $obj.gpu })
      } else {
        $cfg.profiles.$name | Add-Member -NotePropertyName cpu -NotePropertyValue $obj.cpu -Force
        $cfg.profiles.$name | Add-Member -NotePropertyName gpu -NotePropertyValue $obj.gpu -Force
        if ($obj.ceiling) { $cfg.profiles.$name | Add-Member -NotePropertyName ceiling -NotePropertyValue $obj.ceiling -Force }
      }
      Parse-FanCurve -Spec $obj.cpu | Out-Null; Parse-FanCurve -Spec $obj.gpu | Out-Null
      Save-FanConfig -Config $cfg -Why 'fanctl:curve-import'
      "  已导入为档位 '$name'"; Send-FanCmd 'reload' @{}
    }
    default { throw 'curve 子命令: show | set | export | import' }
  }
}

function Cmd-Daemon([object[]]$r) {
  $sub = (ArgAt $r 0) | ForEach-Object { $_.ToLower() }
  $lk = Get-FanLockState
  switch ($sub) {
    { $null -eq $_ -or $_ -in 'status', 'st' } {
      if ($lk -and $lk.alive) { "  守护进程运行中: pid=$($lk.pid) ($($lk.who)) 自 $($lk.since)" }
      else { '  守护进程未运行' + $(if ($lk) { "（发现失效锁 pid=$($lk.pid)）" }) }
      $live = Join-Path $StateDir 'live.json'
      if (Test-Path -LiteralPath $live) {
        $j = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json
        "  最近一轮: $($j.snap.time)  档位=$($j.profile) 转速=$($j.snap.rpm) 目标=$($j.last_target) mode=$($j.mode) uptime=$($j.uptime_s)s"
      }
      return
    }
    'start' {
      if ($lk -and $lk.alive) { "  已在运行 (pid=$($lk.pid))。要重启用: daemon restart"; return }
      $prof = FlagVal $r '-Profile' ''; $iv = FlagVal $r '-Interval' '2'
      $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$src\daemon.ps1`" -Interval $iv"
      if ($prof) { $a += " -Profile `"$prof`"" }
      if (HasFlag $r '-Force') { $a += ' -Force' }
      Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a | Out-Null
      Write-Host '  已请求启动（可能弹出管理员授权），等待首轮数据……' -ForegroundColor Cyan
      $deadline = (Get-Date).AddSeconds(25)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $l2 = Get-FanLockState
        if ($l2 -and $l2.alive -and (Test-Path -LiteralPath (Join-Path $StateDir 'live.json'))) { "  守护进程已运行 (pid=$($l2.pid))"; return }
      }
      Write-Host '  25 秒内没起来：检查 logs\fan.log 或管理员授权是否被拒绝' -ForegroundColor Yellow
      return
    }
    'stop' {
      if (-not ($lk -and $lk.alive)) { '  未运行'; return }
      Send-FanCmd 'stop' @{}
      $deadline = (Get-Date).AddSeconds(15)
      while ((Get-Date) -lt $deadline -and (Get-FanLockState).alive) { Start-Sleep -Milliseconds 400 }
      if ((Get-FanLockState).alive) {
        if (-not (IsAdmin)) { Write-Host '  普通停止无效，尝试强制结束（需管理员）' -ForegroundColor Yellow; Require-AdminOrDaemon | Out-Null }
        Stop-Process -Id $lk.pid -Force -ErrorAction SilentlyContinue
      }
      '  已停止（转速保持在最后一次命令值；重启电脑可完全交还 BIOS）'
      return
    }
    'restart' {
      Send-FanCmd 'stop' @{}
      Start-Sleep -Seconds 3
      $more = @($Rest | Select-Object -Skip 1)
      Cmd-Daemon (@('start') + $more)
      return
    }
    'log' { Get-SharedTailLines -Path (Join-Path $LogDir 'fan.log') -Count ([int](FlagVal $r '-Tail' '40')); return }
    default { throw '用法: daemon start|stop|restart|status|log [-Profile 名] [-Interval 秒]' }
  }
}

function Cmd-Panel([object[]]$r) {
  $port = FlagVal $r '-Port' ''
  $a = "-NoProfile -ExecutionPolicy Bypass"
  if ($port) { $a += " -Port $port" }
  Start-Process -FilePath 'powershell.exe' -ArgumentList "$a -File `"$src\panel.ps1`"" | Out-Null
  Start-Sleep -Seconds 2
  $cfg = Get-FanConfig
  "  面板已启动: http://$($cfg.panel.host):$($(if ($port) { $port } else { $cfg.panel.port }))/   （Ctrl+C 或关闭窗口退出）"
}

function Cmd-Test([object[]]$r) {
  <# safe end-to-end check: only raises speed, always restores #>
  $prof = FlagVal $r '-Profile' ((Get-FanConfig).active_profile)
  $lk = Require-AdminOrDaemon
  if ($lk) { Write-Host '  守护进程在运行时不建议并行测试，请先 daemon stop' -ForegroundColor Yellow; return }
  $s0 = Get-FanSnapshot
  Write-Host "  起点: 转速 $($s0.rpm) RPM, 近CPU $($s0.near_cpu)°C, GPU $($s0.gpu_c)°C, PL1 $($s0.pl1)W" -ForegroundColor Cyan
  $startRpm = [int]$s0.rpm
  $steps = @([math]::Max($startRpm, 4500), [math]::Max($startRpm + 800, 5300), [math]::Min(6400, [math]::Max($startRpm + 1600, 6100)))
  try {
    foreach ($v in $steps) {
      Set-FanTargetRpm -Rpm $v | Out-Null
      $t0 = Get-Date
      while (((Get-Date) - $t0).TotalSeconds -lt 9) {
        $s = Get-FanSnapshot
        "   目标 {0,4} → 实际 {1,4} RPM   近CPU {2}°C GPU {3}°C  PL1 {4}W" -f $v, $s.rpm, $s.near_cpu, $s.gpu_c, $s.pl1
        Start-Sleep -Seconds 3
      }
    }
    Set-FanFullSpeed -On $true | Out-Null
    Start-Sleep -Seconds 6
    $s = Get-FanSnapshot
    "   满速实测: $($s.rpm) RPM (full=$(Get-FanFullSpeed))"
    Set-FanFullSpeed -On $false | Out-Null
    Start-Sleep -Seconds 4
  } finally {
    $cfg = Get-FanConfig
    Set-FanTargetRpm -Rpm ([int]$cfg.safety.exit_rpm) | Out-Null
    Set-FanMode -Mode ([int]$cfg.profiles.$prof.mode) | Out-Null
    Write-Host "  已恢复到 exit_rpm=$($cfg.safety.exit_rpm) + 档位 $prof" -ForegroundColor Green
  }
  Start-Sleep -Seconds 4
  Show-SnapshotTable (Get-FanSnapshot)
  '  判定标准：实际转速应跟随目标（±300 RPM，约 6-9 秒到位）；满速应到 ~6600 RPM'
}

function Cmd-Reset([object[]]$r) {
  $lk = Require-AdminOrDaemon
  if ($lk) { Send-FanCmd 'reset' @{}; return }
  Reset-FanNormal | Out-Null
  Start-Sleep -Seconds 4
  Show-SnapshotTable (Get-FanSnapshot)
}

function Cmd-Diag([object[]]$r) {
  '===== 诊断信息（可直接贴给开发者）====='
  "  计算机: $((Get-CimInstance Win32_ComputerSystem).Model) / $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)"
  "  系统  : $((Get-CimInstance Win32_OperatingSystem).Caption) build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
  "  CPU   : $((Get-CimInstance Win32_Processor).Name)"
  "  GPU   : $((Get-CimInstance Win32_VideoController | Select-Object -Last 1).Name)"
  "  管理员: $(IsAdmin)"
  "  EC    : $(try { Connect-FanWmi } catch { "连接失败: $($_.Exception.Message)" })"
  $s = Get-FanSnapshot
  Show-SnapshotTable $s
  "  WMI ASL 版本: $(Get-FanWmiVersion)"
  "  曲线表(Fan_Get_Table) 本机返回: $(try { (Invoke-FanWmi -Class 'LENOVO_FAN_METHOD' -Method 'Fan_Get_Table' -In @{FanID = [byte]1; SensorID = [byte]1 }).Count } catch { 'ERR' }) (0 = 本 BIOS 不开放曲线表)"
  "  电源计划: $((powercfg /getactivescheme) -join ' ')"
  "  风扇日志尾部:"
  if (Test-Path -LiteralPath (Join-Path $LogDir 'fan.log')) { Get-SharedTailLines -Path (Join-Path $LogDir 'fan.log') -Count 12 | ForEach-Object { "    $_" } }
}

function Cmd-Config([object[]]$r) {
  $sub = ArgAt $r 0
  switch ($sub) {
    'reset' { Save-FanConfig -Config (New-DefaultConfig) -Why 'fanctl:config-reset'; '  config.json 已恢复默认（旧值存于 state\config.prev.json）'; Send-FanCmd 'reload' @{} }
    'path' { $ConfigFile }
    'check' {
      $w = @(Get-FanCurveIssue)
      if ($w.Count -eq 0) { '  曲线检查：全部档位正常' }
      else { $w | ForEach-Object { "  警告: $_" } }
    }
    default { Get-FanConfig | ConvertTo-Json -Depth 10 }
  }
}

function Cmd-Version([object[]]$r) {
  $rootDir = Split-Path (Split-Path $PSCommandPath -Parent)
  $vf = Join-Path $rootDir 'VERSION'
  $ver = if (Test-Path -LiteralPath $vf) { (Get-Content -LiteralPath $vf -Raw).Trim() } else { 'dev' }
  # the tray exe lives beside the repo root or inside the newest dist\ build
  $cand = @(Join-Path $rootDir 'LegionFanStudio.exe')
  $cand += @(Get-ChildItem -LiteralPath (Join-Path $rootDir 'dist') -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'LegionFanStudio-v*' } | Sort-Object LastWriteTime -Descending |
             ForEach-Object { Join-Path $_.FullName 'LegionFanStudio.exe' })
  $exe = $null
  foreach ($c in $cand) { if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break } }
  "Legion Fan Studio $ver"
  "  托盘程序 : $(if ($exe) { $exe } else { '尚未编译（跑 build\build.ps1，产物在 dist\LegionFanStudio-vX.Y.Z\）' })"
  "  引擎目录 : $(Split-Path $PSCommandPath -Parent)"
  "  数据目录 : $DataRoot"
  "  配置文件 : $ConfigFile  $(if (Test-Path -LiteralPath $ConfigFile) { '' } else { '（首次运行自动生成）' })"
  "  PowerShell: $($PSVersionTable.PSVersion)"
}

function Cmd-History([object[]]$r) {
  $n = [int](FlagVal $r '-Tail' '30')
  Get-FanHistory -Tail $n
}

function Cmd-Elevate([object[]]$r) {
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" status"
  '  已在管理员窗口执行 status（读结果即可，不会写入）'
}

function Cmd-Help {
  Get-Content -LiteralPath (Join-Path $src 'help.txt') -Raw -Encoding UTF8
}

switch ("$Command".ToLower()) {
  'status' { Cmd-Status $Rest }
  'watch'  { Cmd-Watch $Rest }
  'mode'   { Cmd-Mode $Rest }
  'profile'{ Cmd-Profile $Rest }
  'set'    { Cmd-Set $Rest }
  'rpm'    { Cmd-Set $Rest }
  'boost'  { Cmd-Boost $Rest }
  'limit'  { Cmd-Limit $Rest }
  'curve'  { Cmd-Curve $Rest }
  'daemon' { Cmd-Daemon $Rest }
  'panel'  { Cmd-Panel $Rest }
  'test'   { Cmd-Test $Rest }
  'reset'  { Cmd-Reset $Rest }
  'diag'   { Cmd-Diag $Rest }
  'config' { Cmd-Config $Rest }
  'history'{ Cmd-History $Rest }
  'version' { Cmd-Version $Rest }
  'elevate'{ Cmd-Elevate $Rest }
  { 'help', '-h', '/?', '' -contains $_ } { Cmd-Help }
  default { Cmd-Help; throw "未知命令: $Command" }
}
