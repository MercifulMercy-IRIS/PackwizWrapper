#!/usr/bin/env bash
# ============================================================================
# EnviousLabs MC Pack Manager — Installer
# ============================================================================
# Installs:
#   1. PackWiz (Go binary) if not present
#   2. PackManager as 'pm' command on PATH
#   3. Bash completion for pm
#   4. Default config at ~/.config/packmanager/packmanager.conf
#
# Usage:
#   curl -sSL <your-host>/install.sh | bash
#   — or —
#   ./install.sh
#
# After install, use from anywhere:
#   pm init
#   pm sync
#   pm deploy
#   pm add tinkers-construct mekanism
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/packmanager"
COMPLETION_DIR="${HOME}/.local/share/bash-completion/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }

header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  EnviousLabs MC Pack Manager — Installer${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_prerequisites() {
    info "Checking prerequisites..."

    # Check for Go (needed to install packwiz)
    if ! command -v go &>/dev/null; then
        warn "Go not found. Attempting to install..."
        install_go
    fi
    log "Go $(go version | grep -oP 'go\K[0-9.]+')"

    # Check for git
    if ! command -v git &>/dev/null; then
        fail "Git is required. Install with: sudo dnf install git  (or apt)"
    fi
    log "Git available"

    # Check for curl
    if ! command -v curl &>/dev/null; then
        fail "curl is required. Install with: sudo dnf install curl  (or apt)"
    fi
    log "curl available"

    # Check for jq (needed for target registry)
    if ! command -v jq &>/dev/null; then
        warn "jq not found — needed for target registry."
        echo -e "    Install with: ${CYAN}sudo dnf install jq${NC}  or  ${CYAN}sudo apt install jq${NC}"
        echo -e "    Continuing without it — deploy commands will fail until jq is installed."
    else
        log "jq available"
    fi

    # Check for docker (optional at install time)
    if command -v docker &>/dev/null; then
        log "Docker available"
    else
        warn "Docker not found — needed for server deployment."
        echo -e "    Install: ${CYAN}https://docs.docker.com/engine/install/${NC}"
    fi
}

install_go() {
    local go_version="1.22.2"
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)       fail "Unsupported architecture: $arch" ;;
    esac

    local tarball="go${go_version}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"

    info "Downloading Go ${go_version}..."
    curl -sLO "$url" || fail "Failed to download Go"

    info "Installing Go to /usr/local/go..."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$tarball"
    rm -f "$tarball"

    # Add to PATH for this session
    export PATH="/usr/local/go/bin:${HOME}/go/bin:$PATH"

    # Persist in profile
    if ! grep -q '/usr/local/go/bin' "${HOME}/.bashrc" 2>/dev/null; then
        echo 'export PATH="/usr/local/go/bin:${HOME}/go/bin:$PATH"' >> "${HOME}/.bashrc"
    fi

    log "Go ${go_version} installed"
}

# ============================================================================
# INSTALL PACKWIZ
# ============================================================================

install_packwiz() {
    if command -v packwiz &>/dev/null; then
        log "PackWiz already installed: $(which packwiz)"
        return
    fi

    info "Installing PackWiz..."
    go install github.com/packwiz/packwiz@latest 2>/dev/null || fail "Failed to install packwiz"

    # Ensure Go bin is in PATH
    local gobin="${HOME}/go/bin"
    if [[ -f "${gobin}/packwiz" ]]; then
        # Symlink to our install dir for reliability
        mkdir -p "$INSTALL_DIR"
        ln -sf "${gobin}/packwiz" "${INSTALL_DIR}/packwiz"
        log "PackWiz installed → ${INSTALL_DIR}/packwiz"
    else
        fail "PackWiz binary not found after install"
    fi
}

# ============================================================================
# INSTALL PACKMANAGER
# ============================================================================

install_packmanager() {
    info "Installing PackManager as 'pm'..."

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    # Copy the main script
    local src="${SCRIPT_DIR}/packmanager.sh"
    local dest="${INSTALL_DIR}/pm"

    if [[ ! -f "$src" ]]; then
        fail "packmanager.sh not found in ${SCRIPT_DIR}"
    fi

    cp "$src" "$dest"
    chmod +x "$dest"
    log "Installed → ${dest}"

    # Copy default config if none exists
    if [[ ! -f "${CONFIG_DIR}/packmanager.conf" ]]; then
        if [[ -f "${SCRIPT_DIR}/packmanager.conf" ]]; then
            cp "${SCRIPT_DIR}/packmanager.conf" "${CONFIG_DIR}/packmanager.conf"
            log "Config → ${CONFIG_DIR}/packmanager.conf"
        else
            create_default_config
        fi
    else
        warn "Config already exists at ${CONFIG_DIR}/packmanager.conf — not overwriting"
    fi

    # Ensure INSTALL_DIR is in PATH
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        local shell_rc="${HOME}/.bashrc"
        [[ -f "${HOME}/.zshrc" ]] && shell_rc="${HOME}/.zshrc"

        if ! grep -q "\.local/bin" "$shell_rc" 2>/dev/null; then
            echo "export PATH=\"\${HOME}/.local/bin:\${PATH}\"" >> "$shell_rc"
            info "Added ${INSTALL_DIR} to PATH in ${shell_rc}"
        fi

        export PATH="${INSTALL_DIR}:${PATH}"
    fi
}

