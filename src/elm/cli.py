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

import click
from rich.console import Console
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

console = Console()


def _fail(msg: str) -> None:
    console.print(f"  [red bold]FAIL[/red bold] {msg}")


def _ok(msg: str) -> None:
    console.print(f"  [green]OK[/green] {msg}")


def _warn(msg: str) -> None:
    console.print(f"  [yellow]WARN[/yellow] {msg}")


def _header(msg: str) -> None:
    console.print(f"\n[bold cyan]── {msg} ──[/bold cyan]")


def _get_cfg(ctx: click.Context) -> Config:
    return ctx.ensure_object(Config)


# ── Main group ────────────────────────────────────────────────────────────


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="elm")
@click.pass_context
def main(ctx: click.Context) -> None:
    """ELM — EnviousLabs Minecraft CLI."""
    ctx.ensure_object(dict)
    ctx.obj = load_config()
    if ctx.invoked_subcommand is None:
        click.echo(ctx.get_help())


# ── Mod commands ──────────────────────────────────────────────────────────


@main.command()
@click.argument("slugs", nargs=-1, required=True)
@click.option("-s", "--source", default="", help="Source: mr (Modrinth) or cf (CurseForge)")
@click.pass_context
def add(ctx: click.Context, slugs: tuple[str, ...], source: str) -> None:
    """Add one or more mods."""
    from elm.packwiz import add_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Adding Mods")

    for slug in slugs:
        try:
            add_mod(cfg, slug, source=source)
            _ok(f"Added {slug}")
        except PackwizError as e:
            _fail(f"Could not add {slug}: {e.stderr.strip()[:120]}")

    safe_refresh(cfg)


@main.command()
@click.argument("slugs", nargs=-1, required=True)
@click.pass_context
def rm(ctx: click.Context, slugs: tuple[str, ...]) -> None:
    """Remove one or more mods."""
    from elm.packwiz import remove_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Removing Mods")

    for slug in slugs:
        try:
            remove_mod(cfg, slug)
            _ok(f"Removed {slug}")
        except PackwizError as e:
            _fail(f"Could not remove {slug}: {e.stderr.strip()[:120]}")

    safe_refresh(cfg)


@main.command()
@click.argument("slug", required=False, default="")
@click.pass_context
def update(ctx: click.Context, slug: str) -> None:
    """Update a mod, or all mods."""
    from elm.packwiz import update_mod, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Updating" if not slug else f"Updating {slug}")

    try:
        update_mod(cfg, slug)
        _ok("Update complete")
    except PackwizError as e:
        _fail(f"Update failed: {e.stderr.strip()[:120]}")

    safe_refresh(cfg)


@main.command(name="ls")
@click.pass_context
def list_mods(ctx: click.Context) -> None:
    """List installed mods."""
    from elm.packwiz import list_mods as _list

    cfg = _get_cfg(ctx)
    mods = _list(cfg)

    if not mods:
        console.print("  No mods installed.")
        return

    table = Table(title="Installed Mods", show_lines=False)
    table.add_column("#", style="dim", width=4)
    table.add_column("Mod", style="cyan")
    for i, name in enumerate(mods, 1):
        table.add_row(str(i), name)
    console.print(table)
    console.print(f"  [dim]{len(mods)} mods total[/dim]")


@main.command()
@click.argument("query")
@click.option("-s", "--source", default="", help="Source: mr or cf")
@click.pass_context
def search(ctx: click.Context, query: str, source: str) -> None:
    """Search for mods."""
    from elm.packwiz import search_mod

    cfg = _get_cfg(ctx)
    output = search_mod(cfg, query, source=source)
    if output.strip():
        console.print(output)
    else:
        console.print("  No results found.")


@main.command()
@click.pass_context
def sync(ctx: click.Context) -> None:
    """Sync mods from mods.txt."""
    from elm.packwiz import sync_from_modsfile, safe_refresh

    cfg = _get_cfg(ctx)
    _header("Syncing from mods.txt")

    if not cfg.mods_file.is_file():
        _fail(f"No mods.txt found at {cfg.mods_file}")
        return

    added, skipped, failed = sync_from_modsfile(cfg)
    _ok(f"Added {added}, skipped {skipped}")
    if failed:
        _warn(f"Failed: {', '.join(failed)}")

    safe_refresh(cfg)


@main.command()
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


@main.command(name="init")
@click.pass_context
def init_pack(ctx: click.Context) -> None:
    """Initialize a new packwiz pack."""
    from elm.packwiz import init_pack as _init, safe_refresh, PackwizError

    cfg = _get_cfg(ctx)
    _header("Initializing Pack")
    try:
        _init(cfg)
        _ok("Pack initialized")
        safe_refresh(cfg)
    except PackwizError as e:
        _fail(f"Init failed: {e.stderr.strip()[:120]}")
        sys.exit(1)


# ── Deploy command group (Pelican) ────────────────────────────────────────


