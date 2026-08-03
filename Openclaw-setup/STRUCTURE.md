# openclaw-setup Folder Structure

## Overview

The `openclaw-setup/` folder is **self-contained** — it includes everything needed to deploy DecoAI to a new PC with OpenClaw.

## Folder Layout

```
openclaw-setup/
├── setup.ps1                    # One-time setup script
├── start.ps1                    # Gateway launcher
├── README.md                    # Full documentation
├── QUICKSTART.txt               # One-page quick-start
├── STRUCTURE.md                 # This file
├── .env.example                 # Environment variable template
│
├── skills/                      # All DecoAI skills (self-contained)
│   ├── database/                # Shared SQLite DB layer
│   │   ├── db.py                # DB connection & initialization
│   │   ├── models.py            # Pydantic data models
│   │   ├── schema.sql           # SQLite schema
│   │   └── decoai.sqlite        # (created on first run)
│   │
│   ├── inventory-management/    # Inventory CRUD + invoice/photo intake
│   │   ├── app/                 # FastAPI service
│   │   │   ├── main.py
│   │   │   ├── extractor.py     # Invoice extraction
│   │   │   ├── vision.py        # Photo analysis
│   │   │   └── refresh.py       # Shelf refresh
│   │   ├── cli/                 # Standalone CLIs (no server needed)
│   │   │   ├── invoice_cli.py   # decoai-invoice
│   │   │   ├── image_cli.py     # decoai-image
│   │   │   └── refresh_cli.py   # decoai-refresh
│   │   ├── SKILL.md             # Skill documentation
│   │   └── requirements.txt
│   │
│   ├── cost-estimation/         # Itemized cost estimates
│   │   ├── app/                 # FastAPI service
│   │   │   ├── main.py
│   │   │   ├── estimator.py     # Core estimation logic
│   │   │   └── price_lookup.py  # (unused; kept for reference)
│   │   ├── cli/                 # Standalone CLI
│   │   │   └── estimate_cli.py  # decoai-estimate
│   │   ├── SKILL.md             # Skill documentation
│   │   └── requirements.txt
│   │
│   ├── amazon-url-builder/      # Missing items → Amazon links
│   │   ├── src/
│   │   │   ├── builder.js       # Core logic
│   │   │   └── server.js        # HTTP service
│   │   ├── package.json
│   │   └── README.md
│   │
│   └── sd3-image-generation/    # Stable Diffusion 3 (local NPU)
│       ├── SD3_Tool.py          # CLI tool
│       ├── session_server.py    # Session server
│       ├── Model_Bins/          # ONNX model files
│       ├── qnn_ctx_json/        # QNN context configs
│       ├── SKILL.md             # Skill documentation
│       ├── requirements.txt
│       └── README.md
│
└── System/                      # OpenClaw system files (optional)
    ├── openclaw.json            # OpenClaw config template
    ├── AGENTS.md                # Agent documentation
    ├── BOOTSTRAP.md
    ├── HEARTBEAT.md
    ├── IDENTITY.md
    ├── SOUL.md
    ├── TOOLS.md
    └── USER.md
```

## How to Use

### On a new PC:

1. **Copy just the `openclaw-setup/` folder** (it's self-contained)
   ```powershell
   # Copy from USB, network share, or clone the repo and copy the folder
   Copy-Item -Path "openclaw-setup" -Destination "C:\mounika\DecoAI\openclaw-setup" -Recurse
   ```

2. **Run setup** (one-time)
   ```powershell
   cd C:\mounika\DecoAI\openclaw-setup
   .\setup.ps1
   ```
   This copies all skills from `skills/` into `~/.openclaw/workspace/Skills/`

3. **Start the gateway**
   ```powershell
   .\start.ps1
   ```

### Sharing across PCs:

- Edit `~/.openclaw/workspace/Skills/.env` and set `DECOAI_DB_PATH` to a network path:
  ```
  DECOAI_DB_PATH=\server\share\decoai.sqlite
  ```
- All PCs will read/write the same shared database

## What Each Script Does

### `setup.ps1`
- Verifies OpenClaw is installed globally
- Copies all skills from `skills/` into `~/.openclaw/workspace/Skills/`
- Creates a shared `.env` file with default configuration
- Safe to run multiple times

### `start.ps1`
- Loads `.env` into the process environment
- Starts the OpenClaw gateway (npm-global `openclaw`)
- Tails the log to the console
- Press Ctrl+C to stop

## Skills Included

| Skill | Purpose | CLI |
|-------|---------|-----|
| **database** | Shared SQLite DB layer | (no CLI) |
| **inventory-management** | Invoice upload, photo analysis, shelf refresh | `decoai-invoice`, `decoai-image`, `decoai-refresh` |
| **cost-estimation** | Itemized cost estimates | `decoai-estimate` |
| **amazon-url-builder** | Missing items → Amazon links | HTTP service on port 8004 |
| **sd3-image-generation** | Stable Diffusion 3 image generation (local NPU) | `SD3_Tool.py`, `session_server.py` |

## Environment Variables

All skills read from `~/.openclaw/workspace/Skills/.env`:

- `DECOAI_DB_PATH` — path to the shared SQLite database
- `INVOICE_READ_MODEL_URL` — invoice extraction model backend (optional)
- `IMAGE_READ_MODEL_URL` — photo analysis model backend (optional)
- `ARDUINO_URL` — Arduino vision service (optional)
- `AMAZON_AFFILIATE_TAG` — Amazon affiliate tag (optional)

See `.env.example` for all available options.

## Troubleshooting

**"openclaw not found"**
→ `npm install -g openclaw`

**"Skills not showing up"**
→ Restart the gateway with `.\start.ps1` (OpenClaw reads skills on startup)

**"Database file not found"**
→ Check `DECOAI_DB_PATH` in `~/.openclaw/workspace/Skills/.env`
→ If the file doesn't exist, skills will create it on first run

**"Model backend not responding"**
→ Leave `INVOICE_READ_MODEL_URL` and `IMAGE_READ_MODEL_URL` blank to use mock data
→ Mock data is deterministic and works fully offline for testing
