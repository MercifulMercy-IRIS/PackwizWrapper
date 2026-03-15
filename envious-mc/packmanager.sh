#!/usr/bin/env bash
# ============================================================================
# ELM v1.0.0 — EnviousLabs Minecraft CLI
# ============================================================================
#
# USAGE:
#   elm <command> [args]
#
# Run 'elm help' for full command reference.
#
# ============================================================================

set -uo pipefail

# ============================================================================
# CONFIG LOADING
# ============================================================================
# Priority: local elm.conf > global ~/.config/elm/elm.conf > defaults

# Defaults
PACK_DIR="$(pwd)"
MODS_FILE="${PACK_DIR}/mods.txt"
LOG_DIR="${PACK_DIR}/.logs"
PACKWIZ_BIN="packwiz"
MC_VERSION="1.20.1"
LOADER="forge"
LOADER_VERSION=""
RETRY_ATTEMPTS=2
RETRY_DELAY=3
AUTO_DEPS=true
PREFER_SOURCE="mr"
# When a mod can't be found during sync, it's automatically saved
# to unresolved.txt. Use 'elm resolve search' to find alternatives.
AUTO_PUBLISH=""                    # Target name to auto-publish to CDN after sync/update
                                   #   "" = disabled, "<target>" = auto-run publish_cdn after sync/update

# Docker / Server defaults
DOCKER_COMPOSE_DIR="${HOME}/.config/elm/servers"  # Where compose files live
SERVER_IMAGE="itzg/minecraft-server:java17"
SERVER_RAM="8192"
SERVER_DISK="25600"
SERVER_CPU="400"
SERVER_BASE_PORT=25565               # First server gets this, +1 for each after
SERVER_RCON_BASE_PORT=25575          # RCON base port
SERVER_DOMAIN=""                     # Base domain (e.g. enviouslabs.com)
SERVER_VM_IP=""                      # Public/Tailscale IP of the Docker VM

# Pack hosting
PACK_HOST_URL=""
PACK_HOST_DIR=""

# CDN — serves pack files + mod JARs to clients via Caddy (auto-HTTPS)
CDN_DOMAIN=""                      # e.g. "pack.enviouslabs.com" (per-target override via targets set)
                                   # If set, Caddy auto-provisions HTTPS via Let's Encrypt
                                   # If empty, serves on http://<server-ip>:8080

# Self-update (GitHub)
ELM_GITHUB_REPO=""               # e.g. "yourusername/PackwizWrapper" (owner/repo)
ELM_GITHUB_BRANCH="main"         # Branch to pull updates from
ELM_GITHUB_PATH=""               # Subdirectory in repo where files live (e.g. "envious-mc")
ELM_UPDATE_FILES="elm.sh install.sh elm.conf mods.txt"  # Files to update

# CurseForge API key (optional — enables fuzzy search on CurseForge)
# Get one free at https://console.curseforge.com
CURSEFORGE_API_KEY=""


# Local/self-hosted mods (for mods not on Modrinth/CurseForge)
LOCAL_MODS_DIR=""               # e.g. /var/www/mods — served by Caddy/tunnel
LOCAL_MODS_URL=""               # e.g. https://mods.enviouslabs.com

# JVM
JVM_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1"

# Migrate from packmanager -> elm config paths
_old_config="${HOME}/.config/packmanager"
_new_config="${HOME}/.config/elm"
if [[ -d "$_old_config" && ! -d "$_new_config" ]]; then
    echo -e "${YELLOW:-}Migrating config from packmanager -> elm...${NC:-}"
    mv "$_old_config" "$_new_config"
    [[ -f "${_new_config}/packmanager.conf" ]] && mv "${_new_config}/packmanager.conf" "${_new_config}/elm.conf"
    echo -e "${GREEN:-}Done. Config now at ${_new_config}${NC:-}"
fi
unset _old_config _new_config

# Map legacy PM_ variables if user still has old config
[[ -n "${PM_GITHUB_REPO:-}" && -z "${ELM_GITHUB_REPO:-}" ]] && ELM_GITHUB_REPO="$PM_GITHUB_REPO"
[[ -n "${PM_GITHUB_BRANCH:-}" && -z "${ELM_GITHUB_BRANCH:-}" ]] && ELM_GITHUB_BRANCH="$PM_GITHUB_BRANCH"
[[ -n "${PM_GITHUB_PATH:-}" && -z "${ELM_GITHUB_PATH:-}" ]] && ELM_GITHUB_PATH="$PM_GITHUB_PATH"
[[ -n "${PM_UPDATE_FILES:-}" && -z "${ELM_UPDATE_FILES:-}" ]] && ELM_UPDATE_FILES="$PM_UPDATE_FILES"

# Load global config
GLOBAL_CONF="${HOME}/.config/elm/elm.conf"
[[ -f "$GLOBAL_CONF" ]] && source "$GLOBAL_CONF"

# Load local config (overrides global)
LOCAL_CONF="${PACK_DIR}/elm.conf"
[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"

# Load API keys (separate file, chmod 600)
KEYS_FILE="${HOME}/.config/elm/keys.conf"
[[ -f "$KEYS_FILE" ]] && source "$KEYS_FILE"

# Load DNS config
DNS_CONF="${HOME}/.config/elm/dns.conf"
[[ -f "$DNS_CONF" ]] && source "$DNS_CONF"

# ============================================================================
# PACK DIRECTORY DISCOVERY
# ============================================================================
# If PACK_DIR (pwd) doesn't contain pack.toml, try to find it:
#   1. pack/ subdirectory (organized layout)
#   2. Walk up parent directories (running from server/ or cdn/)
#   3. Sibling pack/ when standing in server/ or cdn/
# This lets elm work from the project root, from server/, or from anywhere
# inside an organized tree without needing to cd into pack/ first.

discover_pack_dir() {
    local dir="$1"

    # Already has pack.toml — nothing to do
    [[ -f "${dir}/pack.toml" ]] && { echo "$dir"; return 0; }

    # Check pack/ subdirectory (organized layout: root/pack/)
    [[ -f "${dir}/pack/pack.toml" ]] && { echo "${dir}/pack"; return 0; }

    # Check if we're inside server/ or cdn/ — look for sibling pack/
    local dirname
    dirname=$(basename "$dir")
    if [[ "$dirname" == "server" || "$dirname" == "cdn" ]]; then
        local parent
        parent=$(dirname "$dir")
        [[ -f "${parent}/pack/pack.toml" ]] && { echo "${parent}/pack"; return 0; }
    fi

    # Walk up to 3 parent directories
    local walk="$dir"
    local depth=0
    while (( depth < 3 )); do
        walk=$(dirname "$walk")
        [[ "$walk" == "/" || "$walk" == "." ]] && break
        [[ -f "${walk}/pack.toml" ]] && { echo "$walk"; return 0; }
        [[ -f "${walk}/pack/pack.toml" ]] && { echo "${walk}/pack"; return 0; }
        (( depth++ ))
    done

    # Not found — return original dir (check_pack_init will handle the error)
    echo "$dir"
    return 1
}

# Only auto-discover if the current PACK_DIR doesn't have pack.toml
# and the user hasn't explicitly set PACK_DIR in config
_ORIGINAL_DIR="$PACK_DIR"
if [[ ! -f "${PACK_DIR}/pack.toml" ]]; then
    _discovered=$(discover_pack_dir "$PACK_DIR")
    if [[ -f "${_discovered}/pack.toml" ]]; then
        PACK_DIR="$_discovered"
    fi
    unset _discovered
fi

# Re-derive paths after config load + discovery
MODS_FILE="${PACK_DIR}/mods.txt"
UNRESOLVED_FILE="${PACK_DIR}/unresolved.txt"
LOG_DIR="${PACK_DIR}/.logs"
# Staging directory — drop JAR files here for batch matching against unresolved mods
STAGING_DIR="$(dirname "$PACK_DIR")/staging"

# Also try to load a local config from the discovered pack dir
# (in case discovery moved us and there's a elm.conf there)
if [[ -f "${PACK_DIR}/elm.conf" && "${PACK_DIR}/elm.conf" != "$LOCAL_CONF" ]]; then
    source "${PACK_DIR}/elm.conf"
    LOCAL_CONF="${PACK_DIR}/elm.conf"
    # Re-derive again after this config
    MODS_FILE="${PACK_DIR}/mods.txt"
    UNRESOLVED_FILE="${PACK_DIR}/unresolved.txt"
    LOG_DIR="${PACK_DIR}/.logs"
    STAGING_DIR="$(dirname "$PACK_DIR")/staging"
fi

# Handle stray files: if mods.txt / unresolved.txt exist at the original dir
# (project root) but not in the discovered pack dir, use the root copies.
# This covers partially-organized layouts where some files didn't move.
if [[ "$_ORIGINAL_DIR" != "$PACK_DIR" ]]; then
    if [[ ! -f "$MODS_FILE" && -f "${_ORIGINAL_DIR}/mods.txt" ]]; then
        MODS_FILE="${_ORIGINAL_DIR}/mods.txt"
    fi
    if [[ ! -f "$UNRESOLVED_FILE" && -f "${_ORIGINAL_DIR}/unresolved.txt" ]]; then
        UNRESOLVED_FILE="${_ORIGINAL_DIR}/unresolved.txt"
    fi
fi
unset _ORIGINAL_DIR

# Setup
mkdir -p "$LOG_DIR" 2>/dev/null || true
RUN_LOG="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
touch "$RUN_LOG" 2>/dev/null || RUN_LOG="/tmp/elm_run_$$.log"

DEPS_ADDED=()
UNRESOLVED_ADDED=()    # Mods saved to unresolved.txt this run

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Packwiz wrapper — always runs from PACK_DIR ─────────────────────
# Packwiz requires pwd to contain pack.toml. This wrapper ensures every
# call runs from the correct directory, even when elm is invoked from the
# project root or a sibling directory like server/.
pw() {
    (cd "$PACK_DIR" && "$PACKWIZ_BIN" "$@")
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log()       { local l="$1"; shift; echo "$(date '+%H:%M:%S') [${l}] $*" >> "$RUN_LOG"
              case "$l" in
                OK)   echo -e "  ${GREEN}✓${NC} $*" ;;
                FAIL) echo -e "  ${RED}✗${NC} $*" ;;
                WARN) echo -e "  ${YELLOW}⚠${NC} $*" ;;
                INFO) echo -e "  ${BLUE}→${NC} $*" ;;
                SKIP) echo -e "  ${CYAN}⊘${NC} $*" ;;
                DEP)  echo -e "  ${MAGENTA}↳${NC} $*" ;;
              esac; }
header()    { echo ""; echo -e "${BOLD}═══ $* ═══${NC}"; echo ""; }
separator() { echo -e "${DIM}  ─────────────────────────────────────────${NC}"; }

# Normalize a slug/name for comparison: lowercase, strip underscores/hyphens/spaces
normalize_slug() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_ -'
}

check_packwiz() {
    command -v "$PACKWIZ_BIN" &>/dev/null || {
        echo -e "${RED}Error: packwiz not found.${NC}"
        echo "Install with: elm --install-packwiz"
        echo "Or set PACKWIZ_BIN in config"
        exit 1
    }
}

check_pack_init() {
    [[ -f "${PACK_DIR}/pack.toml" ]] || {
        echo -e "${RED}No pack.toml found.${NC}"
        echo ""
        echo -e "  Looked in: ${CYAN}${PACK_DIR}${NC}"
        # Suggest where it might actually be
        if [[ -f "$(pwd)/pack/pack.toml" ]]; then
            echo -e "  ${GREEN}Found it at:${NC} ${CYAN}$(pwd)/pack/pack.toml${NC}"
            echo -e "  This should have been auto-detected — check your config."
        fi
        echo ""
        echo -e "  ${BOLD}Fixes:${NC}"
        echo -e "    • cd into your pack directory and retry"
        echo -e "    • Run ${CYAN}elm init${NC} to create a new pack here"
        echo -e "    • Run ${CYAN}elm organize${NC} if your files are scattered"
        exit 1
    }
}

check_docker() {
    command -v docker &>/dev/null || {
        echo -e "${RED}Docker not found. Install: https://docs.docker.com/engine/install/${NC}"
        exit 1
    }
    docker compose version &>/dev/null 2>&1 || docker-compose version &>/dev/null 2>&1 || {
        echo -e "${RED}Docker Compose not found.${NC}"
        exit 1
    }
}

is_installed() {
    local slug="$1"
    [[ -d "${PACK_DIR}/mods" ]] || return 1
    find "${PACK_DIR}/mods" -maxdepth 1 -name "${slug}.pw.toml" -print -quit 2>/dev/null | grep -q . && return 0
    grep -rlq "\"${slug}\"" "${PACK_DIR}/mods/"*.pw.toml 2>/dev/null && return 0
    return 1
}

is_in_modlist() {
    local slug="$1"
    [[ -f "$MODS_FILE" ]] || return 1
    grep -qE "^!?((mr|cf|url|local):)?${slug}(\s|#|$)" "$MODS_FILE" 2>/dev/null
}

add_to_unresolved() {
    local slug="$1" reason="${2:-not found}"
    # Create file with header if it doesn't exist
    if [[ ! -f "$UNRESOLVED_FILE" ]]; then
        cat > "$UNRESOLVED_FILE" << 'HEADER'
# ELM — Unresolved Mods
# These mods weren't found on Modrinth or CurseForge.
# Add a URL or local JAR binding, then move to mods.txt:
#
#   url:https://example.com/my-mod-1.0.jar
#   local:my-mod
#
# Or remove lines you no longer need.
HEADER
    fi
    # Don't add duplicates
    if ! grep -qE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" 2>/dev/null; then
        printf '%-35s # %s\n' "$slug" "$reason" >> "$UNRESOLVED_FILE"
    fi
    UNRESOLVED_ADDED+=("$slug")
}

is_unresolved() {
    local slug="$1"
    [[ -f "$UNRESOLVED_FILE" ]] || return 1
    grep -qE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" 2>/dev/null
}

append_to_modlist() {
    local entry="$1" comment="${2:-}"
    if [[ -n "$comment" ]]; then
        printf '%-35s # %s\n' "$entry" "$comment" >> "$MODS_FILE"
    else
        echo "$entry" >> "$MODS_FILE"
    fi
}

# ============================================================================
# MODS.TXT PARSER
# ============================================================================

parse_mod_entry() {
    local raw="$1"
    raw="$(echo "$raw" | sed 's/\s*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$raw" || "$raw" == \#* || "$raw" == @* ]] && return 1

    local pinned=false source="auto" slug="" url=""
    [[ "$raw" == !* ]] && { pinned=true; raw="${raw:1}"; }

    if   [[ "$raw" == mr:* ]];    then source="modrinth";   slug="${raw#mr:}"
    elif [[ "$raw" == cf:* ]];    then source="curseforge";  slug="${raw#cf:}"
    elif [[ "$raw" == url:* ]];   then source="url"; url="${raw#url:}"; slug="$(basename "$url" .jar | sed 's/[-_][0-9].*$//')"
    elif [[ "$raw" == local:* ]]; then source="local"; slug="${raw#local:}"; slug="$(basename "$slug" .jar)"
    elif [[ "$raw" == https://www.curseforge.com/* ]]; then source="curseforge"; url="$raw"; slug="$raw"
    elif [[ "$raw" == https://modrinth.com/* ]];       then source="modrinth";  url="$raw"; slug="$raw"
    elif [[ "$raw" == https://* || "$raw" == http://* ]]; then source="url"; url="$raw"; slug="$(basename "$raw" .jar | sed 's/[-_][0-9].*$//')"
    else source="auto"; slug="$raw"
    fi

    echo "${source}|${slug}|${url}|${pinned}"
}

# ============================================================================
# POST-INSTALL VERIFICATION
# ============================================================================
# After packwiz installs a mod, we read the .pw.toml it generated and verify
# the resolved mod actually matches what was requested. This catches:
#   - Fuzzy match grabs (asked for "sound", got "sound-physics-remastered")
#   - Slug aliasing (asked for "ae2", installed "applied-energistics-2")
#   - Completely wrong mods from ambiguous search hits

# Read a .pw.toml and extract key fields
parse_pw_toml() {
    local toml_file="$1"
    [[ -f "$toml_file" ]] || return 1

    local name slug mod_id source filename
    name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml_file" 2>/dev/null || echo "")
    filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml_file" 2>/dev/null || echo "")
    slug=$(basename "$toml_file" .pw.toml)

    # Determine source and mod-id
    if grep -q '\[update\.modrinth\]' "$toml_file" 2>/dev/null; then
        source="modrinth"
        mod_id=$(grep -A5 '\[update\.modrinth\]' "$toml_file" | grep -oP 'mod-id\s*=\s*"\K[^"]+' 2>/dev/null || echo "")
    elif grep -q '\[update\.curseforge\]' "$toml_file" 2>/dev/null; then
        source="curseforge"
        mod_id=$(grep -A5 '\[update\.curseforge\]' "$toml_file" | grep -oP '(project-id|file-id)\s*=\s*\K[0-9]+' 2>/dev/null | head -1 || echo "")
    else
        source="url"
        mod_id=""
    fi

    echo "${slug}|${name}|${mod_id}|${source}|${filename}"
}

# ============================================================================
# ALIAS TRACKING
# ============================================================================
# Aliases are stored in a JSON file so we can track what the user originally
# requested vs what packwiz actually installed. This lets us:
#   - Skip re-prompting for already-approved aliases
#   - List all aliases with `elm config alias`
#   - Remove aliased mods with `elm config alias remove <slug>`

ALIASES_FILE="${HOME}/.config/elm/aliases.json"

init_aliases_file() {
    mkdir -p "$(dirname "$ALIASES_FILE")"
    [[ -f "$ALIASES_FILE" ]] || echo '{}' > "$ALIASES_FILE"
}

alias_get() {
    # Check if a requested slug has an approved alias
    local requested="$1"
    init_aliases_file
    jq -r --arg r "$requested" '.[$r].resolved // empty' "$ALIASES_FILE" 2>/dev/null
}

alias_save() {
    local requested="$1" resolved_slug="$2" resolved_name="$3" toml_file="$4"
    init_aliases_file
    local tmp; tmp=$(mktemp)
    jq --arg r "$requested" --arg s "$resolved_slug" --arg n "$resolved_name" --arg f "$toml_file" \
        '.[$r] = {"resolved": $s, "name": $n, "toml": $f, "approved_at": (now | todate)}' \
        "$ALIASES_FILE" > "$tmp"
    mv "$tmp" "$ALIASES_FILE"
}

alias_remove() {
    local requested="$1"
    init_aliases_file
    local tmp; tmp=$(mktemp)
    jq --arg r "$requested" 'del(.[$r])' "$ALIASES_FILE" > "$tmp"
    mv "$tmp" "$ALIASES_FILE"
}

# Verify a single mod after installation
# Returns 0 if match is good, 1 if mismatch (auto-removed + unresolved)
verify_mod_install() {
    local requested_slug="$1"

    # Find the .pw.toml that was just created
    # PackWiz may name it differently from what we requested
    local toml_file=""

    # First: exact slug match
    if [[ -f "${PACK_DIR}/mods/${requested_slug}.pw.toml" ]]; then
        toml_file="${PACK_DIR}/mods/${requested_slug}.pw.toml"
    else
        # Search for recently modified toml files (created in last 30 seconds)
        toml_file=$(find "${PACK_DIR}/mods" -name "*.pw.toml" -newer "$RUN_LOG" -print 2>/dev/null | tail -1)
    fi

    [[ -z "$toml_file" || ! -f "$toml_file" ]] && return 0  # Can't verify, skip

    local parsed
    parsed=$(parse_pw_toml "$toml_file") || return 0
    IFS='|' read -r resolved_slug resolved_name resolved_id resolved_source resolved_filename <<< "$parsed"

    # Normalize for comparison
    local req_norm res_norm
    req_norm=$(normalize_slug "$requested_slug")
    res_norm=$(normalize_slug "$resolved_slug")

    # Slug match (exact or normalized) — all good
    if [[ "$req_norm" == "$res_norm" ]]; then
        return 0
    fi

    # ── Wrong mod — auto-remove and save to unresolved ──
    # PackWiz often resolves to a similar-sounding but wrong mod.
    # Instead of keeping it (or prompting), remove immediately
    # and let the user resolve it manually via staging/ or search.

    echo -e "  ${RED}⚠ WRONG MOD${NC}: asked for ${BOLD}${requested_slug}${NC}, got ${BOLD}${resolved_name}${NC} (${resolved_slug})"
    log WARN "Removing wrong mod: ${resolved_slug} (wanted ${requested_slug})"
    echo "MISMATCH REMOVED: requested='${requested_slug}' got='${resolved_slug}' (${resolved_name})" >> "$RUN_LOG"

    # Remove the wrong mod from the pack
    pw remove "$resolved_slug" --yes 2>>"$RUN_LOG" || rm -f "$toml_file"
    pw refresh 2>>"$RUN_LOG" || true

    # Save to unresolved for later resolution
    add_to_unresolved "$requested_slug" "got wrong mod: ${resolved_name} (${resolved_slug})"
    echo -e "    ${DIM}→ saved to unresolved.txt${NC}"
    echo -e "    ${DIM}Resolve with: ${CYAN}elm search ${requested_slug}${NC}  or  ${CYAN}elm add --stage${NC}"

    return 1
}

# Full audit: compare every .pw.toml against mods.txt
verify_all_mods() {
    header "Mod Verification Audit"

    [[ -d "${PACK_DIR}/mods" ]] || { echo -e "  ${DIM}No mods installed.${NC}"; return; }
    [[ -f "$MODS_FILE" ]] || { echo -e "  ${DIM}No mods.txt found.${NC}"; return; }

    local checked=0 ok=0 fuzzy=0 unlisted=0 missing=0
    local unlisted_report=()
    local missing_report=()

    echo -e "  ${BLUE}Checking installed mods against mods.txt...${NC}"
    echo ""

    # Build a lookup of requested slugs from mods.txt
    declare -A requested_slugs
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue

        local parsed
        parsed="$(parse_mod_entry "$line")" || continue
        IFS='|' read -r _ slug _ _ <<< "$parsed"
        requested_slugs["$slug"]=1
    done < "$MODS_FILE"

    # Check each installed .pw.toml
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        (( checked++ ))

        local parsed
        parsed=$(parse_pw_toml "$toml") || continue
        IFS='|' read -r resolved_slug resolved_name resolved_id resolved_source resolved_filename <<< "$parsed"

        # Is this mod in mods.txt?
        if [[ -z "${requested_slugs[$resolved_slug]+_}" ]]; then
            # Not in mods.txt — could be a dependency or a misnamed install
            # Check if ANY slug in mods.txt roughly matches this resolved name
            local found_match=false
            for req_slug in "${!requested_slugs[@]}"; do
                local req_norm res_norm name_norm
                req_norm=$(normalize_slug "$req_slug")
                res_norm=$(normalize_slug "$resolved_slug")
                name_norm=$(normalize_slug "$resolved_name")

                if [[ "$req_norm" == "$res_norm" ]]; then
                    found_match=true
                    (( ok++ ))
                    break
                elif [[ "$name_norm" == *"$req_norm"* || "$res_norm" == *"$req_norm"* ]]; then
                    found_match=true
                    (( fuzzy++ ))
                    echo -e "  ${YELLOW}↔${NC} ${resolved_slug} ← ${req_slug} ${DIM}(fuzzy match — may be wrong mod)${NC}"
                    break
                fi
            done

            if ! $found_match; then
                (( unlisted++ ))
                unlisted_report+=("${resolved_slug}|${resolved_name}")
            fi
        else
            (( ok++ ))
        fi
    done

    # Check for mods in mods.txt that aren't installed at all
    for req_slug in "${!requested_slugs[@]}"; do
        if ! is_installed "$req_slug"; then
            # Check if installed under a different slug/alias
            local found=false
            for toml in "${PACK_DIR}/mods/"*.pw.toml; do
                [[ -f "$toml" ]] || continue
                local res_slug
                res_slug=$(basename "$toml" .pw.toml)
                local res_name
                res_name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")
                local rn rr nn
                rn=$(normalize_slug "$req_slug")
                rr=$(normalize_slug "$res_slug")
                nn=$(normalize_slug "$res_name")

                if [[ "$nn" == *"$rn"* || "$rr" == *"$rn"* || "$rn" == *"$rr"* ]]; then
                    found=true
                    break
                fi
            done

            if ! $found; then
                (( missing++ ))
                missing_report+=("$req_slug")
            fi
        fi
    done

    # --- RESULTS ---
    separator
    echo ""
    echo -e "  ${BOLD}Audit Results${NC}"
    echo -e "  Checked:    ${BOLD}${checked}${NC} installed .pw.toml files"
    echo -e "  Matched:    ${GREEN}${ok}${NC} exact matches"
    echo -e "  Fuzzy:      ${YELLOW}${fuzzy}${NC} slug ≠ filename (may be wrong mod)"
    echo -e "  Unlisted:   ${MAGENTA}${unlisted}${NC} installed but not in mods.txt (deps)"
    echo -e "  Missing:    ${RED}${missing}${NC} in mods.txt but not installed"

    # Unlisted mods (likely dependencies)
    if (( unlisted > 0 )); then
        echo ""
        echo -e "  ${MAGENTA}Unlisted mods (probably dependencies):${NC}"
        for entry in "${unlisted_report[@]}"; do
            IFS='|' read -r uslug uname <<< "$entry"
            echo -e "    ${MAGENTA}↳${NC} ${uname} ${DIM}(${uslug})${NC}"
        done
    fi

    # Missing mods
    if (( missing > 0 )); then
        echo ""
        echo -e "  ${RED}${BOLD}Missing mods (in mods.txt, not installed):${NC}"
        for m in "${missing_report[@]}"; do
            echo -e "    ${RED}✗${NC} ${m}"
        done
        echo ""
        echo -e "  ${YELLOW}Run 'elm sync' to install these, or check slugs.${NC}"
    fi

    # Write full audit to log
    {
        echo "=== Verification Audit $(date) ==="
        echo "Checked: $checked  OK: $ok  Aliased: $aliased  Unlisted: $unlisted  Missing: $missing"
        for entry in "${unlisted_report[@]:-}"; do echo "UNLISTED: $entry"; done
        for m in "${missing_report[@]:-}"; do echo "MISSING: $m"; done
    } >> "$RUN_LOG"

    echo ""
    if (( missing == 0 )); then
        echo -e "  ${GREEN}${BOLD}All mods.txt entries are accounted for.${NC}"
    fi
    echo -e "  Full log: ${CYAN}${RUN_LOG}${NC}"
    echo ""
}

# ============================================================================
# INSTALL ENGINE
# ============================================================================

run_packwiz_install() {
    local cmd="$1" slug="$2"
    local output="" exit_code=0

    output=$(pw "$cmd" install "$slug" --yes 2>&1) || exit_code=$?
    echo "$output" >> "$RUN_LOG"

    # Parse dependencies from packwiz output
    local dep_lines
    dep_lines=$(echo "$output" | grep -iE "(dependency|dependencies|also install)" || true)
    if [[ -n "$dep_lines" ]]; then
        while IFS= read -r dline; do
            local dep_name
            dep_name=$(echo "$dline" | grep -oP "[\x27\"]\K[^\x27\"]+" | head -1 || true)
            if [[ -n "$dep_name" ]]; then
                DEPS_ADDED+=("$dep_name")
                log DEP "Auto-installed: ${dep_name}"
            fi
        done <<< "$dep_lines"
    fi

    return "$exit_code"
}

# Retry wrapper for packwiz install commands (works for any source)
try_source() {
    local source="$1" slug="$2" attempt=0
    while (( attempt < RETRY_ATTEMPTS )); do
        run_packwiz_install "$source" "$slug" && return 0
        (( attempt++ ))
        (( attempt < RETRY_ATTEMPTS )) && sleep "$RETRY_DELAY"
    done
    return 1
}

# Convenience aliases
try_modrinth()   { try_source "modrinth" "$1"; }
try_curseforge() { try_source "curseforge" "$1"; }

try_url() {
    local url="$1" slug="$2"
    # packwiz url add <display-name> <download-url> [--force] [--meta-name <filename>]
    pw url add "$slug" "$url" --force --yes 2>>"$RUN_LOG"
}

# Generate .pw.toml manually for local/self-hosted mods
# This is the documented approach for mods not on MR/CF:
# https://packwiz.infra.link/tutorials/creating/adding-mods/
try_local() {
    local slug="$1"
    local jar_name="${slug}.jar"
    local jar_path=""
    local download_url=""

    # Find the JAR file
    if [[ -n "$LOCAL_MODS_DIR" && -f "${LOCAL_MODS_DIR}/${jar_name}" ]]; then
        jar_path="${LOCAL_MODS_DIR}/${jar_name}"
    elif [[ -f "${PACK_DIR}/${jar_name}" ]]; then
        jar_path="${PACK_DIR}/${jar_name}"
    elif [[ -f "${PACK_DIR}/mods/${jar_name}" ]]; then
        jar_path="${PACK_DIR}/mods/${jar_name}"
    else
        # Try glob match (version numbers in filename)
        jar_path=$(find "${LOCAL_MODS_DIR:-${PACK_DIR}}" -maxdepth 1 -name "${slug}*.jar" -print -quit 2>/dev/null || true)
    fi

    if [[ -z "$jar_path" || ! -f "$jar_path" ]]; then
        log FAIL "${slug} — JAR not found in LOCAL_MODS_DIR (${LOCAL_MODS_DIR:-not set})"
        return 1
    fi

    local actual_filename
    actual_filename=$(basename "$jar_path")

    # Build download URL
    if [[ -n "$LOCAL_MODS_URL" ]]; then
        download_url="${LOCAL_MODS_URL}/${actual_filename}"
    else
        # Fall back to packwiz serve URL
        download_url="http://localhost:8080/mods/${actual_filename}"
        log WARN "LOCAL_MODS_URL not set — using localhost. Set it in config for production."
    fi

    # Compute SHA256 hash
    local hash
    hash=$(sha256sum "$jar_path" | cut -d' ' -f1) || { log FAIL "hash failed"; return 1; }

    # Generate .pw.toml
    local toml_path="${PACK_DIR}/mods/${slug}.pw.toml"
    cat > "$toml_path" << TOML
name = "${slug}"
filename = "${actual_filename}"
side = "both"

[download]
url = "${download_url}"
hash-format = "sha256"
hash = "${hash}"
TOML

    log DEP "Generated .pw.toml → ${download_url}"

    # Copy JAR to mods dir if it's not already there (for local serve testing)
    if [[ ! -f "${PACK_DIR}/mods/${actual_filename}" && -f "$jar_path" ]]; then
        cp "$jar_path" "${PACK_DIR}/mods/${actual_filename}" 2>/dev/null || true
    fi

    # Refresh index to pick up the new .pw.toml
    pw refresh 2>>"$RUN_LOG" || true
    return 0
}

install_mod() {
    local source="$1" slug="$2" url="$3" pinned="$4"

    is_installed "$slug" && { log SKIP "${slug} (already installed)"; return 0; }

    local installed=false
    local via=""

    case "$source" in
        modrinth)
            try_modrinth "$slug" && { installed=true; via="Modrinth"; }
            ;;
        curseforge)
            try_curseforge "$slug" && { installed=true; via="CurseForge"; }
            ;;
        url)
            try_url "$url" "$slug" && { installed=true; via="URL"; }
            ;;
        local)
            try_local "$slug" && { installed=true; via="Local"; }
            ;;
        auto)
            local first second fn sn fp
            if [[ "$PREFER_SOURCE" == "cf" ]]; then
                first="try_curseforge"; second="try_modrinth"
                fn="CurseForge"; sn="Modrinth"; fp="mr"
            else
                first="try_modrinth"; second="try_curseforge"
                fn="Modrinth"; sn="CurseForge"; fp="cf"
            fi

            if $first "$slug"; then
                installed=true; via="$fn"
            else
                log WARN "${slug} not on ${fn}, trying ${sn}..."
                if $second "$slug"; then
                    installed=true; via="${sn} fallback"
                    echo -e "    ${DIM}Tip: Pin as '${fp}:${slug}' in mods.txt${NC}"
                fi
            fi
            ;;
    esac

    # --- Direct-download fallback: bypass packwiz, resolve via API + self-host ---
    # If packwiz couldn't install it (or we haven't tried yet), use the Modrinth/CF
    # version APIs directly to find the exact file, download the JAR, and import it.
    if ! $installed && [[ "$source" != "url" && "$source" != "local" ]]; then
        log WARN "${slug} — trying direct API resolution..."
        if modrinth_download_mod "$slug"; then
            installed=true; via="Modrinth direct"
        elif [[ -n "$CURSEFORGE_API_KEY" ]] && curseforge_download_mod "$slug"; then
            installed=true; via="CurseForge direct"
        fi
    fi

    # --- Fuzzy resolution fallback: try slug variations + search ---
    if ! $installed && [[ "$source" != "url" && "$source" != "local" ]]; then
        if fuzzy_resolve_mod "$slug" "false"; then
            installed=true; via="fuzzy resolve (${FUZZY_RESOLVED_AS:-search})"
        fi
    fi

    # --- Mod not found on any source ---
    if ! $installed; then
        echo ""
        echo -e "  ${RED}${BOLD}NOT FOUND${NC}: ${BOLD}${slug}${NC}"
        echo -e "  ${DIM}Not available on Modrinth or CurseForge (source: ${source})${NC}"

        # Always auto-save to unresolved.txt — no prompting
        add_to_unresolved "$slug" "not found on ${source}"
        log WARN "${slug} → saved to unresolved.txt"
        echo -e "  ${DIM}Investigate: ${CYAN}${UNRESOLVED_FILE}${NC}"
        echo -e "  ${DIM}Try:         ${CYAN}elm search ${slug}${NC}  or  ${CYAN}elm resolve search ${slug}${NC}"
        return 1
    fi

    # Verify what actually got installed matches what we asked for
    if $installed; then
        if verify_mod_install "$slug"; then
            log OK "${slug} ${DIM}(${via})${NC}"
        else
            # Wrong mod was auto-removed and saved to unresolved
            return 1
        fi
    fi

    return 0
}


# ============================================================================
# MOD SEARCH (Modrinth + CurseForge APIs)
# ============================================================================
# Fuzzy search for mods by name/slug across both platforms.
# Modrinth's API is free with no key. CurseForge requires CURSEFORGE_API_KEY.
# Used by: elm search <query>, elm resolve search, and sync failure suggestions.

# User-Agent for API requests (good etiquette)
ELM_USER_AGENT="ELM/1 (EnviousLabsMinecraft) (github.com/PackwizWrapper)"

# Search Modrinth API — returns tab-separated: slug \t name \t downloads \t description
search_modrinth_api() {
    local query="$1" limit="${2:-10}"
    command -v curl &>/dev/null || return 1

    # Build facets: filter to mods, matching MC version and loader
    local facets="[[\"project_type:mod\"]"
    [[ -n "$MC_VERSION" ]] && facets="${facets},[\"versions:${MC_VERSION}\"]"
    [[ -n "$LOADER" ]]     && facets="${facets},[\"categories:${LOADER}\"]"
    facets="${facets}]"

    local encoded_query
    encoded_query=$(printf '%s' "$query" | sed 's/ /%20/g; s/"/%22/g')

    local response
    response=$(curl -sL --max-time 10 \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "https://api.modrinth.com/v2/search?query=${encoded_query}&limit=${limit}&facets=${facets}" \
        2>/dev/null) || return 1

    # Parse response — extract hits array
    echo "$response" | jq -r '.hits[]? | [.slug, .title, (.downloads | tostring), .description[:80]] | @tsv' 2>/dev/null
}

# Search CurseForge API — returns tab-separated: slug \t name \t downloads \t summary
search_curseforge_api() {
    local query="$1" limit="${2:-10}"
    [[ -z "$CURSEFORGE_API_KEY" ]] && return 1
    command -v curl &>/dev/null || return 1

    # CurseForge gameId 432 = Minecraft
    local loader_type=""
    case "$LOADER" in
        forge)     loader_type="1" ;;
        fabric)    loader_type="4" ;;
        quilt)     loader_type="5" ;;
        neoforge)  loader_type="6" ;;
    esac

    local encoded_query
    encoded_query=$(printf '%s' "$query" | sed 's/ /%20/g; s/"/%22/g')

    local url="https://api.curseforge.com/v1/mods/search?gameId=432&searchFilter=${encoded_query}&pageSize=${limit}&sortField=2&sortOrder=desc"
    [[ -n "$loader_type" ]] && url="${url}&modLoaderType=${loader_type}"
    [[ -n "$MC_VERSION" ]]  && url="${url}&gameVersion=${MC_VERSION}"

    local response
    response=$(curl -sL --max-time 10 \
        -H "x-api-key: ${CURSEFORGE_API_KEY}" \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "$url" 2>/dev/null) || return 1

    echo "$response" | jq -r '.data[]? | [.slug, .name, (.downloadCount | tostring), .summary[:80]] | @tsv' 2>/dev/null
}

