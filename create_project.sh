#!/usr/bin/env bash
# =============================================================================
# WHALE - Create new WordPress project: user, container, DB, NGINX vhost, SSL, backup, monitoring
# Usage: sudo ./create_project.sh SITE_NAME DOMAIN [FTP_PASSWORD]
# Example: sudo ./create_project.sh mysite example.com 'SecureFtpPass1'
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Config (override via env)
WHALE_DOCKER="${WHALE_DOCKER:-$WHALE_ROOT/docker}"
PROJECTS_CONF="${WHALE_CONFIG}/projects.conf"
NGINX_CONFD="${WHALE_DOCKER}/nginx/conf.d"

require_root

usage() {
  echo "Usage: $0 SITE_NAME DOMAIN [FTP_PASSWORD]"
  echo "  SITE_NAME    : alphanumeric + underscore (e.g. mysite)"
  echo "  DOMAIN       : full domain (e.g. example.com)"
  echo "  FTP_PASSWORD : optional; random if not set"
  exit 1
}

# -----------------------------------------------------------------------------
# Next available port (avoid 8081, 8082 used by main stack)
# -----------------------------------------------------------------------------
get_next_port() {
  local base=8083
  local used
  used=$(docker ps -a --format '{{.Ports}}' 2>/dev/null | grep -oE '[0-9]+->80' | sed 's/->80//' || true)
  for p in $(seq "$base" 9000); do
    if ! echo "$used" | grep -q "^${p}$" && ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  die "No available port found"
}

# -----------------------------------------------------------------------------
# Create system user with home /var/www/<site>, minimal permissions, FTP
# -----------------------------------------------------------------------------
create_site_user() {
  local site=$1
  local ftp_pass=$2
  local home="${WHALE_PROJECTS}/${site}"
  local user="wp_${site}"

  if getent passwd "$user" &>/dev/null; then
    log "User $user already exists."
    echo "$user"
    return 0
  fi

  sudo useradd --system --home-dir "$home" --shell /bin/bash --create-home "$user"
  echo "$user:$ftp_pass" | sudo chpasswd
  sudo chown -R "$user:$user" "$home"
  sudo chmod 750 "$home"

  # vsftpd: allow this user
  if [[ -f /etc/vsftpd.userlist ]]; then
    echo "$user" | sudo tee -a /etc/vsftpd.userlist
  fi
  if grep -q "userlist_enable" /etc/vsftpd.conf 2>/dev/null; then
    : # already configured
  else
    echo "userlist_enable=YES" | sudo tee -a /etc/vsftpd.conf
    echo "userlist_file=/etc/vsftpd.userlist" | sudo tee -a /etc/vsftpd.conf
    echo "userlist_deny=NO" | sudo tee -a /etc/vsftpd.conf
  fi
  sudo systemctl restart vsftpd 2>/dev/null || true

  log "User $user created with home $home"
  echo "$user"
}

