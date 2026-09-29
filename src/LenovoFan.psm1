# =============================================================================
#  LenovoFan.psm1 - 联想拯救者 Y9000P 2022 (82RF) 风扇 / 功耗 EC 控制核心模块
#
#  全部通过固件自带的 ACPI-WMI 接口，无需任何第三方驱动或联想软件：
#    root\wmi\LENOVO_GAMEZONE_DATA    instance ACPI\PNP0C14\GMZN_0   (Fn+Q 档位 / 满速 / 转速)
#    root\wmi\Lfc_thermal_interface   instance ACPI\PNP0C14\WM00_0   (单风扇转速 / 温度 / 功耗墙)
#
#  以下事实均在本机实测确认（详见 docs/实测记录.md）：
#    * SetFan1Speed / SetFan2Speed  的单位是 RPM，写入后 EC 会一直保持（不抢回控制权）
#    * SetPowerLimit1 / 2           的单位是 W，立即生效，可覆盖 Windows 电源计划
#    * SetSmartFanMode              接受 1安静 / 2均衡 / 3野兽；4自定义 被本 BIOS 拒绝
#    * Fan_Set_FullSpeed            双风扇满速（实测 ~6600 RPM）
#    * Fan_Get/Set_Table            本 BIOS 返回空 -> 不支持 EC 风扇曲线表，故曲线在软件侧实现
#    * GetCPUTemperature            恒为 ~97，是温度上限而非实时值；实时用 GetNearCPUTemperature
#
#  安全底线：所有写入都被 clamp 到 [rpm_floor, rpm_ceiling]，并且过温时强制满速。
# =============================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Management

$script:Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# Data roots must be writable. A portable copy writes beside the code; an
# installed copy (e.g. under Program Files) falls back to %LOCALAPPDATA%.
function Test-FanWritable([string]$Dir) {
  try {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    $probe = Join-Path $Dir ('.write-probe-{0}' -f $PID)
    [IO.File]::WriteAllText($probe, '1')
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch { return $false }
}
$script:RotateAt = 5MB                       # rotate a log once it passes this size
$script:DataRoot = $script:Root
$script:Portable = Test-FanWritable $script:Root
if (-not $script:Portable) {
  $script:DataRoot = Join-Path $env:LOCALAPPDATA 'LegionFanStudio'
  New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
}
$script:LogDir = Join-Path $script:DataRoot 'logs'
$script:StateDir = Join-Path $script:DataRoot 'state'
$script:ConfDir = Join-Path $script:DataRoot 'config'
$script:ConfigFile = Join-Path $script:ConfDir 'config.json'
$script:LockFile = Join-Path $script:StateDir 'daemon.lock'
$script:Scope = $null
$script:Obj = @{}
$script:LastWrite = [datetime]::MinValue

$ModeNames = @{ 1 = '安静 Quiet'; 2 = '均衡 Balanced'; 3 = '野兽 Performance'; 4 = '自定义 Custom(本机不支持)' }

# ---------------------------------------------------------------- 日志 / 配置
function Write-FanLog {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0, Mandatory)][string]$Message,
    [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string]$Level = 'INFO',
    [Parameter(Position = 2)][string]$File = 'fan'
  )
  try {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
    $line = '{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-SharedText -Path (Join-Path $script:LogDir "$File.log") -Text $line
    $p = Join-Path $script:LogDir "$File.log"
    if ($script:RotateAt -and (Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt $script:RotateAt)) {
      Move-Item -LiteralPath $p -Destination (Join-Path $script:LogDir ("{0}.{1}.log" -f $File, (Get-Date -Format 'yyyyMMddHHmmss'))) -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  switch ($Level) {
    'ERROR' { Write-Host $Message -ForegroundColor Red }
    'WARN' { Write-Host $Message -ForegroundColor Yellow }
    'ACTION' { Write-Host $Message -ForegroundColor Green }
    default { Write-Host $Message }
  }
}

function Add-SharedText {
  <# Append without fighting other processes.
     PowerShell's Add-Content uses an opener that *retries* on a sharing
     violation, so a writer and a reader on a hot log file can stall each other
     for seconds (observed: the panel's /api/log handler hung while the daemon
     was appending fan.log). A FileStream with FileShare.ReadWrite never blocks. #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
      $b = [Text.Encoding]::UTF8.GetBytes($Text + [Environment]::NewLine)
      $fs.Write($b, 0, $b.Length)
      $fs.Flush($true)
    } finally { $fs.Dispose() }
  } catch { }
}

