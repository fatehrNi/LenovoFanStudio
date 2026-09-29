<#
.SYNOPSIS
  Y9000P 2022 风扇守护进程：按曲线闭环控速 + 过温兜底 + 功耗墙看护。
.DESCRIPTION
  本进程是 EC 的唯一写入者。它每周期读取温度/转速，按当前档位的曲线算出目标 RPM 并下发；
  面板 (panel.ps1) 通过 state\cmd.json 投递命令，本进程消费后写回 state\live.json。
  安全兜底：
    * 近CPU温度 >= nearcpu_crit 或 GPU >= gpu_crit  -> 立刻满速，降温后自动解除
    * 目标转速永远被 clamp 在 [rpm_floor, rpm_ceiling]（防止失速/越界）
    * EC 读失败连续 N 次 -> 拉满速并保持，避免"盲跑"
    * 进程收到退出信号时写回 exit_rpm（交还一个安全的默认转速）
    * 若 PL1 被 EC 主动压低（散热不足信号）而转速未到顶 -> 自动升一档
#>
[CmdletBinding()]
param(
  [string]$Profile = '',
  [ValidateRange(1, 30)][int]$Interval = 2,
  [int]$Deadband = 120,          # RPM 死区：小于此偏差不重复写入，避免风扇来回变速
  [switch]$Force,
  [switch]$NoBoost,
  [string]$RunFor = ''           # 可选：只运行 N 秒后自动退出（用于演示/压测）
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$src = Split-Path -Parent $PSCommandPath
$env:PSModulePath = "$src$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $src 'LenovoFan.psm1') -Force -DisableNameChecking

$cfg = Get-FanConfig
if (-not $Profile) { $Profile = [string]$cfg.active_profile }
if (-not $cfg.profiles.PSObject.Properties[$Profile]) { throw "未知档位 '$Profile'" }

$safe = $cfg.safety
$floor = [int]$safe.rpm_floor
$ceil = [int]$safe.rpm_ceiling
$reassert = [int]$safe.reassert_gap_s

# --- lock (single instance) + graceful exit --------------------------------
# NOTE: do NOT try to subscribe to [Console]::CancelKeyPress - PowerShell cannot
# bind static .NET events, and it would abort the script before the try/finally.
$script:running = $true
$script:lastTarget = -1
$script:lastWriteAt = [datetime]::MinValue
$script:lastCmdId = -1
$script:boostUntil = $null
$script:paused = $false
$script:critLatched = $false
$fails = 0
$script:loopErrs = 0
$hist = New-Object 'System.Collections.Generic.Queue[object]'
$script:sampleQ = New-Object 'System.Collections.Generic.Queue[object]'
$script:lastPlGuard = [datetime]::MinValue
# Get-FanSafetyNum = read an optional safety knob with a numeric fallback.
# NOT named "Sv": that is a built-in alias for Set-Variable, aliases outrank
# functions, and it silently returned $null -> `0 -gt $null` is True in
# PowerShell -> dequeue-on-empty. Never name functions with 1-2 letters.
function Get-FanSafetyNum([string]$key, $default) {
  $v = $null
  try { if ($safe -and $safe.PSObject.Properties[$key]) { $v = $safe.$key } } catch { }
  $i = 0
  if (-not [int]::TryParse("$v", [ref]$i)) {
    if (-not [int]::TryParse("$default", [ref]$i)) { $i = 1 }
  }
  return $i
}
$liveFile = Join-Path $StateDir 'live.json'
$cmdFile = Join-Path $StateDir 'cmd.json'

try { Enter-FanLock -Who "daemon:$Profile" -Force:$Force } catch { Write-FanLog "启动失败: $($_.Exception.Message)" 'ERROR'; exit 1 }
Write-FanLog "守护进程启动中 pid=$PID 档位=$Profile 间隔=${Interval}s" 'ACTION'
$startTime = Get-Date

function Write-JsonAtomic {
  param([string]$Path, [object]$Object, [int]$Depth = 12)
  $tmp = "$Path.tmp"
  $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth $Depth -Compress }
  if ($null -eq $json -or "$json" -eq '') { $json = 'null' }
  [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Write-Live($obj) {
  try {
    $tmp = "$liveFile.tmp"
    $obj | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $liveFile -Force
  } catch { Write-FanLog "live.json 写入失败: $($_.Exception.Message)" 'WARN' }
}

function Get-CmdNum {
  <# pull a required numeric argument out of a command payload; $null if absent #>
  param($Args_, [string]$Name)
  if (-not $Args_) { return $null }
  if ($null -eq $Args_.PSObject.Properties[$Name]) { return $null }
  $v = $Args_.$Name
  if ($null -eq $v -or "$v" -eq '') { return $null }
  $n = 0
  if (-not [int]::TryParse("$v", [ref]$n)) { return $null }
  return $n
}

function Invoke-CmdFile {
  if (-not (Test-Path -LiteralPath $cmdFile)) { return }
  try {
    $c = Get-Content -LiteralPath $cmdFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $c) { return }
    if ([int]$c.id -eq $script:lastCmdId) { return }
    $script:lastCmdId = [int]$c.id
    Write-FanLog "收到命令 $($c.type) $(if ($c.args) { ($c.args | ConvertTo-Json -Compress -Depth 4) })" 'ACTION'
    switch ("$($c.type)".ToLower()) {
      'profile' {
        # NOTE: plain `$Profile = ...` inside this function would create a LOCAL
        # copy and the loop would silently keep the old profile -> use $script:.
        $new = [string]$c.args.profile
        $probe = Get-FanConfig
        if (-not (Test-FanProfile -Config $probe -Name $new)) { Write-FanLog "未知档位 '$new'，忽略" 'WARN'; break }
        $script:Profile = $new
        Set-FanActiveProfile -Name $new | Out-Null
        $script:cfg = Get-FanConfig
        $script:safe = $script:cfg.safety
        $m = [int]$script:cfg.profiles.$new.mode
        if ($c.args.mode) { $m = [int]$c.args.mode }
        if ($m -ge 1 -and $m -le 4) { Set-FanMode -Mode $m | Out-Null }
        $script:lastTarget = -1          # re-evaluate the curve immediately
        Write-FanLog "档位已切换到 $new ($($script:cfg.profiles.$new.label))，上限 $($script:cfg.profiles.$new.ceiling) RPM" 'ACTION'
      }
      'mode'    {
        $mv = Get-CmdNum $c.args 'mode'
        if ($null -eq $mv) { Write-FanLog "mode 命令缺少档位，已忽略" 'ERROR'; break }
        Set-FanMode -Mode ([int]$mv) | Out-Null
      }
      'rpm'     {
        $rv = Get-CmdNum $c.args 'rpm'
        if ($null -eq $rv) { Write-FanLog "rpm 命令缺少有效转速值，已忽略（不写入 EC）" 'ERROR'; break }
        $script:boostUntil = $null
        Set-FanTargetRpm -Rpm ([int]$rv) | Out-Null
        $script:lastTarget = [int]$rv; $script:lastWriteAt = Get-Date
        # hold: pause the curve engine. An explicit hold_s wins; an open-ended one is
        # still bounded by max_hold_s, because a forgotten "hold" froze the fans at
        # 5800 RPM for 2.5 hours during testing.
        $script:paused = $true
        $hold = Get-FanSafetyNum 'max_hold_s' 900
        $want = Get-CmdNum $c.args 'hold_s'
        if ($null -ne $want -and $want -gt 0) { $hold = $want }
        $script:boostUntil = (Get-Date).AddSeconds($hold)
        Write-FanLog "已保持转速 $([int]$rv) RPM，$hold 秒后自动交还曲线控制" 'WARN'
      }
      'boost'   {
        $sec = [int]$c.args.sec; if ($sec -le 0) { $sec = [int]$script:safe.manual_timeout_s }
        Set-FanFullSpeed -On $true | Out-Null
        $script:boostUntil = (Get-Date).AddSeconds($sec)
        Write-FanLog "满速 $sec 秒后自动解除" 'WARN'
      }
      'limit'   {
        $l1 = Get-CmdNum $c.args 'pl1'; $l2 = Get-CmdNum $c.args 'pl2'
        if ($null -eq $l1 -and $null -eq $l2) { Write-FanLog "limit 命令缺少功耗值，已忽略" 'ERROR'; break }
        Set-FanPowerLimit -Pl1 $(if ($l1) { [int]$l1 } else { 0 }) -Pl2 $(if ($l2) { [int]$l2 } else { 0 }) | Out-Null
      }
      'reset'   { Reset-FanNormal | Out-Null; $script:paused = $false; $script:boostUntil = $null; $script:critLatched = $false }
      'pause'   {
        $script:paused = $true
        $maxHold = Get-FanSafetyNum 'max_hold_s' 900
        $script:boostUntil = (Get-Date).AddSeconds($maxHold)
        Write-FanLog "暂停接管，最多 $maxHold 秒后自动恢复曲线控制（可随时点「继续」）" 'WARN'
      }
      'resume'  { $script:paused = $false; $script:boostUntil = $null }
      'reload'  {
        $script:cfg = Get-FanConfig
        $script:safe = $script:cfg.safety
        # cached scalars must follow the reload, otherwise a changed ceiling/floor
        # would silently keep the values captured at startup.
        $script:floor = [int]$script:safe.rpm_floor
        $script:ceil = [int]$script:safe.rpm_ceiling
        $script:reassert = [int]$script:safe.reassert_gap_s
        $script:lastTarget = -1              # curve may have moved -> re-evaluate now
        Write-FanLog '配置已热加载'
        foreach ($m in @(Get-FanCurveIssue -Config $script:cfg)) { Write-FanLog "曲线检查: $m" 'WARN' }
      }
      'stop'    { Write-FanLog "收到 stop 命令，准备收尾退出" 'ACTION'; $script:running = $false }
      default   { Write-FanLog "未知命令 $($c.type)，忽略" 'WARN' }
    }
    Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue
  } catch {
    Write-FanLog "命令文件处理失败: $($_.Exception.Message)" 'ERROR'
    Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue
  }
}

try {
  Connect-FanWmi | Out-Null
  Write-FanLog "守护启动：档位=$($cfg.profiles.$Profile.label) 间隔=${Interval}s 区间=$floor-$ceil RPM 死区=$Deadband" 'ACTION'
  foreach ($m in @(Get-FanCurveIssue -Config $cfg)) { Write-FanLog "曲线检查: $m" 'WARN' }
  if (-not $NoBoost -and $cfg.profiles.$Profile.mode) {
    try { $null = Set-FanMode -Mode ([int]$cfg.profiles.$Profile.mode) } catch { Write-FanLog "档位模式切换失败: $($_.Exception.Message)" 'WARN' }
  }

  while ($script:running) {
   try {
    Invoke-CmdFile
    $snap = Get-FanSnapshot
    if (-not $snap.ok -or $snap.rpm -lt 0) {
      $fails++
      Write-FanLog "EC 读取失败($fails): $($snap.err)" 'ERROR'
      if ($fails -ge 3) {
        try { Set-FanFullSpeed -On $true -SkipSafety | Out-Null } catch { }
        Write-FanLog '连续读取失败 -> 已强制满速，等待 EC 恢复' 'WARN'
      }
      Start-Sleep -Seconds ([math]::Min(10, 2 * $fails))
      try { Connect-FanWmi -Quiet | Out-Null } catch { }
      continue
    }
    $fails = 0

    # ---- 平滑采样：EC 的 nearCPU 是慢 NTC、cpu_util 抖动很大，直接喂曲线会让
    #      目标转速每两秒跳几百转，EC 会被这种频繁写入搞乱（实测过）。取滑动平均。
    $script:sampleQ.Enqueue([pscustomobject]@{ cpu = [double]$snap.near_cpu; gpu = [double]$snap.gpu_c; util = [double]$snap.cpu_util })
    $smoothN = Get-FanSafetyNum 'smooth_samples' 5
    if ($smoothN -lt 1) { $smoothN = 5 }
    while ($script:sampleQ.Count -gt $smoothN -and $script:sampleQ.Count -gt 0) { $script:sampleQ.Dequeue() | Out-Null }
    $avgCpu = [math]::Round(($script:sampleQ | Measure-Object -Property cpu -Average).Average, 1)
    $avgGpu = [math]::Round(($script:sampleQ | Measure-Object -Property gpu -Average).Average, 1)
    $avgUtl = [int](($script:sampleQ | Measure-Object -Property util -Average).Average)
    $avgSnap = [pscustomobject]@{ ok = $true; near_cpu = $avgCpu; gpu_c = $avgGpu; cpu_util = $avgUtl; rpm = $snap.rpm; mode = $snap.mode }

    $d = Get-FanDesiredRpm -Profile $Profile -Snap $avgSnap
    $target = [int]$d.rpm
    $mode = 'auto'
    $forceWrite = $false

    # --- 过温兜底：用瞬时值判断，且绕过一切节流 -----------------------------
    if ([double]$snap.near_cpu -ge [double]$safe.nearcpu_crit -or [double]$snap.gpu_c -ge [double]$safe.gpu_crit) {
      if (-not $script:critLatched) {
        Write-FanLog "过温 nearCPU=$($snap.near_cpu)°C GPU=$($snap.gpu_c)°C -> 强制满速" 'ERROR'
        Set-FanFullSpeed -On $true | Out-Null
        $script:critLatched = $true
      }
      $target = $ceil; $mode = 'crit'; $forceWrite = $true
    } elseif ($script:critLatched -and $snap.near_cpu -lt ([int]$safe.nearcpu_crit - 8) -and $snap.gpu_c -lt ([int]$safe.gpu_crit - 8)) {
      Write-FanLog "温度回落 (nearCPU=$($snap.near_cpu)°C) -> 解除满速，回到曲线控制" 'ACTION'
      Set-FanFullSpeed -On $false | Out-Null
      $script:critLatched = $false
      $mode = 'auto'
    } elseif ($script:critLatched) { $target = $ceil; $mode = 'crit' }

    # --- boost / hold 计时到点收尾 ------------------------------------------
    if ($script:boostUntil -and (Get-Date) -ge $script:boostUntil) {
      if (-not $script:critLatched) { Set-FanFullSpeed -On $false | Out-Null }
      $script:boostUntil = $null
      $script:paused = $false
      $script:lastTarget = -1                      # force a fresh write under the new regime
      Write-FanLog '定时满速/保持已到期，恢复曲线控制' 'ACTION'
    }

    # --- 功耗墙看护：EC 主动降 PL1 = 它认为散热不足（限流，最多 60 秒一次）----
    $plWant = [int]$cfg.power.pl1
    if ($plWant -gt 0 -and $snap.pl1 -gt 0 -and $snap.pl1 -lt ($plWant - 25) -and $snap.cpu_util -gt 40 `
        -and ((Get-Date) - $script:lastPlGuard).TotalSeconds -gt 60) {
      $script:lastPlGuard = Get-Date
      $target = [math]::Min($ceil, $target + 500)
      $mode = 'pl-guard'
      Write-FanLog "PL1=$($snap.pl1)W 被 EC 压低（目标 ${plWant}W，CPU 占用 $($snap.cpu_util)%）-> 目标提到 $target RPM" 'WARN'
    }
    if ([bool]$cfg.power.keep_pl -and $snap.pl1 -gt 0 -and [math]::Abs($snap.pl1 - $plWant) -gt 8 -and $snap.cpu_util -lt 60) {
      Set-FanPowerLimit -Pl1 $plWant -Pl2 ([int]$cfg.power.pl2) | Out-Null
    }

    # --- 下发：限速 + 迟滞 + 定期重申（这是避免把 EC 写崩的关键）--------------
    if (-not $script:paused -and -not $script:critLatched) {
      $up = Get-FanSafetyNum 'deadband_up' $Deadband
      $down = Get-FanSafetyNum 'deadband_down' 400
      $slew = Get-FanSafetyNum 'slew_rpm' 900
      $minGap = Get-FanSafetyNum 'min_write_gap_s' 6
      $gapOk = $forceWrite -or ((Get-Date) - $script:lastWriteAt).TotalSeconds -ge $minGap
      $stale = ((Get-Date) - $script:lastWriteAt).TotalSeconds -ge $reassert
      $want = $script:lastTarget
      $need = $false
      if ($script:lastTarget -lt 0) { $need = $true; $want = $target }
      elseif ($target -ge ($script:lastTarget + $up)) { $need = $true; $want = [math]::Min($target, $script:lastTarget + $slew) }   # 升速快
      elseif ($target -le ($script:lastTarget - $down)) { $need = $true; $want = [math]::Max($target, $script:lastTarget - $slew) } # 降速慢，避免忽快忽慢
      elseif ($stale -and ([math]::Abs($snap.rpm - $script:lastTarget) -gt 350)) { $need = $true; $want = $script:lastTarget }      # 实际没跟上 -> 重申
      # 没有「无条件心跳重申」：实测每次写 EC（哪怕写回同一个值）都会让风扇从 ~2600 RPM
      # 重新拉起，6~12 秒才回到目标。30 秒一次的空写 = 风扇永无止境地降下去再轰上来。
      # 只有读数确实偏离目标时才重申，足够覆盖「EC 被别人改回去」这一情形。

      if ($need -and $gapOk) {
        $applied = Set-FanTargetRpm -Rpm ([int]$want)
        $script:lastTarget = $applied
        $script:lastWriteAt = Get-Date
        $target = $applied
      } else { $target = $script:lastTarget }
    } elseif ($script:paused) { $mode = 'hold' }

    Add-FanHistory -Snap $snap -Target $script:lastTarget -Note "$Profile/$mode"
    # publish a log snapshot so the panel never opens the live log file
    try { Write-JsonAtomic -Path (Join-Path $StateDir 'logtail.json') -Object (@(Get-SharedTailLines -Path (Join-Path $LogDir 'fan.log') -Count 60)) } catch { }
    if ($hist.Count -ge 180) { $hist.Dequeue() | Out-Null }
    $hist.Enqueue([pscustomobject]@{ t = $snap.time.Substring(11); cpu = $snap.near_cpu; gpu = $snap.gpu_c; rpm = $snap.rpm; target = $script:lastTarget })

    Write-Live ([pscustomobject]@{
        alive = $true; pid = $PID; since = $startTime.ToString('o'); profile = $Profile
        label = $cfg.profiles.$Profile.label; mode = $mode; interval = $Interval
        snap = $snap; desired = $d; last_target = $script:lastTarget
        boost_remaining = if ($script:boostUntil) { [int]($script:boostUntil - (Get-Date)).TotalSeconds } else { 0 }
        crit_latched = $script:critLatched; paused = [bool]$script:paused
        hold_remaining = if ($script:paused -and $script:boostUntil) { [int]($script:boostUntil - (Get-Date)).TotalSeconds } else { 0 }
        safety = $safe; power = $cfg.power; profiles = $cfg.profiles; active = $cfg.active_profile
        series = @($hist)
        uptime_s = [int]((Get-Date) - $startTime).TotalSeconds
      })
    $script:loopErrs = 0
    Start-Sleep -Seconds $Interval

    if ($RunFor -and ((Get-Date) - $startTime).TotalSeconds -ge [double]$RunFor) { Write-FanLog "已运行 $RunFor 秒，按计划退出" 'ACTION'; $script:running = $false; break }
   } catch {
      # one bad cycle must never take the controller down
      $script:loopErrs++
      Write-FanLog "本轮异常(连续 $script:loopErrs 轮): $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
      # A controller that keeps throwing has lost the plot: the EC would hold the last
      # value forever, which can be a near-stall value. Put the fans somewhere safe.
      if ($script:loopErrs -eq 3) {
        try {
          $fb = [int]$safe.exit_rpm
          if ($snap -and $snap.ok -and ([double]$snap.near_cpu -ge [double]$safe.nearcpu_crit -or [double]$snap.gpu_c -ge [double]$safe.gpu_crit)) { $fb = [int]$safe.rpm_ceiling }
          Set-FanTargetRpm -Rpm $fb | Out-Null
          $script:lastTarget = $fb
          Write-FanLog "连续 3 轮异常 -> 已写回安全转速 $fb RPM（保持冷却，不再盲目控速）" 'WARN'
        } catch { Write-FanLog "兜底写速也失败了: $($_.Exception.Message)" 'ERROR' }
      }
      try { Connect-FanWmi -Quiet | Out-Null } catch { }
      Start-Sleep -Seconds ([math]::Max(3, $Interval * 2))
    }
  }
} finally {
  try {
    if (-not (Get-FanFullSpeed)) { } else { Set-FanFullSpeed -On $false -SkipSafety | Out-Null }
    if (-not $script:critLatched) { Set-FanTargetRpm -Rpm ([int]$safe.exit_rpm) -SkipSafety | Out-Null }
    Write-FanLog "退出前已写回安全转速 exit_rpm=$($safe.exit_rpm)" 'ACTION'
  } catch { Write-FanLog "退出收尾失败: $($_.Exception.Message)" 'ERROR' }
  try { Remove-Item -LiteralPath $liveFile -Force -ErrorAction SilentlyContinue } catch { }
  Exit-FanLock
  Write-FanLog '守护进程已停止'
}
