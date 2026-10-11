REM Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
REM Licensed under the MIT License. See LICENSE file in project root for details.
@echo off

REM === Build script for MarcerGameDvdConsole (requires .NET SDK 6 or newer) ===
echo Building MarcerGameDvdConsole...
where dotnet >nul 2>nul
if errorlevel 1 (
  echo [ERROR] .NET SDK not found. Please install from https://dotnet.microsoft.com/download
  exit /b 1
)

REM Im marcer_console-Ordner bauen (build.cmd liegt in scripts/)
cd /d %~dp0
cd ..\apps\marcer_console

dotnet build -c Release
if errorlevel 1 (
  echo [ERROR] Build failed!
  exit /b 2
)

REM Finden der fertigen .exe (Release-Verzeichnis)
for /f "delims=" %%I in ('dir /b /s /a-d bin\Release\*MarcerGameDvdConsole*.exe') do set EXEPATH=%%I
if exist "%EXEPATH%" (
  echo [OK] Build complete. EXE: "%EXEPATH%"
) else (
  echo [WARNING] Build appears successful but .exe not found!
)

pause
