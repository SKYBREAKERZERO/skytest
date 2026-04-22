#!/usr/bin/env bash
set -euo pipefail

ENV=${ENV:-dev}
APP_NAME=${APP_NAME:-demo-app}
APP_USER=${APP_USER:-appuser}

TIMEZONE=${TIMEZONE:-Asia/Tokyo}
APT_MIRROR=${APT_MIRROR:-http://deb.debian.org/debian}

USE_MOCK_S3=${USE_MOCK_S3:-true}
S3_BUCKET=${S3_BUCKET:-my-bucket}
S3_KEY=${S3_KEY:-config/app.json}

LOG_FILE=${LOG_FILE:-/var/log/init.log}
INIT_FLAG="/var/run/${APP_NAME}_init.done"

log() {
  local level=$1
  local msg=$2
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] [env=$ENV] $msg" | tee -a "$LOG_FILE"
}

trap 'log ERROR "Failed at line $LINENO"; exit 1' ERR

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log ERROR "Must run as root"
    exit 1
  fi
}

check_idempotent() {
  if [[ -f "$INIT_FLAG" ]]; then
    log INFO "Already initialized, skip"
    exit 0
  fi
}

mock_s3_get() {
  cat <<EOF
{
  "data": {
    "config": {
      "db_host": "127.0.0.1",
      "db_port": 3306
    }
  }
}
EOF
}

s3_get() {
  if [[ "$USE_MOCK_S3" == "true" ]]; then
    mock_s3_get
  else
    aws s3 cp "s3://$S3_BUCKET/$S3_KEY" -
  fi
}

init_system() {
  timedatectl set-timezone "$TIMEZONE"
  sed -i "s|http://deb.debian.org/debian|$APT_MIRROR|g" /etc/apt/sources.list
  apt-get update -y
}

install_packages() {
  apt-get install -y curl wget vim git jq unzip net-tools htop
}

security() {
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart ssh || true
}

init_user() {
  if ! id "$APP_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$APP_USER"
  fi
}

init_dirs() {
  mkdir -p /opt/$APP_NAME
  mkdir -p /var/log/$APP_NAME
  chown -R $APP_USER:$APP_USER /opt/$APP_NAME
}

load_config() {
  CONFIG_JSON=$(s3_get)
  DB_HOST=$(echo "$CONFIG_JSON" | jq -r '.data.config.db_host')
  DB_PORT=$(echo "$CONFIG_JSON" | jq -r '.data.config.db_port')
  log INFO "DB_HOST=$DB_HOST"
  log INFO "DB_PORT=$DB_PORT"
}

init_app() {
  true
}

main() {
  log INFO "START"
  check_root
  check_idempotent
  init_system
  install_packages
  security
  init_user
  init_dirs
  load_config
  init_app
  touch "$INIT_FLAG"
  log INFO "SUCCESS"
}

main "$@"