function New-DefaultConfig {
  # 曲线 = "温度:转速" 8 点，逗号分隔，X 轴为控制温度：
  #   CPU 侧用「近端 NTC 温度 + 负载预判」，GPU 侧用 EC GPU 温度（两者均已实测）
  # 本机 BIOS 自动档参考：安静≈3600 / 均衡≈4000 / 野兽≈4500（怠速），满速≈6600
  @{
    version      = 2
    safety       = @{
      rpm_floor        = 2400   # 任何情况下都不会命令低于此转速（风扇失速保护）
      rpm_ceiling      = 6600   # 实测满速 6400-6600，不越界写入
      nearcpu_crit     = 92     # >= : 强制满速
      gpu_crit         = 87     # >= : 强制满速
      write_gap_ms     = 1200   # 单次写入的底层节流
      min_write_gap_s  = 8      # 曲线调整两次写入的最小间隔（风扇升速要 ~12s，写太密没意义还会抖）
      reassert_gap_s   = 30     # 无偏差时定期重申目标的秒数
      deadband_up      = 200    # 目标比已写入值高这么多才升
      deadband_down    = 400    # 目标比已写入值低这么多才降（降得更保守，避免忽快忽慢）
      slew_rpm         = 900    # 单次写入最多变化这么多
      smooth_samples   = 5      # 控制温度滑动平均样本数（≈10s）
      manual_timeout_s = 180    # manual/boost 默认自动收尾秒数
      max_hold_s       = 900    # 「暂停接管/保持转速」最长多久，到点自动交还曲线（防止忘了）
      exit_rpm         = 4500   # 守护退出时写回的“交还值”= 野兽档怠速自动转速
    }
    power        = @{
      pl1 = 115 ; pl2 = 135     # 野兽模式 EC 默认功耗墙（本机会随温度自动浮动，可用 limit 覆盖）
      keep_pl = $false          # 是否由守护进程持续把 PL1/PL2 钉在上面的值
    }
    telemetry    = @{ cpu_source = 'nearcpu' ; cpu_offset = 0 ; use_nvidia_smi = $false }
    load_boost   = @{ per_10pct_util = 3.0 ; max_add_c = 16 ; window_s = 10 }  # CPU 高负载时预判升温，提前拉转
    active_profile = 'performance'
    profiles     = @{
      quiet       = @{ label = '安静' ; mode = 1 ; ceiling = 5000 ; hysteresis = 2
                       cpu = '70:2600,74:3000,77:3400,80:3900,83:4400,86:4800,89:5000,92:5000'
                       gpu = '60:2600,65:3000,70:3400,75:3900,80:4400,85:4800,88:5000,92:5000' }
      balanced    = @{ label = '均衡' ; mode = 2 ; ceiling = 5800 ; hysteresis = 2
                       cpu = '68:3000,72:3500,75:4000,78:4600,81:5100,84:5500,88:5800,92:5800'
                       gpu = '58:3000,63:3500,68:4000,73:4600,78:5100,83:5500,87:5800,92:5800' }
      performance = @{ label = '野兽' ; mode = 3 ; ceiling = 6600 ; hysteresis = 1
                       cpu = '66:3600,70:4200,74:4800,78:5400,82:6000,86:6400,90:6600,94:6600'
                       gpu = '56:3600,62:4200,68:4800,74:5400,80:6000,85:6400,90:6600,95:6600' }
      max         = @{ label = '满速' ; mode = 3 ; ceiling = 6600 ; hysteresis = 0
                       cpu = '0:6600,20:6600,40:6600,60:6600,80:6600,100:6600,120:6600,130:6600'
                       gpu = '0:6600,20:6600,40:6600,60:6600,80:6600,100:6600,120:6600,130:6600' }
      custom      = @{ label = '自定义' ; mode = 3 ; ceiling = 6600 ; hysteresis = 2
                       cpu = '68:3400,72:4000,76:4600,80:5200,84:5800,88:6200,92:6600,96:6600'
                       gpu = '58:3400,64:4000,70:4600,76:5200,82:5800,87:6200,92:6600,97:6600' }
    }
    panel = @{ host = '127.0.0.1' ; port = 4765 }
  }
}

function Get-FanConfig {
  [CmdletBinding()]param()
  if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
    if (-not (Test-Path -LiteralPath $script:ConfDir)) { New-Item -ItemType Directory -Force -Path $script:ConfDir | Out-Null }
    Save-FanConfig -Config (New-DefaultConfig)
  }
  $raw = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8
  try { $cfg = $raw | ConvertFrom-Json } catch {
    Write-FanLog "config.json 解析失败，已备份并重建: $($_.Exception.Message)" 'ERROR'
    Move-Item -LiteralPath $script:ConfigFile -Destination "$($script:ConfigFile).bad" -Force
    Save-FanConfig -Config (New-DefaultConfig)
    $cfg = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  # Version upgrade: recursively fill anything missing from the shipped defaults,
  # so an old config.json keeps working after a release adds a safety key
  # (e.g. max_hold_s) or a profile. Only *missing* keys are added — never overwritten.
  $def = New-DefaultConfig
  Merge-FanDefaults -Cfg $cfg -Def $def | Out-Null
  Repair-FanConfigCurves -Cfg $cfg -Def $def | Out-Null
  return $cfg
}

function Repair-FanConfigCurves {
  <# A curve string that Parse-FanCurve rejects would throw inside every control
     pass (the shipped v1 "满速" profile did exactly that with 0:6600 repeated),
     so the engine silently loses control. Swap in the shipped default for that
     one side and log it once per distinct bad value. #>
  [CmdletBinding()]param([Parameter(Mandatory)][object]$Cfg, [Parameter(Mandatory)][object]$Def)
  if (-not $script:HealSeen) { $script:HealSeen = @{} }
  $have = @(Get-FanDictKeys $Cfg.profiles)
  foreach ($pn in @(Get-FanDictKeys $Def.profiles)) {
    if ($pn -notin $have) { continue }
    foreach ($side in 'cpu', 'gpu') {
      $cur = "$($Cfg.profiles.$pn.$side)"
      $why = ''
      try { Parse-FanCurve -Spec $cur | Out-Null; continue } catch { $why = $_.Exception.Message }
      $fix = "$($Def.profiles[$pn][$side])"
      try { Parse-FanCurve -Spec $fix | Out-Null } catch { $fix = $null }
      if (-not $fix) { continue }
      $key = "$pn.$side|$cur"
      if (-not $script:HealSeen.ContainsKey($key)) {
        $script:HealSeen[$key] = $true
        Write-FanLog ("档位 {0}.{1} 曲线无效（{2}：{3}），本轮已临时改用默认 {4}，请在面板里修好它" -f $pn, $side, $cur, $why, $fix) 'WARN'
      }
      $Cfg.profiles.$pn | Add-Member -NotePropertyName $side -NotePropertyValue $fix -Force
    }
  }
  return $Cfg
}

