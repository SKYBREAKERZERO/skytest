#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG
########################################
API="./api.sh"

BASE_VPC="vpc-1"
BASE_IGW="igw-1"

########################################
# LOG
########################################
log() {
  echo "[IGW] $*"
}

run() {
  "$API" "$@"
}

########################################
# ROUTER
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"

case "$RESOURCE" in

  vpc)
    case "$ACTION" in
      create)
        log "CREATE VPC $BASE_VPC"
        run vpc create key="$BASE_VPC"
        ;;
      get)
        run vpc get key="$BASE_VPC"
        ;;
      *)
        echo "Usage: ./IGW.sh vpc create|get"
        exit 1
        ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create)
        log "CREATE IGW $BASE_IGW (vpc=$BASE_VPC)"
        run igw create key="$BASE_IGW" vpc="$BASE_VPC"
        ;;
      get)
        run igw get key="$BASE_IGW"
        ;;
      *)
        echo "Usage: ./IGW.sh igw create|get"
        exit 1
        ;;
    esac
    ;;

  *)
    echo "Usage:"
    echo "  ./IGW.sh vpc create|get"
    echo "  ./IGW.sh igw create|get"
    exit 1
    ;;
esac
