@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: =========================================================
:: Enterprise Sync Framework V2.1
:: Final Edition (Status + Error Diagnose)
:: =========================================================

chcp 65001 >nul
title Enterprise Sync Framework V2.1

:: =========================================================
:: CONFIGURATION
:: =========================================================
set "REMOTE_HOST=192.168.1.243"
set "REMOTE_SHARE=Sinovision"
set "REMOTE_PATH=\\%REMOTE_HOST%\%REMOTE_SHARE%"

:: 远程服务目录 & 远程配置目录（共享下的相对路径）
set "REMOTE_SERVICE_DIR=Service"
set "REMOTE_CONFIG_DIR=Config\PDD80"
set "REMOTE_SERVICE_PATH=%REMOTE_PATH%\%REMOTE_SERVICE_DIR%"
set "REMOTE_CONFIG_PATH=%REMOTE_PATH%\%REMOTE_CONFIG_DIR%"

set "LOCAL_PATH=D:\Sinovision"
set "BACKUP_ROOT=D:\Backup\Service"

set "LOG_ROOT=%~dp0Logs"

set "ENABLE_PURGE=0"
set "SAFE_MODE=1"
set "DEBUG_MODE=0"
set "BACKUP_VERIFY=1"

set "EXIT_CODE=0"

:: =========================================================
:: INIT LOG DIR
:: =========================================================
if not exist "%LOG_ROOT%" mkdir "%LOG_ROOT%" >nul 2>&1

call :GenerateTimestamp
set "SESSION_ID=%TS%_%RANDOM%"

set "LOG_FILE=%LOG_ROOT%\sync_%SESSION_ID%.log"
set "ERR_FILE=%LOG_ROOT%\error_%SESSION_ID%.log"
set "DIR_LIST=%TEMP%\dir_%SESSION_ID%.tmp"

:: =========================================================
:: LOG START
:: =========================================================
call :Log INFO "======================================="
call :Log INFO "Enterprise Sync Framework V2.1 Started"
call :Log INFO "Session: %SESSION_ID%"
call :Log INFO "======================================="

:: =========================================================
:: ADMIN CHECK
:: =========================================================
fltmc >nul 2>&1
if errorlevel 1 (
    call :Log FATAL "Admin privilege required"
    goto FatalExit
)

:: =========================================================
:: PATH SAFETY CHECK (仅检查本地路径)
:: =========================================================
call :EnsureSafePath "%LOCAL_PATH%"
if errorlevel 1 goto FatalExit

call :EnsureSafePath "%BACKUP_ROOT%"
if errorlevel 1 goto FatalExit

:: =========================================================
:: USER CONFIRMATION
:: =========================================================
cls
echo ==================================================
echo   WARNING: PRODUCTION SYNC OPERATION
echo ==================================================
echo Remote Service : %REMOTE_SERVICE_PATH%
echo Remote Config  : %REMOTE_CONFIG_PATH%
echo Local Path     : %LOCAL_PATH%
echo Backup Path    : %BACKUP_ROOT%
echo ==================================================
choice /C YN /T 15 /D N /M "Continue?"

if errorlevel 2 (
    call :Log WARN "User cancelled"
    goto SafeExit
)

:: =========================================================
:: CREDENTIAL INPUT
:: =========================================================
set /p "NET_USER=Username: "
if not defined NET_USER (
    call :Log ERROR "Empty username"
    goto FatalExit
)

set /p "NET_PASS=Password: "
if "%NET_PASS%"=="" (
    call :Log ERROR "Empty password"
    goto FatalExit
)

:: =========================================================
:: NETWORK CHECK
:: =========================================================
call :Log INFO "Checking network..."
ping -n 1 -w 3000 %REMOTE_HOST% >nul 2>&1
if errorlevel 1 (
    call :Log ERROR "Host unreachable"
    goto FatalExit
)

:: =========================================================
:: CONNECT SHARE
:: =========================================================
call :CleanupNetwork

net use "%REMOTE_PATH%" "%NET_PASS%" /user:"%NET_USER%" /persistent:no >nul 2>&1
if errorlevel 1 (
    call :Log ERROR "Auth failed"
    goto FatalExit
)

set "NET_PASS="

