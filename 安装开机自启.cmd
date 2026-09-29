@echo off
rem Register the logon scheduled task (install.ps1 elevates itself)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
