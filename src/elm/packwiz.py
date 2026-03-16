"""Packwiz subprocess wrapper.

Runs the packwiz binary and provides safe_refresh() — the auto-hash
function that ensures every mod change updates sha256 hashes cleanly.
"""

from __future__ import annotations

import subprocess

from elm.config import Config
from elm.ui import console, _fail, _ok, _warn, _info, _hint


# ── Error translation ────────────────────────────────────────────────────
# Maps packwiz stderr patterns to user-friendly messages.

_ERROR_HINTS: list[tuple[str, str]] = [
    ("no project found", "Check the mod slug on modrinth.com — the name may differ from what you expect"),
    ("already added", "This mod is already installed. Use 'elm up' to update it instead"),
    ("already exists", "This mod is already installed. Use 'elm up' to update it instead"),
    ("no compatible version found", "This mod doesn't support your current MC version or loader"),
    ("no versions found", "This mod has no releases for your MC version/loader combination"),
    ("could not find mod", "Mod not found — double-check the slug with 'elm search'"),
    ("could not find project", "Project not found — double-check the slug with 'elm search'"),
    ("pack.toml not found", "No pack.toml found — run 'elm init' to create a modpack first"),
    ("error resolving", "Could not resolve dependencies — a required library may be missing"),
    ("rate limit", "Modrinth API rate limit hit — wait a moment and try again"),
]


def _translate_error(stderr: str) -> str | None:
    """Map packwiz stderr to a user-friendly hint, or None."""
    lower = stderr.lower()
    for pattern, hint in _ERROR_HINTS:
        if pattern in lower:
            return hint
    return None


class PackwizError(Exception):
    """Raised when a packwiz command fails."""

    def __init__(self, cmd: list[str], returncode: int, stderr: str = ""):
        self.cmd = cmd
        self.returncode = returncode
        self.stderr = stderr
        self.friendly_hint = _translate_error(stderr)
        super().__init__(f"packwiz failed (exit {returncode}): {' '.join(cmd)}")


