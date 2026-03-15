"""ELM CLI — Typer-based entry point.

Usage:
    elm                        Interactive menu
    elm add <slug>             Add a mod
    elm rm <slug>              Remove a mod
    elm update [slug]          Update mod(s)
    elm sync                   Sync mods from mods.txt
    elm ls                     List installed mods
    elm search <query>         Search for mods
    elm init                   Initialize a new pack
    elm refresh [--build]      Refresh pack index (sha256)
    elm deploy <sub>           Server management via Pelican Panel
    elm key <provider> <token> Store API keys
    elm config show            Show current configuration
    elm check                  Run diagnostics
"""

from __future__ import annotations

import sys

import typer
from rich.panel import Panel

from elm import __version__
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header


# ── Main app ──────────────────────────────────────────────────────────────

app = typer.Typer(
    name="elm",
    help="ELM — EnviousLabs Minecraft CLI",
    invoke_without_command=True,
    no_args_is_help=False,
    add_completion=False,
    pretty_exceptions_enable=False,
)


def version_callback(value: bool) -> None:
    if value:
        console.print(f"elm v{__version__}")
        raise typer.Exit()


@app.callback(invoke_without_command=True)
def callback(
    ctx: typer.Context,
    version: bool = typer.Option(
        False, "--version", "-v", help="Show version", callback=version_callback, is_eager=True
    ),
) -> None:
    """ELM — EnviousLabs Minecraft CLI."""
    if ctx.invoked_subcommand is None:
        from elm.config import load_config
        from elm.menu import run_menu
        try:
            cfg = load_config()
        except Exception as exc:
            _fail(f"Could not load config: {exc}")
            raise typer.Exit(1)
        run_menu(cfg)


# ── Register command groups ──────────────────────────────────────────────

from elm.commands.mod import mod_app
from elm.commands.pack import pack_app
from elm.commands.deploy import deploy_app
from elm.commands.target import target_app
from elm.commands.key import key_app
from elm.commands.config_cmd import config_app
from elm.commands.deps import deps_app

# Register sub-apps as groups
app.add_typer(deploy_app, name="deploy")
app.add_typer(target_app, name="target")
app.add_typer(key_app, name="key")
app.add_typer(config_app, name="config")
app.add_typer(deps_app, name="deps")
app.add_typer(pack_app, name="pack")


# ── Top-level mod commands (mounted directly) ────────────────────────────

from elm.commands.mod import add, rm, update, list_mods, search, sync

app.command()(add)
app.command()(rm)
app.command(name="up")(update)
app.command(name="ls")(list_mods)
app.command()(search)
app.command()(sync)

# Pack commands as top-level aliases
from elm.commands.pack import init, refresh

app.command()(init)
app.command()(refresh)


# ── Self-update ───────────────────────────────────────────────────────────

@app.command(name="update")
def self_update(
    check_only: bool = typer.Option(False, "--check-only", help="Only check, don't install"),
) -> None:
    """Self-update ELM from GitHub (Python package + scripts)."""
    from elm.config import load_config
    from elm.updater import check_for_update, run_full_update, print_result

    cfg = load_config()
    _header("Self-Update")

    repo = cfg.get("ELM_GITHUB_REPO")
    if not repo:
        _fail("ELM_GITHUB_REPO not set.")
        _hint("Set it: elm config set ELM_GITHUB_REPO youruser/repo")
        return

    branch = cfg.get("ELM_GITHUB_BRANCH") or "main"
    _info(f"Repo: [cyan]{repo}[/cyan]  Branch: [cyan]{branch}[/cyan]")

    if check_only:
        with console.status("  Checking for updates..."):
            versions = check_for_update(cfg)
        if versions:
            local, remote = versions
            _info(f"Installed: {local}")
            _ok(f"Available: [bold]{remote}[/bold]")
            _hint("Run [cyan]elm update[/cyan] to install")
        else:
            _ok(f"Already up to date (v{__version__})")
        return

    with console.status("  Updating ELM..."):
        result = run_full_update(cfg)
    print_result(result)


# ── Diagnostics ───────────────────────────────────────────────────────────

@app.command()
def check() -> None:
    """Run diagnostics."""
    import shutil
    from elm.config import load_config, target_list

    cfg = load_config()
    _header("ELM Diagnostics")
    console.print()

    _info(f"ELM v{__version__}")

    # pack.toml
    if cfg.pack_toml.is_file():
        _ok(f"pack.toml: [dim]{cfg.pack_toml}[/dim]")
    else:
        _warn("No pack.toml found")
        _hint("Initialize with: elm init")

    # mods.txt
    if cfg.mods_file.is_file():
        lines = [ln for ln in cfg.mods_file.read_text().splitlines()
                 if ln.strip() and not ln.startswith("#")]
        _ok(f"mods.txt: {len(lines)} entries")
    else:
        _info("No mods.txt [dim](optional)[/dim]")

    # Installed mods
    from elm.core.packwiz import list_mod_tomls
    mods = list_mod_tomls(cfg.pack_dir)
    if mods:
        _ok(f"Installed mods: {len(mods)}")
    else:
        _info("No mods installed")

    # Pelican
    console.print()
    if cfg.pelican_url:
        _ok(f"Pelican URL: [dim]{cfg.pelican_url}[/dim]")
        if cfg.pelican_api_key:
            from elm.core.pelican import PelicanClient
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=cfg.pelican_api_key)
            with console.status("  Testing Pelican connection..."):
                connected = client.test_connection()
            if connected:
                _ok("Pelican Panel: connected")
            else:
                _warn("Pelican Panel: could not connect")
        else:
            _warn("Pelican API key not set")
            _hint("Set with: elm key set pelican")
    else:
        _info("Pelican: not configured [dim](optional)[/dim]")
        _hint("Set up with: elm deploy setup")

    # Targets
    names = target_list()
    if names:
        _ok(f"Targets: {len(names)} configured ({', '.join(names)})")
    else:
        _info("No targets configured")

    console.print()


# ── Backwards-compat aliases ──────────────────────────────────────────────

app.command(name="remove")(rm)
app.command(name="list")(list_mods)


# ── Entry point ───────────────────────────────────────────────────────────

def main() -> None:
    """Wrapper that catches unexpected errors."""
    try:
        app()
    except KeyboardInterrupt:
        console.print("\n  [dim]Interrupted.[/dim]")
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as exc:
        console.print(f"\n  [red bold]FAIL[/red bold]  {exc}")
        console.print("         [dim]This is a bug — please report it.[/dim]")
        sys.exit(1)
