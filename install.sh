#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/libretime}"
DATA_DIR="${DATA_DIR:-/data/libretime}"
LIBRETIME_VERSION="${LIBRETIME_VERSION:-4.5.0}"
PUBLIC_URL="${PUBLIC_URL:-}"
TIMEZONE="${TIMEZONE:-UTC}"
BUILD_LIBRETIME_IMAGES="${BUILD_LIBRETIME_IMAGES:-auto}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-/tmp}"
API_KEY="${API_KEY:-}"
SECRET_KEY="${SECRET_KEY:-}"
ENV_FILE="$DEPLOY_DIR/.env"
COMPOSE_SRC="$SCRIPT_DIR/docker-compose.rhel.yml"
COMPOSE_DST="$DEPLOY_DIR/docker-compose.yml"
SYSTEMD_UNIT="/etc/systemd/system/libretime-compose.service"

if [[ ! -f "$COMPOSE_SRC" ]]; then
  echo "Missing compose source: $COMPOSE_SRC" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required." >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS: /etc/os-release not found." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
supported_ids=("ol" "rhel" "rocky" "fedora" "centos" "alma")
if [[ ! " ${supported_ids[@]} " =~ " ${ID:-} " ]]; then
  echo "Warning: This installer is tuned for RHEL-family and Fedora distributions. Detected ID=${ID:-unknown}."
fi

prompt_required() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local value=""
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ -n "$value" ]]; then
      printf -v "$var_name" "%s" "$value"
      return 0
    fi
    echo "Value cannot be empty."
  done
}

if [[ -t 0 ]]; then
  echo "Collecting required LibreTime settings..."
  prompt_required PUBLIC_URL "Public URL (example: https://radio.example.com)" "${PUBLIC_URL:-http://localhost:8080}"
  prompt_required TIMEZONE "Timezone (IANA, example: America/New_York)" "$TIMEZONE"
  prompt_required DATA_DIR "Host data root path for persistent mounts" "$DATA_DIR"
  prompt_required API_KEY "LibreTime general.api_key (leave default to auto-generate)" "${API_KEY:-$(openssl rand -hex 32)}"
  prompt_required SECRET_KEY "LibreTime general.secret_key (leave default to auto-generate)" "${SECRET_KEY:-$(openssl rand -hex 32)}"
  if [[ "$BUILD_LIBRETIME_IMAGES" == "auto" ]]; then
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
      prompt_required BUILD_LIBRETIME_IMAGES "Build LibreTime app images locally for ARM64? (yes/no)" "yes"
    else
      prompt_required BUILD_LIBRETIME_IMAGES "Build LibreTime app images locally? (yes/no)" "no"
    fi
  fi
else
  if [[ -z "$PUBLIC_URL" ]]; then
    echo "PUBLIC_URL is required in non-interactive mode." >&2
    exit 1
  fi
  if [[ -z "$API_KEY" ]]; then
    API_KEY="$(openssl rand -hex 32)"
  fi
  if [[ -z "$SECRET_KEY" ]]; then
    SECRET_KEY="$(openssl rand -hex 32)"
  fi
fi

case "${BUILD_LIBRETIME_IMAGES,,}" in
  yes|y|true|1) BUILD_LIBRETIME_IMAGES="yes" ;;
  no|n|false|0) BUILD_LIBRETIME_IMAGES="no" ;;
  auto)
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
      BUILD_LIBRETIME_IMAGES="yes"
    else
      BUILD_LIBRETIME_IMAGES="no"
    fi
    ;;
  *)
    echo "Invalid BUILD_LIBRETIME_IMAGES value: $BUILD_LIBRETIME_IMAGES (use auto|yes|no)" >&2
    exit 1
    ;;
esac

echo "Installing container tooling..."
if [[ "$ID" == "fedora" ]]; then
  sudo dnf -y install podman podman-compose gettext curl openssl