# ============================================================================
# DIRECT MOD RESOLUTION (Prism Launcher-style)
# ============================================================================
# When packwiz can't install a mod (or installs the wrong one), these functions
# use the official Modrinth/CurseForge version APIs to:
#   1. Look up the project by slug
#   2. Find the exact file matching our MC_VERSION + LOADER
#   3. Download the JAR directly
#   4. Import it via import_jar_as_mod (self-hosted)
#
# This mirrors how Prism Launcher resolves mods — using
# /v2/project/{slug}/version (Modrinth) and /v1/mods/{id}/files (CurseForge)
# instead of relying on packwiz's fuzzy name matching.

# Modrinth: resolve a slug to an exact JAR download, filtered by MC version + loader
modrinth_download_mod() {
    local slug="$1"
    command -v curl &>/dev/null || return 1

    # Step 1: Get the project to verify it exists
    local project
    project=$(curl -sL --max-time 10 \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "https://api.modrinth.com/v2/project/${slug}" \
        2>/dev/null) || return 1

    # Check for valid response (has slug field)
    local project_slug
    project_slug=$(echo "$project" | jq -r '.slug // empty' 2>/dev/null)
    [[ -z "$project_slug" ]] && return 1

    local project_title
    project_title=$(echo "$project" | jq -r '.title // empty' 2>/dev/null)

    # Step 2: Fetch versions filtered by game version + loader
    local loaders_param=""
    [[ -n "$LOADER" ]] && loaders_param="loaders=%5B%22${LOADER}%22%5D"

    local versions_param=""
    [[ -n "$MC_VERSION" ]] && versions_param="game_versions=%5B%22${MC_VERSION}%22%5D"

    local query_string=""
    [[ -n "$loaders_param" ]] && query_string="${loaders_param}"
    [[ -n "$versions_param" ]] && query_string="${query_string:+${query_string}&}${versions_param}"

    local versions_url="https://api.modrinth.com/v2/project/${project_slug}/version"
    [[ -n "$query_string" ]] && versions_url="${versions_url}?${query_string}"

    local versions
    versions=$(curl -sL --max-time 10 \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "$versions_url" \
        2>/dev/null) || return 1

    # Step 3: Pick the first (latest) version's primary file
    local file_info
    file_info=$(echo "$versions" | jq -r '
        [.[] | select(.files | length > 0)] | first |
        .files[] | select(.primary == true or .primary == null) |
        [.url, .filename, .hashes.sha512] | @tsv
    ' 2>/dev/null | head -1)

    [[ -z "$file_info" ]] && {
        log WARN "${slug} — no compatible version on Modrinth for ${MC_VERSION}/${LOADER}"
        return 1
    }

    IFS=$'\t' read -r download_url jar_filename file_hash <<< "$file_info"
    [[ -z "$download_url" || -z "$jar_filename" ]] && return 1

    log INFO "${slug} — Modrinth direct: ${jar_filename}"

    # Step 4: Download the JAR
    local tmp_jar; tmp_jar=$(mktemp --suffix=.jar)
    local http_code
    http_code=$(curl -sL -o "$tmp_jar" -w '%{http_code}' --max-time 60 "$download_url" 2>/dev/null || echo "000")

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmp_jar"
        log WARN "${slug} — download failed (HTTP ${http_code})"
        return 1
    fi

    # Step 5: Verify hash if available
    if [[ -n "$file_hash" ]]; then
        local actual_hash
        actual_hash=$(sha512sum "$tmp_jar" 2>/dev/null | cut -d' ' -f1)
        if [[ "$actual_hash" != "$file_hash" ]]; then
            rm -f "$tmp_jar"
            log WARN "${slug} — SHA-512 hash mismatch after download"
            return 1
        fi
    fi

    # Step 6: Import as self-hosted mod
    if import_jar_as_mod "$tmp_jar" "$slug"; then
        rm -f "$tmp_jar"
        log OK "${slug} — ${project_title} (Modrinth direct download)"
        echo "MODRINTH DIRECT: ${slug} → ${jar_filename}" >> "$RUN_LOG"
        return 0
    fi

    rm -f "$tmp_jar"
    return 1
}

# CurseForge: resolve a slug to an exact JAR download, filtered by MC version + loader
curseforge_download_mod() {
    local slug="$1"
    [[ -z "$CURSEFORGE_API_KEY" ]] && return 1
    command -v curl &>/dev/null || return 1

    # Step 1: Search for the mod to get its numeric ID
    local encoded_slug
    encoded_slug=$(printf '%s' "$slug" | sed 's/ /%20/g')

    local search_url="https://api.curseforge.com/v1/mods/search?gameId=432&searchFilter=${encoded_slug}&pageSize=1&sortField=2&sortOrder=desc"

    local loader_type=""
    case "$LOADER" in
        forge)    loader_type="1" ;; fabric)   loader_type="4" ;;
        quilt)    loader_type="5" ;; neoforge) loader_type="6" ;;
    esac
    [[ -n "$loader_type" ]] && search_url="${search_url}&modLoaderType=${loader_type}"
    [[ -n "$MC_VERSION" ]]  && search_url="${search_url}&gameVersion=${MC_VERSION}"

    local search_result
    search_result=$(curl -sL --max-time 10 \
        -H "x-api-key: ${CURSEFORGE_API_KEY}" \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "$search_url" 2>/dev/null) || return 1

    local mod_id mod_name
    mod_id=$(echo "$search_result" | jq -r '.data[0].id // empty' 2>/dev/null)
    mod_name=$(echo "$search_result" | jq -r '.data[0].name // empty' 2>/dev/null)
    [[ -z "$mod_id" ]] && return 1

    # Verify the slug actually matches (prevent wrong mod)
    local result_slug
    result_slug=$(echo "$search_result" | jq -r '.data[0].slug // empty' 2>/dev/null)
    local slug_norm result_norm
    slug_norm=$(normalize_slug "$slug")
    result_norm=$(normalize_slug "$result_slug")
    if [[ "$slug_norm" != "$result_norm" ]]; then
        log WARN "${slug} — CurseForge returned '${result_slug}' (not a match)"
        return 1
    fi

    # Step 2: Get files for this mod, filtered by game version + loader
    local files_url="https://api.curseforge.com/v1/mods/${mod_id}/files?pageSize=10"
    [[ -n "$MC_VERSION" ]]  && files_url="${files_url}&gameVersion=${MC_VERSION}"
    [[ -n "$loader_type" ]] && files_url="${files_url}&modLoaderType=${loader_type}"

    local files_result
    files_result=$(curl -sL --max-time 10 \
        -H "x-api-key: ${CURSEFORGE_API_KEY}" \
        -H "User-Agent: ${ELM_USER_AGENT}" \
        "$files_url" 2>/dev/null) || return 1

    # Step 3: Pick the first (most recent) file with a download URL
    local file_info
    file_info=$(echo "$files_result" | jq -r '
        [.data[] | select(.downloadUrl != null and .downloadUrl != "")] | first |
        [.downloadUrl, .fileName, (.fileLength | tostring)] | @tsv
    ' 2>/dev/null)

    [[ -z "$file_info" ]] && {
        log WARN "${slug} — no compatible file on CurseForge for ${MC_VERSION}/${LOADER}"
        return 1
    }

    IFS=$'\t' read -r download_url jar_filename file_size <<< "$file_info"
    [[ -z "$download_url" || -z "$jar_filename" ]] && return 1

    log INFO "${slug} — CurseForge direct: ${jar_filename}"

    # Step 4: Download the JAR
    local tmp_jar; tmp_jar=$(mktemp --suffix=.jar)
    local http_code
    http_code=$(curl -sL -o "$tmp_jar" -w '%{http_code}' --max-time 60 "$download_url" 2>/dev/null || echo "000")

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmp_jar"
        log WARN "${slug} — download failed (HTTP ${http_code})"
        return 1
    fi

    # Step 5: Import as self-hosted mod
    if import_jar_as_mod "$tmp_jar" "$slug"; then
        rm -f "$tmp_jar"
        log OK "${slug} — ${mod_name} (CurseForge direct download)"
        echo "CURSEFORGE DIRECT: ${slug} → ${jar_filename} (mod ID ${mod_id})" >> "$RUN_LOG"
        return 0
    fi

    rm -f "$tmp_jar"
    return 1
}

# ─── Fuzzy Mod Resolution ─────────────────────────────────────────────
# Try multiple strategies to find and download a mod when the exact slug fails.
# Strategies (in order):
#   1. Exact slug → Modrinth project API (already tried by direct download)
#   2. Slug variations → strip common suffixes/prefixes, try alternate forms
#   3. Fuzzy search → query both APIs with the slug as search text
#   4. Substring match → pick the best search result whose slug is close
#
# Returns 0 if mod was successfully downloaded and imported.
# Sets FUZZY_RESOLVED_AS with the actual slug used (for reporting).
FUZZY_RESOLVED_AS=""

