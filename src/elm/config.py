"""Configuration loader — reads elm.conf, keys.conf, targets.json.

Preserves the existing three-level priority: local > global > defaults.
Config files are bash-style KEY="value" pairs, sourced by both bash and Python.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ── Defaults ──────────────────────────────────────────────────────────────

DEFAULTS: dict[str, str] = {
    "MC_VERSION": "1.20.1",
    "LOADER": "forge",
    "LOADER_VERSION": "",
    "PREFER_SOURCE": "mr",
    "RETRY_ATTEMPTS": "2",
    "RETRY_DELAY": "3",
    "AUTO_DEPS": "true",
    "AUTO_PUBLISH": "",
    # Server
    "SERVER_IMAGE": "",
    "SERVER_RAM": "8192",
    "SERVER_DISK": "25600",
    "SERVER_CPU": "400",
    "SERVER_BASE_PORT": "25565",
    "SERVER_RCON_BASE_PORT": "25575",
    "SERVER_DOMAIN": "",
    "SERVER_VM_IP": "",
    # Pelican
    "PELICAN_URL": "",
    "PELICAN_NODE_ID": "",
    "PELICAN_EGG_ID": "",
    "PELICAN_USER_ID": "",
    "PELICAN_NEST_ID": "",
    # CDN / Pack hosting
    "CDN_DOMAIN": "",
    "CDN_COMPOSE_DIR": str(Path.home() / ".config" / "elm" / "servers"),
    "PACK_HOST_URL": "",
    # Self-update
    "ELM_GITHUB_REPO": "",
    "ELM_GITHUB_BRANCH": "main",
    "ELM_GITHUB_PATH": "",
    "ELM_UPDATE_FILES": "elm.sh install.sh elm.conf mods.txt",
    # Local mods
    "LOCAL_MODS_DIR": "",
    "LOCAL_MODS_URL": "",
    # CurseForge
    "CURSEFORGE_API_KEY": "",
}

# Legacy PM_ prefix → ELM_ equivalents (backwards compatibility)
_LEGACY_ALIASES: dict[str, str] = {
    "PM_GITHUB_REPO": "ELM_GITHUB_REPO",
    "PM_GITHUB_BRANCH": "ELM_GITHUB_BRANCH",
    "PM_GITHUB_PATH": "ELM_GITHUB_PATH",
    "PM_UPDATE_FILES": "ELM_UPDATE_FILES",
}

CONFIG_DIR = Path.home() / ".config" / "elm"
KEYS_FILE = CONFIG_DIR / "keys.conf"
TARGETS_FILE = CONFIG_DIR / "targets.json"
DNS_CONF = CONFIG_DIR / "dns.conf"


def _parse_bash_conf(path: Path) -> dict[str, str]:
    """Parse a bash-style config file (KEY="value" or KEY=value)."""
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z_0-9]*)=(.*)$', line)
        if not m:
            continue
        key = m.group(1)
        raw = m.group(2).strip()
        # Strip surrounding quotes
        if (raw.startswith('"') and raw.endswith('"')) or \
           (raw.startswith("'") and raw.endswith("'")):
            raw = raw[1:-1]
        result[key] = raw
    return result


def _write_bash_conf_key(path: Path, key: str, value: str) -> None:
    """Set a single key in a bash-style config file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    found = False
    if path.is_file():
        for line in path.read_text().splitlines():
            if re.match(rf'^{re.escape(key)}=', line):
                lines.append(f'{key}="{value}"')
                found = True
            else:
                lines.append(line)
    if not found:
        lines.append(f'{key}="{value}"')
    path.write_text("\n".join(lines) + "\n")


# ── Config dataclass ──────────────────────────────────────────────────────

@dataclass
class Config:
    """Merged configuration from all sources."""

    values: dict[str, str] = field(default_factory=dict)
    pack_dir: Path = field(default_factory=Path.cwd)
    log_dir: Path = field(default_factory=lambda: Path.cwd() / ".logs")
    run_log: Path | None = None

    # Convenience accessors
    @property
    def mc_version(self) -> str:
        return self.get("MC_VERSION")

    @property
    def loader(self) -> str:
        return self.get("LOADER")

    @property
    def prefer_source(self) -> str:
        return self.get("PREFER_SOURCE")

    @property
    def pelican_url(self) -> str:
        return self.get("PELICAN_URL")

    @property
    def pelican_api_key(self) -> str:
        return self.get("PELICAN_API_KEY")

    @property
    def pelican_node_id(self) -> str:
        return self.get("PELICAN_NODE_ID")

    @property
    def pelican_egg_id(self) -> str:
        return self.get("PELICAN_EGG_ID")

    @property
    def pelican_user_id(self) -> str:
        return self.get("PELICAN_USER_ID")

    @property
    def cdn_domain(self) -> str:
        return self.get("CDN_DOMAIN")

    @property
    def server_ram(self) -> int:
        return int(self.get("SERVER_RAM") or "8192")

    @property
    def server_disk(self) -> int:
        return int(self.get("SERVER_DISK") or "25600")

    @property
    def server_cpu(self) -> int:
        return int(self.get("SERVER_CPU") or "400")

    @property
    def server_domain(self) -> str:
        return self.get("SERVER_DOMAIN")

    @property
    def server_vm_ip(self) -> str:
        return self.get("SERVER_VM_IP")

    @property
    def mods_file(self) -> Path:
        return self.pack_dir / "mods.txt"

    @property
    def unresolved_file(self) -> Path:
        return self.pack_dir / "unresolved.txt"

    @property
    def pack_toml(self) -> Path:
        return self.pack_dir / "pack.toml"

    def get(self, key: str, default: str = "") -> str:
        return self.values.get(key, default)

    def set_global(self, key: str, value: str) -> None:
        """Write a key to the global config file."""
        global_conf = CONFIG_DIR / "elm.conf"
        _write_bash_conf_key(global_conf, key, value)
        self.values[key] = value

    def set_key(self, key: str, value: str) -> None:
        """Write a key to keys.conf (sensitive data)."""
        _write_bash_conf_key(KEYS_FILE, key, value)
        KEYS_FILE.chmod(0o600)
        self.values[key] = value

    def get_key(self, key: str) -> str:
        """Read a key from keys.conf."""
        return self.values.get(key, "")

    def mask_key(self, key: str) -> str:
        """Return a masked version of a key value for display."""
        val = self.get_key(key)
        if not val:
            return ""
        if len(val) <= 8:
            return val[:2] + "***"
        return val[:4] + "..." + val[-4:]


