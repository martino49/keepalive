@echo off
REM KeepAlive launcher: no arguments opens the GUI; any argument is passed to
REM the command-line version (e.g. KeepAlive.bat -ActiveMinutes 30 -RestMinutes 5)
if "%~1"=="" (
    powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0KeepAliveUI.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0KeepAlive.ps1" %*
)
