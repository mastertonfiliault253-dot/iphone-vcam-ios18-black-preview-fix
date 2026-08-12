@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   VCAM 授权生成工具
echo ============================================
echo.
set /p UDID="请输入设备UDID: "
if "%UDID%"=="" (
    echo 错误: UDID 不能为空
    pause
    exit /b 1
)
set /p EXPIRY="请输入过期日期 (YYYY-MM-DD, 默认2099-12-31): "
if "%EXPIRY%"=="" set EXPIRY=2099-12-31

echo.
echo 正在生成授权文件...
python gen-license.py "%UDID%" "%EXPIRY%"

if exist license.plist (
    echo.
    echo 授权文件已生成: %CD%\license.plist
    echo.
    set /p DEPLOY="是否部署到设备? (输入IP地址, 直接回车跳过): "
    if not "%DEPLOY%"=="" (
        echo 正在部署到 %DEPLOY%...
        scp license.plist root@%DEPLOY%:/var/mobile/Media/VCAM/license.plist
        if %ERRORLEVEL% equ 0 (
            echo 部署成功!
        ) else (
            echo 部署失败, 请手动复制 license.plist 到设备 /var/mobile/Media/VCAM/
        )
    )
) else (
    echo 生成失败, 请检查错误信息
)

pause
