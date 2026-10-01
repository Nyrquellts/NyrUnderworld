# Stage the resource and start a server for recording, on its own port so the
# ones already running are left alone.
#
# `data` is excluded from the mirror. Without that, /MIR deletes or overwrites
# the played city on every restage -- the same fault found in
# tools/devserver.cmd, under a header that promises saves survive.
#
# The licence key is read from the environment and passed on the command line.
# It is never written to the config, never printed, and never logged.

$ErrorActionPreference = "Stop"

$Root    = "C:\Dev\NyrUnderworld"
$Vendor  = "C:\Dev\NyrsBBDevKit\vendor\bin"
$Session = Join-Path $env:LOCALAPPDATA "NyrUnderworld\capture3"
$Port    = 30132

$key = [Environment]::GetEnvironmentVariable('FIVEM_LICENSE_KEY', 'User')
if (-not $key) { Write-Output "no licence key in the user environment"; exit 1 }

$exe = (Get-ChildItem "$Vendor\cfx-server-*" -Directory | Select-Object -First 1).FullName + "\cfx-server.exe"
if (-not (Test-Path $exe)) { Write-Output "no enhanced server under $Vendor"; exit 1 }

New-Item -ItemType Directory -Force "$Session\resources" | Out-Null

# Held back: what is at the top of this repository and does not ship, and
# `data`. /XD skips directories only, and in a git worktree .git is a file, so
# .git is in both lists. spec/shipping_spec.lua checks /XF against the files at
# the top; folders are not checked.
#
# This is not the zip a buyer gets. data/README.md is left out with `data`; the
# stage is held to the files in .nyrignore; and /MIR leaves an excluded name alone in the copy as
# well, so a session staged before a name was added here keeps what it matched
# until that is deleted.
robocopy $Root "$Session\resources\nyr_underworld" /MIR /NJH /NJS /NP /NDL /NFL /R:1 /W:1 `
    /XD .git run spec tools docs node_modules data playtest `
    /XF .git STATUS.md .gitignore .nyrignore nyr.json | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Output "staging failed ($LASTEXITCODE)"; exit 1 }
New-Item -ItemType Directory -Force "$Session\resources\nyr_underworld\data" | Out-Null

# Written without a byte-order mark. `Set-Content -Encoding UTF8` writes one
# under Windows PowerShell 5.1 and not under PowerShell 7, and cfx-server reads
# the mark as part of the first line: "endpoint_add_tcp" became a command not
# found, and the server bound the default 30120 instead of this port. Measured
# on 2026-09-13, when the script was run from powershell.exe.
$config = @"
endpoint_add_tcp "127.0.0.1:$Port"
endpoint_add_udp "127.0.0.1:$Port"
sv_maxclients 8
sv_hostname "NYR UNDERWORLD"
sets sv_projectName "NYR UNDERWORLD"
sets sv_projectDesc "The city remembers."
sv_lan true
sv_master1 ""
sv_scriptHookAllowed 0
ensure nyr_underworld
"@
[System.IO.File]::WriteAllText("$Session\server.cfg", $config, (New-Object System.Text.UTF8Encoding $false))

Write-Output "staged into $Session for 127.0.0.1:$Port"
