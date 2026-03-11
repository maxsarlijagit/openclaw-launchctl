#!/bin/bash
#═══════════════════════════════════════════════════════════════════
#  OpenClaw Launch Control — oc-start.sh
#  Full startup, port cleanup, health checks & service verification
#
#  Usage:  ~/oc-start.sh
#  Repo:   https://github.com/YOUR_USER/openclaw-launchctl
#═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ── CUSTOMIZE THESE ───────────────────────────────────────────────
# COMPOSE_DIR:        Path to the directory containing your docker-compose.yml
# GATEWAY_CONTAINER:  Name of the gateway container (find it with: docker ps)
# GATEWAY_PORT:       Must match the port mapped in docker-compose.yml
# MAX_WAIT:           How long (seconds) to wait for /healthz to return 200
# CHECK_INTERVAL:     Seconds between health check attempts
# LOG_TAIL:           Number of recent log lines to scan for service status
# ──────────────────────────────────────────────────────────────────
COMPOSE_DIR="/home/almalinux/openclaw"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
GATEWAY_CONTAINER="openclaw-openclaw-gateway-1"
GATEWAY_PORT=18789
HEALTH_URL="http://127.0.0.1:${GATEWAY_PORT}/healthz"
MAX_WAIT=60
CHECK_INTERVAL=3
LOG_TAIL=40

# ── Colors (no need to change) ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────
timestamp() { date '+%H:%M:%S'; }
info()    { echo -e "${CYAN}[$(timestamp)]${NC} ${BOLD}ℹ${NC}  $1"; }
ok()      { echo -e "${GREEN}[$(timestamp)]${NC} ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "${YELLOW}[$(timestamp)]${NC} ${YELLOW}⚠${NC}  $1"; }
fail()    { echo -e "${RED}[$(timestamp)]${NC} ${RED}✘${NC}  $1"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}"; }

# ── Port cleanup ─────────────────────────────────────────────────
# Finds and kills any process holding the given port.
# Tries SIGTERM first, waits, then SIGKILL if needed.
kill_port() {
    local port=$1
    local pids
    pids=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [ -z "$pids" ]; then
        pids=$(netstat -tlnp 2>/dev/null | grep ":${port} " | grep -oP '[0-9]+(?=/)' | sort -u)
    fi
    if [ -n "$pids" ]; then
        for pid in $pids; do
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            warn "Killing process $pid ($pname) on port $port..."
            kill "$pid" 2>/dev/null || true
        done
        sleep 2
        # Force kill survivors
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                warn "Force killing $pid (SIGKILL)..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
        sleep 1
        # Final verification
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            fail "Could not free port $port — may need sudo"
            return 1
        fi
        ok "Port $port freed"
    else
        ok "Port $port is free"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
# PHASE 1: PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════
section "PRE-FLIGHT CHECKS"

if ! command -v docker &>/dev/null; then
    fail "Docker not found in PATH"
    exit 1
fi
ok "Docker found: $(docker --version | head -1)"

if ! docker info &>/dev/null; then
    fail "Docker daemon not running or no permissions"
    exit 1
fi
ok "Docker daemon responsive"

if [ ! -f "$COMPOSE_FILE" ]; then
    fail "Compose file not found: $COMPOSE_FILE"
    exit 1
fi
ok "Compose file: $COMPOSE_FILE"

if [ ! -f "$COMPOSE_DIR/.env" ]; then
    warn ".env file not found — using defaults"
else
    ok ".env file present"
fi

# Read .env to locate the OpenClaw config directory.
# Your .env should define OPENCLAW_CONFIG_DIR pointing to the directory
# that gets mounted as /home/node/.openclaw inside the container.
source "$COMPOSE_DIR/.env" 2>/dev/null || true
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/home/almalinux/.openclaw/data/config}"
if [ -f "$CONFIG_DIR/openclaw.json" ]; then
    ok "OpenClaw config: $CONFIG_DIR/openclaw.json"
else
    warn "openclaw.json not found in $CONFIG_DIR"
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 2: STOP EXISTING SERVICES & FREE PORT
# ══════════════════════════════════════════════════════════════════
section "STOPPING EXISTING SERVICES"

info "Bringing down compose stack..."
cd "$COMPOSE_DIR"
docker compose down --remove-orphans 2>/dev/null && ok "Compose stack stopped" || warn "No stack running"

# Remove any Docker containers still holding the port
BLOCKING=$(docker ps -q --filter "publish=${GATEWAY_PORT}" 2>/dev/null)
if [ -n "$BLOCKING" ]; then
    warn "Found containers blocking port $GATEWAY_PORT — stopping..."
    docker stop $BLOCKING 2>/dev/null
    docker rm $BLOCKING 2>/dev/null
    ok "Blocking containers removed"
fi

# Kill zombie processes left on the gateway port (common after unclean shutdown)
info "Checking for zombie processes on port $GATEWAY_PORT..."
if ! kill_port $GATEWAY_PORT; then
    fail "Cannot free port $GATEWAY_PORT — aborting"
    exit 1
fi

sleep 2

# ══════════════════════════════════════════════════════════════════
# PHASE 3: START CONTAINERS
# ══════════════════════════════════════════════════════════════════
section "STARTING OPENCLAW"

info "Running docker compose up -d..."
docker compose up -d 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}$line${NC}"
done

