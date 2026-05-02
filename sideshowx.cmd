@echo off
setlocal
set "PS_SCRIPT=%~dp0sideshowx.ps1"

if not exist "%PS_SCRIPT%" (
  echo sideshowx.cmd: missing "%PS_SCRIPT%" 1>&2
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%
