@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: =========================================================
:: Enterprise Sync Framework V3.0
:: Refactored Edition - Improved Modularity & Maintainability
:: =========================================================

:: Initialize code page for UTF-8 support
chcp 65001 >nul
title Enterprise Sync Framework V3.0

:: =========================================================
:: SECTION 1: CONFIGURATION
:: =========================================================

:: --- Network Configuration ---
set "REMOTE_HOST=192.168.1.243"
set "REMOTE_SHARE=Sinovision"
set "REMOTE_PATH=\\%REMOTE_HOST%\%REMOTE_SHARE%"

:: --- Remote Directory Structure ---
set "REMOTE_SERVICE_DIR=Service"
set "REMOTE_CONFIG_DIR=Config\PDD80"
set "REMOTE_SERVICE_PATH=%REMOTE_PATH%\%REMOTE_SERVICE_DIR%"
set "REMOTE_CONFIG_PATH=%REMOTE_PATH%\%REMOTE_CONFIG_DIR%"

:: --- Local Paths ---
set "LOCAL_PATH=D:\Sinovision"
set "BACKUP_ROOT=D:\Backup\Service"

:: --- Logging Configuration ---
set "LOG_ROOT=%~dp0Logs"

:: --- Operational Flags ---
set "ENABLE_PURGE=1"      :: Enable purge of non-excluded files after sync (全新更新模式)
set "SAFE_MODE=1"         :: Enable safety checks
set "DEBUG_MODE=0"        :: Enable debug output
set "BACKUP_VERIFY=1"     :: Verify backup integrity
set "BACKUP_TIMEOUT=300"  :: Backup timeout in seconds (future use)

:: --- Exit Codes ---
set "EXIT_SUCCESS=0"
set "EXIT_ERROR=1"
set "EXIT_CODE=%EXIT_SUCCESS%"

:: --- Robocopy Exclusions ---
set "SERVICE_EXCLUDE_DIRS=AppSettings Logs DeviceLogs certs config"
set "SERVICE_EXCLUDE_FILES=appsettings.json *.log *.tmp *.bak"
set "BACKUP_EXCLUDE_DIRS=Logs DeviceLogs"
set "CONFIG_EXTENSIONS=*.json *.xml *.yml *.yaml *.js *.ts"

:: =========================================================
:: SECTION 2: INITIALIZATION
:: =========================================================

call :InitializeLogging

:: =========================================================
:: SECTION 3: VALIDATION & SAFETY CHECKS
:: =========================================================

call :CheckAdminPrivileges
if errorlevel 1 goto FatalExit

call :ValidateSafePath "%LOCAL_PATH%"
if errorlevel 1 goto FatalExit

call :ValidateSafePath "%BACKUP_ROOT%"
if errorlevel 1 goto FatalExit

:: =========================================================
:: SECTION 4: USER INTERACTION
:: =========================================================

call :DisplaySyncInfo
call :PromptUserConfirmation
if errorlevel 1 goto SafeExit

call :CollectCredentials
if errorlevel 1 goto FatalExit

:: =========================================================
:: SECTION 5: NETWORK OPERATIONS
:: =========================================================

call :CheckNetworkConnectivity
if errorlevel 1 goto FatalExit

call :EstablishNetworkConnection
if errorlevel 1 goto FatalExit

call :VerifyRemotePaths
if errorlevel 1 goto FatalExit

:: =========================================================
:: SECTION 6: DIRECTORY PREPARATION
:: =========================================================

call :EnsureDirectoriesExist

:: =========================================================
:: SECTION 7: MAIN SYNC OPERATIONS
:: =========================================================

call :BuildDirectoryList
call :ProcessAllDirectories
call :SynchronizeConfigFiles

goto SafeExit

:: =========================================================
:: SECTION 8: FUNCTION DEFINITIONS
:: =========================================================

