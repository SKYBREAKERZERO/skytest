#!/usr/bin/env bash
set -euo pipefail

DATA_DIR=".mockdb/data"
mkdir -p "$DATA_DIR"

TRACE_ID="${TRACE_ID:-trace-$RANDOM}"
REQUEST_ID="${REQUEST_ID:-req-$RANDOM}"

RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

declare -A PARAMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    *=*)
      k="${1%%=*}"
      v="${1#*=}"
      PARAMS["$k"]="$v"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

json() {
  echo "{\"meta\":{\"status\":\"SUCCESS\",\"message\":\"$2\",\"trace_id\":\"$TRACE_ID\",\"request_id\":\"$REQUEST_ID\"},\"data\":$3}"
}

err() {
  echo "{\"meta\":{\"status\":\"ERROR\",\"message\":\"$2\"},\"data\":null}"
  exit 1
}

require() {
  [[ -z "${PARAMS[$1]:-}" ]] && err 400 "missing_$1"
}

vpc_create() {
  require key
  local k="${PARAMS[key]}"
  local f="$DATA_DIR/vpc_$k.json"

  [[ -f "$f" ]] && json 200 "idempotent" "$(cat "$f")" && return

  echo "{\"resource\":\"vpc\",\"key\":\"$k\"}" > "$f"
  json 200 "created" "$(cat "$f")"
}

vpc_get() {
  require key
  local f="$DATA_DIR/vpc_${PARAMS[key]}.json"
  [[ ! -f "$f" ]] && err 404 "not_found"
  json 200 "ok" "$(cat "$f")"
}

igw_create() {
  require key
  require vpc

  local k="${PARAMS[key]}"
  local v="${PARAMS[vpc]}"
  local f="$DATA_DIR/igw_$k.json"

  [[ -f "$f" ]] && json 200 "idempotent" "$(cat "$f")" && return

  echo "{\"resource\":\"igw\",\"key\":\"$k\",\"vpc\":\"$v\"}" > "$f"
  json 200 "created" "$(cat "$f")"
}

igw_get() {
  require key
  local f="$DATA_DIR/igw_${PARAMS[key]}.json"
  [[ ! -f "$f" ]] && err 404 "not_found"
  json 200 "ok" "$(cat "$f")"
}

case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      *) err 400 "bad_action" ;;
    esac
    ;;
  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      *) err 400 "bad_action" ;;
    esac
    ;;
  *)
    err 400 "bad_resource"
    ;;
esac
