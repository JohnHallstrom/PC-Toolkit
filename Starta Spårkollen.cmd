@echo off
chcp 65001 >nul
title Spårkollen
echo.
echo  Spårkollen - tar reda på varför datorn är seg och hjälper dig att fixa det.
echo.
echo  1. Tryck Enter för att starta. Klicka sedan "Ja" när Windows frågar om appen får göra ändringar.
echo  2. Vänta några minuter medan datorn går spåret. Ingenting ändras än.
echo  3. Domarprotokollet öppnas i webbläsaren. Kryssa i det du vill fixa och klicka "Sök!".
echo.
set /p "_=  Tryck Enter för att starta... "
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Diagnose.ps1"
if errorlevel 1 pause
