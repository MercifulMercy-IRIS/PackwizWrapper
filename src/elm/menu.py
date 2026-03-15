"""Interactive terminal menu for ELM.

Launched when the user runs `elm` with no arguments.
Arrow-key navigable, categorized, plain-English labels.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import typer
from rich.panel import Panel
from rich.table import Table
from simple_term_menu import TerminalMenu

from elm import __version__
from elm.config import (
    Config,
    DEFAULTS,
    load_config,
    load_targets,
    target_list,
    target_remove,
    target_set,
)
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header


# ── Menu definition ──────────────────────────────────────────────────────

MAIN_MENU: list[str] = [
    "── Mods ──────────────────────",
    "   Install a mod",
    "   Remove a mod",
    "   Update all mods",
    "   Sync from mods.txt",
    "   Show installed mods",
    "   Search for a mod",
    "── Modpack ───────────────────",
    "   Create new modpack",
    "   Refresh mod index",
    "   Update ELM",
    "── Servers ───────────────────",
    "   Panel setup",
    "   Create a server",
    "   Start a server",
    "   Stop a server",
    "   Restart a server",
    "   Server status",
    "   Run console command",
    "   Back up a server",
    "   Delete a server",
    "── Dependencies ──────────────",
    "   Check all dependencies",
    "   Install a dependency",
    "── Settings ──────────────────",
    "   View settings",
    "   Change a setting",
    "   Manage targets",
    "   Manage API keys",
    "   Run diagnostics",
    "──────────────────────────────",
    "   Quit",
]


def _pick(title: str, items: list[str]) -> int | None:
    """Show a sub-menu and return the selected index, or None on escape."""
    menu = TerminalMenu(
        items,
        title=f"\n  {title}\n",
        menu_cursor="  ❯ ",
        menu_cursor_style=("fg_cyan", "bold"),
        menu_highlight_style=("fg_cyan", "bold"),
    )
    idx = menu.show()
    return idx


def _pick_target(cfg: Config, action: str = "select") -> str | None:
    """Let the user pick a target from a list."""
    names = target_list()
    if not names:
        _warn("No targets configured yet.")
        _hint("Add one first:  elm target add <name> -d <domain>")
        return None

    items = [*names, "", "← Back"]
    idx = _pick(f"Pick a target to {action}", items)
    if idx is None or items[idx] == "← Back" or items[idx] == "":
        return None
    return items[idx]


def _pause() -> None:
    """Wait for the user to press Enter before returning to menu."""
    console.print()
    console.input("  [dim]Press Enter to continue...[/dim]")


# ── Action handlers ──────────────────────────────────────────────────────


def action_add_mod(cfg: Config) -> None:
    """Prompt for mod name(s), install them."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import refresh_index

    _header("Install a Mod")
    raw = typer.prompt("  Mod name(s), separated by spaces")
    slugs = raw.strip().split()
    if not slugs:
        return

    ok_count = 0
    for slug in slugs:
        try:
            with console.status(f"  Resolving [cyan]{slug}[/cyan]..."):
                resolved = install_mod(slug, cfg)
            _ok(f"Installed [cyan]{resolved.name}[/cyan]")
            ok_count += 1
        except ResolveError as exc:
            _fail(f"Could not install [cyan]{slug}[/cyan]")
            _hint(str(exc))

    if ok_count:
        refresh_index(cfg.pack_dir)
        _ok("Index updated")


def action_remove_mod(cfg: Config) -> None:
    """Show installed mods, let user pick one to remove."""
    from elm.core.packwiz import list_mod_tomls, remove_mod_toml, refresh_index

    mods = list_mod_tomls(cfg.pack_dir)
    if not mods:
        _info("No mods installed.")
        return

    items = [*mods, "", "← Back"]
    idx = _pick("Pick a mod to remove", items)
    if idx is None or items[idx] == "← Back" or items[idx] == "":
        return

    slug = items[idx]
    if remove_mod_toml(cfg.pack_dir, slug):
        _ok(f"Removed [cyan]{slug}[/cyan]")
        refresh_index(cfg.pack_dir)
        _ok("Index updated")
    else:
        _fail(f"Could not remove [cyan]{slug}[/cyan]")


