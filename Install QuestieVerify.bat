@echo off
rem Double-click this file to install QuestieVerify into WoW Forever. Nothing else needs to be installed.
title QuestieVerify installer
if not exist "%~dp0tools\install.ps1" (
    echo.
    echo The installer can't find its other files.
    echo Right-click the downloaded ZIP file, choose "Extract All...", then double-click
    echo "Install QuestieVerify" inside the extracted folder.
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
echo.
pause
