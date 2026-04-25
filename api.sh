#!/usr/bin/env bash
set -euo pipefail

########################################
# BASE
########################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/.mockdb"
DATA_DIR="$DB_DIR/data"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$DATA_DIR" "$LOG_DIR"

########################################
# TRACE
########################################
TRACE_ID="${TRACE_ID:-$(uuidgen 2>/dev/null || date +%s%N)}"
REQUEST_ID="${REQUEST_ID:-req-$(date +%s%N)-$RANDOM}"

########################################
# INPUT
########################################
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

########################################
# JSON
########################################
json() {
  local code=$1
  local status=$2
  local message=$3
  local data=${4:-null}

  echo "{
  \"meta\": {
    \"code\": $code,
    \"status\": \"$status\",
    \"message\": \"$message\",
    \"trace_id\": \"$TRACE_ID\",
    \"request_id\": \"$REQUEST_ID\",
    \"timestamp\": \"$(date -Iseconds)\"
  },
  \"data\": $data
}"
}

success() { json "$@"; }

error() {
  json "$1" "ERROR" "$2" null
  exit 1
}

########################################
# HELPERS
########################################
require_param() {
  [[ -z "${PARAMS[$1]:-}" ]] && error 400 "missing_param:$1"
}

file_vpc() { echo "$DATA_DIR/vpc_$1.json"; }
file_igw() { echo "$DATA_DIR/igw_$1.json"; }

########################################
# VPC
########################################
vpc_create() {
  require_param key
  local key="${PARAMS[key]}"
  local file=$(file_vpc "$key")

  if [[ -f "$file" ]]; then
    # 幂等返回（重点）
    json 200 "SUCCESS" "idempotent_hit" "$(cat "$file")"
    return
  fi

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"
  echo "$data" > "$file"

  json 200 "SUCCESS" "created" "$data"
}

vpc_get() {
  require_param key
  local file=$(file_vpc "${PARAMS[key]}")
  [[ ! -f "$file" ]] && error 404 "vpc_not_found"

  json 200 "SUCCESS" "ok" "$(cat "$file")"
}

########################################
# IGW
########################################
igw_create() {
  require_param key
  require_param vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  local vpc_file=$(file_vpc "$vpc")
  [[ ! -f "$vpc_file" ]] && error 404 "vpc_not_found"

  local file=$(file_igw "$key")

  if [[ -f "$file" ]]; then
    json 200 "SUCCESS" "idempotent_hit" "$(cat "$file")"
    return
  fi

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"
  echo "$data" > "$file"

  json 200 "SUCCESS" "created" "$data"
}

igw_get() {
  require_param key
  local file=$(file_igw "${PARAMS[key]}")
  [[ ! -f "$file" ]] && error 404 "igw_not_found"

  json 200 "SUCCESS" "ok" "$(cat "$file")"
}

########################################
# ROUTER
########################################
case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      *) error 400 "invalid_vpc_action" ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      *) error 400 "invalid_igw_action" ;;
    esac
    ;;

  *)
    error 400 "unknown_resource"
    ;;
esac
