#!/usr/bin/env bash
# =============================================================================
# WHALE - Deploy the main Docker stack (run after setup.sh)
# Usage: ./deploy_stack.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
cd "${SCRIPT_DIR}/docker"

if [[ ! -f .env ]]; then
  log "Creating .env from .env.example (please edit .env with real passwords)"
  cp -n .env.example .env
fi

export MYSQL_ROOT_PASSWORD
export MYSQL_PASSWORD
export GRAFANA_ADMIN_PASSWORD
source .env 2>/dev/null || true

docker compose -f docker-compose.whale.yml up -d
log "WHALE stack started. Grafana: http://localhost:3000, Portainer: http://localhost:9000"