def pw(cfg: Config, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run a packwiz command in the pack directory."""
    cmd = [cfg.packwiz_bin, "-y", *args]
    result = subprocess.run(
        cmd,
        cwd=cfg.pack_dir,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise PackwizError(cmd, result.returncode, result.stderr)
    return result


def safe_refresh(cfg: Config, *, build: bool = False) -> bool:
    """Refresh the pack index (sha256 hashes).

    Returns True on success, False on failure.  Always prints status.
    """
    args = ["refresh"]
    if build:
        args.append("--build")

    result = pw(cfg, *args, check=False)

    if result.returncode == 0:
        label = "Index built (sha256)" if build else "Index updated (sha256)"
        _ok(label)
        return True
    else:
        _fail("Index refresh failed")
        if result.stderr.strip():
            friendly = _translate_error(result.stderr)
            if friendly:
                _hint(friendly)
            else:
                for line in result.stderr.strip().splitlines()[:3]:
                    _hint(line[:120])
        return False


# ── Mod operations ────────────────────────────────────────────────────────


def add_mod(cfg: Config, slug: str, *, source: str = "") -> subprocess.CompletedProcess[str]:
    """Add a mod by slug (Modrinth/CurseForge)."""
    args = [source or cfg.prefer_source, "install", slug]
    return pw(cfg, *args)


def remove_mod(cfg: Config, slug: str) -> subprocess.CompletedProcess[str]:
    """Remove a mod."""
    return pw(cfg, "remove", slug)


def update_mod(cfg: Config, slug: str = "") -> subprocess.CompletedProcess[str]:
    """Update a mod (or all mods if slug is empty)."""
    args = ["update"]
    if slug:
        args.append(slug)
    else:
        args.append("--all")
    return pw(cfg, *args)


def list_mods(cfg: Config) -> list[str]:
    """List installed mods by reading the mods directory."""
    mods_dir = cfg.pack_dir / "mods"
    if not mods_dir.is_dir():
        return []
    names = []
    for p in mods_dir.glob("*.toml"):
        name = p.stem
        # packwiz uses .pw.toml filenames — strip the .pw suffix
        if name.endswith(".pw"):
            name = name[:-3]
        names.append(name)
    return sorted(names)


def search_mod(cfg: Config, query: str, *, source: str = "") -> str:
    """Search for mods via Modrinth API. Returns formatted results."""
    import httpx
    import urllib.parse

    mc_version = cfg.mc_version
    loader = cfg.loader

    params = {
        "query": query,
        "facets": f'[["versions:{mc_version}"],["categories:{loader}"],["project_type:mod"]]',
        "limit": "15",
    }
    url = f"https://api.modrinth.com/v2/search?{urllib.parse.urlencode(params)}"

    try:
        resp = httpx.get(url, timeout=10)
        resp.raise_for_status()
        data = resp.json()
    except httpx.ConnectError:
        return "  [red bold]FAIL[/red bold]  Could not connect — check your internet connection"
    except httpx.TimeoutException:
        return "  [red bold]FAIL[/red bold]  Search timed out — try again"
    except Exception as exc:
        return f"  [red bold]FAIL[/red bold]  Search failed: {exc}"

    hits = data.get("hits", [])
    if not hits:
        return ""

    lines = []
    for hit in hits:
        slug = hit.get("slug", "")
        title = hit.get("title", "")
        desc = hit.get("description", "")[:80]
        downloads = hit.get("downloads", 0)
        dl_str = f"{downloads:,}"
        lines.append(f"  [cyan]{slug:<30}[/cyan] {title}")
        lines.append(f"  {'':30} [dim]{desc}[/dim]")
        lines.append(f"  {'':30} [dim]{dl_str} downloads[/dim]")
        lines.append("")

    return "\n".join(lines)


def init_pack(
    cfg: Config,
    *,
    name: str = "",
    author: str = "",
    version: str = "1.0.0",
    mc_version: str = "",
    loader: str = "",
    loader_version: str = "",
) -> None:
    """Initialize a new pack by writing pack.toml and index.toml directly.

    Bypasses packwiz's interactive init which fails in non-TTY environments.
    """
    pack_name = name or cfg.pack_dir.name
    mc_ver = mc_version or cfg.mc_version
    mod_loader = loader or cfg.loader

    pack_toml = cfg.pack_dir / "pack.toml"
    index_toml = cfg.pack_dir / "index.toml"

    if pack_toml.is_file():
        raise PackwizError(["init"], 1, "pack.toml already exists in this directory")

    # Resolve loader version if not provided
    if not loader_version and mod_loader == "forge":
        loader_version = _resolve_forge_version(mc_ver)

    # Write pack.toml
    loader_line = f'{mod_loader} = "{loader_version}"' if loader_version else f'{mod_loader} = ""'
    pack_toml.write_text(
        f'name = "{pack_name}"\n'
        f'author = "{author}"\n'
        f'version = "{version}"\n'
        f'pack-format = "packwiz:1.1.0"\n'
        f'\n'
        f'[index]\n'
        f'file = "index.toml"\n'
        f'hash-format = "sha256"\n'
        f'\n'
        f'[versions]\n'
        f'minecraft = "{mc_ver}"\n'
        f'{loader_line}\n'
    )

    # Write index.toml
    index_toml.write_text('hash-format = "sha256"\n')

    # Create mods directory
    (cfg.pack_dir / "mods").mkdir(exist_ok=True)


def _resolve_forge_version(mc_version: str) -> str:
    """Try to resolve the recommended Forge version for a MC version."""
    import httpx

    try:
        resp = httpx.get(
            "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json",
            timeout=10,
        )
        resp.raise_for_status()
        promos = resp.json().get("promos", {})
        # Try recommended first, then latest
        for suffix in ("recommended", "latest"):
            key = f"{mc_version}-{suffix}"
            if key in promos:
                return promos[key]
    except Exception:
        pass
    return ""


def export_pack(cfg: Config) -> subprocess.CompletedProcess[str]:
    """Export the pack (builds for distribution)."""
    return pw(cfg, "curseforge", "export")


# ── Sync from mods.txt ───────────────────────────────────────────────────


def sync_from_modsfile(cfg: Config) -> tuple[int, int, list[str]]:
    """Sync mods from mods.txt — add missing, report results.

    Returns (added_count, skipped_count, failed_slugs).
    """
    mods_file = cfg.mods_file
    if not mods_file.is_file():
        return 0, 0, []

    lines = [
        ln.strip()
        for ln in mods_file.read_text().splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]

    installed = set(list_mods(cfg))
    added = 0
    skipped = 0
    failed: list[str] = []

    for slug in lines:
        if slug in installed:
            skipped += 1
            continue
        try:
            add_mod(cfg, slug)
            added += 1
        except PackwizError:
            failed.append(slug)

    return added, skipped, failed
