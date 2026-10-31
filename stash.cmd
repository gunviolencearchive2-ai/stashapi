@echo off
rem Stash API one-liner:  stash <command>
rem The whole command line after "stash" is sent as-is, no escaping needed.
rem   stash start notepad        stash status        stash screenshot
rem   stash dir C:\Users         stash ping -n 2 ya.ru
setlocal
set "PORT="
if exist "%~dp0.server_port" set /p PORT=<"%~dp0.server_port"
if not defined PORT set "PORT=17653"
curl.exe -s -X POST "http://127.0.0.1:%PORT%/run" --data-binary "%*"
endlocal