:: ---------------------------------------------------------
:: ProcessDir - Process a single directory
:: Parameters: %1 = Directory name
:: ---------------------------------------------------------
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

:: --- Backup Phase ---
call :PerformBackup "%DST%" "%BACKUP_DIR%"
if errorlevel 1 (
    set "EXIT_CODE=%EXIT_ERROR%"
    endlocal & goto FatalExit
)

:: --- Purge Phase: Delete all non-excluded files/folders before sync ---
if "%ENABLE_PURGE%"=="1" (
    call :PurgeLocalDirectory "%DST%"
    if errorlevel 1 (
        set "EXIT_CODE=%EXIT_ERROR%"
        endlocal & goto FatalExit
    )
)

:: --- Sync Phase ---
call :PerformSync "%SRC%" "%DST%"

endlocal
goto :EOF

:: ---------------------------------------------------------
:: PerformBackup - Execute backup operation
:: Parameters: %1 = Source, %2 = Destination
:: ---------------------------------------------------------
:PerformBackup
setlocal

set "SRC=%~1"
set "DST=%~2"

call :Log INFO "Backup start: %SRC% -> %DST%"

robocopy "%SRC%" "%DST%" ^
    /E ^
    /XD %BACKUP_EXCLUDE_DIRS% ^
    /R:2 /W:2 ^
    /NFL /NDL /NJH /NJS /NP

set "RC=%ERRORLEVEL%"
call :CheckRobocopyResult %RC% "Backup"

if %RC% GEQ 8 (
    call :Log FATAL "Backup failed"
    endlocal & exit /b 1
)

if "%BACKUP_VERIFY%"=="1" (
    call :VerifyBackup "%DST%"
    if errorlevel 1 (
        endlocal & exit /b 1
    )
)

endlocal & exit /b 0

:: ---------------------------------------------------------
:: VerifyBackup - Verify backup integrity
:: Parameters: %1 = Backup directory
:: ---------------------------------------------------------
:VerifyBackup
setlocal

set "BACKUP_DIR=%~1"

if not exist "%BACKUP_DIR%" (
    call :Log FATAL "Backup missing: %BACKUP_DIR%"
    endlocal & exit /b 1
)

set "FILECOUNT=0"
for /f %%F in ('dir /s /a-d "%BACKUP_DIR%" ^| find /c /v ""') do set FILECOUNT=%%F

if "%FILECOUNT%"=="0" (
    call :Log FATAL "Backup directory empty: %BACKUP_DIR%"
    endlocal & exit /b 1
)

call :Log INFO "Backup verified, %FILECOUNT% files copied"
endlocal & exit /b 0

:: ---------------------------------------------------------
:: PerformSync - Execute sync operation
:: Parameters: %1 = Source, %2 = Destination
:: ---------------------------------------------------------
:PerformSync
setlocal

set "SRC=%~1"
set "DST=%~2"

call :Log INFO "Sync start: %SRC% -> %DST%"

robocopy "%SRC%" "%DST%" ^
    /E ^
    /XD %SERVICE_EXCLUDE_DIRS% ^
    /XF %SERVICE_EXCLUDE_FILES% ^
    /R:2 /W:2 /NP

set "RC=%ERRORLEVEL%"
call :CheckRobocopyResult %RC% "Sync"

endlocal & goto :EOF

:: ---------------------------------------------------------
:: SynchronizeConfigFiles - Sync configuration files
:: ---------------------------------------------------------
:SynchronizeConfigFiles
call :Log INFO "Sync config from remote: %REMOTE_CONFIG_PATH%"

if not exist "%REMOTE_CONFIG_PATH%\" (
    call :Log ERROR "Remote config dir inaccessible"
    goto :EOF
)

robocopy "%REMOTE_CONFIG_PATH%" "%LOCAL_PATH%" ^
    %CONFIG_EXTENSIONS% ^
    /XO /S /R:2 /W:2 /NP >nul

