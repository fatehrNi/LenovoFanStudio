@echo off
rem Full hardware verification: offline unit tests + on-machine smoke +
rem install/uninstall round trip + packaged-artifact check.
rem It deliberately drives the fans through a test sequence, then leaves the
rem daemon running and the machine at normal values. Asks for admin once.
net session >/dev/null 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0toolsinal_verify.ps1' *>&1 | Tee-Object -FilePath '%~dp0logserify_all.log' ; & '%~dp0tools\dist_verify.ps1' *>&1 | Tee-Object -FilePath '%~dp0logserify_all.log' -Append"
echo.
echo Full output: %~dp0logserify_all.log
pause
