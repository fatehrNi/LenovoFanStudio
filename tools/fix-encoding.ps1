param(
  [string]$Path = '.',
  [switch]$DryRun            # report only, exit 1 if anything lacks a BOM (used by CI)
)
# Windows PowerShell 5.1 (and csc.exe) decode BOM-less files with the system ANSI
# codepage — GBK on this zh-CN machine — which silently corrupts Chinese literals.
# Every .ps1 / .psm1 / .cs in this repo must be UTF-8 *with* BOM.
#
# NB: filter by Extension client-side. `Get-ChildItem -LiteralPath <dir> -Include …`
# silently ignores -Include, which once made this tool rewrite runtime JSON files.
$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $Path).Path

$exts = @('.ps1', '.psm1', '.psd1', '.cs')
$skipDirs = @('\dist\', '\state\', '\logs\', '\build\obj\', '\.git\')

if ((Get-Item -LiteralPath $target).PSIsContainer) {
  $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      ($exts -contains $_.Extension) -and
      -not ($skipDirs | Where-Object { $_.FullName -like "*$_*" })
    })
} else {
  $files = @(Get-Item -LiteralPath $target)
  if ($files.Count -eq 1 -and $DryRun -and -not ($exts -contains $files[0].Extension)) {
    Write-Output "skip (not a source file): $($files[0].Name)"
    exit 0
  }
}

$changed = 0
foreach ($f in $files) {
  try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { Write-Output "SKIP (locked) $($f.FullName)"; continue }
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if ($hasBom) { continue }
  if ($DryRun) {
    Write-Output "NEEDS BOM: $($f.FullName)"
    $changed++
    continue
  }
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  [IO.File]::WriteAllText($f.FullName, $text, (New-Object Text.UTF8Encoding $true))
  Write-Output "BOM added: $($f.FullName)"
  $changed++
}

if ($DryRun) {
  if ($changed) { Write-Output "dry-run: $changed file(s) lack a BOM"; exit 1 }
  Write-Output 'dry-run: all sources are UTF-8 with BOM'
  exit 0
}
Write-Output "done, $changed file(s) fixed (scanned $($files.Count) source files)"
