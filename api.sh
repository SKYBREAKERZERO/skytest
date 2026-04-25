#!/usr/bin/env bash
set -euo pipefail

########################################
# BASE
########################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$BASE_DIR/.mockdb/data"
mkdir -p "$DATA_DIR"

########################################
# TRACE / REQUEST
########################################
TRACE_ID="${TRACE_ID:-trace-$(date +%s%N)}"
REQUEST_ID="${REQUEST_ID:-req-$(date +%s%N)}"

########################################
# INPUT
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

########################################
# PARAMS PARSE（稳定版）
########################################
declare -A PARAMS=()

for arg in "$@"; do
  case "$arg" in
    *=*)
      k="${arg%%=*}"
      v="${arg#*=}"
      PARAMS["$k"]="$v"
      ;;
  esac
done

########################################
# JSON RESPONSE
########################################
json() {
  echo "{
  \"meta\": {
    \"code\": $1,
    \"status\": \"$2\",
    \"message\": \"$3\",
    \"trace_id\": \"$TRACE_ID\",
    \"request_id\": \"$REQUEST_ID\",
    \"timestamp\": \"$(date -Iseconds)\"
  },
  \"data\": $4
}"
}

ok() {
  json 200 "SUCCESS" "$1" "${2:-null}"
}

err() {
  json "$1" "ERROR" "$2" null
  exit 1
}

########################################
# SCHEMA VALIDATION
########################################
require() {
  [[ -z "${PARAMS[$1]:-}" ]] && err 400 "missing_param:$1"
}

########################################
# FILE HELPERS
########################################
vpc_file() { echo "$DATA_DIR/vpc_$1.json"; }
igw_file() { echo "$DATA_DIR/igw_$1.json"; }

########################################
# VPC
########################################
vpc_create() {
  require key
  local key="${PARAMS[key]}"
  local f=$(vpc_file "$key")

  if [[ -f "$f" ]]; then
    ok "idempotent_hit" "$(cat "$f")"
    return
  fi

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"
  echo "$data" > "$f"

  ok "created" "$data"
}

vpc_get() {
  require key
  local f=$(vpc_file "${PARAMS[key]}")

  [[ ! -f "$f" ]] && err 404 "vpc_not_found"

  ok "ok" "$(cat "$f")"
}

vpc_delete() {
  require key
  local f=$(vpc_file "${PARAMS[key]}")

  [[ ! -f "$f" ]] && err 404 "vpc_not_found"

  rm -f "$f"
  ok "deleted" null
}

vpc_list() {
  local arr="["
  local first=true

  for f in "$DATA_DIR"/vpc_*.json; do
    [[ ! -f "$f" ]] && continue

    if [[ "$first" == true ]]; then
      first=false
    else
      arr+=","
    fi

    arr+="$(cat "$f")"
  done

  arr+="]"

  ok "list" "$arr"
}

########################################
# IGW
########################################
igw_create() {
  require key
  require vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"
  local vf=$(vpc_file "$vpc")

  [[ ! -f "$vf" ]] && err 404 "vpc_not_found"

  local f=$(igw_file "$key")

  if [[ -f "$f" ]]; then
    ok "idempotent_hit" "$(cat "$f")"
    return
  fi

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"
  echo "$data" > "$f"

  ok "created" "$data"
}

igw_get() {
  require key
  local f=$(igw_file "${PARAMS[key]}")

  [[ ! -f "$f" ]] && err 404 "igw_not_found"

  ok "ok" "$(cat "$f")"
}

igw_delete() {
  require key
  local f=$(igw_file "${PARAMS[key]}")

  [[ ! -f "$f" ]] && err 404 "igw_not_found"

  rm -f "$f"
  ok "deleted" null
}

igw_list() {
  local arr="["

  for f in "$DATA_DIR"/igw_*.json 2>/dev/null; do
    [[ ! -f "$f" ]] && continue
    arr+="$(cat "$f"),"
  done

  arr="${arr%,}]"

  ok "list" "$arr"
}

########################################
# ROUTER
########################################
case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      delete) vpc_delete ;;
      list) vpc_list ;;
      *) err 400 "invalid_vpc_action" ;;
    esac
    ;;
  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      delete) igw_delete ;;
      list) igw_list ;;
      *) err 400 "invalid_igw_action" ;;
    esac
    ;;
  *)
    err 400 "unknown_resource"
    ;;
esac