@main.group()
@click.pass_context
def deploy(ctx: click.Context) -> None:
    """Server management via Pelican Panel."""
    pass


@deploy.command()
@click.pass_context
def setup(ctx: click.Context) -> None:
    """Interactive Pelican Panel setup wizard."""
    from elm.pelican import PelicanClient, PelicanError

    cfg = _get_cfg(ctx)
    _header("Pelican Panel Setup")

    url = click.prompt("Pelican Panel URL", default=cfg.pelican_url or "https://panel.example.com")
    url = url.rstrip("/")
    cfg.set_global("PELICAN_URL", url)
    _ok(f"Panel URL: {url}")

    api_key = click.prompt("Application API key", hide_input=True)
    cfg.set_key("PELICAN_API_KEY", api_key)
    _ok("API key saved")

    # Test connection
    client = PelicanClient(url=url, api_key=api_key)
    console.print("  Testing connection...", end=" ")
    if client.test_connection():
        console.print("[green]connected[/green]")
    else:
        console.print("[red]failed[/red]")
        _warn("Could not reach panel. Check URL and API key.")
        return

    # List nodes
    try:
        nodes = client.list_nodes()
        if nodes:
            console.print("\n  Available nodes:")
            for n in nodes:
                a = n.get("attributes", {})
                console.print(f"    [{a.get('id')}] {a.get('name')} — {a.get('fqdn', '')}")
            node_id = click.prompt("Node ID", type=int)
            cfg.set_global("PELICAN_NODE_ID", str(node_id))
    except PelicanError:
        _warn("Could not list nodes")

    # List nests → eggs
    try:
        nests = client.list_nests()
        if nests:
            console.print("\n  Available nests:")
            for n in nests:
                a = n.get("attributes", {})
                console.print(f"    [{a.get('id')}] {a.get('name')}")
            nest_id = click.prompt("Nest ID", type=int)
            cfg.set_global("PELICAN_NEST_ID", str(nest_id))

            eggs = client.list_eggs(nest_id)
            if eggs:
                console.print("\n  Available eggs:")
                for e in eggs:
                    a = e.get("attributes", {})
                    console.print(f"    [{a.get('id')}] {a.get('name')}")
                egg_id = click.prompt("Egg ID", type=int)
                cfg.set_global("PELICAN_EGG_ID", str(egg_id))
    except PelicanError:
        _warn("Could not list nests/eggs")

    # List users
    try:
        users = client.list_users()
        if users:
            console.print("\n  Available users:")
            for u in users:
                a = u.get("attributes", {})
                console.print(f"    [{a.get('id')}] {a.get('username')} ({a.get('email', '')})")
            user_id = click.prompt("User ID (server owner)", type=int)
            cfg.set_global("PELICAN_USER_ID", str(user_id))
    except PelicanError:
        _warn("Could not list users")

    _ok("Pelican Panel configured")


@deploy.command()
@click.option("-t", "--target", required=True, help="Target name")
@click.pass_context
def create(ctx: click.Context, target: str) -> None:
    """Create a Pelican server for a target."""
    from elm.pelican import create_target_server, PelicanError

    cfg = _get_cfg(ctx)
    _header(f"Creating Server: {target}")
    try:
        attrs = create_target_server(cfg, target)
        _ok(f"Server created — ID: {attrs.get('id')}, UUID: {attrs.get('uuid', '')[:8]}...")
    except PelicanError as e:
        _fail(f"{e.body or str(e)}")
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
        power_target(cfg, target, signal)
        _ok(f"{signal.title()} signal sent to {target}")
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
        _ok(f"Command sent: {command}")
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
        data = status_target(cfg, target)
        attrs = data.get("attributes", {})
        resources = attrs.get("resources", {})
        state = attrs.get("current_state", "unknown")

        color = {"running": "green", "stopped": "red", "starting": "yellow"}.get(state, "dim")
        console.print(f"\n  Server: [bold]{target}[/bold]")
        console.print(f"  State:  [{color}]{state}[/{color}]")
        if resources:
            mem = resources.get("memory_bytes", 0) / 1024 / 1024
            cpu = resources.get("cpu_absolute", 0)
            disk = resources.get("disk_bytes", 0) / 1024 / 1024
            console.print(f"  CPU:    {cpu:.1f}%")
            console.print(f"  RAM:    {mem:.0f} MB")
            console.print(f"  Disk:   {disk:.0f} MB")
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
        backup_target(cfg, target)
        _ok("Backup created")
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
        delete_target_server(cfg, target)
        _ok(f"Server {target} deleted")
    except PelicanError as e:
        _fail(str(e))
        sys.exit(1)


# ── Target management ─────────────────────────────────────────────────────


@main.group()
@click.pass_context
def target(ctx: click.Context) -> None:
    """Manage deployment targets."""
    pass


