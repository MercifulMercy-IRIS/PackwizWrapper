"""Target management commands."""

from __future__ import annotations

import typer
from rich.table import Table

from elm.config import load_targets, target_set, target_remove
from elm.ui import console, _fail, _ok, _hint, _info

target_app = typer.Typer(help="Manage deployment targets.")


@target_app.command(name="ls")
def target_ls() -> None:
    """List all targets."""
    targets = load_targets()
    if not targets:
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


@target_app.command()
def add(
    name: str = typer.Argument(..., help="Target name"),
    domain: str = typer.Option("", "-d", "--domain", help="Server domain"),
    port: int = typer.Option(25565, "-p", "--port", help="Server port"),
    ram: int = typer.Option(0, "--ram", help="RAM in MB"),
) -> None:
    """Add a deployment target."""
    fields: dict = {"domain": domain, "port": port}
    if ram:
        fields["ram"] = ram
    target_set(name, **fields)
    _ok(f"Target [cyan]{name}[/cyan] added")
    _hint(f"Create server:  elm deploy create -t {name}")


@target_app.command()
def rm(
    name: str = typer.Argument(..., help="Target name"),
) -> None:
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


@target_app.command()
def show(
    name: str = typer.Argument(..., help="Target name"),
) -> None:
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
