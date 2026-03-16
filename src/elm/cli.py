"""ELM CLI — click-based entry point.

Usage:
    elm add <slug>          Add a mod
    elm rm <slug>           Remove a mod
    elm update [slug]       Update mod(s)
    elm sync                Sync mods from mods.txt
    elm ls                  List installed mods
    elm search <query>      Search for mods
    elm refresh [--build]   Refresh pack index (sha256)
    elm init                Initialize a new pack
    elm deploy <sub>        Server management via Pelican Panel
    elm cdn <sub>           Pack hosting via Caddy reverse proxy
    elm key <provider> <token>  Store API keys
    elm config show         Show current configuration
    elm check               Run diagnostics
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import click
from rich.panel import Panel
from rich.table import Table

from elm import __version__
from elm.config import (
    Config,
    load_config,
    load_packs,
    load_targets,
    pack_get_path,
    pack_list,
    pack_register,
    pack_remove,
    target_list,
    target_remove,
    target_set,
)
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header


def _get_cfg(ctx: click.Context) -> Config:
    return ctx.obj


def _require_pack(cfg: Config) -> bool:
    """Check that pack.toml exists, printing guidance if not. Returns True if OK."""
    if cfg.pack_toml.is_file():
        return True
    _fail("No pack.toml found — you need to create a modpack first")
    _hint("Run: elm init")
    return False


# ── Custom help formatter ─────────────────────────────────────────────────


class ElmGroup(click.Group):
    """Custom group that shows a branded help screen with fuzzy matching."""

    def resolve_command(self, ctx: click.Context, args: list[str]) -> tuple:
        """Suggest corrections for mistyped commands."""
        import difflib

        cmd_name = args[0] if args else None
        if cmd_name and cmd_name not in self.commands:
            matches = difflib.get_close_matches(cmd_name, self.commands.keys(), n=1, cutoff=0.5)
            if matches:
                _hint(f"Unknown command '{cmd_name}'. Did you mean: elm {matches[0]}?")
        return super().resolve_command(ctx, args)

    def format_help(self, ctx: click.Context, formatter: click.HelpFormatter) -> None:
        console.print(
            Panel(
                "[bold cyan]ELM[/bold cyan]  [dim]—[/dim]  EnviousLabs Minecraft CLI\n"
                f"[dim]v{__version__}[/dim]",
                border_style="cyan",
                padding=(0, 2),
            )
        )

        sections = {
            "Mods": [
                ("add <slug...>", "Add one or more mods"),
                ("rm <slug...>", "Remove mods"),
                ("up [slug]", "Update one or all mods"),
                ("sync", "Sync mods from mods.txt"),
                ("ls", "List installed mods"),
                ("search <query>", "Search for mods"),
            ],
            "Pack": [
                ("init", "Initialize a new packwiz pack"),
                ("refresh [--build]", "Refresh pack index (sha256)"),
                ("update", "Self-update ELM from GitHub"),
            ],
            "Servers": [
                ("deploy setup", "Interactive Pelican Panel setup"),
                ("deploy create -t NAME", "Create a server"),
                ("deploy start/stop/restart -t NAME", "Power control"),
                ("deploy status -t NAME", "Server status & resources"),
                ("deploy console -t NAME CMD", "Send console command"),
                ("deploy backup -t NAME", "Create a backup"),
                ("deploy remove -t NAME", "Delete a server"),
            ],
            "CDN": [
                ("cdn setup", "Generate Caddy reverse proxy config"),
                ("cdn start", "Start pack hosting server"),
                ("cdn stop", "Stop pack hosting server"),
                ("cdn status", "Check CDN status"),
            ],
            "Client": [
                ("client setup [-d DIR]", "Generate Prism pre-launch scripts"),
                ("client info", "Show pack URL for clients"),
            ],
            "Dependencies": [
                ("deps check", "Check all dependencies"),
                ("deps install <name>", "Install a dependency (go, packwiz, curl, jq, git, docker)"),
                ("deps ls", "List dependencies and status"),
            ],
            "Config": [
                ("pack register/ls/rm", "Manage pack directories"),
                ("target add/ls/rm/show", "Manage deployment targets"),
                ("key set/show/rm", "Manage API keys"),
                ("config show/set/get", "View & edit configuration"),
                ("check", "Run diagnostics"),
                ("-p NAME <command>", "Run against a registered pack"),
            ],
        }

        for section, cmds in sections.items():
            console.print(f"\n  [bold]{section}[/bold]")
            for cmd, desc in cmds:
                from rich.markup import escape
                padded = f"elm {cmd}".ljust(39)
                console.print(f"    [cyan]{escape(padded)}[/cyan] {desc}")

        console.print("\n  [dim]Run[/dim] elm <command> --help [dim]for details[/dim]\n")


class SubGroup(click.Group):
    """Subgroup that shows help when invoked without a subcommand."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        kwargs.setdefault("invoke_without_command", True)
        super().__init__(*args, **kwargs)

    def invoke(self, ctx: click.Context) -> None:
        super().invoke(ctx)
        if not ctx.invoked_subcommand:
            console.print(ctx.get_help())


# ── Main group ────────────────────────────────────────────────────────────


@click.group(cls=ElmGroup, invoke_without_command=True)
@click.version_option(__version__, prog_name="elm")
@click.option("-p", "--pack", "pack_name", default="", help="Use a registered pack by name")
@click.pass_context
def main(ctx: click.Context, pack_name: str) -> None:
    """ELM — EnviousLabs Minecraft CLI."""
    try:
        cwd = None
        if pack_name:
            cwd = pack_get_path(pack_name)
            if not cwd:
                _fail(f"Pack [cyan]{pack_name}[/cyan] not found in registry")
                _hint("List packs: elm pack ls")
                ctx.exit(1)
                return
        ctx.obj = load_config(cwd=cwd)
    except Exception as exc:
        _fail(f"Could not load config: {exc}")
        ctx.exit(1)
    if ctx.invoked_subcommand is None:
        from elm.menu import run_menu
        run_menu(ctx.obj)


# Global error handler — catch uncaught exceptions so users never see raw tracebacks
_original_main = main

def main() -> None:  # noqa: F811
    """Wrapper that catches unexpected errors."""
    try:
        _original_main(standalone_mode=False)
    except click.exceptions.Abort:
        console.print("\n  [dim]Aborted.[/dim]")
        sys.exit(130)
    except click.exceptions.Exit as exc:
        sys.exit(exc.exit_code)
    except click.ClickException as exc:
        console.print(f"\n  [red bold]FAIL[/red bold]  {exc.format_message()}")
        sys.exit(exc.exit_code)
    except KeyboardInterrupt:
        console.print("\n  [dim]Interrupted.[/dim]")
        sys.exit(130)
    except Exception as exc:
        console.print(f"\n  [red bold]FAIL[/red bold]  {exc}")
        console.print("         [dim]This is a bug — please report it.[/dim]")
        sys.exit(1)


# ── Mod commands ──────────────────────────────────────────────────────────


@_original_main.command()
@click.argument("slugs", nargs=-1, required=True)
@click.option("-s", "--source", default="", help="Source: mr (Modrinth) or cf (CurseForge)")
@click.pass_context
def add(ctx: click.Context, slugs: tuple[str, ...], source: str) -> None:
    """Add one or more mods.

    \b
    Examples:
      elm add sodium
      elm add jei create waystones
      elm add sodium -s mr
    """
    from elm.packwiz import add_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    _header("Adding Mods")

    ok_count = 0
    fail_count = 0
    for slug in slugs:
        try:
            with console.status(f"  Installing [cyan]{slug}[/cyan]..."):
                add_mod(cfg, slug, source=source)
            _ok(f"Added [cyan]{slug}[/cyan]")
            ok_count += 1
        except PackwizError as e:
            _fail(f"Could not add [cyan]{slug}[/cyan]")
            fail_count += 1
            if e.friendly_hint:
                _hint(e.friendly_hint)
            elif e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[0][:120])

    if ok_count > 0:
        safe_refresh(cfg)

    # Summary for multi-mod operations
    if len(slugs) > 1:
        console.print()
        _info(f"{ok_count} added, {fail_count} failed")


