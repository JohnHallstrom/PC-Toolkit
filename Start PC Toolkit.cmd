@echo off
title PC Toolkit
echo.
echo  PC Toolkit - checks why the computer is slow and helps you fix it.
echo.
echo  1. Click "Yes" when Windows asks whether to allow changes.
echo  2. Wait a few minutes while the computer is checked. Nothing is changed yet.
echo  3. The report opens in your web browser. Tick what you want to fix and click "Fix selected".
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Diagnose.ps1"
if errorlevel 1 pause
