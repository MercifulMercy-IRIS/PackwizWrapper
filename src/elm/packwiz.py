"""Packwiz subprocess wrapper.

Runs the packwiz binary and provides safe_refresh() — the auto-hash
function that ensures every mod change updates sha256 hashes cleanly.
"""

from __future__ import annotations

import subprocess

from rich.console import Console

from elm.config import Config

console = Console()


class PackwizError(Exception):
    """Raised when a packwiz command fails."""

    def __init__(self, cmd: list[str], returncode: int, stderr: str = ""):
        self.cmd = cmd
        self.returncode = returncode
        self.stderr = stderr
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
        console.print(f"  [green]OK[/green] {label}")
        return True
    else:
        console.print("  [red]FAIL[/red] Index refresh failed")
        if result.stderr.strip():
            for line in result.stderr.strip().splitlines()[:5]:
                console.print(f"       [dim]{line}[/dim]")
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
    except Exception:
        return ""

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


def init_pack(cfg: Config) -> subprocess.CompletedProcess[str]:
    """Initialize a new pack."""
    return pw(cfg, "init",
              "--name", cfg.pack_dir.name,
              "--mc-version", cfg.mc_version,
              "--modloader", cfg.loader)


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
