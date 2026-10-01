@echo off
setlocal
REM ---------------------------------------------------------------------------
REM Start the city and join it. One command, from nothing to standing in it.
REM
REM   tools\play.cmd            GTA V Enhanced  (the game installed here)
REM   tools\play.cmd legacy     GTA V Legacy
REM
REM This launches GTA V and takes over the screen. Run it when you are ready to
REM sit down with it.
REM ---------------------------------------------------------------------------

set "FLAVOUR=%~1"
if "%FLAVOUR%"=="" set "FLAVOUR=enhanced"

if /I "%FLAVOUR%"=="enhanced" (
    set "CLIENT=%LOCALAPPDATA%\FiveM for GTAV Enhanced\FiveM.exe"
) else (
    set "CLIENT=%LOCALAPPDATA%\FiveM\FiveM.exe"
)

if not exist "%CLIENT%" (
    echo.
    echo   No %FLAVOUR% client here:
    echo     %CLIENT%
    echo.
    echo   The two clients are separate downloads and separate programs, both
    echo   linked from the front page of https://fivem.net:
    echo     Legacy    needs GTA V Legacy installed
    echo     Enhanced  needs GTA V Enhanced installed
    echo.
    exit /b 1
)

if "%FIVEM_LICENSE_KEY%"=="" (
    echo.
    echo   FIVEM_LICENSE_KEY is not set in this window. Set it and run again:
    echo.
    echo       set FIVEM_LICENSE_KEY=cfxk_your_key_here
    echo.
    exit /b 1
)

echo   starting the server ...
start "NYR UNDERWORLD server" cmd /k "%~dp0devserver.cmd" %FLAVOUR%

REM Long enough for the server to scan resources and start nyr_underworld.
REM Connecting earlier only means the client waits.
timeout /t 14 /nobreak >nul

echo   connecting ...
REM The Enhanced client registers the cfx:// scheme, not fivem://, and its
REM protocol handler takes the URL as the first argument. The same form works
REM as a plain command-line argument.
start "" "%CLIENT%" "cfx://connect/127.0.0.1:30120"

echo.
echo   The server is in its own window. Close that window to stop the city.
echo.
echo   In game:  F2  the character picker
echo             F8  the console, if you need to reconnect
echo             /nyrhelp  every command
echo.
endlocal
