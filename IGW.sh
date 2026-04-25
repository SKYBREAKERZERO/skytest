#!/usr/bin/env bash
set -euo pipefail

API="./api.sh"

log() {
  echo "[IGW] $*"
}

run() {
  "$API" "$@"
}

RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

case "$RESOURCE" in

  vpc)
    case "$ACTION" in
      create)
        log "CREATE VPC"
        run vpc create "$@"
        ;;
      get)
        log "GET VPC"
        run vpc get "$@"
        ;;
      delete)
        log "DELETE VPC"
        run vpc delete "$@"
        ;;
      list)
        run vpc list "$@"
        ;;
      *)
        echo "Usage: vpc create|get|delete|list"
        ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create)
        log "CREATE IGW"
        run igw create "$@"
        ;;
      get)
        run igw get "$@"
        ;;
      delete)
        run igw delete "$@"
        ;;
      list)
        run igw list "$@"
        ;;
      *)
        echo "Usage: igw create|get|delete|list"
        ;;
    esac
    ;;

  *)
    echo "Usage: vpc|igw ..."
    ;;
esac
