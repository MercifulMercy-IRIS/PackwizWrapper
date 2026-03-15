"""Interactive terminal menu for ELM.

Launched when the user runs `elm` with no arguments.
Arrow-key navigable, categorized, plain-English labels.
"""

from __future__ import annotations

from typing import Any

import click
from rich.panel import Panel
from rich.table import Table
from simple_term_menu import TerminalMenu

from elm import __version__
from elm.config import (
    Config,
    load_targets,
    target_list,
    target_remove,
    target_set,
)
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header


# ── Menu definition ──────────────────────────────────────────────────────

# Category headers start with ── and are not selectable.
# Selectable items are plain strings.
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

# Indices of category headers (not selectable)
_HEADER_INDICES = [i for i, item in enumerate(MAIN_MENU) if item.startswith("──")]


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
    """Let the user pick a target from a list. Returns name or None."""
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
# Each handler receives the Config, does its work, returns nothing.


def action_add_mod(cfg: Config) -> None:
    """Prompt for mod name(s), install them."""
    from elm.packwiz import add_mod, safe_refresh, PackwizError

    _header("Install a Mod")
    raw = click.prompt("  Mod name(s), separated by spaces")
    slugs = raw.strip().split()
    if not slugs:
        return

    ok_count = 0
    for slug in slugs:
        try:
            with console.status(f"  Installing [cyan]{slug}[/cyan]..."):
                add_mod(cfg, slug)
            _ok(f"Installed [cyan]{slug}[/cyan]")
            ok_count += 1
        except PackwizError as exc:
            _fail(f"Could not install [cyan]{slug}[/cyan]")
            if exc.stderr.strip():
                _hint(exc.stderr.strip().splitlines()[0][:100])

    if ok_count:
        safe_refresh(cfg)


def action_remove_mod(cfg: Config) -> None:
    """Show installed mods, let user pick one to remove."""
    from elm.packwiz import list_mods, remove_mod, safe_refresh, PackwizError

    mods = list_mods(cfg)
    if not mods:
        _info("No mods installed.")
        return

    items = [*mods, "", "← Back"]
    idx = _pick("Pick a mod to remove", items)
    if idx is None or items[idx] == "← Back" or items[idx] == "":
        return

    slug = items[idx]
    try:
        remove_mod(cfg, slug)
        _ok(f"Removed [cyan]{slug}[/cyan]")
        safe_refresh(cfg)
    except PackwizError as exc:
        _fail(f"Could not remove [cyan]{slug}[/cyan]")
        if exc.stderr.strip():
            _hint(exc.stderr.strip().splitlines()[0][:100])


def action_update_mods(cfg: Config) -> None:
    """Update all mods."""
    from elm.packwiz import update_mod, safe_refresh, PackwizError

    _header("Updating All Mods")
    try:
        with console.status("  Checking for updates..."):
            update_mod(cfg)
        _ok("Update complete")
        safe_refresh(cfg)
    except PackwizError as exc:
        _fail("Update failed")
        if exc.stderr.strip():
            _hint(exc.stderr.strip().splitlines()[0][:100])


def action_sync(cfg: Config) -> None:
    """Sync mods from mods.txt."""
    from elm.packwiz import sync_from_modsfile, safe_refresh

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
        _warn(f"Failed: {', '.join(failed)}")
    if added:
        safe_refresh(cfg)
    elif not failed:
        _ok("Everything up to date")


def action_list_mods(cfg: Config) -> None:
    """Show installed mods in a table."""
    from elm.packwiz import list_mods

    mods = list_mods(cfg)
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
    from elm.packwiz import search_mod

    query = click.prompt("  Search for")
    with console.status(f"  Searching for [cyan]{query}[/cyan]..."):
        output = search_mod(cfg, query)
    if output.strip():
        console.print(output)
    else:
        _info(f"No results for [cyan]{query}[/cyan]")
        _hint("Try a different query")


