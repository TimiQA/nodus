#!/usr/bin/env bash
set -euo pipefail

SCRIPT_TAG="nodus-managed"
PROJECT_DIR="/opt/nodus"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

DOMAIN=""
LE_EMAIL=""
PUBLIC_IP=""
turn_secret=""

compose_file="${PROJECT_DIR}/docker-compose.yml"

compose_nginx_was_running=0
host_nginx_was_active=0
host_apache_was_active=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root."
  fi
}

backup_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    cp -a "${path}" "${path}.bak_${TIMESTAMP}"
    log "Backup created: ${path}.bak_${TIMESTAMP}"
  fi
}

prompt_inputs() {
  read -r -p "Enter domain (e.g. example.ru): " DOMAIN </dev/tty
  read -r -p "Enter email for Let's Encrypt: " LE_EMAIL </dev/tty
  read -r -p "Enter public IP for Coturn (leave blank to auto-detect from DNS): " PUBLIC_IP </dev/tty

  [[ -n "${DOMAIN}" ]] || fail "Domain cannot be empty."
  [[ -n "${LE_EMAIL}" ]] || fail "Email cannot be empty."
}

install_if_missing() {
  local pkg="$1"
  if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
    log "Installing missing package: ${pkg}"
    apt-get install -y "${pkg}"
  fi
}

preflight_checks() {
  log "Running pre-flight checks"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1

  install_if_missing ufw
  install_if_missing curl
  install_if_missing certbot
  install_if_missing openssl
  install_if_missing docker.io
  install_if_missing docker-compose
  install_if_missing dnsutils

  command -v ufw >/dev/null 2>&1 || fail "ufw not found after installation."
  command -v curl >/dev/null 2>&1 || fail "curl not found after installation."
  command -v certbot >/dev/null 2>&1 || fail "certbot not found after installation."
  command -v docker >/dev/null 2>&1 || fail "docker not found after installation."
  command -v openssl >/dev/null 2>&1 || fail "openssl not found after installation."
  command -v docker-compose >/dev/null 2>&1 || fail "docker-compose not found after installation."

  if ! systemctl is-active --quiet docker; then
    log "Docker daemon is not active, starting docker service"
    systemctl enable --now docker >/dev/null 2>&1
  fi
  systemctl is-active --quiet docker || fail "Docker daemon is not running."
}

remove_managed_ufw_rules() {
  log "Removing previous managed UFW rules (if any)"
  local raw
  raw="$(ufw status numbered || true)"

  if [[ -z "${raw}" ]]; then
    return
  fi

  mapfile -t rule_numbers < <(
    printf '%s\n' "${raw}" | \
      awk -v tag="${SCRIPT_TAG}" '$0 ~ tag { gsub(/[\[\]]/, "", $1); print $1 }' | \
      sort -rn
  )

  if [[ "${#rule_numbers[@]}" -eq 0 ]]; then
    return
  fi

  for n in "${rule_numbers[@]}"; do
    ufw --force delete "${n}" >/dev/null 2>&1 || true
  done
}

apply_firewall_rules() {
  remove_managed_ufw_rules

  log "Applying firewall rules"
  ufw allow 22/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 80/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 443/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 8448/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 3478/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 3478/udp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 5349/tcp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw allow 49152:49200/udp comment "${SCRIPT_TAG}" >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
}

generate_secrets() {
  turn_secret="$(openssl rand -hex 16)"
}

resolve_public_ip() {
  if [[ -n "${PUBLIC_IP}" ]]; then
    return
  fi

  log "Detecting public IP from DNS for ${DOMAIN}"
  PUBLIC_IP="$(getent ahostsv4 "${DOMAIN}" | awk 'NR==1 {print $1}')"

  if [[ -z "${PUBLIC_IP}" ]]; then
    fail "Failed to determine public IP. Please enter it manually when prompted."
  fi
}

write_docker_compose() {
  local path="${PROJECT_DIR}/docker-compose.yml"
  backup_file "${path}"

  cat > "${path}" <<EOF
services:
  matrix:
    image: registry.gitlab.com/famedly/conduit/matrix-conduit:latest
    container_name: matrix-conduit
    restart: unless-stopped
    environment:
      CONDUIT_CONFIG: "/etc/matrix-conduit/conduit.toml"
    volumes:
      - ./conduit.toml:/etc/matrix-conduit/conduit.toml:ro
      - conduit-db:/var/lib/matrix-conduit/
    networks:
      - matrix-net

  element:
    image: vectorim/element-web:latest
    container_name: matrix-element
    restart: unless-stopped
    volumes:
      - ./element-config.json:/app/config.json:ro
    networks:
      - matrix-net

  nginx:
    image: nginx:latest
    container_name: matrix-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8448:8448"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    networks:
      - matrix-net
    depends_on:
      - matrix
      - element

  coturn:
    image: coturn/coturn:latest
    container_name: matrix-coturn
    restart: unless-stopped
    network_mode: host
    user: root
    volumes:
      - ./coturn.conf:/etc/coturn/turnserver.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: [ "turnserver", "-c", "/etc/coturn/turnserver.conf", "-v" ]

networks:
  matrix-net:
    driver: bridge

volumes:
  conduit-db:
EOF
}

write_element_conf() {
  local path="${PROJECT_DIR}/element-config.json"
  backup_file "${path}"

  cat > "${path}" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${DOMAIN}",
      "server_name": "${DOMAIN}"
    },
    "m.identity_server": {
      "base_url": "https://vector.im"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "disable_3pid_login": true,
  "brand": "Sovereign Matrix",
  "default_theme": "dark"
}
EOF
}

