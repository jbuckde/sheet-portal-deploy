#!/usr/bin/env bash
# setup-server.sh — idempotent server bootstrap for sheet-portal
#
# Run as root on the target server.
# Safe to re-run: all steps check before acting.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jbuckde/sheet-portal/main/deploy/setup-server.sh | sudo bash
# or copy to the server and run:
#   sudo bash setup-server.sh

set -euo pipefail

APP_USER="sheetportal"
APP_HOME="/home/${APP_USER}"
APP_DIR="${APP_HOME}"
REPO_RAW="https://raw.githubusercontent.com/jbuckde/sheet-portal-deploy/main"
COMPOSE_FILE="docker-compose.production.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
prompt() {
  local var="$1" prompt="$2" default="${3:-}"
  local current="${!var:-}"
  if [ -n "$current" ]; then
    echo "  ${var} already set — keeping existing value"
    return
  fi
  if [ -n "$default" ]; then
    read -rp "  ${prompt} [${default}]: " val
    eval "${var}='${val:-$default}'"
  else
    while [ -z "${!var:-}" ]; do
      read -rp "  ${prompt}: " val
      eval "${var}='${val}'"
      [ -z "${!var}" ] && echo "  (required, cannot be empty)"
    done
  fi
}

prompt_secret() {
  local var="$1" prompt="$2"
  local current="${!var:-}"
  if [ -n "$current" ]; then
    echo "  ${var} already set — keeping existing value"
    return
  fi
  while [ -z "${!var:-}" ]; do
    read -rsp "  ${prompt}: " val; echo
    eval "${var}='${val}'"
    [ -z "${!var}" ] && echo "  (required, cannot be empty)"
  done
}

section() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------
# 0. Sanity check — warn if resources already exist
# ---------------------------------------------------------------------------
ALREADY_EXISTS=""
id "${APP_USER}"            &>/dev/null && ALREADY_EXISTS="${ALREADY_EXISTS}  - system user '${APP_USER}'\n"
[ -f "${APP_DIR}/.env" ]               && ALREADY_EXISTS="${ALREADY_EXISTS}  - ${APP_DIR}/.env\n"
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "sheet" \
                                       && ALREADY_EXISTS="${ALREADY_EXISTS}  - running Docker containers\n"

if [ -n "$ALREADY_EXISTS" ]; then
  echo
  echo "WARNING: The following resources already exist on this server:"
  printf "%b" "$ALREADY_EXISTS"
  echo
  echo "Re-running will:"
  echo "  - overwrite .env (existing values are re-prompted and kept if confirmed)"
  echo "  - re-download all deploy/ assets from GitHub"
  echo "  - restart the Docker stack"
  echo
  read -rp "Continue anyway? [y/N] " CONFIRM
  case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# 1. Install Docker
# ---------------------------------------------------------------------------
section "Docker"
if ! command -v docker &>/dev/null; then
  echo "--> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
else
  echo "--> Docker already installed: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 2. System user
# ---------------------------------------------------------------------------
section "System user"
if id "${APP_USER}" &>/dev/null; then
  echo "--> User '${APP_USER}' already exists"
else
  echo "--> Creating user '${APP_USER}'..."
  useradd --system --create-home --home-dir "${APP_HOME}" --shell /usr/sbin/nologin "${APP_USER}"
fi
groups "${APP_USER}" | grep -q docker || usermod -aG docker "${APP_USER}"
mkdir -p "${APP_DIR}"
chown "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 750 "${APP_DIR}"

# ---------------------------------------------------------------------------
# 3. Download compose file and deploy assets from GitHub (or copy from /tmp)
# ---------------------------------------------------------------------------
section "Compose file and deploy assets"

# If files were pre-copied to /tmp (private repo), use them instead of GitHub.
LOCAL_ASSETS=""
[ -f "/tmp/docker-compose.production.yml" ] && LOCAL_ASSETS="true"

download() {
  local src="$1" dst="$2"
  local filename
  filename=$(basename "$src")
  local localdir
  localdir=$(dirname "$src")
  # Try local /tmp first (private repo fallback)
  local local_path="/tmp/${src}"
  if [ -f "${local_path}" ]; then
    cp "${local_path}" "${dst}"
  elif [ -n "${LOCAL_ASSETS}" ]; then
    echo "!!! Local file not found: /tmp/${src}" >&2
    exit 1
  else
    curl -fsSL "${REPO_RAW}/${src}" -o "${dst}"
  fi
  chown "${APP_USER}:${APP_USER}" "${dst}"
}

