@echo off
cd /d "%~dp0"
python license_ui.py
if errorlevel 1 (
    echo.
    echo UI ??????????? PySide6: pip install PySide6
    pause
)
