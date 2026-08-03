# DecoAI OpenClaw Setup

A one-command setup to deploy all DecoAI skills (inventory-management, cost-estimation, amazon-url-builder, sd3-image-generation) into OpenClaw on a new PC, with automatic item detection via Geniex (Qwen2.5-VL model).

## Quick Start

```powershell
# 1. One-time setup
.\setup.ps1

# 2. Start all services (OpenClaw + Geniex)
.\start.ps1

# 3. Done! OpenClaw is running on port 18789
```

## What's in this folder

```
openclaw-setup/
  setup.ps1                 # One-time setup: copy skills to ~/.openclaw/workspace/Skills
  start.ps1                 # Start the OpenClaw gateway + Geniex server
  .env.example              # Template for environment variables
  QUICKSTART.txt            # One-page quick-start guide
  README.md                 # This file
  System/                   # OpenClaw system files
    AGENTS.md               # Agent instructions and workflows
    WORKFLOW-DECORATION-CONCEPT.md  # Decoration workflow documentation
  skills/                   # All DecoAI skills (self-contained)
    database/               # Shared SQLite DB layer
    inventory-management/   # Invoice upload, photo analysis, shelf refresh
    cost-estimation/        # Itemized cost estimates
    amazon-url-builder/     # Missing items → Amazon purchase links
    sd3-image-generation/   # Stable Diffusion 3 image generation (local NPU)
    workflow_orchestrator.py # Decoration workflow orchestrator
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenClaw Gateway (18789)                 │
│  - Manages agent conversations                              │
│  - Routes to skills                                         │
│  - Handles Telegram/chat integration                        │
└─────────────────────────────────────────────────────────────┘
         ↓                    ↓                    ↓
    ┌────────────┐    ┌──────────────┐    ┌──────────────┐
    │ Inventory  │    │ Cost         │    │ Amazon URL   │
    │ Management │    │ Estimation   │    │ Builder      │
    │ (CLI)      │    │ (CLI)        │    │ (HTTP 8004)  │
    └────────────┘    └──────────────┘    └──────────────┘
         ↓                    ↓
    ┌────────────────────────────────┐
    │  Shared SQLite Database        │
    │  (decoai.sqlite)               │
    └────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│         Geniex Server (18181) — Qwen2.5-VL Model            │
│  - Item detection in decoration images                      │
│  - OpenAI-compatible API                                    │
│  - Runs on Snapdragon NPU (with QNN SDK)                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              External Services (Optional)                    │
│  - Telegram Bot (owner notifications)                       │
│  - Arduino Vision (shelf refresh)                           │
│  - Model backends (invoice/image analysis)                  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Windows 10/11
- [Node.js](https://nodejs.org) >= 22
- [OpenClaw](https://github.com/openclaw/openclaw) — `npm install -g openclaw`
- Python 3.12 (for inventory-management and cost-estimation CLIs)
- [Geniex](https://github.com/geniex/geniex) — `npm install -g geniex` (for Qwen2.5-VL model inference)
- [QNN SDK](https://developer.qualcomm.com/software/qualcomm-neural-processing-sdk) (for Qwen2.5-VL on Snapdragon)
- Git (optional, for cloning the repo)

## First-time setup

**1. Copy this folder to the new PC:**

```powershell
# On the new PC, clone or copy the DecoAI repo
git clone <repo-url> C:\mounika\DecoAI
cd C:\mounika\DecoAI\openclaw-setup
```

The `openclaw-setup/` folder is self-contained — it includes all skills in the `skills/` subfolder, so you don't need the rest of the repo.

**2. Run setup:**

```powershell
.\setup.ps1
```

This will:

1. Check that `openclaw` is installed globally
2. Verify all DecoAI skill folders exist
3. Create `~/.openclaw/workspace/Skills/` if needed
4. Copy `database/`, `inventory-management/`, `cost-estimation/`, and `amazon-url-builder/` into the workspace
5. Create `Skills/.env` with default configuration

**3. Configure the shared database path (if needed):**

Edit `~/.openclaw/workspace/Skills/.env` and set `DECOAI_DB_PATH` to point to your shared inventory database:

```
DECOAI_DB_PATH=C:\path\to\database\decoai.sqlite
```

If you're using the same PC and repo folder, the default (relative to the repo root) will work.

**4. Fill in any model backend credentials (optional):**

If you want to use a vision model for invoice/image analysis, set:

```
INVOICE_READ_MODEL_URL=http://your-model-server:port/v1
INVOICE_READ_MODEL_NAME=your-model-name
INVOICE_READ_API_KEY=your-api-key

