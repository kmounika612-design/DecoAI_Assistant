#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up DecoAI skills in OpenClaw workspace.

    Copies all DecoAI skills (inventory-management, cost-estimation, database)
    and required files from this folder into ~/.openclaw/workspace/Skills,
    then patches openclaw.json with the shared DB path.

.PARAMETER Clean
    Remove ~/.openclaw before setup. Use this for a fresh start.
#>

param(
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-OK([string]$msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "    [WARN] $msg" -ForegroundColor Yellow
}

function Write-Fail([string]$msg) {
    Write-Host "    [FAIL] $msg" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile   = Join-Path $ScriptDir ".env"

# Resolve openclaw workspace from openclaw.json or use default
$OpenclawConfig     = "$env:USERPROFILE\.openclaw\openclaw.json"
$WorkspaceDir       = "$env:USERPROFILE\.openclaw\workspace"
$WorkspaceSkillsDir = "$WorkspaceDir\Skills"

if (Test-Path $OpenclawConfig) {
    try {
        $cfg = Get-Content $OpenclawConfig -Raw | ConvertFrom-Json
        $ws  = $cfg.agents.defaults.workspace
        if ($ws) {
            $WorkspaceDir       = $ws
            $WorkspaceSkillsDir = Join-Path $ws "Skills"
        }
    } catch {
        Write-Warn "Could not parse openclaw.json - will use default workspace path"
    }
}

# DecoAI skill sources (in openclaw-setup/skills/)
$SkillsDir         = Join-Path $ScriptDir "skills"
$InventorySrc      = Join-Path $SkillsDir "inventory-management"
$CostEstimationSrc = Join-Path $SkillsDir "cost-estimation"
$DatabaseSrc       = Join-Path $SkillsDir "database"
$AmazonBuilderSrc  = Join-Path $SkillsDir "amazon-url-builder"
$SD3Src            = Join-Path $SkillsDir "sd3-image-generation"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  DecoAI OpenClaw Setup" -ForegroundColor Magenta
Write-Host "  workspace:       $WorkspaceDir"
Write-Host "  skills:          $WorkspaceSkillsDir"
Write-Host "  inventory-mgmt:  $InventorySrc"
Write-Host "  cost-estimation: $CostEstimationSrc"
Write-Host "  database:        $DatabaseSrc"
Write-Host "  amazon-builder:  $AmazonBuilderSrc"
Write-Host "  sd3-image-gen:   $SD3Src"
Write-Host ""

# ---------------------------------------------------------------------------
# Clean ~/.openclaw if requested
# ---------------------------------------------------------------------------

if ($Clean) {
    $OpenclawDir = "$env:USERPROFILE\.openclaw"
    if (Test-Path $OpenclawDir) {
        Write-Step "Removing $OpenclawDir (-Clean)"
        Remove-Item -Path $OpenclawDir -Recurse -Force
        Write-OK "Removed $OpenclawDir"
    } else {
        Write-OK "-Clean specified but $OpenclawDir does not exist - nothing to remove"
    }
}

# ---------------------------------------------------------------------------
# Preflight: check openclaw is installed
# ---------------------------------------------------------------------------

Write-Step "Checking prerequisites"

$openclaw = Get-Command openclaw -ErrorAction SilentlyContinue
if (-not $openclaw) {
    Write-Fail "openclaw not found in PATH - install with: npm install -g openclaw"
    exit 1
}
Write-OK "openclaw found: $($openclaw.Source)"

# Check that all skill sources exist
$skillSources = @(
    @{ name = "inventory-management"; path = $InventorySrc },
    @{ name = "cost-estimation"; path = $CostEstimationSrc },
    @{ name = "database"; path = $DatabaseSrc },
    @{ name = "amazon-url-builder"; path = $AmazonBuilderSrc },
    @{ name = "sd3-image-generation"; path = $SD3Src }
)

foreach ($skill in $skillSources) {
    if (-not (Test-Path $skill.path)) {
        Write-Fail "$($skill.name) not found at $($skill.path)"
        exit 1
    }
    Write-OK "$($skill.name) found"
}

# ---------------------------------------------------------------------------
# Check for geniex (Qwen2.5-VL model service)
$geniex = Get-Command geniex -ErrorAction SilentlyContinue
if (-not $geniex) {
    Write-Warn "geniex not found in PATH - Qwen2.5-VL model inference will not work"
    Write-Warn "Install geniex to enable item detection in decoration images"
} else {
    Write-OK "geniex found: $($geniex.Source)"
}

# ---------------------------------------------------------------------------
# Load .env if present (optional, for future use)
# ---------------------------------------------------------------------------

$envVars = @{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch "^#") {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                $envVars[$key] = $val
                [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
    Write-OK "Loaded .env"
} else {
    Write-Warn ".env not found - using defaults"
}

# ---------------------------------------------------------------------------
# Create workspace if needed
# ---------------------------------------------------------------------------

Write-Step "Preparing workspace"

if (-not (Test-Path $WorkspaceDir)) {
    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null
    Write-OK "Created $WorkspaceDir"
}

if (-not (Test-Path $WorkspaceSkillsDir)) {
    New-Item -ItemType Directory -Path $WorkspaceSkillsDir -Force | Out-Null
    Write-OK "Created $WorkspaceSkillsDir"
}

# ---------------------------------------------------------------------------
# Copy database (shared by all skills)
# ---------------------------------------------------------------------------

Write-Step "Installing shared database module"

$dbDest = Join-Path $WorkspaceSkillsDir "database"
if (Test-Path $dbDest) {
    Remove-Item -Path $dbDest -Recurse -Force
}
Copy-Item -Path $DatabaseSrc -Destination $dbDest -Recurse -Force
Write-OK "Copied database -> $dbDest"

# ---------------------------------------------------------------------------
# Copy inventory-management skill
# ---------------------------------------------------------------------------

Write-Step "Installing inventory-management skill"

$invDest = Join-Path $WorkspaceSkillsDir "inventory-management"
if (Test-Path $invDest) {
    Remove-Item -Path $invDest -Recurse -Force
}
Copy-Item -Path $InventorySrc -Destination $invDest -Recurse -Force
Write-OK "Copied inventory-management -> $invDest"

# ---------------------------------------------------------------------------
# Copy cost-estimation skill
# ---------------------------------------------------------------------------

Write-Step "Installing cost-estimation skill"

$costDest = Join-Path $WorkspaceSkillsDir "cost-estimation"
if (Test-Path $costDest) {
    Remove-Item -Path $costDest -Recurse -Force
}
Copy-Item -Path $CostEstimationSrc -Destination $costDest -Recurse -Force
Write-OK "Copied cost-estimation -> $costDest"

# ---------------------------------------------------------------------------
# Copy amazon-url-builder skill
# ---------------------------------------------------------------------------

Write-Step "Installing amazon-url-builder skill"

$amazonDest = Join-Path $WorkspaceSkillsDir "amazon-url-builder"
if (Test-Path $amazonDest) {
    Remove-Item -Path $amazonDest -Recurse -Force
}
Copy-Item -Path $AmazonBuilderSrc -Destination $amazonDest -Recurse -Force
Write-OK "Copied amazon-url-builder -> $amazonDest"

# ---------------------------------------------------------------------------
# Copy SD3 image generation skill
# ---------------------------------------------------------------------------

Write-Step "Installing SD3 image generation skill"

$sd3Dest = Join-Path $WorkspaceSkillsDir "sd3-image-generation"
if (Test-Path $sd3Dest) {
    Remove-Item -Path $sd3Dest -Recurse -Force
}
Copy-Item -Path $SD3Src -Destination $sd3Dest -Recurse -Force
Write-OK "Copied sd3-image-generation -> $sd3Dest"

# ---------------------------------------------------------------------------
# Create/patch .env in workspace Skills folder
# ---------------------------------------------------------------------------

Write-Step "Setting up workspace .env"

$skillsEnvFile = Join-Path $WorkspaceSkillsDir ".env"
$decoaiDbPath  = if ($envVars.ContainsKey("DECOAI_DB_PATH")) {
    $envVars["DECOAI_DB_PATH"]
} else {
    # Default: database/decoai.sqlite in the skills folder
    Join-Path (Join-Path $SkillsDir "database") "decoai.sqlite"
}

$envContent = @"
# DecoAI shared database path — all skills read/write this file
DECOAI_DB_PATH=$decoaiDbPath

# Inventory Manager — invoice upload model backend
INVOICE_READ_MODEL_URL=
INVOICE_READ_MODEL_NAME=
INVOICE_READ_API_KEY=

# Inventory Manager — decoration photo analysis model backend
IMAGE_READ_MODEL_URL=
IMAGE_READ_MODEL_NAME=
IMAGE_READ_API_KEY=

# Inventory Manager — shelf refresh (Arduino vision)
ARDUINO_URL=
REORDER_THRESHOLD=5
REFRESH_INTERVAL_SECONDS=300

# Cost Estimator — price lookup (currently unused; pricing is DB-only)
SERPAPI_KEY=
PRICE_LOOKUP_URL=
PRICE_PREDICT_MODEL_URL=
PRICE_PREDICT_MODEL_NAME=
PRICE_PREDICT_API_KEY=

# Amazon URL Builder
AMAZON_AFFILIATE_TAG=

# Telegram Bot — Owner Notifications
TELEGRAM_BOT_TOKEN=
TELEGRAM_OWNER_CHAT_ID=

# Qwen2.5-VL Model Service (Geniex)
# Used for item detection in decoration images
GENIEX_MODEL=ai-hub-models/Qwen2.5-VL-7B-Instruct

# SSL verification (set to true to disable for self-signed certs)
DECOAI_INSECURE_SSL=false
"@

Set-Content -Path $skillsEnvFile -Value $envContent -Encoding UTF8
Write-OK "Created $skillsEnvFile"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Edit $skillsEnvFile and fill in any required values"
Write-Host "    2. Run .\start.ps1 to launch openclaw"
Write-Host ""
