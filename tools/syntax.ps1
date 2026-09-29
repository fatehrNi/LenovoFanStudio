param([string[]]$Files)
foreach ($f in $Files) {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f).Path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { "FAIL $f"; $errs | ForEach-Object { "   line $($_.Extent.StartLineNumber): $($_.Message)" } }
  else { "OK   $f" }
}