fuzzy_resolve_mod() {
    local slug="$1"
    local interactive="${2:-false}"   # "true" = show candidates and prompt
    FUZZY_RESOLVED_AS=""

    # ── Strategy 1: Slug variations ──────────────────────────────────
    # Many mods use different slug conventions across platforms.
    # e.g., "fabric-api" vs "fabricapi", "jei" vs "just-enough-items"
    local -a variations=()

    # Strip common Forge/Fabric prefixes/suffixes
    local base="$slug"
    base="${base#forge-}" ; base="${base#fabric-}" ; base="${base#quilt-}"
    base="${base%-forge}" ; base="${base%-fabric}" ; base="${base%-quilt}"
    [[ "$base" != "$slug" ]] && variations+=("$base")

    # Try with loader prefix added
    [[ -n "$LOADER" && "$slug" != "${LOADER}-"* ]] && variations+=("${LOADER}-${slug}")

    # Remove hyphens (fabricapi vs fabric-api)
    local nohyphens="${slug//-/}"
    [[ "$nohyphens" != "$slug" ]] && variations+=("$nohyphens")

    # Add hyphens between words if slug is camelCase-ish (justEnoughItems → just-enough-items)
    local hyphenated
    hyphenated=$(echo "$slug" | sed 's/\([a-z]\)\([A-Z]\)/\1-\2/g' | tr '[:upper:]' '[:lower:]')
    [[ "$hyphenated" != "$slug" ]] && variations+=("$hyphenated")

    for variant in "${variations[@]}"; do
        # Try Modrinth exact project lookup with variant slug
        if modrinth_download_mod "$variant" 2>/dev/null; then
            FUZZY_RESOLVED_AS="$variant"
            log OK "${slug} → resolved as '${variant}' (Modrinth, slug variant)"
            return 0
        fi
        # Try CurseForge with variant slug
        if [[ -n "$CURSEFORGE_API_KEY" ]] && curseforge_download_mod "$variant" 2>/dev/null; then
            FUZZY_RESOLVED_AS="$variant"
            log OK "${slug} → resolved as '${variant}' (CurseForge, slug variant)"
            return 0
        fi
    done

    # ── Strategy 2: Fuzzy search → pick best candidate ───────────────
    # Use the slug as a search query on both APIs, rank results by slug similarity.
    local -a candidates=()   # "source|slug|name|downloads"

    # Search Modrinth
    local mr_hits
    mr_hits=$(search_modrinth_api "$slug" 5 2>/dev/null) || true
    if [[ -n "$mr_hits" ]]; then
        while IFS=$'\t' read -r cslug cname cdownloads cdesc; do
            [[ -n "$cslug" ]] && candidates+=("mr|${cslug}|${cname}|${cdownloads}")
        done <<< "$mr_hits"
    fi

    # Search CurseForge
    if [[ -n "$CURSEFORGE_API_KEY" ]]; then
        local cf_hits
        cf_hits=$(search_curseforge_api "$slug" 5 2>/dev/null) || true
        if [[ -n "$cf_hits" ]]; then
            while IFS=$'\t' read -r cslug cname cdownloads cdesc; do
                [[ -n "$cslug" ]] && candidates+=("cf|${cslug}|${cname}|${cdownloads}")
            done <<< "$cf_hits"
        fi
    fi

    [[ ${#candidates[@]} -eq 0 ]] && return 1

    # ── Score candidates by slug similarity ──────────────────────────
    # Simple scoring: normalized slug containment and length distance.
    local slug_norm
    slug_norm=$(normalize_slug "$slug")
    local best_score=0 best_source="" best_slug="" best_name=""

    for entry in "${candidates[@]}"; do
        IFS='|' read -r csrc cslug cname cdownloads <<< "$entry"
        local cnorm
        cnorm=$(normalize_slug "$cslug")

        local score=0
        # Exact match after normalization
        [[ "$cnorm" == "$slug_norm" ]] && score=100
        # One contains the other
        [[ $score -lt 100 && "$cnorm" == *"$slug_norm"* ]] && score=70
        [[ $score -lt 100 && "$slug_norm" == *"$cnorm"* ]] && score=60
        # First 4+ chars match
        [[ $score -lt 50 && ${#slug_norm} -ge 4 && "${cnorm:0:4}" == "${slug_norm:0:4}" ]] && score=40
        # Bonus for high download count (popular mods more likely correct)
        [[ $score -gt 0 && "${cdownloads:-0}" -gt 1000000 ]] && score=$((score + 5))

        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_source="$csrc"
            best_slug="$cslug"
            best_name="$cname"
        fi
    done

    # ── Interactive mode: show candidates and let user pick ──────────
    if [[ "$interactive" == "true" && ${#candidates[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${CYAN}Search results for ${BOLD}${slug}${NC}:"
        local idx=1
        for entry in "${candidates[@]}"; do
            IFS='|' read -r csrc cslug cname cdownloads <<< "$entry"
            local src_label="MR"
            [[ "$csrc" == "cf" ]] && src_label="CF"
            printf "    ${BOLD}%d${NC}) [%s] %-30s %s  (%s downloads)\n" \
                "$idx" "$src_label" "$cslug" "$cname" "$cdownloads"
            idx=$((idx + 1))
        done
        echo -e "    ${BOLD}0${NC}) Skip"

        local choice
        read -rp "  Pick mod to install [1-$((idx-1)), 0=skip]: " choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -lt "$idx" ]]; then
            local picked="${candidates[$((choice-1))]}"
            IFS='|' read -r csrc cslug cname cdownloads <<< "$picked"
            if [[ "$csrc" == "mr" ]]; then
                modrinth_download_mod "$cslug" && { FUZZY_RESOLVED_AS="$cslug"; return 0; }
            else
                curseforge_download_mod "$cslug" && { FUZZY_RESOLVED_AS="$cslug"; return 0; }
            fi
        fi
        return 1
    fi

    # ── Auto mode: only accept high-confidence matches ───────────────
    if [[ $best_score -ge 70 && -n "$best_slug" ]]; then
        log INFO "${slug} → fuzzy match: ${best_name} (${best_slug}, score ${best_score})"
        if [[ "$best_source" == "mr" ]]; then
            modrinth_download_mod "$best_slug" && { FUZZY_RESOLVED_AS="$best_slug"; return 0; }
        else
            curseforge_download_mod "$best_slug" && { FUZZY_RESOLVED_AS="$best_slug"; return 0; }
        fi
    fi

    return 1
}

# Unified search: hits both official APIs and merges results
# Output: source \t slug \t name \t downloads \t description
search_mods() {
    local query="$1" limit="${2:-5}"
    local found=false

    # Modrinth
    local mr_results
    mr_results=$(search_modrinth_api "$query" "$limit" 2>/dev/null) || true
    if [[ -n "$mr_results" ]]; then
        found=true
        while IFS=$'\t' read -r slug name downloads desc; do
            printf "mr\t%s\t%s\t%s\t%s\n" "$slug" "$name" "$downloads" "$desc"
        done <<< "$mr_results"
    fi

    # CurseForge (only if API key is configured)
    if [[ -n "$CURSEFORGE_API_KEY" ]]; then
        local cf_results
        cf_results=$(search_curseforge_api "$query" "$limit" 2>/dev/null) || true
        if [[ -n "$cf_results" ]]; then
            found=true
            while IFS=$'\t' read -r slug name downloads desc; do
                printf "cf\t%s\t%s\t%s\t%s\n" "$slug" "$name" "$downloads" "$desc"
            done <<< "$cf_results"
        fi
    fi

    $found || return 1
}

# Display search results and optionally let the user pick one to install/resolve
# Returns the selected entry as "source:slug" (e.g. "mr:jei") or empty string
interactive_search() {
    local query="$1" action="${2:-install}"  # action: install | resolve

    echo -e "  ${BLUE}Searching for '${query}'...${NC}"
    echo ""

    local results
    results=$(search_mods "$query" 5 2>/dev/null)

    if [[ -z "$results" ]]; then
        echo -e "  ${DIM}No results found on Modrinth or CurseForge${NC}"
        [[ -z "$CURSEFORGE_API_KEY" ]] && echo -e "  ${DIM}(Set CURSEFORGE_API_KEY in config to also search CurseForge)${NC}"
        echo ""
        return 1
    fi

    # Display results as a numbered list
    local i=0
    local -a result_entries=()

    printf "  ${BOLD}%-3s %-4s %-30s %-12s %s${NC}\n" "#" "SRC" "NAME" "DOWNLOADS" "DESCRIPTION"
    separator

    while IFS=$'\t' read -r src slug name downloads desc; do
        (( i++ ))
        result_entries+=("${src}:${slug}")
        local src_label
        case "$src" in
            mr) src_label="${GREEN}MR${NC}" ;;
            cf) src_label="${YELLOW}CF${NC}" ;;
            *)  src_label="$src" ;;
        esac

        # Format download count
        local dl_fmt="$downloads"
        if [[ "$downloads" =~ ^[0-9]+$ ]]; then
            if (( downloads >= 1000000 )); then
                dl_fmt="$(( downloads / 1000000 ))M"
            elif (( downloads >= 1000 )); then
                dl_fmt="$(( downloads / 1000 ))K"
            fi
        fi

        printf "  ${CYAN}%-3s${NC} ${src_label}  %-30s %-12s ${DIM}%s${NC}\n" "$i" "${name:0:30}" "$dl_fmt" "${desc:0:50}"
    done <<< "$results"

    echo ""

    if [[ "$action" == "none" ]]; then
        # Just display, no prompt
        return 0
    fi

    # Prompt user to pick one
    local action_label="install"
    [[ "$action" == "resolve" ]] && action_label="resolve"

    echo -ne "  ${CYAN}Pick a number to ${action_label} (or Enter to skip)>${NC} "
    read -r pick < /dev/tty

    if [[ -z "$pick" ]]; then
        echo -e "  ${DIM}Skipped.${NC}"
        echo ""
        return 1
    fi

    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#result_entries[@]} )); then
        local selected="${result_entries[$((pick - 1))]}"
        echo "$selected"
        return 0
    else
        echo -e "  ${RED}Invalid selection.${NC}"
        return 1
    fi
}

# ============================================================================
# TARGET REGISTRY
# ============================================================================
# Manages multiple Docker-based MC server instances. Each target has:
#   name, pack_dir, domain, port, rcon_port, ram, cpu, description
#
# Stored as JSON at ~/.config/elm/targets.json
#
# Architecture:
#   Docker VM (Rocky/Ubuntu)
#     ├─ caddy container         ← serves pack files for all targets (auto-HTTPS)
#     ├─ mc-survival  :25565     ← survival.enviouslabs.com (SRV record)
#     ├─ mc-creative  :25566     ← creative.enviouslabs.com (SRV record)
#     └─ mc-modded    :25567     ← modded.enviouslabs.com   (SRV record)
# ============================================================================

TARGETS_FILE="${HOME}/.config/elm/targets.json"

init_targets_file() {
    mkdir -p "$(dirname "$TARGETS_FILE")"
    [[ -f "$TARGETS_FILE" ]] || echo '{}' > "$TARGETS_FILE"
}

target_get() {
    local name="$1" field="$2"
    init_targets_file
    jq -r --arg n "$name" --arg f "$field" '.[$n][$f] // empty' "$TARGETS_FILE" 2>/dev/null
}

target_set() {
    local name="$1"; shift
    init_targets_file
    local tmp; tmp=$(mktemp)
    local existing
    existing=$(jq --arg n "$name" '.[$n] // {}' "$TARGETS_FILE" 2>/dev/null)

    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}" val="${1#*=}"
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            existing=$(echo "$existing" | jq --arg k "$key" --argjson v "$val" '.[$k] = $v')
        else
            existing=$(echo "$existing" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
        fi
        shift
    done

    jq --arg n "$name" --argjson obj "$existing" '.[$n] = $obj' "$TARGETS_FILE" > "$tmp"
    mv "$tmp" "$TARGETS_FILE"
}

target_remove() {
    local name="$1"
    init_targets_file
    local tmp; tmp=$(mktemp)
    jq --arg n "$name" 'del(.[$n])' "$TARGETS_FILE" > "$tmp"
    mv "$tmp" "$TARGETS_FILE"
}

target_list() {
    init_targets_file
    jq -r 'keys[]' "$TARGETS_FILE" 2>/dev/null
}

resolve_target() {
    local explicit="${1:-}"

    if [[ -n "$explicit" ]]; then
        local check; check=$(target_get "$explicit" "port")
        # Allow target even without port (might not be created yet)
        echo "$explicit"
        return
    fi

    local count
    count=$(jq 'length' "$TARGETS_FILE" 2>/dev/null || echo 0)

    if (( count == 0 )); then
        echo -e "${RED}No targets configured. Run: elm target add <name>${NC}" >&2
        exit 1
    elif (( count == 1 )); then
        target_list | head -1
    else
        echo -e "${YELLOW}Multiple targets — specify one with --target <name>:${NC}" >&2
        target_list | while read -r t; do
            local dom port desc
            dom=$(target_get "$t" "domain")
            port=$(target_get "$t" "port")
            desc=$(target_get "$t" "description")
            echo -e "  ${CYAN}${t}${NC}  ${dom:-?}:${port:-?}  ${DIM}${desc}${NC}" >&2
        done
        exit 1
    fi
}

load_target() {
    local name="$1"
    local pack_dir; pack_dir=$(target_get "$name" "pack_dir")

    if [[ -n "$pack_dir" ]]; then
        # If the stored pack_dir is stale (no pack.toml), run discovery on it.
        # This handles targets registered before `elm organize` moved things.
        if [[ ! -f "${pack_dir}/pack.toml" ]]; then
            local resolved
            resolved=$(discover_pack_dir "$pack_dir")
            if [[ -f "${resolved}/pack.toml" ]]; then
                pack_dir="$resolved"
                # Persist the fix so it doesn't re-discover every time
                target_set "$name" "pack_dir=${pack_dir}"
            fi
        fi
        PACK_DIR="$pack_dir"
        MODS_FILE="${PACK_DIR}/mods.txt"
        UNRESOLVED_FILE="${PACK_DIR}/unresolved.txt"
        LOG_DIR="${PACK_DIR}/.logs"

        # Handle stray mods.txt at the parent directory (e.g. project root)
        if [[ ! -f "$MODS_FILE" ]]; then
            local parent
            parent=$(dirname "$PACK_DIR")
            [[ -f "${parent}/mods.txt" ]] && MODS_FILE="${parent}/mods.txt"
        fi
    fi

    local ram; ram=$(target_get "$name" "ram")
    [[ -n "$ram" ]] && SERVER_RAM="$ram"
}

next_available_port() {
    local base="${1:-$SERVER_BASE_PORT}"
    init_targets_file
    local max_port="$base"
    while IFS= read -r t; do
        local p; p=$(target_get "$t" "port")
        [[ -n "$p" ]] && (( p >= max_port )) && max_port=$(( p + 1 ))
    done <<< "$(target_list)"
    echo "$max_port"
}

next_available_rcon_port() {
    local base="${1:-$SERVER_RCON_BASE_PORT}"
    init_targets_file
    local max_port="$base"
    while IFS= read -r t; do
        local p; p=$(target_get "$t" "rcon_port")
        [[ -n "$p" ]] && (( p >= max_port )) && max_port=$(( p + 1 ))
    done <<< "$(target_list)"
    echo "$max_port"
}

# ============================================================================
# DOCKER COMPOSE GENERATION
# ============================================================================

compose_dir() {
    echo "${DOCKER_COMPOSE_DIR}"
}

# Generate a Caddyfile for pack serving — auto-HTTPS when CDN_DOMAIN is set
generate_caddyfile() {
    local pack_root="${1:-}"
    local cdir; cdir=$(compose_dir)
    local caddyfile="${cdir}/Caddyfile"

    # Determine the site address
    local site_addr
    if [[ -n "$CDN_DOMAIN" ]]; then
        site_addr="$CDN_DOMAIN"  # Caddy auto-provisions HTTPS via Let's Encrypt
    else
        site_addr=":8080"        # Plain HTTP, any interface
    fi

    cat > "$caddyfile" << CADDYEOF
# ============================================================================
# ELM — Auto-generated Caddyfile
# DO NOT EDIT — regenerated by elm deploy create / elm deploy regenerate
# ============================================================================

${site_addr} {
    root * /srv/packs
    file_server browse

    # Health check endpoint
    respond /health 200

    # CORS — packwiz-installer needs this for cross-origin fetches
    header Access-Control-Allow-Origin *
    header Access-Control-Allow-Methods "GET, HEAD, OPTIONS"

    # TOML files get the right content type
    @toml path *.toml
    header @toml Content-Type "application/toml"

    # JAR downloads — longer cache, correct type
    @jar path *.jar
    header @jar Content-Type "application/java-archive"
    header @jar Cache-Control "public, max-age=3600"

    # Pack metadata — short cache so updates propagate quickly
    @packmeta path */pack.toml */index.toml
    header @packmeta Cache-Control "public, max-age=60"

    # Log to stdout for docker logs
    log {
        output stdout
    }
}
CADDYEOF

    log OK "Generated Caddyfile (${site_addr})"
}

# Generate docker-compose.yml from all registered targets
generate_compose() {
    local cdir; cdir=$(compose_dir)
    mkdir -p "${cdir}"

    local compose_file="${cdir}/docker-compose.yml"

    # Resolve the CDN directory — local cdn/ sibling to pack/
    local cdn_host_dir=""
    local parent
    parent=$(dirname "$PACK_DIR")
    if [[ -d "${parent}/cdn" ]]; then
        cdn_host_dir="${parent}/cdn"
    else
        # Fall back: create one next to the compose dir
        cdn_host_dir="${cdir}/packs"
    fi
    mkdir -p "$cdn_host_dir"

    # Generate Caddyfile for pack serving
    generate_caddyfile "$cdn_host_dir"

    # Header
    cat > "$compose_file" << 'HEADER'
# ============================================================================
# ELM — Auto-generated Docker Compose
# DO NOT EDIT — regenerated by `elm deploy create` and `elm deploy regenerate`
# ============================================================================

services:
HEADER

    # --- Pack file server (Caddy — auto-HTTPS when domain is set) ---
    local caddy_ports
    if [[ -n "$CDN_DOMAIN" ]]; then
        # Caddy needs 80 (HTTP challenge) + 443 (HTTPS) when using a real domain
        caddy_ports="\"80:80\"\n      - \"443:443\""
    else
        # No domain — serve plain HTTP on 8080
        caddy_ports="\"8080:8080\""
    fi

    # Health check port must match what Caddy actually listens on
    local healthcheck_port="8080"
    if [[ -n "$CDN_DOMAIN" ]]; then
        healthcheck_port="80"
    fi

    cat >> "$compose_file" << CADDY

  # --- Pack file server (Caddy — serves packwiz packs for client auto-update) ---
  packserver:
    image: caddy:2-alpine
    container_name: el-packserver
    restart: unless-stopped
    volumes:
      - ${cdir}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${cdn_host_dir}:/srv/packs:ro
      - caddy-data:/data
      - caddy-config:/config
    ports:
      - ${caddy_ports}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:${healthcheck_port}/health"]
      interval: 30s
      timeout: 5s
      retries: 3
CADDY

    # Add each target as a service
    local targets; targets=$(target_list)
    [[ -z "$targets" ]] && { log WARN "No targets to generate"; return; }

    while IFS= read -r t; do
        local port domain ram rcon_port pack_dir
        port=$(target_get "$t" "port")
        domain=$(target_get "$t" "domain")
        ram=$(target_get "$t" "ram")
        rcon_port=$(target_get "$t" "rcon_port")
        pack_dir=$(target_get "$t" "pack_dir")

        [[ -z "$port" ]] && continue

        local ram_mb="${ram:-$SERVER_RAM}"
        local motd="${domain:-${t}} — ELM"
        local rcon_pass
        rcon_pass=$(target_get "$t" "rcon_password")
        [[ -z "$rcon_pass" ]] && rcon_pass="elm-${t}-$(openssl rand -hex 4 2>/dev/null || echo "change-me")"

        # MC container fetches pack.toml from the Caddy container over the internal network
        local packwiz_url=""
        if [[ -d "${cdn_host_dir}/${t}" ]] || [[ -d "${cdn_host_dir}" && -f "${cdn_host_dir}/pack.toml" ]]; then
            packwiz_url="http://packserver:${healthcheck_port}/${t}/pack.toml"
        fi

        cat >> "$compose_file" << SERVICE

  # --- ${t} ---
  mc-${t}:
    image: ${SERVER_IMAGE}
    container_name: el-mc-${t}
    restart: unless-stopped
    stdin_open: true
    tty: true
    depends_on:
      packserver:
        condition: service_healthy
    ports:
      - "${port}:25565"
      - "${rcon_port}:25575"
    environment:
      EULA: "TRUE"
      TYPE: "FORGE"
      VERSION: "${MC_VERSION}"
      MEMORY: "${ram_mb}M"
      MOTD: "${motd}"
      ENABLE_RCON: "true"
      RCON_PASSWORD: "${rcon_pass}"
      RCON_PORT: "25575"
      SERVER_NAME: "${t}"
      DIFFICULTY: "normal"
      VIEW_DISTANCE: "12"
      MAX_PLAYERS: "20"
      PACKWIZ_URL: "${packwiz_url}"
      USE_AIKAR_FLAGS: "true"
    volumes:
      - mc-${t}-data:/data
    mem_limit: ${ram_mb}m
    mem_reservation: $(( ram_mb / 2 ))m
SERVICE

        # Store the rcon password if we generated it
        local existing_rcon; existing_rcon=$(target_get "$t" "rcon_password")
        [[ -z "$existing_rcon" ]] && target_set "$t" "rcon_password=${rcon_pass}"

    done <<< "$targets"

    # Volumes section
    cat >> "$compose_file" << 'VOLUMES'

volumes:
  caddy-data:
  caddy-config:
VOLUMES

    while IFS= read -r t; do
        local port; port=$(target_get "$t" "port")
        [[ -z "$port" ]] && continue
        echo "  mc-${t}-data:" >> "$compose_file"
    done <<< "$targets"

    log OK "Generated ${compose_file}"
}

# Run docker compose command for specific targets or all
dc() {
    local cdir; cdir=$(compose_dir)
    local compose_file="${cdir}/docker-compose.yml"

    [[ -f "$compose_file" ]] || {
        echo -e "${RED}No compose file. Run 'elm deploy create' first.${NC}"
        exit 1
    }

    docker compose -f "$compose_file" "$@" 2>>"$RUN_LOG"
}

# ============================================================================
# SERVER OPERATIONS (Docker-based)
# ============================================================================

docker_start_target() {
    local target_name="$1"
    check_docker
    header "Starting: ${target_name}"
    dc up -d "mc-${target_name}" "packserver"
    log OK "${target_name} started"

    local domain port
    domain=$(target_get "$target_name" "domain")
    port=$(target_get "$target_name" "port")
    [[ -n "$domain" ]] && echo -e "  Connect: ${CYAN}${domain}${NC}"
    echo ""
}

docker_stop_target() {
    local target_name="$1"
    check_docker
    header "Stopping: ${target_name}"
    dc stop "mc-${target_name}"
    log OK "${target_name} stopped"
}

docker_restart_target() {
    local target_name="$1"
    check_docker
    header "Restarting: ${target_name}"
    dc restart "mc-${target_name}"
    log OK "${target_name} restarted"
}

docker_server_status() {
    local target_name="${1:-}"
    check_docker

    if [[ -z "$target_name" ]]; then
        # Show all
        header "All Servers"

        local targets; targets=$(target_list)
        [[ -z "$targets" ]] && { echo -e "  ${DIM}No targets.${NC}"; return; }

        printf "  ${BOLD}%-15s %-10s %-8s %-15s %s${NC}\n" "TARGET" "STATE" "CPU" "MEMORY" "ADDRESS"
        separator

        while IFS= read -r t; do
            local port domain
            port=$(target_get "$t" "port")
            domain=$(target_get "$t" "domain")
            [[ -z "$port" ]] && continue

            local container="el-mc-${t}"
            local state cpu mem

            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
                state="running"
                local stats
                stats=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$container" 2>/dev/null || echo "? ?")
                cpu=$(echo "$stats" | awk '{print $1}')
                mem=$(echo "$stats" | awk '{print $2}')
            else
                state="stopped"
                cpu="-"
                mem="-"
            fi

            local sc="$RED"
            [[ "$state" == "running" ]] && sc="$GREEN"

            local addr="${domain:-${SERVER_VM_IP:-localhost}}:${port}"

            printf "  %-15s ${sc}%-10s${NC} %-8s %-15s %s\n" "$t" "$state" "$cpu" "$mem" "$addr"
        done <<< "$targets"
        echo ""

    else
        # Single target detail
        header "Server: ${target_name}"

        local container="el-mc-${target_name}"
        local domain port rcon_port ram pack_dir desc
        domain=$(target_get "$target_name" "domain")
        port=$(target_get "$target_name" "port")
        rcon_port=$(target_get "$target_name" "rcon_port")
        ram=$(target_get "$target_name" "ram")
        pack_dir=$(target_get "$target_name" "pack_dir")
        desc=$(target_get "$target_name" "description")

        echo -e "  Target:    ${BOLD}${target_name}${NC}"
        [[ -n "$domain" ]]   && echo -e "  Domain:    ${CYAN}${domain}:${port}${NC}"
        [[ -z "$domain" ]]   && echo -e "  Address:   ${SERVER_VM_IP:-localhost}:${port}"
        [[ -n "$rcon_port" ]] && echo -e "  RCON:      localhost:${rcon_port}"
        [[ -n "$desc" ]]     && echo -e "  Desc:      ${desc}"
        [[ -n "$pack_dir" ]] && echo -e "  Pack dir:  ${pack_dir}"
        echo -e "  RAM:       ${ram:-$SERVER_RAM}MB"

        echo ""
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            echo -e "  State:     ${GREEN}running${NC}"
            docker stats --no-stream --format '  CPU: {{.CPUPerc}}  Memory: {{.MemUsage}}  Net: {{.NetIO}}' "$container" 2>/dev/null
        else
            echo -e "  State:     ${RED}stopped${NC}"
        fi
        echo ""
    fi
}

docker_send_command() {
    local target_name="$1" command="$2"

    local rcon_port rcon_pass
    rcon_port=$(target_get "$target_name" "rcon_port")
    rcon_pass=$(target_get "$target_name" "rcon_password")

    if [[ -z "$rcon_port" || -z "$rcon_pass" ]]; then
        # Fallback: use docker exec to write to stdin
        docker exec -i "el-mc-${target_name}" rcon-cli "$command" 2>>"$RUN_LOG" && log OK "Sent: ${command}" || {
            log WARN "rcon-cli failed, trying stdin..."
            echo "$command" | docker exec -i "el-mc-${target_name}" mc-send-to-console 2>>"$RUN_LOG" || true
            log OK "Sent via stdin: ${command}"
        }
    else
        docker exec -i "el-mc-${target_name}" rcon-cli --port "$rcon_port" --password "$rcon_pass" "$command" 2>>"$RUN_LOG"
        log OK "Sent: ${command}"
    fi
}

docker_logs() {
    local target_name="$1"
    local lines="${2:-100}"
    docker logs --tail "$lines" -f "el-mc-${target_name}" 2>&1
}

docker_kill_target() {
    local target_name="$1"
    check_docker
    header "Force Stopping: ${target_name}"
    dc kill "mc-${target_name}" 2>/dev/null || true
    dc rm -f "mc-${target_name}" 2>/dev/null || true
    log OK "${target_name} killed and removed"
}

docker_remove_target() {
    local target_name="$1"
    check_docker

    header "Removing Deployment: ${target_name}"

    local container="el-mc-${target_name}"

    # Stop the container if running
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        log INFO "Stopping ${target_name}..."
        dc stop "mc-${target_name}" 2>>"$RUN_LOG" || true
    fi

    # Remove the container
    dc rm -f "mc-${target_name}" 2>>"$RUN_LOG" || true
    log OK "Container removed"

    # Clean up CDN published files for this target
    local parent; parent=$(dirname "$PACK_DIR")
    if [[ -d "${parent}/cdn/${target_name}" ]]; then
        echo -e "  ${YELLOW}Remove published pack files in cdn/${target_name}/? (y/N)${NC}"
        read -r confirm < /dev/tty
        if [[ "$confirm" == [yY] ]]; then
            rm -rf "${parent}/cdn/${target_name}"
            log OK "Removed cdn/${target_name}/"
        fi
    fi

    # Offer to remove docker volume
    local volume="mc-${target_name}-data"
    if docker volume inspect "$volume" &>/dev/null 2>&1; then
        echo ""
        echo -e "  ${YELLOW}${BOLD}Remove Docker volume '${volume}'?${NC}"
        echo -e "  ${RED}This permanently deletes the server world, configs, and all data.${NC}"
        echo -e "  ${DIM}(Consider running 'elm deploy backup' first)${NC}"
        echo ""
        echo -ne "  ${CYAN}Delete volume? (y/N)>${NC} "
        read -r vol_confirm < /dev/tty
        if [[ "$vol_confirm" == [yY] ]]; then
            docker volume rm "$volume" 2>>"$RUN_LOG" && log OK "Volume '${volume}' removed" || log WARN "Could not remove volume (may still be in use)"
        else
            echo -e "  ${DIM}Volume kept. Remove later with: docker volume rm ${volume}${NC}"
        fi
    fi

    # Remove target from registry
    echo ""
    echo -e "  ${YELLOW}Remove target '${target_name}' from registry? (y/N)${NC}"
    read -r reg_confirm < /dev/tty
    if [[ "$reg_confirm" == [yY] ]]; then
        target_remove "$target_name"
        log OK "Target '${target_name}' removed from registry"
        # Regenerate compose without this target
        generate_compose 2>/dev/null || true
        log OK "Compose regenerated"
    else
        echo -e "  ${DIM}Target kept in registry.${NC}"
    fi

    echo ""
    log OK "Deployment '${target_name}' removed"
    echo ""
}

docker_backup_target() {
    local target_name="$1"

    header "Backup: ${target_name}"

    local backup_dir="${DOCKER_COMPOSE_DIR}/backups/${target_name}"
    mkdir -p "$backup_dir"

    local timestamp; timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${backup_dir}/${target_name}-${timestamp}.tar.gz"

    # Pause autosave
    docker_send_command "$target_name" "save-off" 2>/dev/null || true
    docker_send_command "$target_name" "save-all" 2>/dev/null || true
    sleep 3

    # Backup the volume
    docker run --rm \
        -v "mc-${target_name}-data:/data:ro" \
        -v "${backup_dir}:/backup" \
        alpine tar czf "/backup/${target_name}-${timestamp}.tar.gz" -C /data . \
        2>>"$RUN_LOG"

    # Resume autosave
    docker_send_command "$target_name" "save-on" 2>/dev/null || true

    local size; size=$(du -h "$backup_file" | cut -f1)
    log OK "Backup: ${backup_file} (${size})"
}

# ============================================================================
# PACK PUBLISHING (copies pack files to cdn/ for Caddy to serve)
# ============================================================================

publish_pack() {
    local target_name="${1:-}"

    header "Publishing Pack"
    check_pack_init

    # Resolve publish directory — always use local cdn/ sibling to pack/
    local parent; parent=$(dirname "$PACK_DIR")
    local cdn_dir="${parent}/cdn"
    local publish_dir="$cdn_dir"

    if [[ -n "$target_name" ]]; then
        publish_dir="${cdn_dir}/${target_name}"
    fi

    mkdir -p "${publish_dir}/mods" "${publish_dir}/jars"

    # Build index with hashes for distribution
    pw refresh --build 2>>"$RUN_LOG"

    log INFO "Publishing pack to ${publish_dir}..."

    # Copy pack descriptor files
    cp "${PACK_DIR}/pack.toml" "${publish_dir}/"
    [[ -f "${PACK_DIR}/index.toml" ]] && cp "${PACK_DIR}/index.toml" "${publish_dir}/"

    # Process .pw.toml files — rewrite URLs for self-hosted mods
    local cdn_base
    cdn_base=$(resolve_cdn_base_url "$target_name")
    local jar_count=0
    local toml_count=0

    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local slug; slug=$(basename "$toml" .pw.toml)
        local dest_toml="${publish_dir}/mods/${slug}.pw.toml"

        # Detect self-hosted mods (no modrinth/curseforge update section)
        local is_self_hosted=false
        if ! grep -q '\[update\.modrinth\]' "$toml" 2>/dev/null && \
           ! grep -q '\[update\.curseforge\]' "$toml" 2>/dev/null; then
            is_self_hosted=true
        fi

        if $is_self_hosted; then
            local mod_filename
            mod_filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")

            if [[ -n "$mod_filename" ]]; then
                # Find the JAR source
                local jar_src=""
                [[ -f "${PACK_DIR}/mods/${mod_filename}" ]] && jar_src="${PACK_DIR}/mods/${mod_filename}"
                [[ -z "$jar_src" && -n "$LOCAL_MODS_DIR" && -f "${LOCAL_MODS_DIR}/${mod_filename}" ]] && jar_src="${LOCAL_MODS_DIR}/${mod_filename}"

                if [[ -n "$jar_src" ]]; then
                    cp "$jar_src" "${publish_dir}/jars/${mod_filename}"
                    (( jar_count++ ))
                    # Rewrite download URL to point at our CDN
                    local new_url="${cdn_base}/jars/${mod_filename}"
                    sed "s|^url = \".*\"|url = \"${new_url}\"|" "$toml" > "$dest_toml"
                else
                    cp "$toml" "$dest_toml"
                    log WARN "${slug} — JAR '${mod_filename}' not found, keeping original URL"
                fi
            else
                cp "$toml" "$dest_toml"
            fi
        else
            # Modrinth/CurseForge — copy as-is (uses their CDN)
            cp "$toml" "$dest_toml"
        fi
        (( toml_count++ ))
    done

    # Copy configs if present
    [[ -d "${PACK_DIR}/config" ]] && cp -r "${PACK_DIR}/config" "${publish_dir}/" 2>/dev/null || true

    # Remove stale files in cdn that no longer exist in pack
    for cdn_toml in "${publish_dir}/mods/"*.pw.toml; do
        [[ -f "$cdn_toml" ]] || continue
        local base; base=$(basename "$cdn_toml")
        [[ ! -f "${PACK_DIR}/mods/${base}" ]] && {
            rm -f "$cdn_toml"
            log WARN "Removed stale: ${base}"
        }
    done
    for jar in "${publish_dir}/jars/"*.jar; do
        [[ -f "$jar" ]] || continue
        local jar_name; jar_name=$(basename "$jar")
        grep -rlq "\"${jar_name}\"" "${PACK_DIR}/mods/"*.pw.toml 2>/dev/null || {
            rm -f "$jar"
            log WARN "Removed stale JAR: ${jar_name}"
        }
    done

    # Refresh the published index to reflect rewritten URLs
    if command -v "$PACKWIZ_BIN" &>/dev/null; then
        (cd "$publish_dir" && "$PACKWIZ_BIN" refresh --build 2>/dev/null || true)
    fi

    log OK "Published: ${toml_count} mod(s), ${jar_count} self-hosted JAR(s)"

    # Player connection info
    echo ""
    echo -e "  ${GREEN}Players (Prism Launcher pre-launch command):${NC}"
    echo -e "  ${CYAN}\"\$INST_JAVA\" -jar packwiz-installer-bootstrap.jar ${cdn_base}/pack.toml${NC}"
    echo ""
    if (( jar_count > 0 )); then
        echo -e "  ${MAGENTA}${jar_count} self-hosted JAR(s) in: ${publish_dir}/jars/${NC}"
        echo ""
    fi
}

# ============================================================================
# CDN PUBLISHING (served by Caddy container in Docker Compose)
# ============================================================================
# publish_pack() writes to the local cdn/<target>/ directory:
#
#   cdn/<target>/
#     ├── pack.toml              ← packwiz pack descriptor
#     ├── index.toml             ← mod index with hashes
#     ├── mods/*.pw.toml         ← metadata (URLs rewritten for self-hosted mods)
#     └── jars/*.jar             ← only for url:/local: mods (self-hosted)
#
# The Caddy container mounts cdn/ and serves it directly.
# With CDN_DOMAIN set, Caddy auto-provisions HTTPS via Let's Encrypt.
# Without CDN_DOMAIN, serves on http://server-ip:8080.

# Resolve the CDN domain for a given target (per-target override or global)
resolve_cdn_domain() {
    local target_name="${1:-}"
    local domain=""

    # 1. Per-target override
    if [[ -n "$target_name" ]]; then
        domain=$(target_get "$target_name" "cdn_domain")
    fi

    # 2. Global CDN_DOMAIN
    [[ -z "$domain" ]] && domain="$CDN_DOMAIN"

    # 3. Fall back to PACK_HOST_URL's hostname
    if [[ -z "$domain" && -n "$PACK_HOST_URL" ]]; then
        domain=$(echo "$PACK_HOST_URL" | sed 's|^https\?://||; s|/.*||')
    fi

    # 4. Fall back to SERVER_VM_IP:8080
    [[ -z "$domain" ]] && domain="${SERVER_VM_IP:-localhost}:8080"

    echo "$domain"
}

# Build the full CDN base URL for a target
resolve_cdn_base_url() {
    local target_name="${1:-}"
    local domain
    domain=$(resolve_cdn_domain "$target_name")

    # Caddy auto-provisions HTTPS for real domains
    # If domain has a port (e.g. localhost:8080) → HTTP; otherwise → HTTPS
    local proto="https"
    [[ "$domain" == *:* ]] && proto="http"

    echo "${proto}://${domain}/${target_name}"
}

# ============================================================================
# DOWNLOAD SERVER MODS
# ============================================================================
# Reads every .pw.toml in the pack, extracts the download URL, and fetches
# the actual JAR file into a target mods directory (typically server/mods/).
#
# For Modrinth/CurseForge mods the URL points at their CDN.
# For url:/local: mods it points at whatever was configured.
# Either way, the JAR lands in server/mods/ ready for the server to load.
#
# Handles:
#   - Skipping JARs that already exist and haven't changed (by hash)
#   - Removing stale JARs that no longer have a matching .pw.toml
#   - Filtering by side (skip client-only mods for the server)

download_server_mods() {
    local dest_dir="${1:-}"

    # Auto-detect: sibling server/mods/ relative to pack/
    if [[ -z "$dest_dir" ]]; then
        local parent
        parent=$(dirname "$PACK_DIR")
        if [[ -d "${parent}/server" ]]; then
            dest_dir="${parent}/server/mods"
        else
            echo -e "  ${RED}No destination specified and no sibling server/ directory found.${NC}"
            echo -e "  ${DIM}Usage: elm deploy mods [--dir /path/to/server/mods]${NC}"
            echo -e "  ${DIM}Or run 'elm organize' first to create the directory layout.${NC}"
            return 1
        fi
    fi

    header "Downloading Server Mods"
    check_pack_init

    mkdir -p "$dest_dir"

    if ! command -v curl &>/dev/null; then
        echo -e "  ${RED}curl is required to download mods.${NC}"
        return 1
    fi

    local total=0 downloaded=0 skipped=0 failed=0 removed=0 client_only=0
    local failed_mods=()

    log INFO "Source:  ${PACK_DIR}/mods/*.pw.toml"
    log INFO "Dest:    ${dest_dir}/"
    echo ""

    # --- Download each mod JAR ---
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        (( total++ ))

        local slug
        slug=$(basename "$toml" .pw.toml)

        # Extract fields from .pw.toml
        local mod_name mod_filename mod_url mod_hash mod_hash_format mod_side
        mod_name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "$slug")
        mod_filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")
        mod_side=$(grep -oP '^side\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "both")

        # Skip client-only mods — the server doesn't need them
        if [[ "$mod_side" == "client" ]]; then
            log SKIP "${mod_name} ${DIM}(client-only)${NC}"
            (( client_only++ ))
            continue
        fi

        # Extract download URL and hash from [download] section
        mod_url=$(grep -A5 '^\[download\]' "$toml" | grep -oP '^url\s*=\s*"\K[^"]+' 2>/dev/null || echo "")
        mod_hash=$(grep -A5 '^\[download\]' "$toml" | grep -oP '^hash\s*=\s*"\K[^"]+' 2>/dev/null || echo "")
        mod_hash_format=$(grep -A5 '^\[download\]' "$toml" | grep -oP '^hash-format\s*=\s*"\K[^"]+' 2>/dev/null || echo "sha256")

        if [[ -z "$mod_url" ]]; then
            log WARN "${mod_name} — no download URL in .pw.toml"
            (( failed++ ))
            failed_mods+=("$slug (no URL)")
            continue
        fi

        if [[ -z "$mod_filename" ]]; then
            # Derive from URL
            mod_filename=$(basename "$mod_url" | sed 's/?.*//')
        fi

        local dest_file="${dest_dir}/${mod_filename}"

        # --- Check if JAR already exists and matches hash ---
        if [[ -f "$dest_file" && -n "$mod_hash" ]]; then
            local existing_hash=""
            case "$mod_hash_format" in
                sha256) existing_hash=$(sha256sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                sha512) existing_hash=$(sha512sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                sha1)   existing_hash=$(sha1sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                md5)    existing_hash=$(md5sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                murmur2) existing_hash="" ;;  # Can't verify murmur2 easily, re-download
            esac

            if [[ -n "$existing_hash" && "$existing_hash" == "$mod_hash" ]]; then
                log SKIP "${mod_name} ${DIM}(up to date)${NC}"
                (( skipped++ ))
                continue
            fi
        fi

        # --- Download the JAR ---
        log INFO "Downloading ${mod_name}..."
        echo "  DOWNLOAD: ${mod_url} → ${dest_file}" >> "$RUN_LOG"

        local http_code
        http_code=$(curl -sL -o "$dest_file" -w "%{http_code}" \
            --connect-timeout 15 --max-time 120 \
            -H "User-Agent: ELM/1 (EnviousLabsMinecraft) (github.com/PackwizWrapper)" \
            "$mod_url" 2>>"$RUN_LOG" || echo "000")

        if [[ "$http_code" == "200" && -s "$dest_file" ]]; then
            # Verify hash if available
            local verified=true
            if [[ -n "$mod_hash" ]]; then
                local dl_hash=""
                case "$mod_hash_format" in
                    sha256) dl_hash=$(sha256sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                    sha512) dl_hash=$(sha512sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                    sha1)   dl_hash=$(sha1sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                    md5)    dl_hash=$(md5sum "$dest_file" 2>/dev/null | cut -d' ' -f1) ;;
                esac

                if [[ -n "$dl_hash" && "$dl_hash" != "$mod_hash" ]]; then
                    log WARN "${mod_name} — hash mismatch (expected ${mod_hash:0:12}…, got ${dl_hash:0:12}…)"
                    verified=false
                fi
            fi

            if $verified; then
                log OK "${mod_name} → ${mod_filename}"
                (( downloaded++ ))
            else
                log WARN "${mod_name} — downloaded but hash mismatch, keeping anyway"
                (( downloaded++ ))
            fi
        else
            log FAIL "${mod_name} — HTTP ${http_code}"
            rm -f "$dest_file"  # Remove partial download
            (( failed++ ))
            failed_mods+=("$slug (HTTP ${http_code})")
        fi
    done

    # --- Remove stale JARs no longer in the pack ---
    log INFO "Checking for stale JARs..."

    # Build a set of expected filenames from all .pw.toml files
    declare -A expected_filenames
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local fn
        fn=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")
        [[ -n "$fn" ]] && expected_filenames["$fn"]=1
    done

    for jar in "${dest_dir}/"*.jar; do
        [[ -f "$jar" ]] || continue
        local jar_name
        jar_name=$(basename "$jar")
        if [[ -z "${expected_filenames[$jar_name]+_}" ]]; then
            rm -f "$jar"
            log WARN "Removed stale: ${jar_name}"
            (( removed++ ))
        fi
    done

    # --- Summary ---
    separator
    echo ""
    echo -e "  ${BOLD}Download Summary${NC}"
    echo -e "  Total .pw.toml:  ${BOLD}${total}${NC}"
    echo -e "  Downloaded:      ${GREEN}${downloaded}${NC}"
    echo -e "  Up to date:      ${CYAN}${skipped}${NC}"
    echo -e "  Client-only:     ${DIM}${client_only}${NC} (skipped)"
    echo -e "  Failed:          ${RED}${failed}${NC}"
    (( removed > 0 )) && echo -e "  Stale removed:   ${YELLOW}${removed}${NC}"
    echo ""

    if (( failed > 0 )); then
        echo -e "  ${RED}${BOLD}Failed downloads:${NC}"
        printf '    • %s\n' "${failed_mods[@]}"
        echo ""
        echo -e "  ${DIM}Check URLs with: elm ls --version${NC}"
        echo -e "  ${DIM}Full log: ${RUN_LOG}${NC}"
        echo ""
    fi

    echo -e "  ${GREEN}Server mods:${NC} ${CYAN}${dest_dir}/${NC}"
    echo ""
}

# Auto-publish hook — called after sync/update if AUTO_PUBLISH is set
auto_publish_cdn() {
    [[ -z "$AUTO_PUBLISH" ]] && return 0

    local target="$AUTO_PUBLISH"

    if [[ "$target" == "__auto__" ]]; then
        # Auto-detect target from registered targets, or publish without target name
        local targets; targets=$(target_list 2>/dev/null)
        if [[ -n "$targets" ]]; then
            # Use first target
            target=$(echo "$targets" | head -1)
        else
            target=""
        fi
    fi

    separator
    publish_pack "$target"

    # Also download server mods into sibling server/mods/
    local parent; parent=$(dirname "$PACK_DIR")
    if [[ -d "${parent}/server" ]]; then
        download_server_mods "${parent}/server/mods"
    fi
}

# Alias — publish_cdn now just calls publish_pack (unified)
publish_cdn() {
    publish_pack "$@"
}

# Legacy alias — nginx config generation replaced by Caddy (auto-HTTPS)
generate_nginx_config() {
    log WARN "Nginx config generation has been replaced by Caddy."
    echo -e "  Pack files are now served by the Caddy container in Docker Compose."
    echo -e "  Set ${CYAN}CDN_DOMAIN${NC} in your config for automatic HTTPS."
    echo -e "  Run ${CYAN}elm deploy regenerate${NC} to update the Caddyfile."
    echo ""
    echo -e "  ${DIM}Caddy handles HTTPS automatically via Let's Encrypt — no certbot needed.${NC}"
    echo ""
}

print_srv_records() {
    local target_name="${1:-}"

    header "Cloudflare SRV Records"

    local targets
    if [[ -n "$target_name" ]]; then
        targets="$target_name"
    else
        targets=$(target_list)
    fi

    [[ -z "$targets" ]] && { echo -e "  ${DIM}No targets.${NC}"; return; }

    echo -e "  Add these in Cloudflare DNS → ${BOLD}Add Record → SRV${NC}:"
    echo ""

    while IFS= read -r t; do
        local domain port
        domain=$(target_get "$t" "domain")
        port=$(target_get "$t" "port")

        [[ -z "$domain" || -z "$port" ]] && continue

        # Parse base domain from full domain
        local subdomain base_domain
        subdomain="${domain%%.*}"
        base_domain="${domain#*.}"

        echo -e "  ${BOLD}${t}${NC} → ${CYAN}${domain}${NC}"
        echo -e "    Type:     SRV"
        echo -e "    Name:     ${CYAN}_minecraft._tcp.${subdomain}${NC}"
        echo -e "    Service:  _minecraft"
        echo -e "    Protocol: TCP"
        echo -e "    Priority: 0"
        echo -e "    Weight:   5"
        echo -e "    Port:     ${BOLD}${port}${NC}"
        echo -e "    Target:   ${CYAN}${SERVER_VM_IP:-your-server-ip}${NC}"
        echo ""
        echo -e "    ${DIM}Also add an A record:${NC}"
        echo -e "    ${DIM}${subdomain}.${base_domain} → ${SERVER_VM_IP:-your-server-ip} (DNS only, no proxy)${NC}"
        echo ""
    done <<< "$targets"

    echo -e "  ${YELLOW}Important:${NC} Cloudflare proxy (orange cloud) must be ${BOLD}OFF${NC} for MC traffic."
    echo -e "  Use DNS-only mode (gray cloud) for all Minecraft records."
    echo ""
}

# ============================================================================
# PACK COMMANDS
# ============================================================================

# ============================================================================
# ORGANIZE — restructure a flat/messy directory into pack/ server/ cdn/
# ============================================================================
#
# Target layout:
#   <root>/
#     ├── pack/                ← packwiz working directory (elm operates here)
#     │   ├── pack.toml
#     │   ├── index.toml
#     │   ├── mods.txt
#     │   ├── elm.conf
#     │   ├── unresolved.txt
#     │   ├── mods/            ← .pw.toml files + downloaded JARs
#     │   └── config/          ← mod config files
#     ├── server/              ← minecraft server runtime data
#     │   ├── world/
#     │   ├── server.properties
#     │   ├── logs/
#     │   ├── ops.json, whitelist.json, banned-*.json
#     │   └── ...
#     ├── staging/             ← drop JARs here for 'elm add --stage' batch matching
#     └── cdn/                 ← Caddy-served files (client downloads)
#         ├── pack.toml
#         ├── index.toml
#         ├── mods/            ← .pw.toml metadata
#         └── jars/            ← self-hosted mod JARs
#
# After organizing, PACK_DIR points at <root>/pack/ and the Caddy
# container serves <root>/cdn/.  The server/ dir is left alone — Docker
# or the itzg image manage it — but loose server files are relocated there.

cmd_organize() {
    header "Organize Directory"

    # Organize always works on the directory the user is standing in (or the arg),
    # NOT the auto-discovered PACK_DIR — because the point is to reorganize the
    # flat directory that contains pack.toml alongside server files.
    local root="${1:-$(pwd)}"

    # Sanity: must have at least a pack.toml somewhere to know this is a PM dir
    if [[ ! -f "${root}/pack.toml" ]]; then
        # Maybe they're in the parent of an already-organized layout
        if [[ -f "${root}/pack/pack.toml" ]]; then
            echo -e "  ${YELLOW}This directory already has a pack/ subdirectory.${NC}"
            echo -e "  ${DIM}Looks like it may already be organized.${NC}"
            echo ""
            echo -e "  To re-organize, run from inside the pack/ directory"
            echo -e "  or pass the path: ${CYAN}elm organize ${root}/pack${NC}"
            return 0
        fi
        echo -e "  ${RED}No pack.toml in ${root}${NC}"
        echo -e "  ${DIM}Run this from your existing pack directory, or pass it as an argument.${NC}"
        return 1
    fi

    echo -e "  ${BOLD}Current directory:${NC} ${CYAN}${root}${NC}"
    echo ""

    # --- Scan what's here ---
    local packwiz_files=()     # Things that belong in pack/
    local server_files=()      # Things that belong in server/
    local other_files=()       # Unknown / already organized

    # PackWiz / ELM files
    for f in pack.toml index.toml mods.txt elm.conf unresolved.txt; do
        [[ -f "${root}/${f}" ]] && packwiz_files+=("$f")
    done
    [[ -d "${root}/mods" ]]   && packwiz_files+=("mods/")
    [[ -d "${root}/config" ]] && packwiz_files+=("config/")
    [[ -d "${root}/.logs" ]]  && packwiz_files+=(".logs/")

    # Minecraft server files
    for f in server.properties server-icon.png eula.txt banned-ips.json banned-players.json \
             ops.json whitelist.json usercache.json; do
        [[ -f "${root}/${f}" ]] && server_files+=("$f")
    done
    for d in world world_nether world_the_end logs crash-reports; do
        [[ -d "${root}/${d}" ]] && server_files+=("${d}/")
    done
    # Catch server JAR files
    for f in "${root}"/forge-*.jar "${root}"/minecraft_server*.jar "${root}"/server.jar \
             "${root}"/libraries; do
        [[ -e "$f" ]] && server_files+=("$(basename "$f")")
    done

    # Already organized?
    if [[ -d "${root}/pack" && -f "${root}/pack/pack.toml" ]]; then
        echo -e "  ${YELLOW}This directory already has a pack/ subdirectory with pack.toml.${NC}"
        echo -e "  ${DIM}Looks like it may already be organized. Re-organize? (y/N)${NC}"
        echo -ne "  ${CYAN}>${NC} "
        read -r reorg < /dev/tty
        [[ "$reorg" != [yY] ]] && { echo -e "  ${DIM}Cancelled.${NC}"; return; }
    fi

    # --- Preview ---
    echo -e "  ${BOLD}Will create:${NC}"
    echo -e "    ${CYAN}pack/${NC}    ← packwiz files (pack.toml, mods/, mods.txt, config)"
    echo -e "    ${CYAN}server/${NC}  ← minecraft server runtime (world, properties, logs)"
    echo -e "    ${CYAN}cdn/${NC}     ← Caddy-served client downloads (toml + jars)"
    echo ""

    if (( ${#packwiz_files[@]} > 0 )); then
        echo -e "  ${GREEN}→ pack/${NC} (${#packwiz_files[@]} items):"
        for f in "${packwiz_files[@]}"; do
            echo -e "    ${DIM}${f}${NC}"
        done
    fi
    if (( ${#server_files[@]} > 0 )); then
        echo -e "  ${GREEN}→ server/${NC} (${#server_files[@]} items):"
        for f in "${server_files[@]}"; do
            echo -e "    ${DIM}${f}${NC}"
        done
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}This will move files. Continue? (y/N)${NC}"
    echo -ne "  ${CYAN}>${NC} "
    read -r confirm < /dev/tty
    [[ "$confirm" != [yY] ]] && { echo -e "  ${DIM}Cancelled.${NC}"; return; }

    echo ""

    # --- Create directories ---
    mkdir -p "${root}/pack/mods" "${root}/server" "${root}/cdn/mods" "${root}/cdn/jars"
    log OK "Created pack/ server/ cdn/"

    # --- Move packwiz files into pack/ ---
    for f in pack.toml index.toml mods.txt elm.conf unresolved.txt; do
        if [[ -f "${root}/${f}" ]]; then
            mv "${root}/${f}" "${root}/pack/${f}"
            log OK "  ${f} → pack/"
        fi
    done
    # Move mods/ directory
    if [[ -d "${root}/mods" ]]; then
        # Move contents, not the dir itself (pack/mods/ already created)
        mv "${root}"/mods/* "${root}/pack/mods/" 2>/dev/null || true
        rmdir "${root}/mods" 2>/dev/null || true
        log OK "  mods/ → pack/mods/"
    fi
    if [[ -d "${root}/config" ]]; then
        mv "${root}/config" "${root}/pack/config"
        log OK "  config/ → pack/config/"
    fi
    if [[ -d "${root}/.logs" ]]; then
        mv "${root}/.logs" "${root}/pack/.logs"
        log OK "  .logs/ → pack/.logs/"
    fi

    # --- Move server files into server/ ---
    for f in server.properties server-icon.png eula.txt banned-ips.json banned-players.json \
             ops.json whitelist.json usercache.json; do
        if [[ -f "${root}/${f}" ]]; then
            mv "${root}/${f}" "${root}/server/${f}"
            log OK "  ${f} → server/"
        fi
    done
    for d in world world_nether world_the_end logs crash-reports; do
        if [[ -d "${root}/${d}" ]]; then
            mv "${root}/${d}" "${root}/server/${d}"
            log OK "  ${d}/ → server/"
        fi
    done
    # Server JARs and libraries
    for f in "${root}"/forge-*.jar "${root}"/minecraft_server*.jar "${root}"/server.jar; do
        [[ -f "$f" ]] && { mv "$f" "${root}/server/"; log OK "  $(basename "$f") → server/"; }
    done
    if [[ -d "${root}/libraries" ]]; then
        mv "${root}/libraries" "${root}/server/libraries"
        log OK "  libraries/ → server/"
    fi

    # --- Initial CDN publish from pack/ ---
    log INFO "Populating cdn/ from pack/..."

    # Copy pack descriptor files
    for f in pack.toml index.toml; do
        [[ -f "${root}/pack/${f}" ]] && cp "${root}/pack/${f}" "${root}/cdn/${f}"
    done

    # Copy .pw.toml files into cdn/mods/ — rewrite self-hosted URLs if CDN is configured
    if [[ -d "${root}/pack/mods" ]]; then
        for toml in "${root}/pack/mods/"*.pw.toml; do
            [[ -f "$toml" ]] || continue
            cp "$toml" "${root}/cdn/mods/"
        done

        # Copy self-hosted JARs into cdn/jars/
        for toml in "${root}/pack/mods/"*.pw.toml; do
            [[ -f "$toml" ]] || continue
            # Self-hosted = no [update.modrinth] and no [update.curseforge]
            if ! grep -q '\[update\.modrinth\]' "$toml" 2>/dev/null && \
               ! grep -q '\[update\.curseforge\]' "$toml" 2>/dev/null; then
                local mod_filename
                mod_filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")
                if [[ -n "$mod_filename" && -f "${root}/pack/mods/${mod_filename}" ]]; then
                    cp "${root}/pack/mods/${mod_filename}" "${root}/cdn/jars/${mod_filename}"
                    log DEP "  ${mod_filename} → cdn/jars/"
                fi
            fi
        done
    fi

    log OK "cdn/ populated"

    # --- Update local elm.conf to point at new paths ---
    local conf="${root}/pack/elm.conf"
    if [[ -f "$conf" ]]; then
        # Add or update AUTO_PUBLISH setting
        if grep -q '^AUTO_PUBLISH=' "$conf" 2>/dev/null; then
            sed -i 's|^AUTO_PUBLISH=.*|AUTO_PUBLISH="__auto__"|' "$conf"
        elif grep -q '^# SYNC_ON_FAIL' "$conf" || grep -q '^SYNC_ON_FAIL' "$conf"; then
            # Insert after SYNC_ON_FAIL line
            sed -i '/SYNC_ON_FAIL/a AUTO_PUBLISH="__auto__"' "$conf"
        else
            echo '' >> "$conf"
            echo '# Auto-publish to cdn/ after sync/update' >> "$conf"
            echo 'AUTO_PUBLISH="__auto__"' >> "$conf"
        fi
        log OK "Set AUTO_PUBLISH in pack/elm.conf"
    fi

    # --- Summary ---
    separator
    echo ""
    echo -e "  ${GREEN}${BOLD}Organized!${NC} New layout:"
    echo ""
    echo -e "  ${CYAN}${root}/${NC}"
    echo -e "  ├── ${BOLD}pack/${NC}      ← run elm commands from here"
    echo -e "  │   ├── pack.toml, index.toml"
    echo -e "  │   ├── mods.txt, elm.conf"
    echo -e "  │   └── mods/  config/"
    echo -e "  ├── ${BOLD}server/${NC}    ← minecraft server runtime"
    if (( ${#server_files[@]} > 0 )); then
    echo -e "  │   ├── world/  server.properties  logs/"
    echo -e "  │   └── (${#server_files[@]} items moved)"
    else
    echo -e "  │   └── ${DIM}(empty — Docker/itzg manages this)${NC}"
    fi
    echo -e "  └── ${BOLD}cdn/${NC}       ← Caddy serves this"
    echo -e "      ├── pack.toml, index.toml"
    echo -e "      ├── mods/*.pw.toml"
    echo -e "      └── jars/*.jar"
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "    ${CYAN}cd ${root}/pack${NC}"
    echo -e "    ${CYAN}elm sync${NC}                          # pack changes auto-publish to cdn/"
    echo ""
    echo -e "  ${DIM}Caddy serves cdn/ automatically via Docker Compose.${NC}"
    echo -e "  ${DIM}Set CDN_DOMAIN in config for automatic HTTPS.${NC}"
    echo ""
}

cmd_init() {
    header "Initializing Pack"
    if [[ -f "${PACK_DIR}/pack.toml" ]]; then
        echo -e "  ${YELLOW}pack.toml exists. Re-init? (y/N)${NC}"
        read -r c; [[ "$c" != [yY] ]] && exit 0
    fi

    # --- Minecraft version ---
    local mc_ver="$MC_VERSION"
    echo -e "  ${BOLD}Minecraft version${NC} ${DIM}(default: ${mc_ver})${NC}"
    echo -ne "  ${CYAN}version>${NC} "
    read -r input_mc
    [[ -n "$input_mc" ]] && mc_ver="$input_mc"

    # --- Mod loader ---
    local loader="$LOADER"
    echo ""
    echo -e "  ${BOLD}Mod loader${NC} ${DIM}(default: ${loader})${NC}"
    echo -e "  ${DIM}Options: forge, neoforge, fabric, quilt${NC}"
    echo -ne "  ${CYAN}loader>${NC} "
    read -r input_loader
    if [[ -n "$input_loader" ]]; then
        input_loader=$(echo "$input_loader" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$input_loader" in
            forge|neoforge|fabric|quilt) loader="$input_loader" ;;
            *)
                echo -e "  ${YELLOW}Unknown loader '${input_loader}' — using ${loader}${NC}"
                ;;
        esac
    fi

    # --- Loader version (optional) ---
    local loader_ver="$LOADER_VERSION"
    echo ""
    echo -e "  ${BOLD}${loader^} version${NC} ${DIM}(blank = latest)${NC}"
    echo -ne "  ${CYAN}${loader} version>${NC} "
    read -r input_lv
    [[ -n "$input_lv" ]] && loader_ver="$input_lv"

    # --- Confirm ---
    echo ""
    separator
    echo -e "  Minecraft:  ${BOLD}${mc_ver}${NC}"
    echo -e "  Loader:     ${BOLD}${loader}${NC}"
    if [[ -n "$loader_ver" ]]; then
        echo -e "  Version:    ${BOLD}${loader_ver}${NC}"
    else
        echo -e "  Version:    ${DIM}latest${NC}"
    fi
    echo ""
    echo -ne "  ${BOLD}Create pack? (Y/n)${NC} "
    read -r confirm
    [[ "$confirm" == [nN] ]] && { echo -e "  ${DIM}Cancelled.${NC}"; return; }

    # --- Run packwiz init ---
    local loader_arg=""
    [[ -n "$loader_ver" ]] && loader_arg="--${loader}-version ${loader_ver}"

    echo ""
    pw init --mc-version "$mc_ver" --modloader "$loader" $loader_arg

    [[ -f "$MODS_FILE" ]] || {
        echo "# ELM mods list — edit and run: elm sync" > "$MODS_FILE"
        log OK "Created mods.txt"
    }

    echo ""
    log OK "Pack initialized (MC ${mc_ver} / ${loader})"
}

cmd_sync() {
    check_packwiz; check_pack_init
    header "Syncing Mods"
    [[ -f "$MODS_FILE" ]] || { echo -e "${RED}No mods.txt.${NC}"; exit 1; }

    local total=0 success=0 failed=0
    local failed_mods=()
    DEPS_ADDED=()
    UNRESOLVED_ADDED=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue

        local parsed
        parsed="$(parse_mod_entry "$line")" || continue
        IFS='|' read -r source slug url pinned <<< "$parsed"
        (( total++ ))

        if install_mod "$source" "$slug" "$url" "$pinned"; then
            (( success++ ))
        else
            (( failed++ ))
            failed_mods+=("$slug")
        fi
    done < "$MODS_FILE"

    separator
    log INFO "Refreshing pack index..."
    pw refresh 2>>"$RUN_LOG" && log OK "Index updated" || log WARN "Index warnings"

    # Auto-publish to CDN if configured
    auto_publish_cdn

    header "Sync Summary"
    echo -e "  Processed:   ${BOLD}${total}${NC}"
    echo -e "  Installed:   ${GREEN}${success}${NC}"
    echo -e "  Failed:      ${RED}${failed}${NC}"

    if (( ${#DEPS_ADDED[@]} > 0 )); then
        echo ""
        echo -e "  ${MAGENTA}Auto-installed dependencies:${NC}"
        printf '    ↳ %s\n' "${DEPS_ADDED[@]}"
    fi

    if (( failed > 0 )); then
        echo ""
        echo -e "  ${RED}${BOLD}Failed:${NC}"
        printf '    • %s\n' "${failed_mods[@]}"
        echo ""
        echo -e "  ${YELLOW}Fixes:${NC}"
        echo "    1. Check slug: modrinth.com or curseforge.com"
        echo "    2. Pin source: cf:slug or mr:slug"
        echo "    3. Direct URL: url:https://..."
        echo "    4. Log: ${RUN_LOG}"
        printf '%s\n' "${failed_mods[@]}" > "${LOG_DIR}/last_failed.txt"
    fi

    if (( ${#UNRESOLVED_ADDED[@]} > 0 )); then
        echo ""
        echo -e "  ${CYAN}${BOLD}Saved to unresolved.txt (${#UNRESOLVED_ADDED[@]}):${NC}"
        printf '    → %s\n' "${UNRESOLVED_ADDED[@]}"
        echo ""
        echo -e "  ${DIM}Bind these later with a URL or local JAR in unresolved.txt,${NC}"
        echo -e "  ${DIM}then move the entry to mods.txt. View with: elm resolve${NC}"
    fi
    echo ""
}

cmd_add() {
    check_packwiz; check_pack_init

    # Handle --stage and --import flags
    if [[ "${1:-}" == "--stage" ]]; then
        cmd_stage; return
    fi
    if [[ "${1:-}" == "--import" ]]; then
        shift
        cmd_cf_import "${1:-}"; return
    fi

    if [[ $# -eq 0 ]]; then
        cmd_add_interactive; return
    fi

    # Handle file: prefix — route to cmd_add_file
    if [[ "$1" == file:* ]]; then
        local file_path="${1#file:}"
        shift
        # Check for --slug flag
        local slug_flag=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --slug) slug_flag="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        cmd_add_file "$file_path" "$slug_flag"
        return
    fi

    header "Adding ${#} mod(s)"
    DEPS_ADDED=()

    for input in "$@"; do
        # Support file: prefix inline for batch adds too
        if [[ "$input" == file:* ]]; then
            local fp="${input#file:}"
            import_jar_as_mod "$fp" "" && {
                local auto_slug; auto_slug=$(basename "$fp" | sed 's/\.jar$//; s/[-_][0-9].*$//' | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
                is_in_modlist "$auto_slug" || append_to_modlist "local:${auto_slug}" "added via file"
            }
            continue
        fi

        local parsed
        parsed="$(parse_mod_entry "$input")" || continue
        IFS='|' read -r source slug url pinned <<< "$parsed"

        if install_mod "$source" "$slug" "$url" "$pinned"; then
            is_in_modlist "$slug" || { append_to_modlist "$input"; log INFO "Added to mods.txt"; }
        else
            echo ""
            echo -e "  ${YELLOW}Failed '${slug}'. Try:${NC}"
            echo "    elm search ${slug}"
            echo "    elm add cf:alternate-slug"
            echo "    elm add url:https://direct-link.jar"
            echo "    elm add file:/path/to/mod.jar"
            echo ""
        fi
    done

    if (( ${#DEPS_ADDED[@]} > 0 )); then
        separator
        echo -e "  ${MAGENTA}Dependencies:${NC}"
        printf '    ↳ %s\n' "${DEPS_ADDED[@]}"
    fi

    pw refresh 2>>"$RUN_LOG"
}

cmd_add_interactive() {
    header "Interactive Add"
    echo -e "  Enter mod slugs (supports mr:, cf:, url: prefixes)."
    echo -e "  Blank or ${BOLD}done${NC} to finish."
    echo ""

    local queue=()
    while true; do
        echo -ne "  ${CYAN}mod>${NC} "
        read -r input
        [[ -z "$input" || "$input" == "done" || "$input" == "q" ]] && break
        queue+=("$input")
        echo -e "    ${DIM}+ queued${NC}"
    done

    (( ${#queue[@]} == 0 )) && { echo -e "\n  ${DIM}Nothing queued.${NC}"; return; }
    echo ""
    echo -e "  ${BOLD}Installing ${#queue[@]} mod(s)...${NC}"
    separator
    cmd_add "${queue[@]}"
}

cmd_remove() {
    check_packwiz; check_pack_init

    if [[ -z "${1:-}" ]]; then
        echo "Usage: elm rm <query>"
        echo "  Query can be a partial name — matching .pw.toml files will be shown."
        return 1
    fi

    local query="$1"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    # ── Scan installed .pw.toml files for matches ────────────────────
    local -a match_slugs=() match_names=() match_files=()

    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local slug name filename
        slug=$(basename "$toml" .pw.toml)
        name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "$slug")
        filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")

        # Match against slug, name, and filename (case-insensitive)
        local slug_lower name_lower file_lower
        slug_lower=$(echo "$slug" | tr '[:upper:]' '[:lower:]')
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        file_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')

        if [[ "$slug_lower" == *"$query_lower"* || "$name_lower" == *"$query_lower"* || "$file_lower" == *"$query_lower"* ]]; then
            match_slugs+=("$slug")
            match_names+=("$name")
            match_files+=("$filename")
        fi
    done

    # ── No matches ───────────────────────────────────────────────────
    if [[ ${#match_slugs[@]} -eq 0 ]]; then
        log FAIL "No installed mods matching '${query}'"
        echo -e "  ${DIM}Tip: Run ${CYAN}elm ls${NC} ${DIM}to see all installed mods${NC}"
        return 1
    fi

    # ── Exact single match → remove directly ─────────────────────────
    local target_slug=""
    if [[ ${#match_slugs[@]} -eq 1 ]]; then
        target_slug="${match_slugs[0]}"
        echo -e "  ${BOLD}Match:${NC} ${match_names[0]} ${DIM}(${match_slugs[0]})${NC}"
    else
        # ── Multiple matches → numbered list ─────────────────────────
        echo ""
        echo -e "  ${CYAN}${BOLD}Mods matching '${query}':${NC}"
        echo ""
        local idx=1
        for i in "${!match_slugs[@]}"; do
            local side
            side=$(grep -oP '^side\s*=\s*"\K[^"]+' "${PACK_DIR}/mods/${match_slugs[$i]}.pw.toml" 2>/dev/null || echo "both")
            local si=""
            case "$side" in
                client) si="${CYAN}C${NC}" ;; server) si="${MAGENTA}S${NC}" ;; *) si="${DIM}B${NC}" ;;
            esac
            printf "    ${BOLD}%2d${NC}) [%b] %-35s %s\n" \
                "$idx" "$si" "${match_names[$i]}" "${DIM}${match_files[$i]}${NC}"
            ((idx++))
        done
        echo ""
        echo -e "    ${BOLD} 0${NC}) Cancel"
        echo ""

        local choice
        read -rp "  Remove which mod? [1-$((idx-1)), 0=cancel]: " choice </dev/tty

        if [[ "$choice" == "0" || -z "$choice" ]]; then
            echo "  Cancelled."
            return 0
        fi

        # Support removing multiple: "1 3 5" or "1,3,5"
        local -a picks=()
        choice="${choice//,/ }"
        for c in $choice; do
            if [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -lt "$idx" ]]; then
                picks+=("$((c - 1))")
            fi
        done

        if [[ ${#picks[@]} -eq 0 ]]; then
            echo "  Invalid selection."
            return 1
        fi

        # Remove each selected mod
        for pi in "${picks[@]}"; do
            target_slug="${match_slugs[$pi]}"
            local jar_filename="${match_files[$pi]}"
            echo ""
            header "Removing: ${match_names[$pi]} (${target_slug})"

            pw remove "$target_slug" --yes 2>>"$RUN_LOG" && log OK "Removed from pack" || log WARN "Remove may have failed — cleaning up manually"

            # Remove the .pw.toml if packwiz didn't
            [[ -f "${PACK_DIR}/mods/${target_slug}.pw.toml" ]] && rm -f "${PACK_DIR}/mods/${target_slug}.pw.toml"

            # Clean from mods.txt
            if [[ -f "$MODS_FILE" ]]; then
                local tmp; tmp="$(mktemp)"
                grep -vE "^!?((mr|cf|url|local):)?${target_slug}(\s|#|$)" "$MODS_FILE" > "$tmp" || true
                mv "$tmp" "$MODS_FILE"
                log INFO "Removed from mods.txt"
            fi

            # Clean JAR from server/mods/ and cdn/jars/ if self-hosted
            if [[ -n "$jar_filename" ]]; then
                local parent; parent=$(dirname "$PACK_DIR")
                rm -f "${PACK_DIR}/mods/${jar_filename}" 2>/dev/null || true
                rm -f "${parent}/server/mods/${jar_filename}" 2>/dev/null || true
                rm -f "${parent}/cdn/jars/${jar_filename}" 2>/dev/null || true
            fi
        done

        pw refresh 2>>"$RUN_LOG"
        return 0
    fi

    # ── Single match removal ─────────────────────────────────────────
    local jar_filename="${match_files[0]}"
    header "Removing: ${match_names[0]} (${target_slug})"

    pw remove "$target_slug" --yes 2>>"$RUN_LOG" && log OK "Removed from pack" || log WARN "Remove may have failed — cleaning up manually"

    # Remove .pw.toml if packwiz didn't
    [[ -f "${PACK_DIR}/mods/${target_slug}.pw.toml" ]] && rm -f "${PACK_DIR}/mods/${target_slug}.pw.toml"

    # Clean from mods.txt
    if [[ -f "$MODS_FILE" ]]; then
        local tmp; tmp="$(mktemp)"
        grep -vE "^!?((mr|cf|url|local):)?${target_slug}(\s|#|$)" "$MODS_FILE" > "$tmp" || true
        mv "$tmp" "$MODS_FILE"
        log INFO "Removed from mods.txt"
    fi

    # Clean JAR copies
    if [[ -n "$jar_filename" ]]; then
        local parent; parent=$(dirname "$PACK_DIR")
        rm -f "${PACK_DIR}/mods/${jar_filename}" 2>/dev/null || true
        rm -f "${parent}/server/mods/${jar_filename}" 2>/dev/null || true
        rm -f "${parent}/cdn/jars/${jar_filename}" 2>/dev/null || true
    fi

    pw refresh 2>>"$RUN_LOG"
}

cmd_list() {
    check_pack_init
    local side_filter="" show_version=false use_native=false

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deps)          cmd_deps; return ;;
            --side|-s)       side_filter="$2"; shift 2 ;;
            --version|-v)    show_version=true; shift ;;
            --native|-n)     use_native=true; shift ;;
            *)               shift ;;
        esac
    done

    # Native packwiz list (passthrough mode)
    if $use_native; then
        local args=()
        [[ -n "$side_filter" ]] && args+=("--side" "$side_filter")
        $show_version && args+=("--version")
        pw list "${args[@]}" 2>>"$RUN_LOG"
        return
    fi

    header "Installed Mods"
    [[ -d "${PACK_DIR}/mods" ]] || { echo -e "  ${DIM}No mods yet.${NC}"; return; }

    local count=0
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local name slug side filename pinned_pw=""
        name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || basename "$toml" .pw.toml)
        slug=$(basename "$toml" .pw.toml)
        side=$(grep -oP '^side\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "both")
        filename=$(grep -oP '^filename\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "")

        # Check native packwiz pin
        grep -q '^\[pin\]' "$toml" 2>/dev/null && pinned_pw="📌"

        # Side filter
        if [[ -n "$side_filter" ]]; then
            [[ "$side" != "$side_filter" && "$side" != "both" ]] && continue
        fi

        local si=""
        case "$side" in
            client) si="${CYAN}C${NC}" ;; server) si="${MAGENTA}S${NC}" ;; *) si="${DIM}B${NC}" ;;
        esac

        local tracked=""
        is_in_modlist "$slug" && tracked="${GREEN}✓${NC}" || tracked="${YELLOW}∘${NC}"

        local version_str=""
        if $show_version && [[ -n "$filename" ]]; then
            version_str=" ${DIM}(${filename})${NC}"
        fi

        echo -e "  ${tracked} [${si}] ${pinned_pw}${name}${version_str}"
        (( count++ ))
    done

    echo ""
    echo -e "  ${BOLD}${count} mods total${NC}"
    echo -e "  ${GREEN}✓${NC}=listed  ${YELLOW}∘${NC}=dep  ${CYAN}C${NC}=client ${MAGENTA}S${NC}=server ${DIM}B${NC}=both  📌=pinned"
    echo ""
    echo -e "  ${DIM}Flags: --side <client|server|both>  --version  --native${NC}"
}

cmd_update() {
    check_packwiz; check_pack_init
    header "Updating All Mods"

    if [[ -f "$MODS_FILE" ]]; then
        local hp=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            local cl; cl="$(echo "$line" | sed 's/\s*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [[ "$cl" == !* ]]; then
                $hp || { echo -e "  ${YELLOW}Pinned (skipping):${NC}"; hp=true; }
                echo -e "    ${CYAN}⊘${NC} ${cl:1}"
            fi
        done < "$MODS_FILE"
        $hp && echo ""
    fi

    log INFO "Running packwiz update --all..."
    pw update --all --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Some updates failed"
    pw refresh 2>>"$RUN_LOG"

    # Auto-publish to CDN if configured
    auto_publish_cdn
}

cmd_status() {
    check_pack_init
    header "Pack Status"

    local pn mc
    pn=$(grep -oP '^name\s*=\s*"\K[^"]+' "${PACK_DIR}/pack.toml" 2>/dev/null || echo "?")
    mc=$(grep -A5 '\[versions\]' "${PACK_DIR}/pack.toml" | grep -oP 'minecraft\s*=\s*"\K[^"]+' 2>/dev/null || echo "?")
    echo -e "  Pack: ${BOLD}${pn}${NC}  MC: ${mc}"

    local inst=0 listed=0 pinned=0
    [[ -d "${PACK_DIR}/mods" ]] && inst=$(find "${PACK_DIR}/mods" -name "*.pw.toml" 2>/dev/null | wc -l)
    [[ -f "$MODS_FILE" ]] && {
        listed=$(grep -cvE '^\s*#|^\s*@|^\s*$' "$MODS_FILE" 2>/dev/null || echo 0)
        pinned=$(grep -cE '^\s*!' "$MODS_FILE" 2>/dev/null || echo 0)
    }
    local deps=$(( inst - listed )); (( deps < 0 )) && deps=0

    echo -e "  Installed: ${GREEN}${inst}${NC}  Listed: ${BLUE}${listed}${NC}  Deps: ${MAGENTA}~${deps}${NC}  Pinned: ${CYAN}${pinned}${NC}"

    [[ -f "${LOG_DIR}/last_failed.txt" ]] && {
        local fc; fc=$(wc -l < "${LOG_DIR}/last_failed.txt" 2>/dev/null || echo 0)
        (( fc > 0 )) && {
            echo -e "\n  ${RED}Last sync failures:${NC}"
            while IFS= read -r m; do echo -e "    ${RED}•${NC} $m"; done < "${LOG_DIR}/last_failed.txt"
        }
    }
    echo ""
}

cmd_deps() {
    check_pack_init
    header "Unlisted Dependencies"
    [[ -d "${PACK_DIR}/mods" ]] || { echo -e "  ${DIM}No mods.${NC}"; return; }

    local found=0
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local slug name
        slug=$(basename "$toml" .pw.toml)
        name=$(grep -oP '^name\s*=\s*"\K[^"]+' "$toml" 2>/dev/null || echo "$slug")
        is_in_modlist "$slug" || { echo -e "    ${MAGENTA}↳${NC} ${name}"; (( found++ )); }
    done

    (( found == 0 )) && echo -e "  ${GREEN}All mods tracked in mods.txt${NC}"
    echo ""
}

cmd_search() {
    # Handle --open flag
    if [[ "${1:-}" == "--open" ]]; then
        shift
        cmd_open "${1:-}"; return
    fi

    local query="${1:-}"

    if [[ -z "$query" ]]; then
        echo -e "${RED}Usage: elm search <query>${NC}"
        echo ""
        echo -e "  Search Modrinth (and CurseForge if API key is set) for mods."
        echo ""
        echo -e "  ${BOLD}Examples:${NC}"
        echo -e "    ${CYAN}elm search jei${NC}            # search for Just Enough Items"
        echo -e "    ${CYAN}elm search \"applied ener\"${NC}  # fuzzy search"
        echo -e "    ${CYAN}elm search optifine${NC}        # find alternatives"
        echo ""
        echo -e "  ${DIM}Results are filtered by MC ${MC_VERSION} / ${LOADER}${NC}"
        [[ -z "$CURSEFORGE_API_KEY" ]] && echo -e "  ${DIM}Set CURSEFORGE_API_KEY in config to also search CurseForge${NC}"
        echo ""
        return 1
    fi

    header "Search: ${query}"
    echo -e "  ${DIM}Filtering: MC ${MC_VERSION} / ${LOADER}${NC}"
    echo ""

    local selected
    selected=$(interactive_search "$query" "install") || return 0

    if [[ -n "$selected" ]]; then
        echo ""
        echo -e "  ${GREEN}Selected: ${BOLD}${selected}${NC}"
        echo ""
        echo -e "  ${CYAN}(i)${NC} Install now and add to mods.txt"
        echo -e "  ${CYAN}(a)${NC} Add to mods.txt only (install on next sync)"
        echo -e "  ${DIM}(n)${NC} Cancel"
        echo ""
        echo -ne "  ${CYAN}choice [i/a/n]>${NC} "
        read -r choice < /dev/tty

        case "$choice" in
            i|I)
                check_packwiz; check_pack_init
                local parsed
                parsed="$(parse_mod_entry "$selected")" || return 1
                IFS='|' read -r source slug url pinned <<< "$parsed"
                if install_mod "$source" "$slug" "$url" "$pinned"; then
                    is_in_modlist "$slug" || { append_to_modlist "$selected"; log INFO "Added to mods.txt"; }
                    pw refresh 2>>"$RUN_LOG"
                else
                    log FAIL "Install failed for ${slug}"
                fi
                ;;
            a|A)
                is_in_modlist "${selected#*:}" || {
                    append_to_modlist "$selected"
                    log OK "Added ${selected} to mods.txt (run 'elm sync' to install)"
                }
                ;;
            *)
                echo -e "  ${DIM}Cancelled.${NC}"
                ;;
        esac
    fi
}

cmd_doctor() {
    check_pack_init
    header "Pack Doctor"
    local issues=0

    echo -e "  ${BLUE}Checking listed mods are installed...${NC}"
    [[ -f "$MODS_FILE" ]] && while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue
        local parsed; parsed="$(parse_mod_entry "$line")" || continue
        IFS='|' read -r _ slug _ _ <<< "$parsed"
        is_installed "$slug" || { log WARN "Missing: ${slug}"; (( issues++ )); }
    done < "$MODS_FILE"

    echo -e "  ${BLUE}Refreshing index...${NC}"
    pw refresh 2>>"$RUN_LOG" && log OK "Index clean" || { log WARN "Index issues"; (( issues++ )); }

    echo ""
    (( issues == 0 )) && echo -e "  ${GREEN}${BOLD}All good!${NC}" || echo -e "  ${YELLOW}${issues} issue(s). Run 'elm sync' to fix.${NC}"

    # Run the full verification audit
    verify_all_mods
}

cmd_verify() {
    check_pack_init
    verify_all_mods
}

# ============================================================================
# NETCHECK — network self-diagnosis for pack serving
# ============================================================================
# Tests the full chain: local files → Caddy container → LAN → public internet
# Tells you exactly where things break if clients can't reach pack.toml.

cmd_netcheck() {
    header "Network Diagnostics"

    command -v curl &>/dev/null || { log FAIL "curl is required for network checks"; return 1; }

    local issues=0
    local parent; parent=$(dirname "$PACK_DIR")

    # ── Step 1: Gather targets ──
    local targets; targets=$(target_list 2>/dev/null)
    if [[ -z "$targets" ]]; then
        log WARN "No targets registered — checking global config only"
        targets="__global__"
    fi

    while IFS= read -r target_name; do
        local label="$target_name"
        [[ "$target_name" == "__global__" ]] && label="(global)"

        separator
        echo -e "  ${BOLD}Target: ${CYAN}${label}${NC}"
        echo ""

        # ── Step 2: Check local cdn/ files exist ──
        local cdn_dir="${parent}/cdn"
        [[ "$target_name" != "__global__" ]] && cdn_dir="${parent}/cdn/${target_name}"

        if [[ -f "${cdn_dir}/pack.toml" ]]; then
            log OK "cdn/pack.toml exists locally"
        else
            log FAIL "cdn/pack.toml NOT FOUND at ${cdn_dir}/"
            echo -e "    ${DIM}Run: elm deploy cdn --target ${target_name}${NC}"
            (( issues++ ))
            continue
        fi

        local toml_count=0
        [[ -d "${cdn_dir}/mods" ]] && toml_count=$(find "${cdn_dir}/mods" -name "*.pw.toml" 2>/dev/null | wc -l)
        local jar_count=0
        [[ -d "${cdn_dir}/jars" ]] && jar_count=$(find "${cdn_dir}/jars" -name "*.jar" 2>/dev/null | wc -l)
        echo -e "    ${DIM}mods/*.pw.toml: ${toml_count}  |  jars/*.jar: ${jar_count}${NC}"

        # ── Step 3: Resolve URLs ──
        local cdn_domain; cdn_domain=$(resolve_cdn_domain "$([[ "$target_name" != "__global__" ]] && echo "$target_name")" 2>/dev/null)
        local cdn_base; cdn_base=$(resolve_cdn_base_url "$([[ "$target_name" != "__global__" ]] && echo "$target_name")" 2>/dev/null)
        local pack_url="${cdn_base}/pack.toml"
        local index_url="${cdn_base}/index.toml"

        echo -e "    CDN domain:  ${CYAN}${cdn_domain}${NC}"
        echo -e "    pack.toml:   ${CYAN}${pack_url}${NC}"
        echo ""

        # ── Step 4: Check Docker/Caddy is running ──
        if command -v docker &>/dev/null; then
            local caddy_running=false
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy\|packserver"; then
                log OK "Caddy container is running"
                caddy_running=true
            else
                log FAIL "Caddy container not found/not running"
                echo -e "    ${DIM}Run: elm deploy create --target ${target_name}${NC}"
                echo -e "    ${DIM}Then: elm deploy start ${target_name}${NC}"
                (( issues++ ))
            fi
        else
            log WARN "Docker not available — skipping container check"
        fi

        # ── Step 5: Localhost/internal check ──
        echo ""
        echo -e "  ${BOLD}Internal (localhost):${NC}"

        # Determine internal URL (always http, ports 8080 or 80)
        local internal_port="8080"
        [[ -n "$CDN_DOMAIN" ]] && internal_port="80"

        local internal_base="http://localhost:${internal_port}"
        [[ "$target_name" != "__global__" ]] && internal_base="${internal_base}/${target_name}"

        local internal_pack="${internal_base}/pack.toml"
        local internal_health="${internal_base%/*}/health"
        [[ "$target_name" == "__global__" ]] && internal_health="http://localhost:${internal_port}/health"

        # Health endpoint
        local http_code
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$internal_health" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log OK "Caddy health → ${internal_health} (HTTP ${http_code})"
        else
            log FAIL "Caddy health → ${internal_health} (HTTP ${http_code})"
            echo -e "    ${DIM}Caddy may not be running or port ${internal_port} is not bound${NC}"
            (( issues++ ))
        fi

        # pack.toml from localhost
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$internal_pack" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log OK "pack.toml → ${internal_pack} (HTTP ${http_code})"
        else
            log FAIL "pack.toml → ${internal_pack} (HTTP ${http_code})"
            echo -e "    ${DIM}File may not be published or Caddy file root is misconfigured${NC}"
            (( issues++ ))
        fi

        # index.toml
        local internal_index="${internal_base}/index.toml"
        http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$internal_index" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log OK "index.toml reachable"
        else
            log WARN "index.toml → HTTP ${http_code} (may not be published yet)"
        fi

        # Spot-check a random .pw.toml
        if (( toml_count > 0 )); then
            local sample_toml; sample_toml=$(find "${cdn_dir}/mods" -name "*.pw.toml" 2>/dev/null | head -1)
            if [[ -n "$sample_toml" ]]; then
                local sample_slug; sample_slug=$(basename "$sample_toml")
                local sample_url="${internal_base}/mods/${sample_slug}"
                http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$sample_url" 2>/dev/null || echo "000")
                if [[ "$http_code" == "200" ]]; then
                    log OK "Sample mod → mods/${sample_slug} (HTTP ${http_code})"
                else
                    log WARN "Sample mod → mods/${sample_slug} (HTTP ${http_code})"
                fi
            fi
        fi

        # Spot-check a self-hosted JAR
        if (( jar_count > 0 )); then
            local sample_jar; sample_jar=$(find "${cdn_dir}/jars" -name "*.jar" 2>/dev/null | head -1)
            if [[ -n "$sample_jar" ]]; then
                local jar_name; jar_name=$(basename "$sample_jar")
                local jar_url="${internal_base}/jars/${jar_name}"
                http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$jar_url" 2>/dev/null || echo "000")
                if [[ "$http_code" == "200" ]]; then
                    log OK "Sample JAR → jars/${jar_name} (HTTP ${http_code})"
                else
                    log WARN "Sample JAR → jars/${jar_name} (HTTP ${http_code})"
                fi
            fi
        fi

        # ── Step 6: LAN / VM IP check ──
        if [[ -n "$SERVER_VM_IP" && "$SERVER_VM_IP" != "localhost" ]]; then
            echo ""
            echo -e "  ${BOLD}LAN (${SERVER_VM_IP}):${NC}"

            local lan_base="http://${SERVER_VM_IP}:${internal_port}"
            [[ "$target_name" != "__global__" ]] && lan_base="${lan_base}/${target_name}"

            local lan_pack="${lan_base}/pack.toml"
            http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$lan_pack" 2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                log OK "pack.toml via LAN (HTTP ${http_code})"
            else
                log FAIL "pack.toml via LAN → HTTP ${http_code}"
                echo -e "    ${DIM}Firewall may be blocking port ${internal_port}${NC}"
                echo -e "    ${DIM}Check: sudo firewall-cmd --list-ports  or  sudo ufw status${NC}"
                (( issues++ ))
            fi
        fi

        # ── Step 7: Public / CDN domain check ──
        if [[ "$cdn_domain" != *":"* && "$cdn_domain" != "localhost"* ]]; then
            echo ""
            echo -e "  ${BOLD}Public (${cdn_domain}):${NC}"

            # DNS resolution
            if command -v dig &>/dev/null; then
                local dns_result; dns_result=$(dig +short "$cdn_domain" 2>/dev/null | head -1)
                if [[ -n "$dns_result" ]]; then
                    log OK "DNS resolves → ${dns_result}"
                else
                    log FAIL "DNS lookup failed for ${cdn_domain}"
                    echo -e "    ${DIM}Add an A record: ${cdn_domain} → ${SERVER_VM_IP:-your-server-ip}${NC}"
                    (( issues++ ))
                fi
            elif command -v nslookup &>/dev/null; then
                local dns_result; dns_result=$(nslookup "$cdn_domain" 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
                if [[ -n "$dns_result" ]]; then
                    log OK "DNS resolves → ${dns_result}"
                else
                    log FAIL "DNS lookup failed for ${cdn_domain}"
                    (( issues++ ))
                fi
            else
                log WARN "No dig/nslookup — skipping DNS check"
            fi

            # HTTPS connectivity
            http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "${pack_url}" 2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                log OK "pack.toml via HTTPS (HTTP ${http_code})"
            elif [[ "$http_code" == "000" ]]; then
                log FAIL "Connection failed — cannot reach ${cdn_domain}"
                echo -e "    ${DIM}Possible causes:${NC}"
                echo -e "    ${DIM}  • DNS not pointing to this server${NC}"
                echo -e "    ${DIM}  • Ports 80/443 not open (firewall or cloud provider)${NC}"
                echo -e "    ${DIM}  • Caddy hasn't provisioned TLS yet (check: docker logs caddy)${NC}"
                (( issues++ ))
            else
                log FAIL "pack.toml via HTTPS → HTTP ${http_code}"
                echo -e "    ${DIM}Server responded but returned an error${NC}"
                (( issues++ ))
            fi

            # TLS certificate check
            if [[ "$http_code" != "000" ]]; then
                local tls_info; tls_info=$(curl -svI --max-time 5 "https://${cdn_domain}/" 2>&1 | grep -i "SSL certificate\|issuer\|expire" | head -3)
                if [[ -n "$tls_info" ]]; then
                    echo -e "    ${DIM}TLS: $(echo "$tls_info" | head -1 | sed 's/^[* ]*//')${NC}"
                fi
            fi
        else
            echo ""
            echo -e "  ${DIM}No public domain configured — skipping external check${NC}"
            echo -e "  ${DIM}Set CDN_DOMAIN in config for auto-HTTPS via Caddy${NC}"
        fi

        # ── Step 8: Client simulation ──
        echo ""
        echo -e "  ${BOLD}Client Simulation:${NC}"
        echo -e "  ${DIM}(What a Minecraft client would do on connect)${NC}"

        # Try to fetch pack.toml and check it's valid TOML
        local pack_content
        pack_content=$(curl -sL --max-time 10 "$internal_pack" 2>/dev/null || echo "")
        if [[ -n "$pack_content" ]]; then
            if echo "$pack_content" | grep -q "^\[pack\]" 2>/dev/null; then
                log OK "pack.toml is valid (contains [pack] section)"
                # Extract pack-format and index info
                local pf; pf=$(echo "$pack_content" | grep -oP 'pack-format\s*=\s*"\K[^"]+' 2>/dev/null || echo "?")
                echo -e "    ${DIM}pack-format: ${pf}${NC}"
            else
                log WARN "pack.toml fetched but may be malformed (no [pack] section)"
                (( issues++ ))
            fi

            # Try fetching index.toml
            local idx_content
            idx_content=$(curl -sL --max-time 10 "$internal_index" 2>/dev/null || echo "")
            if echo "$idx_content" | grep -q "\[\[files\]\]" 2>/dev/null; then
                local file_count; file_count=$(echo "$idx_content" | grep -c "\[\[files\]\]" 2>/dev/null || echo 0)
                log OK "index.toml lists ${file_count} file(s)"
            elif [[ -n "$idx_content" ]]; then
                log WARN "index.toml fetched but may be incomplete"
            fi
        else
            log FAIL "Could not fetch pack.toml — client would fail to connect"
            (( issues++ ))
        fi

    done <<< "$targets"

    # ── Summary ──
    separator
    echo ""
    if (( issues == 0 )); then
        echo -e "  ${GREEN}${BOLD}All checks passed!${NC} Clients should be able to connect."
    else
        echo -e "  ${RED}${BOLD}${issues} issue(s) found.${NC} Fix the above and re-run ${CYAN}elm net${NC}."
    fi
    echo ""

    # ── Quick Reference ──
    echo -e "  ${BOLD}Manual curl commands to test from another machine:${NC}"
    echo ""
    local first_target; first_target=$(echo "$targets" | head -1)
    local sample_base; sample_base=$(resolve_cdn_base_url "$([[ "$first_target" != "__global__" ]] && echo "$first_target")" 2>/dev/null)
    echo -e "    ${DIM}# Health check${NC}"
    echo -e "    curl -I ${sample_base%/*}/health"
    echo ""
    echo -e "    ${DIM}# Fetch pack descriptor${NC}"
    echo -e "    curl -sL ${sample_base}/pack.toml"
    echo ""
    echo -e "    ${DIM}# Fetch mod index${NC}"
    echo -e "    curl -sL ${sample_base}/index.toml"
    echo ""
    echo -e "    ${DIM}# Fetch a specific .pw.toml${NC}"
    echo -e "    curl -sL ${sample_base}/mods/<slug>.pw.toml"
    echo ""
    echo -e "    ${DIM}# Check DNS resolution${NC}"
    echo -e "    dig ${cdn_domain:-your-domain}"
    echo ""
    echo -e "    ${DIM}# Check TLS certificate${NC}"
    echo -e "    curl -vI https://${cdn_domain:-your-domain}/ 2>&1 | grep -i 'ssl\\|issuer\\|expire'"
    echo ""
}

cmd_diff() {
    # Show a side-by-side: what mods.txt says vs what .pw.toml files contain
    check_pack_init
    header "Modlist ↔ PackWiz Diff"

    [[ -d "${PACK_DIR}/mods" ]] || { echo -e "  ${DIM}No mods installed.${NC}"; return; }
    [[ -f "$MODS_FILE" ]] || { echo -e "  ${DIM}No mods.txt found.${NC}"; return; }

    # Build lookup of requested slugs
    declare -A requested_map  # slug → original line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue
        local parsed
        parsed="$(parse_mod_entry "$line")" || continue
        IFS='|' read -r _ slug _ _ <<< "$parsed"
        requested_map["$slug"]="$line"
    done < "$MODS_FILE"

    # Build lookup of installed mods from .pw.toml
    declare -A installed_map  # slug → "name|source|mod-id|filename"
    for toml in "${PACK_DIR}/mods/"*.pw.toml; do
        [[ -f "$toml" ]] || continue
        local parsed
        parsed=$(parse_pw_toml "$toml") || continue
        IFS='|' read -r slug name mod_id source filename <<< "$parsed"
        installed_map["$slug"]="${name}|${source}|${mod_id}|${filename}"
    done

    # --- In mods.txt but not installed ---
    local missing=0
    for slug in "${!requested_map[@]}"; do
        if [[ -z "${installed_map[$slug]+_}" ]]; then
            # Check if it might be under a different toml filename
            local found=false
            for islug in "${!installed_map[@]}"; do
                IFS='|' read -r iname _ _ _ <<< "${installed_map[$islug]}"
                local rn in_
                rn=$(normalize_slug "$slug")
                in_=$(normalize_slug "$iname")
                if [[ "$in_" == *"$rn"* || "$rn" == *"$in_"* ]]; then
                    echo -e "  ${CYAN}↔${NC} mods.txt: ${BOLD}${slug}${NC} → installed as: ${BOLD}${islug}${NC} (${iname})"
                    found=true
                    break
                fi
            done
            if ! $found; then
                echo -e "  ${RED}✗${NC} mods.txt: ${BOLD}${slug}${NC} — ${RED}not installed${NC}"
                (( missing++ ))
            fi
        fi
    done

    # --- Installed but not in mods.txt ---
    local extra=0
    for slug in "${!installed_map[@]}"; do
        if [[ -z "${requested_map[$slug]+_}" ]]; then
            IFS='|' read -r name source _ _ <<< "${installed_map[$slug]}"
            # Check if any mods.txt slug is an alias for this
            local is_alias=false
            for rslug in "${!requested_map[@]}"; do
                local rn sn nn
                rn=$(normalize_slug "$rslug")
                sn=$(normalize_slug "$slug")
                nn=$(normalize_slug "$name")
                if [[ "$nn" == *"$rn"* || "$sn" == *"$rn"* || "$rn" == *"$sn"* ]]; then
                    is_alias=true
                    break
                fi
            done
            if ! $is_alias; then
                echo -e "  ${MAGENTA}+${NC} installed: ${BOLD}${name}${NC} (${slug}) — ${DIM}not in mods.txt (dep?)${NC}"
                (( extra++ ))
            fi
        fi
    done

    # --- Summary ---
    echo ""
    separator
    echo -e "  mods.txt entries:  ${BLUE}${#requested_map[@]}${NC}"
    echo -e "  Installed .pw.toml: ${GREEN}${#installed_map[@]}${NC}"
    (( missing > 0 )) && echo -e "  Missing:           ${RED}${missing}${NC} (in mods.txt, not installed)"
    (( extra > 0 ))   && echo -e "  Unlisted:          ${MAGENTA}${extra}${NC} (installed, not in mods.txt)"
    echo ""

    # Show unresolved count if any
    if [[ -f "$UNRESOLVED_FILE" ]]; then
        local ur_count
        ur_count=$(grep -cvE '^\s*(#|$)' "$UNRESOLVED_FILE" 2>/dev/null || echo 0)
        if (( ur_count > 0 )); then
            echo -e "  ${YELLOW}${BOLD}Unresolved mods: ${ur_count}${NC}"
            echo -e "  ${DIM}Fix with: elm resolve search  or  elm add --stage${NC}"
            echo ""
        fi
    fi
}

# ============================================================================
# CONSOLIDATED CHECK (replaces doctor/verify/diff/status)
# ============================================================================
cmd_check() {
    local do_diff=false do_refresh=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diff)    do_diff=true; shift ;;
            --refresh) do_refresh=true; shift ;;
            *)         shift ;;
        esac
    done

    # Run status overview
    cmd_status

    # Run doctor checks
    cmd_doctor

    # Run verify audit
    cmd_verify

    # Optional: show diff
    if $do_diff; then
        cmd_diff
    fi

    # Optional: refresh index
    if $do_refresh; then
        cmd_refresh ""
    fi
}

cmd_export() {
    check_packwiz; check_pack_init
    local fmt="${1:-modrinth}" side="${2:-}"
    header "Exporting (${fmt})"

    # Build --side flag if specified
    local side_flag=""
    [[ -n "$side" ]] && side_flag="--side $side"

    # Refresh with --build for distribution (generates internal hashes)
    log INFO "Refreshing index for distribution..."
    pw refresh --build 2>>"$RUN_LOG"

    case "$fmt" in
        modrinth|mr)
            pw modrinth export $side_flag 2>>"$RUN_LOG" && log OK "Modrinth .mrpack created" || log FAIL "Export failed"
            ;;
        curseforge|cf)
            pw curseforge export $side_flag 2>>"$RUN_LOG" && log OK "CurseForge .zip created" || log FAIL "Export failed"
            ;;
        md|markdown)
            cmd_markdown; return
            ;;
        *)
            echo -e "${RED}Usage: elm export [mr|cf|md] [client|server]${NC}"
            exit 1
            ;;
    esac
}

cmd_serve() {
    check_packwiz; check_pack_init
    header "Local Pack Server"
    echo -e "  Serves pack at ${CYAN}http://localhost:8080/pack.toml${NC}"
    echo -e "  Index auto-refreshes on each request."
    echo -e "  ${DIM}Ctrl+C to stop${NC}"
    echo ""
    pw serve
}

# ============================================================================
# NATIVE PACKWIZ COMMANDS (direct passthroughs + wrappers)
# ============================================================================

cmd_pin() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: elm pin <slug>}"
    header "Pinning: ${slug}"
    # Native packwiz pin — adds [pin] section to .pw.toml
    pw pin "$slug" 2>>"$RUN_LOG" && log OK "Pinned (won't receive updates)" || log FAIL "Pin failed"
}

