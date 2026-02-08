#!/usr/bin/env bash
# =============================================================================
# WHALE - Automated backup: MySQL, WordPress uploads, configs (Docker, NGINX)
# Usage: ./backup.sh [all|mysql|uploads|config|PROJECT_NAME]
# Run via cron: 0 2 * * * /opt/whale/backup.sh all
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

# -----------------------------------------------------------------------------
# Backup MySQL (all databases or single DB)
# -----------------------------------------------------------------------------
backup_mysql() {
  local out_dir="${WHALE_BACKUPS}/mysql"
  mkdir -p "$out_dir"
  local root_pass="${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD}"

  docker exec whale-mysql mysqldump -u root -p"$root_pass" --all-databases --single-transaction --routines --triggers \
    | gzip > "${out_dir}/all_databases_${BACKUP_DATE}.sql.gz"
  log "MySQL backup: ${out_dir}/all_databases_${BACKUP_DATE}.sql.gz"
}

# -----------------------------------------------------------------------------
# Backup single project database
# -----------------------------------------------------------------------------
backup_project_mysql() {
  local db_name=$1
  local site=$2
  local out_dir="${WHALE_BACKUPS}/projects/${site}"
  mkdir -p "$out_dir"
  local root_pass="${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD}"

  docker exec whale-mysql mysqldump -u root -p"$root_pass" --databases "$db_name" --single-transaction \
    | gzip > "${out_dir}/mysql_${BACKUP_DATE}.sql.gz"
  log "MySQL backup ($db_name): ${out_dir}/mysql_${BACKUP_DATE}.sql.gz"
}

# -----------------------------------------------------------------------------
# Backup WordPress uploads and content (per project or main stack)
# -----------------------------------------------------------------------------
backup_uploads() {
  local source_path=$1
  local name=$2
  local out_dir="${WHALE_BACKUPS}/uploads"
  mkdir -p "$out_dir"
  if [[ -d "$source_path" ]]; then
    tar -czf "${out_dir}/${name}_${BACKUP_DATE}.tar.gz" -C "$(dirname "$source_path")" "$(basename "$source_path")"
    log "Uploads backup ($name): ${out_dir}/${name}_${BACKUP_DATE}.tar.gz"
  else
    log "Skip uploads (not found): $source_path"
  fi
}

# -----------------------------------------------------------------------------
# Backup configs: Docker Compose, NGINX, env
# -----------------------------------------------------------------------------
backup_config() {
  local out_dir="${WHALE_BACKUPS}/config"
  mkdir -p "$out_dir"
  local whale_docker="${WHALE_DOCKER:-$SCRIPT_DIR/docker}"
  local config_src=(
    "${whale_docker}/docker-compose.whale.yml"
    "${whale_docker}/nginx/conf.d"
    "${whale_docker}/nginx/nginx.conf"
    "${WHALE_CONFIG}"
  )
  local list_file="${out_dir}/config_${BACKUP_DATE}.list"
  : > "$list_file"
  for path in "${config_src[@]}"; do
    if [[ -e "$path" ]]; then
      echo "$path" >> "$list_file"
    fi
  done
  tar -czf "${out_dir}/config_${BACKUP_DATE}.tar.gz" -C / -T "$list_file" 2>/dev/null || \
    tar -czf "${out_dir}/config_${BACKUP_DATE}.tar.gz" -C "${whale_docker}" . 2>/dev/null
  log "Config backup: ${out_dir}/config_${BACKUP_DATE}.tar.gz"
}

# -----------------------------------------------------------------------------
# Retention: remove backups older than RETENTION_DAYS
# -----------------------------------------------------------------------------
apply_retention() {
  find "${WHALE_BACKUPS}" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  log "Retention applied: removed backups older than $RETENTION_DAYS days"
}

# -----------------------------------------------------------------------------
# Bacula: optionally trigger Bacula backup job (if client configured)
# -----------------------------------------------------------------------------
bacula_backup() {
  if command -v bconsole &>/dev/null; then
    echo "run job=WhaleBackup yes" | bconsole || log "Bacula run skipped (bconsole not configured)"
  else
    log "Bacula not installed; using local backups only"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  local target="${1:-all}"
  mkdir -p "${WHALE_BACKUPS}" "${WHALE_LOGS}"

  if [[ -f "${WHALE_DOCKER:-$SCRIPT_DIR/docker}/.env" ]]; then
    set -a
    source "${WHALE_DOCKER:-$SCRIPT_DIR/docker}/.env"
    set +a
  fi

  case "$target" in
    all)
      backup_mysql
      backup_config
      # Main stack WordPress volumes (docker volumes - need to backup from container or host path)
      for vol in wp1_data wp2_data; do
        local mount
        mount=$(docker volume inspect "whale_${vol}" --format '{{ .Mountpoint }}' 2>/dev/null) || true
        if [[ -n "$mount" && -d "$mount" ]]; then
          backup_uploads "$mount" "$vol"
        fi
      done
      # Per-project backups from projects.conf
      local projects_conf="${WHALE_CONFIG}/projects.conf"
      if [[ -f "$projects_conf" ]]; then
        while IFS='|' read -r site domain _ db_name _; do
          [[ -z "$site" || "$site" =~ ^# ]] && continue
          backup_project_mysql "$db_name" "$site"
          backup_uploads "${WHALE_PROJECTS}/${site}/html" "project_${site}"
        done < "$projects_conf"
      fi
      apply_retention
      bacula_backup
      ;;
    mysql)   backup_mysql; apply_retention ;;
    uploads) backup_uploads "${2:-/var/www}" "${3:-uploads}"; apply_retention ;;
    config)  backup_config; apply_retention ;;
    *)
      # Treat as project name
      if [[ -f "${WHALE_CONFIG}/projects.conf" ]]; then
        while IFS='|' read -r site domain _ db_name _; do
          [[ "$site" == "$target" ]] || continue
          backup_project_mysql "$db_name" "$site"
          backup_uploads "${WHALE_PROJECTS}/${site}/html" "project_${site}"
          apply_retention
          exit 0
        done < "${WHALE_CONFIG}/projects.conf"
      fi
      die "Unknown target: $target (use: all|mysql|uploads|config|PROJECT_NAME)"
      ;;
  esac
  log "Backup finished: $target"
}

main "$@"
