@echo off

REM Starts HatariZipLauncher.exe from the correct folder
setlocal
set EXE_PATH=%~dp0HatariZipLauncher\bin\Release\net10.0\HatariZipLauncher.exe

if not exist "%EXE_PATH%" (
  echo [ERROR] Application not built. Please run build.cmd first.
  exit /b 1
)

pushd "HatariZipLauncher\bin\Release\net10.0"
"HatariZipLauncher.exe"
popd
