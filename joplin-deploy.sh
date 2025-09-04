#!/usr/bin/env bash
set -euo pipefail

# ====================================================================================
# Self-installing Joplin Server stack with Docker CE auto-install (multi-distro)
# - Installs Docker CE + Compose if missing
# - Deploys Postgres + Joplin + Nginx (+ optional Let's Encrypt via webroot)
# - Email is OPTIONAL: SMTP modes = none | relay | mailbox
# - Optional backups + cron
# ====================================================================================

# === Defaults ===
STACK_DIR="/opt/joplin-stack"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
ENV_FILE="${STACK_DIR}/.env"
NGINX_DIR="${STACK_DIR}/nginx"
WEBROOT_DIR="${NGINX_DIR}/webroot"
LE_DIR="${STACK_DIR}/letsencrypt"        # certbot share
DATA_DIR="${STACK_DIR}/data"             # postgres bind
BACKUP_DIR="${STACK_DIR}/backups"
COMPOSE_WRAPPER="${STACK_DIR}/compose.sh"

DOMAIN=""
LE_EMAIL=""
USE_LETSENCRYPT=1                         # 1=yes, 0=no (BYO certs)

# Email is OPTIONAL, default to none.
SMTP_MODE="none"                          # none | relay | mailbox
SMTP_HOST=""
SMTP_PORT="587"
SMTP_SECURITY="starttls"                  # starttls | tls | none
SMTP_USER=""                              # mailbox (or relay with auth)
SMTP_PASS=""
NOREPLY_EMAIL="noreply@localhost"
NOREPLY_NAME="Joplin Server"

DB_NAME="joplin"
DB_USER="joplin"
DB_PASS=""                                # if blank, autogenerate
JOPLIN_IMAGE="joplin/server:latest"
PG_IMAGE="postgres:14"
NGINX_IMAGE="nginx:1.27-alpine"
CERTBOT_IMAGE="certbot/certbot:latest"

ENABLE_BACKUP=0
INSTALL_CRON=1

usage() {
  cat <<EOF
Usage: $0 --domain <fqdn> [options]

Required:
  --domain <fqdn>                 Public domain for Joplin (e.g., joplin.example.com)
  --db-pass <password>            Postgres password (or omit to autogenerate)

Let's Encrypt (default ON):
  --le-email <email>              Email for Let's Encrypt
  --no-letsencrypt                Disable LE (BYO certs under \${STACK_DIR}/letsencrypt/live/<domain>/)

Email (OPTIONAL — default: none):
  --smtp-mode none|relay|mailbox  Default: none
  --smtp-host <host>              (relay/mailbox) e.g., smtp-relay.gmail.com or smtp.gmail.com
  --smtp-port <port>              (relay/mailbox) Default: 587
  --smtp-security starttls|tls|none  (relay/mailbox) Default: starttls
  --smtp-user <user>              (mailbox) required; (relay) only if your relay requires auth
  --smtp-pass <password>          (mailbox/relay with auth)
  --noreply-email <addr>          Default: noreply@localhost
  --noreply-name  <name>          Default: "Joplin Server"

Misc:
  --enable-backup                 Install daily backup (02:30) + LE renew cron
  --no-cron                       Do not install any cron jobs
  --stack-dir <path>              Default: ${STACK_DIR}
EOF
  exit 1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --le-email) LE_EMAIL="${2:-}"; shift 2 ;;
    --no-letsencrypt) USE_LETSENCRYPT=0; shift ;;
    --smtp-mode) SMTP_MODE="${2:-}"; shift 2 ;;
    --smtp-host) SMTP_HOST="${2:-}"; shift 2 ;;
    --smtp-port) SMTP_PORT="${2:-}"; shift 2 ;;
    --smtp-security) SMTP_SECURITY="${2:-}"; shift 2 ;;
    --smtp-user) SMTP_USER="${2:-}"; shift 2 ;;
    --smtp-pass) SMTP_PASS="${2:-}"; shift 2 ;;
    --noreply-email) NOREPLY_EMAIL="${2:-}"; shift 2 ;;
    --noreply-name) NOREPLY_NAME="${2:-}"; shift 2 ;;
    --db-pass) DB_PASS="${2:-}"; shift 2 ;;
    --enable-backup) ENABLE_BACKUP=1; shift ;;
    --no-cron) INSTALL_CRON=0; shift ;;
    --stack-dir)
      STACK_DIR="${2:-}"
      COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
      ENV_FILE="${STACK_DIR}/.env"
      NGINX_DIR="${STACK_DIR}/nginx"
      WEBROOT_DIR="${NGINX_DIR}/webroot"
      LE_DIR="${STACK_DIR}/letsencrypt"
      DATA_DIR="${STACK_DIR}/data"
      BACKUP_DIR="${STACK_DIR}/backups"
      COMPOSE_WRAPPER="${STACK_DIR}/compose.sh"
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

