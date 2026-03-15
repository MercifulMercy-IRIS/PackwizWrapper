"""CurseForge API client (v1).

Handles searching for mods, fetching mod info, and resolving download URLs.
API docs: https://docs.curseforge.com/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

API_BASE = "https://api.curseforge.com/v1"
MINECRAFT_GAME_ID = 432

# Mod loader type IDs used by CurseForge
LOADER_TYPES: dict[str, int] = {
    "forge": 1,
    "cauldron": 2,
    "liteloader": 3,
    "fabric": 4,
    "quilt": 5,
    "neoforge": 6,
}


class CurseForgeError(Exception):
    """Raised when a CurseForge API call fails."""

    def __init__(self, endpoint: str, status: int, body: str = ""):
        self.endpoint = endpoint
        self.status = status
        self.body = body
        super().__init__(f"CurseForge {endpoint} → HTTP {status}")


@dataclass
class CurseForgeFile:
    """A single file from a CurseForge mod."""

    id: int
    display_name: str
    file_name: str
    download_url: str | None
    file_length: int
    game_versions: list[str]
    mod_loader: int | None

    @classmethod
    def from_api(cls, data: dict[str, Any]) -> CurseForgeFile:
        return cls(
            id=data.get("id", 0),
            display_name=data.get("displayName", ""),
            file_name=data.get("fileName", ""),
            download_url=data.get("downloadUrl"),
            file_length=data.get("fileLength", 0),
            game_versions=data.get("gameVersions", []),
            mod_loader=data.get("modLoader"),
        )


@dataclass
class CurseForgeMod:
    """A CurseForge mod."""

    id: int
    slug: str
    name: str
    summary: str
    download_count: int
    categories: list[str]

    @classmethod
    def from_api(cls, data: dict[str, Any]) -> CurseForgeMod:
        cats = [c.get("name", "") for c in data.get("categories", [])]
        return cls(
            id=data.get("id", 0),
            slug=data.get("slug", ""),
            name=data.get("name", ""),
            summary=data.get("summary", ""),
            download_count=data.get("downloadCount", 0),
            categories=cats,
        )


def _get(
    endpoint: str,
    api_key: str,
    params: dict | None = None,
    timeout: float = 15.0,
) -> Any:
    """Make a GET request to the CurseForge API."""
    url = f"{API_BASE}{endpoint}"
    headers = {"x-api-key": api_key, "Accept": "application/json"}
    with httpx.Client(timeout=timeout) as client:
        resp = client.get(url, params=params, headers=headers)
    if resp.status_code >= 400:
        raise CurseForgeError(endpoint, resp.status_code, resp.text)
    return resp.json()


def search(
    query: str,
    api_key: str,
    *,
    mc_version: str = "",
    loader: str = "",
    limit: int = 10,
) -> list[CurseForgeMod]:
    """Search for mods on CurseForge."""
    params: dict[str, str | int] = {
        "gameId": MINECRAFT_GAME_ID,
        "searchFilter": query,
        "pageSize": limit,
        "classId": 6,  # Mods class
        "sortField": 2,  # Popularity
        "sortOrder": "desc",
    }
    if mc_version:
        params["gameVersion"] = mc_version
    if loader and loader in LOADER_TYPES:
        params["modLoaderType"] = LOADER_TYPES[loader]

    data = _get("/mods/search", api_key, params=params)
    return [CurseForgeMod.from_api(m) for m in data.get("data", [])]


def get_mod(mod_id: int, api_key: str) -> CurseForgeMod:
    """Get a mod by its numeric ID."""
    data = _get(f"/mods/{mod_id}", api_key)
    return CurseForgeMod.from_api(data.get("data", {}))


def get_mod_by_slug(slug: str, api_key: str) -> CurseForgeMod | None:
    """Get a mod by searching for its slug."""
    results = search(slug, api_key, limit=5)
    for mod in results:
        if mod.slug == slug:
            return mod
    return results[0] if results else None


def get_files(
    mod_id: int,
    api_key: str,
    *,
    mc_version: str = "",
    loader: str = "",
) -> list[CurseForgeFile]:
    """Get files for a mod, optionally filtered."""
    params: dict[str, str | int] = {}
    if mc_version:
        params["gameVersion"] = mc_version
    if loader and loader in LOADER_TYPES:
        params["modLoaderType"] = LOADER_TYPES[loader]

    data = _get(f"/mods/{mod_id}/files", api_key, params=params)
    return [CurseForgeFile.from_api(f) for f in data.get("data", [])]


def get_latest_file(
    mod_id: int,
    api_key: str,
    *,
    mc_version: str = "",
    loader: str = "",
) -> CurseForgeFile | None:
    """Get the latest compatible file for a mod."""
    files = get_files(mod_id, api_key, mc_version=mc_version, loader=loader)
    return files[0] if files else None


def build_download_url(mod_id: int, file_id: int) -> str:
    """Build a direct download URL for a CurseForge file.

    Some files don't have downloadUrl in the API response due to author
    settings. This constructs the edge CDN URL directly.
    """
    id_part1 = str(file_id)[:4]
    id_part2 = str(file_id)[4:]
    return f"https://edge.forgecdn.net/files/{id_part1}/{id_part2}"
