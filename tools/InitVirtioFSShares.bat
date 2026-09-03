@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: init-virtiofs-shares.bat
::
:: Creates and starts one VirtioFS service per shared folder tag.
::
:: Each virtiofs.exe instance serves exactly ONE tag, so multiple
:: shares require multiple services. This is why a single service
:: only ever exposes the first folder.
::
:: Prerequisites (one-time, manual, on the guest):
::   - WinFsp installed
::   - viofs driver installed via Device Manager (virtio-win ISO)
::
:: Must be run as Administrator. Services are created with
:: start=auto, so after the first run they come up on boot by
:: themselves - no need to put this in shell:startup.
::
:: Full diagnostics are appended to init-virtiofs-shares.log
:: next to this script.
:: ============================================================

set "VIOFS_EXE=C:\Program Files\Virtio-Win\VioFS\virtiofs.exe"
set "LOG=%~dp0init-virtiofs-shares.log"

:: TAG=LETTER pairs. TAG must match <target dir="..."/> in the
:: libvirt domain XML. Use ASCII only - accented tags break both
:: batch parsing and virtiofs itself.
set "SHARES=Downloads=Z Documentos=Y Dev=X Musicas=W Imagens=V Games=U"

echo ============================================================ >>"%LOG%"
call :log INFO "run started (%date% %time%)"

:: --- check for elevation ---
net session >nul 2>&1
if errorlevel 1 (
    call :log ERROR "this script must be run as Administrator."
    echo Right-click the script and choose "Run as administrator".
    pause
    exit /b 1
)

:: --- check the executable ---
if not exist "%VIOFS_EXE%" (
    call :log ERROR "virtiofs.exe not found at: %VIOFS_EXE%"
    call :log ERROR "install the viofs driver via Device Manager, or fix VIOFS_EXE at the top of this script."
    pause
    exit /b 1
)

:: --- check WinFsp ---
sc.exe query "WinFsp.Launcher" >>"%LOG%" 2>&1
if errorlevel 1 (
    call :log ERROR "WinFsp.Launcher service not found. Install WinFsp first."
    pause
    exit /b 1
)

set "FAILED=0"
for %%S in (%SHARES%) do (
    for /f "tokens=1,2 delims==" %%A in ("%%S") do (
        call :setup_share "%%A" "%%B"
        if errorlevel 1 set "FAILED=1"
    )
)

if "%FAILED%"=="1" (
    call :log ERROR "one or more shares failed. See %LOG% for details."
    pause
    exit /b 1
)

call :log OK "all shared folders configured."
timeout /t 3 >nul
exit /b 0


:: ============================================================
:: call :log LEVEL "message"
:: Prints to console and appends a timestamped copy to the log.
:log
echo [virtiofs][%~1] %~2
echo [%date% %time%] [%~1] %~2 >>"%LOG%"
exit /b 0


:: ============================================================
:: call :setup_share <tag> <letter>
:: Creates the per-tag service if missing, then starts it.
:: Skips silently if the drive letter is already in use or the
:: service is already running - never deletes anything.
:setup_share
set "TAG=%~1"
set "LETTER=%~2"
set "SVC=VirtioFsSvc_%TAG%"

:: already mounted? leave it alone.
if exist %LETTER%:\ (
    call :log OK "%LETTER%: already in use - skipping tag '%TAG%'."
    exit /b 0
)

:: does the service exist?
sc.exe query "%SVC%" >nul 2>&1
if errorlevel 1 (
    call :log INFO "creating service %SVC% (tag=%TAG%, letter=%LETTER%:)..."
    sc.exe create "%SVC%" binPath= "\"%VIOFS_EXE%\" -t %TAG% -m %LETTER%:" start= auto depend= "WinFsp.Launcher" DisplayName= "VirtIO-FS %TAG%" >>"%LOG%" 2>&1
    if errorlevel 1 (
        call :log ERROR "failed to create %SVC%. See %LOG% for raw sc.exe output."
        exit /b 1
    )
    sc.exe description "%SVC%" "VirtIO-FS shared folder: %TAG%" >>"%LOG%" 2>&1
    call :log OK "service %SVC% created."
) else (
    call :log INFO "service %SVC% already exists."
)

:: already running?
sc.exe query "%SVC%" 2>nul | find "RUNNING" >nul
if not errorlevel 1 (
    call :log OK "%SVC% is already running."
    exit /b 0
)

call :log INFO "starting %SVC%..."
sc.exe start "%SVC%" >>"%LOG%" 2>&1
set "RC=!errorlevel!"

:: 1056 = service already running, treat as success
if "!RC!"=="0"    goto :setup_ok
if "!RC!"=="1056" goto :setup_ok

call :log ERROR "failed to start %SVC% (exit code !RC!)."
if "!RC!"=="1053" call :log ERROR "  likely cause: WinFsp missing or version mismatch."
if "!RC!"=="1058" call :log ERROR "  likely cause: service is disabled."
if "!RC!"=="2"    call :log ERROR "  likely cause: invalid virtiofs.exe path."
call :log ERROR "  also verify tag '%TAG%' matches <target dir=.../> in the libvirt XML."
exit /b 1

:setup_ok
call :log OK "tag '%TAG%' mounted on %LETTER%:."
exit /b 0
