# WHALE - Web Hosting Application Launching Environment

Scripts and Docker Compose to automate a high-availability WordPress hosting stack: NGINX, WordPress (scalable), MySQL, Portainer, Grafana, Loki, Promtail, backups, and per-project automation.

## Requirements

- **OS**: Ubuntu 22.04 LTS or Debian (other versions may work)
- **Privileges**: Root/sudo for setup, firewall, and user creation
- **Network**: Ports 80, 443, 22, 21, 3000, 9000, 9090, 3100

## Quick Start

1. **Prepare environment** (install Docker, dependencies, enable SSH/FTP):
   ```bash
   sudo ./setup.sh
   ```

2. **Configure firewall** (UFW/iptables):
   ```bash
   sudo ./configure_firewall.sh
   ```

3. **Deploy the main stack** (create `.env` from `docker/.env.example` first):
   ```bash
   cp docker/.env.example docker/.env
   # Edit docker/.env with MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, GRAFANA_ADMIN_PASSWORD
   ./deploy_stack.sh
   ```

4. **Create a new WordPress project** (user, DB, container, NGINX vhost, optional SSL):
   ```bash
   export MYSQL_ROOT_PASSWORD=your_mysql_root_password
   sudo ./create_project.sh mysite example.com 'FtpPassword'
   ```

5. **Backup** (MySQL, uploads, configs; run daily via cron):
   ```bash
   export MYSQL_ROOT_PASSWORD=your_mysql_root_password
   ./backup.sh all
   ```

6. **Restore**:
   ```bash
   ./restore.sh mysql /var/backups/whale/mysql/all_databases_YYYYMMDD_HHMMSS.sql.gz
   ./restore.sh project mysite
   ```

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `setup.sh` | Detect Ubuntu/Debian, apt update, install deps (openssh-server, vsftpd, curl, vim, iptables), Docker + Docker Compose, optional rootless, enable Docker/SSH/FTP; optional Bacula when `INSTALL_BACULA=1` |
| `configure_firewall.sh` | UFW or iptables: allow 22, 80, 443, 21, 3000, 9000, 9090, 3100 |
| `deploy_stack.sh` | Start main stack from `docker/docker-compose.whale.yml` |
| `create_project.sh` | New WordPress site: user `wp_<site>`, home `/var/www/<site>`, MySQL DB, container, NGINX vhost, optional Let's Encrypt, backup registration, Uptime Kuma (optional) |
| `backup.sh` | Backup MySQL (all + per-project), uploads, configs; retention (`BACKUP_RETENTION_DAYS`); trigger Bacula job **WhaleBackup** if bconsole available |
| `restore.sh` | Restore MySQL, uploads, config, or full project by name (supports `restore.sh project PROJECT_NAME [BACKUP_DATE]`) |

## Stack (docker-compose.whale.yml)

- **NGINX**: Reverse proxy and load balancer (upstream to WordPress containers)
- **WordPress** x2: Ports 8081, 8082 (scale by adding services)
- **MySQL**: Single container, persistent volume
- **Portainer**: Management UI (port 9000)
- **Grafana**: Dashboards (port 3000), datasources: Loki, Prometheus
- **Loki + Promtail**: Centralized logs from containers and NGINX
- **Prometheus**: Metrics for alerts
- **Uptime Kuma**: Uptime monitoring (port **3001**); config and monitors in volume `uptime-kuma-data`
- **Certbot**: Optional profile `ssl` for renewal loop

## Security and Monitoring

- Firewall allows only required ports; restrict further as needed.
- Services run as non-root inside containers where possible.
- Grafana alerts: configure in UI (Prometheus/Loki datasources are provisioned).
- All WordPress containers use the `logging=promtail` label for Loki.

## Bacula Community installation

- **setup.sh** can install Bacula when `INSTALL_BACULA=1`:
  ```bash
  sudo INSTALL_BACULA=1 ./setup.sh
  ```
- Or install Bacula separately (Director, Storage Daemon, File Daemon, and Console):
  ```bash
  sudo ./scripts/setup_bacula.sh
  ```
- **setup_bacula.sh** installs Bacula Community packages and configures:
  - Director, Storage Daemon, File Daemon, and Console (bconsole)
  - Job **WhaleBackup** that backs up `WHALE_BACKUPS` (default `/var/backups/whale`)
  - Schedule **WhaleDaily** (Full daily at 03:15)

## Backup and Bacula integration