# --- Validations ---
[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required"; usage; }
if [[ -z "$DB_PASS" ]]; then
  DB_PASS="$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=-' </dev/urandom | head -c 24)"
  echo "Generated DB password: ${DB_PASS}"
fi
if (( USE_LETSENCRYPT == 1 )) && [[ -z "$LE_EMAIL" ]]; then
  echo "ERROR: --le-email required when using Let's Encrypt"; usage
fi
case "$SMTP_MODE" in
  none) : ;;
  relay)
    [[ -z "$SMTP_HOST" ]] && { echo "ERROR: relay mode needs --smtp-host"; usage; }
    ;;
  mailbox)
    [[ -z "$SMTP_HOST" || -z "$SMTP_USER" || -z "$SMTP_PASS" ]] && { echo "ERROR: mailbox mode needs --smtp-host --smtp-user --smtp-pass"; usage; }
    ;;
  *) echo "ERROR: --smtp-mode must be none|relay|mailbox"; usage ;;
esac

# --- Docker install helpers ---
detect_distro() { source /etc/os-release; echo "${ID}|${ID_LIKE:-}|${VERSION_ID:-}|${VERSION_CODENAME:-}"; }

ensure_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install ca-certificates curl gnupg2 dnf-plugins-core
  elif command -v yum >/dev/null 2>&1; then
    yum -y install ca-certificates curl gnupg2 yum-utils
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y ca-certificates curl gpg2
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ca-certificates curl
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

install_docker_debian_ubuntu() {
  local ID="$1" CODENAME="$2"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  local ARCH; ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_docker_rhel_like() {
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-plugins-core ca-certificates curl gnupg2
    local ID="$(. /etc/os-release; echo "$ID")"
    case "$ID" in
      fedora) dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo ;;
      rhel) dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo || dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo ;;
      centos|rocky|almalinux|ol) dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo ;;
      *) dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo ;;
    esac
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    yum -y install yum-utils ca-certificates curl gnupg2
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum -y install docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
  fi
}

install_docker_suse() { zypper --non-interactive refresh; zypper --non-interactive install -y docker docker-compose || zypper --non-interactive install -y docker; systemctl enable --now docker; }
install_docker_arch()  { pacman -Sy --noconfirm docker docker-compose || pacman -Sy --noconfirm docker; systemctl enable --now docker; }

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 || systemctl start docker 2>/dev/null || true
    docker info >/dev/null 2>&1 && return 0
  fi
  echo "[*] Docker not found or not running — installing Docker CE…"
  ensure_prereqs
  local FIELDS; FIELDS="$(detect_distro)"
  local ID="${FIELDS%%|*}"; local REST="${FIELDS#*|}"
  local IDLIKE="${REST%%|*}"; REST="${REST#*|}"
  local VERSION_ID="${REST%%|*}"; local CODENAME="${REST#*|}"
  case "$ID" in
    ubuntu|debian)
      [[ -z "$CODENAME" && "$ID" = "debian" ]] && CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
      [[ -z "$CODENAME" && "$ID" = "ubuntu" ]] && CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-jammy}")"
      install_docker_debian_ubuntu "$ID" "$CODENAME" ;;
    rhel|centos|rocky|almalinux|ol|fedora) install_docker_rhel_like ;;
    opensuse*|sles|suse) install_docker_suse ;;
    arch) install_docker_arch ;;
    *)
      if [[ "${IDLIKE:-}" =~ (debian|ubuntu) ]]; then
        install_docker_debian_ubuntu "debian" "$( . /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
      elif [[ "${IDLIKE:-}" =~ (rhel|fedora) ]]; then
        install_docker_rhel_like
      else
        echo "ERROR: Unsupported distro ($ID). Install Docker manually and re-run." >&2; exit 1
      fi ;;
  esac
  docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not available after install." >&2; exit 1; }
}