call :CheckRobocopyResult %ERRORLEVEL% "ConfigSync"
goto :EOF

:: ---------------------------------------------------------
:: PurgeLocalDirectory - Delete all non-excluded files/folders in local directory
:: Parameters: %1 = Destination dir to purge
:: ---------------------------------------------------------
:PurgeLocalDirectory
setlocal

set "DST=%~1"

call :Log INFO "Purge start: Deleting all non-excluded items in %DST%"

:: Delete excluded files first (we want to keep these, so we don't delete them)
:: Actually, we need to delete everything EXCEPT the excluded items
:: So we iterate through all files and folders, and delete those not matching exclusion patterns

:: Step 1: Delete all files except excluded patterns
for %%F in ("%DST%\*.*") do (
    set "FILENAME=%%~nxF"
    set "SKIP=0"
    for %%E in (%SERVICE_EXCLUDE_FILES%) do (
        if /I "%%F"==%%E set "SKIP=1"
    )
    if "!SKIP!"=="0" (
        call :Log DEBUG "Deleting file: %%F"
        del /q "%%F" >nul 2>&1
    )
)

:: Step 2: Delete all subdirectories except excluded ones
for /D %%D in ("%DST%\*") do (
    set "DIRNAME=%%~nxD"
    set "SKIP=0"
    for %%E in (%SERVICE_EXCLUDE_DIRS%) do (
        if /I "%%D"==%%E set "SKIP=1"
    )
    if "!SKIP!"=="0" (
        call :Log INFO "Deleting directory: %%D"
        rmdir /s /q "%%D" >nul 2>&1
    )
)

call :Log INFO "Purge completed: All non-excluded items deleted"
endlocal & goto :EOF

:: ---------------------------------------------------------
:: PurgeNonExcludedFiles - Remove files/folders not in source
:: Parameters: %1 = Destination dir, %2 = Source dir
:: ---------------------------------------------------------
:PurgeNonExcludedFiles
setlocal

set "DST=%~1"
set "SRC=%~2"

call :Log INFO "Purge start: Removing non-excluded items not in source"

:: Build exclusion pattern for robocopy /XF and /XD
set "EXCLUDE_ARGS="
for %%F in (%SERVICE_EXCLUDE_FILES%) do (
    set "EXCLUDE_ARGS=!EXCLUDE_ARGS! /XF %%F"
)
for %%D in (%SERVICE_EXCLUDE_DIRS%) do (
    set "EXCLUDE_ARGS=!EXCLUDE_ARGS! /XD %%D"
)

:: Use robocopy with /PURGE to remove destination files not in source
:: But we need to exclude certain patterns from purging
robocopy "%SRC%" "%DST%" ^
    /E ^
    /XD %SERVICE_EXCLUDE_DIRS% ^
    /XF %SERVICE_EXCLUDE_FILES% ^
    /PURGE ^
    /R:0 /W:0 /NP ^
    /NFL /NDL /NJH /NJS

set "RC=%ERRORLEVEL%"
call :CheckRobocopyResult %RC% "Purge"

call :Log INFO "Purge completed"
endlocal & goto :EOF

:: ---------------------------------------------------------
:: ValidateSafePath - Ensure path is safe to operate on
:: Parameters: %1 = Path to validate
:: ---------------------------------------------------------
:ValidateSafePath
set "P=%~f1"

for %%A in ("C:\Windows" "C:\Program Files" "C:\ProgramData") do (
    if /I "%P%"=="%%~fA" (
        call :Log FATAL "Blocked system path: %P%"
        exit /b 1
    )
)
exit /b 0

:: ---------------------------------------------------------
:: CheckRobocopyResult - Interpret Robocopy return codes
:: Parameters: %1 = Return code, %2 = Step name
:: ---------------------------------------------------------
:CheckRobocopyResult
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

:: ---------------------------------------------------------
:: CleanupNetwork - Remove network connections
:: ---------------------------------------------------------
:CleanupNetwork
net use >nul 2>&1
for /f "tokens=1" %%N in ('net use ^| findstr /I "%REMOTE_HOST%"') do (
    net use %%N /delete /y >nul 2>&1
)
goto :EOF

:: ---------------------------------------------------------
:: GenerateTimestamp - Create timestamp string
:: Output: TS variable
:: ---------------------------------------------------------
:GenerateTimestamp
for /f "tokens=2 delims==" %%A in ('wmic os get localdatetime /value 2^>nul') do set "DT=%%A"
set "TS=%DT:~0,8%_%DT:~8,6%"
goto :EOF

:: ---------------------------------------------------------
:: GenerateDateFolder - Create date-based folder name
:: Output: DATE_FOLDER variable
:: ---------------------------------------------------------
:GenerateDateFolder
for /f "tokens=2 delims==" %%A in ('wmic os get localdatetime /value 2^>nul') do set "DT=%%A"
set "DATE_FOLDER=%DT:~0,4%-%DT:~4,2%-%DT:~6,2%"
goto :EOF

:: ---------------------------------------------------------
:: InitializeLogging - Setup logging infrastructure
:: ---------------------------------------------------------
:InitializeLogging
if not exist "%LOG_ROOT%" mkdir "%LOG_ROOT%" >nul 2>&1

call :GenerateTimestamp
set "SESSION_ID=%TS%_%RANDOM%"

set "LOG_FILE=%LOG_ROOT%\sync_%SESSION_ID%.log"
set "ERR_FILE=%LOG_ROOT%\error_%SESSION_ID%.log"
set "DIR_LIST=%TEMP%\dir_%SESSION_ID%.tmp"

call :Log INFO "======================================="
call :Log INFO "Enterprise Sync Framework V3.0 Started"
call :Log INFO "Session: %SESSION_ID%"
call :Log INFO "======================================="
goto :EOF

:: ---------------------------------------------------------
:: CheckAdminPrivileges - Verify admin rights
:: ---------------------------------------------------------
:CheckAdminPrivileges
fltmc >nul 2>&1
if errorlevel 1 (
    call :Log FATAL "Admin privilege required"
    exit /b 1
)
exit /b 0

:: ---------------------------------------------------------
:: DisplaySyncInfo - Show sync operation details
:: ---------------------------------------------------------
:DisplaySyncInfo
cls
echo ==================================================
echo   WARNING: PRODUCTION SYNC OPERATION
echo ==================================================
echo Remote Service : %REMOTE_SERVICE_PATH%
echo Remote Config  : %REMOTE_CONFIG_PATH%
echo Local Path     : %LOCAL_PATH%
echo Backup Path    : %BACKUP_ROOT%
echo ==================================================
goto :EOF

:: ---------------------------------------------------------
:: PromptUserConfirmation - Get user confirmation
:: Returns: errorlevel 1 if cancelled
:: ---------------------------------------------------------
:PromptUserConfirmation
choice /C YN /T 15 /D N /M "Continue?"

if errorlevel 2 (
    call :Log WARN "User cancelled"
    exit /b 1
)
exit /b 0

:: ---------------------------------------------------------
:: CollectCredentials - Get network credentials
:: Returns: errorlevel 1 if validation fails
:: ---------------------------------------------------------
:CollectCredentials
set /p "NET_USER=Username: "
if not defined NET_USER (
    call :Log ERROR "Empty username"
    exit /b 1
)

set /p "NET_PASS=Password: "
if "%NET_PASS%"=="" (
    call :Log ERROR "Empty password"
    exit /b 1
)
exit /b 0

:: ---------------------------------------------------------
:: CheckNetworkConnectivity - Test network connection
:: Returns: errorlevel 1 if unreachable
:: ---------------------------------------------------------
:CheckNetworkConnectivity
call :Log INFO "Checking network..."
ping -n 1 -w 3000 %REMOTE_HOST% >nul 2>&1
if errorlevel 1 (
    call :Log ERROR "Host unreachable"
    exit /b 1
)
exit /b 0

:: ---------------------------------------------------------
:: EstablishNetworkConnection - Connect to network share
:: Returns: errorlevel 1 if authentication fails
:: ---------------------------------------------------------
:EstablishNetworkConnection
call :CleanupNetwork

net use "%REMOTE_PATH%" "%NET_PASS%" /user:"%NET_USER%" /persistent:no >nul 2>&1
if errorlevel 1 (
    call :Log ERROR "Auth failed"
    exit /b 1
)

set "NET_PASS="
exit /b 0

:: ---------------------------------------------------------
:: VerifyRemotePaths - Check all remote paths exist
:: Returns: errorlevel 1 if any path inaccessible
:: ---------------------------------------------------------
:VerifyRemotePaths
if not exist "%REMOTE_PATH%\" (
    call :Log ERROR "Share root inaccessible"
    exit /b 1
)
if not exist "%REMOTE_SERVICE_PATH%\" (
    call :Log ERROR "Remote service dir not found: %REMOTE_SERVICE_PATH%"
    exit /b 1
)
if not exist "%REMOTE_CONFIG_PATH%\" (
    call :Log ERROR "Remote config dir not found: %REMOTE_CONFIG_PATH%"
    exit /b 1
)