def action_update_mods(cfg: Config) -> None:
    """Update all mods."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import list_mod_tomls, refresh_index

    _header("Updating All Mods")
    mods = list_mod_tomls(cfg.pack_dir)
    if not mods:
        _info("No mods installed.")
        return

    ok_count = 0
    for slug in mods:
        try:
            with console.status(f"  Checking [cyan]{slug}[/cyan]..."):
                install_mod(slug, cfg)
            _ok(f"Updated [cyan]{slug}[/cyan]")
            ok_count += 1
        except ResolveError as exc:
            _warn(f"Could not update [cyan]{slug}[/cyan]: {exc}")

    if ok_count:
        refresh_index(cfg.pack_dir)
    _ok(f"Updated {ok_count}/{len(mods)} mods")


def action_sync(cfg: Config) -> None:
    """Sync mods from mods.txt."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import list_mod_tomls, refresh_index

    _header("Syncing from mods.txt")
    if not cfg.mods_file.is_file():
        _fail(f"No mods.txt found at [dim]{cfg.mods_file}[/dim]")
        _hint("Create a mods.txt with one mod slug per line")
        return

    lines = [
        ln.strip()
        for ln in cfg.mods_file.read_text().splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]

    installed = set(list_mod_tomls(cfg.pack_dir))
    added = 0
    skipped = 0
    failed: list[str] = []

    for raw_slug in lines:
        slug = raw_slug.split(":")[-1] if ":" in raw_slug else raw_slug
        slug = slug.lstrip("!")
        if slug in installed:
            skipped += 1
            continue
        try:
            with console.status(f"  Installing [cyan]{slug}[/cyan]..."):
                install_mod(raw_slug, cfg)
            _ok(f"Added [cyan]{slug}[/cyan]")
            added += 1
        except ResolveError:
            failed.append(slug)

    if added:
        _ok(f"Added {added} new mod{'s' if added != 1 else ''}")
    if skipped:
        _info(f"Skipped {skipped} already installed")
    if failed:
        _warn(f"Failed: {', '.join(failed)}")
    if added:
        from elm.core.packwiz import refresh_index
        refresh_index(cfg.pack_dir)
        _ok("Index updated")
    elif not failed:
        _ok("Everything up to date")


def action_list_mods(cfg: Config) -> None:
    """Show installed mods in a table."""
    from elm.core.packwiz import list_mod_tomls

    mods = list_mod_tomls(cfg.pack_dir)
    if not mods:
        _header("Installed Mods")
        _info("No mods installed yet.")
        _hint("Use 'Install a mod' from the menu to get started")
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


def action_search(cfg: Config) -> None:
    """Search for a mod."""
    query = typer.prompt("  Search for")
    source = cfg.prefer_source

    with console.status(f"  Searching for [cyan]{query}[/cyan]..."):
        if source == "cf":
            from elm.core.curseforge import search as cf_search
            api_key = cfg.get("CURSEFORGE_API_KEY")
            if not api_key:
                _fail("CurseForge API key not set")
                return
            results = cf_search(query, api_key, mc_version=cfg.mc_version, loader=cfg.loader)
            items = [(r.slug, r.name, f"{r.download_count:,}") for r in results]
        else:
            from elm.core.modrinth import search as mr_search
            results = mr_search(query)
            items = [(r.slug, r.title, f"{r.downloads:,}") for r in results]

    if not items:
        _info(f"No results for [cyan]{query}[/cyan]")
        return

    table = Table(title=f"Results: {query}", border_style="dim", padding=(0, 1))
    table.add_column("Slug", style="cyan")
    table.add_column("Name")
    table.add_column("Downloads", style="dim", justify="right")
    for slug_val, name, dl in items:
        table.add_row(slug_val, name, dl)
    console.print()
    console.print(table)


def action_init(cfg: Config) -> None:
    """Initialize a new pack."""
    from elm.core.packwiz import write_pack_toml, write_index_toml

    _header("New Modpack")
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
        (cfg.pack_dir / "mods").mkdir(parents=True, exist_ok=True)
    _ok(f"Pack initialized: [cyan]{name}[/cyan]")


def action_refresh(cfg: Config) -> None:
    """Refresh pack index."""
    from elm.core.packwiz import refresh_index

    _header("Refreshing Mod Index")
    if refresh_index(cfg.pack_dir):
        _ok("Index updated (sha256)")
    else:
        _fail("Refresh failed — no pack.toml found")