sleep 2

# Verify gateway container is running
GW_STATUS=$(docker inspect -f '{{.State.Status}}' "$GATEWAY_CONTAINER" 2>/dev/null || echo "not_found")
if [ "$GW_STATUS" = "running" ]; then
    ok "Gateway container: running"
else
    fail "Gateway container status: $GW_STATUS"
    docker logs "$GATEWAY_CONTAINER" --tail 20 2>&1
    exit 1
fi

# Verify CLI container (non-critical)
CLI_STATUS=$(docker inspect -f '{{.State.Status}}' "openclaw-openclaw-cli-1" 2>/dev/null || echo "not_found")
if [ "$CLI_STATUS" = "running" ]; then
    ok "CLI container: running"
else
    warn "CLI container status: $CLI_STATUS"
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 4: HEALTH CHECK
# ══════════════════════════════════════════════════════════════════
section "HEALTH CHECK"

info "Waiting for gateway health endpoint (max ${MAX_WAIT}s)..."
ELAPSED=0
HEALTHY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        HEALTHY=true
        break
    fi
    printf "\r  ${DIM}⏳ ${ELAPSED}s — HTTP $HTTP_CODE — waiting...${NC}"
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done
printf "\r%-60s\r" " "

if $HEALTHY; then
    ok "Gateway healthy (HTTP 200) after ${ELAPSED}s"
else
    fail "Gateway did not become healthy after ${MAX_WAIT}s (last HTTP: $HTTP_CODE)"
    docker logs "$GATEWAY_CONTAINER" --tail 30 2>&1
    exit 1
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 5: SERVICE VERIFICATION
# ══════════════════════════════════════════════════════════════════
section "SERVICE VERIFICATION"

info "Analyzing gateway logs..."
LOGS=$(docker logs "$GATEWAY_CONTAINER" --tail $LOG_TAIL 2>&1)

# WebSocket listener
if echo "$LOGS" | grep -q "listening on ws://"; then
    LISTEN_ADDR=$(echo "$LOGS" | grep "listening on ws://" | tail -1 | grep -oP 'ws://[^ ]+')
    ok "Gateway listening: $LISTEN_ADDR"
else
    fail "Gateway not listening on WebSocket"
fi

# Dashboard / Canvas UI
if echo "$LOGS" | grep -q "canvas.*host mounted"; then
    CANVAS_URL=$(echo "$LOGS" | grep "canvas.*host mounted" | grep -oP 'http://[^ ]+' | head -1)
    ok "Dashboard (Canvas): $CANVAS_URL"
else
    warn "Dashboard (Canvas) not detected in logs"
fi

# WhatsApp channel — number is masked for privacy
if echo "$LOGS" | grep -q "Listening for.*WhatsApp"; then
    WA_NUMBER=$(echo "$LOGS" | grep -oP 'starting provider \(\K[^)]+' | head -1)
    WA_MASKED=$(echo "$WA_NUMBER" | sed 's/\(+[0-9]\{4\}\).*\([0-9]\{4\}\)$/\1****\2/')
    ok "WhatsApp: connected ($WA_MASKED)"
