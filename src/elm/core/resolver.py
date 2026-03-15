"""Mod resolver — unifies Modrinth and CurseForge lookups into packwiz TOML.

Takes a mod slug, figures out which source to use, fetches the download URL,
and generates a packwiz-compatible .toml file.
"""

from __future__ import annotations

from dataclasses import dataclass

from elm.config import Config
from elm.core.packwiz import ModEntry, write_mod_toml


class ResolveError(Exception):
    """Raised when a mod cannot be resolved."""


@dataclass
class ResolvedMod:
    """Result of resolving a mod slug to a download."""

    slug: str
    name: str
    filename: str
    url: str
    hash_value: str
    hash_format: str
    source: str  # "mr" or "cf"
    version_id: str = ""
    project_id: str = ""


def _parse_slug(raw: str) -> tuple[str, str]:
    """Parse a slug that may have a source prefix.

    Examples:
        "mr:sodium" → ("mr", "sodium")
        "cf:jei" → ("cf", "jei")
        "sodium" → ("", "sodium")
        "url:https://..." → ("url", "https://...")
        "!sodium" → ("pin", "sodium")
    """
    if raw.startswith("!"):
        return "pin", raw[1:]
    if ":" in raw:
        prefix, rest = raw.split(":", 1)
        if prefix in ("mr", "cf", "url"):
            return prefix, rest
    return "", raw


def resolve_modrinth(slug: str, cfg: Config) -> ResolvedMod:
    """Resolve a mod slug via the Modrinth API."""
    from elm.core.modrinth import get_project, get_latest_version, ModrinthError

    try:
        project = get_project(slug)
    except ModrinthError as e:
        raise ResolveError(f"Modrinth project '{slug}' not found: {e}") from e

    version = get_latest_version(
        slug,
        mc_version=cfg.mc_version,
        loader=cfg.loader,
    )
    if not version:
        raise ResolveError(
            f"No compatible version of '{slug}' for MC {cfg.mc_version} / {cfg.loader}"
        )

    return ResolvedMod(
        slug=project.slug,
        name=project.title,
        filename=version.filename,
        url=version.url,
        hash_value=version.sha512,
        hash_format="sha512",
        source="mr",
        version_id=version.id,
        project_id=project.id,
    )


def resolve_curseforge(slug: str, cfg: Config) -> ResolvedMod:
    """Resolve a mod slug via the CurseForge API."""
    from elm.core.curseforge import (
        get_mod_by_slug,
        get_latest_file,
        build_download_url,
        CurseForgeError,
    )

    api_key = cfg.get("CURSEFORGE_API_KEY")
    if not api_key:
        raise ResolveError("CurseForge API key not set. Run: elm key set curseforge")

    try:
        mod = get_mod_by_slug(slug, api_key)
    except CurseForgeError as e:
        raise ResolveError(f"CurseForge mod '{slug}' not found: {e}") from e
    if not mod:
        raise ResolveError(f"CurseForge mod '{slug}' not found")

    file = get_latest_file(
        mod.id,
        api_key,
        mc_version=cfg.mc_version,
        loader=cfg.loader,
    )
    if not file:
        raise ResolveError(
            f"No compatible file for '{slug}' on MC {cfg.mc_version} / {cfg.loader}"
        )

    url = file.download_url or build_download_url(mod.id, file.id)

    return ResolvedMod(
        slug=mod.slug,
        name=mod.name,
        filename=file.file_name,
        url=url,
        hash_value="",
        hash_format="sha512",
        source="cf",
        version_id=str(file.id),
        project_id=str(mod.id),
    )


def resolve_url(url: str) -> ResolvedMod:
    """Resolve a direct URL to a mod download."""
    filename = url.rsplit("/", 1)[-1] if "/" in url else "mod.jar"
    name = filename.rsplit(".", 1)[0] if "." in filename else filename
    return ResolvedMod(
        slug=name,
        name=name,
        filename=filename,
        url=url,
        hash_value="",
        hash_format="sha512",
        source="url",
    )


def resolve_mod(raw_slug: str, cfg: Config, *, source: str = "") -> ResolvedMod:
    """Resolve a mod slug to a download, trying the preferred source first.

    Slug format:
        "mr:sodium"    → force Modrinth
        "cf:jei"       → force CurseForge
        "url:https://…" → direct URL
        "!sodium"      → pinned (skip updates), treated as normal resolve
        "sodium"       → auto (try preferred source, then fallback)
    """
    prefix, slug = _parse_slug(raw_slug)

    # Direct URL
    if prefix == "url":
        return resolve_url(slug)

    # Force source from prefix
    effective_source = source or prefix or cfg.prefer_source

    if effective_source == "cf":
        return resolve_curseforge(slug, cfg)

    if effective_source == "mr":
        return resolve_modrinth(slug, cfg)

    # Auto: try Modrinth first, fall back to CurseForge
    try:
        return resolve_modrinth(slug, cfg)
    except ResolveError:
        pass

    try:
        return resolve_curseforge(slug, cfg)
    except ResolveError:
        pass

    raise ResolveError(
        f"Could not find '{slug}' on Modrinth or CurseForge "
        f"for MC {cfg.mc_version} / {cfg.loader}"
    )


def install_mod(raw_slug: str, cfg: Config, *, source: str = "") -> ResolvedMod:
    """Resolve a mod and write its packwiz .toml file.

    Returns the resolved mod info.
    """
    resolved = resolve_mod(raw_slug, cfg, source=source)

    entry = ModEntry(
        name=resolved.name,
        filename=resolved.filename,
        download_url=resolved.url,
        download_hash_format=resolved.hash_format,
        download_hash=resolved.hash_value,
    )

    if resolved.source == "mr":
        entry.update_modrinth_mod_id = resolved.project_id
        entry.update_modrinth_version = resolved.version_id
    elif resolved.source == "cf":
        entry.update_curseforge_project_id = int(resolved.project_id)
        entry.update_curseforge_file_id = int(resolved.version_id)

    write_mod_toml(cfg.pack_dir, entry)
    return resolved
