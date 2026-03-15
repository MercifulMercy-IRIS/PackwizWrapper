# Prism Launcher — Packwiz Auto-Update Setup

This configures Prism Launcher to automatically pull the latest modpack via packwiz-installer before every launch.

## Prerequisites

- Java installed and on PATH
- Prism Launcher installed
- Pack hosted via `elm cdn` (or any HTTP server serving `pack.toml`)

## Setup

### 1. Get your pack URL

Run `elm config get PACK_HOST_URL` to find your hosted pack URL. It should look like:
- `https://pack.enviouslabs.com` (with CDN domain)
- `http://localhost:8080` (local dev)

### 2. Edit the helper script

Copy the appropriate script into your Prism instance's `.minecraft` directory:

- **Linux/macOS:** `prism-update.sh`
- **Windows:** `prism-update.bat`

Open the script and replace `__PACK_URL__` with your actual pack URL:

```bash
PACK_URL="https://pack.enviouslabs.com"
```

### 3. Configure Prism Launcher

1. Open Prism Launcher
2. Right-click your instance → **Edit**
3. Go to **Settings** → **Custom Commands**
4. Check **Enable Custom Commands**
5. In **Pre-launch command**, enter:

**Linux/macOS:**
```
bash $INST_DIR/prism-update.sh
```

**Windows:**
```
cmd /c "%INST_DIR%\prism-update.bat"
```

### 4. Test it

Launch the instance. You should see `[ELM] Updating modpack from ...` in the log before Minecraft starts. On first run, it downloads the bootstrap jar and syncs all mods.

## How it works

1. Prism runs the pre-launch script before starting Minecraft
2. The script downloads `packwiz-installer-bootstrap.jar` if not present
3. The bootstrap jar fetches `pack.toml` from your CDN
4. packwiz-installer compares the remote index against local files
5. New/updated mods are downloaded, removed mods are deleted
6. Minecraft launches with the correct modpack

## Alternative: environment variable

Instead of editing the script, you can set `PACK_URL` as an environment variable in Prism:

1. Instance → **Edit** → **Settings** → **Custom Commands**
2. In **Pre-launch command**:
   ```
   PACK_URL="https://pack.enviouslabs.com" bash $INST_DIR/prism-update.sh
   ```
