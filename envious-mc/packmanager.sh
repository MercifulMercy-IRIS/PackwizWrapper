#!/usr/bin/env bash
# ============================================================================
# PackManager v4 — PackWiz + Docker Compose Server Management
# ============================================================================
#
# USAGE:
#   pm <command> [args]
#
# PACK MANAGEMENT:
#   pm init                    Initialize pack + mods.txt in current dir
#   pm sync                    Install all mods from mods.txt
#   pm update                  Update all non-pinned mods
#   pm add [slug...]           Add mods (no args = interactive)
#   pm search <query>          Search Modrinth & CurseForge
#   pm remove <slug>           Remove a mod
#   pm list                    Show installed mods with status
#   pm status                  Pack health overview
#   pm deps                    Show auto-pulled dependencies
#   pm export [mr|cf]          Export pack for distribution
#   pm serve                   Local HTTP server for testing
#   pm verify                  Full audit: mods.txt vs installed .pw.toml
#   pm diff                    Side-by-side modlist vs packwiz diff
#   pm doctor                  All checks + verify in one pass
#
# SERVER MANAGEMENT (Docker Compose + itzg/minecraft-server):
#   pm targets add <n>          Register a server target
#   pm deploy create            Generate compose service + start
#   pm deploy push              Publish pack for auto-update
#   pm deploy start/stop        Docker compose up/down per target
#   pm deploy restart           Restart a server
#   pm deploy status            Show all servers
#   pm deploy console <cmd>     Send RCON command
#   pm deploy logs              Tail server logs
#
# CONFIG:
#   pm config show             Print active config
#   pm config edit             Open config in $EDITOR
#   pm config path             Show config file paths
#
# ============================================================================

set -uo pipefail

# ============================================================================
# CONFIG LOADING
# ============================================================================
# Priority: local packmanager.conf > global ~/.config/packmanager/packmanager.conf > defaults

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

# Docker / Server defaults
DOCKER_COMPOSE_DIR="${HOME}/.config/packmanager/servers"  # Where compose files live
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

# Self-update (GitHub)
PM_GITHUB_REPO=""               # e.g. "yourusername/PackwizWrapper" (owner/repo)
PM_GITHUB_BRANCH="main"         # Branch to pull updates from
PM_GITHUB_PATH=""               # Subdirectory in repo where files live (e.g. "envious-mc")
PM_UPDATE_FILES="packmanager.sh install.sh packmanager.conf mods.txt"  # Files to update

# Local/self-hosted mods (for mods not on Modrinth/CurseForge)
LOCAL_MODS_DIR=""               # e.g. /var/www/mods — served by nginx/tunnel
LOCAL_MODS_URL=""               # e.g. https://mods.enviouslabs.com

# JVM
JVM_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1"

# Load global config
GLOBAL_CONF="${HOME}/.config/packmanager/packmanager.conf"
[[ -f "$GLOBAL_CONF" ]] && source "$GLOBAL_CONF"

