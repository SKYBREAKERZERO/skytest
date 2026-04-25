#!/usr/bin/env bash
set -euo pipefail

########################################
# BASE DIR
########################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/.mockdb"
DATA_DIR="$DB_DIR/data"
IDEM_DIR="$DB_DIR/idem"

mkdir -p "$DATA_DIR" "$IDEM_DIR"

########################################
# INPUT
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"
shift 2 || true

DRY_RUN=false
IDEMPOTENCY_KEY=""

declare -A PARAMS=()

########################################
# PARSE ARGS
########################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --idempotency-key=*|--idem-key=*)
      IDEMPOTENCY_KEY="${1#*=}"; shift ;;
    *=*)
      k="${1%%=*}"
      v="${1#*=}"
      PARAMS["$k"]="$v"
      shift ;;
    *)
      shift ;;
  esac
done

########################################
# RESPONSE
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
    "timestamp": "$(date -Iseconds)"
  },
  "data": $data
}
EOF
}

success() { json 0 "SUCCESS" "$1" "${2:-null}"; }
error() { json 1 "ERROR" "$2" null; exit 1; }

########################################
# FILE
########################################
file() {
  echo "$DATA_DIR/${RESOURCE}_$1.json"
}

########################################
# IDEMPOTENCY
########################################
check_idem() {
  local f="$IDEM_DIR/$1.json"
  [[ -f "$f" ]] && cat "$f" && exit 0
}

save_idem() {
  echo "$2" > "$IDEM_DIR/$1.json"
}

########################################
# VPC
########################################
vpc_create() {
  local key="${PARAMS[key]}"
  [[ -z "$key" ]] && error 100 "missing key"

  local f=$(file "$key")
  [[ -f "$f" ]] && error 101 "VPC exists"

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run" "$data" && return

  echo "$data" > "$f"
  success "VPC created" "$data"
}

vpc_get() {
  local key="${PARAMS[key]}"
  cat "$(file "$key")" 2>/dev/null || error 404 "not found"
}

vpc_list() {
  ls "$DATA_DIR"/vpc_*.json 2>/dev/null | awk -F'[_.]' '{print "{\"key\":\""$2"\"}"}' | jq -s '.'
}

########################################
# IGW
########################################
igw_create() {
  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  [[ -z "$key" || -z "$vpc" ]] && error 100 "missing params"

  [[ ! -f "$DATA_DIR/vpc_${vpc}.json" ]] && error 404 "VPC not found"

  local f=$(file "$key")
  [[ -f "$f" ]] && error 101 "IGW exists"

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run" "$data" && return

  echo "$data" > "$f"
  success "IGW created" "$data"
}

igw_get() {
  local key="${PARAMS[key]}"
  cat "$(file "$key")" 2>/dev/null || error 404 "not found"
}

igw_list() {
  ls "$DATA_DIR"/igw_*.json 2>/dev/null | awk -F'[_.]' '{print "{\"key\":\""$2"\"}"}' | jq -s '.'
}

########################################
# ROUTER
########################################
case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) vpc_get ;;
      list) vpc_list ;;
      *) error 400 "bad action" ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) igw_get ;;
      list) igw_list ;;
      *) error 400 "bad action" ;;
    esac
    ;;

  *)
    error 400 "unknown resource"
    ;;
esac