:: 校验共享根、服务目录、配置目录是否可访问
if not exist "%REMOTE_PATH%\" (
    call :Log ERROR "Share root inaccessible"
    goto FatalExit
)
if not exist "%REMOTE_SERVICE_PATH%\" (
    call :Log ERROR "Remote service dir not found: %REMOTE_SERVICE_PATH%"
    goto FatalExit
)
if not exist "%REMOTE_CONFIG_PATH%\" (
    call :Log ERROR "Remote config dir not found: %REMOTE_CONFIG_PATH%"
    goto FatalExit
)

call :Log INFO "Connected OK, all remote paths verified"

:: =========================================================
:: CREATE DIRS
:: =========================================================
if not exist "%LOCAL_PATH%" mkdir "%LOCAL_PATH%"
if not exist "%BACKUP_ROOT%" mkdir "%BACKUP_ROOT%"

:: =========================================================
:: GET DIR LIST (从远程服务目录获取子目录列表)
:: =========================================================
dir /b /ad "%REMOTE_SERVICE_PATH%" > "%DIR_LIST%" 2>nul

:: =========================================================
:: MAIN LOOP
:: =========================================================
for /f "usebackq delims=" %%D in ("%DIR_LIST%") do (
    call :ProcessDir "%%D"
)

:: =========================================================
:: CONFIG SYNC (从远程配置目录同步)
:: =========================================================
call :SyncConfig

goto SafeExit

:: =========================================================
:: PROCESS DIRECTORY
:: =========================================================
:ProcessDir
setlocal

set "NAME=%~1"
set "SRC=%REMOTE_SERVICE_PATH%\%NAME%"
set "DST=%LOCAL_PATH%\%NAME%"

call :GenerateDateFolder
set "BACKUP_DIR=%BACKUP_ROOT%\%DATE_FOLDER%\%NAME%_%SESSION_ID%"

call :Log INFO "Processing %NAME%"

if not exist "%DST%" (
    call :Log WARN "Missing local dir: %DST%"
    endlocal & goto :EOF
)

:: =========================================================
:: BACKUP
:: =========================================================
call :Log INFO "Backup start"

robocopy "%DST%" "%BACKUP_DIR%" ^
    /E ^
    /XD Logs DeviceLogs ^
    /R:2 /W:2 ^
    /NFL /NDL /NJH /NJS /NP

set "RC=%ERRORLEVEL%"
call :CheckRC %RC% "Backup"

if %RC% GEQ 8 (
    call :Log FATAL "Backup failed"
    set "EXIT_CODE=1"
    endlocal & goto FatalExit
)

if "%BACKUP_VERIFY%"=="1" (
    if not exist "%BACKUP_DIR%" (
        call :Log FATAL "Backup missing"
        set "EXIT_CODE=1"
        endlocal & goto FatalExit
    )

    :: 检查文件数量
    set "FILECOUNT=0"
    for /f %%F in ('dir /s /a-d "%BACKUP_DIR%" ^| find /c /v ""') do set FILECOUNT=%%F

    if "%FILECOUNT%"=="0" (
        call :Log FATAL "Backup directory empty: %BACKUP_DIR%"
        set "EXIT_CODE=1"
        endlocal & goto FatalExit
    )

    call :Log INFO "Backup verified, %FILECOUNT% files copied"
)

:: =========================================================
:: SYNC
:: =========================================================
call :Log INFO "Sync start"

robocopy "%SRC%" "%DST%" ^
    /E ^
    /XD AppSettings Logs DeviceLogs certs config ^
    /XF appsettings.json *.log *.tmp *.bak ^
    /R:2 /W:2 /NP

set "RC2=%ERRORLEVEL%"
call :CheckRC %RC2% "Sync"

endlocal
goto :EOF

:: =========================================================
:: CONFIG SYNC (远程配置源)
:: =========================================================
:SyncConfig
call :Log INFO "Sync config from remote: %REMOTE_CONFIG_PATH%"

if not exist "%REMOTE_CONFIG_PATH%\" (
    call :Log ERROR "Remote config dir inaccessible"
    goto :EOF
)

robocopy "%REMOTE_CONFIG_PATH%" "%LOCAL_PATH%" ^
    *.json *.xml *.yml *.yaml *.js *.ts ^
    /XO /S /R:2 /W:2 /NP >nul

