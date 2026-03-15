"""Packwiz-compatible TOML file generator.

Generates pack.toml and per-mod .toml files that are fully compatible with
the packwiz format, so clients can use them for modpack distribution.
No packwiz binary required — pure Python.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore[no-redef]


class PackwizError(Exception):
    """Raised when a packwiz operation fails."""


@dataclass
class ModEntry:
    """Represents a mod entry in the packwiz format."""

    name: str
    filename: str
    side: str = "both"
    download_url: str = ""
    download_hash_format: str = "sha512"
    download_hash: str = ""
    update_modrinth_mod_id: str = ""
    update_modrinth_version: str = ""
    update_curseforge_file_id: int = 0
    update_curseforge_project_id: int = 0


def _hash_file(path: Path, algo: str = "sha512") -> str:
    """Compute a hash of a file."""
    h = hashlib.new(algo)
    h.update(path.read_bytes())
    return h.hexdigest()


def write_pack_toml(
    pack_dir: Path,
    *,
    name: str,
    mc_version: str,
    loader: str,
    loader_version: str = "",
    pack_format: str = "packwiz:1.1.0",
) -> Path:
    """Generate a pack.toml file."""
    lines = [
        f'pack-format = "{pack_format}"',
        "",
        "[pack]",
        f'name = "{name}"',
        "",
        "[versions]",
        f'minecraft = "{mc_version}"',
    ]
    if loader_version:
        lines.append(f'{loader} = "{loader_version}"')
    else:
        lines.append(f'# {loader} version will be auto-detected')

    lines.extend([
        "",
        "[index]",
        'file = "index.toml"',
        'hash-format = "sha256"',
    ])

    path = pack_dir / "pack.toml"
    path.write_text("\n".join(lines) + "\n")
    return path


def write_mod_toml(
    pack_dir: Path,
    entry: ModEntry,
) -> Path:
    """Write a per-mod .toml file in the mods/ directory."""
    mods_dir = pack_dir / "mods"
    mods_dir.mkdir(parents=True, exist_ok=True)

    lines = [
        f'name = "{entry.name}"',
        f'filename = "{entry.filename}"',
        f'side = "{entry.side}"',
        "",
        "[download]",
        f'url = "{entry.download_url}"',
        f'hash-format = "{entry.download_hash_format}"',
        f'hash = "{entry.download_hash}"',
    ]

    # Add update section based on source
    if entry.update_modrinth_mod_id:
        lines.extend([
            "",
            "[update]",
            "[update.modrinth]",
            f'mod-id = "{entry.update_modrinth_mod_id}"',
            f'version = "{entry.update_modrinth_version}"',
        ])
    elif entry.update_curseforge_project_id:
        lines.extend([
            "",
            "[update]",
            "[update.curseforge]",
            f"file-id = {entry.update_curseforge_file_id}",
            f"project-id = {entry.update_curseforge_project_id}",
        ])

    # Sanitize filename for the toml file
    slug = entry.name.lower().replace(" ", "-")
    for ch in "/:*?\"<>|":
        slug = slug.replace(ch, "")

    path = mods_dir / f"{slug}.toml"
    path.write_text("\n".join(lines) + "\n")
    return path


def remove_mod_toml(pack_dir: Path, slug: str) -> bool:
    """Remove a mod's .toml file. Returns True if found and removed."""
    mods_dir = pack_dir / "mods"
    path = mods_dir / f"{slug}.toml"
    if path.is_file():
        path.unlink()
        return True
    # Try case-insensitive match
    if mods_dir.is_dir():
        for p in mods_dir.glob("*.toml"):
            if p.stem.lower() == slug.lower():
                p.unlink()
                return True
    return False


def list_mod_tomls(pack_dir: Path) -> list[str]:
    """List installed mod slugs by reading the mods directory."""
    mods_dir = pack_dir / "mods"
    if not mods_dir.is_dir():
        return []
    return sorted(p.stem for p in mods_dir.glob("*.toml"))


def read_mod_toml(pack_dir: Path, slug: str) -> dict[str, Any] | None:
    """Read and parse a mod's .toml file."""
    mods_dir = pack_dir / "mods"
    path = mods_dir / f"{slug}.toml"
    if not path.is_file():
        # Try case-insensitive
        if mods_dir.is_dir():
            for p in mods_dir.glob("*.toml"):
                if p.stem.lower() == slug.lower():
                    path = p
                    break
            else:
                return None
        else:
            return None
    return tomllib.loads(path.read_text())


def write_index_toml(pack_dir: Path) -> Path:
    """Generate index.toml listing all mod files with their hashes."""
    mods_dir = pack_dir / "mods"
    entries: list[str] = ['hash-format = "sha256"', ""]

    if mods_dir.is_dir():
        for toml_file in sorted(mods_dir.glob("*.toml")):
            rel_path = f"mods/{toml_file.name}"
            file_hash = _hash_file(toml_file, "sha256")
            metafile = "true"
            entries.extend([
                "[[files]]",
                f'file = "{rel_path}"',
                f'hash = "{file_hash}"',
                f"metafile = {metafile}",
                "",
            ])

    path = pack_dir / "index.toml"
    path.write_text("\n".join(entries) + "\n")
    return path


def refresh_index(pack_dir: Path) -> bool:
    """Regenerate index.toml and update the hash in pack.toml.

    Returns True on success.
    """
    if not (pack_dir / "pack.toml").is_file():
        return False

    # Write index
    index_path = write_index_toml(pack_dir)

    # Update pack.toml with index hash
    index_hash = _hash_file(index_path, "sha256")
    pack_path = pack_dir / "pack.toml"
    content = pack_path.read_text()

    # Update or add hash line in [index] section
    lines = content.splitlines()
    new_lines: list[str] = []
    in_index = False
    hash_written = False
    for line in lines:
        if line.strip() == "[index]":
            in_index = True
            new_lines.append(line)
            continue
        if in_index and line.strip().startswith("[") and line.strip() != "[index]":
            if not hash_written:
                new_lines.append(f'hash = "{index_hash}"')
                hash_written = True
            in_index = False
        if in_index and line.strip().startswith("hash ="):
            new_lines.append(f'hash = "{index_hash}"')
            hash_written = True
            continue
        new_lines.append(line)

    if not hash_written:
        new_lines.append(f'hash = "{index_hash}"')

    pack_path.write_text("\n".join(new_lines) + "\n")
    return True