cmd_unpin() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: elm unpin <slug>}"
    header "Unpinning: ${slug}"
    pw unpin "$slug" 2>>"$RUN_LOG" && log OK "Unpinned (will receive updates)" || log FAIL "Unpin failed"
}

cmd_migrate() {
    check_packwiz; check_pack_init
    local target="${1:?Usage: elm migrate <minecraft|loader> [version]}"
    local version="${2:-}"

    case "$target" in
        minecraft|mc)
            header "Migrating Minecraft Version"
            if [[ -n "$version" ]]; then
                log INFO "Migrating to Minecraft ${version}..."
                pw migrate minecraft "$version" --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Some mods may not support ${version}"
            else
                log INFO "Interactive Minecraft migration..."
                pw migrate minecraft 2>>"$RUN_LOG"
            fi
            ;;
        loader|forge|neoforge|fabric|quilt)
            header "Migrating Loader Version"
            if [[ -n "$version" ]]; then
                log INFO "Migrating loader to ${version}..."
                pw migrate loader "$version" --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Migration had issues"
            else
                log INFO "Interactive loader migration..."
                pw migrate loader 2>>"$RUN_LOG"
            fi
            ;;
        *)
            echo -e "${RED}Usage: elm migrate <minecraft|loader> [version]${NC}"
            echo "  elm migrate minecraft 1.21.1"
            echo "  elm migrate loader 47.2.0"
            exit 1
            ;;
    esac
}

