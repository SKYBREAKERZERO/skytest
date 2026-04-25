#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$BASE_DIR/.mockdb/data"

mkdir -p "$DATA_DIR"

########################################
# TRACE / REQUEST
########################################
TRACE_ID="${TRACE_ID:-$(uuidgen 2>/dev/null || date +%s%N)}"
REQUEST_ID="${REQUEST_ID:-req-$(date +%s%N)}"

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
# JSON（唯一出口，保证永远有输出）
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

error() {
  json "$1" "ERROR" "$2" null
  exit 1
}

########################################
# VALIDATION（schema）
########################################
require() {
  [[ -z "${PARAMS[$1]:-}" ]] && error 400 "missing_param:$1"
}

file_vpc() { echo "$DATA_DIR/vpc_$1.json"; }
file_igw() { echo "$DATA_DIR/igw_$1.json"; }

########################################
# VPC
########################################
vpc_create() {
  require key
  local key="${PARAMS[key]}"
  local f=$(file_vpc "$key")

  if [[ -f "$f" ]]; then
    json 200 "SUCCESS" "idempotent_hit" "$(cat "$f")"
    return
  fi

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"
  echo "$data" > "$f"

  json 200 "SUCCESS" "created" "$data"
}

vpc_get() {
  require key
  local f=$(file_vpc "${PARAMS[key]}")

  [[ ! -f "$f" ]] && error 404 "vpc_not_found"

  json 200 "SUCCESS" "ok" "$(cat "$f")"
}

########################################
# IGW
########################################
igw_create() {
  require key
  require vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  [[ ! -f "$(file_vpc "$vpc")" ]] && error 404 "vpc_not_found"

  local f=$(file_igw "$key")

  if [[ -f "$f" ]]; then
    json 200 "SUCCESS" "idempotent_hit" "$(cat "$f")"
    return
  fi

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"
  echo "$data" > "$f"

  json 200 "SUCCESS" "created" "$data"
}

igw_get() {
  require key
  local f=$(file_igw "${PARAMS[key]}")

  [[ ! -f "$f" ]] && error 404 "igw_not_found"

  json 200 "SUCCESS" "ok" "$(cat "$f")"
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
