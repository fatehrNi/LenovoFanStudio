@echo off
rem Restore normal fan behaviour: release full-speed, re-apply Fn+Q, write a safe RPM
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0srcanctl.ps1" reset
pause
