@echo off
rem Starts ClipBridge in the background: look for its clipboard icon in the system tray, next to the clock.
rem Starting it again replaces the copy that is already running.
start "ClipBridge" /min powershell -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ClipBridge.ps1" %*
