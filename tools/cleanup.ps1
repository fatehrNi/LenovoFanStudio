param([switch]$DryRun)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$pat = 'panel\.ps1|daemon\.ps1'
$mine = $PID
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
  $_.ProcessId -ne $mine -and $_.CommandLine -match $pat -and $_.CommandLine -notmatch 'cleanup\.ps1'
}
if (-not $procs) { '（命令行匹配里没有面板/守护进程）' }
foreach ($p in $procs) {
  "发现 pid=$($p.ProcessId)  cmd=$($p.CommandLine)"
  if (-not $DryRun) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    "  已结束"
  }
}
# also kill whoever holds the daemon lock: a daemon started as `& daemon.ps1` from a
# wrapper script does NOT have daemon.ps1 in its own command line, so the match above misses it
$lock = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\daemon.lock'
if (Test-Path -LiteralPath $lock) {
  try {
    $lk = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
    if (Get-Process -Id ([int]$lk.pid) -ErrorAction SilentlyContinue) {
      "锁里的进程还活着: pid=$($lk.pid) ($($lk.who))"
      if (-not $DryRun) {
        Stop-Process -Id ([int]$lk.pid) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if (Get-Process -Id ([int]$lk.pid) -ErrorAction SilentlyContinue) { "  仍在运行（可能权限不足），请手动结束" } else { "  已结束" }
      }
    }
  } catch { "锁文件解析失败: $($_.Exception.Message)" }
}
if ((Test-Path -LiteralPath $lock) -and -not $DryRun) {
  $lk = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json
  if (-not (Get-Process -Id ([int]$lk.pid) -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $lock -Force; "清理失效锁 (pid=$($lk.pid))" }
}
'CLEAN_DONE'