def action_init(cfg: Config) -> None:
    """Initialize a new pack."""
    from elm.packwiz import init_pack, safe_refresh, PackwizError

    _header("New Modpack")
    try:
        with console.status("  Creating pack..."):
            init_pack(cfg)
        _ok("Pack initialized")
        safe_refresh(cfg)
    except PackwizError as exc:
        _fail("Init failed")
        if exc.stderr.strip():
            _hint(exc.stderr.strip().splitlines()[0][:100])


def action_refresh(cfg: Config) -> None:
    """Refresh pack index."""
    from elm.packwiz import safe_refresh

    _header("Refreshing Mod Index")
    safe_refresh(cfg)


def action_self_update(cfg: Config) -> None:
    """Self-update ELM from GitHub (Python package + shell scripts)."""
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
    from elm.pelican import PelicanClient, PelicanError

    _header("Pelican Panel Setup")
    console.print()

    url = click.prompt("  Panel URL", default=cfg.pelican_url or "https://panel.example.com")
    url = url.rstrip("/")
    cfg.set_global("PELICAN_URL", url)
    _ok(f"Panel URL: [cyan]{url}[/cyan]")

    api_key = click.prompt("  Application API key", hide_input=True)
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
    from elm.pelican import create_target_server, PelicanError

    _header("Create Server")
    name = click.prompt("  Target name")
    domain = click.prompt("  Domain (optional)", default="")

    targets = load_targets()
    if name not in targets:
        fields: dict = {"domain": domain, "port": 25565}
        target_set(name, **fields)
        _ok(f"Target [cyan]{name}[/cyan] created")

    try:
        with console.status(f"  Provisioning [cyan]{name}[/cyan]..."):
            attrs = create_target_server(cfg, name)
        sid = attrs.get("id", "?")
        _ok(f"Server created — ID: {sid}")
    except PelicanError as exc:
        _fail(exc.body or str(exc))


def _server_action(cfg: Config, action: str, signal: str = "") -> None:
    """Common pattern for server actions that need a target pick."""
    from elm.pelican import (
        power_target, status_target, command_target,
        backup_target, delete_target_server, PelicanError,
    )

    target = _pick_target(cfg, action)
    if not target:
        return

    try:
        if action == "start":
            with console.status(f"  Starting [cyan]{target}[/cyan]..."):
                power_target(cfg, target, "start")
            _ok(f"[cyan]{target}[/cyan] starting")

        elif action == "stop":
            with console.status(f"  Stopping [cyan]{target}[/cyan]..."):
                power_target(cfg, target, "stop")
            _ok(f"[cyan]{target}[/cyan] stopping")

        elif action == "restart":
            with console.status(f"  Restarting [cyan]{target}[/cyan]..."):
                power_target(cfg, target, "restart")
            _ok(f"[cyan]{target}[/cyan] restarting")

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
            cmd = click.prompt("  Command to send")
            command_target(cfg, target, cmd)
            _ok(f"Sent: [dim]{cmd}[/dim]")

        elif action == "backup":
            with console.status(f"  Backing up [cyan]{target}[/cyan]..."):
                backup_target(cfg, target)
            _ok(f"Backup created for [cyan]{target}[/cyan]")

        elif action == "delete":
            if not click.confirm(f"  Delete server '{target}'? This cannot be undone"):
                return
            with console.status(f"  Deleting [cyan]{target}[/cyan]..."):
                delete_target_server(cfg, target)
            _ok(f"Server [cyan]{target}[/cyan] deleted")

    except PelicanError as exc:
        _fail(str(exc))


# ── Dependency actions ────────────────────────────────────────────────────


# Each dependency: (label, check_cmd, install_hint, installer_func_or_None)
# check_cmd is looked up via shutil.which; special keys handled separately.

def _check_dep(name: str, binary: str) -> bool:
    """Return True if *binary* is on PATH."""
    import shutil
    return shutil.which(binary) is not None


