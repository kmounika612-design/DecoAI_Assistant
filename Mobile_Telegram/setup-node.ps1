<#
.SYNOPSIS
  Automates the PC-side OpenClaw setup for pairing the WhisperTelegramNode
  Android app as a Gateway node: LAN bind + firewall, pairing wait/approve,
  whisper-node-bridge plugin install/config, and a final verification pass.

.DESCRIPTION
  Mirrors README.md steps 2-3. Building/installing the Android app and
  pushing NPU model files to the device stay manual (one-time, hardware-
  specific steps) - this script only automates the PC/gateway side, which
  is what actually breaks in repeatable, scriptable ways (missed restarts,
  firewall rules, stale device ids, config key placement).

  Idempotent: every phase reads current state via `--json` before mutating,
  so re-running after a partial failure or a phone reinstall is safe.

.PARAMETER PluginPath
  Path to the openclaw-whisper-node-bridge plugin source directory.

.PARAMETER PairingTimeoutSeconds
  How long to wait for a pending node pairing request before giving up.

.PARAMETER SkipFirewall
  Skip the Windows Firewall rule step (use if you manage firewall rules
  yourself, or already have one).

.EXAMPLE
  .\setup-node.ps1
.EXAMPLE
  .\setup-node.ps1 -PairingTimeoutSeconds 600 -SkipFirewall
#>

[CmdletBinding()]
param(
    [string]$PluginPath = (Join-Path $PSScriptRoot "openclaw-whisper-node-bridge"),
    [int]$PairingTimeoutSeconds = 300,
    [switch]$SkipFirewall
)

$ErrorActionPreference = "Stop"
$GatewayPort = 18789
$FirewallRuleName = "OpenClaw Gateway $GatewayPort"
$RequiredCommand = "whisper.transcribe"
$PluginId = "whisper-node-bridge"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Phase([string]$Text) {
    Write-Host ""
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host "  - $Text"
}

function Write-Ok([string]$Text) {
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Write-Host "  [WARN] $Text" -ForegroundColor Yellow
}

function Write-Fail([string]$Text) {
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
}

# Runs `openclaw <args> --json` and parses stdout as JSON. openclaw's CLI
# banner is suppressed whenever --json is present (src/cli/banner.ts:121),
# so stdout should be clean JSON with no decorative preamble to strip.
function Invoke-OpenClawJson {
    param(
        [Parameter(Mandatory)][string[]]$Args
    )
    $output = & openclaw @Args --json 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if (-not $text) {
        return [pscustomobject]@{ ExitCode = $exitCode; Json = $null; Raw = $text }
    }
    try {
        $json = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ ExitCode = $exitCode; Json = $null; Raw = $text }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; Raw = $text }
}

# Runs `openclaw <args>` without --json, for commands with no JSON mode
# (plugins install/enable). Returns exit code + combined output text.
function Invoke-OpenClawText {
    param(
        [Parameter(Mandatory)][string[]]$Args
    )
    $output = & openclaw @Args 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Raw = ($output | Out-String) }
}