def action_self_update(cfg: Config) -> None:
    """Self-update ELM from GitHub."""
    from elm.updater import run_full_update, print_result

    _header("Update ELM")
    repo = cfg.get("ELM_GITHUB_REPO")
    if not repo:
        _fail("ELM_GITHUB_REPO not set.")
        _hint("Set it: elm config set ELM_GITHUB_REPO youruser/repo")
        return

    branch = cfg.get("ELM_GITHUB_BRANCH") or "main"
    _info(f"Repo: [cyan]{repo}[/cyan]  Branch: [cyan]{branch}[/cyan]")

    with console.status("  Updating ELM..."):
        result = run_full_update(cfg)
    print_result(result)


# ── Server actions ────────────────────────────────────────────────────────


def action_deploy_setup(cfg: Config) -> None:
    """Interactive Pelican Panel setup."""
    from elm.core.pelican import PelicanClient, PelicanError

    _header("Pelican Panel Setup")
    console.print()

    url = typer.prompt("  Panel URL", default=cfg.pelican_url or "https://panel.example.com")
    url = url.rstrip("/")
    cfg.set_global("PELICAN_URL", url)
    _ok(f"Panel URL: [cyan]{url}[/cyan]")

    api_key = typer.prompt("  Application API key", hide_input=True)
    cfg.set_key("PELICAN_API_KEY", api_key)
    _ok("API key saved")

    client = PelicanClient(url=url, api_key=api_key)
    with console.status("  Testing connection..."):
        connected = client.test_connection()
    if connected:
        _ok("Connected to panel")
    else:
        _fail("Could not reach panel — check URL and key")
        return

    # Nodes
    try:
        nodes = client.list_nodes()
        if nodes:
            items = [f"{n['attributes']['id']} — {n['attributes']['name']}" for n in nodes]
            idx = _pick("Select a node", items)
            if idx is not None:
                node_id = nodes[idx]["attributes"]["id"]
                cfg.set_global("PELICAN_NODE_ID", str(node_id))
                _ok(f"Node: {node_id}")
    except PelicanError:
        _warn("Could not list nodes")

    # Eggs
    try:
        nests = client.list_nests()
        if nests:
            items = [f"{n['attributes']['id']} — {n['attributes']['name']}" for n in nests]
            idx = _pick("Select a nest", items)
            if idx is not None:
                nest_id = nests[idx]["attributes"]["id"]
                cfg.set_global("PELICAN_NEST_ID", str(nest_id))

                eggs = client.list_eggs(nest_id)
                if eggs:
                    items = [f"{e['attributes']['id']} — {e['attributes']['name']}" for e in eggs]
                    idx = _pick("Select an egg", items)
                    if idx is not None:
                        egg_id = eggs[idx]["attributes"]["id"]
                        cfg.set_global("PELICAN_EGG_ID", str(egg_id))
                        _ok(f"Egg: {egg_id}")
    except PelicanError:
        _warn("Could not list nests/eggs")

    # Users
    try:
        users = client.list_users()
        if users:
            items = [f"{u['attributes']['id']} — {u['attributes']['username']}" for u in users]
            idx = _pick("Select the server owner", items)
            if idx is not None:
                user_id = users[idx]["attributes"]["id"]
                cfg.set_global("PELICAN_USER_ID", str(user_id))
                _ok(f"User: {user_id}")
    except PelicanError:
        _warn("Could not list users")

    console.print()
    _ok("Setup complete")
    _hint("Next: Manage targets → add a target, then create a server")


def action_create_server(cfg: Config) -> None:
    """Create a Pelican server."""
    from elm.core.pelican import create_target_server, PelicanError

    _header("Create Server")
    name = typer.prompt("  Target name")
    domain = typer.prompt("  Domain (optional)", default="")

    targets = load_targets()
    if name not in targets:
        target_set(name, domain=domain, port=25565)
        _ok(f"Target [cyan]{name}[/cyan] created")

    try:
        with console.status(f"  Provisioning [cyan]{name}[/cyan]..."):
            attrs = create_target_server(cfg, name)
        sid = attrs.get("id", "?")
        _ok(f"Server created — ID: {sid}")
    except PelicanError as exc:
        _fail(exc.body or str(exc))