@_original_main.command()
@click.argument("slugs", nargs=-1, required=True)
@click.pass_context
def rm(ctx: click.Context, slugs: tuple[str, ...]) -> None:
    """Remove one or more mods.

    \b
    Examples:
      elm rm sodium
      elm rm jei create waystones
    """
    from elm.packwiz import remove_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    _header("Removing Mods")

    ok_count = 0
    for slug in slugs:
        try:
            remove_mod(cfg, slug)
            _ok(f"Removed [cyan]{slug}[/cyan]")
            ok_count += 1
        except PackwizError as e:
            _fail(f"Could not remove [cyan]{slug}[/cyan]")
            if e.friendly_hint:
                _hint(e.friendly_hint)
            elif e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[0][:120])

    if ok_count > 0:
        safe_refresh(cfg)


@_original_main.command(name="up")
@click.argument("slug", required=False, default="")
@click.pass_context
def up(ctx: click.Context, slug: str) -> None:
    """Update a mod, or all mods.

    \b
    Examples:
      elm up           Update all mods
      elm up sodium    Update just sodium
    """
    from elm.packwiz import update_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    label = f"Updating {slug}" if slug else "Updating All Mods"
    _header(label)

    try:
        with console.status("  Checking for updates..."):
            update_mod(cfg, slug)
        _ok("Update complete")
    except PackwizError as e:
        _fail("Update failed")
        if e.friendly_hint:
            _hint(e.friendly_hint)
        elif e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[0][:120])
        return

    safe_refresh(cfg)


@_original_main.command(name="ls")
@click.pass_context
def list_mods(ctx: click.Context) -> None:
    """List installed mods."""
    from elm.packwiz import list_mods as _list

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    mods = _list(cfg)

    if not mods:
        _header("Installed Mods")
        _info("No mods installed yet.")
        _hint("Get started:  elm add <mod-slug>")
        _hint("Or sync:      elm sync   (reads from mods.txt)")
        return

    table = Table(
        title=f"Installed Mods ({len(mods)})",
        show_lines=False,
        border_style="dim",
        title_style="bold",
        padding=(0, 1),
    )
    table.add_column("#", style="dim", width=4, justify="right")
    table.add_column("Mod", style="cyan")
    for i, name in enumerate(mods, 1):
        table.add_row(str(i), name)
    console.print()
    console.print(table)


@_original_main.command()
@click.argument("query")
@click.option("-s", "--source", default="", help="Source: mr or cf")
@click.pass_context
def search(ctx: click.Context, query: str, source: str) -> None:
    """Search for mods."""
    from elm.packwiz import search_mod

    cfg = _get_cfg(ctx)
    with console.status(f"  Searching for [cyan]{query}[/cyan]..."):
        output = search_mod(cfg, query, source=source)
    if output.strip():
        console.print(output)
    else:
        _info(f"No results for [cyan]{query}[/cyan]")
        _hint("Try a different query or check the source (-s mr / -s cf)")


@_original_main.command()
@click.pass_context
def sync(ctx: click.Context) -> None:
    """Sync mods from mods.txt — installs missing mods, skips existing ones."""
    from elm.packwiz import sync_from_modsfile, safe_refresh

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    _header("Syncing from mods.txt")

    if not cfg.mods_file.is_file():
        _fail(f"No mods.txt found at [dim]{cfg.mods_file}[/dim]")
        _hint("Create a mods.txt with one mod slug per line")
        return

    with console.status("  Syncing mods..."):
        added, skipped, failed = sync_from_modsfile(cfg)

    if added:
        _ok(f"Added {added} new mod{'s' if added != 1 else ''}")
    if skipped:
        _info(f"Skipped {skipped} already installed")
    if failed:
        _warn(f"Failed to add: {', '.join(failed)}")

    if added > 0:
        safe_refresh(cfg)
    elif not failed:
        _ok("Everything is up to date")


@_original_main.command()
@click.option("-b", "--build", is_flag=True, help="Build for distribution")
@click.pass_context
def refresh(ctx: click.Context, build: bool) -> None:
    """Refresh pack index (sha256 hashes)."""
    from elm.packwiz import safe_refresh

    cfg = _get_cfg(ctx)
    if not _require_pack(cfg):
        return
    _header("Refreshing Pack Index")
    ok = safe_refresh(cfg, build=build)
    if not ok:
        sys.exit(1)


@_original_main.command(name="init")
@click.option("--name", default="", help="Pack name")
@click.option("--author", default="", help="Pack author")
@click.option("--mc-version", default="", help="Minecraft version")
@click.option("--loader", default="", help="Mod loader (forge, fabric, quilt, neoforge)")
@click.pass_context
def init_pack(ctx: click.Context, name: str, author: str, mc_version: str, loader: str) -> None:
    """Initialize a new packwiz pack."""
    from elm.packwiz import init_pack as _init, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Initializing Pack")

    if cfg.pack_toml.is_file():
        _warn("pack.toml already exists in this directory")
        _hint("Delete it first or work from a different directory")
        return

    # Interactive prompts for missing values
    if not name:
        name = click.prompt("  Pack name", default=cfg.pack_dir.name)
    if not author:
        author = click.prompt("  Author", default="")
    if not mc_version:
        mc_version = click.prompt("  Minecraft version", default=cfg.mc_version)
    if not loader:
        loader = click.prompt(
            "  Mod loader",
            default=cfg.loader,
            type=click.Choice(["forge", "fabric", "quilt", "neoforge"], case_sensitive=False),
        )

    try:
        with console.status("  Creating pack..."):
            _init(cfg, name=name, author=author, mc_version=mc_version, loader=loader)
        _ok(f"Pack created: [cyan]{name}[/cyan] ({mc_version} / {loader})")
        safe_refresh(cfg)

        # Auto-register in pack registry
        pack_register(name, cfg.pack_dir, mc_version=mc_version, loader=loader)
        _ok(f"Registered as [cyan]{name}[/cyan]")

        console.print()
        _hint("Next steps:")
        _hint(f"  elm add <mod>    Install your first mod")
        _hint(f"  elm sync         Sync mods from mods.txt")
        _hint(f"  elm -p {name} <cmd>  Use from anywhere")
    except PackwizError as e:
        _fail("Init failed")
        if e.friendly_hint:
            _hint(e.friendly_hint)
        elif e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[0][:120])
        sys.exit(1)


# ── Self-update ───────────────────────────────────────────────────────────


