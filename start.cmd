@echo off

REM Starts MarcerGameDvdLauncher.exe from the correct folder
setlocal
set EXE_PATH=%~dp0MarcerGameDvdLauncher\bin\Release\net10.0\MarcerGameDvdLauncher.exe

if not exist "%EXE_PATH%" (
  echo [ERROR] Application not built. Please run build.cmd first.
  exit /b 1
)

pushd "MarcerGameDvdLauncher\bin\Release\net10.0"
"MarcerGameDvdLauncher.exe"
popd
