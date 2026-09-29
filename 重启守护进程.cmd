@echo off
rem Restart the daemon so it picks up code/config changes (asks for admin once)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0srcanctl.ps1" daemon restart
pause