function Merge-FanDefaults {
  <# Recursively add missing properties of $Cfg from $Def. Existing user values win. #>
  [CmdletBinding()]param([Parameter(Mandatory)][object]$Cfg, [object]$Def)
  if ($null -eq $Cfg -or $null -eq $Def) { return $Cfg }
  $keys = if ($Def -is [System.Collections.IDictionary]) { @($Def.Keys) } else { @($Def.PSObject.Properties.Name) }
  foreach ($k in $keys) {
    $dv = if ($Def -is [System.Collections.IDictionary]) { $Def[$k] } else { $Def.$k }
    if ($null -eq $Cfg.PSObject.Properties[$k]) {
      # Insert as PSCustomObject, not hashtable: hashtable keys are NOT visible through
      # PSObject.Properties in PS 5.1, so a mixed tree breaks every ".PSObject.Properties"
      # walk downstream (curve checking, self-heal, panel profile listing).
      $nv = $dv
      if ($dv -is [System.Collections.IDictionary] -or $dv -is [System.Management.Automation.PSCustomObject]) {
        $nv = ($dv | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
      }
      $Cfg | Add-Member -NotePropertyName $k -NotePropertyValue $nv
      continue
    }
    $cv = $Cfg.$k
    $dvIsDict = ($dv -is [System.Collections.IDictionary]) -or ($dv -is [System.Management.Automation.PSCustomObject])
    if ($dvIsDict -and $cv -is [System.Management.Automation.PSCustomObject]) { Merge-FanDefaults -Cfg $cv -Def $dv | Out-Null }
  }
  return $Cfg
}

function Flatten-FanObj {
  <# object -> flat "a.b[0].c" = scalar hashtable, for config diffs #>
  [CmdletBinding()]param([object]$O, [string]$Path = '')
  $out = @{}
  if ($null -eq $O) { if ($Path) { $out[$Path] = '<null>' }; return $out }
  $join = { param($base, $tail) if ($base) { "$base.$tail" } else { "$tail" } }
  if ($O -is [System.Collections.IDictionary]) {
    foreach ($k in @($O.Keys)) { foreach ($e in (Flatten-FanObj -O $O[$k] -Path (& $join $Path $k)).GetEnumerator()) { $out[$e.Name] = $e.Value } }
    return $out
  }
  if ($O -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $O.PSObject.Properties) { foreach ($e in (Flatten-FanObj -O $p.Value -Path (& $join $Path $p.Name)).GetEnumerator()) { $out[$e.Name] = $e.Value } }
    return $out
  }
  if ($O -isnot [string] -and $O -is [System.Collections.IEnumerable]) {
    $i = 0
    foreach ($e in $O) { foreach ($x in (Flatten-FanObj -O $e -Path "$Path[$i]").GetEnumerator()) { $out[$x.Name] = $x.Value }; $i++ }
    return $out
  }
  if ($Path) { $out[$Path] = "$O" }
  return $out
}

function Format-FanDiffValue([string]$V) {
  if ([string]::IsNullOrEmpty($V)) { return "''" }
  if ($V.Length -le 46) { return $V }
  return $V.Substring(0, 43) + '...'
}

function Save-FanConfig {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline)][object]$Config,
    [string]$Why = 'api'          # who changed it: panel / fanctl / daemon / module
  )
  process {
    if (-not (Test-Path -LiteralPath $script:ConfDir)) { New-Item -ItemType Directory -Force -Path $script:ConfDir | Out-Null }
    $old = $null
    if (Test-Path -LiteralPath $script:ConfigFile) {
      try { $old = [IO.File]::ReadAllText($script:ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $old = $null }
      Copy-Item -LiteralPath $script:ConfigFile -Destination (Join-Path $script:StateDir 'config.prev.json') -Force -ErrorAction SilentlyContinue
    }
    $json = if ($Config -is [string]) { $Config } else { $Config | ConvertTo-Json -Depth 10 }
    [IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object Text.UTF8Encoding $false))
    # Audit trail: every config write is logged as an old->new diff. A flattened
    # curve once froze the fans at 5800 RPM for hours and nothing recorded who did it.
    try {
      if ($old) {
        $a = Flatten-FanObj -O $old
        $b = Flatten-FanObj -O $Config
        $diff = New-Object System.Collections.ArrayList
        foreach ($k in @($b.Keys | Sort-Object)) {
          if (-not $a.ContainsKey($k)) { [void]$diff.Add("$k = $(Format-FanDiffValue "$($b[$k])")") }
          elseif ("$($a[$k])" -ne "$($b[$k])") { [void]$diff.Add("$k : $(Format-FanDiffValue "$($a[$k])") -> $(Format-FanDiffValue "$($b[$k])")") }
        }
        foreach ($k in @($a.Keys | Sort-Object)) { if (-not $b.ContainsKey($k)) { [void]$diff.Add("$k 已删除") } }
        if ($diff.Count) {
          $shown = @($diff | Select-Object -First 10) -join '; '
          $more = if ($diff.Count -gt 10) { " (共 $($diff.Count) 项)" } else { '' }
          Write-FanLog "配置变更[$Why] $shown$more" 'ACTION'
        }
      }
    } catch { Write-FanLog "配置差异记录失败: $($_.Exception.Message)" 'WARN' }
  }
}

function Set-FanActiveProfile {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$Name)
  $cfg = Get-FanConfig
  if (-not (Test-FanProfile -Config $cfg -Name $Name)) { throw "未知档位 '$Name'" }
  $cfg.active_profile = $Name
  Save-FanConfig -Config $cfg -Why 'set-profile'
  return $Name
}

# ---------------------------------------------------------------- 锁 / 单实例
function Test-FanProcessAlive { param([int]$ProcId) [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue) }

# A second copy of the whole folder (repo vs dist\...) has its own state\daemon.lock,
# so nothing stopped two daemons from different copies writing the EC at the same time.
# This extra lock always lives in %LOCALAPPDATA% and is shared by every copy on the box.
$script:GlobalLockFile = $null
if ($env:LOCALAPPDATA) {
  $g = Join-Path (Join-Path $env:LOCALAPPDATA 'LegionFanStudio') 'daemon.lock'
  if ($g -ne $script:LockFile) { $script:GlobalLockFile = $g }
}