def discover_pack_dir(start: Path) -> Path:
    """Find the pack directory containing pack.toml."""
    # Direct
    if (start / "pack.toml").is_file():
        return start
    # pack/ subdirectory
    if (start / "pack" / "pack.toml").is_file():
        return start / "pack"
    # Sibling pack/ (when in server/ or cdn/)
    if start.name in ("server", "cdn"):
        sibling = start.parent / "pack"
        if (sibling / "pack.toml").is_file():
            return sibling
    # Walk up 3 levels
    walk = start
    for _ in range(3):
        walk = walk.parent
        if walk == Path("/"):
            break
        if (walk / "pack.toml").is_file():
            return walk
        if (walk / "pack" / "pack.toml").is_file():
            return walk / "pack"
    return start


def _apply_legacy_aliases(values: dict[str, str]) -> None:
    """Map old PM_ prefixed keys to their ELM_ equivalents."""
    for old_key, new_key in _LEGACY_ALIASES.items():
        if old_key in values and not values.get(new_key):
            values[new_key] = values[old_key]


def load_config(cwd: Path | None = None) -> Config:
    """Load configuration with full priority cascade."""
    cwd = cwd or Path.cwd()

    # Start with defaults
    values = dict(DEFAULTS)

    # Load global config — try elm.conf, fall back to packmanager.conf
    global_conf = CONFIG_DIR / "elm.conf"
    if not global_conf.is_file():
        pm_conf = CONFIG_DIR / "packmanager.conf"
        if pm_conf.is_file():
            global_conf = pm_conf
    values.update(_parse_bash_conf(global_conf))

    # Load local config (in cwd) — try elm.conf, fall back to packmanager.conf
    local_conf = cwd / "elm.conf"
    if not local_conf.is_file():
        pm_local = cwd / "packmanager.conf"
        if pm_local.is_file():
            local_conf = pm_local
    values.update(_parse_bash_conf(local_conf))

    # Load keys
    values.update(_parse_bash_conf(KEYS_FILE))

    # Load DNS config
    values.update(_parse_bash_conf(DNS_CONF))

    # Discover pack directory
    pack_dir = discover_pack_dir(cwd)

    # If pack dir has its own elm.conf, load it too
    pack_conf = pack_dir / "elm.conf"
    if pack_conf.is_file() and pack_conf != local_conf:
        values.update(_parse_bash_conf(pack_conf))

    # Apply legacy PM_ → ELM_ aliases
    _apply_legacy_aliases(values)

    # Setup logging
    log_dir = pack_dir / ".logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    from datetime import datetime
    run_log = log_dir / f"run_{datetime.now():%Y%m%d_%H%M%S}.log"

    return Config(
        values=values,
        pack_dir=pack_dir,
        log_dir=log_dir,
        run_log=run_log,
    )


# ── Targets ───────────────────────────────────────────────────────────────

def load_targets() -> dict[str, dict[str, Any]]:
    """Load targets.json registry."""
    TARGETS_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not TARGETS_FILE.is_file():
        TARGETS_FILE.write_text("{}\n")
        return {}
    return json.loads(TARGETS_FILE.read_text())


def save_targets(targets: dict[str, dict[str, Any]]) -> None:
    """Write targets.json."""
    TARGETS_FILE.parent.mkdir(parents=True, exist_ok=True)
    TARGETS_FILE.write_text(json.dumps(targets, indent=2) + "\n")


def target_get(name: str, field: str) -> str | None:
    """Get a single field from a target."""
    targets = load_targets()
    t = targets.get(name, {})
    val = t.get(field)
    if val is None or val == "null":
        return None
    return str(val)


def target_set(name: str, **fields: Any) -> None:
    """Set fields on a target."""
    targets = load_targets()
    if name not in targets:
        targets[name] = {}
    targets[name].update(fields)
    save_targets(targets)


def target_remove(name: str) -> None:
    """Remove a target from the registry."""
    targets = load_targets()
    targets.pop(name, None)
    save_targets(targets)


def target_list() -> list[str]:
    """List all target names."""
    return list(load_targets().keys())