elif echo "$LOGS" | grep -q "\[whatsapp\].*starting"; then
    warn "WhatsApp: starting (not yet confirmed listening)"
else
    fail "WhatsApp: not detected"
fi

# Slack
if echo "$LOGS" | grep -q "socket mode connected"; then
    ok "Slack: socket mode connected"
elif echo "$LOGS" | grep -q "\[slack\].*starting"; then
    warn "Slack: starting (not yet connected)"
else
    fail "Slack: not detected"
fi

# Agent model
MODEL=$(echo "$LOGS" | grep "agent model:" | tail -1 | sed 's/.*agent model: //')
if [ -n "$MODEL" ]; then
    ok "Agent model: $MODEL"
else
    warn "Agent model not detected in logs"
fi

# Hooks
HOOKS_COUNT=$(echo "$LOGS" | grep -c "Registered hook:" || true)
if [ "$HOOKS_COUNT" -gt 0 ]; then
    ok "Hooks registered: $HOOKS_COUNT"
    echo "$LOGS" | grep "Registered hook:" | while IFS= read -r line; do
        HOOK_NAME=$(echo "$line" | grep -oP 'Registered hook: \K[^ ]+')
        echo -e "     ${DIM}↳ $HOOK_NAME${NC}"
    done
else
    warn "No hooks detected"
fi

# Browser control
if echo "$LOGS" | grep -q "Browser control listening"; then
    ok "Browser control: active"
else
    warn "Browser control: not detected"
fi

# Errors in recent logs
ERROR_COUNT=$(echo "$LOGS" | grep -ciE "error|fatal|crash" || true)
if [ "$ERROR_COUNT" -gt 0 ]; then
    warn "Found $ERROR_COUNT error(s) in recent logs"
    echo "$LOGS" | grep -iE "error|fatal|crash" | tail -5 | while IFS= read -r line; do
        echo -e "     ${RED}↳ $line${NC}"
    done
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 6: ACCESS INFO & SUMMARY
# ══════════════════════════════════════════════════════════════════
section "ACCESS CHECK"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$SERVER_IP" ]; then
    ok "Dashboard URL: http://${SERVER_IP}:${GATEWAY_PORT}/__openclaw__/canvas/"
    ok "WebSocket URL: ws://${SERVER_IP}:${GATEWAY_PORT}"
else
    warn "Could not determine server IP"
fi

section "SUMMARY"

echo ""
echo -e "  ${BOLD}Container${NC}          ${BOLD}Status${NC}"
echo -e "  ─────────────────  ──────────"
echo -e "  gateway            $([ "$GW_STATUS" = "running" ] && echo "${GREEN}● running${NC}" || echo "${RED}● $GW_STATUS${NC}")"
echo -e "  cli                $([ "$CLI_STATUS" = "running" ] && echo "${GREEN}● running${NC}" || echo "${YELLOW}● $CLI_STATUS${NC}")"
echo ""
echo -e "  ${BOLD}Service${NC}            ${BOLD}Status${NC}"
echo -e "  ─────────────────  ──────────"
echo -e "  Health endpoint    $(${HEALTHY} && echo "${GREEN}● online${NC}" || echo "${RED}● offline${NC}")"

WA_OK=false; SL_OK=false; DASH_OK=false
echo "$LOGS" | grep -q "Listening for.*WhatsApp" && WA_OK=true
echo "$LOGS" | grep -q "socket mode connected" && SL_OK=true
echo "$LOGS" | grep -q "canvas.*host mounted" && DASH_OK=true

echo -e "  Dashboard          $(${DASH_OK} && echo "${GREEN}● online${NC}" || echo "${RED}● offline${NC}")"
echo -e "  WhatsApp           $(${WA_OK} && echo "${GREEN}● connected${NC}" || echo "${YELLOW}● pending${NC}")"
echo -e "  Slack              $(${SL_OK} && echo "${GREEN}● connected${NC}" || echo "${YELLOW}● pending${NC}")"
echo ""

if $HEALTHY && $WA_OK && $SL_OK && $DASH_OK; then
    echo -e "  ${GREEN}${BOLD}🚀 OpenClaw is fully operational${NC}"
else
    echo -e "  ${YELLOW}${BOLD}⚠  OpenClaw started with warnings — check details above${NC}"
fi
echo ""