create_default_config() {
    cat > "${CONFIG_DIR}/packmanager.conf" << 'CONF'
# ============================================================================
# PackManager Configuration
# ============================================================================
# This file is loaded by pm from ~/.config/packmanager/packmanager.conf
# It can also be overridden per-project by placing packmanager.conf in the
# pack directory (alongside pack.toml and mods.txt).
# ============================================================================

# --- Minecraft & Loader -----------------------------------------------------
MC_VERSION="1.20.1"
LOADER="forge"
# LOADER_VERSION=""             # Leave blank for latest

# --- PackWiz ----------------------------------------------------------------
PACKWIZ_BIN="packwiz"           # Path to packwiz binary
RETRY_ATTEMPTS=2                # Retries per source before fallback
RETRY_DELAY=3                   # Seconds between retries
PREFER_SOURCE="mr"              # "mr" (Modrinth first) or "cf" (CurseForge first)

# --- Docker Server -----------------------------------------------------------
SERVER_IMAGE="itzg/minecraft-server:java17"
SERVER_VM_IP=""                 # Public/Tailscale IP of the Docker VM
SERVER_DOMAIN=""                # Base domain (e.g. enviouslabs.com)
SERVER_BASE_PORT=25565          # First server gets this port, +1 for each after
SERVER_RCON_BASE_PORT=25575     # RCON base port

# --- Server Defaults --------------------------------------------------------
SERVER_RAM="8192"               # MB of RAM for new servers
SERVER_DISK="25600"             # MB of disk space
SERVER_CPU="400"                # CPU limit (100 = 1 core)
SERVER_SWAP="0"                 # Swap in MB
SERVER_IO="500"                 # IO weight (100-1000)
SERVER_DATABASES="2"            # Database limit
SERVER_BACKUPS="3"              # Backup limit

# --- Pack Hosting -----------------------------------------------------------
PACK_HOST_URL=""                # e.g. https://pack.enviouslabs.com
PACK_HOST_DIR=""                # Local dir served by Cloudflare tunnel

# --- Self-Update (GitHub) --------------------------------------------------
PM_GITHUB_REPO=""               # e.g. "yourusername/PackwizWrapper" (owner/repo)
PM_GITHUB_BRANCH="main"         # Branch to pull updates from
PM_GITHUB_PATH=""               # Subdirectory in repo (e.g. "envious-mc")
PM_UPDATE_FILES="packmanager.sh install.sh packmanager.conf mods.txt"

# --- Local/Self-Hosted Mods ------------------------------------------------
# For mods not on Modrinth or CurseForge (custom builds, forks, etc.)
# Place JARs in LOCAL_MODS_DIR and reference them as local:slug in mods.txt
LOCAL_MODS_DIR=""               # e.g. /var/www/mods — directory with JAR files
LOCAL_MODS_URL=""               # e.g. https://mods.enviouslabs.com — public URL

# --- JVM Flags (Aikar's optimized) ------------------------------------------
JVM_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
CONF

    log "Created default config → ${CONFIG_DIR}/packmanager.conf"
}

# ============================================================================
# INSTALL BASH COMPLETION
# ============================================================================