write_conduit_conf() {
  local path="${PROJECT_DIR}/conduit.toml"
  backup_file "${path}"

  cat > "${path}" <<EOF
[global]
server_name = "${DOMAIN}"
address = "0.0.0.0"
port = 6167
database_backend = "rocksdb"
database_path = "/var/lib/matrix-conduit/"
max_request_size = 20000000
allow_registration = true
allow_encryption = true
allow_federation = true
turn_uris = [
  "turns:${DOMAIN}:5349?transport=tcp",
  "turn:${DOMAIN}:3478?transport=udp",
  "turn:${DOMAIN}:3478?transport=tcp"
]
turn_secret = "${turn_secret}"

[global.media]
backend = "filesystem"

[[global.media.retention]]
space = "10GB"

[[global.media.retention]]
scope = "remote"
accessed = "14d"
created = "30d"

[[global.media.retention]]
scope = "local"
accessed = "30d"

[[global.media.retention]]
scope = "thumbnail"
space = "500MB"
EOF
}

write_coturn_conf() {
  local path="${PROJECT_DIR}/coturn.conf"
  backup_file "${path}"

  cat > "${path}" <<EOF
use-auth-secret
static-auth-secret=${turn_secret}
realm=${DOMAIN}

listening-port=3478
tls-listening-port=5349
cert=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
pkey=/etc/letsencrypt/live/${DOMAIN}/privkey.pem
cipher-list=HIGH

min-port=49152
max-port=49200

external-ip=${PUBLIC_IP}
no-cli
EOF
}

write_nginx_conf() {
  local path="${PROJECT_DIR}/nginx.conf"
  backup_file "${path}"

  cat > "${path}" <<EOF
events {}

http {
    server {
        listen 80;
        server_name ${DOMAIN};
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 443 ssl http2;
        listen 8448 ssl http2;
        server_name ${DOMAIN};

        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

        client_max_body_size 20M;

        location / {
            proxy_pass http://matrix-element:80;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
        }

        location /.well-known/matrix/client {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '{"m.homeserver":{"base_url":"https://${DOMAIN}"}}';
        }

        location /.well-known/matrix/server {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '{"m.server":"${DOMAIN}:443"}';
        }

        location /_matrix/ {
            proxy_pass http://matrix-conduit:6167;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_read_timeout 600;
        }
    }
}
EOF
}

render_files() {
  mkdir -p "${PROJECT_DIR}"
  write_docker_compose
  write_element_conf
  write_conduit_conf
  write_coturn_conf
  write_nginx_conf
}

stop_conflicting_web_services() {
  compose_nginx_was_running=0
  host_nginx_was_active=0
  host_apache_was_active=0

  if [[ -f "${compose_file}" ]]; then
    local nginx_container_id
    nginx_container_id="$(docker-compose -f "${compose_file}" ps -q nginx 2>/dev/null || true)"
    if [[ -n "${nginx_container_id}" ]]; then
      log "Stopping compose nginx temporarily to free port 80 for certbot"
      docker-compose -f "${compose_file}" stop nginx >/dev/null 2>&1 || true
      compose_nginx_was_running=1
    fi
  fi

  if systemctl is-active --quiet nginx; then
    log "Stopping host nginx temporarily to free port 80 for certbot"
    systemctl stop nginx >/dev/null 2>&1
    host_nginx_was_active=1
  fi

  if systemctl is-active --quiet apache2; then
    log "Stopping host apache2 temporarily to free port 80 for certbot"
    systemctl stop apache2 >/dev/null 2>&1
    host_apache_was_active=1
  fi
}

start_conflicting_web_services() {
  if [[ "${host_nginx_was_active}" -eq 1 ]]; then
    systemctl start nginx >/dev/null 2>&1 || true
  fi
  if [[ "${host_apache_was_active}" -eq 1 ]]; then
    systemctl start apache2 >/dev/null 2>&1 || true
  fi
  if [[ "${compose_nginx_was_running}" -eq 1 ]] && [[ -f "${compose_file}" ]]; then
    docker-compose -f "${compose_file}" start nginx >/dev/null 2>&1 || true
  fi
}

ensure_certificate() {
  local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  local key_path="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
    if openssl x509 -checkend 2592000 -noout -in "${cert_path}" >/dev/null 2>&1; then
      log "Valid certificate already exists for ${DOMAIN}, skipping certbot"
      return
    fi
    log "Existing certificate found but expiring soon or invalid; requesting renewal"
  else
    log "Certificate for ${DOMAIN} not found, requesting via certbot"
  fi

  stop_conflicting_web_services

  certbot certonly --standalone \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${LE_EMAIL}" >/dev/null

  start_conflicting_web_services
}

start_stack() {
  log "Starting Docker stack"
  docker-compose -f "${PROJECT_DIR}/docker-compose.yml" up -d
}

run_healthcheck() {
  log "Waiting 10 seconds for Conduit database initialization..."
  sleep 10
  
  local url="https://${DOMAIN}/_matrix/client/versions"
  log "Running healthcheck: ${url}"

  if curl --fail --silent --show-error \
      --connect-timeout 5 \
      --max-time 15 \
      --retry 5 \
      --retry-delay 2 \
      --retry-connrefused \
      "${url}" >/dev/null; then
    echo "STATUS: OK"
  else
    echo "STATUS: FAILED"
    return 1
  fi
}

main() {
  require_root
  prompt_inputs
  preflight_checks
  apply_firewall_rules
  generate_secrets
  resolve_public_ip
  render_files
  ensure_certificate
  start_stack
  run_healthcheck

  echo ""
  log "=========================================================="
  log "✅ Deployment completed successfully!"
  log "Project directory: ${PROJECT_DIR}"
  log "Registration is open. Access your messenger here:"
  log "👉 https://${DOMAIN}"
  log "=========================================================="
}

main "$@"
