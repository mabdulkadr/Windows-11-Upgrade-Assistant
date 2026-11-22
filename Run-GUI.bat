@ECHO OFF
TITLE Windows 11 Upgrade Assistant
ECHO Starting Windows 11 Upgrade Assistant...
POWERSHELL.EXE -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Windows-11-Upgrade-Assistant-v1.1.ps1"
IF ERRORLEVEL 1 ECHO The script exited with an error.
PAUSE
