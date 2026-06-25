@echo off
REM ============================================================================
REM  Launch-GUI.cmd — double-click launcher for the Golden ISO Builder (GUI)
REM ============================================================================
REM  WinForms needs a single-threaded apartment (-STA) and we bypass the
REM  per-machine PowerShell execution policy for THIS process only (-NoProfile
REM  -ExecutionPolicy Bypass) so the unsigned .ps1 runs without changing any
REM  system setting. Nothing is installed; this just starts the form.
REM
REM  This is a COMMUNITY tool, NOT an official Veeam product.
REM ============================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0make-golden-gui.ps1" -Gui
endlocal
