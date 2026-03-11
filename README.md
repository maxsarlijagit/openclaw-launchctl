# openclaw-launchctl

A verbose, production-ready startup and health-check script for self-hosted [OpenClaw](https://github.com/openclaw/openclaw) gateway deployments running via Docker Compose.

## What it does

`oc-start.sh` replaces the usual `docker compose up -d` with a full launch sequence that ensures every service is actually online before you walk away. It runs through six phases:

1. **Pre-flight checks** — verifies Docker is running, compose file exists, `.env` is present, and `openclaw.json` config is reachable.
2. **Graceful shutdown** — brings down the existing compose stack, removes orphan containers, and **kills any zombie process** still holding the gateway port (common after unclean shutdowns).
3. **Startup** — runs `docker compose up -d` and confirms both gateway and CLI containers reach `running` state.
4. **Health check** — polls the `/healthz` endpoint every 3 seconds for up to 60 seconds until the gateway reports healthy.
5. **Service verification** — parses gateway logs to confirm each subsystem:
   - WebSocket listener
   - Dashboard (Canvas UI)
   - WhatsApp channel
   - Slack socket mode
   - Agent model
   - Registered hooks
   - Browser control
6. **Summary** — prints a color-coded status table with external access URLs.

## Requirements

- Linux host (tested on AlmaLinux 9 / RHEL-family, should work on Ubuntu/Debian)
- Docker Engine with Compose v2 (`docker compose`)
- `curl`, `ss` (from iproute2), and standard GNU coreutils
- An existing OpenClaw Docker Compose setup

## Installation

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/openclaw-launchctl/main/oc-start.sh -o ~/oc-start.sh
chmod +x ~/oc-start.sh
```

Or clone the repo:

```bash
git clone https://github.com/YOUR_USER/openclaw-launchctl.git
ln -s ~/openclaw-launchctl/oc-start.sh ~/oc-start.sh
```

## Configuration

Before running, edit the variables at the top of `oc-start.sh` to match your environment:

```bash
# ── CUSTOMIZE THESE ───────────────────────────────────────────────
COMPOSE_DIR="/home/your_user/openclaw"          # Path to directory containing docker-compose.yml
GATEWAY_CONTAINER="openclaw-openclaw-gateway-1"  # Name of the gateway container (check with: docker ps)
GATEWAY_PORT=18789                               # Gateway port (must match docker-compose.yml)
MAX_WAIT=60                                      # Max seconds to wait for gateway to become healthy
CHECK_INTERVAL=3                                 # Seconds between health poll attempts
LOG_TAIL=40                                      # Number of log lines to analyze for service status
```

The script also reads your `.env` file to find the OpenClaw config directory. If your setup uses a non-standard path, make sure `OPENCLAW_CONFIG_DIR` is set in your `.env`.

## Usage

```bash
~/oc-start.sh
```

### Example output

```
═══ PRE-FLIGHT CHECKS ═══
[14:30:01] ✔  Docker found: Docker version 27.5.1
[14:30:01] ✔  Docker daemon responsive
[14:30:01] ✔  Compose file: /home/user/openclaw/docker-compose.yml
[14:30:01] ✔  .env file present
[14:30:01] ✔  OpenClaw config found

═══ STOPPING EXISTING SERVICES ═══
[14:30:02] ✔  Compose stack stopped
[14:30:02] ⚠  Killing process 1538193 (openclaw-gatewa) on port 18789...
[14:30:05] ✔  Port 18789 freed

═══ STARTING OPENCLAW ═══
[14:30:08] ✔  Gateway container: running
[14:30:08] ✔  CLI container: running

═══ HEALTH CHECK ═══
[14:30:14] ✔  Gateway healthy (HTTP 200) after 6s

═══ SERVICE VERIFICATION ═══
[14:30:14] ✔  Gateway listening: ws://0.0.0.0:18789
[14:30:14] ✔  Dashboard (Canvas): http://0.0.0.0:18789/__openclaw__/canvas/
[14:30:14] ✔  WhatsApp: connected (+XXXXXXXXXXXX)
[14:30:14] ✔  Slack: socket mode connected
[14:30:14] ✔  Agent model: openrouter/google/gemini-2.5-flash
[14:30:14] ✔  Hooks registered: 4
     ↳ boot-md
     ↳ bootstrap-extra-files
     ↳ command-logger
     ↳ session-memory

═══ ACCESS CHECK ═══
[14:30:14] ✔  Dashboard URL: http://YOUR_SERVER_IP:18789/__openclaw__/canvas/
[14:30:14] ✔  WebSocket URL: ws://YOUR_SERVER_IP:18789

═══ SUMMARY ═══

  Container          Status
  ─────────────────  ──────────
  gateway            ● running
  cli                ● running

  Service            Status
  ─────────────────  ──────────
  Health endpoint    ● online
  Dashboard          ● online
  WhatsApp           ● connected
  Slack              ● connected

  🚀 OpenClaw is fully operational
```

## How it handles port conflicts

After `docker compose down`, zombie gateway processes sometimes linger and hold the port. The script:

1. Detects any process bound to the gateway port via `ss`
2. Sends `SIGTERM` and waits 2 seconds
3. If still alive, sends `SIGKILL`
4. Verifies the port is free before proceeding
5. Aborts with a clear message if the port cannot be freed

## Typical directory layout

For reference, a standard OpenClaw Docker setup looks like this:

```
~/openclaw/                        # COMPOSE_DIR — your docker-compose.yml lives here
  ├── docker-compose.yml
  └── .env                         # Must define OPENCLAW_CONFIG_DIR and OPENCLAW_WORKSPACE_DIR

~/.openclaw/data/
  ├── config/                      # OPENCLAW_CONFIG_DIR — mounted as /home/node/.openclaw in the container
  │   ├── openclaw.json            # Main OpenClaw configuration (channels, agents, bindings, models)
  │   ├── config.json              # Minimal model config
  │   └── agents/                  # Agent definitions
  └── workspace/                   # OPENCLAW_WORKSPACE_DIR — mounted as /home/node/.openclaw/workspace
      └── ...                      # Agent workspaces and project files
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Port 18789 still in use` | Zombie process from previous run | Script handles this automatically; if it fails, try `sudo kill` |
| `EACCES: permission denied, mkdir '/home/node'` | Container can't create home dir | Add `mkdir -p /home/node/.openclaw` to your compose entrypoint |
| `Gateway did not become healthy` | Config error or missing API keys | Check `docker logs openclaw-openclaw-gateway-1 --tail 50` |
| WhatsApp shows `pending` | Auth session expired | Re-pair device via the Canvas UI |

## License

MIT
