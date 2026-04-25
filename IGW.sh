#!/usr/bin/env bash
set -euo pipefail

########################################
# INIT
########################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/.mockdb"
DATA_DIR="$DB_DIR/data"
IDEM_DIR="$DB_DIR/idem"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$DATA_DIR" "$IDEM_DIR" "$LOG_DIR"

########################################
# TRACE
########################################
generate_trace_id() {
  command -v uuidgen >/dev/null 2>&1 && uuidgen || date +%s
}

generate_request_id() {
  echo "req-$(date +%s)-$RANDOM"
}

TRACE_ID="${TRACE_ID:-$(generate_trace_id)}"
REQUEST_ID="${REQUEST_ID:-$(generate_request_id)}"

########################################
# ERROR FIRST (关键修复)
########################################
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
  "error": $( [[ "$err_type" == "null" ]] && echo "null" || cat <<EOT
{
  "type": "$err_type",
  "details": "$err_detail"
}
EOT
)
}
EOF
}

success() { json 0 "SUCCESS" "$1" "${2:-null}"; }
error() { json "$1" "ERROR" "$2" null "$2" "${3:-}"; exit 1; }

########################################
# PARSER
########################################
parse_args() {
  DRY_RUN=false
  declare -gA PARAMS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --*=*)
        k="${1%%=*}"; k="${k#--}"
        v="${1#*=}"
        PARAMS["$k"]="$v"
        shift ;;
      *)
        shift ;;
    esac
  done
}

parse_args "$@"

########################################
# CORE
########################################
require_param() {
  [[ -z "${PARAMS[$1]:-}" ]] && error 1000 "INVALID_ARGUMENT" "missing $1"
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

  [[ -f "$file" ]] && error 1002 "ALREADY_EXISTS" "vpc exists"

  echo "{\"resource\":\"vpc\",\"key\":\"$key\",\"state\":\"ACTIVE\"}" > "$file"
  success "vpc created"
}

########################################
# IGW
########################################
igw_create() {
  require_param key
  require_param vpc

  local key="${PARAMS[key]}"
  local vpc="${PARAMS[vpc]}"

  [[ ! -f "$DATA_DIR/vpc_${vpc}.json" ]] && error 1001 "NOT_FOUND" "vpc not found"

  # safe check
  if ls "$DATA_DIR"/igw_*.json >/dev/null 2>&1; then
    if grep -q "\"vpc\":\"$vpc\"" "$DATA_DIR"/igw_*.json 2>/dev/null; then
      error 1002 "ALREADY_EXISTS" "IGW exists for VPC"
    fi
  fi

  local file=$(resource_file "$key")
  echo "{\"resource\":\"igw\",\"key\":\"$key\",\"vpc\":\"$vpc\",\"state\":\"ATTACHED\"}" > "$file"

  success "igw created"
}

########################################
# ROUTER
########################################
RESOURCE=${2:-}
ACTION=${1:-}
shift 2 || true

case "$RESOURCE" in
  vpc)
    [[ "$ACTION" == "create" ]] && vpc_create ;;
    ;;
  igw)
    [[ "$ACTION" == "create" ]] && igw_create ;;
    ;;
  *)
    error 1000 "INVALID_ARGUMENT" "unknown resource"
    ;;
esac