cmd_settings() {
    check_packwiz; check_pack_init
    local subcmd="${1:-show}"
    shift || true

    case "$subcmd" in
        versions|acceptable-versions|av)
            if [[ $# -gt 0 ]]; then
                # Set acceptable versions
                local versions="$*"
                header "Setting Acceptable Game Versions"
                log INFO "Setting: ${versions}"
                pw settings acceptable-versions "$versions" 2>>"$RUN_LOG" && log OK "Done" || log FAIL "Failed"
            else
                header "Acceptable Game Versions"
                local current
                current=$(grep -A5 '\[options\]' "${PACK_DIR}/pack.toml" 2>/dev/null | grep 'acceptable-game-versions' || echo "")
                if [[ -n "$current" ]]; then
                    echo -e "  ${current}"
                else
                    echo -e "  ${DIM}None set (only exact MC version accepted)${NC}"
                fi
                echo ""
                echo -e "  ${DIM}Set with: elm config versions 1.20,1.20.1,1.20.2${NC}"
            fi
            ;;
        show|"")
            header "Pack Settings"
            echo -e "  ${BOLD}pack.toml:${NC}"
            cat "${PACK_DIR}/pack.toml"
            echo ""
            ;;
        *)
            echo -e "${RED}Usage: elm config <versions|show> [values]${NC}"
            echo "  elm config versions 1.20,1.20.1"
            echo "  elm config show"
            ;;
    esac
}