def _server_action(cfg: Config, action: str) -> None:
    """Common pattern for server actions that need a target pick."""
    from elm.core.pelican import (
        power_target, status_target, command_target,
        backup_target, delete_target_server, PelicanError,
    )

    target = _pick_target(cfg, action)
    if not target:
        return

    try:
        if action in ("start", "stop", "restart"):
            with console.status(f"  Sending {action} to [cyan]{target}[/cyan]..."):
                power_target(cfg, target, action)
            _ok(f"[cyan]{target}[/cyan] {action}ing")

        elif action == "status":
            with console.status("  Fetching status..."):
                data = status_target(cfg, target)
            attrs = data.get("attributes", {})
            resources = attrs.get("resources", {})
            state = attrs.get("current_state", "unknown")

            color = {"running": "green", "stopped": "red", "starting": "yellow",
                     "stopping": "yellow"}.get(state, "dim")
            icon = {"running": "[green]●[/green]", "stopped": "[red]●[/red]",
                    "starting": "[yellow]◐[/yellow]"}.get(state, "[dim]?[/dim]")

            lines = [f"  State:  {icon} [{color}]{state}[/{color}]"]
            if resources:
                mem = resources.get("memory_bytes", 0) / 1024 / 1024
                cpu = resources.get("cpu_absolute", 0)
                disk = resources.get("disk_bytes", 0) / 1024 / 1024
                lines.append(f"  CPU:    {cpu:.1f}%")
                lines.append(f"  RAM:    {mem:.0f} MB")
                lines.append(f"  Disk:   {disk:.0f} MB")

            console.print(Panel(
                "\n".join(lines),
                title=f"[bold]{target}[/bold]",
                border_style="cyan",
                padding=(0, 1),
            ))

        elif action == "console":
            cmd = typer.prompt("  Command to send")
            command_target(cfg, target, cmd)
            _ok(f"Sent: [dim]{cmd}[/dim]")

        elif action == "backup":
            with console.status(f"  Backing up [cyan]{target}[/cyan]..."):
                backup_target(cfg, target)
            _ok(f"Backup created for [cyan]{target}[/cyan]")

        elif action == "delete":
            if not typer.confirm(f"  Delete server '{target}'? This cannot be undone"):
                return
            with console.status(f"  Deleting [cyan]{target}[/cyan]..."):
                delete_target_server(cfg, target)
            _ok(f"Server [cyan]{target}[/cyan] deleted")

    except PelicanError as exc:
        _fail(str(exc))


# ── Dependency actions ────────────────────────────────────────────────────


def action_check_deps(cfg: Config) -> None:
    """Show status of all dependencies."""
    from elm.commands.deps import _dep_status

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
        _hint("Use 'Install a dependency' to set them up")


def action_install_dep(cfg: Config) -> None:
    """Sub-menu to install individual dependencies."""
    _info("Use the CLI to install dependencies:")
    _hint("  elm deps install go")
    _hint("  elm deps install packwiz")
    _hint("  elm deps install curl")
    _hint("  elm deps install git")
    _hint("  elm deps install docker")


# ── Settings actions ──────────────────────────────────────────────────────


def action_view_settings(cfg: Config) -> None:
    """Show configuration grouped by category."""
    categories = {
        "Minecraft": ["MC_VERSION", "LOADER", "LOADER_VERSION"],
        "Mod Sources": ["PREFER_SOURCE", "AUTO_DEPS"],
        "Server": ["SERVER_RAM", "SERVER_DISK", "SERVER_CPU", "SERVER_DOMAIN", "SERVER_VM_IP"],
        "Pelican": ["PELICAN_URL", "PELICAN_NODE_ID", "PELICAN_EGG_ID", "PELICAN_USER_ID"],
        "CDN": ["CDN_DOMAIN", "PACK_HOST_URL"],
        "Updates": ["ELM_GITHUB_REPO", "ELM_GITHUB_BRANCH", "ELM_GITHUB_PATH"],
    }

    for category, keys in categories.items():
        has_values = any(cfg.get(k) for k in keys)
        if not has_values:
            continue

        table = Table(
            title=category, title_style="bold", border_style="dim",
            show_header=False, padding=(0, 1),
        )
        table.add_column("Key", style="cyan", min_width=22)
        table.add_column("Value")
        table.add_column("", width=10)
        for k in keys:
            v = cfg.values.get(k, "")
            if "KEY" in k or "TOKEN" in k:
                v = cfg.mask_key(k) or ""
            default = DEFAULTS.get(k, "")
            marker = "[dim]default[/dim]" if v == default and v else ""
            table.add_row(k, v if v else "[dim]—[/dim]", marker)
        console.print()
        console.print(table)


