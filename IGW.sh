#!/usr/bin/env bash
set -euo pipefail


BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/.mockdb"
DATA_DIR="$DB_DIR/data"
IDEM_DIR="$DB_DIR/idem"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$DATA_DIR" "$IDEM_DIR" "$LOG_DIR"


generate_trace_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    echo "$(date +%s)$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')"
  fi
}

generate_request_id() {
  echo "req-$(date +%s)-$(head -c6 /dev/urandom | base64 | tr -dc a-z0-9)"
}

TRACE_ID="${TRACE_ID:-$(generate_trace_id)}"
REQUEST_ID="${REQUEST_ID:-$(generate_request_id)}"

ACTION=${1:-}
RESOURCE=${2:-}
shift 2 || true

parse_args() {
  DRY_RUN=false
  IDEMPOTENCY_KEY=""

  declare -gA PARAMS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;

      --request-id=*)
        REQUEST_ID="${1#*=}"; shift ;;

      --request-id)
        REQUEST_ID="$2"; shift 2 ;;

      --idempotency-key=*|--idem-key=*)
        IDEMPOTENCY_KEY="${1#*=}"; shift ;;

      --idempotency-key|--idem-key)
        IDEMPOTENCY_KEY="$2"; shift 2 ;;

      --*=*)
        k="${1%%=*}"; k="${k#--}"
        v="${1#*=}"
        PARAMS["$k"]="$v"
        shift ;;

      --*)
        k="${1#--}"
        v="$2"
        PARAMS["$k"]="$v"
        shift 2 ;;

      *=*)
        k="${1%%=*}"
        v="${1#*=}"
        PARAMS["$k"]="$v"
        shift ;;

      *)
        error 1000 "INVALID_ARGUMENT" "unknown argument: $1"
        ;;
    esac
  done
}
parse_args "$@"


json() {
  local code=$1
  local status=$2
  local msg=$3
  local data=${4:-null}
  local err_type=${5:-null}
  local err_detail=${6:-null}

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
  "data": $data,
  "error": $(if [[ "$err_type" == "null" ]]; then echo "null"; else cat <<EOT
{
  "type": "$err_type",
  "details": "$err_detail"
}
EOT
fi)
}
EOF
}

success() { json 0 "SUCCESS" "$1" "${2:-null}"; }
error() { json "$1" "ERROR" "$2" null "$2" "${3:-}"; exit 1; }


require_param() {
  [[ -z "${PARAMS[$1]:-}" ]] && error 1000 "INVALID_ARGUMENT" "missing param: $1"
}

resource_file() {
  echo "$DATA_DIR/${RESOURCE}_$1.json"
}

audit_log() {
  echo "$(date -Iseconds) trace=$TRACE_ID req=$REQUEST_ID action=$ACTION resource=$RESOURCE params=$*" >> "$LOG_DIR/api.log"
}


check_idem() {
  local f="$IDEM_DIR/$1.json"
  [[ -f "$f" ]] && cat "$f" && exit 0
}
save_idem() { echo "$2" > "$IDEM_DIR/$1.json"; }


vpc_create() {
  require_param key
  local key="${PARAMS[key]}"
  local file=$(resource_file "$key")

  [[ -f "$file" ]] && error 1002 "ALREADY_EXISTS" "vpc:$key exists"

  local data="{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run create vpc" "$data" && return

  echo "$data" > "$file"
  success "vpc created" "$data"
}

igw_create() {
  require_param key
  require_param vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  [[ ! -f "$DATA_DIR/vpc_${vpc}.json" ]] && error 1001 "NOT_FOUND" "vpc:$vpc not found"

  # 一个 VPC 一个 IGW
  if grep -l "\"vpc\":\"$vpc\"" "$DATA_DIR"/igw_*.json 2>/dev/null | grep .; then
    error 1002 "ALREADY_EXISTS" "vpc:$vpc already has igw"
  fi

  local file=$(resource_file "$key")

  local data="{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}"

  [[ "$DRY_RUN" == true ]] && success "dry-run create igw" "$data" && return

  echo "$data" > "$file"
  success "igw created" "$data"
}

get() {
  require_param key
  local f=$(resource_file "${PARAMS[key]}")
  [[ ! -f "$f" ]] && error 1001 "NOT_FOUND" "resource not found"
  success "ok" "$(cat "$f")"
}

delete() {
  require_param key
  local f=$(resource_file "${PARAMS[key]}")
  [[ ! -f "$f" ]] && error 1001 "NOT_FOUND" "resource not found"
  rm -f "$f"
  success "deleted"
}

list() {
  local arr="["
  local first=true
  for f in "$DATA_DIR"/${RESOURCE}_*.json 2>/dev/null; do
    [[ ! -f "$f" ]] && continue
    key=$(basename "$f" | sed "s/${RESOURCE}_//" | sed 's/.json//')
    [[ "$first" == true ]] && first=false || arr+=","
    arr+="{\"key\":\"$key\"}"
  done
  arr+="]"
  success "ok" "$arr"
}

audit_log "$@"

case "$RESOURCE" in
  vpc)
    case "$ACTION" in
      create) vpc_create ;;
      get) get ;;
      list) list ;;
      delete) delete ;;
    esac
    ;;

  igw)
    case "$ACTION" in
      create) igw_create ;;
      get) get ;;
      list) list ;;
      delete) delete ;;
    esac
    ;;

  *)
    error 1000 "INVALID_ARGUMENT" "unknown resource"
    ;;
esac





























































