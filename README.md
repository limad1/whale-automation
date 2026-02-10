# WHALE - Web Hosting Application Launching Environment

Scripts e Docker Compose para automatizar uma stack de hospedagem WordPress de alta disponibilidade: NGINX, WordPress (escalável), MySQL, Portainer, Grafana, Loki, Promtail, backups e automação por projeto.

## Requisitos

- **Sistema Operacional**: Ubuntu 22.04 LTS ou Debian (outras versões podem funcionar)
- **Privilégios**: Root/sudo para configuração, firewall e criação de usuários
- **Rede**: Portas 80, 443, 22, 21, 3000, 9000, 9090, 3100

## Início Rápido

1. **Preparar ambiente** (instalar Docker, dependências, ativar SSH/FTP):
   ```bash
   sudo ./setup.sh
   ```

2. **Configurar firewall** (UFW/iptables):
   ```bash
   sudo ./configure_firewall.sh
   ```

3. **Implantar a stack principal** (criar `.env` a partir de `docker/.env.example` primeiro):
   ```bash
   cp docker/.env.example docker/.env
   # Edite docker/.env com MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, GRAFANA_ADMIN_PASSWORD
   ./deploy_stack.sh
   ```

4. **Criar um novo projeto WordPress** (usuário, banco de dados, container, vhost NGINX, SSL opcional):
   ```bash
   export MYSQL_ROOT_PASSWORD=your_mysql_root_password
   sudo ./create_project.sh mysite example.com 'FtpPassword'
   ```

5. **Backup** (MySQL, uploads, configurações; executar diariamente via cron):
   ```bash
   export MYSQL_ROOT_PASSWORD=sua_senha_root_mysql
   ./backup.sh all
   ```

6. **Restaurar**:
   ```bash
   ./restore.sh mysql /var/backups/whale/mysql/todos_os_bancos_AAAAMMDD_HHMMSS.sql.gz
   ./restore.sh project meusite
   ```

## Visão Geral dos Scripts

| Script | Finalidade |
|--------|---------|
| `setup.sh` | Detectar Ubuntu/Debian, atualizar apt, instalar dependências (openssh-server, vsftpd, curl, vim, iptables), Docker + Docker Compose, rootless opcional, ativar Docker/SSH/FTP; Bacula opcional quando `INSTALL_BACULA=1` |
| `configure_firewall.sh` | UFW ou iptables: permitir portas 22, 80, 443, 21, 3000, 9000, 9090, 3100 |
| `deploy_stack.sh` | Iniciar stack principal a partir de `docker/docker-compose.whale.yml` |
| `create_project.sh` | Novo site WordPress: usuário `wp_<site>`, home `/var/www/<site>`, banco de dados MySQL, container, vhost NGINX, Let's Encrypt opcional, registro de backup, Uptime Kuma (opcional) |
| `backup.sh` | Backup do MySQL (todos + por projeto), uploads, configurações; retenção (`BACKUP_RETENTION_DAYS`); aciona job Bacula **WhaleBackup** se bconsole estiver disponível |
| `restore.sh` | Restaurar MySQL, uploads, configuração ou projeto completo por nome (suporta `restore.sh project NOME_DO_PROJETO [DATA_DO_BACKUP]`) |

## Stack (docker-compose.whale.yml)

- **NGINX**: Proxy reverso e balanceador de carga (upstream para containers WordPress)
- **WordPress** x2: Portas 8081, 8082 (escalar adicionando serviços)
- **MySQL**: Container único, volume persistente
- **Portainer**: Interface de gerenciamento (porta 9000)
- **Grafana**: Dashboards (porta 3000), fontes de dados: Loki, Prometheus
- **Loki + Promtail**: Logs centralizados de containers e NGINX
- **Prometheus**: Métricas para alertas
- **Uptime Kuma**: Monitoramento de tempo de atividade (porta **3001**); configuração e monitores no volume `uptime-kuma-data`
- **Certbot**: Perfil opcional `ssl` para loop de renovação

## Segurança e Monitoramento

- Firewall permite apenas portas necessárias; restrinja mais conforme necessário.
- Serviços executados como não-root dentro dos containers quando possível.
- Alertas do Grafana: configure na interface (fontes de dados Prometheus/Loki são provisionadas).
- Todos os containers WordPress usam o rótulo `logging=promtail` para o Loki.

## Instalação do Bacula Community

- **setup.sh** pode instalar o Bacula quando `INSTALL_BACULA=1`:
  ```bash
  sudo INSTALL_BACULA=1 ./setup.sh
  ```
- Ou instalar o Bacula separadamente (Director, Storage Daemon, File Daemon e Console):
  ```bash
  sudo ./scripts/setup_bacula.sh
  ```