@_original_main.command()
@click.pass_context
def update(ctx: click.Context) -> None:
    """Self-update ELM from GitHub."""
    import subprocess
    import tempfile
    import shutil

    cfg = _get_cfg(ctx)
    _header("Self-Update")

    repo = cfg.get("ELM_GITHUB_REPO")
    if not repo:
        _fail("ELM_GITHUB_REPO not set.")
        _hint("Set it in your config (elm config set ELM_GITHUB_REPO youruser/repo)")
        return

    branch = cfg.get("ELM_GITHUB_BRANCH") or "main"
    gh_path = cfg.get("ELM_GITHUB_PATH") or ""
    update_files = (cfg.get("ELM_UPDATE_FILES") or "elm.sh install.sh elm.conf mods.txt").split()

    base_url = f"https://raw.githubusercontent.com/{repo}/{branch}"
    if gh_path:
        base_url = f"{base_url}/{gh_path.strip('/')}"

    _info(f"Repo: [cyan]{repo}[/cyan]  Branch: [cyan]{branch}[/cyan]")

    updated = 0
    skipped = 0
    errors = 0

    for filename in update_files:
        url = f"{base_url}/{filename}"
        try:
            with console.status(f"  Fetching [cyan]{filename}[/cyan]..."):
                result = subprocess.run(
                    ["curl", "-fsSL", "--connect-timeout", "10", url],
                    capture_output=True,
                    text=True,
                )

            if result.returncode != 0:
                _warn(f"Could not fetch {filename}")
                errors += 1
                continue

            dest = cfg.pack_dir / filename
            if dest.is_file() and dest.read_text() == result.stdout:
                skipped += 1
                continue

            # Write via temp file for atomicity
            with tempfile.NamedTemporaryFile(
                mode="w", dir=dest.parent, prefix=f".{filename}.", delete=False
            ) as tmp:
                tmp.write(result.stdout)
                tmp_path = Path(tmp.name)

            # Preserve permissions if the file existed
            if dest.is_file():
                shutil.copymode(dest, tmp_path)

            tmp_path.replace(dest)
            _ok(f"Updated [cyan]{filename}[/cyan]")
            updated += 1

        except Exception as exc:
            _fail(f"Error updating {filename}: {exc}")
            errors += 1

    console.print()
    if updated:
        _ok(f"{updated} file{'s' if updated != 1 else ''} updated")
    if skipped:
        _info(f"{skipped} file{'s' if skipped != 1 else ''} already up to date")
    if errors:
        _warn(f"{errors} file{'s' if errors != 1 else ''} failed")
    if not updated and not errors:
        _ok("Everything is up to date")


# ── Deploy command group (Pelican) ────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def deploy(ctx: click.Context) -> None:
    """Server management via Pelican Panel."""


@deploy.command()
@click.pass_context
def setup(ctx: click.Context) -> None:
    """Interactive Pelican Panel setup wizard."""
    from elm.pelican import PelicanClient, PelicanError

    cfg = _get_cfg(ctx)
    _header("Pelican Panel Setup")
    console.print()

    url = click.prompt("  Panel URL", default=cfg.pelican_url or "https://panel.example.com")
    url = url.rstrip("/")
    cfg.set_global("PELICAN_URL", url)
    _ok(f"Panel URL set to [cyan]{url}[/cyan]")

    api_key = click.prompt("  Application API key", hide_input=True)
    cfg.set_key("PELICAN_API_KEY", api_key)
    _ok("API key saved")

    # Test connection
    client = PelicanClient(url=url, api_key=api_key)
    with console.status("  Testing connection..."):
        connected = client.test_connection()
    if connected:
        _ok("Connected to Pelican Panel")
    else:
        _fail("Could not reach panel — check URL and API key")
        return

    # List nodes
    try:
        nodes = client.list_nodes()
        if nodes:
            console.print()
            table = Table(title="Available Nodes", border_style="dim", padding=(0, 1))
            table.add_column("ID", style="bold")
            table.add_column("Name", style="cyan")
            table.add_column("FQDN", style="dim")
            for n in nodes:
                a = n.get("attributes", {})
                table.add_row(str(a.get("id")), a.get("name", ""), a.get("fqdn", ""))
            console.print(table)
            node_id = click.prompt("\n  Node ID", type=int)
            cfg.set_global("PELICAN_NODE_ID", str(node_id))
            _ok(f"Node ID: {node_id}")
    except PelicanError:
        _warn("Could not list nodes")

    # List nests → eggs
    try:
        nests = client.list_nests()
        if nests:
            console.print()
            table = Table(title="Available Nests", border_style="dim", padding=(0, 1))
            table.add_column("ID", style="bold")
            table.add_column("Name", style="cyan")
            for n in nests:
                a = n.get("attributes", {})
                table.add_row(str(a.get("id")), a.get("name", ""))
            console.print(table)
            nest_id = click.prompt("\n  Nest ID", type=int)
            cfg.set_global("PELICAN_NEST_ID", str(nest_id))

            eggs = client.list_eggs(nest_id)
            if eggs:
                console.print()
                table = Table(title="Available Eggs", border_style="dim", padding=(0, 1))
                table.add_column("ID", style="bold")
                table.add_column("Name", style="cyan")
                for e in eggs:
                    a = e.get("attributes", {})
                    table.add_row(str(a.get("id")), a.get("name", ""))
                console.print(table)
                egg_id = click.prompt("\n  Egg ID", type=int)
                cfg.set_global("PELICAN_EGG_ID", str(egg_id))
                _ok(f"Egg ID: {egg_id}")
    except PelicanError:
        _warn("Could not list nests/eggs")

    # List users
    try:
        users = client.list_users()
        if users:
            console.print()
            table = Table(title="Available Users", border_style="dim", padding=(0, 1))
            table.add_column("ID", style="bold")
            table.add_column("Username", style="cyan")
            table.add_column("Email", style="dim")
            for u in users:
                a = u.get("attributes", {})
                table.add_row(str(a.get("id")), a.get("username", ""), a.get("email", ""))
            console.print(table)
            user_id = click.prompt("\n  User ID (server owner)", type=int)
            cfg.set_global("PELICAN_USER_ID", str(user_id))
            _ok(f"User ID: {user_id}")
    except PelicanError:
        _warn("Could not list users")

    console.print()
    _ok("Pelican Panel setup complete")
    _hint("Next: elm target add <name> -d <domain>")
    _hint("Then:  elm deploy create -t <name>")


@deploy.command()
@click.option("-t", "--target", required=True, help="Target name")
@click.pass_context
def create(ctx: click.Context, target: str) -> None:
    """Create a Pelican server for a target."""
    from elm.pelican import create_target_server, PelicanError

    cfg = _get_cfg(ctx)
    _header(f"Creating Server: {target}")
    try:
        with console.status(f"  Provisioning [cyan]{target}[/cyan] on Pelican..."):
            attrs = create_target_server(cfg, target)
        sid = attrs.get("id", "?")
        uuid = attrs.get("uuid", "")[:8]
        _ok(f"Server created — ID: {sid}, UUID: {uuid}...")
        _hint(f"Start it: elm deploy start -t {target}")
    except PelicanError as e:
        _fail(e.body or str(e))
        sys.exit(1)


