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

:: No elevation. Every action the app performs -- shutdown, restart, sleep,
:: hibernate, the tray hotkey, and registering its own scheduled tasks -- works
:: on a standard user token. The only thing that needs administrator rights is
:: the opt-in "run even when I'm signed out" schedule, which asks for approval
:: at the moment it is used rather than for the whole session.

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%" %*
endlocal
