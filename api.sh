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
  local msg=$3
  local data=${4:-null}

  echo "{
  \"meta\": {
    \"code\": $code,
    \"status\": \"$status\",
    \"message\": \"$msg\",
    \"trace_id\": \"$TRACE_ID\",
    \"request_id\": \"$REQUEST_ID\",
    \"timestamp\": \"$(date -Iseconds)\"
  },
  \"data\": $data
}"
}

success() { json 0 "SUCCESS" "$1" "${2:-null}"; }
error() { json 400 "ERROR" "$2" null; exit 1; }

########################################
# SCHEMA（核心新增）
########################################
declare -A SCHEMA_VPC_CREATE=(
  [key]="required"
)

declare -A SCHEMA_IGW_CREATE=(
  [key]="required"
  [vpc]="required"
)

validate_schema() {
  local schema_name=$1
  local key req

  declare -n schema="$schema_name"

  for key in "${!schema[@]}"; do
    req="${schema[$key]}"

    if [[ "$req" == "required" ]]; then
      if [[ -z "${PARAMS[$key]:-}" ]]; then
        error 1000 "missing required param: $key"
      fi
    fi
  done
}

########################################
# HELPERS
########################################
file_vpc() { echo "$DATA_DIR/vpc_$1.json"; }
file_igw() { echo "$DATA_DIR/igw_$1.json"; }

########################################
# VPC
########################################
vpc_create() {
  validate_schema SCHEMA_VPC_CREATE

  local key="${PARAMS[key]}"
  local file=$(file_vpc "$key")

  [[ -f "$file" ]] && error 1002 "VPC exists"

  echo "{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}" > "$file"

  success "VPC created" "{\"key\":\"$key\"}"
}

vpc_get() {
  local key="${PARAMS[key]:-}"
  [[ -z "$key" ]] && error 1000 "missing key"

  local file=$(file_vpc "$key")
  [[ ! -f "$file" ]] && error 1001 "VPC not found"

  success "OK" "$(cat "$file")"
}

########################################
# IGW
########################################
igw_create() {
  validate_schema SCHEMA_IGW_CREATE

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  [[ ! -f "$(file_vpc "$vpc")" ]] && error 1001 "VPC not found"

  local file=$(file_igw "$key")

  echo "{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}" > "$file"

  success "IGW created" "{\"key\":\"$key\",\"vpc\":\"$vpc\"}"
}

igw_get() {
  local key="${PARAMS[key]:-}"
  [[ -z "$key" ]] && error 1000 "missing key"

  local file=$(file_igw "$key")
  [[ ! -f "$file" ]] && error 1001 "IGW not found"

  success "OK" "$(cat "$file")"
}

########################################
# ROUTER
########################################
case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      *) error 400 "invalid vpc action" ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      *) error 400 "invalid igw action" ;;
    esac
    ;;

  *)
    error 400 "unknown resource"
    ;;
esac
