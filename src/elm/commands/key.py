"""API key management commands."""

from __future__ import annotations

from typing import Optional

import typer
from rich.table import Table

from elm.config import load_config
from elm.ui import console, _fail, _ok, _warn

key_app = typer.Typer(help="Manage API keys.")


@key_app.command(name="set")
def key_set(
    provider: str = typer.Argument(..., help="Provider: pelican or curseforge"),
    token: Optional[str] = typer.Argument(None, help="API key (prompted if omitted)"),
) -> None:
    """Store an API key."""
    provider = provider.lower()
    if provider not in ("pelican", "curseforge"):
        _fail("Provider must be 'pelican' or 'curseforge'")
        raise typer.Exit(1)

    cfg = load_config()
    if token is None:
        token = typer.prompt(f"  {provider.title()} API key", hide_input=True)

    key_map = {
        "pelican": "PELICAN_API_KEY",
        "curseforge": "CURSEFORGE_API_KEY",
    }
    cfg.set_key(key_map[provider], token)
    _ok(f"{provider.title()} API key saved")

    # Test Pelican connection
    if provider == "pelican" and cfg.pelican_url:
        from elm.core.pelican import PelicanClient

        with console.status("  Verifying connection..."):
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=token)
            ok = client.test_connection()
        if ok:
            _ok("Connection verified")
        else:
            _warn("Could not reach panel — check URL and key")


@key_app.command()
def show() -> None:
    """Show stored keys (masked)."""
    cfg = load_config()

    table = Table(border_style="dim", show_header=False, padding=(0, 1))
    table.add_column("Provider", style="bold")
    table.add_column("Key")

    for label, key_name in [("Pelican", "PELICAN_API_KEY"), ("CurseForge", "CURSEFORGE_API_KEY")]:
        masked = cfg.mask_key(key_name)
        val = masked if masked else "[dim]not set[/dim]"
        table.add_row(label, val)

    console.print()
    console.print(table)


@key_app.command()
def rm(
    provider: str = typer.Argument(..., help="Provider: pelican or curseforge"),
) -> None:
    """Remove an API key."""
    provider = provider.lower()
    if provider not in ("pelican", "curseforge"):
        _fail("Provider must be 'pelican' or 'curseforge'")
        raise typer.Exit(1)

    cfg = load_config()
    key_map = {"pelican": "PELICAN_API_KEY", "curseforge": "CURSEFORGE_API_KEY"}
    cfg.set_key(key_map[provider], "")
    _ok(f"{provider.title()} API key removed")
