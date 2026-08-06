<#
.SYNOPSIS
  Automates the PC-side OpenClaw setup for pairing the WhisperTelegramNode
  Android app as a Gateway node

.DESCRIPTION
  Sets Openclaw device pairing, node approval, gateway restart which are 
  needed for the communication of the device

.PARAMETER PluginPath
  Path to the openclaw-whisper-node-bridge plugin source directory.

.PARAMETER PairingTimeoutSeconds
  How long to wait for a pending node pairing request before giving up.

.PARAMETER NodeId
  Pin setup to a specific node id instead of auto-selecting. Only needed when
  more than one node is connected (a desktop node plus a phone, two phones, a
  stale session) and you want to be explicit about which one gets configured.

.PARAMETER PairNew
  Force the pairing wait even when another node is already paired and
  connected. This is how a second device gets added: without it the script
  short-circuits on the node that is already up and the new phone never
  gets approved.

.PARAMETER SkipFirewall
  Skip the Windows Firewall rule step (use if you manage firewall rules
  yourself, or already have one). Creating the rule is the only step that
  needs Administrator; without this switch the script asks for elevation
  for that one step via UAC and runs everything else as the current user.

.EXAMPLE
  .\setup-node.ps1
.EXAMPLE
  .\setup-node.ps1 -PairingTimeoutSeconds 600 -SkipFirewall
#>

[CmdletBinding()]
param(
    [string]$PluginPath,
    [int]$PairingTimeoutSeconds = 300,
    [string]$NodeId,
    [switch]$PairNew,
    [switch]$SkipFirewall
)


if (-not $PluginPath) {
    $PluginPath = Join-Path $PSScriptRoot "openclaw-whisper-node-bridge"
}


$script:PinnedNodeId = $NodeId

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


function Invoke-OpenClawText {
    param(
        [Parameter(Mandatory)][string[]]$Args
    )
    $output = & openclaw @Args 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Raw = ($output | Out-String) }
}


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

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


