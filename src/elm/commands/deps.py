"""Dependency check and install commands."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import typer
from rich.table import Table

from elm.config import load_config
from elm.ui import console, _fail, _ok, _warn, _info, _hint, _header

deps_app = typer.Typer(help="Manage ELM dependencies.")


def _dep_status() -> list[tuple[str, str, bool, str]]:
    """Return (label, binary, found, hint) for every dependency."""
    deps: list[tuple[str, str, bool, str]] = []

    found = shutil.which("go") is not None or Path("/usr/local/go/bin/go").is_file()
    deps.append(("Go", "go", found, "Required to build packwiz"))

    found = shutil.which("packwiz") is not None
    deps.append(("packwiz", "packwiz", found, "Packwiz CLI (optional with ELM 3.0)"))

    found = shutil.which("curl") is not None
    deps.append(("curl", "curl", found, "HTTP downloads"))

    found = shutil.which("git") is not None
    deps.append(("Git", "git", found, "Version control"))

    found = shutil.which("docker") is not None
    deps.append(("Docker", "docker", found, "Container runtime for servers"))

    # Pelican Panel — check via configured URL + connection test
    cfg = load_config()
    pel_ok = False
    if cfg.pelican_url and cfg.pelican_api_key:
        try:
            from elm.core.pelican import PelicanClient
            client = PelicanClient(url=cfg.pelican_url.rstrip("/"), api_key=cfg.pelican_api_key)
            pel_ok = client.test_connection()
        except Exception:
            pass
    deps.append(("Pelican Panel", "pelican", pel_ok, "Game server management panel"))

    return deps


@deps_app.command(name="check")
def deps_check() -> None:
    """Check status of all dependencies."""
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
        status_str = "[green bold]found[/green bold]" if found else "[red bold]missing[/red bold]"
        table.add_row(label, status_str, hint)

    console.print(table)

    missing = [label for label, _, found, _ in statuses if not found]
    console.print()
    if not missing:
        _ok("All dependencies satisfied")
    else:
        _warn(f"{len(missing)} missing: {', '.join(missing)}")
        _hint("Install with: elm deps install <name>")


@deps_app.command(name="ls")
def deps_ls() -> None:
    """List dependencies and their status."""
    deps_check()


@deps_app.command()
def install(
    name: str = typer.Argument(..., help="Dependency name (go, packwiz, curl, git, docker)"),
) -> None:
    """Install a dependency by name."""
    name_lower = name.lower()

    known = {
        "go": ("go", "Go"),
        "packwiz": ("packwiz", "packwiz"),
        "curl": ("curl", "curl"),
        "git": ("git", "Git"),
        "docker": ("docker", "Docker"),
    }

    if name_lower not in known:
        _fail(f"Unknown dependency: {name}")
        _hint(f"Available: {', '.join(known.keys())}")
        return

    binary, label = known[name_lower]

    if name_lower == "go":
        if shutil.which("go") or Path("/usr/local/go/bin/go").is_file():
            _ok("Go is already installed")
            return
        import platform
        arch = platform.machine()
        go_arch = {"x86_64": "amd64", "aarch64": "arm64", "AMD64": "amd64"}.get(arch)
        if not go_arch:
            _fail(f"Unsupported architecture: {arch}")
            return
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
            return
        with console.status("  Installing to /usr/local/go..."):
            subprocess.run(["sudo", "rm", "-rf", "/usr/local/go"], check=True)
            subprocess.run(
                ["sudo", "tar", "-C", "/usr/local", "-xzf", f"/tmp/{tarball}"],
                check=True,
            )
            Path(f"/tmp/{tarball}").unlink(missing_ok=True)
        _ok(f"Go {go_version} installed to /usr/local/go")
        _hint("Add to PATH: export PATH=\"/usr/local/go/bin:$HOME/go/bin:$PATH\"")

    elif name_lower == "packwiz":
        if shutil.which("packwiz"):
            _ok(f"packwiz is already installed: {shutil.which('packwiz')}")
            return
        import os
        go_bin = shutil.which("go") or "/usr/local/go/bin/go"
        if not Path(go_bin).is_file():
            _fail("Go is not installed — run: elm deps install go")
            return
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
            local_bin = Path.home() / ".local" / "bin"
            local_bin.mkdir(parents=True, exist_ok=True)
            dest = local_bin / "packwiz"
            dest.unlink(missing_ok=True)
            dest.symlink_to(pw_path)
            _ok(f"packwiz installed → {dest}")
        else:
            _ok("packwiz built (check $GOPATH/bin)")

    elif name_lower == "docker":
        if shutil.which("docker"):
            _ok("Docker is already installed")
            return
        _info("Installing Docker via official script...")
        subprocess.run(
            ["bash", "-c", "curl -fsSL https://get.docker.com | sudo sh"],
            check=True,
        )
        _ok("Docker installed")
        _hint("Add yourself to the docker group: sudo usermod -aG docker $USER")

    else:
        # curl, git — use system package manager
        if shutil.which(binary):
            _ok(f"{label} is already installed")
            return
        pkg = binary
        apt = shutil.which("apt-get")
        dnf = shutil.which("dnf")
        pacman = shutil.which("pacman")
        if apt:
            mgr = ["sudo", "apt-get", "install", "-y", pkg]
        elif dnf:
            mgr = ["sudo", "dnf", "install", "-y", pkg]
        elif pacman:
            mgr = ["sudo", "pacman", "-S", "--noconfirm", pkg]
        else:
            _fail("No supported package manager found (apt, dnf, pacman)")
            _hint(f"Install manually: sudo <pkg-manager> install {pkg}")
            return
        with console.status(f"  Installing {label}..."):
            subprocess.run(mgr, check=True)
        _ok(f"{label} installed")
