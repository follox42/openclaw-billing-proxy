#!/bin/sh
# entrypoint.sh — wait for Claude credentials before starting the proxy.
#
# proxy.js exits(1) if credentials are missing at boot. Without this wrapper
# the container crash-loops until creds arrive. Instead we idle here and
# only exec proxy.js once /root/.claude/.credentials.json is present.
#
# First boot UX:
#   1. Container starts, this script idles
#   2. Operator runs:  docker exec -it claude-bypass claude auth login
#   3. claude writes creds to /root/.claude/.credentials.json (volume)
#   4. This script detects, exec proxy.js
#
# Subsequent boots: creds already in volume, proxy starts immediately.

set -eu

CREDS_FILE="${CREDS_FILE:-/root/.claude/.credentials.json}"
OAUTH_TOKEN="${OAUTH_TOKEN:-}"

# OAUTH_TOKEN env var bypasses the file check entirely
if [ -n "$OAUTH_TOKEN" ]; then
  echo "[BOOT] OAUTH_TOKEN env var set, starting proxy directly."
  exec node /app/proxy.js
fi

# Already authenticated → start proxy immediately
if [ -s "$CREDS_FILE" ]; then
  echo "[BOOT] Credentials found at $CREDS_FILE, starting proxy."
  exec node /app/proxy.js
fi

# First boot — idle until creds appear
echo "[BOOT] No credentials at $CREDS_FILE yet."
echo "[BOOT] To authenticate, run from the host:"
echo "[BOOT]   docker exec -it claude-bypass claude auth login"
echo "[BOOT] Or set OAUTH_TOKEN env var and restart the container."
echo "[BOOT] Idle loop polling every 5 seconds..."

while [ ! -s "$CREDS_FILE" ]; do
  sleep 5
done

echo "[BOOT] Credentials detected, starting proxy."
exec node /app/proxy.js