def _dep_status() -> list[tuple[str, str, bool, str]]:
    """Return (label, binary, found, hint) for every dependency."""
    import shutil

    deps: list[tuple[str, str, bool, str]] = []

    # Go
    found = shutil.which("go") is not None or Path("/usr/local/go/bin/go").is_file()
    deps.append(("Go", "go", found, "Required to build packwiz"))

    # packwiz
    found = shutil.which("packwiz") is not None
    deps.append(("packwiz", "packwiz", found, "Mod management CLI"))

    # curl
    found = shutil.which("curl") is not None
    deps.append(("curl", "curl", found, "HTTP downloads & API calls"))

    # jq
    found = shutil.which("jq") is not None
    deps.append(("jq", "jq", found, "JSON processing for targets & APIs"))

    # git
    found = shutil.which("git") is not None
    deps.append(("Git", "git", found, "Version control"))

    # Docker
    found = shutil.which("docker") is not None
    deps.append(("Docker", "docker", found, "Container runtime for servers"))

    # Pelican Panel — check via configured URL + connection test
    from elm.config import load_config
    cfg = load_config()
    pel_ok = False
    if cfg.pelican_url and cfg.pelican_api_key:
        try:
            from elm.pelican import PelicanClient
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=cfg.pelican_api_key)
            pel_ok = client.test_connection()
        except Exception:
            pass
    deps.append(("Pelican Panel", "pelican", pel_ok, "Game server management panel"))

    # Wings
    found = shutil.which("wings") is not None
    deps.append(("Wings", "wings", found, "Pelican server daemon"))

    return deps


