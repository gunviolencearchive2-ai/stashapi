@echo off
setlocal
set "DIR=%~dp0"
rem fast path: cached python path (written by bootstrap.ps1 on first run)
if exist "%DIR%.pyok" (
  set /p PYEXE=<"%DIR%.pyok"
  if exist "%PYEXE%" (
    %PYEXE% "%DIR%app.py"
    exit /b %ERRORLEVEL%
  )
)
rem slow path: first run / python vanished -- powershell detects, downloads
rem embedded python if needed, runs app.py, and writes the .pyok marker
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%bootstrap.ps1"