# Load local config (overrides global)
LOCAL_CONF="${PACK_DIR}/packmanager.conf"
[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"

# Re-derive paths after config load (in case PACK_DIR changed)
MODS_FILE="${PACK_DIR}/mods.txt"
LOG_DIR="${PACK_DIR}/.logs"

# Setup
mkdir -p "$LOG_DIR" 2>/dev/null || true
RUN_LOG="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
touch "$RUN_LOG" 2>/dev/null || RUN_LOG="/tmp/pm_run_$$.log"

DEPS_ADDED=()
MISMATCHES=()          # Tracks slug mismatches: requested|resolved_slug|resolved_name|toml

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

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

check_packwiz() {
    command -v "$PACKWIZ_BIN" &>/dev/null || {
        echo -e "${RED}Error: packwiz not found.${NC}"
        echo "Install with: pm --install-packwiz"
        echo "Or set PACKWIZ_BIN in config"
        exit 1
    }
}

check_pack_init() {
    [[ -f "${PACK_DIR}/pack.toml" ]] || {
        echo -e "${RED}No pack.toml. Run 'pm init' first.${NC}"
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
    grep -qE "^!?((mr|cf|url):)?${slug}(\s|#|$)" "$MODS_FILE" 2>/dev/null
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
    raw="$(echo "$raw" | sed 's/\s*#.*$//' | xargs)"
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

# Verify a single mod after installation
# Returns 0 if match is good, 1 if mismatch detected
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

    # Normalize for comparison (lowercase, strip hyphens)
    local req_norm res_norm res_name_norm
    req_norm=$(echo "$requested_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
    res_norm=$(echo "$resolved_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
    res_name_norm=$(echo "$resolved_name" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')

    # Check 1: Slug match (exact or normalized)
    if [[ "$req_norm" == "$res_norm" ]]; then
        return 0  # Perfect match
    fi

    # Check 2: Is the requested slug contained in the resolved name?
    # e.g., "ae2" matches "Applied Energistics 2" → ae2 is in "appliedenergistics2"
    if [[ "$res_name_norm" == *"$req_norm"* || "$res_norm" == *"$req_norm"* ]]; then
        # Close enough — likely an alias. Log it but don't flag as mismatch.
        log INFO "${requested_slug} → ${resolved_name} (${resolved_slug}.pw.toml) ${DIM}— alias OK${NC}"
        echo "ALIAS: ${requested_slug} → ${resolved_slug} (${resolved_name})" >> "$RUN_LOG"
        return 0
    fi

    # Check 3: Is the resolved name at least related?
    # Use a simple substring check in both directions
    if [[ "$req_norm" == *"$res_norm"* ]]; then
        return 0  # Resolved is a substring of requested
    fi

    # If we got here, it's a genuine mismatch
    MISMATCHES+=("${requested_slug}|${resolved_slug}|${resolved_name}|${toml_file}")

    echo -e "  ${RED}⚠ MISMATCH${NC}: asked for ${BOLD}${requested_slug}${NC}, got ${BOLD}${resolved_name}${NC} (${resolved_slug}.pw.toml)"
    echo "MISMATCH: requested='${requested_slug}' resolved_slug='${resolved_slug}' resolved_name='${resolved_name}' file='${toml_file}'" >> "$RUN_LOG"

    return 1
}

# Full audit: compare every .pw.toml against mods.txt
verify_all_mods() {
    header "Mod Verification Audit"

    [[ -d "${PACK_DIR}/mods" ]] || { echo -e "  ${DIM}No mods installed.${NC}"; return; }
    [[ -f "$MODS_FILE" ]] || { echo -e "  ${DIM}No mods.txt found.${NC}"; return; }

    local checked=0 ok=0 aliased=0 mismatched=0 unlisted=0 missing=0
    local mismatch_report=()
    local unlisted_report=()
    local missing_report=()

    echo -e "  ${BLUE}Checking installed mods against mods.txt...${NC}"
    echo ""

    # Build a lookup of requested slugs from mods.txt
    declare -A requested_slugs
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | xargs)" ]] && continue

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
                local req_norm res_norm
                req_norm=$(echo "$req_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                res_norm=$(echo "$resolved_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                local name_norm
                name_norm=$(echo "$resolved_name" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')

                if [[ "$req_norm" == "$res_norm" ]]; then
                    found_match=true
                    (( ok++ ))
                    break
                elif [[ "$name_norm" == *"$req_norm"* || "$res_norm" == *"$req_norm"* ]]; then
                    found_match=true
                    (( aliased++ ))
                    echo -e "  ${CYAN}↔${NC} ${resolved_slug} ← ${req_slug} ${DIM}(alias)${NC}"
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
                local rn rr
                rn=$(echo "$req_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                rr=$(echo "$res_slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                local nn
                nn=$(echo "$res_name" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')

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
    echo -e "  Aliased:    ${CYAN}${aliased}${NC} slug ≠ filename but name matches"
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
        echo -e "  ${YELLOW}Run 'pm sync' to install these, or check slugs.${NC}"
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

    output=$($PACKWIZ_BIN "$cmd" install "$slug" --yes 2>&1) || exit_code=$?
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

try_modrinth() {
    local slug="$1" attempt=0
    while (( attempt < RETRY_ATTEMPTS )); do
        run_packwiz_install "modrinth" "$slug" && return 0
        (( attempt++ ))
        (( attempt < RETRY_ATTEMPTS )) && sleep "$RETRY_DELAY"
    done
    return 1
}

try_curseforge() {
    local slug="$1" attempt=0
    while (( attempt < RETRY_ATTEMPTS )); do
        run_packwiz_install "curseforge" "$slug" && return 0
        (( attempt++ ))
        (( attempt < RETRY_ATTEMPTS )) && sleep "$RETRY_DELAY"
    done
    return 1
}

try_url() {
    local url="$1" slug="$2"
    # packwiz url add <display-name> <download-url> [--force] [--meta-name <filename>]
    $PACKWIZ_BIN url add "$slug" "$url" --force --yes 2>>"$RUN_LOG"
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
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG" || true
    return 0
}

install_mod() {
    local source="$1" slug="$2" url="$3" pinned="$4"

    is_installed "$slug" && { log SKIP "${slug} (already installed)"; return 0; }

    local installed=false
    local via=""

    case "$source" in
        modrinth)
            # Accepts: slug, project ID, Modrinth URL, or search term
            try_modrinth "$slug" && { installed=true; via="Modrinth"; }
            $installed || { log FAIL "${slug} — not on Modrinth"; return 1; }
            ;;
        curseforge)
            # Accepts: slug, project ID, CurseForge URL, or search term
            try_curseforge "$slug" && { installed=true; via="CurseForge"; }
            $installed || { log FAIL "${slug} — not on CurseForge"; return 1; }
            ;;
        url)
            try_url "$url" "$slug" && { installed=true; via="URL"; }
            $installed || { log FAIL "${slug} — URL failed"; return 1; }
            ;;
        local)
            try_local "$slug" && { installed=true; via="Local"; }
            $installed || { log FAIL "${slug} — local JAR not found"; return 1; }
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

            $installed || { log FAIL "${slug} — not found on either source"; return 1; }
            ;;
    esac

    # Verify what actually got installed matches what we asked for
    if $installed; then
        verify_mod_install "$slug"
        local verify_result=$?
        if (( verify_result == 0 )); then
            log OK "${slug} ${DIM}(${via})${NC}"
        else
            log WARN "${slug} ${DIM}(${via})${NC} — ${YELLOW}VERIFY FAILED — review mismatch above${NC}"
        fi
    fi

    return 0
}


# ============================================================================
# TARGET REGISTRY
# ============================================================================
# Manages multiple Docker-based MC server instances. Each target has:
#   name, pack_dir, domain, port, rcon_port, ram, cpu, description
#
# Stored as JSON at ~/.config/packmanager/targets.json
#
# Architecture:
#   Docker VM (Rocky/Ubuntu)
#     ├─ nginx container         ← serves pack files for all targets
#     ├─ mc-survival  :25565     ← survival.enviouslabs.com (SRV record)
#     ├─ mc-creative  :25566     ← creative.enviouslabs.com (SRV record)
#     └─ mc-modded    :25567     ← modded.enviouslabs.com   (SRV record)
# ============================================================================

TARGETS_FILE="${HOME}/.config/packmanager/targets.json"

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
        echo -e "${RED}No targets configured. Run: pm targets add <name>${NC}" >&2
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
    [[ -n "$pack_dir" ]] && PACK_DIR="$pack_dir" && MODS_FILE="${PACK_DIR}/mods.txt"

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

# Generate docker-compose.yml from all registered targets
generate_compose() {
    local cdir; cdir=$(compose_dir)
    mkdir -p "${cdir}/packs"

    local compose_file="${cdir}/docker-compose.yml"

    # Header
    cat > "$compose_file" << 'HEADER'
# ============================================================================
# EnviousLabs MC Servers — Auto-generated by PackManager
# DO NOT EDIT — regenerated by `pm deploy create` and `pm deploy regenerate`
# ============================================================================

services:
HEADER

    # Add nginx pack server
    cat >> "$compose_file" << NGINX

  # --- Pack file server (serves packwiz packs for auto-update) ---
  packserver:
    image: nginx:alpine
    container_name: el-packserver
    restart: unless-stopped
    volumes:
      - ${cdir}/packs:/usr/share/nginx/html:ro
    ports:
      - "8080:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 3
NGINX

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
        local motd="${domain:-${t}} — EnviousLabs"
        local rcon_pass
        rcon_pass=$(target_get "$t" "rcon_password")
        [[ -z "$rcon_pass" ]] && rcon_pass="pm-${t}-$(openssl rand -hex 4 2>/dev/null || echo "change-me")"

        # If the pack has been published, point at the packserver URL
        local packwiz_url=""
        if [[ -d "${cdir}/packs/${t}" ]]; then
            packwiz_url="http://packserver/${t}/pack.toml"
        fi

        cat >> "$compose_file" << SERVICE

  # --- ${t} ---
  mc-${t}:
    image: ${SERVER_IMAGE}
    container_name: el-mc-${t}
    restart: unless-stopped
    stdin_open: true
    tty: true
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
    echo "" >> "$compose_file"
    echo "volumes:" >> "$compose_file"

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
        echo -e "${RED}No compose file. Run 'pm deploy create' first.${NC}"
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
# PACK PUBLISHING (copies pack files to nginx for auto-update)
# ============================================================================

publish_pack() {
    local target_name="${1:-}"

    header "Publishing Pack"
    check_pack_init

    local cdir; cdir=$(compose_dir)
    local publish_dir="${cdir}/packs"

    if [[ -n "$target_name" ]]; then
        publish_dir="${publish_dir}/${target_name}"
    fi

    mkdir -p "${publish_dir}/mods"

    # Build index with hashes for distribution
    $PACKWIZ_BIN refresh --build 2>>"$RUN_LOG"

    info "Copying pack → ${publish_dir}..."
    cp "${PACK_DIR}/pack.toml" "${publish_dir}/"
    [[ -f "${PACK_DIR}/index.toml" ]] && cp "${PACK_DIR}/index.toml" "${publish_dir}/"
    cp "${PACK_DIR}/mods/"*.pw.toml "${publish_dir}/mods/" 2>/dev/null || true

    # If configs exist, copy those too
    if [[ -d "${PACK_DIR}/config" ]]; then
        cp -r "${PACK_DIR}/config" "${publish_dir}/" 2>/dev/null || true
    fi

    log OK "Published to ${publish_dir}"

    # Show player instructions
    local domain; domain=$(target_get "$target_name" "domain")
    local pack_url

    if [[ -n "$PACK_HOST_URL" ]]; then
        pack_url="${PACK_HOST_URL}/${target_name}"
    elif [[ -n "$domain" ]]; then
        pack_url="http://${SERVER_VM_IP:-localhost}:8080/${target_name}"
    else
        pack_url="http://localhost:8080/${target_name}"
    fi

    echo ""
    echo -e "  ${GREEN}Players (Prism Launcher pre-launch command):${NC}"
    echo -e "  ${CYAN}\"\$INST_JAVA\" -jar packwiz-installer-bootstrap.jar ${pack_url}/pack.toml${NC}"
    echo ""
    echo -e "  ${GREEN}Server auto-syncs on startup if PACKWIZ_URL is set.${NC}"
    echo -e "  Regenerate compose to pick it up: ${CYAN}pm deploy regenerate${NC}"
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

cmd_init() {
    header "Initializing Pack"
    if [[ -f "${PACK_DIR}/pack.toml" ]]; then
        echo -e "${YELLOW}pack.toml exists. Re-init? (y/N)${NC}"
        read -r c; [[ "$c" != [yY] ]] && exit 0
    fi

    local loader_arg=""
    [[ -n "$LOADER_VERSION" ]] && loader_arg="--${LOADER}-version ${LOADER_VERSION}"

    $PACKWIZ_BIN init --mc-version "$MC_VERSION" --modloader "$LOADER" $loader_arg

    [[ -f "$MODS_FILE" ]] || {
        echo "# PackManager mods list — edit and run: pm sync" > "$MODS_FILE"
        log OK "Created mods.txt"
    }
}

cmd_sync() {
    check_packwiz; check_pack_init
    header "Syncing Mods"
    [[ -f "$MODS_FILE" ]] || { echo -e "${RED}No mods.txt.${NC}"; exit 1; }

    local total=0 success=0 failed=0
    local failed_mods=()
    DEPS_ADDED=()
    MISMATCHES=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | xargs)" ]] && continue

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
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG" && log OK "Index updated" || log WARN "Index warnings"

    header "Sync Summary"
    echo -e "  Processed:   ${BOLD}${total}${NC}"
    echo -e "  Installed:   ${GREEN}${success}${NC}"
    echo -e "  Failed:      ${RED}${failed}${NC}"
    echo -e "  Mismatches:  ${YELLOW}${#MISMATCHES[@]}${NC}"

    if (( ${#DEPS_ADDED[@]} > 0 )); then
        echo ""
        echo -e "  ${MAGENTA}Auto-installed dependencies:${NC}"
        printf '    ↳ %s\n' "${DEPS_ADDED[@]}"
    fi

    if (( ${#MISMATCHES[@]} > 0 )); then
        echo ""
        echo -e "  ${YELLOW}${BOLD}⚠ MISMATCHED MODS — review these carefully:${NC}"
        echo -e "  ${DIM}PackWiz resolved these to something different than requested.${NC}"
        echo ""
        for entry in "${MISMATCHES[@]}"; do
            IFS='|' read -r req_slug res_slug res_name res_toml <<< "$entry"
            echo -e "    ${YELLOW}•${NC} asked for ${BOLD}${req_slug}${NC}"
            echo -e "      got ${RED}${res_name}${NC} (${res_slug}.pw.toml)"
            echo -e "      ${DIM}fix: pm remove ${res_slug} && pm add mr:correct-slug${NC}"
            echo ""
        done
        # Write mismatches to file for reference
        printf '%s\n' "${MISMATCHES[@]}" > "${LOG_DIR}/last_mismatches.txt"
        echo -e "  ${DIM}Saved to: ${LOG_DIR}/last_mismatches.txt${NC}"
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
    echo ""
}

cmd_add() {
    check_packwiz; check_pack_init

    if [[ $# -eq 0 ]]; then
        cmd_add_interactive; return
    fi

    header "Adding ${#} mod(s)"
    DEPS_ADDED=()
    MISMATCHES=()

    for input in "$@"; do
        local parsed
        parsed="$(parse_mod_entry "$input")" || continue
        IFS='|' read -r source slug url pinned <<< "$parsed"

        if install_mod "$source" "$slug" "$url" "$pinned"; then
            is_in_modlist "$slug" || { append_to_modlist "$input"; log INFO "Added to mods.txt"; }
        else
            echo ""
            echo -e "  ${YELLOW}Failed '${slug}'. Try:${NC}"
            echo "    pm search ${slug}"
            echo "    pm add cf:alternate-slug"
            echo "    pm add url:https://direct-link.jar"
            echo ""
        fi
    done

    if (( ${#DEPS_ADDED[@]} > 0 )); then
        separator
        echo -e "  ${MAGENTA}Dependencies:${NC}"
        printf '    ↳ %s\n' "${DEPS_ADDED[@]}"
    fi

    if (( ${#MISMATCHES[@]} > 0 )); then
        separator
        echo -e "  ${YELLOW}${BOLD}⚠ MISMATCHED — got a different mod than requested:${NC}"
        for entry in "${MISMATCHES[@]}"; do
            IFS='|' read -r req_slug res_slug res_name res_toml <<< "$entry"
            echo -e "    ${YELLOW}•${NC} ${BOLD}${req_slug}${NC} → ${RED}${res_name}${NC} (${res_slug})"
            echo -e "      ${DIM}fix: pm remove ${res_slug} && pm add mr:correct-slug${NC}"
        done
    fi

    $PACKWIZ_BIN refresh 2>>"$RUN_LOG"
}

cmd_add_interactive() {
    header "Interactive Add"
    echo -e "  Enter mod slugs (supports mr:, cf:, url: prefixes)."
    echo -e "  Type ${BOLD}search <query>${NC} to search. Blank or ${BOLD}done${NC} to finish."
    echo ""

    local queue=()
    while true; do
        echo -ne "  ${CYAN}mod>${NC} "
        read -r input
        [[ -z "$input" || "$input" == "done" || "$input" == "q" ]] && break
        if [[ "$input" == search\ * || "$input" == s\ * ]]; then
            _do_search "${input#* }"; continue
        fi
        queue+=("$input")
        echo -e "    ${DIM}+ queued${NC}"
    done

    (( ${#queue[@]} == 0 )) && { echo -e "\n  ${DIM}Nothing queued.${NC}"; return; }
    echo ""
    echo -e "  ${BOLD}Installing ${#queue[@]} mod(s)...${NC}"
    separator
    cmd_add "${queue[@]}"
}

cmd_search() {
    check_packwiz
    [[ -z "${1:-}" ]] && { echo -e "${RED}Usage: pm search <query>${NC}"; exit 1; }
    _do_search "$1"
}

_do_search() {
    local query="$1"
    echo ""
    echo -e "  ${BLUE}Modrinth: '${query}'${NC}"
    local mr_out
    mr_out=$($PACKWIZ_BIN modrinth search "$query" 2>&1) || true
    [[ -n "$mr_out" ]] && echo "$mr_out" | head -25 | while IFS= read -r l; do echo "    $l"; done || echo -e "    ${DIM}No results${NC}"

    echo ""
    echo -e "  ${BLUE}CurseForge: '${query}'${NC}"
    local cf_out
    cf_out=$($PACKWIZ_BIN curseforge search "$query" 2>&1) || true
    [[ -n "$cf_out" ]] && echo "$cf_out" | head -25 | while IFS= read -r l; do echo "    $l"; done || echo -e "    ${DIM}No results${NC}"
    echo ""
}

cmd_remove() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: pm remove <slug>}"
    header "Removing: ${slug}"
    $PACKWIZ_BIN remove "$slug" --yes 2>>"$RUN_LOG" && log OK "Removed from pack" || log WARN "Remove may have failed"
    if [[ -f "$MODS_FILE" ]]; then
        local tmp; tmp="$(mktemp)"
        grep -vE "^!?((mr|cf|url):)?${slug}(\s|#|$)" "$MODS_FILE" > "$tmp" || true
        mv "$tmp" "$MODS_FILE"
        log INFO "Removed from mods.txt"
    fi
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG"
}

cmd_list() {
    check_pack_init
    local side_filter="" show_version=false use_native=false

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
        $PACKWIZ_BIN list "${args[@]}" 2>>"$RUN_LOG"
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
            local cl; cl="$(echo "$line" | sed 's/\s*#.*$//' | xargs)"
            if [[ "$cl" == !* ]]; then
                $hp || { echo -e "  ${YELLOW}Pinned (skipping):${NC}"; hp=true; }
                echo -e "    ${CYAN}⊘${NC} ${cl:1}"
            fi
        done < "$MODS_FILE"
        $hp && echo ""
    fi

    log INFO "Running packwiz update --all..."
    $PACKWIZ_BIN update --all --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Some updates failed"
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG"
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

cmd_doctor() {
    check_pack_init
    header "Pack Doctor"
    local issues=0

    echo -e "  ${BLUE}Checking listed mods are installed...${NC}"
    [[ -f "$MODS_FILE" ]] && while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*@ ]] && continue
        [[ -z "$(echo "$line" | xargs)" ]] && continue
        local parsed; parsed="$(parse_mod_entry "$line")" || continue
        IFS='|' read -r _ slug _ _ <<< "$parsed"
        is_installed "$slug" || { log WARN "Missing: ${slug}"; (( issues++ )); }
    done < "$MODS_FILE"

    echo -e "  ${BLUE}Refreshing index...${NC}"
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG" && log OK "Index clean" || { log WARN "Index issues"; (( issues++ )); }

    echo ""
    (( issues == 0 )) && echo -e "  ${GREEN}${BOLD}All good!${NC}" || echo -e "  ${YELLOW}${issues} issue(s). Run 'pm sync' to fix.${NC}"

    # Run the full verification audit
    verify_all_mods
}

cmd_verify() {
    check_pack_init
    verify_all_mods
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
        [[ -z "$(echo "$line" | xargs)" ]] && continue
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
                rn=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                in_=$(echo "$iname" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
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
                rn=$(echo "$rslug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                sn=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
                nn=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -d '-_ ')
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

    # Show last known mismatches if they exist
    if [[ -f "${LOG_DIR}/last_mismatches.txt" ]]; then
        local mc
        mc=$(wc -l < "${LOG_DIR}/last_mismatches.txt" 2>/dev/null || echo 0)
        if (( mc > 0 )); then
            echo -e "  ${YELLOW}${BOLD}Last sync had ${mc} slug mismatch(es):${NC}"
            while IFS='|' read -r req_slug res_slug res_name res_toml; do
                echo -e "    ${YELLOW}•${NC} ${BOLD}${req_slug}${NC} → ${RED}${res_name}${NC} (${res_slug})"
            done < "${LOG_DIR}/last_mismatches.txt"
            echo ""
        fi
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
    $PACKWIZ_BIN refresh --build 2>>"$RUN_LOG"

    case "$fmt" in
        modrinth|mr)
            $PACKWIZ_BIN modrinth export $side_flag 2>>"$RUN_LOG" && log OK "Modrinth .mrpack created" || log FAIL "Export failed"
            ;;
        curseforge|cf)
            $PACKWIZ_BIN curseforge export $side_flag 2>>"$RUN_LOG" && log OK "CurseForge .zip created" || log FAIL "Export failed"
            ;;
        *)
            echo -e "${RED}Usage: pm export [mr|cf] [client|server]${NC}"
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
    $PACKWIZ_BIN serve
}

# ============================================================================
# NATIVE PACKWIZ COMMANDS (direct passthroughs + wrappers)
# ============================================================================

cmd_pin() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: pm pin <slug>}"
    header "Pinning: ${slug}"
    # Native packwiz pin — adds [pin] section to .pw.toml
    $PACKWIZ_BIN pin "$slug" 2>>"$RUN_LOG" && log OK "Pinned (won't receive updates)" || log FAIL "Pin failed"
}

cmd_unpin() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: pm unpin <slug>}"
    header "Unpinning: ${slug}"
    $PACKWIZ_BIN unpin "$slug" 2>>"$RUN_LOG" && log OK "Unpinned (will receive updates)" || log FAIL "Unpin failed"
}

cmd_migrate() {
    check_packwiz; check_pack_init
    local target="${1:?Usage: pm migrate <minecraft|loader> [version]}"
    local version="${2:-}"

    case "$target" in
        minecraft|mc)
            header "Migrating Minecraft Version"
            if [[ -n "$version" ]]; then
                log INFO "Migrating to Minecraft ${version}..."
                $PACKWIZ_BIN migrate minecraft "$version" --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Some mods may not support ${version}"
            else
                log INFO "Interactive Minecraft migration..."
                $PACKWIZ_BIN migrate minecraft 2>>"$RUN_LOG"
            fi
            ;;
        loader|forge|neoforge|fabric|quilt)
            header "Migrating Loader Version"
            if [[ -n "$version" ]]; then
                log INFO "Migrating loader to ${version}..."
                $PACKWIZ_BIN migrate loader "$version" --yes 2>>"$RUN_LOG" && log OK "Done" || log WARN "Migration had issues"
            else
                log INFO "Interactive loader migration..."
                $PACKWIZ_BIN migrate loader 2>>"$RUN_LOG"
            fi
            ;;
        *)
            echo -e "${RED}Usage: pm migrate <minecraft|loader> [version]${NC}"
            echo "  pm migrate minecraft 1.21.1"
            echo "  pm migrate loader 47.2.0"
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
                $PACKWIZ_BIN settings acceptable-versions "$versions" 2>>"$RUN_LOG" && log OK "Done" || log FAIL "Failed"
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
                echo -e "  ${DIM}Set with: pm settings versions 1.20,1.20.1,1.20.2${NC}"
            fi
            ;;
        show|"")
            header "Pack Settings"
            echo -e "  ${BOLD}pack.toml:${NC}"
            cat "${PACK_DIR}/pack.toml"
            echo ""
            ;;
        *)
            echo -e "${RED}Usage: pm settings <versions|show> [values]${NC}"
            echo "  pm settings versions 1.20,1.20.1"
            echo "  pm settings show"
            ;;
    esac
}

cmd_import() {
    check_packwiz; check_pack_init
    local path="${1:?Usage: pm import <path-to-zip>}"
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

    $PACKWIZ_BIN curseforge import "$path" --yes 2>>"$RUN_LOG" && log OK "Import complete" || log FAIL "Import failed"
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG"
}

cmd_detect() {
    check_packwiz; check_pack_init
    header "Detecting CurseForge Mods"
    log INFO "Scanning installed JARs for CurseForge matches..."
    $PACKWIZ_BIN curseforge detect --yes 2>>"$RUN_LOG" && log OK "Detection complete" || log WARN "Some files not detected"
    $PACKWIZ_BIN refresh 2>>"$RUN_LOG"
}

cmd_open() {
    check_packwiz; check_pack_init
    local slug="${1:?Usage: pm open <slug>}"

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
        $PACKWIZ_BIN refresh --build 2>>"$RUN_LOG" && log OK "Index built" || log FAIL "Build failed"
    else
        $PACKWIZ_BIN refresh 2>>"$RUN_LOG" && log OK "Index refreshed" || log FAIL "Refresh failed"
    fi
}

cmd_markdown() {
    check_packwiz; check_pack_init
    header "Generating Mod List (Markdown)"
    $PACKWIZ_BIN utils markdown 2>>"$RUN_LOG"
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
            [[ -z "$targets" ]] && { echo -e "  ${DIM}No targets. Run: pm targets add <name>${NC}"; return; }

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
            local name="${1:?Usage: pm targets add <name> [key=value...]}"
            shift || true

            header "Adding Target: ${name}"

            local existing_port; existing_port=$(target_get "$name" "port")
            if [[ -n "$existing_port" ]]; then
                log WARN "Target '${name}' already exists (port: ${existing_port})"
                echo -e "  Use ${CYAN}pm targets set ${name} key=value${NC} to update"
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
                echo -e "  ${CYAN}pm targets set ${name} domain=${name}.enviouslabs.com${NC}"
            fi

            echo ""
            echo -e "  Next: ${CYAN}pm deploy create --target ${name}${NC}"
            echo ""
            ;;

        set|update)
            local name="${1:?Usage: pm targets set <name> key=value [key=value...]}"
            shift || true
            target_set "$name" "$@"
            log OK "Updated target: ${name}"
            ;;

        remove|rm|delete)
            local name="${1:?Usage: pm targets remove <name>}"
            echo -e "  ${YELLOW}Remove target '${name}'? (y/N)${NC}"
            read -r confirm
            [[ "$confirm" != [yY] ]] && return
            target_remove "$name"
            log OK "Removed target: ${name}"
            echo -e "  ${DIM}Docker volume mc-${name}-data still exists. Remove with:${NC}"
            echo -e "  ${CYAN}docker volume rm mc-${name}-data${NC}"
            ;;

        show|info)
            local name="${1:?Usage: pm targets show <name>}"
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
            echo -e "  ${BOLD}pm targets${NC} — Multi-Server Management"
            echo ""
            echo -e "  ${CYAN}pm targets list${NC}                 Show all targets"
            echo -e "  ${CYAN}pm targets add <n> [k=v...]${NC}  Register a new target"
            echo -e "  ${CYAN}pm targets set <n> k=v ...${NC}   Update target settings"
            echo -e "  ${CYAN}pm targets show <n>${NC}          Full target details"
            echo -e "  ${CYAN}pm targets remove <n>${NC}        Remove a target"
            echo -e "  ${CYAN}pm targets dns [n]${NC}           Show SRV record setup"
            echo ""
            echo -e "  ${BOLD}Fields:${NC} domain, port, rcon_port, pack_dir, ram, cpu, description"
            echo ""
            echo -e "  ${BOLD}Example:${NC}"
            echo "    pm targets add survival domain=survival.enviouslabs.com ram=8192"
            echo "    pm targets add creative domain=creative.enviouslabs.com ram=4096"
            echo "    pm targets dns                  # show SRV records for Cloudflare"
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
        status|st|regenerate|help) target_name="${target_flag:-}" ;;
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
                log FAIL "Target '${target_name}' has no port. Run: pm targets add ${target_name}"
                exit 1
            }

            # Generate/regenerate the compose file
            generate_compose

            # Publish pack if it exists
            if [[ -f "${PACK_DIR}/pack.toml" ]]; then
                publish_pack "$target_name"
                # Regenerate compose so PACKWIZ_URL picks up the published pack
                generate_compose
            fi

            log OK "Compose generated for ${target_name}"
            echo ""
            echo -e "  Start with: ${CYAN}pm deploy start --target ${target_name}${NC}"
            echo -e "  DNS setup:  ${CYAN}pm targets dns ${target_name}${NC}"
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
            local command="${1:?Usage: pm deploy console <command> --target <n>}"
            docker_send_command "$target_name" "$command"
            ;;

        logs|log)
            docker_logs "$target_name" "${1:-100}"
            ;;

        backup|bk)
            docker_backup_target "$target_name"
            ;;

        regenerate|regen)
            header "Regenerating Compose"
            generate_compose
            echo -e "  ${DIM}Apply changes with: docker compose -f $(compose_dir)/docker-compose.yml up -d${NC}"
            echo ""
            ;;

        full)
            header "Full Deployment: ${target_name}"
            echo -e "  sync mods → publish pack → generate compose → start"
            echo -e "  ${YELLOW}Continue? (y/N)${NC}"
            read -r confirm
            [[ "$confirm" != [yY] ]] && exit 0

            echo ""
            cmd_sync
            separator
            publish_pack "$target_name"
            separator
            generate_compose
            separator
            docker_start_target "$target_name"

            local domain; domain=$(target_get "$target_name" "domain")

            header "Deployment Complete: ${target_name}"
            echo -e "  ${GREEN}${BOLD}Server is starting!${NC}"
            [[ -n "$domain" ]] && echo -e "  Connect: ${CYAN}${domain}${NC}"
            echo -e "  Status:  ${CYAN}pm deploy status --target ${target_name}${NC}"
            echo -e "  Logs:    ${CYAN}pm deploy logs --target ${target_name}${NC}"
            echo -e "  DNS:     ${CYAN}pm targets dns ${target_name}${NC}"
            echo ""
            ;;

        help|*)
            echo ""
            echo -e "  ${BOLD}pm deploy${NC} — Docker Server Management"
            echo ""
            echo -e "  All commands accept ${CYAN}--target <name>${NC} (auto-resolves if only one)"
            echo ""
            echo -e "  ${CYAN}pm deploy create${NC}           Generate compose + publish pack"
            echo -e "  ${CYAN}pm deploy push${NC}             Publish pack for auto-update"
            echo -e "  ${CYAN}pm deploy start${NC}            Start the server"
            echo -e "  ${CYAN}pm deploy stop${NC}             Stop the server"
            echo -e "  ${CYAN}pm deploy restart${NC}          Restart the server"
            echo -e "  ${CYAN}pm deploy status${NC}           All servers (or --target for one)"
            echo -e "  ${CYAN}pm deploy console <cmd>${NC}    Send RCON command"
            echo -e "  ${CYAN}pm deploy logs${NC}             Tail server logs"
            echo -e "  ${CYAN}pm deploy backup${NC}           Backup server world"
            echo -e "  ${CYAN}pm deploy regenerate${NC}       Rebuild docker-compose.yml"
            echo -e "  ${CYAN}pm deploy full${NC}             Pipeline: sync → publish → create → start"
            echo ""
            echo -e "  ${BOLD}Example:${NC}"
            echo "    pm targets add survival domain=survival.enviouslabs.com ram=8192"
            echo "    pm deploy create --target survival"
            echo "    pm deploy start --target survival"
            echo "    pm deploy status"
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
                echo -e "    ${DIM}1. ./packmanager.conf (not found)${NC}"
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
        *)
            echo -e "${RED}Usage: pm config [show|edit|path]${NC}"
            ;;
    esac
}

