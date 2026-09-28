@echo off
rem Stops ClipBridge and removes it from Windows startup. Files you received are not touched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClipBridge.ps1" -Uninstall
echo.
pause
