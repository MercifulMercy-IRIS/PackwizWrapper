"""Pelican Panel API client.

Handles all communication with the Pelican Panel REST API for game server
management.  Application API for admin ops, Client API for power/console.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

from elm.config import Config, target_get, target_set


class PelicanError(Exception):
    """Raised when a Pelican API call fails."""

    def __init__(self, method: str, endpoint: str, status: int, body: str = ""):
        self.method = method
        self.endpoint = endpoint
        self.status = status
        self.body = body
        super().__init__(f"Pelican {method} {endpoint} → HTTP {status}")


@dataclass
class PelicanClient:
    """REST client for Pelican Panel."""

    url: str
    api_key: str
    timeout: float = 30.0

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    # ── Low-level API ─────────────────────────────────────────────────

    def _request(
        self, method: str, path: str, json_data: dict | None = None
    ) -> dict[str, Any]:
        """Make an authenticated API request."""
        url = f"{self.url}{path}"
        with httpx.Client(timeout=self.timeout) as client:
            resp = client.request(
                method, url, headers=self._headers(), json=json_data
            )
        if resp.status_code >= 400:
            raise PelicanError(method, path, resp.status_code, resp.text)
        if resp.status_code == 204 or not resp.content:
            return {}
        return resp.json()

    def app_api(
        self, method: str, endpoint: str, data: dict | None = None
    ) -> dict[str, Any]:
        """Application API — admin operations."""
        return self._request(method, f"/api/application{endpoint}", data)

    def client_api(
        self, method: str, endpoint: str, data: dict | None = None
    ) -> dict[str, Any]:
        """Client API — user/server-scoped operations."""
        return self._request(method, f"/api/client{endpoint}", data)

    # ── Connection test ───────────────────────────────────────────────

    def test_connection(self) -> bool:
        """Test if we can reach the panel."""
        try:
            self.app_api("GET", "/servers")
            return True
        except (PelicanError, httpx.HTTPError):
            return False

    # ── Server CRUD ───────────────────────────────────────────────────

    def list_servers(self) -> list[dict]:
        """List all servers."""
        result = self.app_api("GET", "/servers")
        return result.get("data", [])

    def create_server(
        self,
        name: str,
        *,
        user_id: int,
        egg_id: int,
        allocation_id: int,
        ram: int = 8192,
        disk: int = 25600,
        cpu: int = 400,
        mc_version: str = "1.20.1",
        loader: str = "FORGE",
        packwiz_url: str = "",
        description: str = "",
    ) -> dict[str, Any]:
        """Create a new server on Pelican."""
        payload = {
            "name": f"elm-{name}",
            "description": description or f"ELM server: {name}",
            "user": user_id,
            "egg": egg_id,
            "docker_image": "ghcr.io/pelican-eggs/yolks:java_21",
            "startup": "java -Xms128M -Xmx{{SERVER_MEMORY}}M -jar server.jar",
            "environment": {
                "MC_VERSION": mc_version,
                "SERVER_JARFILE": "server.jar",
                "BUILD_TYPE": loader.upper(),
                "PACKWIZ_URL": packwiz_url,
                "MOTD": f"{name} — ELM",
            },
            "limits": {
                "memory": ram,
                "swap": 0,
                "disk": disk,
                "io": 500,
                "cpu": cpu,
            },
            "feature_limits": {
                "databases": 0,
                "allocations": 1,
                "backups": 3,
            },
            "allocation": {"default": allocation_id},
            "start_on_completion": False,
        }
        return self.app_api("POST", "/servers", payload)

    def delete_server(self, server_id: int) -> None:
        """Delete a server."""
        self.app_api("DELETE", f"/servers/{server_id}")

    def get_server(self, server_id: int) -> dict[str, Any]:
        """Get server details."""
        return self.app_api("GET", f"/servers/{server_id}")

    # ── Power control ─────────────────────────────────────────────────

    def power(self, uuid: str, signal: str) -> None:
        """Send power signal: start, stop, restart, kill."""
        self.client_api("POST", f"/servers/{uuid}/power", {"signal": signal})

    def send_command(self, uuid: str, command: str) -> None:
        """Send a console command."""
        self.client_api("POST", f"/servers/{uuid}/command", {"command": command})

    # ── Resources / status ────────────────────────────────────────────

    def resources(self, uuid: str) -> dict[str, Any]:
        """Get server resource usage (CPU, RAM, state)."""
        return self.client_api("GET", f"/servers/{uuid}/resources")

    # ── Backups ───────────────────────────────────────────────────────

    def create_backup(self, uuid: str) -> dict[str, Any]:
        """Create a server backup."""
        return self.client_api("POST", f"/servers/{uuid}/backups", {})

    # ── Nodes & allocations ───────────────────────────────────────────

    def list_nodes(self) -> list[dict]:
        """List all nodes."""
        result = self.app_api("GET", "/nodes")
        return result.get("data", [])

    def list_allocations(self, node_id: int) -> list[dict]:
        """List allocations for a node."""
        result = self.app_api("GET", f"/nodes/{node_id}/allocations")
        return result.get("data", [])

    def find_allocation(self, node_id: int, port: int) -> int | None:
        """Find an unassigned allocation for a specific port."""
        allocs = self.list_allocations(node_id)
        for alloc in allocs:
            attrs = alloc.get("attributes", {})
            if attrs.get("port") == port and not attrs.get("assigned"):
                return attrs["id"]
        return None

    # ── Nests & eggs ──────────────────────────────────────────────────

    def list_nests(self) -> list[dict]:
        """List all nests."""
        result = self.app_api("GET", "/nests")
        return result.get("data", [])

    def list_eggs(self, nest_id: int) -> list[dict]:
        """List eggs in a nest."""
        result = self.app_api("GET", f"/nests/{nest_id}/eggs")
        return result.get("data", [])

    # ── Users ─────────────────────────────────────────────────────────

    def list_users(self) -> list[dict]:
        """List all users."""
        result = self.app_api("GET", "/users")
        return result.get("data", [])


# ── Helper: build client from config ──────────────────────────────────────

def get_client(cfg: Config) -> PelicanClient:
    """Create a PelicanClient from the loaded config."""
    url = cfg.pelican_url
    key = cfg.pelican_api_key
    if not url:
        raise PelicanError("GET", "/", 0, "PELICAN_URL not configured. Run: elm deploy setup")
    if not key:
        raise PelicanError("GET", "/", 0, "Pelican API key not set. Run: elm key pelican <token>")
    return PelicanClient(url=url.rstrip("/"), api_key=key)


# ── High-level target operations ──────────────────────────────────────────

def create_target_server(cfg: Config, target_name: str) -> dict:
    """Create a Pelican server for an ELM target."""
    client = get_client(cfg)

    # Check not already created
    existing = target_get(target_name, "pelican_server_id")
    if existing:
        raise PelicanError("POST", "/servers", 409, f"Already exists: ID {existing}")

    port = target_get(target_name, "port")
    domain = target_get(target_name, "domain") or target_name
    ram = int(target_get(target_name, "ram") or cfg.server_ram)

    node_id = int(cfg.pelican_node_id)
    egg_id = int(cfg.pelican_egg_id)
    user_id = int(cfg.pelican_user_id)

    # Find allocation
    alloc_id = client.find_allocation(node_id, int(port))
    if alloc_id is None:
        raise PelicanError(
            "GET", f"/nodes/{node_id}/allocations", 404,
            f"No available allocation for port {port}. Create one in Pelican Panel."
        )

    result = client.create_server(
        target_name,
        user_id=user_id,
        egg_id=egg_id,
        allocation_id=alloc_id,
        ram=ram,
        disk=cfg.server_disk,
        cpu=cfg.server_cpu,
        mc_version=cfg.mc_version,
        loader=cfg.loader,
        description=f"ELM: {domain}",
    )

    attrs = result.get("attributes", {})
    server_id = attrs.get("id")
    server_uuid = attrs.get("uuid")

    target_set(
        target_name,
        pelican_server_id=server_id,
        pelican_server_uuid=server_uuid,
        pelican_allocation_id=alloc_id,
    )

    return attrs


def power_target(cfg: Config, target_name: str, signal: str) -> None:
    """Send a power signal to a target's Pelican server."""
    client = get_client(cfg)
    uuid = target_get(target_name, "pelican_server_uuid")
    if not uuid:
        raise PelicanError(
            "POST", "/power", 404,
            f"No Pelican server for '{target_name}'. Run: elm deploy create --target {target_name}"
        )
    client.power(uuid, signal)