# Writes a JSON5-compatible patch file and applies it via `config patch
# --file`, which reads from disk - this is what avoids PowerShell's
# double-quote mangling on every inline --strict-json call we hit manually
# earlier this session.
function Apply-ConfigPatch {
    param(
        [Parameter(Mandatory)]$PatchObject
    )
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json5"
    try {
        ($PatchObject | ConvertTo-Json -Depth 10) | Set-Content -Path $tempFile -Encoding utf8
        $result = Invoke-OpenClawText -Args @("config", "patch", "--file", $tempFile)
        if ($result.ExitCode -ne 0) {
            Write-Fail "config patch failed:`n$($result.Raw)"
            throw "config patch failed"
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

function Get-ConfigValue([string]$Path) {
    $result = Invoke-OpenClawJson -Args @("config", "get", $Path)
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return $result.Json
}

$script:PhaseResults = [ordered]@{}

# ---------------------------------------------------------------------------
# Phase 1 - Gateway connectivity
# ---------------------------------------------------------------------------

function Invoke-Phase1-GatewayConnectivity {
    Write-Phase "Phase 1: Gateway connectivity"

    $status = Invoke-OpenClawJson -Args @("gateway", "status")
    if (-not $status.Json -or -not $status.Json.rpc.ok) {
        Write-Fail "Gateway is not running or not reachable. Start it first: openclaw gateway restart"
        $script:PhaseResults["Gateway running"] = $false
        throw "gateway not running"
    }
    Write-Ok "Gateway is running and reachable"
    $script:PhaseResults["Gateway running"] = $true

    $bind = Get-ConfigValue "gateway.bind"
    $needsRestart = $false
    if ($bind -ne "lan") {
        Write-Step "gateway.bind is '$bind', setting to 'lan'"
        Apply-ConfigPatch -PatchObject @{ gateway = @{ bind = "lan" } }
        $needsRestart = $true
    }
    else {
        Write-Ok "gateway.bind is already 'lan'"
    }

    if (-not $SkipFirewall) {
        $existingRule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            Write-Step "No firewall rule found for port $GatewayPort; creating one"
            New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound `
                -Protocol TCP -LocalPort $GatewayPort -Action Allow -Profile Any | Out-Null
            Write-Ok "Created inbound firewall rule '$FirewallRuleName'"
        }
        else {
            Write-Ok "Firewall rule '$FirewallRuleName' already exists"
        }
    }
    else {
        Write-Warn "Skipping firewall check (-SkipFirewall)"
    }

    if ($needsRestart) {
        Write-Step "Restarting gateway to apply gateway.bind change"
        Invoke-OpenClawText -Args @("gateway", "restart") | Out-Null
    }

    # Poll until 0.0.0.0:<port> is actually listening - config saying "lan"
    # is not proof the running process picked it up yet.
    $listening = $false
    for ($i = 0; $i -lt 15; $i++) {
        $status = Invoke-OpenClawJson -Args @("gateway", "status", "--deep")
        $listeners = $status.Json.port.listeners
        if ($listeners) {
            foreach ($listener in $listeners) {
                if ($listener.address -like "0.0.0.0:*") {
                    $listening = $true
                    break
                }
            }
        }
        if ($listening) { break }
        Start-Sleep -Seconds 2
    }

    if (-not $listening) {
        Write-Fail "Gateway is not listening on 0.0.0.0:$GatewayPort after restart"
        $script:PhaseResults["Gateway LAN-listening"] = $false
        throw "gateway not listening on LAN"
    }
    Write-Ok "Gateway is listening on 0.0.0.0:$GatewayPort"
    $script:PhaseResults["Gateway LAN-listening"] = $true

    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1 -ExpandProperty IPAddress)
    if ($lanIp) {
        Write-Host ""
        Write-Host "  On the phone app, enter:" -ForegroundColor Magenta
        Write-Host "    Host: $lanIp" -ForegroundColor Magenta
        Write-Host "    Port: $GatewayPort" -ForegroundColor Magenta
    }
    else {
        Write-Warn "Could not detect a LAN IPv4 address automatically; check 'ipconfig' manually"
    }
}

# ---------------------------------------------------------------------------
# Phase 2 - Pairing wait + approve
# ---------------------------------------------------------------------------

function Get-PendingNodeRequest {
    $list = Invoke-OpenClawJson -Args @("devices", "list")
    if (-not $list.Json -or -not $list.Json.pending) {
        return $null
    }
    return $list.Json.pending | Where-Object { $_.role -eq "node" } | Select-Object -First 1
}

function Get-RequestId($PendingEntry) {
    # Defensive: confirmed field name is requestId, but fail loudly instead
    # of silently picking the wrong one if a future version renames it.
    if ($PendingEntry.PSObject.Properties.Name -contains "requestId") {
        return $PendingEntry.requestId
    }
    if ($PendingEntry.PSObject.Properties.Name -contains "id") {
        return $PendingEntry.id
    }
    Write-Fail "Could not find a request id field on pending entry:`n$($PendingEntry | ConvertTo-Json -Depth 5)"
    throw "unknown pending-entry shape"
}

function Invoke-Phase2-PairingWaitApprove {
    Write-Phase "Phase 2: Node pairing"

    # Already paired and connected from a prior run? Skip straight through.
    $existingConnected = Invoke-OpenClawJson -Args @("nodes", "status")
    $alreadyConnectedNode = $null
    if ($existingConnected.Json -and $existingConnected.Json.nodes) {
        $alreadyConnectedNode = $existingConnected.Json.nodes | Where-Object { $_.connected -eq $true } | Select-Object -First 1
    }
    if ($alreadyConnectedNode) {
        # nodes status --json returns nodeId, not id (src/cli/nodes-cli/register.status.ts).
        Write-Ok "A node is already paired and connected: $($alreadyConnectedNode.nodeId)"
        $script:PhaseResults["Node paired"] = $true
        $script:PhaseResults["Node connected"] = $true
        return $alreadyConnectedNode.nodeId
    }

    Write-Host ""
    Write-Host "  On the phone: open the Whisper Node app and tap 'Start node'." -ForegroundColor Magenta
    Write-Host "  Waiting up to $PairingTimeoutSeconds seconds for a pairing request..." -ForegroundColor Magenta

    $pending = $null
    $elapsed = 0
    $pollIntervalSeconds = 3
    while ($elapsed -lt $PairingTimeoutSeconds) {
        $pending = Get-PendingNodeRequest
        if ($pending) { break }
        Start-Sleep -Seconds $pollIntervalSeconds
        $elapsed += $pollIntervalSeconds
        Write-Host "  ... waiting ($elapsed/$PairingTimeoutSeconds s)" -NoNewline
        Write-Host "`r" -NoNewline
    }
    Write-Host ""

    if (-not $pending) {
        Write-Fail "No pending node pairing request appeared within $PairingTimeoutSeconds seconds."
        Write-Warn "Check on the phone: adb logcat -s GatewayNodeClient:*"
        Write-Warn "  - 'ETIMEDOUT' means the phone can't reach the gateway (recheck Phase 1 / same network)."
        Write-Warn "  - No output at all means the app never attempted to connect."
        $script:PhaseResults["Node paired"] = $false
        throw "pairing timed out"
    }

    $requestId = Get-RequestId $pending
    Write-Step "Approving pairing request $requestId"
    $approve = Invoke-OpenClawJson -Args @("devices", "approve", $requestId)
    if ($approve.ExitCode -ne 0) {
        Write-Fail "Approval failed:`n$($approve.Raw)"
        $script:PhaseResults["Node paired"] = $false
        throw "approve failed"
    }
    Write-Ok "Approved"
    $script:PhaseResults["Node paired"] = $true

    $nodeId = $pending.deviceId
    $connected = $false
    for ($i = 0; $i -lt 10; $i++) {
        $describe = Invoke-OpenClawJson -Args @("nodes", "describe", "--node", $nodeId)
        if ($describe.Json -and $describe.Json.connected -eq $true) {
            $connected = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $connected) {
        Write-Warn "Node approved but not yet showing connected - it may still be finishing its handshake."
    }
    else {
        Write-Ok "Node is connected: $nodeId"
    }
    $script:PhaseResults["Node connected"] = $connected

    return $nodeId
}

# ---------------------------------------------------------------------------
# Phase 3 - Plugin install + config
# ---------------------------------------------------------------------------

function Invoke-Phase3-PluginInstallConfig {
    param([Parameter(Mandatory)][string]$NodeId)

    Write-Phase "Phase 3: Plugin install + configuration"

    if (-not (Test-Path $PluginPath)) {
        Write-Fail "Plugin path not found: $PluginPath"
        $script:PhaseResults["Plugin installed"] = $false
        throw "plugin path missing"
    }

    $pluginsList = Invoke-OpenClawJson -Args @("plugins", "list", "--enabled", "--verbose")
    $installedEntry = $null
    if ($pluginsList.Json -and $pluginsList.Json.plugins) {
        # plugins list --json wraps the array as { plugins: [PluginRecord, ...] }
        # (src/cli/plugins-list-command.ts) - unwrap before filtering.
        $installedEntry = $pluginsList.Json.plugins | Where-Object {
            ($_.id -eq $PluginId) -or ($_.name -eq $PluginId)
        } | Select-Object -First 1
    }

    if (-not $installedEntry) {
        Write-Step "Installing plugin from $PluginPath"
        $install = Invoke-OpenClawText -Args @("plugins", "install", "-l", $PluginPath, "--force")
        if ($install.ExitCode -ne 0) {
            Write-Fail "Plugin install failed:`n$($install.Raw)"
            $script:PhaseResults["Plugin installed"] = $false
            throw "plugin install failed"
        }
        Write-Ok "Plugin installed"
    }
    else {
        Write-Ok "Plugin already installed"
        $enableResult = Invoke-OpenClawText -Args @("plugins", "enable", $PluginId)
        if ($enableResult.ExitCode -eq 0) {
            Write-Ok "Plugin enabled"
        }
    }
    $script:PhaseResults["Plugin installed"] = $true

    # Detect old (allowCommands) vs new (commands.allow) node-command-allow
    # key shape before writing - README.md/TESTING.md both call out this
    # exact version-drift trap.
    $nodesConfig = Get-ConfigValue "gateway.nodes"
    $useLegacyShape = $false
    if ($nodesConfig -and ($nodesConfig.PSObject.Properties.Name -contains "allowCommands" -or
                           $nodesConfig.PSObject.Properties.Name -contains "denyCommands")) {
        $useLegacyShape = $true
    }

    $patch = [ordered]@{
        plugins = @{
            entries = @{
                "whisper-node-bridge" = @{
                    config = @{
                        nodeId    = $NodeId
                        timeoutMs = 120000
                    }
                }
            }
        }
        tools = @{
            media = @{
                models = @(
                    @{ provider = "whisper-node-bridge"; capabilities = @("audio") }
                )
                audio  = @{
                    enabled        = $true
                    timeoutSeconds = 120
                }
            }
        }
    }

    if ($useLegacyShape) {
        Write-Step "Detected legacy gateway.nodes.allowCommands shape"
        $patch.gateway = @{ nodes = @{ allowCommands = @($RequiredCommand) } }
    }
    else {
        Write-Step "Using gateway.nodes.commands.allow shape"
        $patch.gateway = @{ nodes = @{ commands = @{ allow = @($RequiredCommand) } } }
    }

    Write-Step "Writing combined config patch (plugin config, command allowlist, media provider)"
    Apply-ConfigPatch -PatchObject $patch

    Write-Step "Restarting gateway to apply plugin/config changes"
    Invoke-OpenClawText -Args @("gateway", "restart") | Out-Null
    Start-Sleep -Seconds 5
}

# ---------------------------------------------------------------------------
# Phase 4 - Verification
# ---------------------------------------------------------------------------

function Invoke-Phase4-Verification {
    param([Parameter(Mandatory)][string]$NodeId)

    Write-Phase "Phase 4: Verification"

    $connected = $false
    for ($i = 0; $i -lt 10; $i++) {
        $describe = Invoke-OpenClawJson -Args @("nodes", "describe", "--node", $NodeId)
        if ($describe.Json -and $describe.Json.connected -eq $true) {
            $connected = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if ($connected) { Write-Ok "Node still connected after restart" }
    else { Write-Fail "Node not connected after restart" }
    $script:PhaseResults["Node connected (post-restart)"] = $connected

    $providers = Invoke-OpenClawJson -Args @("capability", "audio", "providers")
    $providerEntry = $null
    if ($providers.Json) {
        $providerEntry = $providers.Json | Where-Object { $_.id -eq $PluginId } | Select-Object -First 1
    }
    $providerOk = ($providerEntry -and $providerEntry.available -and $providerEntry.configured)
    if ($providerOk) { Write-Ok "whisper-node-bridge is available and configured" }
    else { Write-Fail "whisper-node-bridge is not available/configured (see 'openclaw capability audio providers')" }
    $script:PhaseResults["Plugin available+configured"] = [bool]$providerOk

    $ffmpegOk = $false
    try {
        & ffmpeg -version *> $null
        $ffmpegOk = ($LASTEXITCODE -eq 0)
    }
    catch {
        $ffmpegOk = $false
    }
    if ($ffmpegOk) { Write-Ok "ffmpeg is on PATH" }
    else { Write-Fail "ffmpeg not found on PATH (required by whisper-node-bridge)" }
    $script:PhaseResults["ffmpeg present"] = $ffmpegOk

    $doctor = Invoke-OpenClawJson -Args @("doctor", "--lint")
    $doctorFindings = @()
    if ($doctor.Json -and $doctor.Json.findings) {
        $doctorFindings = $doctor.Json.findings | Where-Object { $_.severity -in @("warning", "error") }
    }
    if ($doctorFindings.Count -eq 0) {
        Write-Ok "doctor --lint: no warning/error findings"
    }
    else {
        Write-Warn "doctor --lint findings:"
        foreach ($finding in $doctorFindings) {
            Write-Host "    [$($finding.severity)] $($finding.checkId): $($finding.message)"
        }
    }
    $script:PhaseResults["Doctor clean"] = ($doctorFindings.Count -eq 0)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Write-Summary {
    Write-Host ""
    Write-Host "== Summary ==" -ForegroundColor Cyan
    $allPass = $true
    foreach ($key in $script:PhaseResults.Keys) {
        $value = $script:PhaseResults[$key]
        if ($value) {
            Write-Host ("  [PASS] {0}" -f $key) -ForegroundColor Green
        }
        else {
            Write-Host ("  [FAIL] {0}" -f $key) -ForegroundColor Red
            $allPass = $false
        }
    }
    Write-Host ""
    if ($allPass) {
        Write-Host "All checks passed. Send a Telegram voice note to test end to end." -ForegroundColor Green
    }
    else {
        Write-Host "Some checks failed - see details above." -ForegroundColor Red
    }
    return $allPass
}

try {
    Invoke-Phase1-GatewayConnectivity
    $nodeId = Invoke-Phase2-PairingWaitApprove
    Invoke-Phase3-PluginInstallConfig -NodeId $nodeId
    Invoke-Phase4-Verification -NodeId $nodeId
    $allPass = Write-Summary
    if (-not $allPass) {
        exit 1
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Fail "Setup stopped: $($_.Exception.Message)"
    Write-Summary | Out-Null
    exit 1
}
