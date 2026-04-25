#!/usr/bin/env bash
set -euo pipefail

API="./api.sh"

########################################
# LOG
########################################
log() {
  echo "[IGW] $*"
}

########################################
# RUN API（关键：不吞输出）
########################################
run() {
  "$API" "$@"
}

########################################
# INPUT
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

########################################
# HELP
########################################
usage() {
  echo "Usage:"
  echo "  IGW.sh vpc create key=vpc-1"
  echo "  IGW.sh vpc get    key=vpc-1"
  echo "  IGW.sh igw create key=igw-1 vpc=vpc-1"
  echo "  IGW.sh igw get    key=igw-1"
}

########################################
# ROUTER
########################################
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
        log "LIST VPC"
        run vpc list "$@"
        ;;
      *)
        usage
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
        log "GET IGW"
        run igw get "$@"
        ;;
      delete)
        log "DELETE IGW"
        run igw delete "$@"
        ;;
      list)
        log "LIST IGW"
        run igw list "$@"
        ;;
      *)
        usage
        ;;
    esac
    ;;

  *)
    usage
    ;;
esac