# ============================================================================
# SELF-UPDATE (GitHub)
# ============================================================================
# Downloads the latest version of PackManager files from a GitHub repo.
# Requires PM_GITHUB_REPO to be set (e.g. "yourusername/envious-mc").
# Uses raw.githubusercontent.com to fetch files from PM_GITHUB_BRANCH.
# Backs up existing files before overwriting.

cmd_self_update() {
    header "Self-Update"

    # Validate config
    if [[ -z "$PM_GITHUB_REPO" ]]; then
        echo -e "  ${RED}PM_GITHUB_REPO not set.${NC}"
        echo ""
        echo -e "  Set it in your config (${CYAN}pm config edit${NC}):"
        echo -e "    ${CYAN}PM_GITHUB_REPO=\"yourusername/envious-mc\"${NC}"
        echo ""
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        echo -e "  ${RED}curl is required for self-update.${NC}"
        exit 1
    fi

    # Sanitize: strip trailing/leading slashes and whitespace
    local repo_clean="${PM_GITHUB_REPO#/}"; repo_clean="${repo_clean%/}"; repo_clean="$(echo "$repo_clean" | xargs)"
    local branch_clean="${PM_GITHUB_BRANCH#/}"; branch_clean="${branch_clean%/}"; branch_clean="$(echo "$branch_clean" | xargs)"
    local path_clean=""
    if [[ -n "$PM_GITHUB_PATH" ]]; then
        path_clean="${PM_GITHUB_PATH#/}"; path_clean="${path_clean%/}"; path_clean="$(echo "$path_clean" | xargs)"
    fi

    # Build base URL: repo/branch[/path]
    local raw_base="https://raw.githubusercontent.com/${repo_clean}/${branch_clean}"
    [[ -n "$path_clean" ]] && raw_base="${raw_base}/${path_clean}"
    local install_dir="${HOME}/.local/bin"
    local config_dir="${HOME}/.config/packmanager"
    local backup_dir="${config_dir}/backups/$(date +%Y%m%d_%H%M%S)"

    # --- Check connectivity & repo existence ---
    log INFO "Checking ${repo_clean} (branch: ${branch_clean})..."

    local http_code
    http_code=$(curl -sL -o /dev/null -w "%{http_code}" "${raw_base}/packmanager.sh" 2>/dev/null || echo "000")

    if [[ "$http_code" == "404" ]]; then
        echo -e "  ${RED}Repository or branch not found.${NC}"
        echo -e "  Checked: ${DIM}${raw_base}/packmanager.sh${NC}"
        echo ""
        echo -e "  Verify:"
        echo -e "    • PM_GITHUB_REPO is correct: ${CYAN}${PM_GITHUB_REPO}${NC}"
        echo -e "    • PM_GITHUB_BRANCH is correct: ${CYAN}${PM_GITHUB_BRANCH}${NC}"
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

    local files_to_update=($PM_UPDATE_FILES)
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

    # Backup pm binary
    if [[ -f "${install_dir}/pm" ]]; then
        cp "${install_dir}/pm" "${backup_dir}/packmanager.sh.bak"
        log OK "Backed up pm binary"
    fi

    # Backup install.sh if it exists somewhere known
    local script_dir=""
    # Try to find where the original install was (check if pm is a symlink or has a comment)
    if [[ -f "${config_dir}/install.sh" ]]; then
        cp "${config_dir}/install.sh" "${backup_dir}/install.sh.bak"
    fi

    # --- Apply updates ---
    separator
    log INFO "Applying updates..."

    # 1. Update the pm binary (packmanager.sh → ~/.local/bin/pm)
    if [[ -f "${tmp_dir}/packmanager.sh" ]]; then
        cp "${tmp_dir}/packmanager.sh" "${install_dir}/pm"
        chmod +x "${install_dir}/pm"
        log OK "Updated pm → ${install_dir}/pm"
    fi

    # 2. Update install.sh (store in config dir for future use)
    if [[ -f "${tmp_dir}/install.sh" ]]; then
        cp "${tmp_dir}/install.sh" "${config_dir}/install.sh"
        chmod +x "${config_dir}/install.sh"
        log OK "Updated install.sh → ${config_dir}/install.sh"
    fi

    # 3. Update default config template (NOT the user's active config)
    if [[ -f "${tmp_dir}/packmanager.conf" ]]; then
        cp "${tmp_dir}/packmanager.conf" "${config_dir}/packmanager.conf.default"
        log OK "Updated config template → packmanager.conf.default"
        echo -e "    ${DIM}Your active config was NOT overwritten.${NC}"
        echo -e "    ${DIM}Compare with: diff ${config_dir}/packmanager.conf ${config_dir}/packmanager.conf.default${NC}"
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
    echo -e "  ${CYAN}cp ${backup_dir}/packmanager.sh.bak ${install_dir}/pm${NC}"
    echo ""
}

