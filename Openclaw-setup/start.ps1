#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the OpenClaw gateway with DecoAI skills.

.PARAMETER NoBuild
    Skip any build steps (not applicable for npm-global openclaw, but kept for compatibility).

.PARAMETER Config
    Path to an openclaw.json config file. Defaults to ~/.openclaw/openclaw.json.
#>

param(
    [switch]$NoBuild,
    [string]$Config = ""
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
$LogFile   = Join-Path $ScriptDir "openclaw-gateway.log"

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
    Write-Warn ".env not found - using system environment"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  DecoAI OpenClaw Gateway - Start" -ForegroundColor Magenta
Write-Host "  log file: $LogFile"
if ($Config) {
    Write-Host "  config:   $Config"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Step "Preflight checks"

$openclaw = Get-Command openclaw -ErrorAction SilentlyContinue
if (-not $openclaw) {
    Write-Fail "openclaw not found in PATH - install with: npm install -g openclaw"
    exit 1
}
Write-OK "openclaw found: $($openclaw.Source)"

# Check for geniex (Qwen2.5-VL model service)
$geniex = Get-Command geniex -ErrorAction SilentlyContinue
if (-not $geniex) {
    Write-Warn "geniex not found in PATH - Qwen2.5-VL model inference will not work"
    Write-Warn "Install geniex to enable item detection in decoration images"
} else {
    Write-OK "geniex found: $($geniex.Source)"
}

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
# Start Geniex server (Qwen2.5-VL model service)
# ---------------------------------------------------------------------------

$geniexProc = $null
if ($geniex) {
    Write-Step "Starting Geniex server (Qwen2.5-VL model)"

    $geniexLogFile = Join-Path $ScriptDir "geniex-server.log"
    "" | Set-Content $geniexLogFile -Encoding UTF8

    $geniexProc = Start-Process `
        -FilePath "geniex" `
        -ArgumentList "serve --host 127.0.0.1:18181 --compute npu" `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $geniexLogFile `
        -RedirectStandardError $geniexLogFile

    Write-OK "Geniex server started (pid=$($geniexProc.Id))"
    Write-OK "Log: $geniexLogFile"
    Write-OK "Listening on http://127.0.0.1:18181"
    Start-Sleep -Seconds 2
} else {
    Write-Warn "Geniex not available - item detection will use mock data"
}

# ---------------------------------------------------------------------------
# Start openclaw gateway (foreground process, output tailed to log file)
# ---------------------------------------------------------------------------

Write-Step "Starting openclaw gateway"

"" | Set-Content $LogFile -Encoding UTF8

$runArgs = "gateway run"
foreach ($a in $configArgs) { $runArgs += " `"$a`"" }

# Build SET commands for all vars loaded from .env so cmd.exe inherits them
$envSetCmds = ($envVars.GetEnumerator() | ForEach-Object {
    "SET `"$($_.Key)=$($_.Value)`""
}) -join " && "

$proc = Start-Process `
    -FilePath "cmd.exe" `
    -ArgumentList "/c $envSetCmds && openclaw $runArgs >> `"$LogFile`" 2>&1" `
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
    $proc.Dispose()

    # Stop Geniex server if it was started
    if ($geniexProc -and -not $geniexProc.HasExited) {
        Write-Host ""
        Write-Step "Stopping Geniex server"
        taskkill /F /T /PID $geniexProc.Id 2>$null
        $geniexProc.Dispose()
        Write-OK "Geniex server stopped"
    }

    Write-Host ""
    Write-OK "Gateway stopped"
}