- **setup_bacula.sh** instala os pacotes do Bacula Community e configura:
  - Director, Storage Daemon, File Daemon e Console (bconsole)
  - Job **WhaleBackup** que faz backup de `WHALE_BACKUPS` (padrão `/var/backups/whale`)
  - Agendamento **WhaleDaily** (Full diário às 03:15)

## Integração de Backup e Bacula

- **`backup.sh all`** realiza backups locais para `WHALE_BACKUPS` (padrão `/var/backups/whale`).
- Se **bconsole** estiver disponível, **backup.sh** aciona um job Bacula chamado **WhaleBackup** (faz backup do mesmo diretório para o armazenamento Bacula).
- **Política de retenção**: `BACKUP_RETENTION_DAYS` (padrão 7) é aplicado aos arquivos de backup locais; a retenção do Bacula é configurada no Bacula (Pool/Schedule).
- **`restore.sh`** suporta a restauração de:
  - **MySQL**: a partir de um arquivo de backup (`restore.sh mysql ARQUIVO_DE_BACKUP`)
  - **Uploads**: a partir de um tarball (`restore.sh uploads ARQUIVO_DE_BACKUP [CAMINHO_DESTINO]`)
  - **Configuração**: extrai arquivo de configuração compactado (`restore.sh config ARQUIVO_DE_BACKUP`)
  - **Projeto completo por nome**: MySQL + uploads para um projeto (`restore.sh project NOME_DO_PROJETO [DATA_DO_BACKUP]`)

## Uptime Kuma – acesso e token

- A stack expõe o **Uptime Kuma** em **http://localhost:3001** (ou http://seu-servidor:3001).
- **Primeiro acesso**: abra o painel → crie o **usuário admin**.
- **API / adicionar monitores automaticamente**: vá para **Configurações → Tokens de API**, crie um token.
- Configure no WHALE (ex., em `docker/.env` ou via `export`):
  ```bash
  export UPTIME_KUMA_URL="http://localhost:3001"
  export UPTIME_KUMA_TOKEN="seu_token_aqui"
  ```
- **create_project.sh** chama `scripts/uptime_kuma.py` ao final da criação do site. Se `UPTIME_KUMA_URL` (e opcionalmente token ou login) estiver definido, o **novo domínio é registrado como um monitor HTTP** no Uptime Kuma para monitoramento de disponibilidade.
- **Alternativa (sem token)**: instale `pip install uptime-kuma-api` e defina `UPTIME_KUMA_USER` e `UPTIME_KUMA_PASSWORD`; o script adicionará monitores via login.

## Variáveis de Ambiente

- **lib/common.sh**: `WHALE_ROOT`, `WHALE_CONFIG`, `WHALE_BACKUPS`, `WHALE_PROJECTS`, `WHALE_LOGS`
- **setup.sh**: `INSTALL_BACULA=1` para instalar o Bacula Community (Director, Storage Daemon, File Daemon, Console)
- **backup.sh**: `BACKUP_RETENTION_DAYS` (padrão 7), `MYSQL_ROOT_PASSWORD` (para dumps do MySQL)
- **docker/.env**: `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_ROOT_URL`, `LETSENCRYPT_EMAIL`
- **Uptime Kuma**: `UPTIME_KUMA_URL` (ex. http://localhost:3001), `UPTIME_KUMA_TOKEN`; ou `UPTIME_KUMA_USER` + `UPTIME_KUMA_PASSWORD` com `pip install uptime-kuma-api` para adicionar monitores automaticamente

## Opcional: Docker Rootless (sem root)

```bash
export ROOTLESS_DOCKER=1
./setup.sh
# Em seguida, execute o Docker como seu usuário: systemctl --user start docker
```

## Estrutura de Arquivos

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
    ├── setup_bacula.sh   # Instala Bacula (Director, SD, FD, Console) + job WhaleBackup
    └── uptime_kuma.py
```

## Entregáveis 

Scripts modulares que preparam o ambiente WHALE, instalam o Bacula (opcional) e permitem a criação de novos sites WordPress com alta disponibilidade, segurança, monitoramento e backup/restauração automatizados:

- **setup.sh** – Preparação do ambiente (Ubuntu/Debian, Docker, dependências, SSH/FTP); instalação opcional do Bacula quando `INSTALL_BACULA=1`.
- **configure_firewall.sh** – Regras de firewall UFW/iptables para as portas necessárias.
- **deploy_stack.sh** – Implanta a stack principal do Docker (NGINX, WordPress, MySQL, Portainer, Loki, Grafana, etc.).
- **create_project.sh** – Cria novo site WordPress (usuário, banco de dados, container, vhost NGINX, SSL, monitoramento).
- **backup.sh** – Backups locais (MySQL, uploads, configurações); retenção; aciona job Bacula **WhaleBackup** quando bconsole estiver disponível.
- **restore.sh** – Restaura MySQL, uploads, configurações ou projeto completo por nome.

## Licença

Use e modifique conforme necessário para o seu ambiente.
