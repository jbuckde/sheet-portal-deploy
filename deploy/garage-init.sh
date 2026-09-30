#!/bin/sh
# Idempotent Garage bootstrap — run once after garage is healthy.
# Set GARAGE_KEY_NAME to override the key name (default: dev-key).
# On success, prints "Key ID: <id>" and "Secret key: <secret>" to stdout
# so that setup-server.sh can capture and inject them into .env.

KEY_NAME="${GARAGE_KEY_NAME:-dev-key}"

# Assign layout on first run; ignore errors on re-run.
NODE_ID=$(/garage node id -q 2>/dev/null | cut -d: -f1 | head -c 16)
/garage layout assign -z dc1 -c 10G "$NODE_ID" 2>/dev/null || true
/garage layout apply --version 1 2>/dev/null || true

# Create key — prints credentials on first run, "already exists" on re-run.
CREATE_OUT=$(/garage key create "$KEY_NAME" 2>&1)
KEY_ID=$(echo "$CREATE_OUT" | grep -E '^Key ID:' | awk '{print $3}')
SECRET=$(echo "$CREATE_OUT"  | grep -E '^Secret key:' | awk '{print $3}')

# If key already existed, fetch credentials via key info.
if [ -z "$KEY_ID" ]; then
  KEY_ID=$(echo "$CREATE_OUT" | grep -oE 'GK[a-f0-9]+' | head -1)
  if [ -z "$KEY_ID" ]; then
    # Fall back: look up by name
    KEY_ID=$(/garage key list 2>/dev/null | grep "$KEY_NAME" | awk '{print $1}' | head -1)
  fi
  if [ -n "$KEY_ID" ]; then
    INFO=$(/garage key info "$KEY_ID" 2>/dev/null)
    SECRET=$(echo "$INFO" | grep -E '^Secret key:' | awk '{print $3}')
  fi
fi

/garage bucket create sheet-portal 2>/dev/null || true
/garage bucket allow sheet-portal --read --write --key "$KEY_NAME" 2>/dev/null || true

echo ""
echo "Key ID: ${KEY_ID}"
echo "Secret key: ${SECRET}"
