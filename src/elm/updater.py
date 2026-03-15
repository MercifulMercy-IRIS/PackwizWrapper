"""Self-update logic for ELM.

Handles three update paths:
1. **Python package** — `pip install --upgrade` from the git repo (updates CLI,
   menu, all Python modules).  Works whether ELM was installed normally or in
   editable mode.
2. **Shell scripts & config** — individual file sync from GitHub raw content,
   auto-discovered via the GitHub API so new files are never missed.
3. **Version check** — compares the remote ``__version__`` against the local
   one *before* doing any work, so we can skip when already current.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from elm.config import Config
from elm.ui import console, _fail, _ok, _warn, _info, _hint


# ── Helpers ──────────────────────────────────────────────────────────────


def _curl_text(url: str, timeout: int = 15) -> str | None:
    """Fetch *url* via curl.  Returns body text or None on failure."""
    r = subprocess.run(
        ["curl", "-fsSL", "--connect-timeout", str(timeout), url],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    return r.stdout


def _github_raw_url(repo: str, branch: str, path: str) -> str:
    """Build a raw.githubusercontent.com URL."""
    path = path.strip("/")
    base = f"https://raw.githubusercontent.com/{repo}/{branch}"
    return f"{base}/{path}" if path else base


def _github_api_url(repo: str, branch: str, path: str) -> str:
    """Build a GitHub API contents URL."""
    path = path.strip("/")
    base = f"https://api.github.com/repos/{repo}/contents"
    url = f"{base}/{path}" if path else base
    return f"{url}?ref={branch}"


# ── Version checking ────────────────────────────────────────────────────


def fetch_remote_version(repo: str, branch: str, gh_path: str) -> str | None:
    """Fetch the remote ``__version__`` from ``src/elm/__init__.py``."""
    # Try the Python package location first
    for init_path in [
        f"{gh_path}/src/elm/__init__.py" if gh_path else "src/elm/__init__.py",
        "src/elm/__init__.py",
    ]:
        url = _github_raw_url(repo, branch, init_path)
        body = _curl_text(url, timeout=10)
        if body:
            import re
            m = re.search(r'__version__\s*=\s*["\']([^"\']+)["\']', body)
            if m:
                return m.group(1)
    return None


def check_for_update(cfg: Config) -> tuple[str, str] | None:
    """Return ``(local, remote)`` versions if an update is available, else None."""
    from elm import __version__ as local_version

    repo = cfg.get("ELM_GITHUB_REPO")
    if not repo:
        return None

    branch = cfg.get("ELM_GITHUB_BRANCH") or "main"
    gh_path = cfg.get("ELM_GITHUB_PATH") or ""

    remote = fetch_remote_version(repo, branch, gh_path)
    if not remote:
        return None

    if remote != local_version:
        return (local_version, remote)
    return None


# ── File discovery via GitHub API ────────────────────────────────────────


def discover_repo_files(
    repo: str, branch: str, gh_path: str
) -> list[dict[str, str]] | None:
    """List files in the repo path via the GitHub API.

    Returns a list of dicts with ``name``, ``download_url``, ``type`` keys,
    or None on failure.
    """
    url = _github_api_url(repo, branch, gh_path)
    body = _curl_text(url, timeout=15)
    if not body:
        return None
    try:
        entries = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(entries, list):
        return None
    return [
        {
            "name": e["name"],
            "download_url": e.get("download_url", ""),
            "type": e.get("type", "file"),
        }
        for e in entries
        if isinstance(e, dict) and "name" in e
    ]


# ── Update results ──────────────────────────────────────────────────────


@dataclass
class UpdateResult:
    """Collects outcomes from an update run."""

    updated_files: list[str] = field(default_factory=list)
    skipped_files: list[str] = field(default_factory=list)
    failed_files: list[str] = field(default_factory=list)
    pip_updated: bool = False
    pip_error: str = ""
    old_version: str = ""
    new_version: str = ""

    @property
    def any_updates(self) -> bool:
        return bool(self.updated_files) or self.pip_updated


# ── Core update logic ───────────────────────────────────────────────────


def _update_pip_package(repo: str, branch: str) -> tuple[bool, str]:
    """Reinstall the ELM Python package from the git repo.

    Returns (success, error_message).
    """
    import sys

    git_url = f"git+https://github.com/{repo}.git@{branch}"

    r = subprocess.run(
        [
            sys.executable, "-m", "pip", "install",
            "--upgrade", "--quiet", "--quiet",
            git_url,
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        err = r.stderr.strip().splitlines()
        return False, err[-1] if err else "pip install failed"
    return True, ""


def _sync_shell_files(
    cfg: Config,
    repo: str,
    branch: str,
    gh_path: str,
    result: UpdateResult,
) -> None:
    """Sync shell scripts, config templates, and data files from GitHub.

    Auto-discovers files via the API when possible; falls back to the
    hardcoded ``ELM_UPDATE_FILES`` list.
    """
    # Discover files from the API
    remote_files = discover_repo_files(repo, branch, gh_path)

    if remote_files:
        # Filter to updatable file types (skip dirs, .git, Python source)
        file_names = [
            f["name"]
            for f in remote_files
            if f["type"] == "file"
            and not f["name"].startswith(".")
            and f["name"] not in ("pyproject.toml", "README.md", "LICENSE")
        ]
    else:
        # Fallback to configured list
        file_names = (
            cfg.get("ELM_UPDATE_FILES") or "elm.sh install.sh elm.conf mods.txt"
        ).split()

    base_url = _github_raw_url(repo, branch, gh_path)

    for filename in file_names:
        url = f"{base_url}/{filename}"
        try:
            body = _curl_text(url, timeout=15)
            if body is None:
                result.failed_files.append(filename)
                continue

            dest = cfg.pack_dir / filename
            if dest.is_file() and dest.read_text() == body:
                result.skipped_files.append(filename)
                continue

            # Atomic write via temp file
            with tempfile.NamedTemporaryFile(
                mode="w", dir=dest.parent, prefix=f".{filename}.", delete=False
            ) as tmp:
                tmp.write(body)
                tmp_path = Path(tmp.name)

            if dest.is_file():
                shutil.copymode(dest, tmp_path)

            tmp_path.replace(dest)
            result.updated_files.append(filename)

        except Exception:
            result.failed_files.append(filename)


def run_full_update(cfg: Config) -> UpdateResult:
    """Execute the full update pipeline.

    1. Fetch remote version and compare with local.
    2. Update the Python package via pip (CLI, menu, all modules).
    3. Sync shell scripts and data files from GitHub.
    """
    from elm import __version__ as local_version

    result = UpdateResult(old_version=local_version)

    repo = cfg.get("ELM_GITHUB_REPO")
    if not repo:
        return result

    branch = cfg.get("ELM_GITHUB_BRANCH") or "main"
    gh_path = cfg.get("ELM_GITHUB_PATH") or ""

    # 1 — Version check
    remote_version = fetch_remote_version(repo, branch, gh_path)
    result.new_version = remote_version or local_version

    # 2 — Update Python package
    ok, err = _update_pip_package(repo, branch)
    result.pip_updated = ok
    result.pip_error = err

    # 3 — Sync shell files
    _sync_shell_files(cfg, repo, branch, gh_path, result)

    return result


def print_result(result: UpdateResult) -> None:
    """Pretty-print an UpdateResult to the console."""
    console.print()

    # Version info
    if result.new_version and result.new_version != result.old_version:
        _ok(f"Version: {result.old_version} → [bold]{result.new_version}[/bold]")
    elif result.new_version:
        _info(f"Version: {result.old_version} (unchanged)")

    # pip status
    if result.pip_updated:
        _ok("Python package updated (CLI, menu, all modules)")
    elif result.pip_error:
        _warn(f"Python package update failed: {result.pip_error}")
        _hint("Try manually: pip install --upgrade git+https://github.com/<repo>")

    # File sync
    if result.updated_files:
        _ok(
            f"{len(result.updated_files)} file{'s' if len(result.updated_files) != 1 else ''}"
            f" updated: {', '.join(result.updated_files)}"
        )
    if result.skipped_files:
        _info(
            f"{len(result.skipped_files)} already up to date"
        )
    if result.failed_files:
        _warn(
            f"{len(result.failed_files)} failed: {', '.join(result.failed_files)}"
        )

    # Summary
    console.print()
    if result.any_updates:
        _ok("Update complete")
        if result.pip_updated:
            _hint("Restart your shell to pick up CLI changes")
    elif not result.failed_files and not result.pip_error:
        _ok("Everything is already up to date")