def action_change_setting(cfg: Config) -> None:
    """Prompt for a setting key and value."""
    key = typer.prompt("  Setting name (e.g. MC_VERSION)")
    current = cfg.get(key.upper())
    if current:
        _info(f"Current: {current}")
    value = typer.prompt(f"  New value for {key.upper()}")
    cfg.set_global(key.upper(), value)
    _ok(f"{key.upper()} = {value}")


def action_manage_targets(cfg: Config) -> None:
    """Sub-menu for target management."""
    while True:
        names = target_list()
        items = ["Add a target", "List targets"]
        if names:
            items.append("Remove a target")
            items.append("Show target details")
        items.extend(["", "← Back"])

        idx = _pick("Manage Targets", items)
        if idx is None or items[idx] == "← Back" or items[idx] == "":
            return

        choice = items[idx]
        if choice == "Add a target":
            name = typer.prompt("  Target name")
            domain = typer.prompt("  Domain (optional)", default="")
            port = typer.prompt("  Port", type=int, default=25565)
            target_set(name, domain=domain, port=port)
            _ok(f"Target [cyan]{name}[/cyan] added")

        elif choice == "List targets":
            targets = load_targets()
            if not targets:
                _info("No targets yet.")
            else:
                table = Table(border_style="dim", padding=(0, 1))
                table.add_column("Name", style="cyan bold")
                table.add_column("Domain")
                table.add_column("Port", justify="right")
                for n, data in targets.items():
                    table.add_row(n, data.get("domain", "") or "—",
                                  str(data.get("port", "")))
                console.print()
                console.print(table)

        elif choice == "Remove a target":
            target = _pick_target(cfg, "remove")
            if target:
                target_remove(target)
                _ok(f"Target [cyan]{target}[/cyan] removed")

        elif choice == "Show target details":
            target = _pick_target(cfg, "view")
            if target:
                targets = load_targets()
                data = targets.get(target, {})
                table = Table(
                    title=target, title_style="bold cyan",
                    border_style="dim", show_header=False, padding=(0, 1),
                )
                table.add_column("Key", style="bold")
                table.add_column("Value")
                for k, v in sorted(data.items()):
                    table.add_row(k, str(v) if v else "[dim]—[/dim]")
                console.print()
                console.print(table)

        _pause()


def action_manage_keys(cfg: Config) -> None:
    """Sub-menu for API key management."""
    while True:
        items = ["Set a key", "Show keys", "Remove a key", "", "← Back"]
        idx = _pick("Manage API Keys", items)
        if idx is None or items[idx] == "← Back" or items[idx] == "":
            return

        choice = items[idx]
        if choice == "Set a key":
            providers = ["pelican", "curseforge"]
            pidx = _pick("Which provider?", [*providers, "", "← Back"])
            if pidx is None or pidx >= len(providers):
                continue
            provider = providers[pidx]
            token = typer.prompt(f"  {provider.title()} API key", hide_input=True)
            key_map = {"pelican": "PELICAN_API_KEY", "curseforge": "CURSEFORGE_API_KEY"}
            cfg.set_key(key_map[provider], token)
            _ok(f"{provider.title()} key saved")

        elif choice == "Show keys":
            table = Table(border_style="dim", show_header=False, padding=(0, 1))
            table.add_column("Provider", style="bold")
            table.add_column("Key")
            for label, key_name in [("Pelican", "PELICAN_API_KEY"),
                                     ("CurseForge", "CURSEFORGE_API_KEY")]:
                masked = cfg.mask_key(key_name)
                table.add_row(label, masked if masked else "[dim]not set[/dim]")
            console.print()
            console.print(table)

        elif choice == "Remove a key":
            providers = ["pelican", "curseforge"]
            pidx = _pick("Which provider?", [*providers, "", "← Back"])
            if pidx is None or pidx >= len(providers):
                continue
            provider = providers[pidx]
            key_map = {"pelican": "PELICAN_API_KEY", "curseforge": "CURSEFORGE_API_KEY"}
            cfg.set_key(key_map[provider], "")
            _ok(f"{provider.title()} key removed")

        _pause()