IMAGE_READ_MODEL_URL=http://your-model-server:port/v1
IMAGE_READ_MODEL_NAME=your-model-name
IMAGE_READ_API_KEY=your-api-key
```

Without these, the skills will use mock/dummy data for testing.

**5. Configure Telegram bot for owner notifications (optional):**

If you want the system to automatically notify the owner when clients confirm decoration ideas, set up a Telegram bot:

1. Create a bot with [@BotFather](https://t.me/botfather) on Telegram
2. Get your chat ID using [@userinfobot](https://t.me/userinfobot)
3. Add to `~/.openclaw/workspace/Skills/.env`:

```
TELEGRAM_BOT_TOKEN=your-bot-token-here
TELEGRAM_OWNER_CHAT_ID=your-chat-id-here
```

When a client confirms a decoration concept, the owner will automatically receive a Telegram message with:
- List of missing items to purchase
- Quantities needed
- Total cost

See [WORKFLOW-DECORATION-CONCEPT.md](System/WORKFLOW-DECORATION-CONCEPT.md) for the full workflow.

**6. Install Qwen2.5-VL model service (optional but recommended):**

For automatic item detection in decoration images, install Geniex:

1. Install Geniex globally:
   ```powershell
   npm install -g geniex
   ```

2. Install [QNN SDK](https://developer.qualcomm.com/software/qualcomm-neural-processing-sdk) from Qualcomm (for NPU acceleration)

When you run `start.ps1`, it will automatically start the Geniex server with the Qwen2.5-VL-7B-Instruct model on port 18181.

When a client confirms a decoration image, the workflow will automatically call the Geniex server to detect items. If Geniex is not running, item detection will use mock data for testing.

## Starting the gateway

```powershell
.\start.ps1
```

This will:

1. Load `.env` into the process environment
2. Start Geniex server (if installed) on port 18181 for item detection
3. Start `openclaw gateway run` with all env vars injected
4. Tail the log to the console

Press **Ctrl+C** to stop both services.

## Skills

### inventory-management

Owner-facing inventory intake and stock-check. Three CLIs:

- `decoai-invoice` — extract line items from a purchase invoice and add to inventory
- `decoai-image` — detect decoration items in a photo and check against stock
- `decoai-refresh` — sync shelf stock from Arduino vision counts (or dummy data)

See [`inventory-management/SKILL.md`](../inventory-management/SKILL.md) for details.

### cost-estimation

Itemized have-vs-need cost estimate for a decoration concept.

- `decoai-estimate` — check needed items against inventory DB and report what's missing

See [`cost-estimation/SKILL.md`](../cost-estimation/SKILL.md) for details.

### amazon-url-builder

Takes missing items and returns Amazon purchase links.

- `POST /purchase-links` — HTTP endpoint (runs on port 8004 by default)

### sd3-image-generation

Stable Diffusion 3 image generation on local NPU (no cloud, no API key needed).

- `SD3_Tool.py` — CLI tool for generating images
- `session_server.py` — Session server for batch operations

See [`sd3-image-generation/SKILL.md`](skills/sd3-image-generation/SKILL.md) for details.

## Workflows

### Decoration Concept Workflow

Automated end-to-end flow when clients upload decoration images and confirm ideas:

1. **Client uploads image** → Agent analyzes it using Geniex (Qwen2.5-VL model) to detect decoration items
2. **Client confirms** → Agent automatically gets cost estimate from database
3. **Results sent to client** → Itemized breakdown (in stock vs. need to buy) with total cost
4. **Owner notified via Telegram** → Missing items list and total cost (automatic)
5. **Owner generates purchase links** → Uses Amazon URL Builder to create shopping links

**Flow diagram:**
```
Client uploads image
    ↓
Geniex detects items (Qwen2.5-VL model)
    ↓
Client confirms decoration idea
    ↓
Cost estimation (database pricing)
    ↓
Results to client + Telegram notification to owner
    ↓
Owner generates Amazon links for missing items
```

**Setup required:**
- Geniex installed and running (automatic with `start.ps1`)
- Telegram bot configured (see step 5 in First-time setup)

See [WORKFLOW-DECORATION-CONCEPT.md](System/WORKFLOW-DECORATION-CONCEPT.md) for full details and example conversation flow.

## Services and Ports

When you run `start.ps1`, the following services start:

| Service | Port | Purpose |
|---------|------|---------|
| **OpenClaw Gateway** | 18789 | Main agent gateway (configurable in openclaw.json) |
| **Geniex Server** | 18181 | Qwen2.5-VL model inference for item detection |
| **Amazon URL Builder** | 8004 | HTTP service for generating Amazon purchase links |

## Logs

```
openclaw-gateway.log      # OpenClaw gateway stdout/stderr
geniex-server.log         # Geniex server stdout/stderr (if running)
```

## Troubleshooting

**"openclaw not found in PATH"**

Install OpenClaw globally:

```powershell
npm install -g openclaw
```

**"inventory-management not found at ..."**

Make sure you have the complete `openclaw-setup/` folder with the `skills/` subfolder. The setup script expects to find `skills/inventory-management/`, `skills/cost-estimation/`, `skills/database/`, and `skills/amazon-url-builder/`.

**Skills not showing up in OpenClaw**

After running `setup.ps1`, restart the gateway with `start.ps1`. OpenClaw reads the skills directory on startup.

**Database file not found**

Check that `DECOAI_DB_PATH` in `~/.openclaw/workspace/Skills/.env` points to a valid file. If the file doesn't exist, the skills will create it on first run (with an empty schema).

**Telegram notifications not working**

- Verify `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_CHAT_ID` are set in `~/.openclaw/workspace/Skills/.env`
- Test the bot token: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- Verify the chat ID is correct (use [@userinfobot](https://t.me/userinfobot) to confirm)
- Check that the bot has permission to send messages to that chat (start a conversation with the bot first)

**Geniex service not starting**

- Verify Geniex is installed: `geniex --version`
- Install with: `npm install -g geniex`
- Check that QNN SDK is installed (for NPU acceleration)
- Check `geniex-server.log` in the openclaw-setup folder for error details
- Geniex server runs on port 18181 by default

**Item detection using mock data**

- If Geniex is not running, item detection will use deterministic mock data for testing
- This is fine for development but won't detect real items in images
- Install Geniex to enable real item detection

## On a different PC

To set up DecoAI on a different PC:

1. Copy just the `openclaw-setup/` folder (it's self-contained with all skills in `skills/`)
2. Run `.\setup.ps1`
3. Edit `~/.openclaw/workspace/Skills/.env` to point `DECOAI_DB_PATH` at your shared database location
4. Run `.\start.ps1`

If you want to share the database across multiple PCs, set `DECOAI_DB_PATH` to a network path (e.g., `\\server\share\decoai.sqlite`).