mkdir -p "${APP_DIR}/deploy/grafana/provisioning" "${APP_DIR}/deploy/grafana/dashboards"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/deploy"

for f in \
  "${COMPOSE_FILE}" \
  "deploy/garage.toml" \
  "deploy/garage-init.sh" \
  "deploy/Dockerfile.garage-init" \
  "deploy/Caddyfile" \
  "deploy/dex-config.yaml" \
  "deploy/prometheus.yml" \
  "deploy/grafana/provisioning/datasources.yaml" \
  "deploy/grafana/provisioning/dashboards.yaml"
do
  dst="${APP_DIR}/${f}"
  mkdir -p "$(dirname "$dst")"
  echo "--> ${f}"
  download "${f}" "${dst}"
done
chmod +x "${APP_DIR}/deploy/garage-init.sh"

# ---------------------------------------------------------------------------
# 4. TLS certificate
# ---------------------------------------------------------------------------
section "TLS certificate"
CERT_DIR="${APP_DIR}/certs"
mkdir -p "${CERT_DIR}"
chown "${APP_USER}:${APP_USER}" "${CERT_DIR}"
if [ ! -f "${CERT_DIR}/cert.pem" ] || [ ! -f "${CERT_DIR}/key.pem" ]; then
  echo "--> No certificate found in ${CERT_DIR}."
  echo "    Place cert.pem and key.pem there, then re-run, or press Enter to generate a self-signed cert."
  read -rp "  Hostname / IP for self-signed cert [$(hostname -I | awk '{print $1}')]: " CERT_HOST
  CERT_HOST="${CERT_HOST:-$(hostname -I | awk '{print $1}')}"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
    -subj "/CN=${CERT_HOST}" \
    -addext "subjectAltName=IP:${CERT_HOST},DNS:${CERT_HOST}" 2>/dev/null
  chown "${APP_USER}:${APP_USER}" "${CERT_DIR}/cert.pem" "${CERT_DIR}/key.pem"
  chmod 600 "${CERT_DIR}/key.pem"
  echo "--> Self-signed cert generated for ${CERT_HOST}"
else
  echo "--> Certificate already present"
fi

# ---------------------------------------------------------------------------
# 5. .env — collect or reuse
# ---------------------------------------------------------------------------
section ".env configuration"
ENV_FILE="${APP_DIR}/.env"

# Load existing values so prompts can show "already set"
set -a
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}" || true
set +a

echo "  Fill in the required values. Press Enter to keep an existing value."
echo

prompt      APP_BASE_URL        "Public URL (e.g. https://192.168.1.25)"
prompt      JWT_SECRET          "JWT secret (long random string)"
prompt      POSTGRES_PASSWORD   "PostgreSQL password"
DATABASE_URL="postgresql://sheetportal:${POSTGRES_PASSWORD}@postgres:5432/sheetportal"

# Dex OIDC
prompt      DEX_PUBLIC_ISSUER   "Dex public issuer URL (e.g. https://192.168.1.25/dex)"
DEX_ISSUER="http://dex:5556/dex"
DEX_ENABLED="true"
DEX_CLIENT_ID="sheet-portal"
prompt_secret DEX_CLIENT_SECRET "Dex client secret"
DEX_REDIRECT_URI="${APP_BASE_URL}/auth/callback/dex"

# Google OAuth (optional)
prompt      GOOGLE_CLIENT_ID     "Google OAuth client ID (Enter to skip)" ""
prompt_secret_optional() {
  local var="$1" prompt="$2"
  local current="${!var:-}"
  if [ -n "$current" ]; then echo "  ${var} already set — keeping"; return; fi
  read -rsp "  ${prompt} (Enter to skip): " val; echo
  eval "${var}='${val}'"
}
if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
  prompt_secret_optional GOOGLE_CLIENT_SECRET "Google OAuth client secret"
  GOOGLE_REDIRECT_URI="${APP_BASE_URL}/auth/callback/google"
fi

# LLM
prompt      GEMINI_API_KEY      "Gemini API key (for voice detection, Enter to skip)" ""
prompt      GROQ_API_KEY        "Groq API key (for voice detection, Enter to skip)"   ""

# Grafana
prompt_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password"

# Backup
prompt      BACKUP_TARGET       "Backup target (rclone remote or path, Enter to skip)" ""