function New-GatewayFirewallRule {
    if (Test-IsElevated) {
        try {
            New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound `
                -Protocol TCP -LocalPort $GatewayPort -Action Allow -Profile Any | Out-Null
            return $true
        }
        catch {
            Write-Warn "Rule creation failed even though this session is elevated: $($_.Exception.Message)"
            return $false
        }
    }

    Write-Step "Not running as Administrator - requesting elevation for the firewall rule only (accept the UAC prompt)"
    $command = "`$ErrorActionPreference = 'Stop'; try { New-NetFirewallRule -DisplayName '$FirewallRuleName' -Direction Inbound -Protocol TCP -LocalPort $GatewayPort -Action Allow -Profile Any | Out-Null; exit 0 } catch { exit 1 }"
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList @(
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded)
        if ($proc.ExitCode -eq 0) {
            return $true
        }
        Write-Warn "Elevated helper exited with code $($proc.ExitCode)"
        return $false
    }
    catch {
        # Declining the UAC prompt throws here rather than returning an exit code.
        Write-Warn "Elevation was declined or unavailable: $($_.Exception.Message)"
        return $false
    }
}


function Set-NodeCommandAllowlist {
    $existing = @()
    $nodesConfig = Get-ConfigValue "gateway.nodes"
    if ($nodesConfig -and $nodesConfig.PSObject.Properties.Name -contains "commands") {
        $commandsConfig = $nodesConfig.commands
        if ($commandsConfig -and $commandsConfig.PSObject.Properties.Name -contains "allow") {
            $existing = @($commandsConfig.allow)
        }
    }

    if ($existing -contains $RequiredCommand) {
        Write-Ok "gateway.nodes.commands.allow already allows $RequiredCommand"
        return $false
    }

    $merged = @($existing + $RequiredCommand | Where-Object { $_ } | Select-Object -Unique)
    $was = if ($existing.Count) { $existing -join ", " } else { "empty" }
    Write-Step "Adding $RequiredCommand to gateway.nodes.commands.allow (was: $was)"
    Apply-ConfigPatch -PatchObject @{ gateway = @{ nodes = @{ commands = @{ allow = $merged } } } }
    return $true
}


function Get-MergedMediaModels {
    $existing = @()
    $media = Get-ConfigValue "tools.media"
    if ($media -and $media.PSObject.Properties.Name -contains "models") {
        $existing = @($media.models)
    }

    
    if ($existing | Where-Object { $_.provider -eq $PluginId }) {
        return $existing
    }
    return @($existing + @{ provider = $PluginId; capabilities = @("audio") })
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


    if (Set-NodeCommandAllowlist) {
        $needsRestart = $true
    }

    if (-not $SkipFirewall) {
        $existingRule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            Write-Step "No firewall rule found for port $GatewayPort; creating one"
            if (New-GatewayFirewallRule) {
                Write-Ok "Created inbound firewall rule '$FirewallRuleName'"
                $script:PhaseResults["Firewall rule"] = $true
            }
            else {

                Write-Warn "Could not create the firewall rule; continuing without it."
                Write-Warn "If pairing times out in Phase 2, run this once in an elevated PowerShell:"
                Write-Host "    New-NetFirewallRule -DisplayName '$FirewallRuleName' -Direction Inbound -Protocol TCP -LocalPort $GatewayPort -Action Allow -Profile Any"
                Write-Warn "then re-run this script with -SkipFirewall."
                $script:PhaseResults["Firewall rule"] = "warn"
            }
        }
        else {
            Write-Ok "Firewall rule '$FirewallRuleName' already exists"
            $script:PhaseResults["Firewall rule"] = $true
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
    $nodeRequests = $list.Json.pending | Where-Object { $_.role -eq "node" }
    if ($script:PinnedNodeId) {
        $nodeRequests = $nodeRequests | Where-Object { $_.deviceId -eq $script:PinnedNodeId }
    }
    return $nodeRequests | Select-Object -First 1
}

function Get-RequestId($PendingEntry) {

    if ($PendingEntry.PSObject.Properties.Name -contains "requestId") {
        return $PendingEntry.requestId
    }
    if ($PendingEntry.PSObject.Properties.Name -contains "id") {
        return $PendingEntry.id
    }
    Write-Fail "Could not find a request id field on pending entry:`n$($PendingEntry | ConvertTo-Json -Depth 5)"
    throw "unknown pending-entry shape"
}


function Resolve-NodeReapproval {
    param([Parameter(Mandatory)][string]$NodeId)

    $describe = Invoke-OpenClawJson -Args @("nodes", "describe", "--node", $NodeId)
    if (-not $describe.Json -or $describe.Json.approvalState -ne "pending-reapproval") {
        return $false
    }

    $requestId = $describe.Json.pendingRequestId
    if (-not $requestId) {
        Write-Warn "Node is pending re-approval but exposed no pendingRequestId"
        return $false
    }

    $declared = @($describe.Json.pendingDeclaredCommands) -join ", "
    Write-Step "Node is pending re-approval (declares: $declared); approving request $requestId"
    $approve = Invoke-OpenClawJson -Args @("nodes", "approve", $requestId)
    if ($approve.ExitCode -ne 0) {
        Write-Warn "nodes approve failed:`n$($approve.Raw)"
        return $false
    }
    Write-Ok "Re-approved the node's declared command surface"
    return $true
}


function Select-TargetNode {
    param($Nodes)

    $connected = @($Nodes | Where-Object { $_.connected -eq $true })
    if ($connected.Count -eq 0) { return $null }

    if ($script:PinnedNodeId) {
        $pinned = $connected | Where-Object { $_.nodeId -eq $script:PinnedNodeId } | Select-Object -First 1
        if ($pinned) {
            Write-Step "Using pinned node $($script:PinnedNodeId)"
            return $pinned
        }

        Write-Step "Pinned node $($script:PinnedNodeId) is not connected yet; waiting for it to pair"
        return $null
    }

    if ($connected.Count -eq 1) { return $connected[0] }


    $candidates = @($connected | Where-Object {
        $describe = Invoke-OpenClawJson -Args @("nodes", "describe", "--node", $_.nodeId)
        $describe.Json -and (
            (@($describe.Json.commands) -contains $RequiredCommand) -or
            (@($describe.Json.pendingDeclaredCommands) -contains $RequiredCommand)
        )
    })

    if ($candidates.Count -eq 1) {
        Write-Step "Selected the only node offering ${RequiredCommand}: $($candidates[0].nodeId)"
        return $candidates[0]
    }
    if ($candidates.Count -gt 1) {
        Write-Warn "Multiple connected nodes offer ${RequiredCommand}: $((@($candidates.nodeId) -join ', '))"
        Write-Warn "Using the first. Pin one explicitly with -NodeId <id>."
        return $candidates[0]
    }

    Write-Warn "No connected node offers $RequiredCommand yet. Connected: $((@($connected.nodeId) -join ', '))"
    Write-Warn "Using the first. Pin one explicitly with -NodeId <id> if that is the wrong device."
    return $connected[0]
}

function Invoke-Phase2-PairingWaitApprove {
    Write-Phase "Phase 2: Node pairing"


    $alreadyConnectedNode = $null
    if ($PairNew) {
        Write-Step "-PairNew: ignoring any already-connected node and waiting for a new pairing request"
    }
    else {
        $existingConnected = Invoke-OpenClawJson -Args @("nodes", "status")
        if ($existingConnected.Json -and $existingConnected.Json.nodes) {
            $alreadyConnectedNode = Select-TargetNode -Nodes $existingConnected.Json.nodes
        }
    }
    if ($alreadyConnectedNode) {
        # nodes status --json returns nodeId, not id (src/cli/nodes-cli/register.status.ts).
        Write-Ok "A node is already paired and connected: $($alreadyConnectedNode.nodeId)"
        # "connected" is not the same as "usable" - clear any held-back command
        # surface before treating this phase as done.
        Resolve-NodeReapproval -NodeId $alreadyConnectedNode.nodeId | Out-Null
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


    $nodeId = $pending.deviceId
    if (-not $nodeId) {
        Write-Fail "Pairing request carried no deviceId:`n$($pending | ConvertTo-Json -Depth 5)"
        $script:PhaseResults["Node paired"] = $false
        throw "unknown pending-entry shape"
    }


    Write-Step "Approving pairing request $requestId"
    $approve = Invoke-OpenClawJson -Args @("devices", "approve", $requestId)
    if ($approve.ExitCode -ne 0) {
        Write-Step "devices approve did not take it; retrying with nodes approve"
        $approve = Invoke-OpenClawJson -Args @("nodes", "approve", $requestId)
    }
    if ($approve.ExitCode -ne 0) {
        Write-Fail "Approval failed:`n$($approve.Raw)"
        $script:PhaseResults["Node paired"] = $false
        throw "approve failed"
    }
    Write-Ok "Approved"
    $script:PhaseResults["Node paired"] = $true

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


    $pluginsList = Invoke-OpenClawJson -Args @("plugins", "list", "--verbose")
    $installedEntry = $null
    if ($pluginsList.Json -and $pluginsList.Json.plugins) {

        $installedEntry = $pluginsList.Json.plugins | Where-Object {
            ($_.id -eq $PluginId) -or ($_.name -eq $PluginId)
        } | Select-Object -First 1
    }

    if (-not $installedEntry) {
        Write-Step "Installing plugin from $PluginPath"

        $install = Invoke-OpenClawText -Args @("plugins", "install", "-l", $PluginPath)
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
                models = @(Get-MergedMediaModels)
                audio  = @{
                    enabled        = $true
                    timeoutSeconds = 120
                }
            }
        }
    }

    Set-NodeCommandAllowlist | Out-Null

    Write-Step "Writing plugin config patch (plugin nodeId, media provider)"
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


    $declaresCommand = $false
    $lastDescribe = $null
    for ($i = 0; $i -lt 10; $i++) {
        $describe = Invoke-OpenClawJson -Args @("nodes", "describe", "--node", $NodeId)
        $lastDescribe = $describe.Json
        if ($lastDescribe -and (@($lastDescribe.commands) -contains $RequiredCommand)) {
            $declaresCommand = $true
            break
        }
        if ($lastDescribe -and $lastDescribe.approvalState -eq "pending-reapproval") {
            Resolve-NodeReapproval -NodeId $NodeId | Out-Null
        }
        Start-Sleep -Seconds 2
    }

    if ($declaresCommand) {
        Write-Ok "Node declares $RequiredCommand (approvalState: $($lastDescribe.approvalState))"
    }
    else {
        Write-Fail "Node does not declare $RequiredCommand - dispatch will fail with 'node did not declare commands'"
        if ($lastDescribe) {
            Write-Warn "  approvalState : $($lastDescribe.approvalState)"
            Write-Warn "  commands      : $((@($lastDescribe.commands) -join ', '))"
            if ($lastDescribe.pendingDeclaredCommands) {
                Write-Warn "  pending       : $((@($lastDescribe.pendingDeclaredCommands) -join ', '))"
                Write-Warn "Approve it with: openclaw nodes approve $($lastDescribe.pendingRequestId)"
            }
            else {
                Write-Warn "The app advertised no commands on connect - check the node app build."
                Write-Warn "Watch the connect frame with: adb logcat -s GatewayNodeClient:*"
            }
        }
    }
    $script:PhaseResults["Node declares $RequiredCommand"] = $declaresCommand

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
    $doctorErrors = @()
    $doctorWarnings = @()
    if ($doctor.Json -and $doctor.Json.findings) {
        $doctorErrors = @($doctor.Json.findings | Where-Object { $_.severity -eq "error" })
        $doctorWarnings = @($doctor.Json.findings | Where-Object { $_.severity -eq "warning" })
    }

    foreach ($finding in ($doctorErrors + $doctorWarnings)) {
        Write-Host "    [$($finding.severity)] $($finding.checkId): $($finding.message)"
    }

    if ($doctorErrors.Count -gt 0) {
        Write-Fail "doctor --lint reported $($doctorErrors.Count) error finding(s)"
        $script:PhaseResults["Doctor clean"] = $false
    }
    elseif ($doctorWarnings.Count -gt 0) {
        Write-Warn "doctor --lint: $($doctorWarnings.Count) warning(s), no errors - review them, they do not block setup"
        $script:PhaseResults["Doctor clean"] = "warn"
    }
    else {
        Write-Ok "doctor --lint: no findings"
        $script:PhaseResults["Doctor clean"] = $true
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Write-Summary {

    param([switch]$Aborted)

    Write-Host ""
    Write-Host "== Summary ==" -ForegroundColor Cyan
    $allPass = $true
    foreach ($key in $script:PhaseResults.Keys) {
        $value = $script:PhaseResults[$key]

        if ($value -is [string] -and $value -eq "warn") {
            Write-Host ("  [WARN] {0}" -f $key) -ForegroundColor Yellow
        }
        elseif ($value) {
            Write-Host ("  [PASS] {0}" -f $key) -ForegroundColor Green
        }
        else {
            Write-Host ("  [FAIL] {0}" -f $key) -ForegroundColor Red
            $allPass = $false
        }
    }
    Write-Host ""
    if ($Aborted) {
        Write-Host "Setup did not finish - the checks above are only the phases that ran." -ForegroundColor Red
        return $false
    }
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
    Write-Summary -Aborted | Out-Null
    exit 1
}
