"""Shared terminal output helpers for ELM CLI and interactive menu."""

from __future__ import annotations

from rich.console import Console

console = Console(highlight=False)


def _fail(msg: str) -> None:
    console.print(f"  [red bold]FAIL[/red bold]  {msg}")


def _ok(msg: str) -> None:
    console.print(f"  [green bold] OK [/green bold]  {msg}")


def _warn(msg: str) -> None:
    console.print(f"  [yellow bold]WARN[/yellow bold]  {msg}")


def _info(msg: str) -> None:
    console.print(f"  [blue bold]INFO[/blue bold]  {msg}")


def _hint(msg: str) -> None:
    console.print(f"         [dim]{msg}[/dim]")


def _header(msg: str) -> None:
    console.print(f"\n[bold cyan]── {msg} ──[/bold cyan]")