# Compose wrapper so cron/commands work with either v2 or legacy
write_compose_wrapper() {
  cat > "${COMPOSE_WRAPPER}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if docker compose version >/dev/null 2>&1; then
  exec docker compose "$@"
elif command -v docker-compose >/dev/null 2>&1; then
  exec docker-compose "$@"
else
  echo "docker compose / docker-compose not found" >&2
  exit 1
fi
SH
  chmod 0755 "${COMPOSE_WRAPPER}"
}

# --- Ensure Docker + wrapper ---
ensure_docker
write_compose_wrapper

# --- Create structure ---
mkdir -p "${STACK_DIR}" "${NGINX_DIR}/conf.d" "${WEBROOT_DIR}" "${LE_DIR}" "${DATA_DIR}" "${BACKUP_DIR}"

# Decide if mailer is enabled based on SMTP_MODE
MAILER_ENABLED="0"
if [[ "$SMTP_MODE" == "relay" || "$SMTP_MODE" == "mailbox" ]]; then
  MAILER_ENABLED="1"
fi

# --- Write .env for compose (include path vars & mailer flag) ---
cat > "${ENV_FILE}" <<EOF
DOMAIN=${DOMAIN}
LE_EMAIL=${LE_EMAIL}
USE_LETSENCRYPT=${USE_LETSENCRYPT}

DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

MAILER_ENABLED=${MAILER_ENABLED}
NOREPLY_EMAIL=${NOREPLY_EMAIL}
NOREPLY_NAME=${NOREPLY_NAME}

SMTP_MODE=${SMTP_MODE}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_SECURITY=${SMTP_SECURITY}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}

JOPLIN_IMAGE=${JOPLIN_IMAGE}
PG_IMAGE=${PG_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
CERTBOT_IMAGE=${CERTBOT_IMAGE}

STACK_DIR=${STACK_DIR}
NGINX_DIR=${NGINX_DIR}
WEBROOT_DIR=${WEBROOT_DIR}
LE_DIR=${LE_DIR}
DATA_DIR=${DATA_DIR}
EOF

# --- Nginx reverse proxy config ---
VHOST="${NGINX_DIR}/conf.d/joplin.conf"
cat > "${VHOST}" <<'NGINXCONF'
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # ACME webroot for HTTP-01
    location /.well-known/acme-challenge/ {
        alias /var/www/certbot/.well-known/acme-challenge/;
    }

    # redirect all other HTTP to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    # If using LE, certs are mounted under /etc/letsencrypt
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://app:22300;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }

    client_max_body_size 100m;
}
NGINXCONF
sed -i "s|\${DOMAIN}|${DOMAIN}|g" "${VHOST}"

# --- docker-compose.yml (uses variables from .env) ---
cat > "${COMPOSE_FILE}" <<'COMPOSEYML'
services:
  db:
    image: ${PG_IMAGE}
    container_name: joplin_postgres
    restart: always
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - ${DATA_DIR}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 6

  app:
    image: ${JOPLIN_IMAGE}
    container_name: joplin_server
    restart: always
    depends_on:
      db:
        condition: service_healthy
    expose:
      - "22300"
    environment:
      APP_PORT: 22300
      APP_BASE_URL: "https://${DOMAIN}"
      DB_CLIENT: pg
      POSTGRES_PASSWORD: "${DB_PASS}"
      POSTGRES_DATABASE: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PORT: 5432
      POSTGRES_HOST: db

      # --- Email (optional) ---
      MAILER_ENABLED: "${MAILER_ENABLED}"
      MAILER_NOREPLY_NAME: "${NOREPLY_NAME}"
      MAILER_NOREPLY_EMAIL: "${NOREPLY_EMAIL}"
      MAILER_HOST: "${SMTP_HOST}"
      MAILER_PORT: "${SMTP_PORT}"
      MAILER_SECURITY: "${SMTP_SECURITY}"
      MAILER_AUTH_USER: "${SMTP_USER}"
      MAILER_AUTH_PASSWORD: "${SMTP_PASS}"
    healthcheck:
      test: ["CMD", "node", "-e", "require('net').connect(22300,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"]
      interval: 10s
      timeout: 3s
      retries: 20
      start_period: 20s

  nginx:
    image: ${NGINX_IMAGE}
    container_name: joplin_nginx
    restart: always
    depends_on:
      app:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${NGINX_DIR}/conf.d:/etc/nginx/conf.d:ro
      - ${WEBROOT_DIR}:/var/www/certbot
      - ${LE_DIR}:/etc/letsencrypt

  certbot:
    image: ${CERTBOT_IMAGE}
    profiles: ["certs"]
    volumes:
      - ${WEBROOT_DIR}:/var/www/certbot
      - ${LE_DIR}:/etc/letsencrypt
    entrypoint: ["/bin/sh","-c"]
    command: "echo 'Use: docker compose run --rm certbot certonly ... or renew'"
