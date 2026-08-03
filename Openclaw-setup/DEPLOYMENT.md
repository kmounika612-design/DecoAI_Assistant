# DecoAI OpenClaw Deployment Checklist

## Pre-Deployment (on source PC)

- [x] All skills copied to `openclaw-setup/skills/`
  - [x] database/
  - [x] inventory-management/
  - [x] cost-estimation/
  - [x] amazon-url-builder/
- [x] Setup scripts created and tested
  - [x] setup.ps1 (copies skills to workspace)
  - [x] start.ps1 (launches gateway)
- [x] Documentation complete
  - [x] README.md (full guide)
  - [x] QUICKSTART.txt (one-page guide)
  - [x] STRUCTURE.md (folder layout)
  - [x] .env.example (config template)

## Deployment to New PC

### Step 1: Prerequisites
- [ ] Windows 10/11
- [ ] Node.js >= 22 installed
- [ ] Python 3.12 installed
- [ ] OpenClaw installed globally: `npm install -g openclaw`
- [ ] Git installed (optional, for cloning repo)

### Step 2: Copy Files
- [ ] Copy `openclaw-setup/` folder to new PC
  - Option A: Clone entire repo, copy the folder
  - Option B: Copy folder from USB/network share
  - Option C: Download as ZIP and extract

### Step 3: Run Setup
```powershell
cd C:\mounika\DecoAI\openclaw-setup
.\setup.ps1
```
- [ ] Setup completes without errors
- [ ] All skills copied to `~/.openclaw/workspace/Skills/`
- [ ] `.env` file created at `~/.openclaw/workspace/Skills/.env`

### Step 4: Configure (Optional)
- [ ] Edit `~/.openclaw/workspace/Skills/.env` if needed
  - Set `DECOAI_DB_PATH` to shared database location
  - Configure model backends (INVOICE_READ_MODEL_URL, IMAGE_READ_MODEL_URL)
  - Set AMAZON_AFFILIATE_TAG if using Amazon links

### Step 5: Start Gateway
```powershell
.\start.ps1
```
- [ ] Gateway starts without errors
- [ ] Log shows "Gateway ready on port 18789"
- [ ] OpenClaw accessible at http://127.0.0.1:18789

### Step 6: Verify Skills
- [ ] Restart gateway (Ctrl+C, then `.\start.ps1`)
- [ ] Skills appear in OpenClaw workspace
  - [ ] inventory-management (decoai-invoice, decoai-image, decoai-refresh)
  - [ ] cost-estimation (decoai-estimate)
  - [ ] amazon-url-builder

## Multi-PC Setup (Shared Database)

If deploying to multiple PCs with a shared database:

1. Set up first PC normally (steps 1-6 above)
2. On subsequent PCs:
   - [ ] Run `.\setup.ps1` on each PC
   - [ ] Edit `~/.openclaw/workspace/Skills/.env` on each PC
   - [ ] Set `DECOAI_DB_PATH` to the same network path:
     ```
     DECOAI_DB_PATH=\server\share\decoai.sqlite
     ```
   - [ ] All PCs now read/write the same database

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "openclaw not found" | `npm install -g openclaw` |
| "Skills not showing" | Restart gateway with `.\start.ps1` |
| "Database not found" | Check `DECOAI_DB_PATH` in `.env` |
| "Model backend error" | Leave model URLs blank to use mock data |
| "Permission denied" | Run PowerShell as Administrator |

## Post-Deployment

- [ ] Test each skill with sample data
- [ ] Verify database is being read/written
- [ ] Check logs for any errors
- [ ] Document any custom configuration

## Rollback

If something goes wrong:

1. Stop the gateway (Ctrl+C)
2. Delete `~/.openclaw/workspace/Skills/` folder
3. Run `.\setup.ps1` again to re-deploy

The database is never modified by setup, so no data is lost.

## Support

For issues, check:
- `README.md` — full documentation
- `STRUCTURE.md` — folder layout and file descriptions
- `QUICKSTART.txt` — one-page reference
- `~/.openclaw/workspace/Skills/.env` — configuration
- Gateway log: `openclaw-setup/openclaw-gateway.log`
