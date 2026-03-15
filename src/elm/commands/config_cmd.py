"""Configuration view/edit commands."""

from __future__ import annotations

import typer
from rich.table import Table

from elm.config import DEFAULTS, load_config
from elm.ui import console, _ok

config_app = typer.Typer(help="View and edit configuration.")

CONFIG_CATEGORIES = {
    "Minecraft": ["MC_VERSION", "LOADER", "LOADER_VERSION"],
    "Mod Sources": ["PREFER_SOURCE", "AUTO_DEPS", "AUTO_PUBLISH"],
    "Server": ["SERVER_IMAGE", "SERVER_RAM", "SERVER_DISK", "SERVER_CPU",
               "SERVER_BASE_PORT", "SERVER_RCON_BASE_PORT", "SERVER_DOMAIN",
               "SERVER_VM_IP"],
    "Pelican": ["PELICAN_URL", "PELICAN_NODE_ID", "PELICAN_EGG_ID",
                "PELICAN_USER_ID", "PELICAN_NEST_ID"],
    "CDN": ["CDN_DOMAIN", "CDN_COMPOSE_DIR", "PACK_HOST_URL"],
    "Updates": ["ELM_GITHUB_REPO", "ELM_GITHUB_BRANCH", "ELM_GITHUB_PATH",
                "ELM_UPDATE_FILES"],
    "Network": ["RETRY_ATTEMPTS", "RETRY_DELAY"],
    "Local Mods": ["LOCAL_MODS_DIR", "LOCAL_MODS_URL"],
}


@config_app.command()
def show() -> None:
    """Show current configuration."""
    cfg = load_config()

    for category, keys in CONFIG_CATEGORIES.items():
        has_values = any(cfg.get(k) for k in keys)
        if not has_values:
            continue

        table = Table(
            title=category,
            title_style="bold",
            border_style="dim",
            show_header=False,
            padding=(0, 1),
        )
        table.add_column("Key", style="cyan", min_width=25)
        table.add_column("Value")
        table.add_column("", width=10)

        for k in keys:
            v = cfg.values.get(k, "")
            if "KEY" in k or "TOKEN" in k:
                v = cfg.mask_key(k) or ""

            default = DEFAULTS.get(k, "")
            marker = "[dim]default[/dim]" if v == default and v else ""

            display = v if v else "[dim]—[/dim]"
            table.add_row(k, display, marker)

        console.print()
        console.print(table)


@config_app.command(name="set")
def config_set(
    key: str = typer.Argument(..., help="Config key"),
    value: str = typer.Argument(..., help="New value"),
) -> None:
    """Set a global config value."""
    cfg = load_config()
    cfg.set_global(key.upper(), value)
    _ok(f"{key.upper()} = {value}")


@config_app.command()
def get(
    key: str = typer.Argument(..., help="Config key"),
) -> None:
    """Get a config value."""
    cfg = load_config()
    val = cfg.get(key.upper())
    if val:
        console.print(f"  {key.upper()} = {val}")
    else:
        console.print(f"  {key.upper()} [dim]not set[/dim]")
