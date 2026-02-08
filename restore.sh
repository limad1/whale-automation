#!/usr/bin/env bash
# =============================================================================
# WHALE - Restore from backups: MySQL, uploads, config
# Usage: ./restore.sh mysql BACKUP_FILE
#        ./restore.sh uploads BACKUP_FILE DEST_PATH
#        ./restore.sh config BACKUP_FILE
#        ./restore.sh project PROJECT_NAME [BACKUP_DATE]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# Restore MySQL from .sql or .sql.gz
# -----------------------------------------------------------------------------
restore_mysql() {
  local backup_file=$1
  [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"
  local root_pass="${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD}"

  log "Restoring MySQL from $backup_file ..."
  if [[ "$backup_file" == *.gz ]]; then
    zcat "$backup_file" | docker exec -i whale-mysql mysql -u root -p"$root_pass"
  else
    docker exec -i whale-mysql mysql -u root -p"$root_pass" < "$backup_file"
  fi
  log "MySQL restore completed."
}

# -----------------------------------------------------------------------------
# Restore uploads/content from .tar.gz
# -----------------------------------------------------------------------------
restore_uploads() {
  local backup_file=$1
  local dest_path=${2:-/tmp/whale_restore}
  [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"
  mkdir -p "$dest_path"
  log "Restoring uploads to $dest_path from $backup_file ..."
  tar -xzf "$backup_file" -C "$dest_path"
  log "Uploads restore completed. Verify and copy to project path if needed."
}

# -----------------------------------------------------------------------------
# Restore config (extract archive to temp and show instructions)
# -----------------------------------------------------------------------------
restore_config() {
  local backup_file=$1
  [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"
  local extract_dir="/tmp/whale_config_restore_$$"
  mkdir -p "$extract_dir"
  tar -xzf "$backup_file" -C "$extract_dir"
  log "Config extracted to $extract_dir. Copy files to whale docker/config paths and reload NGINX."
  echo "  cd $extract_dir && ls -la"
}

# -----------------------------------------------------------------------------
# Restore full project (DB + uploads) by name and optional date
# -----------------------------------------------------------------------------
restore_project() {
  local project_name=$1
  local date_suffix=${2:-}
  local projects_conf="${WHALE_CONFIG}/projects.conf"
  [[ -f "$projects_conf" ]] || die "Projects config not found: $projects_conf"

  local site domain container db_name port
  while IFS='|' read -r site domain container db_name port; do
    [[ "$site" == "$project_name" ]] || continue
    local base="${WHALE_BACKUPS}/projects/${site}"
    local mysql_file uploads_file
    if [[ -n "$date_suffix" ]]; then
      mysql_file="${base}/mysql_${date_suffix}.sql.gz"
      uploads_file="${WHALE_BACKUPS}/uploads/project_${site}_${date_suffix}.tar.gz"
    else
      mysql_file=$(ls -t "${base}"/mysql_*.sql.gz 2>/dev/null | head -1)
      uploads_file=$(ls -t "${WHALE_BACKUPS}"/uploads/project_${site}_*.tar.gz 2>/dev/null | head -1)
    fi
    if [[ -z "$mysql_file" || ! -f "$mysql_file" ]]; then
      die "No MySQL backup found for project $project_name"
    fi
    restore_mysql "$mysql_file"
    if [[ -f "$uploads_file" ]]; then
      restore_uploads "$uploads_file" "${WHALE_PROJECTS}/${project_name}/html.restored"
      log "Move content: sudo mv ${WHALE_PROJECTS}/${project_name}/html.restored/* ${WHALE_PROJECTS}/${project_name}/html/"
    fi
    log "Project $project_name restored."
    return 0
  done < "$projects_conf"
  die "Project not found: $project_name"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
usage() {
  echo "Usage:"
  echo "  $0 mysql BACKUP_FILE"
  echo "  $0 uploads BACKUP_FILE [DEST_PATH]"
  echo "  $0 config BACKUP_FILE"
  echo "  $0 project PROJECT_NAME [BACKUP_DATE]"
  exit 1
}

main() {
  [[ $# -ge 1 ]] || usage
  local cmd=$1
  shift

  local env_file="${WHALE_DOCKER:-$SCRIPT_DIR/docker}/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    source "$env_file"
    set +a
  fi

  case "$cmd" in
    mysql)   [[ $# -ge 1 ]] || usage; restore_mysql "$1" ;;
    uploads) [[ $# -ge 1 ]] || usage; restore_uploads "$1" "${2:-/tmp/whale_restore}" ;;
    config)  [[ $# -ge 1 ]] || usage; restore_config "$1" ;;
    project) [[ $# -ge 1 ]] || usage; restore_project "$1" "${2:-}" ;;
    *)       usage ;;
  esac
}

main "$@"
