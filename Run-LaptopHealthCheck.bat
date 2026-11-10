@echo off
title Laptop Health Check - FULL (about 1-3 hours)
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
echo   Laptop Health Check - FULL CHECK
echo   --------------------------------
echo   1. Click YES on the administrator prompt that appears next.
echo   2. Keep the charger plugged in and the lid open.
echo   3. Walk away. The report opens by itself when it finishes (about 1-3 hours).
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaptopHealthCheck.ps1" %*
