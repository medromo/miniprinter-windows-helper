@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Print-DepositOrders.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" if not "%RC%"=="3" pause
endlocal & exit /b %RC%