@deploy.command()
@click.option("-t", "--target", required=True)
@click.argument("signal", type=click.Choice(["start", "stop", "restart", "kill"]))
@click.pass_context
def power(ctx: click.Context, target: str, signal: str) -> None:
    """Send a power signal to a target's server."""
    from elm.pelican import power_target, PelicanError

    cfg = _get_cfg(ctx)
    try:
        with console.status(f"  Sending {signal} to [cyan]{target}[/cyan]..."):
            power_target(cfg, target, signal)
        _ok(f"{signal.title()} signal sent to [cyan]{target}[/cyan]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


# Convenience aliases for power signals
@deploy.command()
@click.option("-t", "--target", required=True)
@click.pass_context
def start(ctx: click.Context, target: str) -> None:
    """Start a target's server."""
    ctx.invoke(power, target=target, signal="start")


@deploy.command()
@click.option("-t", "--target", required=True)
@click.pass_context
def stop(ctx: click.Context, target: str) -> None:
    """Stop a target's server."""
    ctx.invoke(power, target=target, signal="stop")


@deploy.command()
@click.option("-t", "--target", required=True)
@click.pass_context
def restart(ctx: click.Context, target: str) -> None:
    """Restart a target's server."""
    ctx.invoke(power, target=target, signal="restart")


@deploy.command(name="console")
@click.option("-t", "--target", required=True)
@click.argument("command")
@click.pass_context
def send_console(ctx: click.Context, target: str, command: str) -> None:
    """Send a console command to a target's server."""
    from elm.pelican import command_target, PelicanError

    cfg = _get_cfg(ctx)
    try:
        command_target(cfg, target, command)
        _ok(f"Command sent: [dim]{command}[/dim]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy.command()
@click.option("-t", "--target", required=True)
@click.pass_context
def status(ctx: click.Context, target: str) -> None:
    """Show server status and resource usage."""
    from elm.pelican import status_target, PelicanError

    cfg = _get_cfg(ctx)
    try:
        with console.status(f"  Fetching status for [cyan]{target}[/cyan]..."):
            data = status_target(cfg, target)

        attrs = data.get("attributes", {})
        resources = attrs.get("resources", {})
        state = attrs.get("current_state", "unknown")

        color = {"running": "green", "stopped": "red", "starting": "yellow",
                 "stopping": "yellow", "offline": "red"}.get(state, "dim")
        state_icon = {"running": "[green]●[/green]", "stopped": "[red]●[/red]",
                      "starting": "[yellow]◐[/yellow]", "stopping": "[yellow]◑[/yellow]",
                      "offline": "[red]○[/red]"}.get(state, "[dim]?[/dim]")

        console.print()
        panel_lines = [f"  State:  {state_icon} [{color}]{state}[/{color}]"]

        if resources:
            mem = resources.get("memory_bytes", 0) / 1024 / 1024
            cpu = resources.get("cpu_absolute", 0)
            disk = resources.get("disk_bytes", 0) / 1024 / 1024
            uptime = resources.get("uptime", 0)

            panel_lines.append(f"  CPU:    {cpu:.1f}%")
            panel_lines.append(f"  RAM:    {mem:.0f} MB")
            panel_lines.append(f"  Disk:   {disk:.0f} MB")
            if uptime:
                hours, remainder = divmod(uptime // 1000, 3600)
                minutes = remainder // 60
                panel_lines.append(f"  Uptime: {hours}h {minutes}m")

        console.print(Panel(
            "\n".join(panel_lines),
            title=f"[bold]{target}[/bold]",
            border_style="cyan",
            padding=(0, 1),
        ))

    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy.command()
@click.option("-t", "--target", required=True)
@click.pass_context
def backup(ctx: click.Context, target: str) -> None:
    """Create a server backup."""
    from elm.pelican import backup_target, PelicanError

    cfg = _get_cfg(ctx)
    try:
        with console.status(f"  Creating backup for [cyan]{target}[/cyan]..."):
            backup_target(cfg, target)
        _ok(f"Backup created for [cyan]{target}[/cyan]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy.command()
@click.option("-t", "--target", required=True)
@click.confirmation_option(prompt="Delete this server? This cannot be undone")
@click.pass_context
def remove(ctx: click.Context, target: str) -> None:
    """Delete a target's Pelican server."""
    from elm.pelican import delete_target_server, PelicanError

    cfg = _get_cfg(ctx)
    try:
        with console.status(f"  Deleting [cyan]{target}[/cyan]..."):
            delete_target_server(cfg, target)
        _ok(f"Server [cyan]{target}[/cyan] deleted")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


# ── CDN / Pack Hosting ─────────────────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def cdn(ctx: click.Context) -> None:
    """Manage pack hosting via Caddy reverse proxy."""


@cdn.command()
@click.pass_context
def setup(ctx: click.Context) -> None:
    """Generate Caddy + Docker Compose config for pack hosting."""
    cfg = _get_cfg(ctx)
    _header("CDN Setup")

    if not cfg.pack_toml.is_file():
        _fail("No pack.toml found — initialize a pack first (elm init)")
        return

    domain = cfg.cdn_domain
    pack_url = cfg.pack_host_url

    if not domain and not pack_url:
        domain = click.prompt(
            "  CDN domain (leave empty for localhost:8080)", default="", show_default=False
        )
        if domain:
            cfg.set_global("CDN_DOMAIN", domain)
            cfg.set_global("PACK_HOST_URL", f"https://{domain}")
            _ok(f"CDN domain: [cyan]{domain}[/cyan] (HTTPS via Caddy)")
        else:
            cfg.set_global("PACK_HOST_URL", "http://localhost:8080")
            _ok("Serving on [cyan]http://localhost:8080[/cyan]")

    compose_dir = cfg.cdn_compose_dir
    compose_dir.mkdir(parents=True, exist_ok=True)

    # Resolve pack directory as absolute path for the volume mount
    pack_abs = cfg.pack_dir.resolve()

    # Generate Caddyfile
    if domain:
        caddy_config = (
            f"{domain} {{\n"
            f"    root * /srv/pack\n"
            f"    file_server {{\n"
            f"        browse\n"
            f"    }}\n"
            f"    header Cache-Control \"public, max-age=60\"\n"
            f"    header Access-Control-Allow-Origin \"*\"\n"
            f"}}\n"
        )
    else:
        caddy_config = (
            ":8080 {\n"
            "    root * /srv/pack\n"
            "    file_server {\n"
            "        browse\n"
            "    }\n"
            "    header Cache-Control \"public, max-age=60\"\n"
            "    header Access-Control-Allow-Origin \"*\"\n"
            "}\n"
        )

    caddyfile = compose_dir / "Caddyfile"
    caddyfile.write_text(caddy_config)
    _ok(f"Caddyfile written to [dim]{caddyfile}[/dim]")

    # Generate docker-compose.yml
    ports_section = '    ports:\n      - "443:443"\n      - "80:80"' if domain else \
        '    ports:\n      - "8080:8080"'

    compose_config = (
        "services:\n"
        "  caddy:\n"
        "    image: caddy:2-alpine\n"
        "    restart: unless-stopped\n"
        f"{ports_section}\n"
        "    volumes:\n"
        f"      - ./Caddyfile:/etc/caddy/Caddyfile:ro\n"
        f"      - {pack_abs}:/srv/pack:ro\n"
        "      - caddy_data:/data\n"
        "      - caddy_config:/config\n"
        "\n"
        "volumes:\n"
        "  caddy_data:\n"
        "  caddy_config:\n"
    )

    compose_file = compose_dir / "docker-compose.yml"
    compose_file.write_text(compose_config)
    _ok(f"docker-compose.yml written to [dim]{compose_file}[/dim]")

    pack_url = cfg.pack_host_url or (f"https://{domain}" if domain else "http://localhost:8080")
    console.print()
    _ok("CDN config ready")
    _hint(f"Start:      elm cdn start")
    _hint(f"Pack URL:   {pack_url}/pack.toml")


@cdn.command(name="start")
@click.pass_context
def cdn_start(ctx: click.Context) -> None:
    """Start the Caddy pack server."""
    import subprocess

    cfg = _get_cfg(ctx)
    compose_dir = cfg.cdn_compose_dir
    compose_file = compose_dir / "docker-compose.yml"

    if not compose_file.is_file():
        _fail("No docker-compose.yml found — run: elm cdn setup")
        return

    _header("Starting CDN")
    try:
        subprocess.run(
            ["docker", "compose", "up", "-d"],
            cwd=compose_dir, check=True, capture_output=True, text=True,
        )
        pack_url = cfg.pack_host_url or "http://localhost:8080"
        _ok("Caddy is running")
        _hint(f"Pack index: {pack_url}/pack.toml")
    except subprocess.CalledProcessError as e:
        _fail("Failed to start Caddy")
        if e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[-1][:120])
    except FileNotFoundError:
        _fail("Docker not found — install with: elm deps install docker")


@cdn.command(name="stop")
@click.pass_context
def cdn_stop(ctx: click.Context) -> None:
    """Stop the Caddy pack server."""
    import subprocess

    cfg = _get_cfg(ctx)
    compose_dir = cfg.cdn_compose_dir

    if not (compose_dir / "docker-compose.yml").is_file():
        _fail("No docker-compose.yml found — nothing to stop")
        return

    _header("Stopping CDN")
    try:
        subprocess.run(
            ["docker", "compose", "down"],
            cwd=compose_dir, check=True, capture_output=True, text=True,
        )
        _ok("Caddy stopped")
    except subprocess.CalledProcessError as e:
        _fail("Failed to stop Caddy")
        if e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[-1][:120])


@cdn.command(name="status")
@click.pass_context
def cdn_status(ctx: click.Context) -> None:
    """Check CDN server status."""
    import subprocess

    cfg = _get_cfg(ctx)
    compose_dir = cfg.cdn_compose_dir

    if not (compose_dir / "docker-compose.yml").is_file():
        _info("CDN not configured — run: elm cdn setup")
        return

    _header("CDN Status")
    try:
        result = subprocess.run(
            ["docker", "compose", "ps", "--format", "json"],
            cwd=compose_dir, capture_output=True, text=True,
        )
        output = result.stdout.strip()
        if not output:
            _warn("Caddy container is not running")
            _hint("Start with: elm cdn start")
            return

        import json as _json
        # docker compose ps --format json outputs one JSON object per line
        for line in output.splitlines():
            try:
                container = _json.loads(line)
                name = container.get("Name", "caddy")
                state = container.get("State", "unknown")
                health = container.get("Health", "")
                ports = container.get("Publishers", [])

                color = {"running": "green", "exited": "red", "created": "yellow"}.get(
                    state, "dim"
                )
                state_icon = {"running": "[green]●[/green]", "exited": "[red]●[/red]"}.get(
                    state, "[dim]?[/dim]"
                )

                panel_lines = [f"  State:  {state_icon} [{color}]{state}[/{color}]"]
                if health:
                    panel_lines.append(f"  Health: {health}")

                if ports:
                    port_strs = []
                    for p in ports:
                        pub = p.get("PublishedPort", 0)
                        tgt = p.get("TargetPort", 0)
                        if pub:
                            port_strs.append(f"{pub}->{tgt}")
                    if port_strs:
                        panel_lines.append(f"  Ports:  {', '.join(port_strs)}")

                pack_url = cfg.pack_host_url or "http://localhost:8080"
                panel_lines.append(f"  URL:    {pack_url}/pack.toml")

                console.print(Panel(
                    "\n".join(panel_lines),
                    title=f"[bold]{name}[/bold]",
                    border_style="cyan",
                    padding=(0, 1),
                ))
            except _json.JSONDecodeError:
                continue

    except FileNotFoundError:
        _fail("Docker not found")


# ── Client / Prism Launcher ────────────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def client(ctx: click.Context) -> None:
    """Generate client-side launcher scripts."""


@client.command()
@click.option("-d", "--dir", "dest_dir", default="", help="Output directory (default: current)")
@click.pass_context
def setup(ctx: click.Context, dest_dir: str) -> None:
    """Generate Prism Launcher pre-launch scripts with your pack URL.

    \b
    Examples:
      elm client setup
      elm client setup -d ~/Games/PrismLauncher/instances/MyPack/.minecraft
    """
    cfg = _get_cfg(ctx)
    _header("Client Setup")

    pack_url = cfg.pack_host_url
    if not pack_url:
        pack_url = click.prompt(
            "  Pack host URL (e.g. https://pack.example.com)",
            default=f"https://{cfg.cdn_domain}" if cfg.cdn_domain else "",
        )
        if not pack_url:
            _fail("No pack URL — configure CDN_DOMAIN or PACK_HOST_URL first")
            _hint("Run: elm cdn setup")
            return
        cfg.set_global("PACK_HOST_URL", pack_url)

    pack_url = pack_url.rstrip("/")
    out = Path(dest_dir) if dest_dir else Path.cwd()
    out.mkdir(parents=True, exist_ok=True)

    # Generate bash script
    sh_content = (
        "#!/usr/bin/env bash\n"
        "# ELM — Prism Launcher pre-launch script (packwiz-installer)\n"
        "# Generated by: elm client setup\n"
        "#\n"
        "# Pre-launch command:\n"
        '#   bash "$INST_DIR/prism-update.sh"\n'
        "\n"
        f'PACK_URL="${{PACK_URL:-{pack_url}}}"\n'
        'BOOTSTRAP_JAR="packwiz-installer-bootstrap.jar"\n'
        'BOOTSTRAP_URL="https://github.com/packwiz/packwiz-installer-bootstrap'
        '/releases/latest/download/packwiz-installer-bootstrap.jar"\n'
        "\n"
        'cd "$INST_MC_DIR" || exit 1\n'
        "\n"
        'if [ ! -f "$BOOTSTRAP_JAR" ]; then\n'
        '    echo "[ELM] Downloading packwiz-installer-bootstrap..."\n'
        '    curl -fsSL -o "$BOOTSTRAP_JAR" "$BOOTSTRAP_URL" || {\n'
        '        echo "[ELM] Failed to download bootstrap jar"\n'
        "        exit 1\n"
        "    }\n"
        "fi\n"
        "\n"
        'echo "[ELM] Updating modpack from $PACK_URL..."\n'
        'java -jar "$BOOTSTRAP_JAR" -g -s client "$PACK_URL/pack.toml"\n'
    )
    sh_path = out / "prism-update.sh"
    sh_path.write_text(sh_content)
    sh_path.chmod(0o755)
    _ok(f"prism-update.sh  \u2192  [dim]{sh_path}[/dim]")

    # Generate bat script
    bat_content = (
        "@echo off\n"
        "REM ELM — Prism Launcher pre-launch script (packwiz-installer)\n"
        "REM Generated by: elm client setup\n"
        "REM\n"
        "REM Pre-launch command:\n"
        'REM   cmd /c "%INST_DIR%\\prism-update.bat"\n'
        "\n"
        f'if "%PACK_URL%"=="" set "PACK_URL={pack_url}"\n'
        'set "BOOTSTRAP_JAR=packwiz-installer-bootstrap.jar"\n'
        'set "BOOTSTRAP_URL=https://github.com/packwiz/packwiz-installer-bootstrap'
        '/releases/latest/download/packwiz-installer-bootstrap.jar"\n'
        "\n"
        'cd /d "%INST_MC_DIR%" || exit /b 1\n'
        "\n"
        "if not exist \"%BOOTSTRAP_JAR%\" (\n"
        "    echo [ELM] Downloading packwiz-installer-bootstrap...\n"
        '    curl -fsSL -o "%BOOTSTRAP_JAR%" "%BOOTSTRAP_URL%"\n'
        "    if errorlevel 1 (\n"
        "        echo [ELM] Failed to download bootstrap jar\n"
        "        exit /b 1\n"
        "    )\n"
        ")\n"
        "\n"
        "echo [ELM] Updating modpack from %PACK_URL%...\n"
        'java -jar "%BOOTSTRAP_JAR%" -g -s client "%PACK_URL%/pack.toml"\n'
    )
    bat_path = out / "prism-update.bat"
    bat_path.write_text(bat_content)
    _ok(f"prism-update.bat \u2192  [dim]{bat_path}[/dim]")

    console.print()
    _ok(f"Pack URL: [cyan]{pack_url}[/cyan]")
    console.print()
    _hint("Prism Launcher setup:")
    _hint("  1. Copy scripts to your instance's .minecraft folder")
    _hint("  2. Instance > Edit > Settings > Custom Commands")
    _hint("  3. Pre-launch command:")
    _hint('     Linux:   bash "$INST_DIR/prism-update.sh"')
    _hint('     Windows: cmd /c "%INST_DIR%\\prism-update.bat"')


@client.command()
@click.pass_context
def info(ctx: click.Context) -> None:
    """Show the pack URL clients should connect to."""
    cfg = _get_cfg(ctx)
    pack_url = cfg.pack_host_url
    if pack_url:
        _ok(f"Pack URL: [cyan]{pack_url}/pack.toml[/cyan]")
    else:
        _warn("No PACK_HOST_URL configured")
        _hint("Run: elm cdn setup  or  elm config set PACK_HOST_URL <url>")


# ── Pack registry ─────────────────────────────────────────────────────────


@_original_main.group(name="pack", cls=SubGroup)
@click.pass_context
def pack_group(ctx: click.Context) -> None:
    """Manage registered pack directories."""


@pack_group.command(name="register")
@click.argument("name", required=False, default="")
@click.option("-d", "--dir", "pack_dir", default="", help="Pack directory (default: current)")
@click.pass_context
def pack_reg(ctx: click.Context, name: str, pack_dir: str) -> None:
    """Register a pack directory so elm can find it from anywhere.

    \b
    Examples:
      elm pack register                    Register current dir with auto name
      elm pack register mypack             Register current dir as 'mypack'
      elm pack register mypack -d /path    Register a specific directory
    """
    cfg = _get_cfg(ctx)
    directory = Path(pack_dir) if pack_dir else cfg.pack_dir
    directory = directory.resolve()

    pack_toml = directory / "pack.toml"
    if not pack_toml.is_file():
        _fail(f"No pack.toml found in [dim]{directory}[/dim]")
        _hint("Initialize a pack first: elm init")
        return

    if not name:
        name = directory.name

    pack_register(name, directory, mc_version=cfg.mc_version, loader=cfg.loader)
    _ok(f"Registered [cyan]{name}[/cyan] \u2192 [dim]{directory}[/dim]")
    _hint(f"Use from anywhere: elm -p {name} <command>")


@pack_group.command(name="ls")
@click.pass_context
def pack_ls(ctx: click.Context) -> None:
    """List all registered packs."""
    packs = load_packs()
    if not packs:
        _header("Registered Packs")
        _info("No packs registered yet.")
        _hint("Register one: elm pack register [name]")
        return

    table = Table(
        title=f"Registered Packs ({len(packs)})",
        border_style="dim",
        padding=(0, 1),
    )
    table.add_column("Name", style="cyan bold")
    table.add_column("Path")
    table.add_column("MC", justify="center")
    table.add_column("Loader", justify="center")
    table.add_column("", width=6)

    for name, data in packs.items():
        p = Path(data.get("path", ""))
        exists = (p / "pack.toml").is_file() if p.is_dir() else False
        status = "[green]OK[/green]" if exists else "[red]![/red]"
        table.add_row(
            name,
            str(data.get("path", "")),
            data.get("mc_version", ""),
            data.get("loader", ""),
            status,
        )
    console.print()
    console.print(table)


@pack_group.command(name="rm")
@click.argument("name")
@click.pass_context
def pack_rm(ctx: click.Context, name: str) -> None:
    """Unregister a pack."""
    packs = load_packs()
    if name not in packs:
        _fail(f"Pack [cyan]{name}[/cyan] not found")
        existing = pack_list()
        if existing:
            _hint(f"Available: {', '.join(existing)}")
        return
    pack_remove(name)
    _ok(f"Unregistered [cyan]{name}[/cyan]")


# ── Target management ─────────────────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def target(ctx: click.Context) -> None:
    """Manage deployment targets."""


@target.command(name="ls")
@click.pass_context
def target_ls(ctx: click.Context) -> None:
    """List all targets."""
    targets = load_targets()
    if not targets:
        _header("Targets")
        _info("No targets configured yet.")
        _hint("Add one:  elm target add <name> -d <domain>")
        return

    table = Table(
        title=f"Targets ({len(targets)})",
        border_style="dim",
        padding=(0, 1),
    )
    table.add_column("Name", style="cyan bold")
    table.add_column("Domain")
    table.add_column("Port", justify="right")
    table.add_column("Pelican ID", style="dim")
    for name, data in targets.items():
        pel_id = data.get("pelican_server_id", "")
        table.add_row(
            name,
            data.get("domain", "") or "[dim]—[/dim]",
            str(data.get("port", "")),
            str(pel_id) if pel_id else "[dim]—[/dim]",
        )
    console.print()
    console.print(table)


@target.command(name="add")
@click.argument("name")
@click.option("-d", "--domain", default="", help="Server domain")
@click.option("-p", "--port", type=int, default=25565, help="Server port")
@click.option("--ram", type=int, default=0, help="RAM in MB")
@click.pass_context
def target_add(ctx: click.Context, name: str, domain: str, port: int, ram: int) -> None:
    """Add a deployment target."""
    fields: dict = {"domain": domain, "port": port}
    if ram:
        fields["ram"] = ram
    target_set(name, **fields)
    _ok(f"Target [cyan]{name}[/cyan] added")
    _hint(f"Create server:  elm deploy create -t {name}")


@target.command(name="rm")
@click.argument("name")
@click.pass_context
def target_rm(ctx: click.Context, name: str) -> None:
    """Remove a deployment target."""
    targets = load_targets()
    if name not in targets:
        _fail(f"Target [cyan]{name}[/cyan] not found")
        existing = list(targets.keys())
        if existing:
            _hint(f"Available: {', '.join(existing)}")
        return
    target_remove(name)
    _ok(f"Target [cyan]{name}[/cyan] removed")


@target.command(name="show")
@click.argument("name")
@click.pass_context
def target_show(ctx: click.Context, name: str) -> None:
    """Show target details."""
    targets = load_targets()
    data = targets.get(name)
    if not data:
        _fail(f"Target [cyan]{name}[/cyan] not found")
        existing = list(targets.keys())
        if existing:
            _hint(f"Available: {', '.join(existing)}")
        return

    table = Table(
        title=name,
        title_style="bold cyan",
        border_style="dim",
        show_header=False,
        padding=(0, 1),
    )
    table.add_column("Key", style="bold")
    table.add_column("Value")
    for k, v in sorted(data.items()):
        table.add_row(k, str(v) if v else "[dim]—[/dim]")
    console.print()
    console.print(table)


# ── Key management ────────────────────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def key(ctx: click.Context) -> None:
    """Manage API keys."""


@key.command(name="set")
@click.argument("provider", type=click.Choice(["pelican", "curseforge"]))
@click.argument("token", required=False, default=None)
@click.pass_context
def key_set(ctx: click.Context, provider: str, token: str | None) -> None:
    """Store an API key. If TOKEN is omitted, you'll be prompted securely."""
    cfg = _get_cfg(ctx)
    if token is None:
        token = click.prompt(f"  {provider.title()} API key", hide_input=True)
    key_map = {
        "pelican": "PELICAN_API_KEY",
        "curseforge": "CURSEFORGE_API_KEY",
    }
    cfg.set_key(key_map[provider], token)
    _ok(f"{provider.title()} API key saved")

    # Test Pelican connection
    if provider == "pelican" and cfg.pelican_url:
        from elm.pelican import PelicanClient

        with console.status("  Verifying connection..."):
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=token)
            ok = client.test_connection()
        if ok:
            _ok("Connection verified")
        else:
            _warn("Could not reach panel — check URL and key")


@key.command(name="show")
@click.pass_context
def key_show(ctx: click.Context) -> None:
    """Show stored keys (masked)."""
    cfg = _get_cfg(ctx)

    table = Table(border_style="dim", show_header=False, padding=(0, 1))
    table.add_column("Provider", style="bold")
    table.add_column("Key")

    for label, key_name in [("Pelican", "PELICAN_API_KEY"), ("CurseForge", "CURSEFORGE_API_KEY")]:
        masked = cfg.mask_key(key_name)
        val = masked if masked else "[dim]not set[/dim]"
        table.add_row(label, val)

    console.print()
    console.print(table)


@key.command(name="rm")
@click.argument("provider", type=click.Choice(["pelican", "curseforge"]))
@click.pass_context
def key_rm(ctx: click.Context, provider: str) -> None:
    """Remove an API key."""
    cfg = _get_cfg(ctx)
    key_map = {"pelican": "PELICAN_API_KEY", "curseforge": "CURSEFORGE_API_KEY"}
    cfg.set_key(key_map[provider], "")
    _ok(f"{provider.title()} API key removed")


# ── Config ────────────────────────────────────────────────────────────────


CONFIG_CATEGORIES = {
    "Minecraft": ["MC_VERSION", "LOADER", "LOADER_VERSION"],
    "Packwiz": ["PACKWIZ_BIN", "PREFER_SOURCE", "AUTO_DEPS", "AUTO_PUBLISH"],
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


@_original_main.group(name="config", cls=SubGroup)
@click.pass_context
def config_group(ctx: click.Context) -> None:
    """View and edit configuration."""


@config_group.command(name="show")
@click.pass_context
def config_show(ctx: click.Context) -> None:
    """Show current configuration."""
    from elm.config import DEFAULTS

    cfg = _get_cfg(ctx)

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


@config_group.command(name="set")
@click.argument("key")
@click.argument("value")
@click.pass_context
def config_set(ctx: click.Context, key: str, value: str) -> None:
    """Set a global config value."""
    cfg = _get_cfg(ctx)
    cfg.set_global(key.upper(), value)
    _ok(f"{key.upper()} = {value}")


@config_group.command(name="get")
@click.argument("key")
@click.pass_context
def config_get(ctx: click.Context, key: str) -> None:
    """Get a config value."""
    cfg = _get_cfg(ctx)
    val = cfg.get(key.upper())
    if val:
        console.print(f"  {key.upper()} = {val}")
    else:
        console.print(f"  {key.upper()} [dim]not set[/dim]")


# ── Dependencies ──────────────────────────────────────────────────────


@_original_main.group(cls=SubGroup)
@click.pass_context
def deps(ctx: click.Context) -> None:
    """Manage ELM dependencies."""


@deps.command(name="check")
@click.pass_context
def deps_check(ctx: click.Context) -> None:
    """Check status of all dependencies."""
    from elm.menu import _dep_status

    _header("Dependency Check")
    console.print()

    statuses = _dep_status()
    table = Table(
        title="Dependencies",
        title_style="bold",
        border_style="dim",
        padding=(0, 1),
    )
    table.add_column("Dependency", style="cyan")
    table.add_column("Status", width=12)
    table.add_column("Purpose", style="dim")

    for label, _binary, found, hint in statuses:
        status_str = "[green bold]found[/green bold]" if found else "[red bold]missing[/red bold]"
        table.add_row(label, status_str, hint)

    console.print(table)

    missing = [label for label, _, found, _ in statuses if not found]
    console.print()
    if not missing:
        _ok("All dependencies satisfied")
    else:
        _warn(f"{len(missing)} missing: {', '.join(missing)}")
        _hint("Install with: elm deps install <name>")


@deps.command(name="install")
@click.argument("name")
@click.pass_context
def deps_install(ctx: click.Context, name: str) -> None:
    """Install a dependency by name."""
    import subprocess
    import shutil

    cfg = _get_cfg(ctx)
    name_lower = name.lower()

    known = {
        "go": ("go", "Go"),
        "packwiz": ("packwiz", "packwiz"),
        "curl": ("curl", "curl"),
        "jq": ("jq", "jq"),
        "git": ("git", "Git"),
        "docker": ("docker", "Docker"),
        "pelican": ("pelican", "Pelican Panel"),
        "wings": ("wings", "Wings"),
    }

    if name_lower not in known:
        _fail(f"Unknown dependency: {name}")
        _hint(f"Available: {', '.join(known.keys())}")
        return

    binary, label = known[name_lower]

    if name_lower == "go":
        if shutil.which("go") or Path("/usr/local/go/bin/go").is_file():
            _ok("Go is already installed")
            return
        import platform
        arch = platform.machine()
        go_arch = {"x86_64": "amd64", "aarch64": "arm64", "AMD64": "amd64"}.get(arch)
        if not go_arch:
            _fail(f"Unsupported architecture: {arch}")
            return
        go_version = "1.22.2"
        tarball = f"go{go_version}.linux-{go_arch}.tar.gz"
        url = f"https://go.dev/dl/{tarball}"
        with console.status(f"  Downloading Go {go_version}..."):
            r = subprocess.run(
                ["curl", "-fsSL", "-o", f"/tmp/{tarball}", url],
                capture_output=True, text=True,
            )
        if r.returncode != 0:
            _fail("Download failed")
            return
        with console.status("  Installing to /usr/local/go..."):
            subprocess.run(["sudo", "rm", "-rf", "/usr/local/go"], check=True)
            subprocess.run(
                ["sudo", "tar", "-C", "/usr/local", "-xzf", f"/tmp/{tarball}"],
                check=True,
            )
            Path(f"/tmp/{tarball}").unlink(missing_ok=True)
        _ok(f"Go {go_version} installed to /usr/local/go")
        _hint("Add to PATH: export PATH=\"/usr/local/go/bin:$HOME/go/bin:$PATH\"")

    elif name_lower == "packwiz":
        if shutil.which("packwiz"):
            _ok(f"packwiz is already installed: {shutil.which('packwiz')}")
            return
        import os
        go_bin = shutil.which("go") or "/usr/local/go/bin/go"
        if not Path(go_bin).is_file():
            _fail("Go is not installed — run: elm deps install go")
            return
        env = os.environ.copy()
        gopath = env.get("GOPATH", str(Path.home() / "go"))
        env["GOPATH"] = gopath
        env["PATH"] = f"/usr/local/go/bin:{gopath}/bin:{env.get('PATH', '')}"
        with console.status("  Building packwiz..."):
            subprocess.run(
                [go_bin, "install", "github.com/packwiz/packwiz@latest"],
                env=env, capture_output=True, text=True, check=True,
            )
        pw_path = Path(gopath) / "bin" / "packwiz"
        if pw_path.is_file():
            local_bin = Path.home() / ".local" / "bin"
            local_bin.mkdir(parents=True, exist_ok=True)
            dest = local_bin / "packwiz"
            dest.unlink(missing_ok=True)
            dest.symlink_to(pw_path)
            _ok(f"packwiz installed → {dest}")
        else:
            _ok("packwiz built (check $GOPATH/bin)")

    elif name_lower == "docker":
        if shutil.which("docker"):
            _ok("Docker is already installed")
            return
        _info("Installing Docker via official script...")
        subprocess.run(
            ["bash", "-c", "curl -fsSL https://get.docker.com | sudo sh"],
            check=True,
        )
        _ok("Docker installed")
        _hint("Add yourself to the docker group: sudo usermod -aG docker $USER")

    elif name_lower == "pelican":
        _header("Install Pelican Panel")
        if not shutil.which("docker"):
            _fail("Docker is required — run: elm deps install docker")
            return

        panel_dir = Path.home() / ".config" / "elm" / "pelican"
        panel_dir.mkdir(parents=True, exist_ok=True)

        app_url = click.prompt("  Panel URL (e.g. https://panel.example.com)")
        db_pass = click.prompt("  Database password", default="pelican_secret")

        compose = (
            "services:\n"
            "  panel:\n"
            "    image: ghcr.io/pelican-dev/panel:latest\n"
            "    restart: unless-stopped\n"
            "    ports:\n"
            '      - "80:80"\n'
            '      - "443:443"\n'
            "    environment:\n"
            f'      APP_URL: "{app_url}"\n'
            '      DB_HOST: "db"\n'
            '      DB_PORT: "3306"\n'
            '      DB_DATABASE: "pelican"\n'
            '      DB_USERNAME: "pelican"\n'
            f'      DB_PASSWORD: "{db_pass}"\n'
            '      CACHE_DRIVER: "redis"\n'
            '      SESSION_DRIVER: "redis"\n'
            '      QUEUE_CONNECTION: "redis"\n'
            '      REDIS_HOST: "redis"\n'
            "    volumes:\n"
            "      - panel_data:/app/storage\n"
            "      - panel_logs:/app/storage/logs\n"
            "    depends_on:\n"
            "      - db\n"
            "      - redis\n"
            "\n"
            "  db:\n"
            "    image: mariadb:11\n"
            "    restart: unless-stopped\n"
            "    environment:\n"
            f'      MYSQL_ROOT_PASSWORD: "{db_pass}"\n'
            '      MYSQL_DATABASE: "pelican"\n'
            '      MYSQL_USER: "pelican"\n'
            f'      MYSQL_PASSWORD: "{db_pass}"\n'
            "    volumes:\n"
            "      - db_data:/var/lib/mysql\n"
            "\n"
            "  redis:\n"
            "    image: redis:7-alpine\n"
            "    restart: unless-stopped\n"
            "\n"
            "volumes:\n"
            "  panel_data:\n"
            "  panel_logs:\n"
            "  db_data:\n"
        )

        compose_file = panel_dir / "docker-compose.yml"
        compose_file.write_text(compose)
        _ok(f"docker-compose.yml \u2192 [dim]{compose_file}[/dim]")

        _info("Starting Pelican Panel...")
        try:
            subprocess.run(
                ["docker", "compose", "up", "-d"],
                cwd=panel_dir, check=True, capture_output=True, text=True,
            )
            _ok("Pelican Panel is running")
            console.print()
            _hint(f"Open {app_url} in your browser to complete setup")
            _hint("Then run: elm deploy setup  — to connect ELM to the panel")

            # Save the URL to config
            cfg.set_global("PELICAN_URL", app_url)
        except subprocess.CalledProcessError as e:
            _fail("Failed to start Pelican Panel")
            if e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[-1][:120])

    elif name_lower == "wings":
        _header("Install Wings")
        if not shutil.which("docker"):
            _fail("Docker is required — run: elm deps install docker")
            return

        if shutil.which("wings"):
            _ok(f"Wings is already installed: {shutil.which('wings')}")
            return

        import platform
        arch = platform.machine()
        wings_arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(arch)
        if not wings_arch:
            _fail(f"Unsupported architecture: {arch}")
            return

        _info("Downloading Wings...")
        wings_url = (
            "https://github.com/pelican-dev/wings/releases/latest/download"
            f"/wings_linux_{wings_arch}"
        )
        wings_bin = Path("/usr/local/bin/wings")

        try:
            with console.status("  Downloading Wings binary..."):
                subprocess.run(
                    ["sudo", "curl", "-fsSL", "-o", str(wings_bin), wings_url],
                    check=True, capture_output=True, text=True,
                )
                subprocess.run(
                    ["sudo", "chmod", "+x", str(wings_bin)],
                    check=True, capture_output=True, text=True,
                )
            _ok(f"Wings installed \u2192 {wings_bin}")
            console.print()
            _hint("Configure Wings in your Pelican Panel:")
            _hint("  Panel > Nodes > Create Node > copy the config token")
            _hint("  Then run: sudo wings configure --panel-url <URL> --token <TOKEN>")
            _hint("  Finally:  sudo wings --debug  (to test)")
        except subprocess.CalledProcessError as e:
            _fail("Failed to install Wings")
            if e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[-1][:120])

    else:
        # curl, jq, git — use system package manager
        if shutil.which(binary):
            _ok(f"{label} is already installed")
            return
        pkg = binary
        apt = shutil.which("apt-get")
        dnf = shutil.which("dnf")
        pacman = shutil.which("pacman")
        if apt:
            mgr = ["sudo", "apt-get", "install", "-y", pkg]
        elif dnf:
            mgr = ["sudo", "dnf", "install", "-y", pkg]
        elif pacman:
            mgr = ["sudo", "pacman", "-S", "--noconfirm", pkg]
        else:
            _fail("No supported package manager found (apt, dnf, pacman)")
            _hint(f"Install manually: sudo <pkg-manager> install {pkg}")
            return
        with console.status(f"  Installing {label}..."):
            subprocess.run(mgr, check=True)
        _ok(f"{label} installed")