# -----------------------------------------------------------------------------
# Create MySQL database and user for the site
# -----------------------------------------------------------------------------
create_mysql_db() {
  local db_name=$1
  local db_user=$2
  local db_pass=$3
  local root_pass="${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD}"

  docker exec whale-mysql mysql -u root -p"$root_pass" -e "
    CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_pass';
    GRANT ALL ON \`$db_name\`.* TO '$db_user'@'%';
    FLUSH PRIVILEGES;
  " 2>/dev/null || die "Failed to create database $db_name"
  log "MySQL database $db_name and user $db_user created"
}

# -----------------------------------------------------------------------------
# Generate project docker-compose and start WordPress container
# -----------------------------------------------------------------------------
create_wordpress_container() {
  local site=$1
  local port=$2
  local db_name=$3
  local db_user=$4
  local db_pass=$5
  local home="${WHALE_PROJECTS}/${site}"
  local project_network="whale_whale-net"  # default stack name "whale"

  mkdir -p "$home/html" "$home/backups"
  sudo chown -R "wp_${site}:wp_${site}" "$home"

  cat > "$home/docker-compose.yml" << EOF
version: "3.8"
services:
  wordpress:
    image: wordpress:php8.2-apache
    container_name: whale-wp-${site}
    restart: unless-stopped
    ports:
      - "${port}:80"
    environment:
      WORDPRESS_DB_HOST: whale-mysql
      WORDPRESS_DB_NAME: ${db_name}
      WORDPRESS_DB_USER: ${db_user}
      WORDPRESS_DB_PASSWORD: ${db_pass}
    volumes:
      - ${home}/html:/var/www/html
    networks:
      - whale-net
    labels:
      logging: promtail
      logging_jobname: wp-${site}

networks:
  whale-net:
    external: true
EOF

  cd "$home"
  docker compose up -d
  cd - >/dev/null
  log "WordPress container whale-wp-${site} started on port $port"
}

# -----------------------------------------------------------------------------
# Add NGINX vhost (HTTP first for ACME challenge)
# -----------------------------------------------------------------------------
add_nginx_vhost() {
  local domain=$1
  local backend=$2
  local conf_file="${NGINX_CONFD}/${domain}.conf"

  if [[ -f "$conf_file" ]]; then
    log "NGINX vhost $conf_file already exists; skipping."
    return 0
  fi

  cat > "$conf_file" << EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        proxy_pass http://${backend};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  log "NGINX vhost $conf_file created (HTTP)"
  docker exec whale-nginx nginx -t && docker exec whale-nginx nginx -s reload
}

# -----------------------------------------------------------------------------
# Generate self-signed certificate and configure vhost for HTTPS (fallback when Certbot fails)
# Cert and key on host: WHALE_DOCKER/nginx/ssl/ → in container: /etc/nginx/ssl/
# -----------------------------------------------------------------------------
configure_ssl_selfsigned() {
  local domain=$1
  local conf_file="${NGINX_CONFD}/${domain}.conf"
  local backend_container="whale-wp-${SITE_NAME}:80"
  local ssl_dir="${WHALE_DOCKER}/nginx/ssl"
  local cert_host="${ssl_dir}/selfsigned.crt"
  local key_host="${ssl_dir}/selfsigned.key"
  # Paths as seen inside NGINX container
  local cert_nginx="/etc/nginx/ssl/selfsigned.crt"
  local key_nginx="/etc/nginx/ssl/selfsigned.key"

  mkdir -p "$ssl_dir"

  if [[ ! -f "$cert_host" || ! -f "$key_host" ]]; then
    log "Generating self-signed certificate (OpenSSL) at ${ssl_dir}/selfsigned.crt"
    if openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$key_host" -out "$cert_host" \
      -subj "/CN=WHALE-SelfSigned/O=WHALE/C=XX" \
      -addext "subjectAltName=DNS:${domain},DNS:www.${domain},DNS:localhost" 2>/dev/null; then
      :
    else
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_host" -out "$cert_host" \
        -subj "/CN=${domain}/O=WHALE/C=XX"
    fi
    chmod 644 "$cert_host"
    chmod 600 "$key_host"
  else
    log "Using existing self-signed certificate at ${cert_host}"
  fi

  log "Configuring NGINX vhost for HTTPS with self-signed certificate"
  cat > "$conf_file" << EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name ${domain} www.${domain};
    ssl_certificate     ${cert_nginx};
    ssl_certificate_key ${key_nginx};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    location / {
        proxy_pass http://${backend_container};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  docker exec whale-nginx nginx -t && docker exec whale-nginx nginx -s reload
  log "HTTPS configured for $domain (self-signed certificate)"
}

# -----------------------------------------------------------------------------
# Obtain Let's Encrypt certificate and switch vhost to HTTPS. On failure (e.g. no public DNS), use self-signed.
# -----------------------------------------------------------------------------
configure_ssl() {
  local domain=$1
  local email="${LETSENCRYPT_EMAIL:-admin@${domain}}"
  local conf_file="${NGINX_CONFD}/${domain}.conf"

  if docker run --rm \
    -v "${WHALE_DOCKER}/nginx/ssl:/etc/letsencrypt" \
    -v whale_certbot_www:/var/www/certbot \
    certbot/certbot certonly --webroot -w /var/www/certbot \
    -d "$domain" -d "www.${domain}" \
    --email "$email" --agree-tos --no-eff-email --force-renewal 2>/dev/null; then
    : # Certbot succeeded
  else
    log "Certbot failed for $domain (e.g. no public DNS). Using self-signed certificate."
    configure_ssl_selfsigned "$domain"
    return 0
  fi

  local cert_path="/etc/nginx/ssl/live/${domain}/fullchain.pem"
  local key_path="/etc/nginx/ssl/live/${domain}/privkey.pem"
  local backend_container="whale-wp-${SITE_NAME}:80"

  cat > "$conf_file" << EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name ${domain} www.${domain};
    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://${backend_container};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  docker exec whale-nginx nginx -t && docker exec whale-nginx nginx -s reload
  log "SSL configured for $domain (Let's Encrypt)"
}

# -----------------------------------------------------------------------------
# Register project and add backup entry
# -----------------------------------------------------------------------------
register_project() {
  local site=$1
  local domain=$2
  local container=$3
  local db_name=$4
  local port=$5
  echo "${site}|${domain}|${container}|${db_name}|${port}" >> "$PROJECTS_CONF"
  log "Project registered in $PROJECTS_CONF"
}

# -----------------------------------------------------------------------------
# Add Uptime Kuma monitor (optional)
# -----------------------------------------------------------------------------
register_uptime_kuma() {
  local domain=$1
  local url="https://${domain}"
  if command -v python3 &>/dev/null && [[ -f "${SCRIPT_DIR}/scripts/uptime_kuma.py" ]]; then
    python3 "${SCRIPT_DIR}/scripts/uptime_kuma.py" add "$domain" "$url" 2>/dev/null || log "Uptime Kuma skip (not configured or script failed)"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  [[ $# -ge 2 ]] || usage
  SITE_NAME="$1"
  DOMAIN="$2"
  FTP_PASS="${3:-$(openssl rand -base64 12)}"

  # Validate site name
  if [[ ! "$SITE_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    die "SITE_NAME must be alphanumeric and underscore only"
  fi

  log "Creating project: site=$SITE_NAME domain=$DOMAIN"

  # Load MySQL credentials from whale .env if present
  if [[ -f "${WHALE_DOCKER}/.env" ]]; then
    set -a
    source "${WHALE_DOCKER}/.env"
    set +a
  fi

  PORT=$(get_next_port)
  DB_NAME="${SITE_NAME}_db"
  DB_USER="wp_${SITE_NAME}"
  DB_PASS="${MYSQL_PASSWORD:-$(openssl rand -base64 16)}"

  create_site_user "$SITE_NAME" "$FTP_PASS"
  create_mysql_db "$DB_NAME" "$DB_USER" "$DB_PASS"
  create_wordpress_container "$SITE_NAME" "$PORT" "$DB_NAME" "$DB_USER" "$DB_PASS"
  add_nginx_vhost "$DOMAIN" "whale-wp-${SITE_NAME}:80"

  # SSL (optional; requires DNS pointing to this host)
  if [[ -n "${LETSENCRYPT_EMAIL:-}" ]] || true; then
    configure_ssl "$DOMAIN" || true
  else
    log "Set LETSENCRYPT_EMAIL and re-run SSL step or use configure_ssl for $DOMAIN"
  fi

  register_project "$SITE_NAME" "$DOMAIN" "whale-wp-${SITE_NAME}" "$DB_NAME" "$PORT"
  register_uptime_kuma "$DOMAIN"

  log "=== Project $SITE_NAME created ==="
  log "  Domain: $DOMAIN"
  log "  Port: $PORT"
  log "  DB: $DB_NAME"
  log "  User: wp_${SITE_NAME} (FTP pass: $FTP_PASS)"
  log "  Path: ${WHALE_PROJECTS}/${SITE_NAME}"
}

main "$@"
