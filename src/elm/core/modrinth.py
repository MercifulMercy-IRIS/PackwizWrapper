"""Modrinth API v2 client.

Handles searching for mods, fetching project info, and resolving download URLs.
API docs: https://docs.modrinth.com/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

API_BASE = "https://api.modrinth.com/v2"
USER_AGENT = "EnviousLabs/elm (https://github.com/EnviousLabs/elm)"


class ModrinthError(Exception):
    """Raised when a Modrinth API call fails."""

    def __init__(self, endpoint: str, status: int, body: str = ""):
        self.endpoint = endpoint
        self.status = status
        self.body = body
        super().__init__(f"Modrinth {endpoint} → HTTP {status}")


@dataclass
class ModrinthVersion:
    """A single version/file of a Modrinth project."""

    id: str
    version_number: str
    name: str
    filename: str
    url: str
    sha512: str
    sha1: str
    size: int
    game_versions: list[str]
    loaders: list[str]

    @classmethod
    def from_api(cls, data: dict[str, Any]) -> ModrinthVersion:
        """Build from a Modrinth API version response."""
        primary = data.get("files", [{}])[0] if data.get("files") else {}
        hashes = primary.get("hashes", {})
        return cls(
            id=data.get("id", ""),
            version_number=data.get("version_number", ""),
            name=data.get("name", ""),
            filename=primary.get("filename", ""),
            url=primary.get("url", ""),
            sha512=hashes.get("sha512", ""),
            sha1=hashes.get("sha1", ""),
            size=primary.get("size", 0),
            game_versions=data.get("game_versions", []),
            loaders=data.get("loaders", []),
        )


@dataclass
class ModrinthProject:
    """A Modrinth project (mod/modpack/etc)."""

    id: str
    slug: str
    title: str
    description: str
    project_type: str
    downloads: int
    icon_url: str
    categories: list[str]

    @classmethod
    def from_api(cls, data: dict[str, Any]) -> ModrinthProject:
        return cls(
            id=data.get("id", ""),
            slug=data.get("slug", ""),
            title=data.get("title", ""),
            description=data.get("description", ""),
            project_type=data.get("project_type", "mod"),
            downloads=data.get("downloads", 0),
            icon_url=data.get("icon_url", ""),
            categories=data.get("categories", []),
        )


def _get(endpoint: str, params: dict | None = None, timeout: float = 15.0) -> Any:
    """Make a GET request to the Modrinth API."""
    url = f"{API_BASE}{endpoint}"
    with httpx.Client(timeout=timeout) as client:
        resp = client.get(url, params=params, headers={"User-Agent": USER_AGENT})
    if resp.status_code >= 400:
        raise ModrinthError(endpoint, resp.status_code, resp.text)
    return resp.json()


def search(
    query: str,
    *,
    project_type: str = "mod",
    limit: int = 10,
) -> list[ModrinthProject]:
    """Search for projects on Modrinth."""
    import json as jsonlib

    facets = [[f"project_type:{project_type}"]]
    data = _get(
        "/search",
        params={
            "query": query,
            "limit": str(limit),
            "facets": jsonlib.dumps(facets),
        },
    )
    return [ModrinthProject.from_api(hit) for hit in data.get("hits", [])]


def get_project(slug_or_id: str) -> ModrinthProject:
    """Get a project by slug or ID."""
    data = _get(f"/project/{slug_or_id}")
    return ModrinthProject.from_api(data)


def get_versions(
    slug_or_id: str,
    *,
    game_versions: list[str] | None = None,
    loaders: list[str] | None = None,
) -> list[ModrinthVersion]:
    """Get versions of a project, optionally filtered."""
    import json as jsonlib

    params: dict[str, str] = {}
    if game_versions:
        params["game_versions"] = jsonlib.dumps(game_versions)
    if loaders:
        params["loaders"] = jsonlib.dumps(loaders)

    data = _get(f"/project/{slug_or_id}/version", params=params)
    return [ModrinthVersion.from_api(v) for v in data]


def get_latest_version(
    slug_or_id: str,
    *,
    mc_version: str = "",
    loader: str = "",
) -> ModrinthVersion | None:
    """Get the latest compatible version of a project."""
    game_versions = [mc_version] if mc_version else None
    loaders = [loader] if loader else None
    versions = get_versions(slug_or_id, game_versions=game_versions, loaders=loaders)
    return versions[0] if versions else None