COMPOSEYML

# --- Bring up core stack (HTTP first) ---
echo "[*] Starting base stack (db/app/nginx)…"
"${COMPOSE_WRAPPER}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d db app nginx

# --- Obtain Let's Encrypt certs, if enabled ---
if (( USE_LETSENCRYPT == 1 )); then
  echo "[*] Requesting Let's Encrypt certificate for ${DOMAIN}…"
  "${COMPOSE_WRAPPER}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" run --rm certbot \
    certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" --email "${LE_EMAIL}" --agree-tos --no-eff-email

  echo "[*] Reloading nginx with new certs…"
  "${COMPOSE_WRAPPER}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T nginx nginx -s reload
else
  cat <<MSG
[*] Let's Encrypt disabled.
    Place your certs at: ${LE_DIR}/live/${DOMAIN}/{fullchain.pem,privkey.pem}
    Then reload nginx:
      ${COMPOSE_WRAPPER} --env-file ./.env restart nginx
MSG
fi

# --- Backup script + cron (optional) ---
BACKUP_SCRIPT="${STACK_DIR}/backup-joplin.sh"
cat > "${BACKUP_SCRIPT}" <<'BACKUPSH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

BACKUP_ROOT="./backups"
LOG="${BACKUP_ROOT}/last.log"
mkdir -p "${BACKUP_ROOT}"

echo "== $(date) ==" | tee -a "$LOG"

DB_CONT="joplin_postgres"
DB_NAME="$(docker exec "$DB_CONT" printenv POSTGRES_DB)"
DB_USER="$(docker exec "$DB_CONT" printenv POSTGRES_USER)"
TS="$(date +%F_%H-%M-%S)"
DEST="${BACKUP_ROOT}/${TS}"
mkdir -p "$DEST"

echo "[*] pg_dump (custom)…" | tee -a "$LOG"
docker exec "$DB_CONT" sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c -Z 9 -f /tmp/joplin.dump'
docker cp "${DB_CONT}:/tmp/joplin.dump" "${DEST}/postgres_${DB_NAME}_${TS}.dump"
docker exec "$DB_CONT" rm -f /tmp/joplin.dump

echo "[*] pg_dump (plain)…" | tee -a "$LOG"
docker exec "$DB_CONT" sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "${DEST}/postgres_${DB_NAME}_${TS}.sql.gz"

cp -a ./docker-compose.yml "${DEST}/docker-compose.yml"
cp -a ./.env "${DEST}/.env"
rsync -a ./nginx/ "${DEST}/nginx/"

( cd "$DEST" && sha256sum $(find . -type f -printf '%P\n') > SHA256SUMS )

find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \; || true
echo "== backup done ==" | tee -a "$LOG"
BACKUPSH
chmod 0750 "${BACKUP_SCRIPT}"

if (( INSTALL_CRON == 1 )); then
  echo "[*] Installing cron jobs…"
  CRONF="/etc/cron.d/joplin-stack"
  {
    echo "# Joplin stack: renew LE certs daily at 03:05 and reload nginx"
    echo "5 3 * * * root cd ${STACK_DIR} && ${COMPOSE_WRAPPER} --env-file ./.env run --rm certbot renew && ${COMPOSE_WRAPPER} --env-file ./.env exec -T nginx nginx -s reload"
    if (( ENABLE_BACKUP == 1 )); then
      echo "# Daily backup at 02:30"
      echo "30 2 * * * root bash ${BACKUP_SCRIPT} >> ${BACKUP_DIR}/cron.log 2>&1"
    fi
  } > "$CRONF"
  chmod 0644 "$CRONF"
  systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
fi

echo
echo "✅ Deployment complete."
echo "   URL: https://${DOMAIN}"
echo "   Stack dir: ${STACK_DIR}"
echo "   Compose: ${COMPOSE_FILE}"
echo "   LE certs: ${LE_DIR}/live/${DOMAIN}/ (if enabled)"
echo "   Backup script: ${BACKUP_SCRIPT} (cron installed: $INSTALL_CRON, backup enabled: $ENABLE_BACKUP)"
