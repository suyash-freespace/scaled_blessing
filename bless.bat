@echo off
REM ---------------------------------------------------------------------------
REM Operator wrapper for bless_rig.ps1, for use from cmd.exe.
REM
REM   bless 2,3,4                        stations 2, 3 and 4 (region US915)
REM   bless 1,3 -Region EU868            stations 1 and 3 as EU868
REM   bless 2,3,4 -DryRun                print the launch plan, touch no hardware
REM   bless 2,3,4 -KeepLogs              keep each station's output for diagnosis
REM   bless -Stations 2,3,4 -Freq 8000   any bless_rig.ps1 parameter works
REM
REM   bless 3,4 -Keys "3=<32 hex>:<16 hex>,4=<32 hex>:<16 hex>"
REM                                      per-blessing key material
REM
REM Only -DeviceList and -ReadVerdict are pre-filled. EVERYTHING else is forwarded
REM verbatim, so -Region, -Keys, -KeepLogs, -Freq and the rest all work unchanged
REM (both quoted and unquoted - verified).
REM
REM Everything is forwarded verbatim via %*, NOT parsed positionally. That matters:
REM cmd.exe treats a comma as an argument separator, so "bless 2,3,4" read through
REM %1 %2 %3 arrives as three separate arguments and the 3 binds to -Region. %* is
REM the raw remainder of the command line, so the comma list survives intact.
REM
REM Paths are built from %~dp0 (this file's own directory), so it works from any
REM working directory - a wrong CWD is the usual cause of "is not recognized".
REM
REM In production the blessing service calls bless_rig.ps1 directly, because it has
REM to read each DevEUI and register the keys with the LNS before flashing. This
REM wrapper is for bench runs.
REM ---------------------------------------------------------------------------
setlocal

if "%~1"=="" goto usage

REM Allow the short form "bless 2,3,4" as well as the explicit "-Stations 2,3,4":
REM if the first character is not a dash, assume a bare station list.
set "ARGS=%*"
if not "%ARGS:~0,1%"=="-" set "ARGS=-Stations %ARGS%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bless_rig.ps1" ^
  -DeviceList "%~dp0rig_devices.csv" -ReadVerdict %ARGS%
set RC=%ERRORLEVEL%

REM A dry run also exits 0, so do not claim devices passed when nothing was flashed.
echo %ARGS% | findstr /i /c:"-DryRun" >nul
if not errorlevel 1 exit /b %RC%

echo.
if %RC% EQU 0 echo RESULT: all selected device^(s^) PASSED
if %RC% EQU 1 echo RESULT: setup or validation error - nothing was flashed
if %RC% EQU 2 echo RESULT: at least one device did not pass
if %RC% GTR 2 echo RESULT: unexpected exit code %RC%
exit /b %RC%

:usage
echo Usage: bless ^<stations^> [bless_rig.ps1 flags]
echo.
echo   stations   comma-separated, e.g. 2,3,4    ^(NOT space-separated^)
echo.
echo Examples:
echo   bless 2,3,4
echo   bless 1,3 -Region EU868
echo   bless 2,3,4 -DryRun
echo   bless 2,3,4 -KeepLogs
echo   bless 3,4 -Keys "3=APPKEY32HEX:JOINEUI16HEX,4=APPKEY32HEX:JOINEUI16HEX"
echo.
echo Any bless_rig.ps1 parameter is forwarded as-is. Region defaults to US915.
echo Every launch MASS ERASES its device. Dry-run first if unsure.
exit /b 1