@target.command(name="ls")
@click.pass_context
def target_ls(ctx: click.Context) -> None:
    """List all targets."""
    targets = load_targets()
    if not targets:
        console.print("  No targets configured.")
        return

    table = Table(title="Targets")
    table.add_column("Name", style="cyan")
    table.add_column("Domain")
    table.add_column("Port")
    table.add_column("Pelican ID", style="dim")
    for name, data in targets.items():
        table.add_row(
            name,
            data.get("domain", ""),
            str(data.get("port", "")),
            str(data.get("pelican_server_id", "")),
        )
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
    _ok(f"Target '{name}' added")


@target.command(name="rm")
@click.argument("name")
@click.pass_context
def target_rm(ctx: click.Context, name: str) -> None:
    """Remove a deployment target."""
    target_remove(name)
    _ok(f"Target '{name}' removed")


@target.command(name="show")
@click.argument("name")
@click.pass_context
def target_show(ctx: click.Context, name: str) -> None:
    """Show target details."""
    targets = load_targets()
    data = targets.get(name)
    if not data:
        _fail(f"Target '{name}' not found")
        return
    console.print(f"\n  [bold cyan]{name}[/bold cyan]")
    for k, v in sorted(data.items()):
        console.print(f"    {k}: {v}")


# ── Key management ────────────────────────────────────────────────────────


@main.group()
@click.pass_context
def key(ctx: click.Context) -> None:
    """Manage API keys."""
    pass


@key.command(name="set")
@click.argument("provider", type=click.Choice(["pelican", "curseforge"]))
@click.argument("token")
@click.pass_context
def key_set(ctx: click.Context, provider: str, token: str) -> None:
    """Store an API key."""
    cfg = _get_cfg(ctx)
    key_map = {
        "pelican": "PELICAN_API_KEY",
        "curseforge": "CURSEFORGE_API_KEY",
    }
    cfg.set_key(key_map[provider], token)
    _ok(f"{provider.title()} API key saved")

    # Test Pelican connection
    if provider == "pelican" and cfg.pelican_url:
        from elm.pelican import PelicanClient

        client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=token)
        if client.test_connection():
            _ok("Connection verified")
        else:
            _warn("Could not reach panel")


@key.command(name="show")
@click.pass_context
def key_show(ctx: click.Context) -> None:
    """Show stored keys (masked)."""
    cfg = _get_cfg(ctx)
    for label, key_name in [("Pelican", "PELICAN_API_KEY"), ("CurseForge", "CURSEFORGE_API_KEY")]:
        masked = cfg.mask_key(key_name)
        status = masked if masked else "[dim]not set[/dim]"
        console.print(f"  {label}: {status}")


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


@main.group(name="config")
@click.pass_context
def config_group(ctx: click.Context) -> None:
    """View and edit configuration."""
    pass


@config_group.command(name="show")
@click.pass_context
def config_show(ctx: click.Context) -> None:
    """Show current configuration."""
    cfg = _get_cfg(ctx)
    table = Table(title="Configuration")
    table.add_column("Key", style="cyan")
    table.add_column("Value")
    for k in sorted(cfg.values):
        v = cfg.values[k]
        if "KEY" in k or "TOKEN" in k:
            v = cfg.mask_key(k) or "[dim]not set[/dim]"
        table.add_row(k, v or "[dim]empty[/dim]")
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


@main.command()
@click.pass_context
def check(ctx: click.Context) -> None:
    """Run diagnostics."""
    import shutil

    cfg = _get_cfg(ctx)
    _header("ELM Diagnostics")

    # packwiz
    pw_path = shutil.which(cfg.packwiz_bin)
    if pw_path:
        _ok(f"packwiz: {pw_path}")
    else:
        _fail(f"packwiz not found (expected: {cfg.packwiz_bin})")

    # pack.toml
    if cfg.pack_toml.is_file():
        _ok(f"pack.toml: {cfg.pack_toml}")
    else:
        _warn(f"No pack.toml at {cfg.pack_toml}")

    # mods.txt
    if cfg.mods_file.is_file():
        lines = [ln for ln in cfg.mods_file.read_text().splitlines() if ln.strip() and not ln.startswith("#")]
        _ok(f"mods.txt: {len(lines)} entries")
    else:
        _warn("No mods.txt")

    # Pelican
    if cfg.pelican_url:
        _ok(f"Pelican URL: {cfg.pelican_url}")
        if cfg.pelican_api_key:
            from elm.pelican import PelicanClient

            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=cfg.pelican_api_key)
            if client.test_connection():
                _ok("Pelican: connected")
            else:
                _warn("Pelican: could not connect")
        else:
            _warn("Pelican API key not set")
    else:
        console.print("  [dim]Pelican: not configured[/dim]")

    # Targets
    names = target_list()
    console.print(f"  Targets: {len(names)} configured")


# ── Backwards-compat aliases ──────────────────────────────────────────────

# Allow 'elm remove' as alias for 'elm rm'
main.add_command(rm, "remove")
# Allow 'elm list' as alias for 'elm ls'
main.add_command(list_mods, "list")


if __name__ == "__main__":
    main()