# ============================================================================
# JAR FILE IMPORT — add self-hosted mods from JAR files
# ============================================================================
#
# import_jar_as_mod <jar_path> [slug_override]
#   Takes a JAR file path, generates a .pw.toml, hashes it, copies to:
#     pack/mods/  — the .pw.toml + JAR for packwiz
#     server/mods/ — the JAR for the Minecraft server
#     cdn/jars/    — the JAR for client downloads via Caddy
#   Returns 0 on success.

import_jar_as_mod() {
    local jar_path="$1"
    local slug_override="${2:-}"

    [[ -f "$jar_path" ]] || { log FAIL "JAR not found: ${jar_path}"; return 1; }

    local jar_filename
    jar_filename=$(basename "$jar_path")

    # Derive slug from filename: strip version suffix + .jar, lowercase
    local slug
    if [[ -n "$slug_override" ]]; then
        slug="$slug_override"
    else
        slug=$(echo "$jar_filename" | sed 's/\.jar$//; s/[-_][0-9].*$//' | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
    fi

    # Skip if already installed via Modrinth/CurseForge
    local existing_toml="${PACK_DIR}/mods/${slug}.pw.toml"
    if [[ -f "$existing_toml" ]]; then
        if grep -q '\[update\.modrinth\]\|\[update\.curseforge\]' "$existing_toml" 2>/dev/null; then
            log SKIP "${slug} — already installed from Modrinth/CurseForge"
            return 2
        fi
    fi

    # Compute SHA256
    local hash
    hash=$(sha256sum "$jar_path" | cut -d' ' -f1) || { log FAIL "hash failed for ${jar_filename}"; return 1; }

    # Resolve CDN base URL for download URL
    local parent; parent=$(dirname "$PACK_DIR")
    local cdn_base=""
    local download_url=""
    if [[ -n "$LOCAL_MODS_URL" ]]; then
        download_url="${LOCAL_MODS_URL}/${jar_filename}"
    else
        cdn_base=$(resolve_cdn_base_url "" 2>/dev/null || echo "")
        if [[ -n "$cdn_base" ]]; then
            download_url="${cdn_base}/jars/${jar_filename}"
        else
            download_url="http://localhost:8080/jars/${jar_filename}"
            log WARN "No CDN_DOMAIN or LOCAL_MODS_URL — using localhost URL"
        fi
    fi

    # Generate .pw.toml
    local toml_path="${PACK_DIR}/mods/${slug}.pw.toml"
    cat > "$toml_path" << TOML
name = "${slug}"
filename = "${jar_filename}"
side = "both"

[download]
url = "${download_url}"
hash-format = "sha256"
hash = "${hash}"
TOML

    # Copy JAR to pack/mods/ (for packwiz serve + distribution)
    cp "$jar_path" "${PACK_DIR}/mods/${jar_filename}" 2>/dev/null || true

    # Copy to server/mods/ if the directory exists
    local server_mods="${parent}/server/mods"
    if [[ -d "${parent}/server" ]]; then
        mkdir -p "$server_mods"
        cp "$jar_path" "${server_mods}/${jar_filename}" 2>/dev/null || true
    fi

    # Copy to cdn/jars/ for client downloads
    local cdn_jars="${parent}/cdn/jars"
    mkdir -p "$cdn_jars"
    cp "$jar_path" "${cdn_jars}/${jar_filename}" 2>/dev/null || true

    log OK "${slug} → ${jar_filename}"
    log DEP "  pack/mods/ + server/mods/ + cdn/jars/"
    return 0
}

# ============================================================================
# STAGE — batch-match JARs in staging/ against unresolved mods
# ============================================================================

cmd_stage() {
    check_packwiz; check_pack_init
    header "Staging — Batch Import JARs"

    # Create staging dir if needed
    mkdir -p "$STAGING_DIR"

    # Check for JARs
    local jars=()
    while IFS= read -r -d '' f; do
        jars+=("$f")
    done < <(find "$STAGING_DIR" -maxdepth 1 -name "*.jar" -print0 2>/dev/null)

    if (( ${#jars[@]} == 0 )); then
        echo -e "  ${DIM}No JAR files found in:${NC} ${CYAN}${STAGING_DIR}/${NC}"
        echo ""
        echo -e "  Drop .jar files into that directory, then run ${BOLD}elm add --stage${NC} again."
        echo -e "  JARs are fuzzy-matched against your unresolved mods list."
        echo ""
        return 0
    fi

    log INFO "Found ${#jars[@]} JAR(s) in staging/"

    # Load unresolved mods (if any)
    local -A unresolved_slugs
    local unresolved_count=0
    if [[ -f "$UNRESOLVED_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            local uslug
            uslug=$(echo "$line" | sed 's/\s*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$uslug" ]] && continue
            local norm; norm=$(normalize_slug "$uslug")
            unresolved_slugs["$norm"]="$uslug"
            (( unresolved_count++ ))
        done < "$UNRESOLVED_FILE"
    fi

    local matched=0 unmatched=0 skipped=0
    local matched_files=()

    echo ""
    for jar in "${jars[@]}"; do
        local jar_name; jar_name=$(basename "$jar")
        # Derive a normalized form from the filename for matching
        local jar_slug; jar_slug=$(echo "$jar_name" | sed 's/\.jar$//; s/[-_][0-9].*$//' | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
        local jar_norm; jar_norm=$(normalize_slug "$jar_slug")

        # Try exact match against unresolved
        local resolved_slug=""
        if [[ -n "${unresolved_slugs[$jar_norm]+_}" ]]; then
            resolved_slug="${unresolved_slugs[$jar_norm]}"
        else
            # Fuzzy: check if any unresolved slug is a substring of the JAR name or vice versa
            for norm in "${!unresolved_slugs[@]}"; do
                if [[ "$jar_norm" == *"$norm"* || "$norm" == *"$jar_norm"* ]]; then
                    resolved_slug="${unresolved_slugs[$norm]}"
                    break
                fi
            done
        fi

        if [[ -n "$resolved_slug" ]]; then
            # Matched an unresolved mod — import it
            if import_jar_as_mod "$jar" "$resolved_slug"; then
                (( matched++ ))
                matched_files+=("$jar")
                # Remove from unresolved.txt
                local escaped; escaped=$(printf '%s\n' "$resolved_slug" | sed 's/[][\\/.^$*]/\\&/g')
                sed -i "/^${escaped}\b/d" "$UNRESOLVED_FILE" 2>/dev/null || true
                # Add to mods.txt as local: if not already there
                if ! is_in_modlist "$resolved_slug"; then
                    append_to_modlist "local:${resolved_slug}" "imported from staging/"
                fi
                # Remove the normalized key so it can't double-match
                unset "unresolved_slugs[$(normalize_slug "$resolved_slug")]"
            else
                (( skipped++ ))
            fi
        else
            # No unresolved match — offer to import anyway
            echo -e "  ${YELLOW}?${NC} ${BOLD}${jar_name}${NC} — no unresolved match (slug: ${jar_slug})"
            echo -ne "    Import anyway? (y/N/s=slug override): "
            read -r answer
            case "$answer" in
                [yY])
                    if import_jar_as_mod "$jar" ""; then
                        (( matched++ ))
                        matched_files+=("$jar")
                        local auto_slug; auto_slug=$(echo "$jar_name" | sed 's/\.jar$//; s/[-_][0-9].*$//' | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
                        is_in_modlist "$auto_slug" || append_to_modlist "local:${auto_slug}" "imported from staging/"
                    fi
                    ;;
                s*|S*)
                    # User wants to specify a slug
                    echo -ne "    Enter slug: "
                    read -r custom_slug
                    if [[ -n "$custom_slug" ]]; then
                        if import_jar_as_mod "$jar" "$custom_slug"; then
                            (( matched++ ))
                            matched_files+=("$jar")
                            is_in_modlist "$custom_slug" || append_to_modlist "local:${custom_slug}" "imported from staging/"
                        fi
                    fi
                    ;;
                *)
                    (( unmatched++ ))
                    ;;
            esac
        fi
    done

    # Clean up — remove matched JARs from staging/
    if (( ${#matched_files[@]} > 0 )); then
        echo ""
        echo -ne "  Remove ${#matched_files[@]} matched JAR(s) from staging/? (Y/n): "
        read -r cleanup
        if [[ "$cleanup" != [nN] ]]; then
            for f in "${matched_files[@]}"; do
                rm -f "$f"
            done
            log OK "Cleaned up staging/"
        fi
    fi

    # Refresh packwiz index
    pw refresh 2>>"$RUN_LOG" || true

    # Summary
    separator
    echo ""
    echo -e "  ${BOLD}Staging Summary${NC}"
    echo -e "  Total JARs:    ${BOLD}${#jars[@]}${NC}"
    echo -e "  Matched:       ${GREEN}${matched}${NC}"
    echo -e "  Skipped:       ${CYAN}${skipped}${NC}"
    echo -e "  Unmatched:     ${YELLOW}${unmatched}${NC}"
    if (( unresolved_count > 0 )); then
        local remaining=0
        [[ -f "$UNRESOLVED_FILE" ]] && remaining=$(grep -cvE '^\s*(#|$)' "$UNRESOLVED_FILE" 2>/dev/null || echo 0)
        echo -e "  Still unresolved: ${RED}${remaining}${NC}"
    fi
    echo ""
}

# ============================================================================
# ADD FILE — import a single JAR as a self-hosted mod
# ============================================================================
#   elm add file:/path/to/my-mod.jar
#   elm add file:/path/to/my-mod.jar --slug custom-name

cmd_add_file() {
    check_packwiz; check_pack_init
    local jar_path="$1"
    local slug_override="${2:-}"

    # Expand ~ if present
    jar_path="${jar_path/#\~/$HOME}"

    if [[ ! -f "$jar_path" ]]; then
        log FAIL "File not found: ${jar_path}"
        echo -e "  ${DIM}Usage: elm add file:/path/to/mod.jar${NC}"
        return 1
    fi

    local jar_name; jar_name=$(basename "$jar_path")
    header "Adding JAR: ${jar_name}"

    if import_jar_as_mod "$jar_path" "$slug_override"; then
        local slug
        if [[ -n "$slug_override" ]]; then
            slug="$slug_override"
        else
            slug=$(echo "$jar_name" | sed 's/\.jar$//; s/[-_][0-9].*$//' | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
        fi

        # Add to mods.txt if not there
        if ! is_in_modlist "$slug"; then
            append_to_modlist "local:${slug}" "added via file"
            log INFO "Added to mods.txt as local:${slug}"
        fi

        # Remove from unresolved if present
        if is_unresolved "$slug"; then
            local escaped; escaped=$(printf '%s\n' "$slug" | sed 's/[][\\/.^$*]/\\&/g')
            sed -i "/^${escaped}\b/d" "$UNRESOLVED_FILE" 2>/dev/null || true
            log INFO "Removed from unresolved.txt"
        fi

        pw refresh 2>>"$RUN_LOG" || true
        echo ""
        echo -e "  ${GREEN}${BOLD}Done!${NC} ${slug} is installed as a self-hosted mod."
        echo -e "  ${DIM}Clients will download it from your CDN/server.${NC}"
        echo ""
    fi
}

# ============================================================================
# CURSEFORGE IMPORT (packwiz native)
# ============================================================================

cmd_cf_import() {
    check_packwiz; check_pack_init
    local path="${1:?Usage: elm add --import <path-to-zip>}"
    header "Importing CurseForge Pack"

    if [[ ! -f "$path" ]]; then
        log FAIL "File not found: ${path}"
        exit 1
    fi

    log INFO "Importing from ${path}..."
    log WARN "This will overwrite existing files!"
    echo -e "  ${YELLOW}Continue? (y/N)${NC}"
    read -r confirm
    [[ "$confirm" != [yY] ]] && exit 0

    pw curseforge import "$path" --yes 2>>"$RUN_LOG" && log OK "Import complete" || log FAIL "Import failed"
    pw refresh 2>>"$RUN_LOG"
}

cmd_detect() {
    check_packwiz; check_pack_init
    header "Detecting CurseForge Mods"
    log INFO "Scanning installed JARs for CurseForge matches..."
    pw curseforge detect --yes 2>>"$RUN_LOG" && log OK "Detection complete" || log WARN "Some files not detected"
    pw refresh 2>>"$RUN_LOG"
}

cmd_open() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: elm search --open <slug>}"

    # Check if it has a CurseForge or Modrinth source
    local toml="${PACK_DIR}/mods/${slug}.pw.toml"
    if [[ ! -f "$toml" ]]; then
        log FAIL "No .pw.toml for: ${slug}"
        return 1
    fi

    if grep -q '\[update\.modrinth\]' "$toml" 2>/dev/null; then
        local project_id
        project_id=$(grep -A5 '\[update\.modrinth\]' "$toml" | grep -oP 'mod-id\s*=\s*"\K[^"]+' 2>/dev/null || echo "")
        if [[ -n "$project_id" ]]; then
            local url="https://modrinth.com/mod/${project_id}"
            echo -e "  ${CYAN}${url}${NC}"
            command -v xdg-open &>/dev/null && xdg-open "$url" 2>/dev/null || true
            return
        fi
    fi

    if grep -q '\[update\.curseforge\]' "$toml" 2>/dev/null; then
        local project_id
        project_id=$(grep -A5 '\[update\.curseforge\]' "$toml" | grep -oP 'project-id\s*=\s*\K[0-9]+' 2>/dev/null || echo "")
        if [[ -n "$project_id" ]]; then
            local url="https://www.curseforge.com/projects/${project_id}"
            echo -e "  ${CYAN}${url}${NC}"
            command -v xdg-open &>/dev/null && xdg-open "$url" 2>/dev/null || true
            return
        fi
    fi

    log WARN "${slug} has no Modrinth/CurseForge source"
}

cmd_refresh() {
    check_packwiz; check_pack_init
    local build=false
    [[ "${1:-}" == "--build" || "${1:-}" == "-b" ]] && build=true

    header "Refreshing Pack Index"
    if $build; then
        log INFO "Building with internal hashes (for distribution)..."
        pw refresh --build 2>>"$RUN_LOG" && log OK "Index built" || log FAIL "Build failed"
    else
        pw refresh 2>>"$RUN_LOG" && log OK "Index refreshed" || log FAIL "Refresh failed"
    fi
}

cmd_markdown() {
    check_packwiz; check_pack_init
    header "Generating Mod List (Markdown)"
    pw utils markdown 2>>"$RUN_LOG"
}

# ============================================================================
# ALIASES COMMAND (legacy)
# ============================================================================
# New installs no longer create aliases — mismatched mods are auto-removed
# and sent to unresolved.txt. This command exists to manage any old aliases.

cmd_aliases() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls|"")
            init_aliases_file
            header "Mod Aliases"

            local count
            count=$(jq 'length' "$ALIASES_FILE" 2>/dev/null || echo 0)

            if (( count == 0 )); then
                echo -e "  ${DIM}No aliases tracked.${NC}"
                echo -e "  ${DIM}Aliases are created when packwiz installs a mod under a different name.${NC}"
                echo ""
                return
            fi

            printf "  ${BOLD}%-25s %-30s %s${NC}\n" "REQUESTED" "INSTALLED AS" "APPROVED"
            separator

            jq -r 'to_entries[] | "\(.key)|\(.value.resolved)|\(.value.name)|\(.value.approved_at)"' "$ALIASES_FILE" 2>/dev/null \
            | while IFS='|' read -r requested resolved name approved; do
                local short_date="${approved:-?}"
                [[ ${#short_date} -gt 10 ]] && short_date="${short_date:0:10}"
                printf "  ${CYAN}%-25s${NC} %-30s %s\n" "$requested" "${name} (${resolved})" "$short_date"
            done

            echo ""
            echo -e "  ${BOLD}${count} alias(es)${NC}"
            echo ""
            echo -e "  ${DIM}Remove: elm config alias remove <requested-slug>${NC}"
            echo -e "  ${DIM}Clear:  elm config alias clear${NC}"
            echo ""
            ;;

        remove|rm)
            local slug="${1:?Usage: elm config alias remove <requested-slug>}"
            init_aliases_file

            local resolved
            resolved=$(alias_get "$slug")
            if [[ -z "$resolved" ]]; then
                log FAIL "No alias found for: ${slug}"
                return 1
            fi

            local name
            name=$(jq -r --arg r "$slug" '.[$r].name // empty' "$ALIASES_FILE" 2>/dev/null)

            echo -e "  Alias: ${BOLD}${slug}${NC} → ${BOLD}${name}${NC} (${resolved})"
            echo ""
            echo -e "  ${CYAN}(a)${NC} Remove alias tracking only (keep the mod installed)"
            echo -e "  ${RED}(b)${NC} Remove alias AND uninstall the mod"
            echo -e "  ${DIM}(c)${NC} Cancel"
            echo ""
            echo -ne "  ${CYAN}choice [a/b/c]>${NC} "
            read -r choice

            case "$choice" in
                a|A)
                    alias_remove "$slug"
                    log OK "Alias removed (mod still installed as ${resolved})"
                    ;;
                b|B)
                    alias_remove "$slug"
                    if [[ -f "${PACK_DIR}/mods/${resolved}.pw.toml" ]]; then
                        pw remove "$resolved" --yes 2>>"$RUN_LOG" || rm -f "${PACK_DIR}/mods/${resolved}.pw.toml"
                        pw refresh 2>>"$RUN_LOG" || true
                        log OK "Alias removed and ${resolved} uninstalled"
                    else
                        log OK "Alias removed (${resolved}.pw.toml not found — may already be gone)"
                    fi

                    # Also remove from mods.txt if present
                    if [[ -f "$MODS_FILE" ]]; then
                        local tmp; tmp="$(mktemp)"
                        grep -vE "^!?((mr|cf|url):)?${slug}(\s|#|$)" "$MODS_FILE" > "$tmp" || true
                        mv "$tmp" "$MODS_FILE"
                    fi
                    ;;
                *)
                    echo -e "  ${DIM}Cancelled.${NC}"
                    ;;
            esac
            ;;

        clear)
            init_aliases_file
            local count
            count=$(jq 'length' "$ALIASES_FILE" 2>/dev/null || echo 0)

            if (( count == 0 )); then
                echo -e "  ${DIM}No aliases to clear.${NC}"
                return
            fi

            echo -e "  ${YELLOW}Clear all ${count} alias(es)? (y/N)${NC}"
            echo -e "  ${DIM}This only removes tracking — installed mods are untouched.${NC}"
            read -r confirm
            [[ "$confirm" != [yY] ]] && return

            echo '{}' > "$ALIASES_FILE"
            log OK "Cleared ${count} alias(es)"
            ;;

        help|*)
            echo ""
            echo -e "  ${BOLD}elm config alias${NC} — Manage Mod Aliases"
            echo ""
            echo -e "  ${CYAN}elm config alias list${NC}             Show all tracked aliases"
            echo -e "  ${CYAN}elm config alias remove <slug>${NC}    Remove alias (option to uninstall mod)"
            echo -e "  ${CYAN}elm config alias clear${NC}            Clear all alias tracking"
            echo ""
            echo -e "  Aliases are created when packwiz installs a mod under a"
            echo -e "  different slug than what you requested (e.g. ae2 → applied-energistics-2)."
            echo -e "  You must approve each alias before it's kept."
            echo ""
            ;;
    esac
}

# ============================================================================
# RESOLVE COMMAND — aggressively re-attempt all unresolved mods
# ============================================================================

cmd_resolve() {
    # Route unresolved management subcommands
    case "${1:-}" in
        list|search|edit|remove)
            cmd_unresolved "$@"; return ;;
    esac

    local mode="${1:-auto}"   # auto | interactive | <specific-slug>

    if [[ ! -f "$UNRESOLVED_FILE" ]]; then
        log OK "No unresolved mods — nothing to resolve"
        return 0
    fi

    # Load unresolved slugs
    local -a slugs=()
    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        local s="${line%%[[:space:]]*}"
        [[ -n "$s" ]] && slugs+=("$s")
    done < "$UNRESOLVED_FILE"

    if [[ ${#slugs[@]} -eq 0 ]]; then
        log OK "unresolved.txt is empty — nothing to resolve"
        return 0
    fi

    # Specific slug mode
    if [[ "$mode" != "auto" && "$mode" != "interactive" && "$mode" != "-i" ]]; then
        local target="$mode"
        local found=false
        for s in "${slugs[@]}"; do
            [[ "$s" == "$target" ]] && { found=true; break; }
        done
        if ! $found; then
            log FAIL "'${target}' not in unresolved.txt"
            return 1
        fi
        slugs=("$target")
        mode="interactive"  # single-slug always interactive
    fi

    [[ "$mode" == "-i" ]] && mode="interactive"
    local interactive="false"
    [[ "$mode" == "interactive" ]] && interactive="true"

    echo ""
    echo -e "${CYAN}${BOLD}══ Resolve Unresolved Mods ══${NC}"
    echo -e "${DIM}Strategy: exact slug → slug variations → fuzzy search → ${interactive} mode${NC}"
    echo -e "${DIM}Processing ${#slugs[@]} unresolved mod(s)...${NC}"
    echo ""

    local resolved=0 failed=0 skipped=0
    local -a resolved_list=() still_unresolved=()

    for slug in "${slugs[@]}"; do
        echo -e "  ${BOLD}→ ${slug}${NC}"

        # Skip if somehow already installed
        if is_installed "$slug"; then
            log SKIP "${slug} — already installed"
            resolved_list+=("$slug")
            ((resolved++))
            continue
        fi

        # Round 1: Try exact slug via direct download (quick re-check)
        if modrinth_download_mod "$slug" 2>/dev/null; then
            log OK "${slug} — found on Modrinth (exact)"
            resolved_list+=("$slug")
            ((resolved++))
            continue
        fi
        if [[ -n "$CURSEFORGE_API_KEY" ]] && curseforge_download_mod "$slug" 2>/dev/null; then
            log OK "${slug} — found on CurseForge (exact)"
            resolved_list+=("$slug")
            ((resolved++))
            continue
        fi

        # Round 2: Fuzzy resolution (slug variants + search)
        if fuzzy_resolve_mod "$slug" "$interactive"; then
            log OK "${slug} → resolved as '${FUZZY_RESOLVED_AS:-${slug}}'"
            resolved_list+=("$slug")
            ((resolved++))
            continue
        fi

        # Still unresolved
        echo -e "    ${RED}✗${NC} Could not resolve ${slug}"
        still_unresolved+=("$slug")
        ((failed++))
    done

    # ── Update files ─────────────────────────────────────────────────
    # Remove resolved mods from unresolved.txt
    for slug in "${resolved_list[@]}"; do
        sed -i "/^${slug}[[:space:]#]/d; /^${slug}$/d" "$UNRESOLVED_FILE" 2>/dev/null || true

        # Add to mods.txt if not already there
        if [[ -f "$MODS_FILE" ]] && ! grep -qE "^(mr:|cf:|url:|local:)?${slug}(\s|$)" "$MODS_FILE" 2>/dev/null; then
            echo "$slug" >> "$MODS_FILE"
        fi
    done

    # Refresh packwiz index if we resolved anything
    if [[ $resolved -gt 0 ]]; then
        pw refresh 2>>"$RUN_LOG" || true
    fi

    # ── Summary ──────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}── Resolve Summary ──${NC}"
    echo -e "  ${GREEN}✓ Resolved:${NC}   ${resolved}"
    echo -e "  ${RED}✗ Still unresolved:${NC} ${failed}"

    if [[ ${#still_unresolved[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}Still unresolved:${NC}"
        for s in "${still_unresolved[@]}"; do
            echo -e "    ${RED}•${NC} ${s}"
        done
        echo ""
        echo -e "  ${DIM}Tips:${NC}"
        echo -e "    ${DIM}• Run ${CYAN}elm resolve -i${NC} ${DIM}for interactive mode (pick from search results)${NC}"
        echo -e "    ${DIM}• Run ${CYAN}elm search <name>${NC} ${DIM}to find alternative slugs manually${NC}"
        echo -e "    ${DIM}• Add ${CYAN}url:https://...${NC} ${DIM}binding in mods.txt for direct-download mods${NC}"
        echo -e "    ${DIM}• Drop JARs in staging/ and run ${CYAN}elm add --stage${NC}${NC}"
    fi

    return 0
}

# ============================================================================
# UNRESOLVED COMMAND
# ============================================================================

cmd_unresolved() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls|"")
            header "Unresolved Mods"

            if [[ ! -f "$UNRESOLVED_FILE" ]]; then
                echo -e "  ${GREEN}No unresolved mods.${NC}"
                echo ""
                return
            fi

            local count=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue
                local slug comment=""
                slug=$(echo "$line" | sed 's/\s*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                comment=$(echo "$line" | grep -oP '#\s*\K.*' 2>/dev/null || true)

                echo -e "  ${YELLOW}?${NC} ${BOLD}${slug}${NC}"
                [[ -n "$comment" ]] && echo -e "    ${DIM}${comment}${NC}"
                (( count++ ))
            done < "$UNRESOLVED_FILE"

            echo ""
            if (( count == 0 )); then
                echo -e "  ${GREEN}No unresolved mods.${NC}"
            else
                echo -e "  ${BOLD}${count} unresolved mod(s)${NC}"
                echo ""
                echo -e "  ${DIM}To resolve, edit unresolved.txt and add a URL or local prefix:${NC}"
                echo -e "    ${CYAN}url:https://example.com/my-mod.jar${NC}"
                echo -e "    ${CYAN}local:my-mod${NC}"
                echo -e "  ${DIM}Then move the line to mods.txt and run: elm sync${NC}"
            fi
            echo ""
            ;;

        edit)
            if [[ ! -f "$UNRESOLVED_FILE" ]]; then
                echo -e "  ${DIM}No unresolved.txt exists yet.${NC}"
                return
            fi
            local editor="${EDITOR:-nano}"
            echo -e "  Opening ${CYAN}${UNRESOLVED_FILE}${NC} in ${editor}..."
            "$editor" "$UNRESOLVED_FILE"
            ;;

        resolve)
            local slug="${1:?Usage: elm resolve resolve <slug> <url-or-local-path>}"
            local binding="${2:?Usage: elm resolve resolve <slug> <url|local:name>}"

            if ! is_unresolved "$slug"; then
                log FAIL "${slug} is not in unresolved.txt"
                return 1
            fi

            # Build the mods.txt entry
            local entry=""
            if [[ "$binding" == local:* || "$binding" == url:* ]]; then
                entry="$binding"
            elif [[ "$binding" == https://* || "$binding" == http://* ]]; then
                entry="url:${binding}"
            else
                entry="local:${binding}"
            fi

            # Remove from unresolved.txt
            local tmp; tmp=$(mktemp)
            grep -vE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" > "$tmp" || true
            mv "$tmp" "$UNRESOLVED_FILE"

            # Add to mods.txt
            append_to_modlist "$entry" "resolved from unresolved.txt (was: ${slug})"
            log OK "${slug} → ${entry} (moved to mods.txt)"
            echo -e "  ${DIM}Run 'elm sync' to install.${NC}"
            ;;

        remove|rm)
            local slug="${1:?Usage: elm resolve remove <slug>}"
            if [[ ! -f "$UNRESOLVED_FILE" ]]; then
                log FAIL "No unresolved.txt"
                return 1
            fi
            local tmp; tmp=$(mktemp)
            grep -vE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" > "$tmp" || true
            mv "$tmp" "$UNRESOLVED_FILE"
            log OK "Removed ${slug} from unresolved.txt"
            ;;

        search|find)
            header "Search Unresolved Mods"

            if [[ ! -f "$UNRESOLVED_FILE" ]]; then
                echo -e "  ${GREEN}No unresolved mods.${NC}"
                echo ""
                return
            fi

            # If a slug was given, search just that one
            if [[ -n "${1:-}" ]]; then
                local slug="$1"
                if ! is_unresolved "$slug"; then
                    echo -e "  ${RED}'${slug}' is not in unresolved.txt${NC}"
                    return 1
                fi

                local selected
                selected=$(interactive_search "$slug" "resolve") || return 0

                if [[ -n "$selected" ]]; then
                    # Remove from unresolved, add to mods.txt
                    local tmp; tmp=$(mktemp)
                    grep -vE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" > "$tmp" || true
                    mv "$tmp" "$UNRESOLVED_FILE"
                    append_to_modlist "$selected" "resolved via search (was: ${slug})"
                    log OK "${slug} → ${selected} (moved to mods.txt)"
                    echo -e "  ${DIM}Run 'elm sync' to install.${NC}"
                fi
                return
            fi

            # No slug given — search all unresolved mods
            local count=0
            local resolved_count=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]] && continue
                local slug
                slug=$(echo "$line" | sed 's/\s*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                (( count++ ))

                separator
                echo -e "  ${YELLOW}Searching for:${NC} ${BOLD}${slug}${NC}"
                echo ""

                local selected
                selected=$(interactive_search "$slug" "resolve") || continue

                if [[ -n "$selected" ]]; then
                    local tmp; tmp=$(mktemp)
                    grep -vE "^${slug}(\s|#|$)" "$UNRESOLVED_FILE" > "$tmp" || true
                    mv "$tmp" "$UNRESOLVED_FILE"
                    append_to_modlist "$selected" "resolved via search (was: ${slug})"
                    log OK "${slug} → ${selected}"
                    (( resolved_count++ ))
                fi
                echo ""
            done < "$UNRESOLVED_FILE"

            separator
            echo ""
            if (( resolved_count > 0 )); then
                echo -e "  ${GREEN}${BOLD}Resolved ${resolved_count}/${count} mod(s).${NC}"
                echo -e "  ${DIM}Run 'elm sync' to install them.${NC}"
            else
                echo -e "  ${DIM}No mods resolved.${NC}"
            fi
            echo ""
            ;;

        clear)
            if [[ ! -f "$UNRESOLVED_FILE" ]]; then
                echo -e "  ${DIM}Nothing to clear.${NC}"
                return
            fi
            echo -e "  ${YELLOW}Clear all unresolved mods? (y/N)${NC}"
            read -r confirm
            [[ "$confirm" != [yY] ]] && return
            rm -f "$UNRESOLVED_FILE"
            log OK "Cleared unresolved.txt"
            ;;

        help|*)
            echo ""
            echo -e "  ${BOLD}elm resolve${NC} — Manage Mods Not Found on MR/CF"
            echo ""
            echo -e "  ${CYAN}elm resolve list${NC}                     Show pending mods"
            echo -e "  ${CYAN}elm resolve search [slug]${NC}            Search APIs for matches"
            echo -e "  ${CYAN}elm resolve edit${NC}                     Open unresolved.txt in editor"
            echo -e "  ${CYAN}elm resolve resolve <slug> <url>${NC}     Bind a URL and move to mods.txt"
            echo -e "  ${CYAN}elm resolve remove <slug>${NC}            Remove from unresolved list"
            echo -e "  ${CYAN}elm resolve clear${NC}                    Delete unresolved.txt"
            echo ""
            echo -e "  ${BOLD}Example:${NC}"
            echo "    elm resolve search               # search all unresolved mods"
            echo "    elm resolve search my-mod         # search one specific mod"
            echo "    elm resolve resolve my-mod url:https://example.com/my-mod-1.0.jar"
            echo "    elm sync                             # installs the resolved mods"
            echo ""
            ;;
    esac
}

# ============================================================================
# TARGETS COMMAND
# ============================================================================

cmd_targets() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls|"")
            init_targets_file
            header "Server Targets"

            local targets; targets=$(target_list)
            [[ -z "$targets" ]] && { echo -e "  ${DIM}No targets. Run: elm target add <name>${NC}"; return; }

            while IFS= read -r t; do
                local domain port ram desc pack_dir rcon_port
                domain=$(target_get "$t" "domain")
                port=$(target_get "$t" "port")
                ram=$(target_get "$t" "ram")
                desc=$(target_get "$t" "description")
                pack_dir=$(target_get "$t" "pack_dir")
                rcon_port=$(target_get "$t" "rcon_port")

                echo -e "  ${BOLD}${t}${NC}"
                [[ -n "$domain" ]]    && echo -e "    Domain:  ${CYAN}${domain}:${port:-?}${NC}"
                [[ -n "$port" ]]      && echo -e "    Port:    ${port}  RCON: ${rcon_port:-?}"
                [[ -n "$pack_dir" ]]  && echo -e "    Pack:    ${pack_dir}"
                [[ -n "$ram" ]]       && echo -e "    RAM:     ${ram}MB"
                [[ -n "$desc" ]]      && echo -e "    Desc:    ${DIM}${desc}${NC}"
                echo ""
            done <<< "$targets"
            ;;

        add|new)
            local name="${1:?Usage: elm target add <name> [key=value...]}"
            shift || true

            header "Adding Target: ${name}"

            local existing_port; existing_port=$(target_get "$name" "port")
            if [[ -n "$existing_port" ]]; then
                log WARN "Target '${name}' already exists (port: ${existing_port})"
                echo -e "  Use ${CYAN}elm target set ${name} key=value${NC} to update"
                return 1
            fi

            # Auto-assign ports
            local port; port=$(next_available_port)
            local rcon_port; rcon_port=$(next_available_rcon_port)

            target_set "$name" \
                "description=Minecraft server: ${name}" \
                "pack_dir=${PACK_DIR}" \
                "port=${port}" \
                "rcon_port=${rcon_port}" \
                "ram=${SERVER_RAM}" \
                "$@"

            log OK "Target '${name}' added"
            echo -e "  Port:      ${BOLD}${port}${NC}"
            echo -e "  RCON port: ${rcon_port}"

            local domain; domain=$(target_get "$name" "domain")
            if [[ -z "$domain" && -n "$SERVER_DOMAIN" ]]; then
                target_set "$name" "domain=${name}.${SERVER_DOMAIN}"
                domain="${name}.${SERVER_DOMAIN}"
                log OK "Auto-assigned domain: ${domain}"
            elif [[ -z "$domain" ]]; then
                echo ""
                echo -e "  ${YELLOW}Set a domain:${NC}"
                echo -e "  ${CYAN}elm target set ${name} domain=${name}.enviouslabs.com${NC}"
            fi

            echo ""
            echo -e "  Next: ${CYAN}elm deploy create --target ${name}${NC}"
            echo ""
            ;;

        set|update)
            local name="${1:?Usage: elm target set <name> key=value [key=value...]}"
            shift || true
            target_set "$name" "$@"
            log OK "Updated target: ${name}"
            ;;

        remove|rm|delete)
            local name="${1:?Usage: elm target remove <name>}"
            echo -e "  ${YELLOW}Remove target '${name}'? (y/N)${NC}"
            read -r confirm
            [[ "$confirm" != [yY] ]] && return
            target_remove "$name"
            log OK "Removed target: ${name}"
            echo -e "  ${DIM}Docker volume mc-${name}-data still exists. Remove with:${NC}"
            echo -e "  ${CYAN}docker volume rm mc-${name}-data${NC}"
            ;;

        show|info)
            local name="${1:?Usage: elm target show <name>}"
            init_targets_file
            local raw; raw=$(jq --arg n "$name" '.[$n] // empty' "$TARGETS_FILE" 2>/dev/null)
            if [[ -z "$raw" || "$raw" == "null" ]]; then
                log FAIL "Target '${name}' not found"; return 1
            fi
            header "Target: ${name}"
            echo "$raw" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
            echo ""
            ;;

        dns|srv)
            print_srv_records "${1:-}"
            ;;

        help|*)
            echo ""
            echo -e "  ${BOLD}elm target${NC} — Multi-Server Management"
            echo ""
            echo -e "  ${CYAN}elm target list${NC}                 Show all targets"
            echo -e "  ${CYAN}elm target add <n> [k=v...]${NC}  Register a new target"
            echo -e "  ${CYAN}elm target set <n> k=v ...${NC}   Update target settings"
            echo -e "  ${CYAN}elm target show <n>${NC}          Full target details"
            echo -e "  ${CYAN}elm target remove <n>${NC}        Remove a target"
            echo -e "  ${CYAN}elm target dns [n]${NC}           Show SRV record setup"
            echo ""
            echo -e "  ${BOLD}Fields:${NC} domain, port, rcon_port, pack_dir, ram, cpu, description"
            echo ""
            echo -e "  ${BOLD}Example:${NC}"
            echo "    elm target add survival domain=survival.enviouslabs.com ram=8192"
            echo "    elm target add creative domain=creative.enviouslabs.com ram=4096"
            echo "    elm target dns                  # show SRV records for Cloudflare"
            echo ""
            ;;
    esac
}

