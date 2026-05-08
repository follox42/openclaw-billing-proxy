#!/bin/sh
# entrypoint.sh — wait for Claude credentials, then start proxy.
#
# proxy.js exits(1) if credentials are missing at boot, so we idle here
# until /root/.claude/.credentials.json is present.
#
# During idle we run a minimal HTTP health stub so the docker-compose
# healthcheck (GET /health) passes and Docker doesn't mark the container
# unhealthy + restart it before the operator has a chance to run
# `claude auth login`.
#
# First boot UX:
#   1. Container starts, this script runs the health stub on PROXY_PORT
#   2. Operator runs: docker exec -it claude-bypass claude auth login
#   3. Credentials land in volume, this script kills the stub, exec proxy.js
#
# Subsequent boots: creds already in volume, proxy starts immediately.
#
# Token refresh (added 2026-05-08):
#   Claude Code OAuth tokens have a ~24h TTL. The proxy reads the file
#   fresh on each request but doesn't refresh it. If the proxy is idle
#   for >24h, requests start returning 401. To avoid this we spawn a
#   background loop that runs `claude -p "ping" --max-turns 1
#   --no-session-persistence` every REFRESH_INTERVAL_HOURS (default 12).
#   Set REFRESH_INTERVAL_HOURS=0 to disable.

set -u

CREDS_FILE="${CREDS_FILE:-/root/.claude/.credentials.json}"
OAUTH_TOKEN="${OAUTH_TOKEN:-}"
PROXY_PORT="${PROXY_PORT:-18801}"
REFRESH_INTERVAL_HOURS="${REFRESH_INTERVAL_HOURS:-12}"

# Background daily token refresh — keeps the OAuth token from expiring.
# Skipped if REFRESH_INTERVAL_HOURS=0 or if OAUTH_TOKEN env var is set
# (that path bypasses the file-based credential entirely).
start_refresh_loop() {
  if [ -n "$OAUTH_TOKEN" ] || [ "$REFRESH_INTERVAL_HOURS" = "0" ]; then
    echo "[REFRESH] Disabled (OAUTH_TOKEN set or REFRESH_INTERVAL_HOURS=0)"
    return
  fi
  sleep_seconds=$((REFRESH_INTERVAL_HOURS * 3600))
  echo "[REFRESH] Token refresh loop armed (every ${REFRESH_INTERVAL_HOURS}h)"
  (
    while true; do
      sleep "$sleep_seconds"
      echo "[REFRESH] Pinging Claude to refresh OAuth token..."
      if claude -p "ping" --max-turns 1 --no-session-persistence >/dev/null 2>&1; then
        echo "[REFRESH] OK — token refreshed"
      else
        echo "[REFRESH] WARN — claude ping failed, token may be stale"
      fi
    done
  ) &
}

# OAUTH_TOKEN env var bypasses the file check entirely
if [ -n "$OAUTH_TOKEN" ]; then
  echo "[BOOT] OAUTH_TOKEN env var set, starting proxy directly."
  exec node /app/proxy.js
fi

# Already authenticated -> start proxy immediately
if [ -s "$CREDS_FILE" ]; then
  echo "[BOOT] Credentials found at $CREDS_FILE, starting proxy."
  start_refresh_loop
  exec node /app/proxy.js
fi

# First boot — idle with a health stub HTTP server
echo "[BOOT] No credentials at $CREDS_FILE yet."
echo "[BOOT] To authenticate, run from the host:"
echo "[BOOT]   docker exec -it claude-bypass claude auth login"
echo "[BOOT] Or set OAUTH_TOKEN env var and restart the container."

# Spawn health stub in background — answers /health 200, everything else 503
node -e "
const http = require('http');
const port = parseInt(process.env.PROXY_PORT || '18801', 10);
http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status: 'booting', credentials: false, message: 'Run: docker exec -it claude-bypass claude auth login'}));
  } else {
    res.writeHead(503, {'Content-Type': 'text/plain'});
    res.end('Proxy not started — waiting for credentials. See /health.');
  }
}).listen(port, '0.0.0.0', () => {
  console.log('[BOOT] Health stub listening on :' + port);
});
" &
STUB_PID=$!

# Poll for credentials
echo "[BOOT] Polling $CREDS_FILE every 5 seconds..."
while [ ! -s "$CREDS_FILE" ]; do
  sleep 5
done

echo "[BOOT] Credentials detected, killing health stub and starting proxy."
kill "$STUB_PID" 2>/dev/null || true
# Give the OS a moment to release the port
sleep 1
start_refresh_loop
exec node /app/proxy.js
