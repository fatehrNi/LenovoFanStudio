@echo off
rem Open the local tuning dashboard (no admin needed)
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\panel.ps1"
