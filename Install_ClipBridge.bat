@echo off
rem Makes ClipBridge start automatically when you sign in to Windows (for your user only,
rem no admin rights needed) and starts it now. Run it again after moving the ClipBridge folder.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ClipBridge.ps1" -Install %*
echo.
pause