# ============================================================================
# DEPLOY COMMAND (Docker Compose + itzg/minecraft-server)
# ============================================================================

cmd_deploy() {
    local subcmd="${1:-help}"
    shift || true

    # Parse --target flag
    local target_flag=""
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target|-t) target_flag="$2"; shift 2 ;;
            *)           args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]+"${args[@]}"}"

    # Resolve target
    local target_name=""
    case "$subcmd" in
        status|st|regenerate|nginx|caddy|help) target_name="${target_flag:-}" ;;
        *)
            target_name=$(resolve_target "$target_flag")
            load_target "$target_name"
            ;;
    esac

    case "$subcmd" in
        create)
            header "Creating Server: ${target_name}"
            check_docker

            local port; port=$(target_get "$target_name" "port")
            [[ -z "$port" ]] && {
                log FAIL "Target '${target_name}' has no port. Run: elm target add ${target_name}"
                exit 1
            }

            # Auto-publish pack to cdn/ if pack exists
            if [[ -f "${PACK_DIR}/pack.toml" ]]; then
                check_packwiz
                publish_pack "$target_name"
            fi

            # Download server-side mods
            local parent; parent=$(dirname "$PACK_DIR")
            if [[ -d "${parent}/server" && -f "${PACK_DIR}/pack.toml" ]]; then
                download_server_mods "${parent}/server/mods"
            fi

            # Generate compose (picks up published pack in cdn/)
            generate_compose

            log OK "Compose generated for ${target_name}"

            # Auto-update DDNS if configured
            if [[ "${ELM_DNS_AUTO_UPDATE:-false}" == "true" && -n "${ELM_DNS_PROVIDER:-}" ]]; then
                echo ""
                _dns_force_update
            fi

            echo ""
            echo -e "  Start with:  ${CYAN}elm deploy start${NC}"
            if [[ -n "$CDN_DOMAIN" ]]; then
                echo -e "  Pack URL:    ${CYAN}https://${CDN_DOMAIN}/${target_name}/pack.toml${NC}"
            else
                echo -e "  Pack URL:    ${CYAN}http://${SERVER_VM_IP:-localhost}:8080/${target_name}/pack.toml${NC}"
            fi
            echo ""
            ;;

        push|publish)
            check_packwiz; check_pack_init
            publish_pack "$target_name"
            # Regenerate compose to update PACKWIZ_URL
            generate_compose
            # If server is running, restart to pick up new mods
            local container="el-mc-${target_name}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
                echo -e "  ${YELLOW}Restart to load new mods? (y/N)${NC}"
                read -r confirm
                [[ "$confirm" == [yY] ]] && docker_restart_target "$target_name"
            fi
            ;;

        start|up)
            docker_start_target "$target_name"
            # Auto-update DDNS if configured
            if [[ "${ELM_DNS_AUTO_UPDATE:-false}" == "true" && -n "${ELM_DNS_PROVIDER:-}" ]]; then
                _dns_force_update
            fi
            ;;

        stop|down)
            docker_stop_target "$target_name"
            ;;

        restart)
            docker_restart_target "$target_name"
            ;;

        status|st)
            docker_server_status "$target_name"
            ;;

        console|cmd|rcon)
            local command="${1:?Usage: elm deploy console <command> --target <n>}"
            docker_send_command "$target_name" "$command"
            ;;

        logs|log)
            docker_logs "$target_name" "${1:-100}"
            ;;

        backup|bk)
            docker_backup_target "$target_name"
            ;;

        remove|rm|destroy)
            docker_remove_target "$target_name"
            ;;

        kill)
            docker_kill_target "$target_name"
            ;;

        regenerate|regen)
            header "Regenerating Compose"
            generate_compose
            echo -e "  ${DIM}Apply changes with: docker compose -f $(compose_dir)/docker-compose.yml up -d${NC}"
            echo ""
            ;;

        cdn|publish)
            check_packwiz; check_pack_init
            publish_pack "$target_name"
            ;;

        mods|download)
            check_pack_init
            # Parse optional --dir flag
            local mods_dest=""
            local margs=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dir|-d) mods_dest="$2"; shift 2 ;;
                    *)        margs+=("$1"); shift ;;
                esac
            done
            # If no --dir, try target's server dir, then sibling convention
            if [[ -z "$mods_dest" && -n "$target_name" ]]; then
                local srv_pack_dir
                srv_pack_dir=$(target_get "$target_name" "pack_dir")
                if [[ -n "$srv_pack_dir" ]]; then
                    local srv_parent
                    srv_parent=$(dirname "$srv_pack_dir")
                    [[ -d "${srv_parent}/server" ]] && mods_dest="${srv_parent}/server/mods"
                fi
            fi
            download_server_mods "$mods_dest"
            ;;

        nginx)
            generate_nginx_config "$target_name"
            ;;

        caddy)
            header "Regenerating Caddyfile"
            generate_caddyfile
            echo -e "  ${DIM}Apply changes with: elm deploy regenerate${NC}"
            echo ""
            ;;

        full)
            header "Full Deployment: ${target_name}"
            echo -e "  sync → publish → compose → download server mods → start"
            echo -e "  ${YELLOW}Continue? (y/N)${NC}"
            read -r confirm < /dev/tty
            [[ "$confirm" != [yY] ]] && exit 0

            echo ""
            cmd_sync
            separator
            publish_pack "$target_name"
            separator
            local parent; parent=$(dirname "$PACK_DIR")
            [[ -d "${parent}/server" ]] && download_server_mods "${parent}/server/mods"
            separator
            generate_compose
            separator
            docker_start_target "$target_name"

            local domain; domain=$(target_get "$target_name" "domain")
            local cdn_url
            cdn_url=$(resolve_cdn_base_url "$target_name")

            header "Deployment Complete: ${target_name}"
            echo -e "  ${GREEN}${BOLD}Server is starting!${NC}"
            [[ -n "$domain" ]] && echo -e "  Game:    ${CYAN}${domain}${NC}"
            echo -e "  Pack:    ${CYAN}${cdn_url}/pack.toml${NC}"
            echo -e "  Status:  ${CYAN}elm deploy status${NC}"
            echo -e "  Logs:    ${CYAN}elm deploy logs ${target_name}${NC}"
            echo ""
            ;;

        serve)
            check_packwiz; check_pack_init
            cmd_serve
            ;;

        help|*)
            echo ""
            echo -e "  ${BOLD}elm deploy${NC} — Docker Server Management"
            echo ""
            echo -e "  All commands accept ${CYAN}--target <name>${NC} (auto-resolves if only one)"
            echo ""
            echo -e "  ${BOLD}Setup:${NC}"
            echo -e "  ${CYAN}elm deploy create${NC}          Publish pack + generate compose (auto-HTTPS)"
            echo -e "  ${CYAN}elm deploy full${NC}            Pipeline: sync → publish → compose → start"
            echo -e "  ${CYAN}elm deploy remove${NC}          Tear down deployment"
            echo ""
            echo -e "  ${BOLD}Server:${NC}"
            echo -e "  ${CYAN}elm deploy start${NC}           Start the server"
            echo -e "  ${CYAN}elm deploy stop${NC}            Stop the server"
            echo -e "  ${CYAN}elm deploy restart${NC}         Restart the server"
            echo -e "  ${CYAN}elm deploy status${NC}          Show all servers"
            echo -e "  ${CYAN}elm deploy console <cmd>${NC}   Send RCON command"
            echo -e "  ${CYAN}elm deploy logs${NC}            Tail server logs"
            echo -e "  ${CYAN}elm deploy backup${NC}          Backup server world"
            echo ""
            echo -e "  ${BOLD}Updates:${NC}"
            echo -e "  ${CYAN}elm deploy push${NC}            Re-publish pack after changes"
            echo -e "  ${CYAN}elm deploy mods${NC}            Download mod JARs into server/mods/"
            echo -e "  ${CYAN}elm deploy regen${NC}           Rebuild docker-compose.yml + Caddyfile"
            echo -e "  ${CYAN}elm deploy serve${NC}           Local HTTP dev server"
            echo ""
            echo -e "  ${BOLD}Quick start:${NC}"
            echo "    elm target add survival domain=survival.enviouslabs.com ram=8192"
            echo "    elm config edit   # set CDN_DOMAIN=pack.enviouslabs.com for HTTPS"
            echo "    elm deploy create --target survival"
            echo "    elm deploy start"
            echo ""
            echo -e "  ${DIM}Caddy handles HTTPS automatically when CDN_DOMAIN is set.${NC}"
            echo -e "  ${DIM}Without CDN_DOMAIN, pack files are served on http://server-ip:8080${NC}"
            echo ""
            ;;
    esac
}

# ============================================================================
# CONFIG COMMAND
# ============================================================================

cmd_config() {
    local subcmd="${1:-show}"

    case "$subcmd" in
        show)
            header "Active Configuration"
            echo -e "  ${BOLD}Config files (priority order):${NC}"
            if [[ -f "$LOCAL_CONF" ]]; then
                echo -e "    ${GREEN}1.${NC} ${LOCAL_CONF} ${GREEN}(active)${NC}"
            else
                echo -e "    ${DIM}1. ./elm.conf (not found)${NC}"
            fi
            if [[ -f "$GLOBAL_CONF" ]]; then
                echo -e "    ${GREEN}2.${NC} ${GLOBAL_CONF} ${GREEN}(active)${NC}"
            else
                echo -e "    ${DIM}2. ${GLOBAL_CONF} (not found)${NC}"
            fi

            echo ""
            echo -e "  ${BOLD}Minecraft:${NC}"
            echo -e "    Version:   ${MC_VERSION}"
            echo -e "    Loader:    ${LOADER}"
            echo -e "    Source:    ${PREFER_SOURCE} first"

            echo ""
            echo -e "  ${BOLD}Docker:${NC}"
            if command -v docker &>/dev/null; then
                echo -e "    Docker:    ${GREEN}installed${NC}"
                local compose_file="${DOCKER_COMPOSE_DIR}/docker-compose.yml"
                if [[ -f "$compose_file" ]]; then
                    local svc_count
                    svc_count=$(grep -c "^  mc-" "$compose_file" 2>/dev/null || echo 0)
                    echo -e "    Compose:   ${compose_file} (${svc_count} server(s))"
                else
                    echo -e "    Compose:   ${DIM}not generated yet${NC}"
                fi
                echo -e "    Image:     ${SERVER_IMAGE}"
            else
                echo -e "    ${RED}Docker not installed${NC}"
            fi

            local tcount
            tcount=$(jq 'length' "$TARGETS_FILE" 2>/dev/null || echo 0)
            echo -e "    Targets:   ${tcount} registered"
            echo -e "    VM IP:     ${SERVER_VM_IP:-${YELLOW}not set${NC}}"

            echo ""
            echo -e "  ${BOLD}Server Defaults:${NC}"
            echo -e "    RAM:  ${SERVER_RAM}MB  CPU: ${SERVER_CPU}%  Disk: ${SERVER_DISK}MB"

            if [[ -n "$PACK_HOST_URL" ]]; then
                echo ""
                echo -e "  ${BOLD}Pack Hosting:${NC}"
                echo -e "    URL: ${PACK_HOST_URL}"
                echo -e "    Dir: ${PACK_HOST_DIR:-not set}"
            fi

            echo ""
            echo -e "  ${BOLD}CDN (Caddy — auto-HTTPS):${NC}"
            echo -e "    Domain:    ${CDN_DOMAIN:-${YELLOW}not set (http on :8080)${NC}}"
            if [[ -n "$CDN_DOMAIN" ]]; then
                echo -e "    HTTPS:     ${GREEN}automatic via Let's Encrypt${NC}"
            fi
            echo ""
            ;;
        edit)
            local conf="$GLOBAL_CONF"
            [[ -f "$LOCAL_CONF" ]] && conf="$LOCAL_CONF"

            local editor="${EDITOR:-nano}"
            echo -e "Opening ${CYAN}${conf}${NC} in ${editor}..."
            "$editor" "$conf"
            ;;
        path)
            echo -e "  Global: ${CYAN}${GLOBAL_CONF}${NC}"
            echo -e "  Local:  ${CYAN}${LOCAL_CONF}${NC}"
            ;;
        alias)
            shift 2>/dev/null || true
            cmd_aliases "$@"
            ;;
        *)
            echo -e "${RED}Usage: elm config [show|edit|path|alias]${NC}"
            ;;
    esac
}

# ============================================================================
# API KEY MANAGEMENT
# ============================================================================

_key_set() {
    local varname="$1" value="$2"
    mkdir -p "$(dirname "$KEYS_FILE")"
    touch "$KEYS_FILE"
    chmod 600 "$KEYS_FILE"
    # Remove existing line for this var, then append
    grep -v "^${varname}=" "$KEYS_FILE" > "${KEYS_FILE}.tmp" 2>/dev/null || true
    echo "${varname}=\"${value}\"" >> "${KEYS_FILE}.tmp"
    mv "${KEYS_FILE}.tmp" "$KEYS_FILE"
    chmod 600 "$KEYS_FILE"
    # Export to current session
    export "$varname"="$value"
}

_key_remove() {
    local varname="$1"
    if [[ -f "$KEYS_FILE" ]]; then
        grep -v "^${varname}=" "$KEYS_FILE" > "${KEYS_FILE}.tmp" 2>/dev/null || true
        mv "${KEYS_FILE}.tmp" "$KEYS_FILE"
        chmod 600 "$KEYS_FILE"
        unset "$varname" 2>/dev/null || true
    fi
}

_key_show() {
    local varname="$1" label="${2:-$1}"
    local val="${!varname:-}"
    if [[ -n "$val" ]]; then
        local len=${#val}
        if (( len > 8 )); then
            local masked="${val:0:4}****${val: -4}"
        else
            local masked="****"
        fi
        echo -e "  ${GREEN}✓${NC} ${label}: ${masked}"
    else
        echo -e "  ${DIM}○ ${label}: not set${NC}"
    fi
}

cmd_key() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        curseforge|cf)
            local key="${1:?Usage: elm key curseforge <API_KEY>}"
            _key_set "CURSEFORGE_API_KEY" "$key"
            echo -e "  ${GREEN}✓${NC} CurseForge API key saved"
            ;;
        noip)
            local user="${1:?Usage: elm key noip <username> <password>}"
            local pass="${2:?Usage: elm key noip <username> <password>}"
            _key_set "NOIP_USERNAME" "$user"
            _key_set "NOIP_PASSWORD" "$pass"
            echo -e "  ${GREEN}✓${NC} No-IP credentials saved"
            ;;
        duckdns)
            local token="${1:?Usage: elm key duckdns <TOKEN>}"
            _key_set "DUCKDNS_TOKEN" "$token"
            echo -e "  ${GREEN}✓${NC} DuckDNS token saved"
            ;;
        dynu)
            local user="${1:?Usage: elm key dynu <username> <password>}"
            local pass="${2:?Usage: elm key dynu <username> <password>}"
            _key_set "DYNU_USERNAME" "$user"
            _key_set "DYNU_PASSWORD" "$pass"
            echo -e "  ${GREEN}✓${NC} Dynu credentials saved"
            ;;
        cloudflare)
            local token="${1:?Usage: elm key cloudflare <API_TOKEN>}"
            _key_set "CLOUDFLARE_API_TOKEN" "$token"
            echo -e "  ${GREEN}✓${NC} Cloudflare API token saved"
            ;;
        list|ls)
            header "Configured API Keys"
            echo -e "  ${DIM}Keys stored in: ${KEYS_FILE}${NC}"
            echo ""
            _key_show "CURSEFORGE_API_KEY" "CurseForge"
            _key_show "NOIP_USERNAME" "No-IP (user)"
            _key_show "NOIP_PASSWORD" "No-IP (pass)"
            _key_show "DUCKDNS_TOKEN" "DuckDNS"
            _key_show "DYNU_USERNAME" "Dynu (user)"
            _key_show "DYNU_PASSWORD" "Dynu (pass)"
            _key_show "CLOUDFLARE_API_TOKEN" "Cloudflare"
            echo ""
            ;;
        rm|remove)
            local provider="${1:?Usage: elm key rm <provider>}"
            case "$provider" in
                curseforge|cf)
                    _key_remove "CURSEFORGE_API_KEY"
                    echo -e "  ${GREEN}✓${NC} CurseForge key removed"
                    ;;
                noip)
                    _key_remove "NOIP_USERNAME"
                    _key_remove "NOIP_PASSWORD"
                    echo -e "  ${GREEN}✓${NC} No-IP credentials removed"
                    ;;
                duckdns)
                    _key_remove "DUCKDNS_TOKEN"
                    echo -e "  ${GREEN}✓${NC} DuckDNS token removed"
                    ;;
                dynu)
                    _key_remove "DYNU_USERNAME"
                    _key_remove "DYNU_PASSWORD"
                    echo -e "  ${GREEN}✓${NC} Dynu credentials removed"
                    ;;
                cloudflare)
                    _key_remove "CLOUDFLARE_API_TOKEN"
                    echo -e "  ${GREEN}✓${NC} Cloudflare token removed"
                    ;;
                *)
                    echo -e "${RED}Unknown provider: ${provider}${NC}"
                    echo "  Providers: curseforge, noip, duckdns, dynu, cloudflare"
                    ;;
            esac
            ;;
        *)
            echo -e "${BOLD}Usage:${NC} elm key <provider> <value>"
            echo ""
            echo "  elm key curseforge <API_KEY>       Set CurseForge API key"
            echo "  elm key noip <user> <pass>         Set No-IP credentials"
            echo "  elm key duckdns <TOKEN>             Set DuckDNS token"
            echo "  elm key dynu <user> <pass>         Set Dynu credentials"
            echo "  elm key cloudflare <API_TOKEN>     Set Cloudflare API token"
            echo ""
            echo "  elm key list                       Show configured keys"
            echo "  elm key rm <provider>              Remove a key"
            echo ""
            echo -e "  ${DIM}Keys are stored in ${KEYS_FILE} (chmod 600)${NC}"
            ;;
    esac
}

# ============================================================================
# DDNS PROVIDER SUPPORT
# ============================================================================

_dns_set() {
    local varname="$1" value="$2"
    mkdir -p "$(dirname "$DNS_CONF")"
    touch "$DNS_CONF"
    grep -v "^${varname}=" "$DNS_CONF" > "${DNS_CONF}.tmp" 2>/dev/null || true
    echo "${varname}=\"${value}\"" >> "${DNS_CONF}.tmp"
    mv "${DNS_CONF}.tmp" "$DNS_CONF"
    export "$varname"="$value"
}

_ddns_update_noip() {
    local hostname="$1" ip="$2"
    local result
    result=$(curl -s -u "${NOIP_USERNAME}:${NOIP_PASSWORD}" \
        "http://dynupdate.no-ip.com/nic/update?hostname=${hostname}&myip=${ip}" 2>&1)
    echo "$result"
    [[ "$result" == *"good"* || "$result" == *"nochg"* ]]
}

_ddns_update_duckdns() {
    local domain="$1" ip="$2"
    local result
    result=$(curl -s "https://www.duckdns.org/update?domains=${domain}&token=${DUCKDNS_TOKEN}&ip=${ip}" 2>&1)
    echo "$result"
    [[ "$result" == "OK" ]]
}

_ddns_update_dynu() {
    local hostname="$1" ip="$2"
    local result
    result=$(curl -s -u "${DYNU_USERNAME}:${DYNU_PASSWORD}" \
        "https://api.dynu.com/nic/update?hostname=${hostname}&myip=${ip}" 2>&1)
    echo "$result"
    [[ "$result" == *"good"* || "$result" == *"nochg"* ]]
}

_ddns_update_cloudflare() {
    local hostname="$1" ip="$2"
    local zone_id="${ELM_CF_ZONE_ID:-}"
    local record_id="${ELM_CF_RECORD_ID:-}"

    if [[ -z "$zone_id" || -z "$record_id" ]]; then
        echo -e "  ${RED}Cloudflare requires zone_id and record_id.${NC}"
        echo -e "  Run ${CYAN}elm dns set cloudflare${NC} to configure."
        return 1
    fi

    local result
    result=$(curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${hostname}\",\"content\":\"${ip}\",\"ttl\":120}" 2>&1)
    echo "$result" | jq -r '.success // "false"' 2>/dev/null
    echo "$result" | jq -r '.success' 2>/dev/null | grep -q 'true'
}

_dns_detect_ip() {
    # Prefer SERVER_VM_IP if set, otherwise auto-detect public IP
    if [[ -n "${SERVER_VM_IP:-}" ]]; then
        echo "$SERVER_VM_IP"
    else
        curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null || echo ""
    fi
}

_dns_force_update() {
    local provider="${ELM_DNS_PROVIDER:-}"
    local hostname="${ELM_DNS_HOSTNAME:-}"

    if [[ -z "$provider" ]]; then
        echo -e "  ${RED}No DDNS provider configured.${NC}"
        echo -e "  Run ${CYAN}elm dns set <provider>${NC} first."
        return 1
    fi

    if [[ -z "$hostname" ]]; then
        echo -e "  ${RED}No hostname configured.${NC}"
        echo -e "  Run ${CYAN}elm dns set ${provider}${NC} first."
        return 1
    fi

    local ip
    ip=$(_dns_detect_ip)
    if [[ -z "$ip" ]]; then
        echo -e "  ${RED}Could not detect public IP.${NC}"
        return 1
    fi

    echo -e "  Updating ${CYAN}${hostname}${NC} → ${BOLD}${ip}${NC} via ${provider}..."

    case "$provider" in
        noip)
            if [[ -z "${NOIP_USERNAME:-}" || -z "${NOIP_PASSWORD:-}" ]]; then
                echo -e "  ${RED}No-IP credentials not set. Run: elm key noip <user> <pass>${NC}"
                return 1
            fi
            if _ddns_update_noip "$hostname" "$ip"; then
                echo -e "  ${GREEN}✓${NC} DNS updated successfully"
            else
                echo -e "  ${RED}✗ DNS update failed${NC}"
                return 1
            fi
            ;;
        duckdns)
            if [[ -z "${DUCKDNS_TOKEN:-}" ]]; then
                echo -e "  ${RED}DuckDNS token not set. Run: elm key duckdns <TOKEN>${NC}"
                return 1
            fi
            if _ddns_update_duckdns "$hostname" "$ip"; then
                echo -e "  ${GREEN}✓${NC} DNS updated successfully"
            else
                echo -e "  ${RED}✗ DNS update failed${NC}"
                return 1
            fi
            ;;
        dynu)
            if [[ -z "${DYNU_USERNAME:-}" || -z "${DYNU_PASSWORD:-}" ]]; then
                echo -e "  ${RED}Dynu credentials not set. Run: elm key dynu <user> <pass>${NC}"
                return 1
            fi
            if _ddns_update_dynu "$hostname" "$ip"; then
                echo -e "  ${GREEN}✓${NC} DNS updated successfully"
            else
                echo -e "  ${RED}✗ DNS update failed${NC}"
                return 1
            fi
            ;;
        cloudflare)
            if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
                echo -e "  ${RED}Cloudflare token not set. Run: elm key cloudflare <TOKEN>${NC}"
                return 1
            fi
            if _ddns_update_cloudflare "$hostname" "$ip"; then
                echo -e "  ${GREEN}✓${NC} DNS updated successfully"
            else
                echo -e "  ${RED}✗ DNS update failed${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "  ${RED}Unknown provider: ${provider}${NC}"
            return 1
            ;;
    esac
}