elif [[ "${VERSION_ID%%.*}" == "8" ]]; then
  sudo dnf -y module install container-tools:el8
  sudo dnf -y install podman-compose gettext curl openssl
elif [[ "${VERSION_ID%%.*}" == "9" ]]; then
  sudo dnf -y install podman podman-compose gettext curl openssl
else
  sudo dnf -y install container-tools podman-compose gettext curl openssl
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "podman not found after install." >&2
  exit 1
fi

if [[ "$BUILD_LIBRETIME_IMAGES" == "yes" ]]; then
  echo "Building LibreTime images locally for this architecture..."
  SRC_ARCHIVE="$SOURCE_CACHE_DIR/libretime-${LIBRETIME_VERSION}.tar.gz"
  SRC_DIR="$SOURCE_CACHE_DIR/libretime-${LIBRETIME_VERSION}"

  rm -rf "$SRC_DIR"
  curl -fsSLo "$SRC_ARCHIVE" "https://github.com/libretime/libretime/archive/refs/tags/${LIBRETIME_VERSION}.tar.gz"
  tar -xzf "$SRC_ARCHIVE" -C "$SOURCE_CACHE_DIR"

  # Tarball extracts to libretime-<version> directory.
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "Expected source directory not found: $SRC_DIR" >&2
    exit 1
  fi

  for target in analyzer playout api worker legacy nginx; do
    echo "Building ghcr.io/libretime/libretime-${target}:${LIBRETIME_VERSION} ..."
    sudo podman build \
      --pull \
      --target "libretime-${target}" \
      --build-arg "LIBRETIME_VERSION=${LIBRETIME_VERSION}" \
      -t "ghcr.io/libretime/libretime-${target}:${LIBRETIME_VERSION}" \
      "$SRC_DIR"
  done
fi

echo "Preparing directories..."
sudo mkdir -p "$DEPLOY_DIR"
sudo mkdir -p "$DATA_DIR/postgres" "$DATA_DIR/storage" "$DATA_DIR/playout"
sudo chown -R 999:999 "$DATA_DIR/postgres"
sudo chown -R 1000:1000 "$DATA_DIR/storage" "$DATA_DIR/playout"
sudo chmod 775 "$DATA_DIR/storage" "$DATA_DIR/playout"
sudo cp "$COMPOSE_SRC" "$COMPOSE_DST"
if [[ "$DATA_DIR" != "/data/libretime" ]]; then
  sudo sed -i "s|/data/libretime|$DATA_DIR|g" "$COMPOSE_DST"
fi

TARGET_USER="${SUDO_USER:-$USER}"
if id "$TARGET_USER" >/dev/null 2>&1; then
  sudo chown -R "$TARGET_USER:$TARGET_USER" "$DEPLOY_DIR"
fi

mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

touch "$ENV_FILE"

set_or_append_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf "%s=%s\n" "$key" "$value" >>"$ENV_FILE"
  fi
}

set_if_empty_secret() {
  local key="$1"
  local current
  current="$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  if [[ -z "$current" ]]; then
    set_or_append_env "$key" "$(openssl rand -hex 16)"
  fi
}

set_or_append_env "LIBRETIME_VERSION" "$LIBRETIME_VERSION"
set_or_append_env "POSTGRES_USER" "libretime"
set_or_append_env "RABBITMQ_DEFAULT_USER" "libretime"
set_or_append_env "RABBITMQ_DEFAULT_VHOST" "/libretime"
set_or_append_env "API_KEY" "$API_KEY"
set_or_append_env "SECRET_KEY" "$SECRET_KEY"
set_if_empty_secret "POSTGRES_PASSWORD"
set_if_empty_secret "RABBITMQ_DEFAULT_PASS"
set_if_empty_secret "ICECAST_SOURCE_PASSWORD"
set_if_empty_secret "ICECAST_ADMIN_PASSWORD"
set_if_empty_secret "ICECAST_RELAY_PASSWORD"

