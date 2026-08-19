@echo off
REM Launcher for build.ps1 - bundles src\ into dist\TimedShutdown.ps1.
REM Bypasses execution policy and keeps the window open so output stays visible.
REM Pass -FixEncoding to re-save any source file that lost its UTF-8 BOM.
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0build.ps1" %*
pause
