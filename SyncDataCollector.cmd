@echo off
REM Launch the Sync DataCollector GUI.
REM -STA is required for WinForms; -ExecutionPolicy Bypass avoids policy prompts.
REM %~dp0 keeps this working from any folder (USB stick, network share, etc).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SyncDataCollector.ps1"
if errorlevel 1 (
  echo.
  echo The app exited with an error. See the message above and sync-log.txt.
  pause
)