call :Log INFO "Connected OK, all remote paths verified"
exit /b 0

:: ---------------------------------------------------------
:: EnsureDirectoriesExist - Create local directories
:: ---------------------------------------------------------
:EnsureDirectoriesExist
if not exist "%LOCAL_PATH%" mkdir "%LOCAL_PATH%"
if not exist "%BACKUP_ROOT%" mkdir "%BACKUP_ROOT%"
goto :EOF

:: ---------------------------------------------------------
:: BuildDirectoryList - Get list of remote directories
:: ---------------------------------------------------------
:BuildDirectoryList
dir /b /ad "%REMOTE_SERVICE_PATH%" > "%DIR_LIST%" 2>nul
goto :EOF

:: ---------------------------------------------------------
:: ProcessAllDirectories - Iterate through directory list
:: ---------------------------------------------------------
:ProcessAllDirectories
for /f "usebackq delims=" %%D in ("%DIR_LIST%") do (
    call :ProcessDir "%%D"
)
goto :EOF

:: ---------------------------------------------------------
:: Log - Write log message
:: Parameters: %1 = Level, %2 = Message
:: ---------------------------------------------------------
:Log
set "LV=%~1"
set "MSG=%~2"

echo [%LV%] %MSG%
>>"%LOG_FILE%" echo [%DATE% %TIME%] [%LV%] %MSG%

if /I "%LV%"=="ERROR" >>"%ERR_FILE%" echo [%DATE% %TIME%] %MSG%
if /I "%LV%"=="FATAL" >>"%ERR_FILE%" echo [%DATE% %TIME%] %MSG%
goto :EOF

:: ---------------------------------------------------------
:: ShowLastError - Display recent error messages
:: ---------------------------------------------------------
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

:: ---------------------------------------------------------
:: SafeExit - Clean exit with success status
:: ---------------------------------------------------------
:SafeExit
set "EXIT_CODE=%EXIT_SUCCESS%"
call :CleanupNetwork
del /f /q "%DIR_LIST%" >nul 2>&1
call :Log INFO "Completed"
goto ShowResult

:: ---------------------------------------------------------
:: FatalExit - Clean exit with error status
:: ---------------------------------------------------------
:FatalExit
set "EXIT_CODE=%EXIT_ERROR%"
call :CleanupNetwork
del /f /q "%DIR_LIST%" >nul 2>&1
call :Log FATAL "Aborted"
goto ShowResult

:: ---------------------------------------------------------
:: ShowResult - Display execution summary
:: ---------------------------------------------------------
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