@deps.command(name="ls")
@click.pass_context
def deps_ls(ctx: click.Context) -> None:
    """List all dependencies and their status."""
    ctx.invoke(deps_check)


# ── Diagnostics ───────────────────────────────────────────────────────────


@_original_main.command()
@click.pass_context
def check(ctx: click.Context) -> None:
    """Run diagnostics."""
    import shutil

    cfg = _get_cfg(ctx)
    _header("ELM Diagnostics")
    console.print()

    # Version
    _info(f"ELM v{__version__}")

    # packwiz
    pw_path = shutil.which(cfg.packwiz_bin)
    if pw_path:
        _ok(f"packwiz found: [dim]{pw_path}[/dim]")
    else:
        _fail(f"packwiz not found (expected: {cfg.packwiz_bin})")
        _hint("Install: https://packwiz.infra.link/installation/")

    # pack.toml
    if cfg.pack_toml.is_file():
        _ok(f"pack.toml: [dim]{cfg.pack_toml}[/dim]")
    else:
        _warn("No pack.toml found")
        _hint(f"Expected at: {cfg.pack_toml}")
        _hint("Initialize with: elm init")

    # mods.txt
    if cfg.mods_file.is_file():
        lines = [ln for ln in cfg.mods_file.read_text().splitlines()
                 if ln.strip() and not ln.startswith("#")]
        _ok(f"mods.txt: {len(lines)} entries")
    else:
        _info("No mods.txt [dim](optional)[/dim]")

    # Pelican
    console.print()
    if cfg.pelican_url:
        _ok(f"Pelican URL: [dim]{cfg.pelican_url}[/dim]")
        if cfg.pelican_api_key:
            from elm.pelican import PelicanClient

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

_original_main.add_command(rm, "remove")
_original_main.add_command(list_mods, "list")
_original_main.add_command(update, "self-update")


if __name__ == "__main__":
    main()
