# OpenClaw Twitter Demo

An [OpenClaw](https://github.com/openclaw/openclaw) gateway setup with Telegram and X/Twitter integrations, on-device LLM inference via Ollama, image generation via Nano Banana Pro, and cost savings tracking built into the OpenClaw control UI.

## What's in this repo

```
openclaw-twitter-demo/
  setup.ps1                     # One-time setup: clone oc-repo, build, configure
  start.ps1                     # Start the gateway
  openclaw.json                 # OpenClaw config (copied to ~/.openclaw/ by setup.ps1)
  openclaw-cost-savings.patch   # Our UI changes applied on top of oc-repo base commit
  nano-banana-pro/              # Image generation skill (Gemini Image API)
  xurl/                         # X/Twitter CLI (cloned + built by setup.ps1)
  .env                          # Secrets (copy from .env.example and fill in)
  .env.example                  # Template for required environment variables
```

## Prerequisites

- Windows 10/11
- [Node.js](https://nodejs.org) >= 22
- [pnpm](https://pnpm.io) — `npm install -g pnpm`
- [Git](https://git-scm.com)
- Go — installed automatically by `setup.ps1` if missing

## First-time setup

**1. Copy and fill in `.env`:**

```powershell
Copy-Item .env.example .env
# Edit .env and fill in all values
```

Required variables:

| Variable | Where to get it |
|---|---|
| `XURL_CLIENT_ID` / `XURL_CLIENT_SECRET` | [X Developer Portal](https://developer.x.com/en/portal/dashboard) |
| `XURL_ACCESS_TOKEN` / `XURL_TOKEN_SECRET` / `XURL_CONSUMER_KEY` / `XURL_CONSUMER_SECRET` | X Developer Portal — OAuth 1.0a credentials |
| `XURL_BEARER_TOKEN` | X Developer Portal — app-only bearer token |
| `GEMINI_API_KEY` | [Google AI Studio](https://aistudio.google.com/app/apikey) |
| `TELEGRAM_BOT_TOKEN` | [@BotFather](https://t.me/BotFather) on Telegram |
| `OLLAMA_API_KEY` | Your Ollama account dashboard |
| `BRAVE_API_KEY` | [Brave Search API](https://api.search.brave.com) |
| `OPENCLAW_GATEWAY_TOKEN` | Any random hex string — `openssl rand -hex 24` |

**2. Run setup:**

```powershell
.\setup.ps1
```

This will:

1. Check prerequisites (Node >= 22, pnpm, git)
2. Clone `openclaw/openclaw` into `oc-repo/`, check out the pinned base commit, and apply `openclaw-cost-savings.patch` as a commit
3. Run `pnpm install` and build `oc-repo` (TypeScript + control UI)
4. Run `pnpm openclaw setup` and copy `openclaw.json` to `~/.openclaw/`, patching in your API keys
5. Install Go if missing, clone `xdevplatform/xurl`, build `xurl.exe`, and add it to your user PATH
6. Configure xurl with your X/Twitter credentials (OAuth 1.0a + OAuth 2.0 + bearer token)
7. Install [uv](https://docs.astral.sh/uv) for the nano-banana-pro Python skill
8. Copy `nano-banana-pro` and `xurl` skills into the OpenClaw workspace skills directory

## Starting the gateway

```powershell
.\start.ps1
```

This will:

1. Load `.env` into the process environment
2. Ensure `xurl` is on the PATH
3. Build `oc-repo` (`pnpm build && pnpm ui:build`) — use `-NoBuild` to skip
4. Read the gateway port and auth token from `~/.openclaw/openclaw.json`
5. Start `pnpm openclaw gateway run` with all env vars injected

Press **Ctrl+C** to stop.

### Options

| Flag | Description |
|---|---|
| `-NoBuild` | Skip the build step (use existing `dist/`) |
| `-Config <path>` | Use a custom `openclaw.json` instead of `~/.openclaw/openclaw.json` |

## Cost savings in the UI

The OpenClaw control UI at `http://127.0.0.1:18789/usage` shows on-device savings vs running the same workload on Claude Sonnet 4.5 ($3 input / $15 output per 1M tokens). Since inference runs on-device via Ollama at $0, the full cloud price is your saving.

**Usage Overview** (the `/usage` tab) shows:
- **On-device Savings** — total dollar amount saved vs cloud (green hero tile)
- **Input tokens** — total prompt tokens with cache breakdown
- **Output tokens** — total completion tokens

**Context bar** (in the chat window) shows `8k / 128k · saved ~$0.0124` inline next to the context usage meter.

## Skills

### nano-banana-pro

Generates and edits images using the Gemini Image API. Triggered from any connected channel (Telegram, X/Twitter, etc.):

```
generate an image of a sunset over mountains
```

Requires `GEMINI_API_KEY` in `.env`. Images are capped at 1K resolution to stay within Telegram's 6 MB file limit.

### xurl

Authenticated X/Twitter API access — post tweets, search, send DMs, upload media. Credentials are configured automatically by `setup.ps1`.

To verify auth is working:

```powershell
.\xurl\xurl.exe search "news"
```

## Logs

```
openclaw-gateway.log      # gateway stdout
openclaw-gateway.log.err  # gateway stderr
```

## Gateway config

OpenClaw reads from `~/.openclaw/openclaw.json` (written by `setup.ps1` from `openclaw.json` in this repo). Key settings:

| Setting | Value |
|---|---|
| `gateway.port` | `18789` (default) |
| `gateway.auth.token` | Set from `OPENCLAW_GATEWAY_TOKEN` in `.env` |
| `agents.defaults.workspace` | Skills are installed here under `skills/` |
| `channels.telegram` | Configured with `TELEGRAM_BOT_TOKEN` |
