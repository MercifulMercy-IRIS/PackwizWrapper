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
    load_targets,
    target_list,
    target_remove,
    target_set,
)
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header


def _get_cfg(ctx: click.Context) -> Config:
    return ctx.obj


# ── Custom help formatter ─────────────────────────────────────────────────


class ElmGroup(click.Group):
    """Custom group that shows a branded help screen."""

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
            "Config": [
                ("target add/ls/rm/show", "Manage deployment targets"),
                ("key set/show/rm", "Manage API keys"),
                ("config show/set/get", "View & edit configuration"),
                ("check", "Run diagnostics"),
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
@click.pass_context
def main(ctx: click.Context) -> None:
    """ELM — EnviousLabs Minecraft CLI."""
    try:
        ctx.obj = load_config()
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
    """Add one or more mods."""
    from elm.packwiz import add_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Adding Mods")

    ok_count = 0
    for slug in slugs:
        try:
            with console.status(f"  Installing [cyan]{slug}[/cyan]..."):
                add_mod(cfg, slug, source=source)
            _ok(f"Added [cyan]{slug}[/cyan]")
            ok_count += 1
        except PackwizError as e:
            _fail(f"Could not add [cyan]{slug}[/cyan]")
            if e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[0][:100])

    if ok_count > 0:
        safe_refresh(cfg)


@_original_main.command()
@click.argument("slugs", nargs=-1, required=True)
@click.pass_context
def rm(ctx: click.Context, slugs: tuple[str, ...]) -> None:
    """Remove one or more mods."""
    from elm.packwiz import remove_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Removing Mods")

    ok_count = 0
    for slug in slugs:
        try:
            remove_mod(cfg, slug)
            _ok(f"Removed [cyan]{slug}[/cyan]")
            ok_count += 1
        except PackwizError as e:
            _fail(f"Could not remove [cyan]{slug}[/cyan]")
            if e.stderr.strip():
                _hint(e.stderr.strip().splitlines()[0][:100])

    if ok_count > 0:
        safe_refresh(cfg)


@_original_main.command(name="up")
@click.argument("slug", required=False, default="")
@click.pass_context
def up(ctx: click.Context, slug: str) -> None:
    """Update a mod, or all mods."""
    from elm.packwiz import update_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    label = f"Updating {slug}" if slug else "Updating All Mods"
    _header(label)

    try:
        with console.status("  Checking for updates..."):
            update_mod(cfg, slug)
        _ok("Update complete")
    except PackwizError as e:
        _fail("Update failed")
        if e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[0][:100])
        return

    safe_refresh(cfg)


@_original_main.command(name="ls")
@click.pass_context
def list_mods(ctx: click.Context) -> None:
    """List installed mods."""
    from elm.packwiz import list_mods as _list

    cfg = _get_cfg(ctx)
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
    """Sync mods from mods.txt."""
    from elm.packwiz import sync_from_modsfile, safe_refresh

    cfg = _get_cfg(ctx)
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
    _header("Refreshing Pack Index")
    ok = safe_refresh(cfg, build=build)
    if not ok:
        sys.exit(1)


@_original_main.command(name="init")
@click.pass_context
def init_pack(ctx: click.Context) -> None:
    """Initialize a new packwiz pack."""
    from elm.packwiz import init_pack as _init, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Initializing Pack")
    try:
        with console.status("  Creating pack..."):
            _init(cfg)
        _ok("Pack initialized")
        safe_refresh(cfg)
    except PackwizError as e:
        _fail("Init failed")
        if e.stderr.strip():
            _hint(e.stderr.strip().splitlines()[0][:100])
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
