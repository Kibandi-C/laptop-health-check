@echo off
title Laptop Health Check - QUICK (about 5 minutes)
cd /d "%~dp0"
if not exist "%~dp0LaptopHealthCheck.ps1" (
    echo.
    echo   LaptopHealthCheck.ps1 was not found next to this file.
    echo   Extract the whole ZIP first: right-click it, choose Extract All, then run this file from the extracted folder.
    echo.
    pause
    exit /b 1
)
echo.
echo   Laptop Health Check - QUICK MODE (about 5 minutes)
echo   --------------------------------------------------
echo   For testing a laptop before you accept it.
echo   1. Click YES on the administrator prompt that appears next.
echo   2. Stay with the laptop: a 90-second fan test will ask if the fan spun up.
echo   3. The report opens by itself at the end.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaptopHealthCheck.ps1" -Quick %*
