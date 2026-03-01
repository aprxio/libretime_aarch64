# LibreTime Podman Installer (RHEL-family & Fedora)

This directory contains a scripted LibreTime deployment for RHEL-family distributions (RHEL, Rocky Linux, AlmaLinux, Oracle Linux) and Fedora using Podman Compose.

## Files

- `install.sh`: End-to-end installer and bootstrap script.
- `docker-compose.rhel.yml`: Compose template copied to `/opt/libretime/docker-compose.yml`.

## What `install.sh` does

1. Installs container tooling (`podman`, `podman-compose`, `container-tools`) and helper packages.
2. Optionally builds LibreTime app images locally (useful on ARM64).
3. Creates deployment/data directories.
4. Sets required ownership/permissions:
   - `postgres` data: `999:999`
   - `storage` + `playout`: `1000:1000`, mode `775`
5. Writes `/opt/libretime/.env` secrets (if missing).
6. Downloads `config.template.yml` and `nginx.conf` for the selected LibreTime version.
7. Generates/updates `/opt/libretime/config.yml`.
8. Runs DB migrations and starts services.
9. Installs and enables `libretime-compose.service`.
10. Opens firewall ports `8080`, `8000`, `8001`, `8002` when `firewalld` is active.

## Prerequisites

- RHEL-family (RHEL, Rocky Linux, AlmaLinux, Oracle Linux) or Fedora host (script is tuned for these; warns on other distros).
- `sudo` access.
- Outbound network access to:
  - `github.com` (release tarball and templates)
  - `ghcr.io` (container images, unless building locally)

## Quick start (interactive)

```bash
cd /home/psams/apps/libretime
chmod +x install.sh
./install.sh
```

Prompts:

- `PUBLIC_URL` (required)
- `TIMEZONE`
- `DATA_DIR` (host persistent root; default `/data/libretime`)
- `API_KEY` (default auto-generated)
- `SECRET_KEY` (default auto-generated)
- `BUILD_LIBRETIME_IMAGES` (`auto|yes|no`)

Note: `storage.path` is fixed to `/srv/libretime` inside containers.

## Non-interactive install

```bash
cd /home/psams/apps/libretime
PUBLIC_URL="https://radio.example.com" \
TIMEZONE="UTC" \
DATA_DIR="/data/libretime" \
LIBRETIME_VERSION="4.5.0" \
BUILD_LIBRETIME_IMAGES="no" \
./install.sh
```

Required in non-interactive mode:

- `PUBLIC_URL`

Optional env vars:

- `DEPLOY_DIR` (default `/opt/libretime`)
- `DATA_DIR` (default `/data/libretime`)
- `LIBRETIME_VERSION` (default `4.5.0`)
- `TIMEZONE` (default `UTC`)
- `BUILD_LIBRETIME_IMAGES` (default `auto`)
- `SOURCE_CACHE_DIR` (default `/tmp`)
- `API_KEY`, `SECRET_KEY` (auto-generated if unset)

## Service management

Systemd unit:

- `/etc/systemd/system/libretime-compose.service`

Commands:

```bash
sudo systemctl status libretime-compose.service
sudo systemctl restart libretime-compose.service
sudo systemctl stop libretime-compose.service
sudo systemctl start libretime-compose.service
```

Compose runtime directory:

- `/opt/libretime`

Manual compose commands:

```bash
cd /opt/libretime
sudo podman compose -f docker-compose.yml ps
sudo podman compose -f docker-compose.yml logs -f api
```

## Reload after `config.yml` changes

`config.yml` is mounted into containers, but most services need a restart to apply changes.

Preferred (systemd-managed):

```bash
sudo systemctl restart libretime-compose.service
```

Direct compose restart from deploy directory:

```bash
cd /opt/libretime
sudo podman compose -f docker-compose.yml up -d --force-recreate
```

If you changed only stream/playout behavior and want minimal disruption, restart just playout components:

```bash
cd /opt/libretime
sudo podman compose -f docker-compose.yml restart playout liquidsoap
```

## Access

- Web UI: `http://<server-ip>:8080`
- Default login: `admin / admin` (change immediately)

## Troubleshooting

### 1) API/playout cannot resolve service names (`Temporary failure in name resolution`)

Symptoms:

- `requests.exceptions.ConnectionError ... host='nginx'`
- `psycopg.OperationalError: [Errno -3] Temporary failure in name resolution`

Checks:

```bash
sudo podman network inspect libretime_default
sudo podman exec libretime_api_1 python3 -c "import socket; print(socket.gethostbyname('postgres'))"
```

Expected:

- Containers attached to `libretime_default`
- Service names resolve (`postgres`, `rabbitmq`, `nginx`, etc.)

### 2) Browser warning: `configured storage.path '/srv/libretime/' is not writable`

Fix host permissions:

```bash
sudo chown -R 1000:1000 /data/libretime/storage /data/libretime/playout
sudo chmod 775 /data/libretime/storage /data/libretime/playout
```

Verify from container:

```bash
sudo podman exec libretime_api_1 sh -lc "id; ls -ld /srv/libretime"
```

Expected:

- UID/GID `1000:1000` owner on `/srv/libretime` mount
- Writable by container user `libretime`

### 3) Refresh deployment after compose/template changes

```bash
cd /opt/libretime
sudo podman compose -f docker-compose.yml down
sudo podman compose -f docker-compose.yml up -d
```
