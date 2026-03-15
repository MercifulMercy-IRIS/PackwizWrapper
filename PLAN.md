# ELM 3.0 Full Rewrite Plan

## Architecture Overview

Rewrite ELM from scratch using Typer, direct Modrinth/CurseForge API calls, while maintaining packwiz-compatible pack format for client distribution.

**Key insight**: We use the Modrinth & CurseForge APIs to find mods and get download URLs, then generate packwiz-compatible TOML files ourselves. No packwiz binary needed, but the output format is fully packwiz-compatible so clients can use it.

## Tech Stack

| Component | Choice |
|---|---|
| CLI framework | **Typer** (type-hint based, built on Click) |
| HTTP client | **httpx** (async support, already proven) |
| Terminal UI | **Rich** (styling) + **simple-term-menu** (TUI) |
| Config format | Bash-style KEY="value" (backward compat) |
| Pack format | **packwiz TOML** (pack.toml + per-mod .toml) |
| Build system | **pyproject.toml** with hatchling |

## Module Structure

```
src/elm/
├── __init__.py          # Version
├── __main__.py          # Entry: python -m elm
├── app.py               # Typer app definition + commands
├── commands/
│   ├── __init__.py
│   ├── mod.py           # add, rm, update, search, sync, list
│   ├── pack.py          # init, refresh, export
│   ├── deploy.py        # Pelican server management
│   ├── target.py        # Target CRUD
│   ├── key.py           # API key management
│   ├── config_cmd.py    # Config show/set/get
│   └── deps.py          # Dependency check/install
├── core/
│   ├── __init__.py
│   ├── modrinth.py      # Modrinth API client
│   ├── curseforge.py    # CurseForge API client
│   ├── packwiz.py       # Packwiz TOML file generator (no binary)
│   ├── pelican.py       # Pelican Panel API client
│   └── resolver.py      # Mod resolution (search → download URL → TOML)
├── config.py            # Config loading & management
├── ui.py                # Rich console helpers
├── menu.py              # Interactive TUI menu
└── updater.py           # Self-update from GitHub
```

## Implementation Steps

### Phase 1: Foundation
1. New `pyproject.toml` with Typer dependency
2. `src/elm/__init__.py` — version
3. `src/elm/ui.py` — Rich console helpers
4. `src/elm/config.py` — Config system (reuse logic, clean up)
5. `src/elm/app.py` — Typer app with callback, version flag

### Phase 2: Core API Clients
6. `src/elm/core/modrinth.py` — Modrinth v2 API (search, get project, get versions, download URLs)
7. `src/elm/core/curseforge.py` — CurseForge API (search, get mod, get files)
8. `src/elm/core/packwiz.py` — Generate pack.toml + per-mod .toml files (pure Python, no binary)
9. `src/elm/core/resolver.py` — Unified mod resolution: slug → API lookup → download URL → packwiz TOML

### Phase 3: Mod Commands
10. `src/elm/commands/mod.py` — add, rm, update, search, sync, list
11. `src/elm/commands/pack.py` — init, refresh

### Phase 4: Server & Deploy
12. `src/elm/core/pelican.py` — Pelican Panel API (port from existing, clean up)
13. `src/elm/commands/deploy.py` — deploy create/start/stop/status/backup/remove
14. `src/elm/commands/target.py` — target add/ls/rm/show
15. `src/elm/commands/key.py` — key set/show/rm

### Phase 5: Config, Deps, Menu
16. `src/elm/commands/config_cmd.py` — config show/set/get
17. `src/elm/commands/deps.py` — dependency check/install
18. `src/elm/menu.py` — Interactive TUI
19. `src/elm/updater.py` — Self-update

### Phase 6: Polish
20. `src/elm/__main__.py` — python -m elm support
21. Wire all command groups into app.py
22. Test end-to-end
