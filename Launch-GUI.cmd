@echo off
REM Launch-GUI.cmd - double-click launcher for the Golden ISO Builder (GUI).
REM WinForms needs a single-threaded apartment (-STA); we use -ExecutionPolicy
REM Bypass for THIS process only so the unsigned .ps1 runs without changing any
REM system setting. Nothing is installed; this just starts the form.
REM Community tool, NOT an official Veeam product.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0make-golden-gui.ps1" -Gui
if errorlevel 1 (
    echo.
    echo The GUI exited with an error. To see the details, run it from an open
    echo PowerShell window instead of double-clicking:
    echo     powershell -NoProfile -ExecutionPolicy Bypass -STA -File ".\make-golden-gui.ps1" -Gui
    pause
)
endlocal
