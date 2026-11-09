@echo off
title Laptop Health Check
cd /d "%~dp0"
echo.
echo   Laptop Health Check
echo   -------------------
echo   1. Click YES on the administrator prompt that appears next.
echo   2. Keep the charger plugged in and the lid open.
echo   3. Walk away. The report opens by itself when it finishes (about 1-3 hours).
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LaptopHealthCheck.ps1" %*
