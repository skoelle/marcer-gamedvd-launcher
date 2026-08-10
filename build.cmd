@echo off

REM === Build script for MarcerGameDvdLauncher (requires .NET SDK 6 or newer) ===
echo Building MarcerGameDvdLauncher...
where dotnet >nul 2>nul
if errorlevel 1 (
  echo [ERROR] .NET SDK not found. Please install from https://dotnet.microsoft.com/download
  exit /b 1
)

REM Im aktuellen Ordner (wo build.cmd liegt) bauen
cd /d %~dp0
cd MarcerGameDvdLauncher

dotnet build -c Release
if errorlevel 1 (
  echo [ERROR] Build failed!
  exit /b 2
)

REM Finden der fertigen .exe (Release-Verzeichnis)
for /f "delims=" %%I in ('dir /b /s /a-d bin\Release\*MarcerGameDvdLauncher*.exe') do set EXEPATH=%%I
if exist "%EXEPATH%" (
  echo [OK] Build complete. EXE: "%EXEPATH%"
) else (
  echo [WARNING] Build appears successful but .exe not found!
)

pause