cmd_self_update_status() {
    header "Update Status"

    if [[ -z "$PM_GITHUB_REPO" ]]; then
        echo -e "  ${YELLOW}PM_GITHUB_REPO not configured.${NC}"
        echo -e "  Set it in your config: ${CYAN}pm config edit${NC}"
        echo ""
        return
    fi

    local config_dir="${HOME}/.config/packmanager"
    local local_sha_file="${config_dir}/.last_update_sha"

    # Sanitize repo/branch
    local repo_clean="${PM_GITHUB_REPO#/}"; repo_clean="${repo_clean%/}"; repo_clean="$(echo "$repo_clean" | xargs)"
    local branch_clean="${PM_GITHUB_BRANCH#/}"; branch_clean="${branch_clean%/}"; branch_clean="$(echo "$branch_clean" | xargs)"

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
                echo -e "  Run: ${CYAN}pm self-update${NC}"
            fi
        else
            echo -e "  Status:  ${YELLOW}Unknown (run pm self-update to sync)${NC}"
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

  PackManager v4 — PackWiz + Docker Compose Server Management

  PACK MANAGEMENT:
    init                           Initialize pack.toml + mods.txt
    sync                           Install all mods from mods.txt
    update                         Update all non-pinned mods
    add [slug...]                  Add mods (no args = interactive)
    search <query>                 Search Modrinth & CurseForge
    remove <slug>                  Remove a mod from pack + mods.txt
    list [--side <s>] [--version]  Show installed mods (--native for raw packwiz)
    status                         Pack health overview
    deps                           Show auto-pulled dependencies
    refresh [--build]              Refresh index (--build for distribution)
    serve                          Local HTTP dev server (localhost:8080)

  PACKWIZ NATIVE:
    pin <slug>                     Pin mod version (prevent updates)
    unpin <slug>                   Unpin (allow updates again)
    migrate <minecraft|loader> [v] Migrate MC or loader version
    settings versions [v1,v2,...]  View/set acceptable game versions
    import <zip>                   Import a CurseForge modpack .zip
    detect                         Detect installed JARs on CurseForge
    open <slug>                    Open mod page on Modrinth/CurseForge
    export [mr|cf] [client|server] Export pack (.mrpack or .zip)
    markdown                       Generate mod list as Markdown

  VERIFICATION:
    verify                         Full audit: mods.txt ↔ installed .pw.toml
    diff                           Side-by-side modlist vs packwiz state
    doctor                         All checks + verify + refresh

  SERVER (Docker Compose — all accept --target <n>):
    targets list                   Show all server targets
    targets add <n> [k=v...]    Register a new target (auto-assigns port)
    targets set <n> k=v ...     Update target settings
    targets show <n>            Full target details
    targets dns [n]                Show SRV records for Cloudflare
    targets remove <n>          Remove a target
    deploy create               Generate compose service for target
    deploy push                    Publish pack for auto-update
    deploy start/stop/restart      Docker compose controls
    deploy status                  All servers (or --target for one)
    deploy console <cmd>           Send RCON command
    deploy logs                    Tail server logs
    deploy backup                  Backup server world
    deploy regenerate              Rebuild docker-compose.yml
    deploy full                    Pipeline: sync → publish → create → start

  CONFIG:
    config show                    Print active configuration
    config edit                    Open config in editor
    config path                    Show config file locations

  MODS.TXT FORMAT:
    tinkers-construct              Auto-detect (Modrinth → CurseForge)
    mr:ars-nouveau                 Modrinth only
    cf:journeymap                  CurseForge only
    url:https://dl.com/mod.jar     Direct download URL
    local:my-custom-mod            Local JAR from LOCAL_MODS_DIR
    !jei                           Pinned (skip updates in pm update)
    https://modrinth.com/mod/slug  Full Modrinth URL
    https://curseforge.com/...     Full CurseForge URL (page or file)

  SELF-UPDATE:
    self-update                    Download latest from GitHub
    update-status                  Check if updates are available

  EXAMPLES:
    pm add tinkers-construct mekanism ae2 ars-nouveau
    pm add cf:journeymap mr:jade
    pm add url:https://example.com/custom-mod.jar
    pm add local:my-fork                       # from LOCAL_MODS_DIR
    pm list --side server                      # server-only mods
    pm export mr server                        # Modrinth server pack
    pm pin jei                                 # lock JEI version
    pm migrate minecraft 1.21.1                # version migration
    pm settings versions 1.20,1.20.1,1.20.2   # accept multiple MC versions
    pm import ~/Downloads/modpack.zip          # import CurseForge pack
    pm targets add survival domain=survival.enviouslabs.com ram=8192
    pm targets add creative domain=creative.enviouslabs.com ram=4096
    pm deploy create --target survival     # generates compose
    pm deploy create --target creative
    pm deploy start --target survival      # docker compose up
    pm deploy status                       # all servers at a glance
    pm targets dns                         # SRV records for Cloudflare

HELP
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local cmd="${1:-help}"; shift || true

    case "$cmd" in
        # Pack management
        init)              cmd_init ;;
        sync)              cmd_sync ;;
        update|up)         cmd_update ;;
        add|a)             cmd_add "$@" ;;
        search|s|find)     cmd_search "${1:-}" ;;
        remove|rm)         cmd_remove "${1:-}" ;;
        list|ls)           cmd_list "$@" ;;
        status|st)         cmd_status ;;
        deps)              cmd_deps ;;
        export|ex)         cmd_export "${1:-modrinth}" "${2:-}" ;;
        serve)             cmd_serve ;;
        refresh)           cmd_refresh "${1:-}" ;;

        # Packwiz native
        pin)               cmd_pin "${1:-}" ;;
        unpin)             cmd_unpin "${1:-}" ;;
        migrate|mig)       cmd_migrate "$@" ;;
        settings|set)      cmd_settings "$@" ;;
        import)            cmd_import "${1:-}" ;;
        detect)            cmd_detect ;;
        open)              cmd_open "${1:-}" ;;
        markdown|md)       cmd_markdown ;;

        # Verification
        doctor|doc)        cmd_doctor ;;
        verify|vf)         cmd_verify ;;
        diff|df)           cmd_diff ;;

        # Server management
        targets|t)         cmd_targets "$@" ;;
        deploy|d)          cmd_deploy "$@" ;;
        config|cfg)        cmd_config "$@" ;;
        publish)           publish_pack ;;

        # Self-update
        self-update|selfupdate|su)  cmd_self_update ;;
        update-status|us)           cmd_self_update_status ;;

        # Meta
        help|--help|-h)    cmd_help ;;
        --version|-v)      echo "PackManager v4.1.0" ;;
        *)                 echo -e "${RED}Unknown: ${cmd}${NC}"; cmd_help; exit 1 ;;
    esac
}

main "$@"