def action_check_deps(cfg: Config) -> None:
    """Show status of all dependencies."""
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
        status = "[green bold]found[/green bold]" if found else "[red bold]missing[/red bold]"
        table.add_row(label, status, hint)

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
    import subprocess
    import shutil

    # Build a list of installable items with their installers
    installable: list[tuple[str, str]] = [
        ("Go", "Language runtime needed to build packwiz"),
        ("packwiz", "Mod management CLI (requires Go)"),
        ("curl", "HTTP download tool"),
        ("jq", "JSON processor"),
        ("Git", "Version control"),
        ("Docker", "Container runtime for game servers"),
        ("Pelican Panel", "Game server management web UI"),
        ("Wings", "Pelican server daemon"),
    ]

    while True:
        items = [f"{name}  [dim]— {desc}[/dim]" for name, desc in installable]
        items.extend(["", "← Back"])
        idx = _pick("Install a Dependency", items)
        if idx is None or idx >= len(installable):
            return

        name = installable[idx][0]
        console.print()

        if name == "Go":
            if _check_dep("Go", "go") or Path("/usr/local/go/bin/go").is_file():
                _ok("Go is already installed")
                _pause()
                continue
            _header("Install Go")
            _info("Go is required to build packwiz from source.")
            console.print()
            if not click.confirm("  Install Go system-wide? (requires sudo)"):
                _pause()
                continue
            try:
                import platform
                arch = platform.machine()
                go_arch = {"x86_64": "amd64", "aarch64": "arm64", "AMD64": "amd64"}.get(arch)
                if not go_arch:
                    _fail(f"Unsupported architecture: {arch}")
                    _pause()
                    continue

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
                    _pause()
                    continue

                with console.status("  Installing to /usr/local/go..."):
                    subprocess.run(["sudo", "rm", "-rf", "/usr/local/go"], check=True)
                    subprocess.run(
                        ["sudo", "tar", "-C", "/usr/local", "-xzf", f"/tmp/{tarball}"],
                        check=True,
                    )
                    Path(f"/tmp/{tarball}").unlink(missing_ok=True)

                _ok(f"Go {go_version} installed to /usr/local/go")
                _hint("You may need to add /usr/local/go/bin to your PATH")
                _hint("  export PATH=\"/usr/local/go/bin:$HOME/go/bin:$PATH\"")
            except Exception as exc:
                _fail(f"Installation failed: {exc}")

        elif name == "packwiz":
            if _check_dep("packwiz", "packwiz"):
                _ok(f"packwiz is already installed: {shutil.which('packwiz')}")
                _pause()
                continue
            _header("Install packwiz")
            _info("packwiz is installed via 'go install' (requires Go).")
            console.print()
            go_bin = shutil.which("go") or "/usr/local/go/bin/go"
            if not Path(go_bin).is_file():
                _fail("Go is not installed — install Go first")
                _pause()
                continue
            if not click.confirm("  Install packwiz via go install?"):
                _pause()
                continue
            try:
                import os
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
                    # Symlink to ~/.local/bin
                    local_bin = Path.home() / ".local" / "bin"
                    local_bin.mkdir(parents=True, exist_ok=True)
                    dest = local_bin / "packwiz"
                    dest.unlink(missing_ok=True)
                    dest.symlink_to(pw_path)
                    _ok(f"packwiz installed → {dest}")
                else:
                    _ok("packwiz built (check $GOPATH/bin)")
            except subprocess.CalledProcessError as exc:
                _fail("Build failed")
                if exc.stderr:
                    _hint(exc.stderr.strip().splitlines()[0][:120])
            except Exception as exc:
                _fail(f"Installation failed: {exc}")

        elif name in ("curl", "jq", "Git"):
            binary = {"curl": "curl", "jq": "jq", "Git": "git"}[name]
            if _check_dep(name, binary):
                _ok(f"{name} is already installed")
                _pause()
                continue
            _header(f"Install {name}")
            pkg = {"curl": "curl", "jq": "jq", "Git": "git"}[name]
            _info(f"Install {name} using your system package manager:")
            console.print()
            console.print(f"    [cyan]sudo apt install {pkg}[/cyan]     [dim](Debian/Ubuntu)[/dim]")
            console.print(f"    [cyan]sudo dnf install {pkg}[/cyan]     [dim](Fedora/RHEL)[/dim]")
            console.print(f"    [cyan]sudo pacman -S {pkg}[/cyan]       [dim](Arch)[/dim]")
            console.print(f"    [cyan]brew install {pkg}[/cyan]         [dim](macOS)[/dim]")
            console.print()
            if click.confirm(f"  Attempt auto-install with apt/dnf?"):
                apt = shutil.which("apt-get")
                dnf = shutil.which("dnf")
                pacman = shutil.which("pacman")
                mgr: list[str] = []
                if apt:
                    mgr = ["sudo", "apt-get", "install", "-y", pkg]
                elif dnf:
                    mgr = ["sudo", "dnf", "install", "-y", pkg]
                elif pacman:
                    mgr = ["sudo", "pacman", "-S", "--noconfirm", pkg]
                else:
                    _fail("No supported package manager found (apt, dnf, pacman)")
                    _pause()
                    continue
                try:
                    with console.status(f"  Installing {name}..."):
                        subprocess.run(mgr, check=True)
                    _ok(f"{name} installed")
                except subprocess.CalledProcessError:
                    _fail(f"Failed to install {name}")

        elif name == "Docker":
            if _check_dep("Docker", "docker"):
                _ok("Docker is already installed")
                _pause()
                continue
            _header("Install Docker")
            _info("Docker is best installed via the official script.")
            console.print()
            console.print("    [cyan]curl -fsSL https://get.docker.com | sudo sh[/cyan]")
            console.print()
            if click.confirm("  Run the official Docker install script? (requires sudo)"):
                try:
                    with console.status("  Installing Docker..."):
                        subprocess.run(
                            ["bash", "-c", "curl -fsSL https://get.docker.com | sudo sh"],
                            check=True,
                        )
                    _ok("Docker installed")
                    _hint("Add yourself to the docker group: sudo usermod -aG docker $USER")
                except subprocess.CalledProcessError:
                    _fail("Docker installation failed")

        elif name == "Pelican Panel":
            _header("Install Pelican Panel")
            _info("Pelican Panel is the web UI for managing game servers.")
            _info("It runs as a PHP application with a database backend.")
            console.print()
            _info("Installation options:")
            console.print()
            console.print("    [cyan]1.[/cyan] Docker (recommended):")
            console.print("       [dim]https://pelican.dev/docs/panel/getting-started[/dim]")
            console.print()
            console.print("    [cyan]2.[/cyan] Manual install on a web server:")
            console.print("       [dim]Requires PHP 8.2+, MySQL/MariaDB, Nginx/Caddy[/dim]")
            console.print()
            _hint("After installing, run 'elm deploy setup' to connect ELM to your panel")

        elif name == "Wings":
            _header("Install Wings")
            _info("Wings is the Pelican daemon that runs on each game server node.")
            console.print()
            _info("Installation options:")
            console.print()
            console.print("    [cyan]1.[/cyan] Docker (recommended):")
            console.print("       [dim]https://pelican.dev/docs/wings/getting-started[/dim]")
            console.print()
            console.print("    [cyan]2.[/cyan] Standalone binary:")
            console.print("       [dim]Download from GitHub releases[/dim]")
            console.print()
            _hint("Wings must be configured in Pelican Panel after installation")

        _pause()


