@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "NAME=HD Camera USC-CAM"
cd /d "%~dp0driver"
regsvr32 /s /u /n /i:UnityCaptureName="%NAME%" UnityCaptureFilter64bit.dll
regsvr32 /s /u /n /i:UnityCaptureName="%NAME%" UnityCaptureFilter32bit.dll
echo Removed.
pause
