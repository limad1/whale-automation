#!/usr/bin/env python3
"""
WHALE - Uptime Kuma: register HTTP monitors for new projects.
Called by create_project.sh after creating a site so the domain is monitored.

Usage: python3 uptime_kuma.py add DOMAIN URL
Example: python3 uptime_kuma.py add example.com https://example.com

Environment (set in .env or export):
  UPTIME_KUMA_URL   - Base URL (e.g. http://localhost:3001 or http://seu-servidor:3001)
  UPTIME_KUMA_TOKEN - API token (Settings → API Tokens). If not set, uses login.
  UPTIME_KUMA_USER  - Admin username (optional, for login when token not used)
  UPTIME_KUMA_PASSWORD - Admin password (optional)

Setup:
  1. Open Uptime Kuma: http://seu-servidor:3001
  2. Create admin user (first run)
  3. Settings → API Tokens → Create token
  4. export UPTIME_KUMA_URL="http://seu-servidor:3001"
  5. export UPTIME_KUMA_TOKEN="seu_token_aqui"
"""
import os
import sys
import json
import urllib.request
import urllib.error

def get_config():
    base = os.environ.get("UPTIME_KUMA_URL", "").rstrip("/")
    token = os.environ.get("UPTIME_KUMA_TOKEN", "")
    user = os.environ.get("UPTIME_KUMA_USER", "")
    password = os.environ.get("UPTIME_KUMA_PASSWORD", "")
    return base, token, user, password

def add_monitor_via_api_library(base: str, domain: str, url: str, user: str, password: str) -> bool:
    """Use uptime-kuma-api library (login + add_monitor). Install: pip install uptime-kuma-api"""
    try:
        from uptime_kuma_api import UptimeKumaApi, MonitorType
    except ImportError:
        return False
    try:
        api = UptimeKumaApi(base)
        api.login(user, password)
        api.add_monitor(type=MonitorType.HTTP, name=domain, url=url)
        api.disconnect()
        return True
    except Exception as e:
        print(f"Uptime Kuma API (library) error: {e}", file=sys.stderr)
        return False

def add_monitor(domain: str, url: str) -> bool:
    base, token, user, password = get_config()
    if not base:
        print("Set UPTIME_KUMA_URL (e.g. http://localhost:3001) to register monitors.", file=sys.stderr)
        return False

    # 1) Prefer uptime-kuma-api library with login (reliable; install: pip install uptime-kuma-api)
    if user and password:
        if add_monitor_via_api_library(base, domain, url, user, password):
            return True

    # 2) Try token-based REST (if Uptime Kuma adds this in future)
    if token:
        try:
            api_url = f"{base}/api/monitors"
            data = json.dumps({
                "type": "http",
                "name": domain,
                "url": url,
            }).encode("utf-8")
            req = urllib.request.Request(
                api_url,
                data=data,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {token}",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.status in (200, 201):
                    return True
        except (urllib.error.HTTPError, OSError):
            pass

    # 3) Instruct user to add manually or use library
    print(f"Add monitor in Uptime Kuma ({base}):", file=sys.stderr)
    print(f"  Name: {domain}  URL: {url}", file=sys.stderr)
    print("  For auto-add: pip install uptime-kuma-api and set UPTIME_KUMA_USER + UPTIME_KUMA_PASSWORD", file=sys.stderr)
    return False

def main():
    if len(sys.argv) < 4 or sys.argv[1].lower() != "add":
        print("Usage: uptime_kuma.py add DOMAIN URL", file=sys.stderr)
        sys.exit(1)
    domain, url = sys.argv[2], sys.argv[3]
    ok = add_monitor(domain, url)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
