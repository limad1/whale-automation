#!/usr/bin/env bash
# =============================================================================
# WHALE - Configure firewall (iptables/UFW): allow only required ports
# Ports: 80 (HTTP), 443 (HTTPS), 22 (SSH), 21 (FTP), 3306 (MySQL internal)
# Optional: 9000 (Portainer), 3000 (Grafana), 9090 (Prometheus)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

# Allowed ports
PORTS_ALLOW=(
  22    # SSH
  80    # HTTP
  443   # HTTPS
  21    # FTP
  3000  # Grafana
  3001  # Uptime Kuma
  9000  # Portainer
  9090  # Prometheus
  3100  # Loki (optional, often internal)
)

require_root

if command -v ufw &>/dev/null; then
  log "Configuring UFW..."
  run_ufw() {
    for p in "${PORTS_ALLOW[@]}"; do
      sudo ufw allow "$p/tcp" 2>/dev/null || true
    done
    sudo ufw allow from 127.0.0.1
    sudo ufw --force enable
    sudo ufw status verbose
  }
  run_ufw
  log "UFW configured."
else
  log "UFW not found. Configuring iptables..."
  # Flush and set defaults
  sudo iptables -F
  sudo iptables -P INPUT DROP
  sudo iptables -P FORWARD DROP
  sudo iptables -P OUTPUT ACCEPT
  sudo iptables -A INPUT -i lo -j ACCEPT
  sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  for p in "${PORTS_ALLOW[@]}"; do
    sudo iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
  done
  # Allow Docker bridge if needed
  sudo iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT
  sudo iptables -A FORWARD -i docker0 -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
  sudo iptables -A FORWARD -i eth0 -o docker0 -m state --state ESTABLISHED,RELATED -j ACCEPT
  if [[ -d /etc/iptables ]]; then
    sudo iptables-save | sudo tee /etc/iptables/rules.v4
  fi
  log "iptables configured."
fi
