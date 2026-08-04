#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the openclaw-twitter-demo environment:
      1. Installs dependencies for oc-repo (pnpm install + build)
      2. Installs Go if missing, clones xdevplatform/xurl, builds with "go build"
      3. Runs xurl auth sequence (remove default, add wosaiplugins2, oauth1, bearer, oauth2)
      4. Installs uv (Python package manager for nano-banana-pro)
      5. Copies the nano-banana-pro skill into the openclaw workspace skills dir
      6. Copies the xurl skill into the openclaw workspace skills dir

.PARAMETER ImageGenMode
    Agent mode: "hybrid" (default) or "cloud". Controls which AGENTS.md is
    copied into the workspace — AGENTS-hybrid.md or AGENTS-cloud.md.

.PARAMETER Clean
    Remove ~/.openclaw before setup. Use this for a fresh start.
#>

param(
    [ValidateSet("hybrid", "cloud")]
    [string]$ImageGenMode = "cloud",
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

function Assert-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Fail "$cmd is not installed or not in PATH"
        throw "Missing required command: $cmd"
    }
}

function Invoke-Step([string]$label, [scriptblock]$block) {
    Write-Step $label
    try {
        & $block
    } catch {
        Write-Fail "Step failed: $_"
        throw
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$OcRepo        = Join-Path $ScriptDir "oc-repo"
$NanoBananaSrc = Join-Path $ScriptDir "nano-banana-pro"
$EnvFile       = Join-Path $ScriptDir ".env"

# ---------------------------------------------------------------------------
# Load and validate .env
# ---------------------------------------------------------------------------

if (-not (Test-Path $EnvFile)) {
    Write-Fail ".env file not found at $EnvFile"
    Write-Host "  Copy .env.example to .env and fill in all values." -ForegroundColor Yellow
    exit 1
}

# Parse KEY=VALUE lines from .env into a hashtable and into the process environment
$envVars = @{}
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

# Mandatory variables - validated against .env file contents directly,
# so missing or absent keys are always caught regardless of shell environment
$requiredVars = @(
    "XURL_CLIENT_ID",
    "XURL_CLIENT_SECRET",
    "XURL_ACCESS_TOKEN",
    "XURL_TOKEN_SECRET",
    "XURL_CONSUMER_KEY",
    "XURL_CONSUMER_SECRET",
    "XURL_BEARER_TOKEN",
    "GEMINI_API_KEY",
    "TELEGRAM_BOT_TOKEN",
    "OLLAMA_API_KEY",
    "BRAVE_API_KEY",
    "OPENCLAW_GATEWAY_TOKEN",
    "OPENROUTER_API_KEY"
)

$missing = @()
foreach ($var in $requiredVars) {
    if (-not $envVars.ContainsKey($var) -or [string]::IsNullOrWhiteSpace($envVars[$var])) {
        $missing += $var
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Fail "The following required variables are missing or empty in .env:"
    $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ""
    exit 1
}

Write-OK "All required .env variables present"

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

# Resolve openclaw workspace skills dir from openclaw.json
$OpenclawConfig     = "$env:USERPROFILE\.openclaw\openclaw.json"
$WorkspaceSkillsDir = "$env:USERPROFILE\.openclaw\workspace\skills"

if (Test-Path $OpenclawConfig) {
    try {
        $cfg = Get-Content $OpenclawConfig -Raw | ConvertFrom-Json
        $ws  = $cfg.agents.defaults.workspace
        if ($ws) {
            $WorkspaceSkillsDir = Join-Path $ws "skills"
        }
    } catch {
        Write-Warn "Could not parse openclaw.json - will use default workspace path"
    }
}

# xurl skill source: sibling openclaw/skills/xurl
$OpenclawSkillsDir = Join-Path $ScriptDir "openclaw\skills"
$XurlSkillSrc      = Join-Path $OpenclawSkillsDir "xurl"

# xurl repo and binary
$XurlRepoDir = Join-Path $ScriptDir "xurl"
$XurlBin     = Join-Path $XurlRepoDir "xurl.exe"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  OpenClaw Twitter Demo - Setup" -ForegroundColor Magenta
Write-Host "  oc-repo:          $OcRepo"
Write-Host "  workspace skills: $WorkspaceSkillsDir"
Write-Host "  nano-banana-pro:  $NanoBananaSrc"
Write-Host "  image-gen-hybrid: $(Join-Path $ScriptDir 'image-gen-hybrid')"
Write-Host "  xurl skill src:   $XurlSkillSrc"
Write-Host "  xurl repo:        $XurlRepoDir"
Write-Host "  system files:     $(Join-Path $ScriptDir 'system')"
Write-Host "  mode:             $ImageGenMode"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------

Invoke-Step "Checking prerequisites" {
    # Verify Python 3.12 is active
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd) {
        Write-Fail "python not found in PATH"
        exit 1
    }
    $pythonExe = $pythonCmd.Source
    $pythonVer = & $pythonExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>&1
    if ($pythonVer -ne "3.12") {
        Write-Fail "Python 3.12 required (found $pythonVer at $pythonExe)"
        Write-Host "  Install Python 3.12 from https://python.org and ensure it is first on PATH." -ForegroundColor Yellow
        exit 1
    }
    Write-OK "python $pythonVer ($pythonExe)"
    $script:PythonExe = $pythonExe

    Assert-Command "node"
    $nodeVer   = (node --version) -replace "v", ""
    $nodeMajor = [int]($nodeVer.Split(".")[0])
    if ($nodeMajor -lt 22) {
        throw "Node.js >= 22 required (found $nodeVer). Install from https://nodejs.org"
    }
    Write-OK "node $nodeVer"

    Assert-Command "pnpm"
    Write-OK "pnpm $(pnpm --version)"

    Assert-Command "git"
    Write-OK "git $(git --version)"

    if (-not (Test-Path $NanoBananaSrc)) {
        throw "nano-banana-pro skill not found at $NanoBananaSrc"
    }
    Write-OK "nano-banana-pro skill found"
}

# ---------------------------------------------------------------------------
# 1b. Clone oc-repo if missing and checkout base commit
# ---------------------------------------------------------------------------

$BaseCommit = "v2026.5.12"
$PatchFile  = Join-Path $ScriptDir "openclaw-cost-savings.patch"

if (-not (Test-Path $OcRepo)) {
    Invoke-Step "Cloning openclaw/openclaw into oc-repo" {
        git clone https://github.com/openclaw/openclaw.git $OcRepo
        Write-OK "Cloned into $OcRepo"
    }

    Invoke-Step "Checking out base commit $BaseCommit" {
        Push-Location $OcRepo
        try {
            git checkout $BaseCommit
            Write-OK "Checked out $BaseCommit"
        } finally {
            Pop-Location
        }
    }
    # ---------------------------------------------------------------------------
    # 1c. Apply cost-savings patch (if not already applied)
    # ---------------------------------------------------------------------------

    Invoke-Step "Applying cost-savings patch" {
        if (-not (Test-Path $PatchFile)) {
            throw "Patch file not found at $PatchFile"
        }
        Push-Location $OcRepo
        try {
            $checkResult = & git apply --check $PatchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                git config --global user.email "example@example.com"
                git config --global user.name "Example Name"
                git am -3 $PatchFile
                if ($LASTEXITCODE -ne 0) {
                    git am --abort 2>$null
                    throw "git am failed - resolve conflicts manually in oc-repo then re-run"
                }
                Write-OK "Patch applied as commit"
            } else {
                Write-OK "Patch already applied - skipping"
            }
        } finally {
            Pop-Location
        }
    }
} else {
    Write-OK "oc-repo found at $OcRepo - skipping clone"
}



# ---------------------------------------------------------------------------
# 2. pnpm install
# ---------------------------------------------------------------------------

Invoke-Step "Installing oc-repo dependencies (pnpm install)" {
    Push-Location $OcRepo
    try {
        pnpm install --frozen-lockfile
        Write-OK "pnpm install complete"
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 3. Build oc-repo
# ---------------------------------------------------------------------------

Invoke-Step "Building oc-repo" {
    Push-Location $OcRepo
    try {
        pnpm build
        Write-OK "build complete"
        Write-Host "    Building control UI ..."
        pnpm ui:build
        Write-OK "ui:build complete"
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 4. Run openclaw setup and override config
# ---------------------------------------------------------------------------

Invoke-Step "Running pnpm openclaw setup" {
    Push-Location $OcRepo
    try {
        pnpm openclaw setup
        Write-OK "openclaw setup complete"
    } finally {
        Pop-Location
    }
}

Invoke-Step "Overriding ~/.openclaw/openclaw.json from repo openclaw.json" {
    $OpenclawConfigDir = "$env:USERPROFILE\.openclaw"
    $OpenclawConfigDst = "$OpenclawConfigDir\openclaw.json"
    $OpenclawJsonSrc   = Join-Path $ScriptDir "openclaw.json"

    if (-not (Test-Path $OpenclawConfigDir)) {
        New-Item -ItemType Directory -Path $OpenclawConfigDir -Force | Out-Null
        Write-OK "Created $OpenclawConfigDir"
    }

    Copy-Item -Path $OpenclawJsonSrc -Destination $OpenclawConfigDst -Force
    Write-OK "Copied openclaw.json -> $OpenclawConfigDst"

    # Patch placeholder values from .env and environment
    $configRaw = Get-Content $OpenclawConfigDst -Raw
    $configRaw = $configRaw -replace "BRAVE_API_KEY_PLACEHOLDER",          $env:BRAVE_API_KEY
    $configRaw = $configRaw -replace "OLLAMA_API_KEY_PLACEHOLDER",         $env:OLLAMA_API_KEY
    $configRaw = $configRaw -replace "OPENCLAW_GATEWAY_TOKEN_PLACEHOLDER", $env:OPENCLAW_GATEWAY_TOKEN
    $workspacePath = "$env:USERPROFILE\.openclaw\workspace" -replace '\\', '\\'
    $configRaw = $configRaw -replace "OPENCLAW_WORKSPACE_PLACEHOLDER", $workspacePath
    Set-Content -Path $OpenclawConfigDst -Value $configRaw -NoNewline
    Write-OK "Patched BRAVE_API_KEY, OLLAMA_API_KEY, OPENCLAW_GATEWAY_TOKEN, workspace into config"
}

# ---------------------------------------------------------------------------
# 6. Install Go if missing
# ---------------------------------------------------------------------------

Invoke-Step "Checking Go installation" {
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
    if ($goCmd) {
        Write-OK "go already installed: $(go version)"
    } else {
        $goVersion   = "1.22.4"
        $goInstaller = "https://go.dev/dl/go${goVersion}.windows-amd64.msi"
        $msiPath     = Join-Path $env:TEMP "go-installer.msi"

        Write-Host "    Go not found - downloading Go $goVersion ..."
        Invoke-WebRequest -Uri $goInstaller -OutFile $msiPath -UseBasicParsing

        Write-Host "    Running Go installer (silent) ..."
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

        # Refresh PATH for this session
        $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $env:PATH    = "C:\Program Files\Go\bin;$machinePath;$userPath"

        $goCmd = Get-Command go -ErrorAction SilentlyContinue
        if ($goCmd) {
            Write-OK "Go installed: $(go version)"
        } else {
            throw "Go installed but 'go' not found in PATH. Restart your terminal and re-run setup."
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Clone and build xurl
# ---------------------------------------------------------------------------

Invoke-Step "Cloning xdevplatform/xurl and building with go build" {
    if (Test-Path $XurlRepoDir) {
        Write-Host "    Repo already exists - pulling latest ..."
        Push-Location $XurlRepoDir
        try {
            git pull --ff-only
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "    Cloning https://github.com/xdevplatform/xurl ..."
        git clone https://github.com/xdevplatform/xurl $XurlRepoDir
    }

    Push-Location $XurlRepoDir
    try {
        Write-Host "    Running: go build -o xurl.exe ."
        go build -o xurl.exe .
        if (-not (Test-Path $XurlBin)) {
            throw "go build completed but xurl.exe not found in $XurlRepoDir"
        }
        Write-OK "Built: $XurlBin"
    } finally {
        Pop-Location
    }

    # Persist xurl dir in user PATH
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$XurlRepoDir*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$XurlRepoDir;$userPath", "User")
        Write-OK "Added $XurlRepoDir to user PATH"
    }
    if ($env:PATH -notlike "*$XurlRepoDir*") {
        $env:PATH = "$XurlRepoDir;$env:PATH"
    }
    Write-OK "xurl ready at $XurlBin"
}

# ---------------------------------------------------------------------------
# 8. Configure xurl auth
# ---------------------------------------------------------------------------

Invoke-Step "Configuring xurl authentication" {
    # Check if auth is already working by running a live API call
    Write-Host "    Checking if xurl auth is already configured ..."
    $testOutput = & $XurlBin search "news" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-OK "xurl auth already working - skipping configuration"
    } else {
        Write-Host "    Auth check failed (exit $LASTEXITCODE) - configuring now ..."

        Write-Host "    Step 1/5: Remove default app ..."
        & $XurlBin auth apps remove default 2>&1 | ForEach-Object { Write-Host "      $_" }

        Write-Host "    Step 2/5: Add wosaiplugins2 app ..."
        & $XurlBin auth apps add wosaiplugins2 `
            --client-id     $env:XURL_CLIENT_ID `
            --client-secret $env:XURL_CLIENT_SECRET

        Write-Host "    Step 3/5: Configure OAuth 1.0a credentials ..."
        & $XurlBin auth oauth1 `
            --app             wosaiplugins2 `
            --access-token    $env:XURL_ACCESS_TOKEN `
            --token-secret    $env:XURL_TOKEN_SECRET `
            --consumer-key    $env:XURL_CONSUMER_KEY `
            --consumer-secret $env:XURL_CONSUMER_SECRET

        Write-Host "    Step 4/5: Set bearer token ..."
        & $XurlBin auth app wosaiplugins2 `
            --bearer-token $env:XURL_BEARER_TOKEN

        Write-Host "    Step 5/5: Configure OAuth 2.0 ..."
        & $XurlBin auth oauth2 --app wosaiplugins2

        Write-OK "xurl auth configuration complete"
    }
}


# ---------------------------------------------------------------------------
# 9. Install uv
# ---------------------------------------------------------------------------

Invoke-Step "Installing uv (Python package manager)" {
    $existing = Get-Command uv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-OK "uv already installed: $(uv --version)"
    } else {
        Write-Host "    Downloading uv installer ..."
        Invoke-RestMethod "https://astral.sh/uv/install.ps1" | Invoke-Expression
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $env:PATH = "$userPath;$env:PATH"
        $check = Get-Command uv -ErrorAction SilentlyContinue
        if ($check) {
            Write-OK "uv installed: $(uv --version)"
        } else {
            Write-Warn "uv installed but not in PATH yet - restart terminal or add %USERPROFILE%\.local\bin to PATH"
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Copy image generation skill into workspace (mode-dependent)
# ---------------------------------------------------------------------------

Invoke-Step "Installing image generation skill into workspace ($ImageGenMode mode)" {
    if (-not (Test-Path $WorkspaceSkillsDir)) {
        New-Item -ItemType Directory -Path $WorkspaceSkillsDir -Force | Out-Null
        Write-OK "Created $WorkspaceSkillsDir"
    }

    if ($ImageGenMode -eq "hybrid") {
        # Hybrid: copy image-gen-hybrid skill, remove nano-banana-pro if present
        $hybridSrc  = Join-Path $ScriptDir "image-gen-hybrid"
        $hybridDest = Join-Path $WorkspaceSkillsDir "image-gen-hybrid"
        $cloudDest  = Join-Path $WorkspaceSkillsDir "nano-banana-pro"
        if (-not (Test-Path $hybridSrc)) {
            throw "image-gen-hybrid skill not found at $hybridSrc"
        }
        if (Test-Path $cloudDest) {
            Remove-Item -Path $cloudDest -Recurse -Force
            Write-OK "Removed nano-banana-pro (not used in hybrid mode)"
        }
        Copy-Item -Path $hybridSrc -Destination $hybridDest -Recurse -Force
        Write-OK "Copied image-gen-hybrid -> $hybridDest"

        # Install Python dependencies
        $reqFile = Join-Path $hybridSrc "requirements.txt"
        if (Test-Path $reqFile) {
            Write-Host "    Installing image-gen-hybrid requirements into global Python ($script:PythonExe) ..."
            & $script:PythonExe -m pip install -r $reqFile --no-user
            if ($LASTEXITCODE -ne 0) {
                throw "pip install failed with exit code $LASTEXITCODE"
            }
            Write-OK "image-gen-hybrid requirements installed"
        } else {
            Write-Warn "requirements.txt not found at $reqFile - skipping"
        }
    } else {
        # Cloud: copy nano-banana-pro skill, remove image-gen-hybrid if present
        $hybridDest = Join-Path $WorkspaceSkillsDir "image-gen-hybrid"
        $cloudDest  = Join-Path $WorkspaceSkillsDir "nano-banana-pro"
        if (Test-Path $hybridDest) {
            Remove-Item -Path $hybridDest -Recurse -Force
            Write-OK "Removed image-gen-hybrid (not used in cloud mode)"
        }
        Copy-Item -Path $NanoBananaSrc -Destination $cloudDest -Recurse -Force
        Write-OK "Copied nano-banana-pro -> $cloudDest"
    }
}

# ---------------------------------------------------------------------------
# 11. Copy xurl skill into workspace
# ---------------------------------------------------------------------------

Invoke-Step "Installing xurl skill into workspace" {
    if (-not (Test-Path $XurlSkillSrc)) {
        Write-Warn "xurl skill source not found at $XurlSkillSrc - skipping"
    } else {
        $dest = Join-Path $WorkspaceSkillsDir "xurl"
        if (-not (Test-Path $WorkspaceSkillsDir)) {
            New-Item -ItemType Directory -Path $WorkspaceSkillsDir -Force | Out-Null
        }
        Copy-Item -Path $XurlSkillSrc -Destination $dest -Recurse -Force
        Write-OK "Copied xurl skill -> $dest"
    }
}

# ---------------------------------------------------------------------------
# Install openclaw globally, though we will be using oc-repo to host the claw
# ---------------------------------------------------------------------------

npm install -g openclaw@2026.5.7

# ---------------------------------------------------------------------------
# Copy system agent files into workspace
# ---------------------------------------------------------------------------

Invoke-Step "Copying system agent files into workspace ($ImageGenMode mode)" {
    $SystemSrc  = Join-Path $ScriptDir "system"
    $WorkspaceDir = if (Test-Path $OpenclawConfig) {
        try {
            $cfg = Get-Content $OpenclawConfig -Raw | ConvertFrom-Json
            $cfg.agents.defaults.workspace
        } catch { $null }
    } else { $null }
    $WorkspaceDir = if ($WorkspaceDir) { $WorkspaceDir } else { "$env:USERPROFILE\.openclaw\workspace" }

    if (-not (Test-Path $SystemSrc)) {
        Write-Warn "system/ folder not found at $SystemSrc - skipping"
    } else {
        if (-not (Test-Path $WorkspaceDir)) {
            New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null
            Write-OK "Created $WorkspaceDir"
        }
        # Copy all non-AGENTS files as-is
        Get-ChildItem $SystemSrc -File | Where-Object { $_.Name -notlike "AGENTS-*.md" } | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $WorkspaceDir -Force
            Write-OK "Copied $($_.Name) -> $WorkspaceDir"
        }
        # Copy the mode-specific AGENTS file as AGENTS.md
        $agentsSrc = Join-Path $SystemSrc "AGENTS-$ImageGenMode.md"
        if (Test-Path $agentsSrc) {
            Copy-Item -Path $agentsSrc -Destination (Join-Path $WorkspaceDir "AGENTS.md") -Force
            Write-OK "Copied AGENTS-$ImageGenMode.md -> $WorkspaceDir\AGENTS.md"
        } else {
            Write-Warn "AGENTS-$ImageGenMode.md not found at $agentsSrc - skipping"
        }
    }
}

# ---------------------------------------------------------------------------
# Save mode to .setup-config so start.ps1 can read it
# ---------------------------------------------------------------------------

$setupConfig = Join-Path $ScriptDir ".setup-config"
"IMAGE_GEN_MODE=$ImageGenMode" | Set-Content $setupConfig -Encoding UTF8
Write-OK "Saved mode=$ImageGenMode to .setup-config"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Run .\start.ps1 to launch openclaw"
Write-Host ""