- **`backup.sh all`** performs local backups to `WHALE_BACKUPS` (default `/var/backups/whale`).
- If **bconsole** is available, **backup.sh** triggers a Bacula job named **WhaleBackup** (backs up the same directory to Bacula storage).
- **Retention policy**: `BACKUP_RETENTION_DAYS` (default 7) is applied to local backup files; Bacula retention is configured in Bacula (Pool/Schedule).
- **`restore.sh`** supports restoring:
  - **MySQL**: from a backup file (`restore.sh mysql BACKUP_FILE`)
  - **Uploads**: from a tarball (`restore.sh uploads BACKUP_FILE [DEST_PATH]`)
  - **Config**: extract config archive (`restore.sh config BACKUP_FILE`)
  - **Full project by name**: MySQL + uploads for a project (`restore.sh project PROJECT_NAME [BACKUP_DATE]`)

## Uptime Kuma – access and token

- The stack exposes **Uptime Kuma** at **http://localhost:3001** (or http://seu-servidor:3001).
- **First access**: open the panel → create the **admin user**.
- **API / auto-add monitors**: go to **Settings → API Tokens**, create a token.
- Configure in WHALE (e.g. in `docker/.env` or `export`):
  ```bash
  export UPTIME_KUMA_URL="http://localhost:3001"
  export UPTIME_KUMA_TOKEN="seu_token_aqui"
  ```
- **create_project.sh** calls `scripts/uptime_kuma.py` at the end of site creation. If `UPTIME_KUMA_URL` (and optionally token or login) is set, the **new domain is registered as an HTTP monitor** in Uptime Kuma for availability monitoring.
- **Alternative (no token)**: install `pip install uptime-kuma-api` and set `UPTIME_KUMA_USER` and `UPTIME_KUMA_PASSWORD`; the script will add monitors via login.

## Environment Variables

- **lib/common.sh**: `WHALE_ROOT`, `WHALE_CONFIG`, `WHALE_BACKUPS`, `WHALE_PROJECTS`, `WHALE_LOGS`
- **setup.sh**: `INSTALL_BACULA=1` to install Bacula Community (Director, Storage Daemon, File Daemon, Console)
- **backup.sh**: `BACKUP_RETENTION_DAYS` (default 7), `MYSQL_ROOT_PASSWORD` (for MySQL dumps)
- **docker/.env**: `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_ROOT_URL`, `LETSENCRYPT_EMAIL`
- **Uptime Kuma**: `UPTIME_KUMA_URL` (e.g. http://localhost:3001), `UPTIME_KUMA_TOKEN`; or `UPTIME_KUMA_USER` + `UPTIME_KUMA_PASSWORD` with `pip install uptime-kuma-api` for auto-add monitors

## Optional: Docker Rootless

```bash
export ROOTLESS_DOCKER=1
./setup.sh
# Then run Docker as your user: systemctl --user start docker
```

## File Layout

```
whale-automation/
├── setup.sh
├── configure_firewall.sh
├── deploy_stack.sh
├── create_project.sh
├── backup.sh
├── restore.sh
├── lib/
│   └── common.sh
├── config/
│   └── projects.conf
├── templates/
│   ├── nginx-vhost.conf
│   └── nginx-vhost-http-only.conf
├── docker/
│   ├── docker-compose.whale.yml
│   ├── .env.example
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── conf.d/
│   └── monitor/
│       ├── loki-config.yaml
│       ├── promtail-config.yaml
│       ├── prometheus.yml
│       └── grafana/provisioning/datasources/
└── scripts/
    ├── setup_bacula.sh   # Install Bacula (Director, SD, FD, Console) + WhaleBackup job
    └── uptime_kuma.py
```

## Deliverables

Modular scripts that prepare the WHALE environment, install Bacula (optional), and allow creation of new WordPress sites with high availability, security, monitoring, and automated backup/restore:

- **setup.sh** – Environment preparation (Ubuntu/Debian, Docker, dependencies, SSH/FTP); optional Bacula install when `INSTALL_BACULA=1`.
- **configure_firewall.sh** – UFW/iptables rules for required ports.
- **deploy_stack.sh** – Deploy the main Docker stack (NGINX, WordPress, MySQL, Portainer, Loki, Grafana, etc.).
- **create_project.sh** – Create new WordPress site (user, DB, container, NGINX vhost, SSL, monitoring).
- **backup.sh** – Local backups (MySQL, uploads, configs); retention; trigger Bacula job **WhaleBackup** when bconsole is available.
- **restore.sh** – Restore MySQL, uploads, configs, or full project by name.

## License

Use and modify as needed for your environment.
