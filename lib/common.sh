#!/usr/bin/env bash
# =============================================================================
# WHALE - Common library: shared variables and functions for scripts
# =============================================================================
set -euo pipefail

# Paths (override via environment if needed)
export WHALE_ROOT="${WHALE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export WHALE_CONFIG="${WHALE_CONFIG:-$WHALE_ROOT/config}"
export WHALE_TEMPLATES="${WHALE_TEMPLATES:-$WHALE_ROOT/templates}"
export WHALE_BACKUPS="${WHALE_BACKUPS:-/var/backups/whale}"
export WHALE_PROJECTS="${WHALE_PROJECTS:-/var/www}"
export WHALE_LOGS="${WHALE_LOGS:-$WHALE_ROOT/logs}"

# NGINX and proxy
export NGINX_CONF_D="${NGINX_CONF_D:-/etc/nginx/conf.d}"
export NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
export NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
export LETSENCRYPT_LIVE="${LETSENCRYPT_LIVE:-/etc/letsencrypt/live}"

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"; }
log_err() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] ERROR: $*" >&2; }
die() { log_err "$*"; exit 1; }

# Check root when required
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (or with sudo)."
  fi
}

# Check port is free
is_port_in_use() {
  local port=$1
  if command -v ss &>/dev/null; then
    ss -tuln | grep -q ":$port " && return 0
  else
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$port" 'BEGIN { port=sprintf(":%04X", p) } $2 ~ port { exit 1 }' || return 0
  fi
  return 1
}

# Find next available port from a base
next_available_port() {
  local base=$1
  local max=$((base + 500))
  local p=$base
  while [[ $p -lt $max ]]; do
    if ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    ((p++))
  done
  return 1
}

# Source this file: source "$(dirname "$0")/lib/common.sh"
