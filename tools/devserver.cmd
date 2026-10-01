@echo off
setlocal EnableDelayedExpansion
REM ---------------------------------------------------------------------------
REM A server you can actually play on.
REM
REM This is NOT `nyrbb fivem boot`. That is a probe: it watches a server come up
REM for a bounded number of seconds and then kills it, which is right for a
REM probe and useless for playing. This one starts the server and gets out of
REM the way. The window it runs in IS the server; close it to stop the city.
REM
REM   tools\devserver.cmd            GTA V Enhanced  (the game installed here)
REM   tools\devserver.cmd legacy     GTA V Legacy
REM
REM This is a local development copy. The certified buyer package is produced
REM separately by Nyr release-check against a fresh staging directory.
REM ---------------------------------------------------------------------------

set "FLAVOUR=%~1"
if "%FLAVOUR%"=="" set "FLAVOUR=enhanced"

set "ROOT=%~dp0.."
set "VENDOR=C:\Dev\NyrsBBDevKit\vendor\bin"
set "SESSION=%LOCALAPPDATA%\NyrUnderworld\dev-server"

if "%FIVEM_LICENSE_KEY%"=="" (
    echo.
    echo   FIVEM_LICENSE_KEY is not set in this window.
    echo.
    echo   Both FiveM servers refuse to start without one, on loopback included
    echo   and in LAN mode, whatever the documentation says. The key is free
    echo   from https://portal.cfx.re/servers/registration-keys and belongs to
    echo   your own Cfx.re account.
    echo.
    echo   Set it for this window only, then run this again:
    echo.
    echo       set FIVEM_LICENSE_KEY=cfxk_your_key_here
    echo.
    exit /b 1
)

REM --------------------------------------------------------------- the server
set "CITIZEN="
if /I "%FLAVOUR%"=="enhanced" (
    for /d %%D in ("%VENDOR%\cfx-server-*") do set "EXE=%%D\cfx-server.exe"
) else (
    for /d %%D in ("%VENDOR%\fivem-server-*") do (
        set "EXE=%%D\FXServer.exe"
        set "CITIZEN=%%D\citizen"
    )
)

if not exist "!EXE!" (
    echo.
    echo   No %FLAVOUR% server found under %VENDOR%.
    echo.
    echo   They are two separate downloads and two different programs:
    echo     legacy   FXServer.exe    from runtime.fivem.net
    echo     enhanced cfx-server.exe  from the Cfx server download page
    echo.
    exit /b 1
)

REM -------------------------------------------------------------- the staging
if not exist "%SESSION%\resources" mkdir "%SESSION%\resources" >nul 2>&1

echo   staging the resource ...
REM Held back: what is at the top of this repository and does not ship. /XD
REM skips directories only, and in a git worktree .git is a file -- copied, it
REM makes the server's folder look like the worktree to git -- so .git is in
REM both lists. spec/shipping_spec.lua checks /XF against the files at the top;
REM folders are not checked. /E copies and never deletes, so a name added here
REM later stays in a session staged before it, as removed code does, until the
REM session folder is cleared.
robocopy "%ROOT%" "%SESSION%\resources\nyr_underworld" ^
    /E /NJH /NJS /NP /NDL /NFL /R:1 /W:1 ^
    /XD .git run spec tools docs node_modules data playtest ^
    /XF .git STATUS.md .gitignore .nyrignore nyr.json *.cfg *.cfg.local .env *.key *.pem >nul
if errorlevel 8 (
    echo   could not stage the resource into %SESSION%
    exit /b 1
)

REM Never mirror or copy data from the authoring tree. /MIR used to purge the
REM session's saves when they were absent from the source. /E never deletes.
REM Removed code may remain in this dev copy; certify releases in a fresh stage.
REM The city's save files live only in the session.
if not exist "%SESSION%\resources\nyr_underworld\data" mkdir "%SESSION%\resources\nyr_underworld\data" >nul 2>&1
copy /Y "%~dp0dev-server.cfg" "%SESSION%\server.cfg" >nul

echo.
echo   NYR UNDERWORLD   %FLAVOUR% server on 127.0.0.1:30120
echo   session   %SESSION%
echo.
echo   Connect: open FiveM, press F8, type   connect 127.0.0.1:30120
echo   In game: F2 opens the character picker, /nyrhelp lists every command.
echo.
echo   Close this window to stop the city. Saves survive.
echo.

cd /d "%SESSION%"
REM OneSync goes on the command line: a config file cannot change it, because
REM it is read before server.cfg is executed. The licence key goes here rather
REM than in the config so it is never written to disk.
if defined CITIZEN (
    "!EXE!" +set citizen_dir "!CITIZEN!" +set onesync on +set sv_licenseKey "%FIVEM_LICENSE_KEY%" +exec server.cfg
) else (
    "!EXE!" +set onesync on +set sv_licenseKey "%FIVEM_LICENSE_KEY%" +exec server.cfg
)
endlocal
