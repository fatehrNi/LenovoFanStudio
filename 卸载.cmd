@echo off
rem Remove the scheduled task and restore normal fan values (elevates itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
