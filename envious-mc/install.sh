#!/usr/bin/env bash
# ============================================================================
# ELM (EnviousLabs Minecraft) — Installer
# ============================================================================
# Installs:
#   1. PackWiz (Go binary) if not present
#   2. ELM as 'elm' command on PATH
#   3. Bash completion for elm
#   4. Default config at ~/.config/elm/elm.conf
#
# Usage:
#   curl -sSL <your-host>/install.sh | bash
#   — or —
#   ./install.sh
#
# After install, use from anywhere:
#   elm init
#   elm sync
#   elm add tinkers-construct mekanism
#   elm deploy create
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
CONFIG_DIR="${HOME}/.config/elm"
COMPLETION_DIR="${HOME}/.local/share/bash-completion/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; exit 1; }

header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  ELM — EnviousLabs Minecraft — Installer${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

check_prerequisites() {
    info "Checking prerequisites..."

    # Check for Go (needed to install packwiz)
    if ! command -v go &>/dev/null && ! /usr/local/go/bin/go version &>/dev/null 2>&1; then
        warn "Go not found. Attempting to install..."
        install_go
    elif ! command -v go &>/dev/null; then
        # Go is installed but not in PATH — fix it for this session
        export GOPATH="${HOME}/go"
        export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
        hash -r 2>/dev/null || true
    fi
    log "Go $(go version 2>/dev/null | grep -oP 'go\K[0-9.]+' || echo 'unknown')"

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
    export GOPATH="${HOME}/go"
    export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"

    # Persist in shell profiles — cover bash AND profile-based shells (Rocky uses .bash_profile)
    local go_path_line='export GOPATH="${HOME}/go"'
    local go_export_line='export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"'

    for profile in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
        if [[ -f "$profile" ]] || [[ "$profile" == "${HOME}/.bashrc" ]]; then
            if ! grep -q '/usr/local/go/bin' "$profile" 2>/dev/null; then
                {
                    echo ""
                    echo "# Go (added by ELM installer)"
                    echo "$go_path_line"
                    echo "$go_export_line"
                } >> "$profile"
                info "Added Go PATH to $(basename "$profile")"
            fi
        fi
    done

    # Rehash so the current shell picks up the new binary immediately
    hash -r 2>/dev/null || true

    # Verify Go is actually callable now
    if ! /usr/local/go/bin/go version &>/dev/null; then
        fail "Go installed to /usr/local/go but binary is not executable. Check permissions."
    fi

    log "Go ${go_version} installed"
    info "Note: If 'go' isn't found after install, run: source ~/.bash_profile"
}

# ============================================================================
# INSTALL PACKWIZ
# ============================================================================

install_packwiz() {
    if command -v packwiz &>/dev/null; then
        log "PackWiz already installed: $(which packwiz)"
        return
    fi

    # Make sure Go is available
    if ! command -v go &>/dev/null; then
        if [[ -x /usr/local/go/bin/go ]]; then
            export GOPATH="${HOME}/go"
            export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
            hash -r 2>/dev/null || true
        else
            fail "Go is not installed. Cannot install PackWiz."
        fi
    fi

    info "Installing PackWiz via 'go install'..."
    go install github.com/packwiz/packwiz@latest 2>>"${LOG_FILE:-/dev/null}" || fail "Failed to install packwiz. Check Go installation and network."

    # Ensure Go bin is in PATH
    local gobin="${GOPATH:-${HOME}/go}/bin"
    if [[ -f "${gobin}/packwiz" ]]; then
        # Symlink to our install dir for reliability
        mkdir -p "$INSTALL_DIR"
        ln -sf "${gobin}/packwiz" "${INSTALL_DIR}/packwiz"
        hash -r 2>/dev/null || true
        log "PackWiz installed → ${INSTALL_DIR}/packwiz"
    else
        fail "PackWiz binary not found in ${gobin} after 'go install'. Check output above."
    fi
}

# ============================================================================
# INSTALL ELM
# ============================================================================

migrate_from_packmanager() {
    local old_config="${HOME}/.config/packmanager"
    local old_bin="${INSTALL_DIR}/pm"
    local old_completion="${COMPLETION_DIR}/pm"

    if [[ -d "$old_config" && ! -d "$CONFIG_DIR" ]]; then
        info "Migrating config from packmanager → elm..."
        mv "$old_config" "$CONFIG_DIR"
        [[ -f "${CONFIG_DIR}/packmanager.conf" ]] && mv "${CONFIG_DIR}/packmanager.conf" "${CONFIG_DIR}/elm.conf"
        log "Config migrated to ${CONFIG_DIR}"
    fi

    # Remove old pm binary/symlink
    [[ -f "$old_bin" || -L "$old_bin" ]] && rm -f "$old_bin" && log "Removed old 'pm' command"
    [[ -f "$old_completion" ]] && rm -f "$old_completion" && log "Removed old pm completion"
}

install_elm() {
    info "Installing ELM as 'elm'..."

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    # Symlink the main script
    local src="${SCRIPT_DIR}/elm.sh"
    local dest="${INSTALL_DIR}/elm"

    if [[ ! -f "$src" ]]; then
        fail "elm.sh not found in ${SCRIPT_DIR}"
    fi

    chmod +x "$src"

    # Use symlink if source is on the same filesystem, otherwise copy
    if ln -sf "$src" "$dest" 2>/dev/null; then
        log "Linked → ${dest} → ${src}"
    else
        cp "$src" "$dest"
        chmod +x "$dest"
        log "Copied → ${dest} (symlink failed — re-run install after edits)"
    fi

    # Copy default config if none exists
    if [[ ! -f "${CONFIG_DIR}/elm.conf" ]]; then
        if [[ -f "${SCRIPT_DIR}/elm.conf" ]]; then
            cp "${SCRIPT_DIR}/elm.conf" "${CONFIG_DIR}/elm.conf"
            log "Config → ${CONFIG_DIR}/elm.conf"
        else
            create_default_config
        fi
    else
        warn "Config already exists at ${CONFIG_DIR}/elm.conf — not overwriting"
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
    cat > "${CONFIG_DIR}/elm.conf" << 'CONF'
# ============================================================================
# ELM Configuration (EnviousLabs Minecraft)
# ============================================================================
# Loaded from ~/.config/elm/elm.conf
# Per-project override: place elm.conf alongside pack.toml and mods.txt.
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

# --- Sync Behavior -----------------------------------------------------------
# Mods not found during sync are auto-saved to unresolved.txt.
# Use 'elm resolve search' to find alternatives via API.
AUTO_PUBLISH=""                 # "" = off, "__auto__" = sibling cdn/ dir, "<target>" = named target

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

# --- CDN (Caddy — auto-HTTPS via Let's Encrypt) ----------------------------
CDN_DOMAIN=""                   # Set for automatic HTTPS; leave empty for http://server-ip:8080

# --- Self-Update (GitHub) --------------------------------------------------
ELM_GITHUB_REPO=""              # e.g. "yourusername/PackwizWrapper" (owner/repo)
ELM_GITHUB_BRANCH="main"        # Branch to pull updates from
ELM_GITHUB_PATH=""              # Subdirectory in repo (e.g. "envious-mc")
ELM_UPDATE_FILES="elm.sh install.sh elm.conf mods.txt"

# --- Local/Self-Hosted Mods ------------------------------------------------
LOCAL_MODS_DIR=""               # e.g. /var/www/mods — directory with JAR files
LOCAL_MODS_URL=""               # e.g. https://mods.enviouslabs.com — public URL

# --- JVM Flags (Aikar's optimized) ------------------------------------------
JVM_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
CONF

    log "Created default config → ${CONFIG_DIR}/elm.conf"
}

# ============================================================================
# INSTALL BASH COMPLETION
# ============================================================================

install_completion() {
    info "Installing bash completion..."

    mkdir -p "$COMPLETION_DIR"

    cat > "${COMPLETION_DIR}/elm" << 'COMP'
# Bash completion for elm (EnviousLabs Minecraft CLI)
_elm_completions() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="init add rm ls sync up search pin unpin export deploy target check net config key dns update resolve organize migrate nuke help"

    case "$prev" in
        elm)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return 0
            ;;
        export|ex)
            COMPREPLY=($(compgen -W "modrinth curseforge mr cf md" -- "$cur"))
            return 0
            ;;
        deploy)
            COMPREPLY=($(compgen -W "create push start stop restart status console logs backup mods regen cdn full serve remove --target" -- "$cur"))
            return 0
            ;;
        target|t)
            COMPREPLY=($(compgen -W "list add set show rm dns" -- "$cur"))
            return 0
            ;;
        resolve|res)
            COMPREPLY=($(compgen -W "auto -i list search edit remove" -- "$cur"))
            return 0
            ;;
        config|cfg)
            COMPREPLY=($(compgen -W "show edit path alias" -- "$cur"))
            return 0
            ;;
        key)
            COMPREPLY=($(compgen -W "curseforge noip duckdns dynu cloudflare list rm" -- "$cur"))
            return 0
            ;;
        dns)
            COMPREPLY=($(compgen -W "set update status auto" -- "$cur"))
            return 0
            ;;
        update)
            COMPREPLY=($(compgen -W "--check" -- "$cur"))
            return 0
            ;;
        check)
            COMPREPLY=($(compgen -W "--diff --refresh" -- "$cur"))
            return 0
            ;;
        migrate|mig)
            COMPREPLY=($(compgen -W "minecraft loader mc" -- "$cur"))
            return 0
            ;;
        ls)
            COMPREPLY=($(compgen -W "--side --version --native --deps" -- "$cur"))
            return 0
            ;;
        --side|-s)
            COMPREPLY=($(compgen -W "client server both" -- "$cur"))
            return 0
            ;;
        --target|-t)
            local targets_file="${HOME}/.config/elm/targets.json"
            if [[ -f "$targets_file" ]] && command -v jq &>/dev/null; then
                local target_names
                target_names=$(jq -r 'keys[]' "$targets_file" 2>/dev/null)
                COMPREPLY=($(compgen -W "$target_names" -- "$cur"))
            fi
            return 0
            ;;
        rm|pin|unpin)
            if [[ -d "mods" ]]; then
                local mods
                mods=$(find mods -name "*.pw.toml" -exec basename {} .pw.toml \; 2>/dev/null)
                COMPREPLY=($(compgen -W "$mods" -- "$cur"))
            fi
            return 0
            ;;
        add|a)
            if [[ "$cur" == file:* ]]; then
                local path_part="${cur#file:}"
                local completions
                completions=$(compgen -f -- "$path_part" 2>/dev/null)
                COMPREPLY=($(printf "file:%s\n" $completions))
            elif [[ -f "mods.txt" ]]; then
                local slugs
                slugs=$(grep -vE '^\s*#|^\s*$' mods.txt | sed 's/\s*#.*$//;s/^!//;s/^mr://;s/^cf://;s/^url://;s/^local://' | xargs)
                COMPREPLY=($(compgen -W "$slugs file: --stage --import" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "file: --stage --import" -- "$cur"))
            fi
            return 0
            ;;
        search|s)
            COMPREPLY=($(compgen -W "--open" -- "$cur"))
            return 0
            ;;
    esac

    # Default: command completion
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    fi
}

