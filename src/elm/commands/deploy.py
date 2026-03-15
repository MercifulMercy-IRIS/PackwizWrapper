"""Server deployment commands via Pelican Panel."""

from __future__ import annotations

import sys

import typer
from rich.panel import Panel
from rich.table import Table

from elm.config import load_config, load_targets, target_set
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header

deploy_app = typer.Typer(help="Server management via Pelican Panel.")


@deploy_app.command()
def setup() -> None:
    """Interactive Pelican Panel setup wizard."""
    from elm.core.pelican import PelicanClient, PelicanError

    cfg = load_config()
    _header("Pelican Panel Setup")
    console.print()

    url = typer.prompt("  Panel URL", default=cfg.pelican_url or "https://panel.example.com")
    url = url.rstrip("/")
    cfg.set_global("PELICAN_URL", url)
    _ok(f"Panel URL set to [cyan]{url}[/cyan]")

    api_key = typer.prompt("  Application API key", hide_input=True)
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
            node_id = typer.prompt("\n  Node ID", type=int)
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
            nest_id = typer.prompt("\n  Nest ID", type=int)
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
                egg_id = typer.prompt("\n  Egg ID", type=int)
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
            user_id = typer.prompt("\n  User ID (server owner)", type=int)
            cfg.set_global("PELICAN_USER_ID", str(user_id))
            _ok(f"User ID: {user_id}")
    except PelicanError:
        _warn("Could not list users")

    console.print()
    _ok("Pelican Panel setup complete")
    _hint("Next: elm target add <name> -d <domain>")
    _hint("Then:  elm deploy create -t <name>")


@deploy_app.command()
def create(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Create a Pelican server for a target."""
    from elm.core.pelican import create_target_server, PelicanError

    cfg = load_config()
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


@deploy_app.command()
def start(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Start a target's server."""
    _power_cmd(target, "start")


@deploy_app.command()
def stop(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Stop a target's server."""
    _power_cmd(target, "stop")


@deploy_app.command()
def restart(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Restart a target's server."""
    _power_cmd(target, "restart")


def _power_cmd(target: str, signal: str) -> None:
    """Send a power signal to a target's server."""
    from elm.core.pelican import power_target, PelicanError

    cfg = load_config()
    try:
        with console.status(f"  Sending {signal} to [cyan]{target}[/cyan]..."):
            power_target(cfg, target, signal)
        _ok(f"{signal.title()} signal sent to [cyan]{target}[/cyan]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy_app.command(name="console")
def send_console(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
    command: str = typer.Argument(..., help="Console command to send"),
) -> None:
    """Send a console command to a target's server."""
    from elm.core.pelican import command_target, PelicanError

    cfg = load_config()
    try:
        command_target(cfg, target, command)
        _ok(f"Command sent: [dim]{command}[/dim]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy_app.command()
def status(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Show server status and resource usage."""
    from elm.core.pelican import status_target, PelicanError

    cfg = load_config()
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


@deploy_app.command()
def backup(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
) -> None:
    """Create a server backup."""
    from elm.core.pelican import backup_target, PelicanError

    cfg = load_config()
    try:
        with console.status(f"  Creating backup for [cyan]{target}[/cyan]..."):
            backup_target(cfg, target)
        _ok(f"Backup created for [cyan]{target}[/cyan]")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


@deploy_app.command()
def remove(
    target: str = typer.Option(..., "-t", "--target", help="Target name"),
    yes: bool = typer.Option(False, "--yes", "-y", help="Skip confirmation"),
) -> None:
    """Delete a target's Pelican server."""
    from elm.core.pelican import delete_target_server, PelicanError

    if not yes:
        typer.confirm("Delete this server? This cannot be undone", abort=True)

    cfg = load_config()
    try:
        with console.status(f"  Deleting [cyan]{target}[/cyan]..."):
            delete_target_server(cfg, target)
        _ok(f"Server [cyan]{target}[/cyan] deleted")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)
