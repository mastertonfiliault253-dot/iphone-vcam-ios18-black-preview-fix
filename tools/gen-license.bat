@echo off
cd /d "%~dp0"
echo ============================================
echo   VCAM License Generator
echo ============================================
echo.
set /p UDID="Device UDID: "
if "%UDID%"=="" (
    echo ERROR: UDID is required
    pause
    exit /b 1
)
set /p EXPIRY="Expiry date (YYYY-MM-DD, default 2099-12-31): "
if "%EXPIRY%"=="" set EXPIRY=2099-12-31

echo.
echo Generating license for UDID=%UDID% expiry=%EXPIRY%...
python gen-license.py %UDID% %EXPIRY%

if exist license.plist (
    echo.
    echo SUCCESS: license.plist generated
    echo Location: %CD%\license.plist
    echo.
    echo To deploy, copy this file to device:
    echo   /var/mobile/Media/VCAM/license.plist
) else (
    echo FAILED: license.plist not created
)
pause