def command_target(cfg: Config, target_name: str, command: str) -> None:
    """Send a console command to a target's server."""
    client = get_client(cfg)
    uuid = target_get(target_name, "pelican_server_uuid")
    if not uuid:
        raise PelicanError("POST", "/command", 404, f"No Pelican server for '{target_name}'")
    client.send_command(uuid, command)


def status_target(cfg: Config, target_name: str) -> dict:
    """Get resource usage for a target's server."""
    client = get_client(cfg)
    uuid = target_get(target_name, "pelican_server_uuid")
    if not uuid:
        raise PelicanError("GET", "/resources", 404, f"No Pelican server for '{target_name}'")
    return client.resources(uuid)


def backup_target(cfg: Config, target_name: str) -> dict:
    """Create a backup for a target's server."""
    client = get_client(cfg)
    uuid = target_get(target_name, "pelican_server_uuid")
    if not uuid:
        raise PelicanError("POST", "/backups", 404, f"No Pelican server for '{target_name}'")
    return client.create_backup(uuid)


def delete_target_server(cfg: Config, target_name: str) -> None:
    """Delete a target's Pelican server."""
    client = get_client(cfg)
    server_id = target_get(target_name, "pelican_server_id")
    if not server_id:
        raise PelicanError("DELETE", "/servers", 404, f"No Pelican server for '{target_name}'")
    client.delete_server(int(server_id))
    target_set(
        target_name,
        pelican_server_id="",
        pelican_server_uuid="",
        pelican_allocation_id="",
    )
