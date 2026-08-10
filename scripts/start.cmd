@echo off

REM Starts MarcerGameDvdLauncher.exe (script is in scripts/, code in src/)
setlocal
set EXE_PATH=%~dp0..\src\MarcerGameDvdLauncher\bin\Release\net10.0\MarcerGameDvdLauncher.exe

if not exist "%EXE_PATH%" (
  echo [ERROR] Application not built. Please run build.cmd first.
  exit /b 1
)

pushd "%~dp0..\src\MarcerGameDvdLauncher\bin\Release\net10.0"
"MarcerGameDvdLauncher.exe"
popd
