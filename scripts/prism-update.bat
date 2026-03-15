@echo off
REM Prism Launcher pre-launch script — packwiz-installer bootloader (Windows)
REM Place this in your Prism instance directory and set it as the pre-launch command.
REM
REM Usage in Prism Launcher:
REM   Settings > Custom Commands > Pre-launch command:
REM     cmd /c "%INST_DIR%\prism-update.bat"
REM
REM Configuration: set PACK_URL below to your hosted pack.toml URL.

if "%PACK_URL%"=="" set "PACK_URL=__PACK_URL__"
set "BOOTSTRAP_JAR=packwiz-installer-bootstrap.jar"
set "BOOTSTRAP_URL=https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar"

cd /d "%INST_MC_DIR%" || exit /b 1

if not exist "%BOOTSTRAP_JAR%" (
    echo [ELM] Downloading packwiz-installer-bootstrap...
    curl -fsSL -o "%BOOTSTRAP_JAR%" "%BOOTSTRAP_URL%"
    if errorlevel 1 (
        echo [ELM] Failed to download bootstrap jar
        exit /b 1
    )
)

echo [ELM] Updating modpack from %PACK_URL%...
java -jar "%BOOTSTRAP_JAR%" -g -s client "%PACK_URL%/pack.toml"