cmd_dns() {
    local subcmd="${1:-status}"
    shift || true

    case "$subcmd" in
        set)
            local provider="${1:?Usage: elm dns set <noip|duckdns|dynu|cloudflare>}"
            shift || true

            case "$provider" in
                noip|duckdns|dynu|cloudflare)
                    _dns_set "ELM_DNS_PROVIDER" "$provider"
                    echo -e "  ${GREEN}✓${NC} DDNS provider set to: ${BOLD}${provider}${NC}"

                    local hostname
                    if [[ -n "${1:-}" ]]; then
                        hostname="$1"
                    else
                        echo -n "  Hostname to update (e.g. myserver.ddns.net): "
                        read -r hostname
                    fi
                    if [[ -n "$hostname" ]]; then
                        _dns_set "ELM_DNS_HOSTNAME" "$hostname"
                        echo -e "  ${GREEN}✓${NC} Hostname set to: ${BOLD}${hostname}${NC}"
                    fi

                    # Cloudflare needs extra config
                    if [[ "$provider" == "cloudflare" ]]; then
                        if [[ -n "${2:-}" ]]; then
                            _dns_set "ELM_CF_ZONE_ID" "$2"
                            _dns_set "ELM_CF_RECORD_ID" "${3:-}"
                        else
                            echo -n "  Cloudflare Zone ID: "
                            read -r zone_id
                            echo -n "  Cloudflare DNS Record ID: "
                            read -r record_id
                            [[ -n "$zone_id" ]] && _dns_set "ELM_CF_ZONE_ID" "$zone_id"
                            [[ -n "$record_id" ]] && _dns_set "ELM_CF_RECORD_ID" "$record_id"
                        fi
                    fi

                    echo ""
                    echo -e "  ${DIM}Make sure your API key is set: elm key ${provider} ...${NC}"
                    echo -e "  ${DIM}Enable auto-update on deploy:  elm dns auto on${NC}"
                    ;;
                *)
                    echo -e "${RED}Unknown provider: ${provider}${NC}"
                    echo "  Supported: noip, duckdns, dynu, cloudflare"
                    ;;
            esac
            ;;
        update)
            header "DDNS Update"
            _dns_force_update
            ;;
        status)
            header "DNS Configuration"
            echo -e "  Provider:    ${ELM_DNS_PROVIDER:-${DIM}not set${NC}}"
            echo -e "  Hostname:    ${ELM_DNS_HOSTNAME:-${DIM}not set${NC}}"
            echo -e "  Auto-update: ${ELM_DNS_AUTO_UPDATE:-false}"
            echo -e "  Server IP:   ${SERVER_VM_IP:-${DIM}auto-detect${NC}}"
            if [[ "${ELM_DNS_PROVIDER:-}" == "cloudflare" ]]; then
                echo -e "  CF Zone ID:  ${ELM_CF_ZONE_ID:-${DIM}not set${NC}}"
                echo -e "  CF Record:   ${ELM_CF_RECORD_ID:-${DIM}not set${NC}}"
            fi
            echo ""
            echo -e "  ${DIM}Config: ${DNS_CONF}${NC}"
            echo ""
            ;;
        auto)
            local toggle="${1:-}"
            case "$toggle" in
                on)
                    _dns_set "ELM_DNS_AUTO_UPDATE" "true"
                    echo -e "  ${GREEN}✓${NC} Auto DDNS update enabled (triggers on deploy create/start)"
                    ;;
                off)
                    _dns_set "ELM_DNS_AUTO_UPDATE" "false"
                    echo -e "  ${GREEN}✓${NC} Auto DDNS update disabled"
                    ;;
                *)
                    echo -e "  Auto-update: ${ELM_DNS_AUTO_UPDATE:-false}"
                    echo -e "  ${DIM}Usage: elm dns auto [on|off]${NC}"
                    ;;
            esac
            ;;
        *)
            echo -e "${BOLD}Usage:${NC} elm dns <set|update|status|auto>"
            echo ""
            echo "  elm dns set <provider> [hostname]   Configure DDNS provider"
            echo "  elm dns update                      Force DNS update now"
            echo "  elm dns status                      Show DNS configuration"
            echo "  elm dns auto [on|off]               Toggle auto-update on deploy"
            echo ""
            echo "  Providers: noip, duckdns, dynu, cloudflare"
            ;;
    esac
}

# ============================================================================
# SELF-UPDATE (GitHub)
# ============================================================================
# Downloads the latest version of ELM files from a GitHub repo.
# Requires ELM_GITHUB_REPO to be set (e.g. "yourusername/envious-mc").
# Uses raw.githubusercontent.com to fetch files from ELM_GITHUB_BRANCH.
# Backs up existing files before overwriting.

cmd_self_update() {
    # Handle --check flag (replaces old update-status command)
    if [[ "${1:-}" == "--check" ]]; then
        cmd_self_update_status
        return
    fi

    header "Self-Update"

    # Validate config
    if [[ -z "$ELM_GITHUB_REPO" ]]; then
        echo -e "  ${RED}ELM_GITHUB_REPO not set.${NC}"
        echo ""
        echo -e "  Set it in your config (${CYAN}elm config edit${NC}):"
        echo -e "    ${CYAN}ELM_GITHUB_REPO=\"yourusername/envious-mc\"${NC}"
        echo ""
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        echo -e "  ${RED}curl is required for self-update.${NC}"
        exit 1
    fi

    # Sanitize: strip trailing/leading slashes and whitespace
    local repo_clean="${ELM_GITHUB_REPO#/}"; repo_clean="${repo_clean%/}"; repo_clean="$(echo "$repo_clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local branch_clean="${ELM_GITHUB_BRANCH#/}"; branch_clean="${branch_clean%/}"; branch_clean="$(echo "$branch_clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local path_clean=""
    if [[ -n "$ELM_GITHUB_PATH" ]]; then
        path_clean="${ELM_GITHUB_PATH#/}"; path_clean="${path_clean%/}"; path_clean="$(echo "$path_clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi

    # Build base URL: repo/branch[/path]
    local raw_base="https://raw.githubusercontent.com/${repo_clean}/${branch_clean}"
    [[ -n "$path_clean" ]] && raw_base="${raw_base}/${path_clean}"
    local install_dir="${HOME}/.local/bin"
    local config_dir="${HOME}/.config/elm"
    local backup_dir="${config_dir}/backups/$(date +%Y%m%d_%H%M%S)"

    # --- Check connectivity & repo existence ---
    log INFO "Checking ${repo_clean} (branch: ${branch_clean})..."

    local http_code
    http_code=$(curl -sL -o /dev/null -w "%{http_code}" "${raw_base}/elm.sh" 2>/dev/null || echo "000")

    if [[ "$http_code" == "404" ]]; then
        echo -e "  ${RED}Repository or branch not found.${NC}"
        echo -e "  Checked: ${DIM}${raw_base}/elm.sh${NC}"
        echo ""
        echo -e "  Verify:"
        echo -e "    • ELM_GITHUB_REPO is correct: ${CYAN}${ELM_GITHUB_REPO}${NC}"
        echo -e "    • ELM_GITHUB_BRANCH is correct: ${CYAN}${ELM_GITHUB_BRANCH}${NC}"
        echo -e "    • The repo is accessible (public, or use a token)"
        exit 1
    elif [[ "$http_code" == "000" ]]; then
        echo -e "  ${RED}Network error — cannot reach GitHub.${NC}"
        exit 1
    elif [[ "$http_code" != "200" ]]; then
        echo -e "  ${RED}Unexpected HTTP ${http_code} from GitHub.${NC}"
        exit 1
    fi

    # --- Fetch latest commit hash for display ---
    local remote_sha=""
    remote_sha=$(curl -sL "https://api.github.com/repos/${repo_clean}/commits/${branch_clean}" 2>/dev/null \
        | grep -oP '"sha"\s*:\s*"\K[a-f0-9]{40}' | head -1 || true)

    if [[ -n "$remote_sha" ]]; then
        local short_sha="${remote_sha:0:8}"
        echo -e "  Latest commit: ${CYAN}${short_sha}${NC}"
    fi

    # --- Compare with local version if possible ---
    local local_sha_file="${config_dir}/.last_update_sha"
    if [[ -f "$local_sha_file" && -n "$remote_sha" ]]; then
        local local_sha
        local_sha=$(cat "$local_sha_file" 2>/dev/null || echo "")
        if [[ "$local_sha" == "$remote_sha" ]]; then
            echo -e "  ${GREEN}Already up to date.${NC}"
            echo ""
            return 0
        fi
        echo -e "  Local version: ${DIM}${local_sha:0:8}${NC}"
    fi

    # --- Download files to temp dir ---
    local tmp_dir; tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    local files_to_update=($ELM_UPDATE_FILES)
    local downloaded=0
    local skipped=0

    echo ""
    log INFO "Downloading ${#files_to_update[@]} file(s)..."

    for fname in "${files_to_update[@]}"; do
        local url="${raw_base}/${fname}"
        local tmp_file="${tmp_dir}/${fname}"

        local dl_code
        dl_code=$(curl -sL -o "$tmp_file" -w "%{http_code}" "$url" 2>/dev/null || echo "000")

        if [[ "$dl_code" == "200" && -s "$tmp_file" ]]; then
            log OK "${fname}"
            (( downloaded++ ))
        elif [[ "$dl_code" == "404" ]]; then
            log SKIP "${fname} (not in repo)"
            rm -f "$tmp_file"
            (( skipped++ ))
        else
            log WARN "${fname} (HTTP ${dl_code})"
            rm -f "$tmp_file"
            (( skipped++ ))
        fi
    done

    if (( downloaded == 0 )); then
        echo -e "  ${RED}No files downloaded — aborting.${NC}"
        exit 1
    fi

    # --- Create backups ---
    separator
    log INFO "Backing up current files → ${backup_dir}/"
    mkdir -p "$backup_dir"

    # Backup elm binary
    if [[ -f "${install_dir}/elm" ]]; then
        cp "${install_dir}/elm" "${backup_dir}/elm.sh.bak"
        log OK "Backed up elm binary"
    fi

    # Backup install.sh if it exists somewhere known
    local script_dir=""
    # Try to find where the original install was (check if elm is a symlink or has a comment)
    if [[ -f "${config_dir}/install.sh" ]]; then
        cp "${config_dir}/install.sh" "${backup_dir}/install.sh.bak"
    fi

    # --- Apply updates ---
    separator
    log INFO "Applying updates..."

    # 1. Update the elm binary (elm.sh)
    #    If elm is a symlink, update the file it points at (the source repo copy)
    #    Otherwise, overwrite the binary directly
    if [[ -f "${tmp_dir}/elm.sh" ]]; then
        local elm_target="${install_dir}/elm"
        if [[ -L "$elm_target" ]]; then
            local link_dest
            link_dest=$(readlink -f "$elm_target")
            cp "${tmp_dir}/elm.sh" "$link_dest"
            chmod +x "$link_dest"
            log OK "Updated source → ${link_dest} (symlinked from elm)"
        else
            cp "${tmp_dir}/elm.sh" "$elm_target"
            chmod +x "$elm_target"
            log OK "Updated elm → ${elm_target}"
        fi
    fi

    # 2. Update install.sh (store in config dir for future use)
    if [[ -f "${tmp_dir}/install.sh" ]]; then
        cp "${tmp_dir}/install.sh" "${config_dir}/install.sh"
        chmod +x "${config_dir}/install.sh"
        log OK "Updated install.sh → ${config_dir}/install.sh"
    fi

    # 3. Update default config template (NOT the user's active config)
    if [[ -f "${tmp_dir}/elm.conf" ]]; then
        cp "${tmp_dir}/elm.conf" "${config_dir}/elm.conf.default"
        log OK "Updated config template → elm.conf.default"
        echo -e "    ${DIM}Your active config was NOT overwritten.${NC}"
        echo -e "    ${DIM}Compare with: diff ${config_dir}/elm.conf ${config_dir}/elm.conf.default${NC}"
    fi

    # 4. Update mods.txt template (only if no local mods.txt exists in the pack dir)
    if [[ -f "${tmp_dir}/mods.txt" ]]; then
        if [[ ! -f "${PACK_DIR}/mods.txt" ]]; then
            cp "${tmp_dir}/mods.txt" "${PACK_DIR}/mods.txt"
            log OK "Installed mods.txt → ${PACK_DIR}/mods.txt"
        else
            cp "${tmp_dir}/mods.txt" "${config_dir}/mods.txt.default"
            log OK "Updated mods.txt template → mods.txt.default"
            echo -e "    ${DIM}Your mods.txt was NOT overwritten.${NC}"
        fi
    fi

    # --- Save commit hash ---
    if [[ -n "$remote_sha" ]]; then
        echo "$remote_sha" > "$local_sha_file"
    fi

    # --- Cleanup ---
    rm -rf "$tmp_dir"
    trap - EXIT

    # --- Summary ---
    echo ""
    separator
    echo ""
    echo -e "  ${GREEN}${BOLD}Update complete!${NC}"
    echo -e "  Updated:  ${GREEN}${downloaded}${NC} file(s)"
    (( skipped > 0 )) && echo -e "  Skipped:  ${YELLOW}${skipped}${NC} file(s)"
    echo -e "  Backups:  ${CYAN}${backup_dir}${NC}"
    if [[ -n "$remote_sha" ]]; then
        echo -e "  Version:  ${CYAN}${remote_sha:0:8}${NC}"
    fi
    echo ""
    echo -e "  ${DIM}If something broke, restore with:${NC}"
    echo -e "  ${CYAN}cp ${backup_dir}/elm.sh.bak ${install_dir}/elm${NC}"
    echo ""
}

cmd_self_update_status() {
    header "Update Status"

    if [[ -z "$ELM_GITHUB_REPO" ]]; then
        echo -e "  ${YELLOW}ELM_GITHUB_REPO not configured.${NC}"
        echo -e "  Set it in your config: ${CYAN}elm config edit${NC}"
        echo ""
        return
    fi

    local config_dir="${HOME}/.config/elm"
    local local_sha_file="${config_dir}/.last_update_sha"

    # Sanitize repo/branch
    local repo_clean="${ELM_GITHUB_REPO#/}"; repo_clean="${repo_clean%/}"; repo_clean="$(echo "$repo_clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local branch_clean="${ELM_GITHUB_BRANCH#/}"; branch_clean="${branch_clean%/}"; branch_clean="$(echo "$branch_clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    echo -e "  Repo:    ${CYAN}${repo_clean}${NC}"
    echo -e "  Branch:  ${branch_clean}"

    if [[ -f "$local_sha_file" ]]; then
        local local_sha; local_sha=$(cat "$local_sha_file" 2>/dev/null || echo "unknown")
        echo -e "  Local:   ${CYAN}${local_sha:0:8}${NC}"
    else
        echo -e "  Local:   ${DIM}unknown (never updated via self-update)${NC}"
    fi

    # Check remote
    local remote_sha=""
    remote_sha=$(curl -sL --max-time 5 "https://api.github.com/repos/${repo_clean}/commits/${branch_clean}" 2>/dev/null \
        | grep -oP '"sha"\s*:\s*"\K[a-f0-9]{40}' | head -1 || true)

    if [[ -n "$remote_sha" ]]; then
        echo -e "  Remote:  ${CYAN}${remote_sha:0:8}${NC}"

        if [[ -f "$local_sha_file" ]]; then
            local local_sha; local_sha=$(cat "$local_sha_file" 2>/dev/null || echo "")
            if [[ "$local_sha" == "$remote_sha" ]]; then
                echo -e "  Status:  ${GREEN}Up to date${NC}"
            else
                echo -e "  Status:  ${YELLOW}Update available${NC}"
                echo ""
                echo -e "  Run: ${CYAN}elm update${NC}"
            fi
        else
            echo -e "  Status:  ${YELLOW}Unknown (run elm update to sync)${NC}"
        fi
    else
        echo -e "  Remote:  ${DIM}could not check (network/rate limit)${NC}"
    fi
    echo ""
}

# ============================================================================
# HELP
# ============================================================================

cmd_help() {
    cat << 'HELP'

  ELM v1.0.0 — EnviousLabs Minecraft CLI

  CORE PACK:
    elm init                       Initialize pack.toml + mods.txt
    elm add [slug...]              Add mods (no args = interactive)
    elm add file:/path/to.jar      Add JAR as self-hosted mod
    elm add --stage                Batch-match JARs in staging/
    elm add --import <zip>         Import CurseForge modpack .zip
    elm rm <slug>                  Remove a mod
    elm ls [--side s] [--deps]     List mods (--deps for dependencies)
    elm sync                       Install all mods from mods.txt
    elm up                         Update non-pinned mods
    elm search <query>             Search Modrinth/CurseForge
    elm search --open <slug>       Open mod page in browser
    elm pin/unpin <slug>           Pin/unpin mod version
    elm export [mr|cf|md]          Export pack (.mrpack, .zip, or markdown)

  SERVER (all via deploy, use --target <name>):
    elm deploy create              Publish + generate compose (auto-HTTPS)
    elm deploy full                Pipeline: sync → publish → compose → start
    elm deploy start/stop/restart  Control server
    elm deploy status              Show all servers
    elm deploy console <cmd>       Send RCON command
    elm deploy logs                Tail server logs
    elm deploy backup              Backup server world
    elm deploy push                Re-publish pack after changes
    elm deploy mods                Download mod JARs into server/mods/
    elm deploy regen               Rebuild docker-compose.yml + Caddyfile
    elm deploy serve               Local HTTP dev server
    elm deploy remove              Tear down deployment
    elm target [list|add|set|show|rm|dns]   Manage server targets

  DIAGNOSTICS:
    elm check [--diff] [--refresh] Full audit (status + doctor + verify)
    elm net                        Network check: can clients reach pack?

  CONFIG & KEYS:
    elm config [show|edit|path]    Manage configuration
    elm config alias               Manage mod aliases
    elm key <provider> <value>     Set API key (copy-paste friendly)
    elm key list                   Show configured keys (masked)
    elm key rm <provider>          Remove a key

  DNS (DDNS auto-update on deploy):
    elm dns set <provider> [host]  Configure DDNS (noip/duckdns/dynu/cloudflare)
    elm dns update                 Force DNS update now
    elm dns status                 Show DNS configuration
    elm dns auto [on|off]          Toggle auto-update on deploy

  SELF-UPDATE:
    elm update                     Download latest from GitHub
    elm update --check             Check if updates are available

  MAINTENANCE:
    elm resolve                    Re-attempt unresolved mods (auto)
    elm resolve -i                 Re-attempt interactively
    elm resolve list/search/edit   Manage unresolved mods
    elm organize [dir]             Sort flat dir into pack/ server/ cdn/
    elm migrate <mc|loader> [ver]  Migrate version
    elm nuke                       Eagle 500KG — wipe everything

  MODS.TXT FORMAT:
    tinkers-construct              Auto-detect (Modrinth → CurseForge)
    mr:ars-nouveau                 Modrinth only
    cf:journeymap                  CurseForge only
    url:https://dl.com/mod.jar     Direct download URL
    local:my-custom-mod            Local JAR from LOCAL_MODS_DIR
    !jei                           Pinned (skip in elm up)

  EXAMPLES:
    elm add tinkers-construct mekanism ae2
    elm add cf:journeymap mr:jade
    elm add file:~/Downloads/mod.jar --slug name
    elm ls --side server
    elm export mr server
    elm key curseforge YOUR_API_KEY
    elm key noip myuser mypass
    elm dns set noip myserver.ddns.net
    elm dns auto on
    elm target add survival domain=survival.enviouslabs.com ram=8192
    elm deploy create --target survival
    elm deploy start
    elm deploy status
    elm check --diff
    elm nuke

HELP
}

# ============================================================================
# NUKE — Wipe everything and start fresh
# ============================================================================

cmd_nuke() {
    local parent
    parent=$(dirname "$PACK_DIR")

    # ── Inventory what exists ────────────────────────────────────────
    local -a targets=()
    local -a target_labels=()

    # Pack directory
    if [[ -d "$PACK_DIR" ]]; then
        targets+=("$PACK_DIR")
        local mod_count=0
        [[ -d "${PACK_DIR}/mods" ]] && mod_count=$(find "${PACK_DIR}/mods" -name "*.pw.toml" 2>/dev/null | wc -l)
        target_labels+=("pack/          pack.toml, index.toml, ${mod_count} mod .pw.tomls, mods.txt, unresolved.txt")
    fi

    # Server directory
    if [[ -d "${parent}/server" ]]; then
        targets+=("${parent}/server")
        target_labels+=("server/        server.properties, mods/, docker volumes, world data")
    fi

    # CDN directory
    if [[ -d "${parent}/cdn" ]]; then
        targets+=("${parent}/cdn")
        target_labels+=("cdn/           Caddyfile, published packs, self-hosted JARs")
    fi

    # Staging directory
    if [[ -d "${parent}/staging" ]]; then
        targets+=("${parent}/staging")
        target_labels+=("staging/       Staged JAR files awaiting import")
    fi

    # Docker compose
    local compose_file="${parent}/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        targets+=("$compose_file")
        target_labels+=("docker-compose.yml")
    fi

    # Caddyfile at root
    local caddyfile="${parent}/Caddyfile"
    if [[ -f "$caddyfile" ]]; then
        targets+=("$caddyfile")
        target_labels+=("Caddyfile")
    fi

    # Config
    if [[ -f "${parent}/elm.conf" ]]; then
        targets+=("${parent}/elm.conf")
        target_labels+=("elm.conf")
    fi

    # Logs
    if [[ -d "$LOG_DIR" ]]; then
        targets+=("$LOG_DIR")
        target_labels+=(".logs/         Run logs and history")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        log WARN "Nothing found to nuke. Directory is already clean."
        return 0
    fi

    # ── Eagle 500KG Bomb confirmation ────────────────────────────────
    echo ""
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}${BOLD}        ✦ EAGLE 500KG BOMB — STRATAGEM REQUESTED ✦${NC}"
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  INCOMING ORBITAL PAYLOAD  ⚠${NC}"
    echo ""
    echo -e "  ${DIM}Super Earth High Command has received your request to deploy${NC}"
    echo -e "  ${DIM}an Eagle 500KG bomb on your entire ELM installation.${NC}"
    echo ""
    echo -e "  ${BOLD}The following will be permanently destroyed:${NC}"
    echo ""
    for i in "${!target_labels[@]}"; do
        echo -e "    ${RED}💥${NC} ${target_labels[$i]}"
    done
    echo ""
    echo -e "  ${RED}${BOLD}Root:${NC} ${parent}"
    echo ""
    echo -e "  ${RED}${BOLD}This cannot be undone. Everything dies. Even the bugs.${NC}"
    echo -e "  ${DIM}(For a managed democracy, of course.)${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Enter the stratagem sequence to deploy the Eagle 500KG:${NC}"
    echo ""
    echo -e "    ${BOLD}⬆ ➡ ⬇ ⬇ ⬇${NC}  ${DIM}(arrow keys or WASD — ESC to abort)${NC}"
    echo ""

    # ── Stratagem input reader ───────────────────────────────────────
    # Eagle 500KG sequence: Up Right Down Down Down
    local -a STRATAGEM=("up" "right" "down" "down" "down")
    local -a STRAT_ARROWS=("⬆" "➡" "⬇" "⬇" "⬇")
    local step=0 total=${#STRATAGEM[@]}

    # Read a single directional keypress → sets _SDIR
    _read_stratagem_key() {
        _SDIR=""
        local key
        IFS= read -rsn1 key </dev/tty
        case "$key" in
            $'\x1b')
                local s1 s2
                IFS= read -rsn1 -t 0.1 s1 </dev/tty 2>/dev/null || true
                if [[ "$s1" == "[" ]]; then
                    IFS= read -rsn1 -t 0.1 s2 </dev/tty 2>/dev/null || true
                    case "$s2" in
                        A) _SDIR="up" ;; B) _SDIR="down" ;;
                        C) _SDIR="right" ;; D) _SDIR="left" ;;
                        *) _SDIR="bad" ;;
                    esac
                else
                    _SDIR="abort"
                fi
                ;;
            w|W) _SDIR="up" ;; a|A) _SDIR="left" ;;
            s|S) _SDIR="down" ;; d|D) _SDIR="right" ;;
            q|Q) _SDIR="abort" ;; *) _SDIR="bad" ;;
        esac
    }

    _dir_to_arrow() {
        case "$1" in
            up) echo "⬆" ;; down) echo "⬇" ;; left) echo "⬅" ;; right) echo "➡" ;; *) echo "✗" ;;
        esac
    }

    # Draw the progress line
    _draw_strat() {
        local filled=$1 fail=$2
        printf "\r  ➤  "
        local i
        for (( i=0; i<total; i++ )); do
            if (( i < filled )); then
                printf "${GREEN}${BOLD}%s ${NC}" "${STRAT_ARROWS[$i]}"
            elif (( i == filled )) && [[ "$fail" == "1" ]]; then
                printf "${RED}${BOLD}✗ ${NC}"
            else
                printf "${DIM}%s ${NC}" "${STRAT_ARROWS[$i]}"
            fi
        done
    }

    _draw_strat 0 0

    while (( step < total )); do
        _read_stratagem_key

        [[ "$_SDIR" == "bad" ]] && continue

        if [[ "$_SDIR" == "abort" ]]; then
            _draw_strat "$step" 0
            echo ""
            echo ""
            echo -e "  ${GREEN}${BOLD}Stratagem aborted.${NC} Eagle returning to hangar."
            echo -e "  ${DIM}Democracy is still safe. Your modpack lives another day.${NC}"
            return 0
        fi

        if [[ "$_SDIR" == "${STRATAGEM[$step]}" ]]; then
            (( step++ ))
            _draw_strat "$step" 0
        else
            _draw_strat "$step" 1
            echo ""
            echo ""
            echo -e "  ${RED}${BOLD}WRONG INPUT!${NC} Expected $(_dir_to_arrow "${STRATAGEM[$step]}"), got $(_dir_to_arrow "$_SDIR")"
            echo ""
            echo -e "  ${GREEN}${BOLD}Eagle airstrike cancelled.${NC} Your modpack survives."
            echo -e "  ${DIM}Even Helldivers mess up sometimes. Run ${CYAN}elm nuke${NC} ${DIM}to try again.${NC}"
            return 0
        fi
    done

    echo ""
    echo ""
    echo -e "  ${RED}${BOLD}⚡ STRATAGEM ACTIVATED ⚡${NC}"
    echo ""
    sleep 1
    echo -e "  ${RED}${BOLD}⬇  EAGLE 500KG INBOUND  ⬇${NC}"
    echo ""

    # ── Stop any running Docker containers first ─────────────────────
    if [[ -f "$compose_file" ]]; then
        echo -e "  ${YELLOW}Stopping Docker containers...${NC}"
        (cd "$parent" && docker compose down --remove-orphans 2>/dev/null || docker-compose down --remove-orphans 2>/dev/null || true)
        log OK "Containers stopped"
    fi

    # ── Destroy everything ───────────────────────────────────────────
    for i in "${!targets[@]}"; do
        local t="${targets[$i]}"
        if [[ -d "$t" ]]; then
            rm -rf "$t"
            echo -e "    ${RED}✗${NC} Destroyed: $(basename "$t")/"
        elif [[ -f "$t" ]]; then
            rm -f "$t"
            echo -e "    ${RED}✗${NC} Destroyed: $(basename "$t")"
        fi
    done

    echo ""
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}${BOLD}        ✦ IMPACT CONFIRMED — AREA NEUTRALIZED ✦${NC}"
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}How'd it feel, Helldiver?${NC}"
    echo -e "  ${DIM}Your installation has been wiped. Run ${CYAN}elm init${NC} ${DIM}to start fresh.${NC}"
    echo -e "  ${DIM}For Super Earth. For democracy.${NC}"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local cmd="${1:-help}"; shift || true

    case "$cmd" in
        # Core pack management
        init)              cmd_init ;;
        add|a)             cmd_add "$@" ;;
        rm)                cmd_remove "${1:-}" ;;
        ls)                cmd_list "$@" ;;
        sync)              cmd_sync ;;
        up)                cmd_update ;;
        search|s)          cmd_search "$@" ;;
        pin)               cmd_pin "${1:-}" ;;
        unpin)             cmd_unpin "${1:-}" ;;
        export|ex)         cmd_export "$@" ;;

        # Server & deploy
        deploy)            cmd_deploy "$@" ;;
        target|t)          cmd_targets "$@" ;;

        # Diagnostics
        check)             cmd_check "$@" ;;
        net)               cmd_netcheck ;;

        # Config, keys & DNS
        config|cfg)        cmd_config "$@" ;;
        key)               cmd_key "$@" ;;
        dns)               cmd_dns "$@" ;;

        # Self-update
        update)            cmd_self_update "$@" ;;

        # Maintenance
        nuke)              cmd_nuke ;;
        resolve|res)       cmd_resolve "$@" ;;
        organize)          cmd_organize "${1:-}" ;;
        migrate|mig)       cmd_migrate "$@" ;;

        # Meta
        help|--help|-h)    cmd_help ;;
        --version|-v)      echo "ELM v1.0.0" ;;
        *)                 echo -e "${RED}Unknown: ${cmd}${NC}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