call :CheckRC %ERRORLEVEL% "ConfigSync"
goto :EOF

:: =========================================================
:: SAFE PATH CHECK
:: =========================================================
:EnsureSafePath
set "P=%~f1"

for %%A in ("C:\Windows" "C:\Program Files" "C:\ProgramData") do (
    if /I "%P%"=="%%~fA" (
        call :Log FATAL "Blocked system path"
        exit /b 1
    )
)
exit /b 0

:: =========================================================
:: CHECK ROBOCOPY RESULT
:: =========================================================
:CheckRC
set "RC=%~1"
set "STEP=%~2"

if %RC% GEQ 8 (
    call :Log ERROR "%STEP% FAILED rc=%RC%"
) else if %RC% GEQ 4 (
    call :Log WARN "%STEP% completed with mismatches rc=%RC%"
) else if %RC% EQU 0 (
    call :Log INFO "%STEP% no changes rc=%RC%"
) else (
    call :Log INFO "%STEP% success rc=%RC%"
)
goto :EOF

:: =========================================================
:: CLEAN NETWORK
:: =========================================================
:CleanupNetwork
net use >nul 2>&1
for /f "tokens=1" %%N in ('net use ^| findstr /I "%REMOTE_HOST%"') do (
    net use %%N /delete /y >nul 2>&1
)
goto :EOF

:: =========================================================
:: TIMESTAMP
:: =========================================================
:GenerateTimestamp
for /f "tokens=2 delims==" %%A in ('wmic os get localdatetime /value 2^>nul') do set "DT=%%A"
set "TS=%DT:~0,8%_%DT:~8,6%"
goto :EOF

:: =========================================================
:: DATE FOLDER (FIXED)
:: =========================================================
:GenerateDateFolder
for /f "tokens=2 delims==" %%A in ('wmic os get localdatetime /value 2^>nul') do set "DT=%%A"
set "DATE_FOLDER=%DT:~0,4%-%DT:~4,2%-%DT:~6,2%"
goto :EOF

:: =========================================================
:: LOGGING
:: =========================================================
:Log
set "LV=%~1"
set "MSG=%~2"

echo [%LV%] %MSG%
>>"%LOG_FILE%" echo [%DATE% %TIME%] [%LV%] %MSG%

if /I "%LV%"=="ERROR" >>"%ERR_FILE%" echo [%DATE% %TIME%] %MSG%
if /I "%LV%"=="FATAL" >>"%ERR_FILE%" echo [%DATE% %TIME%] %MSG%
goto :EOF

:: =========================================================
:: SHOW ERROR CONTEXT
:: =========================================================
:ShowLastError
echo.
echo Last Error Context:
echo ------------------------------------------------

if not exist "%ERR_FILE%" (
    echo No error log found.
    goto :EOF
)

powershell -NoProfile -Command "Get-Content -Path '%ERR_FILE%' -Tail 20"

echo ------------------------------------------------
goto :EOF

:: =========================================================
:: SAFE EXIT
:: =========================================================
:SafeExit
set "EXIT_CODE=0"
call :CleanupNetwork
del /f /q "%DIR_LIST%" >nul 2>&1
call :Log INFO "Completed"
goto ShowResult

:: =========================================================
:: FATAL EXIT
:: =========================================================
:FatalExit
set "EXIT_CODE=1"
call :CleanupNetwork
del /f /q "%DIR_LIST%" >nul 2>&1
call :Log FATAL "Aborted"
goto ShowResult

:: =========================================================
:: FINAL RESULT
:: =========================================================
:ShowResult
echo.
echo ======================================
echo            EXECUTION RESULT
echo ======================================
echo.

if "%EXIT_CODE%"=="0" (
    echo STATUS : SUCCESS
    echo RESULT : All operations completed
) else (
    echo STATUS : FAILED
    echo RESULT : Error occurred during execution

    echo.
    call :ShowLastError
)

echo.
echo Log File: %LOG_FILE%
echo ErrorLog: %ERR_FILE%
echo.
echo Press any key to close window...
pause >nul

endlocal
exit /b %EXIT_CODE%