install_completion() {
    info "Installing bash completion..."

    mkdir -p "$COMPLETION_DIR"

    cat > "${COMPLETION_DIR}/pm" << 'COMP'
# Bash completion for pm (PackManager)
_pm_completions() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="init sync update add remove list status deps refresh export serve pin unpin migrate settings import detect open markdown targets deploy doctor verify diff config publish self-update update-status help"

    case "$prev" in
        pm)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return 0
            ;;
        export|ex)
            COMPREPLY=($(compgen -W "modrinth curseforge mr cf" -- "$cur"))
            return 0
            ;;
        modrinth|curseforge|mr|cf)
            # After export format, offer side filter
            if [[ "${COMP_WORDS[1]}" == "export" || "${COMP_WORDS[1]}" == "ex" ]]; then
                COMPREPLY=($(compgen -W "client server" -- "$cur"))
            fi
            return 0
            ;;
        deploy|d)
            COMPREPLY=($(compgen -W "create push publish start stop restart kill status console backup full help --target" -- "$cur"))
            return 0
            ;;
        targets|t)
            COMPREPLY=($(compgen -W "list add set show remove help" -- "$cur"))
            return 0
            ;;
        config|cfg)
            COMPREPLY=($(compgen -W "show edit path" -- "$cur"))
            return 0
            ;;
        migrate|mig)
            COMPREPLY=($(compgen -W "minecraft loader mc" -- "$cur"))
            return 0
            ;;
        settings|set)
            COMPREPLY=($(compgen -W "versions show" -- "$cur"))
            return 0
            ;;
        list|ls)
            COMPREPLY=($(compgen -W "--side --version --native" -- "$cur"))
            return 0
            ;;
        --side|-s)
            COMPREPLY=($(compgen -W "client server both" -- "$cur"))
            return 0
            ;;
        refresh)
            COMPREPLY=($(compgen -W "--build" -- "$cur"))
            return 0
            ;;
        --target|-t)
            # Complete with target names from registry
            local targets_file="${HOME}/.config/packmanager/targets.json"
            if [[ -f "$targets_file" ]] && command -v jq &>/dev/null; then
                local target_names
                target_names=$(jq -r 'keys[]' "$targets_file" 2>/dev/null)
                COMPREPLY=($(compgen -W "$target_names" -- "$cur"))
            fi
            return 0
            ;;
        remove|rm|pin|unpin|open)
            # Complete with installed mod slugs
            if [[ -d "mods" ]]; then
                local mods
                mods=$(find mods -name "*.pw.toml" -exec basename {} .pw.toml \; 2>/dev/null)
                COMPREPLY=($(compgen -W "$mods" -- "$cur"))
            fi
            return 0
            ;;
        add|a)
            # Complete with mods.txt entries that aren't installed yet
            if [[ -f "mods.txt" ]]; then
                local slugs
                slugs=$(grep -vE '^\s*#|^\s*$' mods.txt | sed 's/\s*#.*$//;s/^!//;s/^mr://;s/^cf://;s/^url://;s/^local://' | xargs)
                COMPREPLY=($(compgen -W "$slugs" -- "$cur"))
            fi
            return 0
            ;;
        import)
            # Complete with .zip files
            COMPREPLY=($(compgen -f -X '!*.zip' -- "$cur"))
            return 0
            ;;
    esac

    # Default: command completion
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    fi
}

complete -F _pm_completions pm
COMP

    # Source it in bashrc if not already
    local source_line="[[ -f ${COMPLETION_DIR}/pm ]] && source ${COMPLETION_DIR}/pm"
    if ! grep -qF "bash-completion/completions/pm" "${HOME}/.bashrc" 2>/dev/null; then
        echo "$source_line" >> "${HOME}/.bashrc"
    fi

    log "Bash completion installed"
}

# ============================================================================
# VERIFY INSTALLATION
# ============================================================================

verify() {
    echo ""
    echo -e "${BOLD}═══ Verification ═══${NC}"
    echo ""

    local all_good=true

    if command -v pm &>/dev/null; then
        log "pm command available"
    else
        warn "pm not found in PATH — restart your shell or run: source ~/.bashrc"
        all_good=false
    fi

    if command -v packwiz &>/dev/null; then
        log "packwiz available"
    else
        warn "packwiz not found in PATH — restart your shell"
        all_good=false
    fi

    if [[ -f "${CONFIG_DIR}/packmanager.conf" ]]; then
        log "Config at ${CONFIG_DIR}/packmanager.conf"
    else
        warn "No config file found"
        all_good=false
    fi

    echo ""
    if $all_good; then
        echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
    else
        echo -e "${YELLOW}${BOLD}  Installed with warnings — restart your shell.${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Quick start:${NC}"
    echo -e "    ${CYAN}pm init${NC}              Initialize a pack in the current directory"
    echo -e "    ${CYAN}pm sync${NC}              Install all mods from mods.txt"
    echo -e "    ${CYAN}pm add <slug>${NC}        Add a mod"
    echo -e "    ${CYAN}pm deploy create${NC}     Generate Docker compose for a target"
    echo -e "    ${CYAN}pm config edit${NC}       Edit your config (VM IP, domain, etc.)"
    echo ""
    echo -e "  ${BOLD}Config:${NC} ${CYAN}${CONFIG_DIR}/packmanager.conf${NC}"
    echo -e "  ${BOLD}Docs:${NC}   ${CYAN}pm help${NC}"
    echo ""
}

# ============================================================================
# UNINSTALL
# ============================================================================

uninstall() {
    echo ""
    echo -e "${YELLOW}Uninstalling PackManager...${NC}"

    rm -f "${INSTALL_DIR}/pm"
    rm -f "${COMPLETION_DIR}/pm"
    # Don't remove config — user may want to keep it

    log "Removed pm binary"
    log "Removed bash completion"
    warn "Config preserved at ${CONFIG_DIR}/packmanager.conf"
    warn "PackWiz preserved — remove manually with: rm ${INSTALL_DIR}/packwiz"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install|"")
            header
            check_prerequisites
            install_packwiz
            install_packmanager
            install_completion
            verify
            ;;
        uninstall|remove)
            uninstall
            ;;
        *)
            echo "Usage: ./install.sh [install|uninstall]"
            exit 1
            ;;
    esac
}

main "$@"
