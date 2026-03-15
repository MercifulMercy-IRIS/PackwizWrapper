"""Pack management commands — init, refresh."""

from __future__ import annotations

import sys

import typer

from elm.config import load_config
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header

pack_app = typer.Typer(help="Pack management commands.")


@pack_app.command()
def init() -> None:
    """Initialize a new packwiz-compatible modpack."""
    from elm.core.packwiz import write_pack_toml, write_index_toml

    cfg = load_config()
    _header("Initializing Pack")

    if cfg.pack_toml.is_file():
        _warn("pack.toml already exists")
        _hint(f"At: {cfg.pack_toml}")
        if not typer.confirm("  Overwrite?", default=False):
            return

    name = cfg.pack_dir.name
    with console.status("  Creating pack..."):
        write_pack_toml(
            cfg.pack_dir,
            name=name,
            mc_version=cfg.mc_version,
            loader=cfg.loader,
            loader_version=cfg.get("LOADER_VERSION"),
        )
        write_index_toml(cfg.pack_dir)

    # Create mods directory
    (cfg.pack_dir / "mods").mkdir(parents=True, exist_ok=True)

    _ok(f"Pack initialized: [cyan]{name}[/cyan]")
    _info(f"MC {cfg.mc_version} / {cfg.loader}")
    _hint(f"pack.toml at: {cfg.pack_toml}")
    _hint("Next: elm add <mod-slug>")


@pack_app.command()
def refresh(
    build: bool = typer.Option(False, "-b", "--build", help="Build for distribution"),
) -> None:
    """Refresh pack index (regenerate sha256 hashes)."""
    from elm.core.packwiz import refresh_index

    cfg = load_config()
    _header("Refreshing Pack Index")

    if not cfg.pack_toml.is_file():
        _fail("No pack.toml found")
        _hint("Initialize with: elm init")
        sys.exit(1)

    ok = refresh_index(cfg.pack_dir)
    if ok:
        label = "Index built (sha256)" if build else "Index updated (sha256)"
        _ok(label)
    else:
        _fail("Index refresh failed")
        sys.exit(1)
