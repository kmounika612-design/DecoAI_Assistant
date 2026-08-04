#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the openclaw gateway from oc-repo.

.PARAMETER NoBuild
    Skip the build step and use the existing dist/ output.

.PARAMETER Config
    Path to an openclaw.json config file. Defaults to ~/.openclaw/openclaw.json.

.PARAMETER ImageGenMode
    Set to "hybrid" to start the image-gen-hybrid session server before the gateway.
    Defaults to "cloud" (no session server).
#>

param(
    [switch]$NoBuild,
    [string]$Config = "",
    [ValidateSet("hybrid", "cloud")]
    [string]$ImageGenMode = "cloud"
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

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$OcRepo      = Join-Path $ScriptDir "oc-repo"
$LogFile     = Join-Path $ScriptDir "openclaw-gateway.log"

# ---------------------------------------------------------------------------
# Load .env into process environment
# ---------------------------------------------------------------------------

$EnvFile = Join-Path $ScriptDir ".env"
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
    Write-Warn ".env not found - secrets may be missing. Copy .env.example to .env and fill in values."
}

# Read mode from .setup-config written by setup.ps1 (overridden by -ImageGenMode if passed)
$setupConfig = Join-Path $ScriptDir ".setup-config"
if ($ImageGenMode -eq "cloud" -and (Test-Path $setupConfig)) {
    Get-Content $setupConfig | ForEach-Object {
        $parts = $_ -split "=", 2
        if ($parts.Count -eq 2 -and $parts[0].Trim() -eq "IMAGE_GEN_MODE") {
            $ImageGenMode = $parts[1].Trim()
        }
    }
    Write-OK "ImageGenMode from .setup-config: $ImageGenMode"
}

# Ensure xurl is on the process PATH for this session and persisted to user PATH
$XurlDir = Join-Path $ScriptDir "xurl"
if (Test-Path $XurlDir) {
    if ($env:PATH -notlike "*$XurlDir*") {
        $env:PATH = "$XurlDir;$env:PATH"
    }
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$XurlDir*") {
        [System.Environment]::SetEnvironmentVariable("PATH", "$XurlDir;$userPath", "User")
        Write-OK "Added xurl to user PATH: $XurlDir"
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  OpenClaw Twitter Demo - Start" -ForegroundColor Magenta
Write-Host "  oc-repo:    $OcRepo"
Write-Host "  log file:   $LogFile"
if ($Config) {
    Write-Host "  config:     $Config"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Step "Preflight checks"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warn "node not found - only needed for oc-repo build step"
}
else {
    Write-OK "node $(node --version)"
}

if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Fail "pnpm not found - run setup.ps1 first"
    exit 1
}
Write-OK "pnpm $(pnpm --version)"

if (-not (Test-Path $OcRepo)) {
    Write-Fail "oc-repo not found at $OcRepo"
    exit 1
}
Write-OK "oc-repo found"

# ---------------------------------------------------------------------------
# Optional build
# ---------------------------------------------------------------------------

if (-not $NoBuild) {
    Write-Step "Checking if build is needed"

    $DistDir  = Join-Path $OcRepo "dist"
    $distMtime = if (Test-Path $DistDir) {
        (Get-ChildItem $DistDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property LastWriteTime -Maximum).Maximum
    } else { $null }

    $srcChanged = if ($distMtime) {
        Get-ChildItem "$OcRepo\src","$OcRepo\ui\src" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $distMtime } |
            Select-Object -First 1
    } else { $true }

    if ($srcChanged) {
        Write-Step "Building (source changed)"
        Push-Location $OcRepo
        try {
            Write-Host "    Running pnpm build ..."
            pnpm build
            Write-Host "    Running pnpm ui:build ..."
            pnpm ui:build
            Write-OK "build complete"
        } catch {
            Write-Fail "Build failed: $_ - cannot start gateway with a broken dist"
            exit 1
        } finally {
            Pop-Location
        }
    } else {
        Write-OK "dist is up to date - skipping build"
    }
} else {
    Write-OK "Skipping build (-NoBuild)"
}

# ---------------------------------------------------------------------------
# Resolve config args
# ---------------------------------------------------------------------------

$configArgs = @()
if ($Config) {
    if (-not (Test-Path $Config)) {
        Write-Fail "Config file not found: $Config"
        exit 1
    }
    $configArgs = @("--config", $Config)
    Write-OK "Using config: $Config"
} else {
    $defaultConfig = "$env:USERPROFILE\.openclaw\openclaw.json"
    if (Test-Path $defaultConfig) {
        Write-OK "Using default config: $defaultConfig"
    } else {
        Write-Warn "No openclaw.json found at $defaultConfig - openclaw will use defaults"
    }
}

# ---------------------------------------------------------------------------
# Read gateway connection details from config
# ---------------------------------------------------------------------------

$gatewayPort  = 18789
$gatewayToken = ""

$cfgPath = if ($Config) { $Config } else { "$env:USERPROFILE\.openclaw\openclaw.json" }
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.gateway.port)       { $gatewayPort  = $cfg.gateway.port }
        if ($cfg.gateway.auth.token) { $gatewayToken = $cfg.gateway.auth.token }
    } catch {
        Write-Warn "Could not read gateway config - using defaults"
    }
}

