@echo off
rem Launch the tray app. It has NO window: look at the taskbar corner (right side,
rem maybe inside the small "^" overflow) and right-click the fan icon.
set "EXE=%~dp0LegionFanStudio.exe"
if not exist "%EXE%" for /d %%D in ("%~dp0dist\LegionFanStudio-v*") do set "EXE=%%D\LegionFanStudio.exe"
if not exist "%EXE%" (
  echo LegionFanStudio.exe not found - run:  powershell -ExecutionPolicy Bypass -File builduild.ps1
  pause
  exit /b 1
)
start "" "%EXE%"
echo Started: %EXE%
echo If the icon is hidden, click the "^" arrow in the taskbar corner.
timeout /t 4 >nul