complete -F _elm_completions elm
COMP

    # Source it in bashrc if not already
    local source_line="[[ -f ${COMPLETION_DIR}/elm ]] && source ${COMPLETION_DIR}/elm"
    if ! grep -qF "bash-completion/completions/elm" "${HOME}/.bashrc" 2>/dev/null; then
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

    if command -v elm &>/dev/null; then
        log "elm command available"
    else
        warn "elm not found in PATH — restart your shell or run: source ~/.bashrc"
        all_good=false
    fi

    if command -v packwiz &>/dev/null; then
        log "packwiz available"
    else
        warn "packwiz not found in PATH — restart your shell"
        all_good=false
    fi

    if [[ -f "${CONFIG_DIR}/elm.conf" ]]; then
        log "Config at ${CONFIG_DIR}/elm.conf"
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
    echo -e "    ${CYAN}elm init${NC}              Initialize a pack in the current directory"
    echo -e "    ${CYAN}elm sync${NC}              Install all mods from mods.txt"
    echo -e "    ${CYAN}elm add <slug>${NC}        Add a mod"
    echo -e "    ${CYAN}elm key cf <KEY>${NC}      Set CurseForge API key"
    echo -e "    ${CYAN}elm deploy create${NC}     Publish pack + generate Docker compose"
    echo -e "    ${CYAN}elm deploy full${NC}       Pipeline: sync → publish → compose → start"
    echo -e "    ${CYAN}elm config edit${NC}       Edit your config"
    echo ""
    echo -e "  ${BOLD}Config:${NC} ${CYAN}${CONFIG_DIR}/elm.conf${NC}"
    echo -e "  ${BOLD}Docs:${NC}   ${CYAN}elm help${NC}"
    echo ""
}

# ============================================================================
# UNINSTALL
# ============================================================================

uninstall() {
    echo ""
    echo -e "${YELLOW}Uninstalling ELM...${NC}"

    rm -f "${INSTALL_DIR}/elm"
    rm -f "${COMPLETION_DIR}/elm"
    # Don't remove config — user may want to keep it

    log "Removed elm binary"
    log "Removed bash completion"
    warn "Config preserved at ${CONFIG_DIR}/elm.conf"
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
            migrate_from_packmanager
            install_elm
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
