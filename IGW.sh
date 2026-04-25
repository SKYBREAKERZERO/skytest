#!/usr/bin/env bash
set -euo pipefail

API="./api.sh"

log() {
  echo "[IGW] $*"
}

run() {
  "$API" "$@"
}

case "${1:-}" in

  vpc)
    case "${2:-}" in
      create)
        log "CREATE VPC vpc-1"
        run vpc create key=vpc-1
        ;;
      get)
        run vpc get key=vpc-1
        ;;
      *)
        echo "usage: vpc create|get"
        ;;
    esac
    ;;

  igw)
    case "${2:-}" in
      create)
        log "CREATE IGW igw-1"
        run igw create key=igw-1 vpc=vpc-1
        ;;
      get)
        run igw get key=igw-1
        ;;
      *)
        echo "usage: igw create|get"
        ;;
    esac
    ;;

  *)
    echo "usage: vpc|igw create|get"
    ;;
esac
