#!/usr/bin/env bash
# =============================================================================
# WHALE - Web Hosting Application Launching Environment
# setup.sh - Environment preparation: Ubuntu/Debian, Docker, rootless, services
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/logs/setup_$(date +%Y%m%d_%H%M%S).log"
readonly DEPS=(openssh-server vsftpd curl vim iptables ca-certificates gnupg lsb-release apt-transport-https software-properties-common)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
run() { log "RUN: $*"; "$@" >> "$LOG_FILE" 2>&1 || die "Command failed: $*"; }

# -----------------------------------------------------------------------------
# Detect Linux (Ubuntu/Debian)
# -----------------------------------------------------------------------------
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release not found. This script supports Ubuntu/Debian only."
  fi
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    die "Unsupported OS: $ID. This script requires Ubuntu or Debian."
  fi
  log "Detected OS: $PRETTY_NAME"
}

# -----------------------------------------------------------------------------
# Prepare system: update and install dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
  log "Updating package lists..."
  run sudo apt-get update -qq

  log "Installing dependencies: ${DEPS[*]}"
  run sudo apt-get install -y "${DEPS[@]}"

  # UFW is the frontend for iptables on Ubuntu/Debian
  if command -v ufw &>/dev/null; then
    run sudo apt-get install -y ufw
  fi
}

# -----------------------------------------------------------------------------
# Install Docker (latest) and Docker Compose
# -----------------------------------------------------------------------------
install_docker() {
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    log "Docker is already installed and running."
    docker --version
    return 0
  fi

  log "Installing Docker..."
  # Add Docker's official GPG key and repository
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  source /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-jammy} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  run sudo apt-get update -qq
  run sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Installing Docker Compose standalone (compose plugin is included; adding docker-compose for compatibility)..."
  local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
  sudo curl -sL "$compose_url" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose

  log "Docker installed: $(docker --version); Docker Compose: $(docker-compose --version 2>/dev/null || docker compose version)"
}

# -----------------------------------------------------------------------------
# Configure Docker rootless mode (optional; run as non-root user)
# -----------------------------------------------------------------------------
configure_docker_rootless() {
  if [[ -n "${ROOTLESS_DOCKER:-}" && "${ROOTLESS_DOCKER}" == "1" ]]; then
    log "Configuring Docker rootless..."
    if ! command -v dockerd-rootless-setuptool.sh &>/dev/null; then
      run sudo apt-get install -y rootlesskit
      curl -fsSL https://get.docker.com/rootless | sh
    else
      dockerd-rootless-setuptool.sh install
    fi
    log "Rootless Docker configured. Use 'systemctl --user start docker' to run Docker as current user."
  else
    log "Skipping rootless Docker (set ROOTLESS_DOCKER=1 to enable). Using system Docker."
    run sudo systemctl enable docker
    run sudo systemctl start docker
  fi
}

# -----------------------------------------------------------------------------
# Enable and start services: Docker, SSH, FTP
# -----------------------------------------------------------------------------
enable_services() {
  log "Enabling and starting services..."

  # Docker (if not rootless)
  if [[ -z "${ROOTLESS_DOCKER:-}" || "${ROOTLESS_DOCKER}" != "1" ]]; then
    run sudo systemctl enable docker
    run sudo systemctl start docker
  fi

  run sudo systemctl enable ssh
  run sudo systemctl start ssh

  run sudo systemctl enable vsftpd
  run sudo systemctl start vsftpd

  log "Services enabled: docker, ssh, vsftpd"
}

# -----------------------------------------------------------------------------
# Add current user to docker group (avoid sudo for docker)
# -----------------------------------------------------------------------------
add_user_to_docker() {
  if getent group docker &>/dev/null && [[ -n "${SUDO_USER:-}" ]]; then
    run sudo usermod -aG docker "$SUDO_USER"
    log "User $SUDO_USER added to group docker. Log out and back in for it to take effect."
  fi
}

# -----------------------------------------------------------------------------
# Install Bacula Community (Director, Storage Daemon, File Daemon, Console)
# Set INSTALL_BACULA=1 to run this step.
# -----------------------------------------------------------------------------
install_bacula() {
  if [[ -n "${INSTALL_BACULA:-}" && "${INSTALL_BACULA}" == "1" ]]; then
    log "Installing Bacula Community..."
    if [[ -x "${SCRIPT_DIR}/scripts/setup_bacula.sh" ]]; then
      run sudo "${SCRIPT_DIR}/scripts/setup_bacula.sh"
    else
      run bash "${SCRIPT_DIR}/scripts/setup_bacula.sh"
    fi
  else
    log "Skipping Bacula (set INSTALL_BACULA=1 to install Director, SD, FD, Console and WhaleBackup job)."
  fi
}

# -----------------------------------------------------------------------------
# Create log directory and persist
# -----------------------------------------------------------------------------
mkdir -p "${SCRIPT_DIR}/logs"

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "=== WHALE setup.sh started ==="
  detect_os
  install_dependencies
  install_docker
  configure_docker_rootless
  enable_services
  add_user_to_docker
  install_bacula
  log "=== WHALE setup.sh finished successfully ==="
  log "Next: run configure_firewall.sh, then deploy the stack with docker-compose -f docker-compose.whale.yml up -d"
}

main "$@"
