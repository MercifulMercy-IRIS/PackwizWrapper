"""Mod management commands — add, rm, update, search, sync, list."""

from __future__ import annotations

from typing import Optional

import typer
from rich.table import Table

from elm.config import load_config
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header

mod_app = typer.Typer(help="Mod management commands.")


@mod_app.command()
def add(
    slugs: list[str] = typer.Argument(..., help="Mod slug(s) to install"),
    source: str = typer.Option("", "-s", "--source", help="Source: mr (Modrinth) or cf (CurseForge)"),
) -> None:
    """Add one or more mods."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import refresh_index

    cfg = load_config()
    _header("Adding Mods")

    ok_count = 0
    for slug in slugs:
        try:
            with console.status(f"  Resolving [cyan]{slug}[/cyan]..."):
                resolved = install_mod(slug, cfg, source=source)
            _ok(f"Added [cyan]{resolved.name}[/cyan] ({resolved.source}:{resolved.slug})")
            _hint(f"{resolved.filename}")
            ok_count += 1
        except ResolveError as e:
            _fail(f"Could not add [cyan]{slug}[/cyan]")
            _hint(str(e))

    if ok_count > 0:
        refresh_index(cfg.pack_dir)
        _ok("Index updated")


@mod_app.command()
def rm(
    slugs: list[str] = typer.Argument(..., help="Mod slug(s) to remove"),
) -> None:
    """Remove one or more mods."""
    from elm.core.packwiz import remove_mod_toml, refresh_index

    cfg = load_config()
    _header("Removing Mods")

    ok_count = 0
    for slug in slugs:
        if remove_mod_toml(cfg.pack_dir, slug):
            _ok(f"Removed [cyan]{slug}[/cyan]")
            ok_count += 1
        else:
            _fail(f"Mod [cyan]{slug}[/cyan] not found")

    if ok_count > 0:
        refresh_index(cfg.pack_dir)
        _ok("Index updated")


@mod_app.command()
def update(
    slug: Optional[str] = typer.Argument(None, help="Mod slug to update (all if omitted)"),
) -> None:
    """Update a mod, or all mods."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import list_mod_tomls, read_mod_toml, refresh_index

    cfg = load_config()

    if slug:
        _header(f"Updating {slug}")
        mods_to_update = [slug]
    else:
        _header("Updating All Mods")
        mods_to_update = list_mod_tomls(cfg.pack_dir)
        if not mods_to_update:
            _info("No mods installed.")
            return

    ok_count = 0
    for mod_slug in mods_to_update:
        try:
            with console.status(f"  Checking [cyan]{mod_slug}[/cyan]..."):
                resolved = install_mod(mod_slug, cfg)
            _ok(f"Updated [cyan]{resolved.name}[/cyan]")
            ok_count += 1
        except ResolveError as e:
            _warn(f"Could not update [cyan]{mod_slug}[/cyan]: {e}")

    if ok_count > 0:
        refresh_index(cfg.pack_dir)
    _ok(f"Updated {ok_count}/{len(mods_to_update)} mods")


@mod_app.command(name="ls")
def list_mods() -> None:
    """List installed mods."""
    from elm.core.packwiz import list_mod_tomls

    cfg = load_config()
    mods = list_mod_tomls(cfg.pack_dir)

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


@mod_app.command()
def search(
    query: str = typer.Argument(..., help="Search query"),
    source: str = typer.Option("", "-s", "--source", help="Source: mr or cf"),
) -> None:
    """Search for mods."""
    cfg = load_config()
    effective_source = source or cfg.prefer_source

    with console.status(f"  Searching for [cyan]{query}[/cyan]..."):
        if effective_source == "cf":
            from elm.core.curseforge import search as cf_search
            api_key = cfg.get("CURSEFORGE_API_KEY")
            if not api_key:
                _fail("CurseForge API key not set. Run: elm key set curseforge")
                return
            results = cf_search(query, api_key, mc_version=cfg.mc_version, loader=cfg.loader)
            items = [(r.slug, r.name, f"{r.download_count:,} downloads") for r in results]
        else:
            from elm.core.modrinth import search as mr_search
            results = mr_search(query)
            items = [(r.slug, r.title, f"{r.downloads:,} downloads") for r in results]

    if not items:
        _info(f"No results for [cyan]{query}[/cyan]")
        _hint("Try a different query or check the source (-s mr / -s cf)")
        return

    table = Table(
        title=f"Search Results: {query}",
        border_style="dim",
        title_style="bold",
        padding=(0, 1),
    )
    table.add_column("Slug", style="cyan")
    table.add_column("Name")
    table.add_column("Downloads", style="dim", justify="right")

    for slug_val, name, downloads in items:
        table.add_row(slug_val, name, downloads)

    console.print()
    console.print(table)
    _hint(f"Install with: elm add <slug>")


@mod_app.command()
def sync() -> None:
    """Sync mods from mods.txt."""
    from elm.core.resolver import install_mod, ResolveError
    from elm.core.packwiz import list_mod_tomls, refresh_index

    cfg = load_config()
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
        # Check if already installed (rough match)
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
        _warn(f"Failed to add: {', '.join(failed)}")
        # Write unresolved
        cfg.unresolved_file.write_text("\n".join(failed) + "\n")
        _hint(f"See {cfg.unresolved_file}")

    if added > 0:
        refresh_index(cfg.pack_dir)
        _ok("Index updated")
    elif not failed:
        _ok("Everything is up to date")