cat > "${ENV_FILE}" <<ENVEOF
# Generated by setup-server.sh
APP_BASE_URL=${APP_BASE_URL}
JWT_SECRET=${JWT_SECRET}

DATABASE_URL=${DATABASE_URL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

DEX_ENABLED=${DEX_ENABLED}
DEX_ISSUER=${DEX_ISSUER}
DEX_PUBLIC_ISSUER=${DEX_PUBLIC_ISSUER}
DEX_CLIENT_ID=${DEX_CLIENT_ID}
DEX_CLIENT_SECRET=${DEX_CLIENT_SECRET}
DEX_REDIRECT_URI=${DEX_REDIRECT_URI}

GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}
GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI:-}

GEMINI_API_KEY=${GEMINI_API_KEY:-}
GROQ_API_KEY=${GROQ_API_KEY:-}

GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
BACKUP_TARGET=${BACKUP_TARGET:-}

# S3 — filled in automatically by this script after Garage init
S3_ENDPOINT=http://garage:3900
S3_REGION=garage
S3_BUCKET=sheet-portal
S3_ACCOUNT_ID=
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
ENVEOF

chown "${APP_USER}:${APP_USER}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
echo "--> .env written"

# ---------------------------------------------------------------------------
# 6. Pull images and start stack
# ---------------------------------------------------------------------------
section "Starting stack"
cd "${APP_DIR}"
sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" build createbuckets
sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" pull --quiet
sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" up -d

echo "--> Waiting for Garage to become healthy..."
for i in $(seq 1 30); do
  STATUS=$(sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" \
    ps --format "{{.Health}}" garage 2>/dev/null || true)
  [ "$STATUS" = "healthy" ] && break
  echo "    ($i/30) status: ${STATUS:-starting}"
  sleep 3
done
[ "$STATUS" = "healthy" ] || { echo "!!! Garage did not become healthy in time"; exit 1; }

# ---------------------------------------------------------------------------
# 7. Garage init — run createbuckets, extract credentials, patch .env
# ---------------------------------------------------------------------------
section "Garage init"

# Check if already initialised
EXISTING_KEY=$(sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" \
  exec -T garage /garage key list 2>/dev/null | grep sheet-portal-key | awk '{print $1}' || true)

if [ -n "${EXISTING_KEY}" ]; then
  echo "--> Garage already initialised (key ${EXISTING_KEY})"
  # Re-read credentials in case .env is incomplete
  KEY_INFO=$(sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" \
    exec -T garage /garage key info "${EXISTING_KEY}" 2>/dev/null)
else
  echo "--> Running createbuckets..."
  # Run and capture output
  INIT_LOG=$(sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" \
    run --rm createbuckets 2>&1)
  echo "${INIT_LOG}"
  KEY_INFO="${INIT_LOG}"
fi

KEY_ID=$(echo "${KEY_INFO}"     | grep -E '^Key ID:'     | awk '{print $3}' | tr -d '[:space:]')
SECRET=$(echo "${KEY_INFO}"     | grep -E '^Secret key:' | awk '{print $3}' | tr -d '[:space:]')

if [ -z "${KEY_ID}" ] || [ -z "${SECRET}" ]; then
  echo "!!! Could not extract S3 credentials automatically."
  echo "    Run: docker compose -f ${COMPOSE_FILE} exec garage /garage key info sheet-portal-key"
  echo "    Then add S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY to ${ENV_FILE} and restart:"
  echo "    docker compose -f ${COMPOSE_FILE} up -d api ops"
else
  sed -i "s|^S3_ACCOUNT_ID=.*|S3_ACCOUNT_ID=${KEY_ID}|"       "${ENV_FILE}"
  sed -i "s|^S3_ACCESS_KEY_ID=.*|S3_ACCESS_KEY_ID=${KEY_ID}|" "${ENV_FILE}"
  sed -i "s|^S3_SECRET_ACCESS_KEY=.*|S3_SECRET_ACCESS_KEY=${SECRET}|" "${ENV_FILE}"
  echo "--> S3 credentials written to .env"

  # Restart api and ops so they pick up the new credentials
  sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" up -d api ops
  echo "--> api and ops restarted with S3 credentials"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
section "Setup complete"
sudo -u "${APP_USER}" docker compose -f "${COMPOSE_FILE}" ps \
  --format "table {{.Name}}\t{{.Status}}"
echo
echo "  App URL : ${APP_BASE_URL}"
echo "  Logs    : docker compose -f ${APP_DIR}/${COMPOSE_FILE} logs -f api"
