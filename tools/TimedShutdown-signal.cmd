@echo off
REM ---------------------------------------------------------------------------
REM  TimedShutdown-signal.cmd  [name]
REM
REM  Raises a signal that an armed "signal file appears" trigger will act on.
REM  Default name is "done", giving:
REM
REM      %LOCALAPPDATA%\TimedShutdown\signals\done.flag
REM
REM  The destination is absolute, so this works no matter what working directory
REM  the calling tool happens to use - hook processes launch with surprising ones.
REM
REM  The app DELETES the flag when it consumes it. Write it and leave it there:
REM  a flag created and removed by the producer between two one-second polls is
REM  never seen.
REM
REM  Exits 1 if the flag could not be written, so a calling script can tell.
REM ---------------------------------------------------------------------------
setlocal

set "NAME=%~1"
if "%NAME%"=="" set "NAME=done"

set "SIGDIR=%LOCALAPPDATA%\TimedShutdown\signals"
set "SIGFILE=%SIGDIR%\%NAME%.flag"

if not exist "%SIGDIR%" mkdir "%SIGDIR%" 2>nul
if not exist "%SIGDIR%" (
    echo [TimedShutdown] could not create "%SIGDIR%" 1>&2
    exit /b 1
)

echo %DATE% %TIME%> "%SIGFILE%"
if not exist "%SIGFILE%" (
    echo [TimedShutdown] could not write "%SIGFILE%" 1>&2
    exit /b 1
)

echo [TimedShutdown] signalled: %SIGFILE%
exit /b 0
