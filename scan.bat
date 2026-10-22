@echo off
REM ---------------------------------------------------------------------------
REM Operator wrapper for scan_rig.ps1. Reports the DevEUI of every device on the
REM bench. Reads only - no device is erased or written, so this is always safe.
REM
REM   scan                               every station in the device list
REM   scan 2,3                           stations 2 and 3 only
REM   scan -Json                         JSON on stdout, for the blessing service
REM   scan 2,3 -Freq 8000                any scan_rig.ps1 parameter works
REM
REM Exists for the same reason bless.bat does: this machine runs with the default
REM Restricted execution policy, so ".\scan_rig.ps1" is refused with
REM "running scripts is disabled on this system". The -ExecutionPolicy Bypass
REM below applies to this one process only and changes no machine setting.
REM
REM Only -DeviceList is pre-filled. Everything else is forwarded verbatim via %*,
REM NOT parsed positionally, because cmd.exe treats a comma as an argument
REM separator - "scan 2,3,4" read through %1 %2 %3 would arrive as three separate
REM arguments and the 3 would bind to the next parameter.
REM
REM Paths are built from %~dp0 (this file's own directory), so it works from any
REM working directory. A wrong CWD is the usual cause of "is not recognized".
REM ---------------------------------------------------------------------------
setlocal

if "%~1"=="/?" goto usage
if "%~1"=="-?" goto usage
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage

REM No arguments is the normal case here - it scans the whole bench. Test that
REM BEFORE touching %ARGS:~0,1%, or an empty list becomes a bare "-Stations" with
REM no value and the script refuses to start.
set "ARGS=%*"
if not defined ARGS goto run

REM Allow the short form "scan 2,3" as well as the explicit "-Stations 2,3": if the
REM first character is not a dash, assume a bare station list.
if not "%ARGS:~0,1%"=="-" set "ARGS=-Stations %ARGS%"

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan_rig.ps1" ^
  -DeviceList "%~dp0rig_devices.csv" %ARGS%
set RC=%ERRORLEVEL%

REM Under -Json the caller is parsing stdout, so print nothing after the JSON.
echo %ARGS% | findstr /i /c:"-Json" >nul
if not errorlevel 1 exit /b %RC%

echo.
if %RC% EQU 0 echo RESULT: every listed station reported a DevEUI
if %RC% EQU 1 echo RESULT: setup error - no device was read
if %RC% EQU 2 echo RESULT: a station is empty, or a DevEUI read failed
if %RC% GTR 2 echo RESULT: unexpected exit code %RC%
exit /b %RC%

:usage
echo Usage: scan [stations] [scan_rig.ps1 flags]
echo.
echo   stations   comma-separated, e.g. 2,3    ^(NOT space-separated^)
echo              omit to scan every station in the device list
echo.
echo Examples:
echo   scan
echo   scan 2,3
echo   scan -Json
echo.
echo Reads only - no device is erased or written.
echo Exit codes: 0 all listed stations answered, 1 setup error,
echo             2 a station is empty or a DevEUI read failed.
exit /b 1
