#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
SERVE_FILE="$PROJECT_DIR/tailscale/config/serve.json"
MIN_DISK_KB=4194304
TIMEZONE_NAME=${TIMEZONE_NAME:-America/Chicago}

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

install_or_update_packages() {
  log "Installing or updating required packages..."
  apk update
  apk add --upgrade docker docker-cli-compose git tzdata
}

configure_timezone() {
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
  if [ -n "$available_kb" ] && [ "$available_kb" -lt "$MIN_DISK_KB" ]; then
    log "WARNING: less than 4 GB of free space is available for $PROJECT_DIR."
    log "Home Assistant history, image pulls, and updates can exhaust small removable media quickly."
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

check_commands() {
  command -v docker >/dev/null 2>&1 || fail "docker is not installed"
  docker compose version >/dev/null 2>&1 || fail "docker compose plugin is not available"
  docker info >/dev/null 2>&1 || fail "docker daemon is not responding"
}

check_project_files() {
  [ -f "$COMPOSE_FILE" ] || fail "missing $COMPOSE_FILE"
  [ -f "$ENV_FILE" ] || fail "missing $ENV_FILE"
  [ -f "$SERVE_FILE" ] || fail "missing $SERVE_FILE"

  mkdir -p \
    "$PROJECT_DIR/homeassistant/config" \
    "$PROJECT_DIR/tailscale/state" \
    "$PROJECT_DIR/tailscale/config"

  if [ ! -f "$PROJECT_DIR/homeassistant/config/configuration.yaml" ]; then
    fail "missing $PROJECT_DIR/homeassistant/config/configuration.yaml"
  fi

  if grep -q 'REPLACE_WITH_YOUR_TAILSCALE_DNS_NAME' "$SERVE_FILE"; then
    log "Tailscale Serve config still has the placeholder DNS name."
    log "Update $SERVE_FILE after the node is created in Tailscale."
    log "The containers can still start, but tailnet HTTPS proxying will not be correct until you update it."
  fi
}

pull_and_start() {
  log "Pulling container images..."
  docker compose -f "$COMPOSE_FILE" pull

  log "Starting the compose stack..."
  docker compose -f "$COMPOSE_FILE" up -d
}

show_status() {
  log "Compose service status:"
  docker compose -f "$COMPOSE_FILE" ps

  TS_AUTHKEY_VALUE=$(awk -F= '$1 == "TS_AUTHKEY" {print substr($0, index($0, "=") + 1)}' "$ENV_FILE" || true)
  if [ -z "$TS_AUTHKEY_VALUE" ]; then
    log ""
    log "Tailscale login is still required."
    log "Run: docker exec -it tailscale tailscale up"
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
check_commands
check_project_files
pull_and_start
show_status