echo "Downloading LibreTime templates..."
curl -fsSLo "$DEPLOY_DIR/config.template.yml" \
  "https://raw.githubusercontent.com/libretime/libretime/$LIBRETIME_VERSION/docker/config.template.yml"
curl -fsSLo "$DEPLOY_DIR/nginx.conf" \
  "https://raw.githubusercontent.com/libretime/libretime/$LIBRETIME_VERSION/docker/nginx.conf"

if [[ ! -f "$DEPLOY_DIR/config.yml" ]]; then
  echo "Generating config.yml from template..."
  bash -a -c "source '$ENV_FILE'; envsubst < '$DEPLOY_DIR/config.template.yml' > '$DEPLOY_DIR/config.yml'"
fi

set_yaml_top_level_key() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section=0; updated=0 }
    $0 ~ "^" section ":[[:space:]]*$" { in_section=1; print; next }
    in_section && $0 ~ "^[^[:space:]].*:[[:space:]]*$" { in_section=0 }
    in_section && $0 ~ "^[[:space:]]{2}" key ":[[:space:]]*" {
      print "  " key ": " value
      updated=1
      next
    }
    { print }
    END { if (updated == 0) exit 10 }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

echo "Applying required settings to config.yml..."
set_yaml_top_level_key "$DEPLOY_DIR/config.yml" "general" "public_url" "$PUBLIC_URL"
set_yaml_top_level_key "$DEPLOY_DIR/config.yml" "general" "api_key" "$API_KEY"
set_yaml_top_level_key "$DEPLOY_DIR/config.yml" "general" "secret_key" "$SECRET_KEY"
set_yaml_top_level_key "$DEPLOY_DIR/config.yml" "general" "timezone" "$TIMEZONE"
set_yaml_top_level_key "$DEPLOY_DIR/config.yml" "storage" "path" "/srv/libretime"

COMPOSE_CMD=()
SYSTEMD_EXEC_START=""
SYSTEMD_EXEC_STOP=""
if podman compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(podman compose -f docker-compose.yml)
  SYSTEMD_EXEC_START="/usr/bin/podman compose -f docker-compose.yml up -d"
  SYSTEMD_EXEC_STOP="/usr/bin/podman compose -f docker-compose.yml down"
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(podman-compose -f docker-compose.yml)
  SYSTEMD_EXEC_START="/usr/bin/podman-compose -f docker-compose.yml up -d"
  SYSTEMD_EXEC_STOP="/usr/bin/podman-compose -f docker-compose.yml down"
else
  echo "Neither 'podman compose' nor 'podman-compose' is available." >&2
  exit 1
fi

echo "Running database migrations and starting services..."
sudo "${COMPOSE_CMD[@]}" run --rm api libretime-api migrate
sudo "${COMPOSE_CMD[@]}" up -d

echo "Writing systemd unit..."
sudo tee "$SYSTEMD_UNIT" >/dev/null <<EOF
[Unit]
Description=LibreTime stack (Podman Compose)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DEPLOY_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$SYSTEMD_EXEC_START
ExecStop=$SYSTEMD_EXEC_STOP
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now libretime-compose.service

if systemctl is-active --quiet firewalld; then
  echo "Configuring firewalld..."
  sudo firewall-cmd --permanent --add-port=8080/tcp
  sudo firewall-cmd --permanent --add-port=8000/tcp
  sudo firewall-cmd --permanent --add-port=8001/tcp
  sudo firewall-cmd --permanent --add-port=8002/tcp
  sudo firewall-cmd --reload
fi

echo "Done."
echo "Web UI: http://<server-ip>:8080"
echo "Default login: admin / admin (change immediately)."
echo "Configured public_url: $PUBLIC_URL"
echo "Configured timezone: $TIMEZONE"
echo "Configured storage.path: /srv/libretime"
echo "Configured host data root: $DATA_DIR"
