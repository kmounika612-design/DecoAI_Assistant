@echo off
rem OpenClaw Gateway (v2026.7.1-2)
set "TMPDIR=C:\Users\qc_de\AppData\Local\Temp"
set "OPENCLAW_GATEWAY_PORT=18789"
set "OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service"
set "OPENCLAW_WINDOWS_TASK_NAME=OpenClaw Gateway"
set "OPENCLAW_WINDOWS_TASK_HIDDEN_LAUNCHER=1"
set "OPENCLAW_SERVICE_MARKER=openclaw"
set "OPENCLAW_SERVICE_KIND=gateway"
set "OPENCLAW_SERVICE_VERSION=2026.7.1-2"
"C:\Program Files\nodejs\node.exe" C:\Users\qc_de\AppData\Roaming\npm\node_modules\openclaw\dist\index.js gateway --port 18789
