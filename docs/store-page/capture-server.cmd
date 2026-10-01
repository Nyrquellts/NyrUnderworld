@echo off
setlocal EnableDelayedExpansion
REM A server for recording, on its own port, staged from the shipping file set.
REM Invoked exactly the way tools\devserver.cmd invokes it, because that is the
REM call that is known to satisfy the licence handshake.
REM
REM The key is read from the environment and passed on the command line. It is
REM never written to the config and never echoed.

set "SESSION=%LOCALAPPDATA%\NyrUnderworld\capture3"
set "VENDOR=C:\Dev\NyrsBBDevKit\vendor\bin"

if "%FIVEM_LICENSE_KEY%"=="" (
    echo FIVEM_LICENSE_KEY is not set in this window.
    exit /b 1
)

for /d %%D in ("%VENDOR%\cfx-server-*") do set "EXE=%%D\cfx-server.exe"
if not exist "!EXE!" ( echo no enhanced server under %VENDOR% & exit /b 1 )

cd /d "%SESSION%"
"!EXE!" +set onesync on +set sv_licenseKey "%FIVEM_LICENSE_KEY%" +exec server.cfg
endlocal