# ── Settings actions ──────────────────────────────────────────────────────


def action_view_settings(cfg: Config) -> None:
    """Show configuration grouped by category."""
    from elm.config import DEFAULTS

    categories = {
        "Minecraft": ["MC_VERSION", "LOADER", "LOADER_VERSION"],
        "Packwiz": ["PACKWIZ_BIN", "PREFER_SOURCE", "AUTO_DEPS"],
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
    key = click.prompt("  Setting name (e.g. MC_VERSION)")
    current = cfg.get(key.upper())
    if current:
        _info(f"Current: {current}")
    value = click.prompt(f"  New value for {key.upper()}")
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
            name = click.prompt("  Target name")
            domain = click.prompt("  Domain (optional)", default="")
            port = click.prompt("  Port", type=int, default=25565)
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
            token = click.prompt(f"  {provider.title()} API key", hide_input=True)
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

    pw_path = shutil.which(cfg.packwiz_bin)
    if pw_path:
        _ok(f"packwiz: [dim]{pw_path}[/dim]")
    else:
        _fail(f"packwiz not found (expected: {cfg.packwiz_bin})")
        _hint("Install: https://packwiz.infra.link/installation/")

    if cfg.pack_toml.is_file():
        _ok(f"pack.toml: [dim]{cfg.pack_toml}[/dim]")
    else:
        _warn("No pack.toml found")
        _hint("Use 'Create new modpack' from the menu")

    if cfg.mods_file.is_file():
        lines = [ln for ln in cfg.mods_file.read_text().splitlines()
                 if ln.strip() and not ln.startswith("#")]
        _ok(f"mods.txt: {len(lines)} entries")
    else:
        _info("No mods.txt [dim](optional)[/dim]")

    console.print()
    if cfg.pelican_url:
        _ok(f"Pelican: [dim]{cfg.pelican_url}[/dim]")
        if cfg.pelican_api_key:
            from elm.pelican import PelicanClient
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
    import sys

    # If not an interactive terminal, show help text instead of menu
    if not sys.stdin.isatty():
        from elm.cli import _original_main
        click.echo(_original_main.get_help(click.Context(_original_main)))
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
            # No terminal available — fall back to help
            from elm.cli import _original_main
            click.echo(_original_main.get_help(click.Context(_original_main)))
            return

        # Escape pressed
        if idx is None:
            console.print("\n  [dim]Goodbye.[/dim]\n")
            break

        label = MAIN_MENU[idx].strip()

        # Skip category headers
        if label.startswith("──"):
            continue

        # Quit
        if label == "Quit":
            console.print("\n  [dim]Goodbye.[/dim]\n")
            break

        # Dispatch
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