function Read-FanLockFile([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $lk = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $lk) { return $null }
    return [pscustomobject]@{ who = "$($lk.who)"; pid = [int]$lk.pid; since = "$($lk.since)";
                              root = "$($lk.root)"; alive = (Test-FanProcessAlive -ProcId ([int]$lk.pid)) }
  } catch { return $null }
}

function Get-FanOtherCopyLock {
  <# a daemon from ANOTHER copy of this tool holding the shared lock? #>
  [CmdletBinding()]param()
  $g = Read-FanLockFile $script:GlobalLockFile
  if (-not $g -or -not $g.alive -or $g.pid -eq $PID) { return $null }
  return $g
}

function Get-FanLockState {
  [CmdletBinding()]param()
  if (-not (Test-Path -LiteralPath $script:LockFile)) { return $null }
  try {
    $lk = Get-Content -LiteralPath $script:LockFile -Raw | ConvertFrom-Json
    return [pscustomobject]@{ who = $lk.who; pid = [int]$lk.pid; since = $lk.since; alive = (Test-FanProcessAlive -ProcId ([int]$lk.pid)) }
  } catch { return [pscustomobject]@{ who = '?'; pid = 0; since = '?'; alive = $false } }
}

function Enter-FanLock {
  [CmdletBinding()]
  param([string]$Who = 'daemon', [switch]$Force)
  if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
  # refuse to start if another COPY of this tool is already driving the EC
  $other = Get-FanOtherCopyLock
  if ($other) {
    if (-not $Force) { throw "另一个副本的守护进程正在控制风扇：$($other.who) (pid=$($other.pid), 数据目录 $($other.root))。一台机器只能有一个 EC 写入者 —— 先在那份安装里 stop，或对本份加 -Force。" }
    Write-FanLog "覆盖另一份安装的锁：结束 $($other.who) pid=$($other.pid)" 'WARN'
    Stop-Process -Id $other.pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
  }
  $cur = Get-FanLockState
  if ($cur -and $cur.alive) {
    if (-not $Force) { throw "已有实例在运行：$($cur.who) (pid=$($cur.pid))。先 stop 或加 -Force。" }
    Write-FanLog "覆盖旧锁：结束 $($cur.who) pid=$($cur.pid)" 'WARN'
    Stop-Process -Id $cur.pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  } elseif ($cur) { Write-FanLog "发现失效锁 (pid=$($cur.pid))，清理" 'WARN' }
  $rec = [pscustomobject]@{ who = $Who; pid = $PID; since = (Get-Date -Format 'o'); root = $script:DataRoot } | ConvertTo-Json -Compress
  Set-Content -LiteralPath $script:LockFile -Value $rec -Encoding ASCII
  if ($script:GlobalLockFile) {
    $gd = Split-Path -Parent $script:GlobalLockFile
    if (-not (Test-Path -LiteralPath $gd)) { New-Item -ItemType Directory -Force -Path $gd | Out-Null }
    Set-Content -LiteralPath $script:GlobalLockFile -Value $rec -Encoding ASCII
  }
}

function Exit-FanLock {
  [CmdletBinding()]param()
  $cur = Get-FanLockState
  if ($cur -and $cur.pid -eq $PID) { Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue }
  if ($script:GlobalLockFile) {
    $g = Read-FanLockFile $script:GlobalLockFile
    if ($g -and $g.pid -eq $PID) { Remove-Item -LiteralPath $script:GlobalLockFile -Force -ErrorAction SilentlyContinue }
  }
}

# ---------------------------------------------------------------- WMI 通道
function Assert-FanAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '需要管理员权限（风扇 EC 写入）。用 fanctl.ps1 elevate 或右键以管理员运行。'
  }
}

function Connect-FanWmi {
  [CmdletBinding()]param([switch]$Quiet)
  $script:Obj = @{}
  $script:Scope = New-Object System.Management.ManagementScope('root\wmi')
  $script:Scope.Options.Timeout = [TimeSpan]::FromSeconds(15)
  try { $script:Scope.Options.EnablePrivileges = $true } catch { }
  $script:Scope.Connect()
  foreach ($cn in 'LENOVO_GAMEZONE_DATA', 'Lfc_thermal_interface', 'LENOVO_FAN_METHOD') {
    $sr = New-Object System.Management.ManagementObjectSearcher($script:Scope, (New-Object System.Management.ObjectQuery("SELECT * FROM $cn")))
    $coll = $sr.Get()
    if ($coll.Count -lt 1) { throw "本机没有 $cn 实例（不是 Legion Y9000P 2022？或非管理员权限）" }
    foreach ($o in $coll) { $script:Obj[$cn] = $o; break }
  }
  $info = ($script:Obj.Keys | ForEach-Object { "$_@$($script:Obj[$_]['InstanceName'])" }) -join '  '
  if (-not $Quiet) { Write-FanLog "EC 已连接: $info" }
  return $info
}

function Invoke-FanWmi {
  <#
    This provider rejects class-level calls, and zero-input methods return no
    __PARAMETERS object at all -> pass $null for those. Verified on 82RF.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Class,
    [Parameter(Mandatory)][string]$Method,
    [hashtable]$In = @{},
    [switch]$NoRetry
  )
  if (-not $script:Obj -or -not $script:Obj.ContainsKey($Class)) { Connect-FanWmi -Quiet | Out-Null }
  $obj = $script:Obj[$Class]
  try {
    $ip = $null
    try { $ip = $obj.GetMethodParameters($Method) } catch { $ip = $null }
    if ($null -ne $ip) { foreach ($k in $In.Keys) { $ip[$k] = $In[$k] } }
    $r = if ($null -eq $ip) { $obj.InvokeMethod($Method, [System.Management.ManagementBaseObject]$null, [System.Management.InvokeMethodOptions]$null) }
    else { $obj.InvokeMethod($Method, $ip, [System.Management.InvokeMethodOptions]$null) }
    $out = @{}
    if ($null -ne $r) { foreach ($p in $r.Properties) { $out[$p.Name] = $p.Value } }
    return $out
  } catch {
    if ($NoRetry) { throw }
    Write-FanLog "EC 调用异常 $Class.$Method : $($_.Exception.Message)（重连重试）" 'WARN'
    Connect-FanWmi -Quiet | Out-Null
    return Invoke-FanWmi -Class $Class -Method $Method -In $In -NoRetry
  }
}