def action_check(cfg: Config) -> None:
    """Run diagnostics."""
    import shutil

    _header("ELM Diagnostics")
    console.print()

    _info(f"ELM v{__version__}")

    # pack.toml
    if cfg.pack_toml.is_file():
        _ok(f"pack.toml: [dim]{cfg.pack_toml}[/dim]")
    else:
        _warn("No pack.toml found")
        _hint("Use 'Create new modpack' from the menu")

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
        _ok(f"Pelican: [dim]{cfg.pelican_url}[/dim]")
        if cfg.pelican_api_key:
            from elm.core.pelican import PelicanClient
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=cfg.pelican_api_key)
            with console.status("  Testing Pelican..."):
                ok = client.test_connection()
            if ok:
                _ok("Panel: connected")
            else:
                _warn("Panel: could not connect")
        else:
            _warn("Pelican API key not set")
    else:
        _info("Pelican: not configured [dim](optional)[/dim]")
        _hint("Use 'Panel setup' from the Servers menu")

    # Targets
    names = target_list()
    if names:
        _ok(f"Targets: {len(names)} ({', '.join(names)})")
    else:
        _info("No targets configured")

    console.print()


# ── Dispatch table ────────────────────────────────────────────────────────

DISPATCH: dict[str, Any] = {
    "Install a mod": action_add_mod,
    "Remove a mod": action_remove_mod,
    "Update all mods": action_update_mods,
    "Sync from mods.txt": action_sync,
    "Show installed mods": action_list_mods,
    "Search for a mod": action_search,
    "Create new modpack": action_init,
    "Refresh mod index": action_refresh,
    "Update ELM": action_self_update,
    "Panel setup": action_deploy_setup,
    "Create a server": action_create_server,
    "Start a server": lambda cfg: _server_action(cfg, "start"),
    "Stop a server": lambda cfg: _server_action(cfg, "stop"),
    "Restart a server": lambda cfg: _server_action(cfg, "restart"),
    "Server status": lambda cfg: _server_action(cfg, "status"),
    "Run console command": lambda cfg: _server_action(cfg, "console"),
    "Back up a server": lambda cfg: _server_action(cfg, "backup"),
    "Delete a server": lambda cfg: _server_action(cfg, "delete"),
    "Check all dependencies": action_check_deps,
    "Install a dependency": action_install_dep,
    "View settings": action_view_settings,
    "Change a setting": action_change_setting,
    "Manage targets": action_manage_targets,
    "Manage API keys": action_manage_keys,
    "Run diagnostics": action_check,
}


# ── Main menu loop ───────────────────────────────────────────────────────


def run_menu(cfg: Config) -> None:
    """Interactive menu — the main entry point."""
    if not sys.stdin.isatty():
        console.print("Run [cyan]elm --help[/cyan] for usage information.")
        return

    console.print(
        Panel(
            f"[bold cyan]ELM[/bold cyan]  [dim]—[/dim]  EnviousLabs Minecraft\n"
            f"[dim]v{__version__}[/dim]",
            border_style="cyan",
            padding=(0, 2),
        )
    )

    while True:
        try:
            menu = TerminalMenu(
                MAIN_MENU,
                title="\n  Use ↑↓ arrows, Enter to select, Esc to quit\n",
                menu_cursor="  ❯ ",
                menu_cursor_style=("fg_cyan", "bold"),
                menu_highlight_style=("fg_cyan", "bold"),
                skip_empty_entries=True,
            )
            idx = menu.show()
        except OSError:
            console.print("Run [cyan]elm --help[/cyan] for usage information.")
            return

        if idx is None:
            console.print("\n  [dim]Goodbye.[/dim]\n")
            break

        label = MAIN_MENU[idx].strip()

        if label.startswith("──"):
            continue

        if label == "Quit":
            console.print("\n  [dim]Goodbye.[/dim]\n")
            break

        handler = DISPATCH.get(label)
        if handler:
            console.print()
            try:
                handler(cfg)
            except KeyboardInterrupt:
                console.print("\n  [dim]Cancelled.[/dim]")
            except Exception as exc:
                _fail(str(exc))
            _pause()
        else:
            _warn(f"No handler for: {label}")
