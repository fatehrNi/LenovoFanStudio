@echo off
rem Start the fan daemon - the single EC writer (asks for admin once)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0srcanctl.ps1" daemon start
pause