function Get-FanValue {
  param([string]$Class, [string]$Method, [string]$Key, [hashtable]$In = @{}, [int]$Default = -999)
  $r = Invoke-FanWmi -Class $Class -Method $Method -In $In
  if ($r.Count -eq 0) { return $Default }
  $v = $r[$Key]
  if ($null -eq $v) { $v = ($r.Values | Select-Object -First 1) }
  if ($null -eq $v) { return $Default }
  return $v
}

# ---------------------------------------------------------------- 读：遥测
function Get-FanMode { [int](Get-FanValue -Class 'LENOVO_GAMEZONE_DATA' -Method 'GetSmartFanMode' -Key 'Data') }
function Get-FanFullSpeed { [bool](Get-FanValue -Class 'LENOVO_FAN_METHOD' -Method 'Fan_Get_FullSpeed' -Key 'Status') }
function Get-FanRpm { param([ValidateRange(1, 2)][int]$Fan = 1) [int](Get-FanValue -Class 'LENOVO_FAN_METHOD' -Method 'Fan_GetCurrentFanSpeed' -Key 'CurrentFanSpeed' -In @{FanID = [byte]$Fan }) }
function Get-FanLfcRpm { param([ValidateRange(1, 2)][int]$Fan = 1) [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method "GetFan$($Fan)Speed" -Key 'Data') }
function Get-FanNearCpuC { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetNearCPUTemperature' -Key 'Data') }
function Get-FanGpuC { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetGPUTemperature' -Key 'Data') }
function Get-FanNearGpuC { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetNearGPUTemperature' -Key 'Data') }
function Get-FanEnvC { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetEnvironmentTemperature' -Key 'Data') }
function Get-FanRamC { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetRAMTemperature' -Key 'Data') }
function Get-FanTjLimit { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetCPUTemperature' -Key 'Data') }
function Get-FanPl1 { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetPowerLimit1' -Key 'Data') }
function Get-FanPl2 { [int](Get-FanValue -Class 'Lfc_thermal_interface' -Method 'GetPowerLimit2' -Key 'Data') }
function Get-FanWmiVersion { [int](Get-FanValue -Class 'LENOVO_GAMEZONE_DATA' -Method 'GetVersion' -Key 'Data') }

function Get-FanCpuUtil {
  try {
    $v = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter 'Name="_Total"' -ErrorAction Stop).PercentProcessorTime
    if ($null -eq $v) { return -1 }
    return [math]::Min(100, [int]$v)
  } catch { return -1 }
}

function Get-FanSnapshot {
  <# one consistent read; never throws so the daemon/UI stay alive #>
  [CmdletBinding()]param()
  $s = [ordered]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); ok = $true; err = $null
    mode = -1; mode_name = '?'; full = $false
    rpm = -1; rpm_lfc = -1; near_cpu = -1; gpu_c = -1; near_gpu = -1; env_c = -1; ram_c = -1; tj = -1
    pl1 = -1; pl2 = -1; cpu_util = -1; target = -1
  }
  try {
    $m = Get-FanMode
    $s['mode'] = $m
    $s['mode_name'] = if ($ModeNames.ContainsKey($m)) { $ModeNames[$m] } else { "未知($m)" }
    $s['full'] = Get-FanFullSpeed
    $s['rpm'] = Get-FanRpm -Fan 1
    $s['rpm_lfc'] = Get-FanLfcRpm -Fan 1
    $s['near_cpu'] = Get-FanNearCpuC
    $s['gpu_c'] = Get-FanGpuC
    $s['near_gpu'] = Get-FanNearGpuC
    $s['env_c'] = Get-FanEnvC
    $s['ram_c'] = Get-FanRamC
    $s['tj'] = Get-FanTjLimit
    $s['pl1'] = Get-FanPl1
    $s['pl2'] = Get-FanPl2
    $s['cpu_util'] = Get-FanCpuUtil
  } catch { $s['ok'] = $false; $s['err'] = $_.Exception.Message }
  return [pscustomobject]$s
}

# ---------------------------------------------------------------- 写：控制
function Assert-FanWritable {
  [CmdletBinding()]param()
  Assert-FanAdmin
  $cfg = Get-FanConfig
  $gap = [int]$cfg.safety.write_gap_ms
  $since = ((Get-Date) - $script:LastWrite).TotalMilliseconds
  if ($since -lt $gap) { Start-Sleep -Milliseconds ([int]($gap - $since)) }
  $script:LastWrite = Get-Date
}

function Limit-FanRpm {
  param([int]$Rpm, [int]$Floor = 2400, [int]$Ceiling = 6600)
  if ($Rpm -le 0) { $Rpm = $Floor }
  [int][math]::Max($Floor, [math]::Min($Ceiling, $Rpm))
}

function Set-FanTargetRpm {
  <# EC 对两个风扇执行同一目标（实测同速），故双写；单位 = RPM #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$Rpm,
    [ValidateRange(1, 2)][int]$Fan = 0,      # 0 = 两个都写
    [switch]$SkipSafety
  )
  $cfg = Get-FanConfig
  # A missing/zero value must never become "spin the fans down to the floor".
  # (A malformed command once did exactly that, so this is now a hard reject.)
  if ($Rpm -le 0) { throw "无效的转速目标 '$Rpm'（必须是 > 0 的 RPM），已拒绝写入" }
  if (-not $SkipSafety) { Assert-FanWritable }
  $v = Limit-FanRpm -Rpm $Rpm -Floor ([int]$cfg.safety.rpm_floor) -Ceiling ([int]$cfg.safety.rpm_ceiling)
  $targets = if ($Fan -eq 0) { @(1, 2) } else { @($Fan) }
  foreach ($f in $targets) {
    $null = Invoke-FanWmi -Class 'Lfc_thermal_interface' -Method "SetFan$($f)Speed" -In @{Data = [uint32]$v }
  }
  Write-FanLog "目标转速 -> $v RPM (fan $(if ($Fan -eq 0) { '1+2' } else { $Fan }))" 'ACTION'
  return $v
}

function Set-FanFullSpeed {
  [CmdletBinding()]
  param([Parameter(Mandatory)][bool]$On, [switch]$SkipSafety)
  if (-not $SkipSafety) { Assert-FanWritable }
  $null = Invoke-FanWmi -Class 'LENOVO_FAN_METHOD' -Method 'Fan_Set_FullSpeed' -In @{Status = $On }
  Write-FanLog "满速锁定 -> $(if ($On) { 'ON' } else { 'off' })" 'ACTION'
  return $On
}

function Set-FanMode {
  [CmdletBinding()]
  param([Parameter(Mandatory)][ValidateRange(1, 4)][int]$Mode, [switch]$SkipSafety)
  if (-not $SkipSafety) { Assert-FanWritable }
  $null = Invoke-FanWmi -Class 'LENOVO_GAMEZONE_DATA' -Method 'SetSmartFanMode' -In @{Data = [uint32]$Mode }
  $back = Get-FanMode
  if ($back -ne $Mode) { Write-FanLog "Fn+Q 档位 $Mode 被 EC 拒绝（当前仍为 $back）" 'WARN' }
  else { Write-FanLog "Fn+Q 档位 -> $Mode ($($ModeNames[$Mode]))" 'ACTION' }
  return $back
}

function Set-FanPowerLimit {
  <# EC 级功耗墙：优先级高于 Windows 电源计划里的"最大处理器状态" #>
  [CmdletBinding()]
  param([int]$Pl1 = 0, [int]$Pl2 = 0, [switch]$SkipSafety)
  $cfg = Get-FanConfig
  if (-not $SkipSafety) { Assert-FanWritable }
  $did = @()
  if ($Pl1 -gt 0) {
    $v = [int][math]::Max(15, [math]::Min(200, $Pl1))
    $null = Invoke-FanWmi -Class 'Lfc_thermal_interface' -Method 'SetPowerLimit1' -In @{Data = [uint32]$v }
    $did += "PL1=$v"
  }
  if ($Pl2 -gt 0) {
    $v = [int][math]::Max(15, [math]::Min(200, $Pl2))
    $null = Invoke-FanWmi -Class 'Lfc_thermal_interface' -Method 'SetPowerLimit2' -In @{Data = [uint32]$v }
    $did += "PL2=$v"
  }
  if ($did.Count) { Write-FanLog "功耗墙 -> $($did -join ' ') W（EC 层，覆盖电源计划）" 'ACTION' }
  return [pscustomobject]@{ pl1 = Get-FanPl1; pl2 = Get-FanPl2 }
}

function Reset-FanNormal {
  <# 一键把机器交还给 BIOS 的正常表现：取消满速 + 档位 + 安全转速 + 功耗墙 #>
  [CmdletBinding()]
  param([switch]$SkipSafety)
  $cfg = Get-FanConfig
  if (-not $SkipSafety) { Assert-FanWritable }
  $null = Set-FanFullSpeed -On $false -SkipSafety
  $pname = [string]$cfg.active_profile
  $mode = 3
  if ($cfg.profiles.PSObject.Properties[$pname]) { $mode = [int]$cfg.profiles.$pname.mode }
  $null = Set-FanMode -Mode $mode -SkipSafety
  $exit = [int]$cfg.safety.exit_rpm
  $null = Set-FanTargetRpm -Rpm $exit -SkipSafety
  if ([bool]$cfg.power.keep_pl) { $null = Set-FanPowerLimit -Pl1 ([int]$cfg.power.pl1) -Pl2 ([int]$cfg.power.pl2) -SkipSafety }
  Write-FanLog "已恢复正常值：mode=$mode rpm=$exit（EC 手动值会保持，重启可回到 BIOS 全自动）" 'ACTION'
  return $exit
}

# ---------------------------------------------------------------- 曲线引擎
function Parse-FanCurve {
  <# "66:3600,70:4200,..." (or array of pairs) -> ordered @(@{Temp;Rpm}) #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][object]$Spec)
  $pts = New-Object System.Collections.ArrayList
  $add = { param($t, $r) [void]$pts.Add([pscustomobject]@{ Temp = [double]$t; Rpm = [int]$r }) }
  if ($Spec -is [string]) {
    foreach ($tok in ($Spec -split '[;,，；]')) {
      $t = $tok.Trim(); if (-not $t) { continue }
      $kv = $t -split '[:：]'
      if ($kv.Count -ne 2) { throw "曲线点格式错误: '$t'（应为 温度:转速）" }
      & $add $kv[0] $kv[1]
    }
  } else {
    foreach ($e in $Spec) {
      if ($e -is [array]) { & $add $e[0] $e[1] }
      elseif ($e -is [string]) { $kv = $e -split '[:：]'; if ($kv.Count -eq 2) { & $add $kv[0] $kv[1] } }
      elseif ($e.PSObject.Properties['Temp']) { & $add $e.Temp $e.Rpm }
      elseif ($e.PSObject.Properties['t']) { & $add $e.t $e.rpm }
      else { throw "无法解析曲线点: $e" }
    }
  }
  if ($pts.Count -lt 2) { throw "曲线至少需要 2 个点，当前 $($pts.Count)" }
  $sorted = @($pts | Sort-Object Temp)
  $prevT = [double]::NegativeInfinity
  foreach ($p in $sorted) {
    if ($p.Temp -le $prevT) { throw "曲线温度必须递增（$($p.Temp) 重复或倒序）" }
    if ($p.Temp -lt -20 -or $p.Temp -gt 130) { throw "曲线温度越界: $($p.Temp)" }
    if ($p.Rpm -lt 0 -or $p.Rpm -gt 9999) { throw "曲线转速越界: $($p.Rpm)" }
    $prevT = $p.Temp
  }
  return $sorted
}

function Format-FanCurve {
  [CmdletBinding()]param([object]$Points)
  (@($Points | ForEach-Object { "$($_.Temp):$($_.Rpm)" })) -join ','
}

function Get-FanDictKeys([object]$O) {
  <# member/key names that work for BOTH a hashtable (New-DefaultConfig) and a
     JSON-loaded PSCustomObject — hashtable keys are invisible to PSObject.Properties #>
  if ($null -eq $O) { return @() }
  if ($O -is [System.Collections.IDictionary]) { return @($O.Keys | ForEach-Object { "$_" }) }
  return @($O.PSObject.Properties.Name)
}

function Test-FanProfile {
  <# profile exists? works for a hashtable (New-DefaultConfig) and a JSON object #>
  [CmdletBinding()]param([object]$Config, [string]$Name)
  if ($null -eq $Config -or $null -eq $Config.profiles) { return $false }
  if ($Config.profiles -is [System.Collections.IDictionary]) { return $Config.profiles.Contains($Name) }
  return $null -ne $Config.profiles.PSObject.Properties[$Name]
}

function Get-FanCurveIssue {
  <# Human-readable warnings about the curves in a config. A flat curve that is NOT
     the profile ceiling is almost always an accident (a dragged slider saved onto
     every point), because it pins the fans at one speed regardless of temperature. #>
  [CmdletBinding()]param([object]$Config = $null)
  if (-not $Config) { $Config = Get-FanConfig }
  $res = New-Object System.Collections.ArrayList
  foreach ($pn in @(Get-FanDictKeys $Config.profiles)) {
    $p = $Config.profiles.$pn
    if ($null -eq $p) { continue }
    foreach ($side in 'cpu', 'gpu') {
      $spec = "$($p.$side)"
      if (-not $spec.Trim()) { [void]$res.Add("$pn.$side 曲线为空"); continue }
      $pts = $null; $why = ''
      try { $pts = Parse-FanCurve -Spec $spec } catch { $why = $_.Exception.Message }
      if ($why) { [void]$res.Add("$pn.$side 曲线无效: $why"); continue }
      $uniq = @($pts | ForEach-Object { $_.Rpm } | Select-Object -Unique)
      if ($uniq.Count -eq 1 -and [int]$uniq[0] -ne [int]$p.ceiling) {
        [void]$res.Add("$pn.$side 整条曲线恒定为 $($uniq[0]) RPM（上限是 $($p.ceiling)，恒定值一般只在「满速」档出现，疑似误改）")
      }
    }
  }
  return [string[]]$res
}

function Resolve-FanCurve {
  <# piecewise-linear interpolation over the curve points, clamped #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Steps,
    [Parameter(Mandatory)][double]$Temp,
    [int]$Floor = 2400,
    [int]$Ceiling = 6600
  )
  $pts = Parse-FanCurve -Spec $Steps
  if ($Temp -le $pts[0].Temp) { return (Limit-FanRpm -Rpm $pts[0].Rpm -Floor $Floor -Ceiling $Ceiling) }
  $last = $pts[$pts.Count - 1]
  if ($Temp -ge $last.Temp) { return (Limit-FanRpm -Rpm $last.Rpm -Floor $Floor -Ceiling $Ceiling) }
  for ($i = 0; $i -lt $pts.Count - 1; $i++) {
    $a = $pts[$i]; $b = $pts[$i + 1]
    if ($Temp -lt $a.Temp -or $Temp -gt $b.Temp) { continue }
    $span = $b.Temp - $a.Temp
    if ($span -le 0) { return (Limit-FanRpm -Rpm $b.Rpm -Floor $Floor -Ceiling $Ceiling) }
    $f = ($Temp - $a.Temp) / $span
    return (Limit-FanRpm -Rpm ([int]($a.Rpm + $f * ($b.Rpm - $a.Rpm))) -Floor $Floor -Ceiling $Ceiling)
  }
  return (Limit-FanRpm -Rpm $last.Rpm -Floor $Floor -Ceiling $Ceiling)
}

function Get-FanControlTemp {
  <# CPU 侧控制温度 = 近端 NTC + 负载预判（NTC 热惯性大，负载先动让风扇先转） #>
  [CmdletBinding()]
  param([double]$NearCpu, [int]$CpuUtil = -1, [object]$Config = $null)
  if (-not $Config) { $Config = Get-FanConfig }
  $t = $NearCpu + [double]$Config.telemetry.cpu_offset
  if ($CpuUtil -gt 0 -and [double]$Config.load_boost.per_10pct_util -gt 0) {
    $add = ([double]$CpuUtil / 10.0) * [double]$Config.load_boost.per_10pct_util
    $t += [math]::Min([double]$Config.load_boost.max_add_c, $add)
  }
  return [math]::Round($t, 1)
}

function Get-FanDesiredRpm {
  <# profile -> target RPM from current temps; returns @{rpm;cpu_t;gpu_t;why} #>
  [CmdletBinding()]
  param(
    [string]$Profile = '',
    [pscustomobject]$Snap = $null,
    [object]$Config = $null        # pass New-DefaultConfig (or any config) to test offline
  )
  $cfg = if ($Config) { $Config } else { Get-FanConfig }
  if (-not $Profile) { $Profile = [string]$cfg.active_profile }
  if (-not (Test-FanProfile -Config $cfg -Name $Profile)) { throw "未知档位 '$Profile'" }
  $p = $cfg.profiles.$Profile
  if (-not $Snap) { $Snap = Get-FanSnapshot }
  $floor = [int]$cfg.safety.rpm_floor
  $ceil = [int]$cfg.safety.rpm_ceiling
  $cap = [int]$p.ceiling; if ($cap -lt $floor -or $cap -gt $ceil) { $cap = $ceil }
  $cpuT = Get-FanControlTemp -NearCpu $Snap.near_cpu -CpuUtil $Snap.cpu_util -Config $cfg
  $gpuT = [double]$Snap.gpu_c
  $rpmCpu = Resolve-FanCurve -Steps $p.cpu -Temp $cpuT -Floor $floor -Ceiling $cap
  $rpmGpu = Resolve-FanCurve -Steps $p.gpu -Temp $gpuT -Floor $floor -Ceiling $cap
  $rpm = [math]::Max($rpmCpu, $rpmGpu)
  $why = if ($rpmGpu -ge $rpmCpu) { 'GPU 曲线' } else { 'CPU 曲线' }
  if ([double]$Snap.near_cpu -ge [double]$cfg.safety.nearcpu_crit -or [double]$Snap.gpu_c -ge [double]$cfg.safety.gpu_crit) {
    $rpm = $ceil; $why = '过温强制'
  }
  return [pscustomobject]@{ profile = $Profile; rpm = [int]$rpm; cpu_temp_basis = $cpuT; gpu_temp = $gpuT; rpm_from_cpu = $rpmCpu; rpm_from_gpu = $rpmGpu; why = $why; ceiling = $cap }
}

# ---------------------------------------------------------------- 历史
function Add-FanHistory {
  [CmdletBinding()]
  param([pscustomobject]$Snap, [int]$Target = -1, [string]$Note = '')
  if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
  $csv = Join-Path $script:LogDir 'history.csv'
  if (-not (Test-Path -LiteralPath $csv)) {
    'time,mode,near_cpu,gpu_c,rpm,target,rpm_lfc,pl1,pl2,cpu_util,note' | Set-Content -LiteralPath $csv -Encoding UTF8
  }
  Add-SharedText -Path $csv -Text (
    '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f $Snap.time, $Snap.mode, $Snap.near_cpu, $Snap.gpu_c, $Snap.rpm, $Target, $Snap.rpm_lfc, $Snap.pl1, $Snap.pl2, $Snap.cpu_util, $Note)
  # keep history bounded (~2 MB) without ever racing another writer
  try {
    if ((Get-Item -LiteralPath $csv).Length -gt 2MB) {
      Move-Item -LiteralPath $csv -Destination (Join-Path $script:LogDir ("history.{0}.csv" -f (Get-Date -Format 'yyyyMMddHHmmss'))) -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Get-SharedTailLines {
  <# Read the last N lines of a file that ANOTHER process is appending to.
     Get-Content -Tail deadlocks/blocks against a live writer (observed: the
     panel hung on /api/log while the daemon was appending fan.log).
     Opens with FileShare.ReadWrite and only reads the tail bytes. #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Count = 40,
    [int]$MaxBytes = 262144
  )
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      if ($len -eq 0) { return @() }
      $take = [math]::Min($len, [int]$MaxBytes)
      $fs.Seek(-$take, [IO.SeekOrigin]::End) | Out-Null
      $buf = New-Object byte[] $take
      $read = 0
      while ($read -lt $take) {
        $n = $fs.Read($buf, $read, $take - $read)
        if ($n -le 0) { break }
        $read += $n
      }
      $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
      $lines = @($text -split "`r?`n")
      if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
      if ($take -lt $len -and $lines.Count -gt 0) { $lines = $lines[1..($lines.Count - 1)] }   # first line may be truncated
      if ($lines.Count -gt $Count) { $lines = $lines[($lines.Count - $Count)..($lines.Count - 1)] }
      return [string[]]$lines
    } finally { $fs.Dispose() }
  } catch {
    Write-FanLog "读取尾部失败 $Path : $($_.Exception.Message)" 'WARN'
    return @()
  }
}

function Get-FanHistory {
  [CmdletBinding()]
  param([int]$Tail = 40)
  Get-SharedTailLines -Path (Join-Path $script:LogDir 'history.csv') -Count $Tail
}

Export-ModuleMember -Function Write-FanLog, Get-FanConfig, Save-FanConfig, New-DefaultConfig, Set-FanActiveProfile,
  Connect-FanWmi, Invoke-FanWmi, Assert-FanAdmin, Assert-FanWritable,
  Get-FanMode, Get-FanFullSpeed, Get-FanRpm, Get-FanLfcRpm, Get-FanNearCpuC, Get-FanGpuC, Get-FanNearGpuC,
  Get-FanEnvC, Get-FanRamC, Get-FanTjLimit, Get-FanPl1, Get-FanPl2, Get-FanWmiVersion, Get-FanCpuUtil, Get-FanSnapshot,
  Set-FanTargetRpm, Set-FanFullSpeed, Set-FanMode, Set-FanPowerLimit, Reset-FanNormal,
  Limit-FanRpm, Resolve-FanCurve, Parse-FanCurve, Format-FanCurve, Get-FanCurveIssue, Get-FanControlTemp, Get-FanDesiredRpm,
  Merge-FanDefaults, Flatten-FanObj, Repair-FanConfigCurves, Test-FanProfile, Get-FanDictKeys,
  Enter-FanLock, Exit-FanLock, Get-FanLockState, Test-FanProcessAlive, Get-FanOtherCopyLock, Read-FanLockFile,
  Add-FanHistory, Get-FanHistory, Get-SharedTailLines, Add-SharedText -Variable 'Root', 'LogDir', 'StateDir', 'ConfDir', 'ConfigFile', 'ModeNames'
