param(
  [Parameter(Mandatory)][string]$Command,     # e.g. "& $fanctl dump"   (PowerShell syntax)
  [string]$Log = 'logs\elev.log',
  [switch]$Show,
  [switch]$NoWait                            # return immediately; poll the Log file for results
)
# Run PowerShell code elevated (UAC) and capture EVERY stream into a UTF-8 file.
# Available inside $Command:  $fanctl (src\fanctl.ps1), $root (repo root), $panel (src\panel.ps1)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logFull = Join-Path $root $Log
New-Item -ItemType Directory -Force -Path (Split-Path $logFull) | Out-Null

$template = @'
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$root = '{ROOT}'
$fanctl = Join-Path $root 'src\fanctl.ps1'
$panel = Join-Path $root 'src\panel.ps1'
$log = '{LOG}'
$cmd = '{CMD}'
try {
  & ([ScriptBlock]::Create($cmd)) *>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { "ERR: " + ($_.Exception.Message -replace "`r?`n", ' ') + "  @ " + $_.InvocationInfo.PositionMessage } else { ($_ | Out-String).TrimEnd() } } |
    Where-Object { $_ -ne '' } | Out-File -FilePath $log -Encoding utf8
} catch {
  ("OUTER FAILURE: " + ($_ | Out-String)) | Out-File -FilePath $log -Encoding utf8 -Append
}
"EXIT" | Add-Content -LiteralPath $log
'@
$esc = $Command.Replace("'", "''")
$body = $template.Replace('{ROOT}', $root).Replace('{LOG}', $logFull).Replace('{CMD}', $esc)
$tmp = Join-Path $PSScriptRoot '.elevrun-inner.ps1'
[IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding $true))

Remove-Item -LiteralPath $logFull -Force -ErrorAction SilentlyContinue
if ($NoWait) {
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"")
  "started pid=$($p.Id) (not waiting; read $Log when ready)"
  exit 0
}
$p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"")
if (Test-Path -LiteralPath $logFull) {
  if ($Show) { Get-Content -LiteralPath $logFull } else { "[captured elevated output -> $logFull]" }
} else {
  Write-Host "elevated run produced no log (exit=$($p.ExitCode)). Inner script:" -ForegroundColor Red
  Get-Content -LiteralPath $tmp
}
