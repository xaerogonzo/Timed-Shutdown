@echo off
setlocal

:: Prefer the bundled single-file build; fall back to running from src\ directly
:: so the app still starts in a fresh checkout before build.ps1 has been run.
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%dist\TimedShutdown.ps1"
if not exist "%PS1%" set "PS1=%SCRIPT_DIR%src\Main.ps1"

if not exist "%PS1%" (
    echo Could not find dist\TimedShutdown.ps1 or src\Main.ps1.
    echo Run build.bat first, or check that this file sits in the project root.
    pause
    exit /b 1
)

:: Check for administrator privileges (fltMC is instant and spawns no window)
fltMC >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%" %*
endlocal