Write-OK "Gateway config: port=$gatewayPort"

# ---------------------------------------------------------------------------
# Start image-gen-hybrid session server (hybrid mode only)
# ---------------------------------------------------------------------------

$imageGenProc = $null
if ($ImageGenMode -eq "hybrid") {
    Write-Step "Starting image-gen-hybrid session server"
    $imageGenDir = Join-Path $ScriptDir "image-gen-hybrid"
    $imageGenLog = Join-Path $ScriptDir "image-gen-hybrid.log"
    "" | Set-Content $imageGenLog -Encoding UTF8

    if (-not (Test-Path $imageGenDir)) {
        Write-Fail "image-gen-hybrid not found at $imageGenDir"
        exit 1
    }

    $imageGenProc = Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList "/c python session_server.py >> `"$imageGenLog`" 2>&1" `
        -WorkingDirectory $imageGenDir `
        -NoNewWindow `
        -PassThru

    Write-OK "Session server started (pid=$($imageGenProc.Id))"
    Write-OK "Log: $imageGenLog"
    Start-Sleep -Seconds 2
    if ($imageGenProc.HasExited) {
        Write-Fail "Session server exited unexpectedly - check $imageGenLog"
        exit 1
    }
    Write-OK "Session server running"
}

# ---------------------------------------------------------------------------
# Start openclaw gateway (foreground process, output tailed to log file)
# ---------------------------------------------------------------------------

Write-Step "Starting openclaw gateway"

"" | Set-Content $LogFile -Encoding UTF8

$runArgs = "openclaw gateway run"
foreach ($a in $configArgs) { $runArgs += " $a" }

# Build SET commands for all vars loaded from .env so cmd.exe inherits them
$envSetCmds = ($envVars.GetEnumerator() | ForEach-Object {
    "SET `"$($_.Key)=$($_.Value)`""
}) -join " && "

$proc = Start-Process `
    -FilePath "cmd.exe" `
    -ArgumentList "/c $envSetCmds && pnpm $runArgs >> `"$LogFile`" 2>&1" `
    -WorkingDirectory $OcRepo `
    -NoNewWindow `
    -PassThru

Write-OK "Gateway started (pid=$($proc.Id))"
Write-OK "Log: $LogFile"

# Wait for the gateway HTTP port to accept connections (up to 30 seconds)
Write-Host "    Waiting for gateway to be ready on port $gatewayPort ..." -ForegroundColor DarkGray
$gatewayReady = $false
$deadline     = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Write-Fail "Gateway process exited before becoming ready (code=$($proc.ExitCode))"
        Write-Warn "Check log: $LogFile"
        exit 1
    }
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$gatewayPort" `
            -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        $gatewayReady = $true
        break
    } catch {
        # Any response (even 4xx/5xx) means the port is open and gateway is up
        if ($_.Exception.Response -ne $null) {
            $gatewayReady = $true
            break
        }
    }
    Start-Sleep -Milliseconds 500
}

if (-not $gatewayReady) {
    Write-Warn "Gateway did not respond on port $gatewayPort within 30 seconds - continuing anyway"
    Write-Warn "Check log: $LogFile"
} else {
    Write-OK "Gateway ready on port $gatewayPort"
}

# ---------------------------------------------------------------------------
# Tail log to console - Ctrl+C stops the gateway
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Gateway running (pid=$($proc.Id)). Press Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "  Tailing $LogFile" -ForegroundColor DarkGray
Write-Host ""

# $approveJob = Start-Job -ScriptBlock {
#     param($ocRepo)
#     while ($true) {
#         Start-Sleep -Seconds 2
#         try {
#             $json = & cmd.exe /c "cd `"$ocRepo`" && pnpm openclaw devices list --json 2>nul" |
#                 Where-Object { $_ -notmatch "^>" -and $_ -notmatch "^$" } |
#                 Out-String
#             if ($json) {
#                 $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
#                 if ($data -and $data.pending) {
#                     foreach ($req in $data.pending) {
#                         if ($req.clientId -eq "openclaw-control-ui") {
#                             & cmd.exe /c "cd `"$ocRepo`" && pnpm openclaw devices approve `"$($req.requestId)`" 2>nul" | Out-Null
#                         }
#                     }
#                 }
#             }
#         } catch { }
#     }
# } -ArgumentList $OcRepo

try {
    Get-Content $LogFile -Wait -Encoding UTF8 | ForEach-Object {
        Write-Host "  $_"
        if ($proc.HasExited) {
            Write-Warn "Gateway process exited (code=$($proc.ExitCode))"
            break
        }
    }
} finally {
    if (-not $proc.HasExited) {
        taskkill /F /T /PID $proc.Id 2>$null
    }
    if ($imageGenProc -and -not $imageGenProc.HasExited) {
        taskkill /F /T /PID $imageGenProc.Id 2>$null
        Write-OK "Session server stopped"
    }
    Stop-Job  $approveJob  -ErrorAction SilentlyContinue
    Remove-Job $approveJob -ErrorAction SilentlyContinue
    $proc.Dispose()
    Write-Host ""
    Write-OK "Gateway stopped"
}
