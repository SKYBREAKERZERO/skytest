#!/usr/bin/env bash
set -euo pipefail

########################################
# BASE
########################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/.mockdb"
DATA_DIR="$DB_DIR/data"
IDEM_DIR="$DB_DIR/idem"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$DATA_DIR" "$IDEM_DIR" "$LOG_DIR"

########################################
# TRACE / REQUEST (企业级)
########################################
generate_trace_id() {
  command -v uuidgen >/dev/null 2>&1 && uuidgen || date +%s%N
}

generate_request_id() {
  echo "req-$(date +%s%N)-$RANDOM"
}

TRACE_ID="${TRACE_ID:-$(generate_trace_id)}"
REQUEST_ID="${REQUEST_ID:-$(generate_request_id)}"

########################################
# INPUT
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

DRY_RUN=false
declare -A PARAMS=()

########################################
# PARSER（安全版）
########################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
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
# LOG
########################################
audit_log() {
  echo "$(date -Iseconds) trace=$TRACE_ID request=$REQUEST_ID action=$ACTION resource=$RESOURCE params=$*" \
    >> "$LOG_DIR/api.log"
}

########################################
# JSON
########################################
json() {
  local code=$1
  local status=$2
  local msg=$3
  local data=${4:-null}

  cat <<EOF
{
  "meta": {
    "code": $code,
    "status": "$status",
    "message": "$msg",
    "trace_id": "$TRACE_ID",
    "request_id": "$REQUEST_ID",
    "timestamp": "$(date -Iseconds)"
  },
  "data": $data
}
EOF
}

success() { json 0 "SUCCESS" "$1" "${2:-null}"; }
error() { json 1 "ERROR" "$2" null; exit 1; }

########################################
# CORE
########################################
require_param() {
  local v="${PARAMS[$1]:-}"
  [[ -z "$v" ]] && error 1000 "missing param: $1"
}

resource_file() {
  echo "$DATA_DIR/${RESOURCE}_$1.json"
}

########################################
# VPC
########################################
vpc_create() {
  require_param key
  local key="${PARAMS[key]}"
  local file=$(resource_file "$key")

  [[ -f "$file" ]] && error 1002 "vpc already exists"

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run vpc" "$data" && return

  echo "$data" > "$file"
  success "VPC created" "$data"
}

vpc_get() {
  require_param key
  local file=$(resource_file "${PARAMS[key]}")
  [[ ! -f "$file" ]] && error 1001 "vpc not found"
  success "ok" "$(cat "$file")"
}

vpc_list() {
  ls "$DATA_DIR"/vpc_*.json 2>/dev/null \
    | awk -F'[_.]' '{print "{\"key\":\""$2"\"}"}' \
    | jq -s '.'
}

########################################
# IGW
########################################
igw_create() {
  require_param key
  require_param vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  local vpc_file="$DATA_DIR/vpc_${vpc}.json"
  [[ ! -f "$vpc_file" ]] && error 1001 "VPC not found"

  # safe duplicate check
  if ls "$DATA_DIR"/igw_*.json >/dev/null 2>&1; then
    if grep -q "\"vpc\":\"$vpc\"" "$DATA_DIR"/igw_*.json 2>/dev/null; then
      error 1002 "IGW already exists for VPC"
    fi
  fi

  local file=$(resource_file "$key")

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run igw" "$data" && return

  echo "$data" > "$file"
  success "IGW created" "$data"
}

igw_get() {
  require_param key
  local file=$(resource_file "${PARAMS[key]}")
  [[ ! -f "$file" ]] && error 1001 "igw not found"
  success "ok" "$(cat "$file")"
}

igw_list() {
  ls "$DATA_DIR"/igw_*.json 2>/dev/null \
    | awk -F'[_.]' '{print "{\"key\":\""$2"\"}"}' \
    | jq -s '.'
}

########################################
# ROUTER
########################################
audit_log "$@"

case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      list) vpc_list ;;
      *) error 1000 "invalid vpc action" ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      list) igw_list ;;
      *) error 1000 "invalid igw action" ;;
    esac
    ;;

  *)
    error 1000 "unknown resource"
    ;;
esac
