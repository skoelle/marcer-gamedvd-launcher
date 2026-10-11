REM Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
REM Licensed under the MIT License. See LICENSE file in project root for details.
@echo off

REM Starts MarcerGameDvdConsole.exe (script is in scripts/, code in apps/marcer_console/)
setlocal
set EXE_PATH=%~dp0..\apps\marcer_console\bin\Release\net10.0\MarcerGameDvdConsole.exe

if not exist "%EXE_PATH%" (
  echo [ERROR] Application not built. Please run build.cmd first.
  exit /b 1
)

pushd "%~dp0..\apps\marcer_console\bin\Release\net10.0"
"MarcerGameDvdConsole.exe"
popd
