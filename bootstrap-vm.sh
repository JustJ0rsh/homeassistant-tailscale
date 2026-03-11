#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
TIMEZONE_NAME="${TIMEZONE_NAME:-}"
COMPOSE_CMD=""
REPO_UPDATE=${REPO_UPDATE:-1}
IMAGE_REFRESH=${IMAGE_REFRESH:-1}
PRUNE_IMAGES=${PRUNE_IMAGES:-0}
FORCE_RECREATE=${FORCE_RECREATE:-1}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run this script as root"
  fi
}

require_alpine() {
  if [ ! -f /etc/alpine-release ]; then
    fail "this script currently supports Alpine Linux only"
  fi
  command -v apk >/dev/null 2>&1 || fail "apk is required on Alpine"
}

set_alpine_repositories() {
  if [ ! -f /etc/apk/repositories ]; then
    fail "missing /etc/apk/repositories"
  fi

  log "Configuring Alpine repositories to kernel mirror v3.23..."
  cat <<'EOF' > /etc/apk/repositories
https://mirrors.edge.kernel.org/alpine/v3.23/main
https://mirrors.edge.kernel.org/alpine/v3.23/community
EOF
}

install_docker_packages() {
  if apk add --no-cache docker docker-cli-compose git tzdata; then
    return
  fi

  log "docker-cli-compose package unavailable, trying fallback package names..."
  if apk add --no-cache docker docker-compose git tzdata; then
    return
  fi

  fail "failed to install required Alpine packages (docker, compose, git, tzdata). Check /etc/apk/repositories and network connectivity."
}

install_or_update_packages() {
  set_alpine_repositories

  log "Updating package indexes and installed packages..."
  apk update
  apk upgrade --available
  install_docker_packages
}

configure_timezone() {
  if [ -z "$TIMEZONE_NAME" ] && [ -f /etc/timezone ]; then
    TIMEZONE_NAME=$(cat /etc/timezone)
  fi
  TIMEZONE_NAME="${TIMEZONE_NAME:-America/Chicago}"

  zoneinfo_path="/usr/share/zoneinfo/$TIMEZONE_NAME"
  if [ ! -f "$zoneinfo_path" ]; then
    fail "timezone data not found for $TIMEZONE_NAME"
  fi

  if [ -d /etc/localtime ]; then
    rm -rf /etc/localtime
  else
    rm -f /etc/localtime
  fi
  ln -s "$zoneinfo_path" /etc/localtime
  printf '%s\n' "$TIMEZONE_NAME" > /etc/timezone
  printf '%s\n' "export TZ=$TIMEZONE_NAME" > /etc/profile.d/10timezone.sh

  log "Timezone set to $TIMEZONE_NAME"
}

warn_if_low_disk() {
  available_kb=$(df -Pk "$PROJECT_DIR" | awk 'NR==2 {print $4}')
  if [ -n "$available_kb" ] && [ "$available_kb" -lt 4194304 ]; then
    log "WARNING: less than 4 GB free in $PROJECT_DIR."
    log "Home Assistant history and image updates need disk space."
  fi
}

enable_and_start_docker() {
  log "Enabling Docker service..."
  rc-update add docker default >/dev/null 2>&1 || true

  if rc-service docker status >/dev/null 2>&1; then
    log "Docker service is already running."
    return
  fi

  log "Starting Docker service..."
  rc-service docker start
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    return
  fi

  fail "Docker Compose is not available. Install docker-cli-compose or Docker with compose plugin."
}

compose_exec() {
  if [ "$COMPOSE_CMD" = "docker compose" ]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

ensure_serve_config() {
  if [ -f "$PROJECT_DIR/tailscale/config/serve.json" ]; then
    return
  fi

  mkdir -p "$PROJECT_DIR/tailscale/config"
  if [ ! -f "$PROJECT_DIR/tailscale/config/serve.example.json" ]; then
    fail "missing template tailscale/config/serve.example.json"
  fi

  log "Creating tailscale/config/serve.json from template..."
  cp "$PROJECT_DIR/tailscale/config/serve.example.json" "$PROJECT_DIR/tailscale/config/serve.json"
  log "Created $PROJECT_DIR/tailscale/config/serve.json. Update REPLACE_WITH_YOUR_TAILSCALE_DNS_NAME before using Tailscale Serve."
}

check_required_files() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$PROJECT_DIR/.env.example" ]; then
      cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
      log "Created $ENV_FILE from .env.example."
      log "Update TS_AUTHKEY and any custom settings before next run."
    else
      fail "missing $ENV_FILE"
    fi
  fi

  [ -f "$COMPOSE_FILE" ] || fail "missing $COMPOSE_FILE"
  ensure_serve_config

  mkdir -p \
    "$PROJECT_DIR/homeassistant/config" \
    "$PROJECT_DIR/tailscale/state" \
    "$PROJECT_DIR/tailscale/config"

  if [ ! -f "$PROJECT_DIR/homeassistant/config/configuration.yaml" ]; then
    fail "missing $PROJECT_DIR/homeassistant/config/configuration.yaml"
  fi

  if grep -q 'REPLACE_WITH_YOUR_TAILSCALE_DNS_NAME' \
    "$PROJECT_DIR/tailscale/config/serve.json"; then
    log "Tailscale Serve config still has the placeholder DNS name."
    log "Update $PROJECT_DIR/tailscale/config/serve.json with your node's tailnet hostname."
  fi
}

sync_repo() {
  if [ "$REPO_UPDATE" -ne 1 ]; then
    return
  fi

  if [ ! -d "$PROJECT_DIR/.git" ]; then
    log "No git repository detected; skipping repo sync."
    return
  fi

  if ! git -C "$PROJECT_DIR" remote get-url origin >/dev/null 2>&1; then
    log "Git remote 'origin' missing; skipping repo sync."
    return
  fi

  log "Updating local repository..."
  git -C "$PROJECT_DIR" fetch --all --prune

  current_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
  if git -C "$PROJECT_DIR" rev-parse --verify --quiet "origin/$current_branch" >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" pull --ff-only "origin" "$current_branch"
  else
    log "No matching remote branch for $current_branch; skipping pull."
  fi
}

pull_and_apply_stack() {
  if [ "$IMAGE_REFRESH" -eq 1 ]; then
    log "Pulling latest container images..."
    compose_exec -f "$COMPOSE_FILE" pull
  fi

  log "Starting the compose stack..."
  if [ "$FORCE_RECREATE" -eq 1 ]; then
    compose_exec -f "$COMPOSE_FILE" up -d --remove-orphans --force-recreate
  else
    compose_exec -f "$COMPOSE_FILE" up -d --remove-orphans
  fi

  if [ "$PRUNE_IMAGES" -eq 1 ]; then
    docker image prune -f >/dev/null
  fi
}

show_status() {
  log "Compose service status:"
  compose_exec -f "$COMPOSE_FILE" ps

  TS_AUTHKEY_VALUE=$(awk -F= '$1 == "TS_AUTHKEY" {print substr($0, index($0, "=") + 1)}' "$ENV_FILE" || true)
  if [ -z "$TS_AUTHKEY_VALUE" ]; then
    log ""
    log "Tailscale login is still required."
    log "Run: docker exec tailscale tailscale up"
  else
    log ""
    log "Tailnet should come online automatically using TS_AUTHKEY."
  fi
  log ""
  log "Home Assistant should become available at http://HOST_IP:8123"
}

require_root
require_alpine
install_or_update_packages
configure_timezone
warn_if_low_disk
enable_and_start_docker
detect_compose_command
check_required_files
sync_repo
pull_and_apply_stack
show_status
