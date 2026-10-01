@echo off
rem ---------------------------------------------------------------------------
rem Run every NYR Underworld domain spec under a plain Lua interpreter, then
rem the rig's own tests under Python.
rem
rem The domain is pure Lua on purpose: no FiveM natives, no game, no server,
rem no database. If a rule cannot be tested here, it is in the wrong layer.
rem
rem The rig (docs/rig/rig.py) is Python and stdlib only; its tests run against
rem a fake bridge in a thread. They are run from here because a test that is
rem run by a second command is a test that is not run.
rem ---------------------------------------------------------------------------
setlocal
set ROOT=%~dp0..
rem Override LUABIN and ROCKS in the environment if Lua 5.4 lives elsewhere.
if not defined LUABIN set LUABIN=%LOCALAPPDATA%\Microsoft\WinGet\Packages\DEVCOM.Lua_Microsoft.Winget.Source_8wekyb3d8bbwe\bin
if not defined ROCKS set ROCKS=%USERPROFILE%\.luarocks\share\lua\5.4

set LUA_PATH=%ROOT%\?.lua;%ROCKS%\?.lua;%ROCKS%\?\init.lua;;

cd /d "%ROOT%"
if not exist "%ROOT%\run\spec" mkdir "%ROOT%\run\spec"
"%LUABIN%\lua.exe" tools\run_specs.lua %*
if errorlevel 1 exit /b %ERRORLEVEL%

rem The rules written in NYR-Lang (tools\nyr\*.nyr): every module nyrc built from
rem them (nyr.json) must still be what its source compiles to. A hand edit, or a
rem source changed without `nyrc.cmd --build`, fails here.
if not defined NYRC set NYRC=C:\Dev\NyrLang\nyrc.cmd
if not exist "%NYRC%" (
    echo NYR-Lang's compiler is not at %NYRC% ^(set NYRC^): the rule modules were not checked
    exit /b 1
)
call "%NYRC%" --check "%ROOT%\nyr.json"
if errorlevel 1 exit /b %ERRORLEVEL%

where python >nul 2>&1
if errorlevel 1 (
    echo rig tests skipped: no python on PATH
    exit /b 0
)
python docs\rig\test_rig.py
exit /b %ERRORLEVEL%
