#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="./vpc-state.json"
LOG_FILE="./vpc-log.json"

trace_id="${TRACE_ID:-$(date +%s%N)}"

# =========================
# dependencies check
# =========================
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# =========================
# utils
# =========================
json_escape() {
  echo "$1" | sed 's/"/\\"/g'
}

read_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"vpcs":[],"subnets":[],"igw":[]}'
  else
    cat "$STATE_FILE"
  fi
}

write_state() {
  echo "$1" > "$STATE_FILE"
}

log() {
  local level="$1"
  local msg="$2"
  local ts

  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  cat <<EOF >> "$LOG_FILE"
{
  "ts": "$ts",
  "level": "$level",
  "trace_id": "$trace_id",
  "msg": "$(json_escape "$msg")"
}
EOF
}

json() {
  local msg="$1"
  local request="$2"
  local resource="$3"
  local result="$4"

  cat <<EOF
{
  "meta": {
    "trace_id": "$trace_id",
    "code": 0,
    "message": "$msg"
  },
  "request": $request,
  "resource": $resource,
  "result": $result
}
EOF
}

# =========================
# idempotency check
# =========================
vpc_exists() {
  local cidr="$1"

  read_state | jq -e \
    --arg cidr "$cidr" \
    '.vpcs[]? | select(.cidr == $cidr)' >/dev/null 2>&1
}

# =========================
# VPC
# =========================
create_vpc() {
  local cidr="$1"
  local vpc_id="vpc-$(date +%s)"

  log "INFO" "create-vpc $cidr"

  if vpc_exists "$cidr"; then
    local existing
    existing=$(read_state | jq --arg cidr "$cidr" '.vpcs[] | select(.cidr==$cidr)')

    json "exists" \
    "{\"action\":\"create-vpc\",\"cidr\":\"$cidr\"}" \
    "$existing" \
    "{\"status\":\"exists\"}"
    return
  fi

  new_state=$(read_state | jq \
    --arg id "$vpc_id" \
    --arg cidr "$cidr" \
    '.vpcs = (.vpcs // []) + [{"id":$id,"cidr":$cidr}]')

  write_state "$new_state"

  json "created" \
  "{\"action\":\"create-vpc\",\"cidr\":\"$cidr\"}" \
  "{\"vpc_id\":\"$vpc_id\",\"cidr\":\"$cidr\"}" \
  "{\"status\":\"created\"}"
}

# =========================
# Subnet
# =========================
create_subnet() {
  local vpc_id="$1"
  local cidr="$2"
  local subnet_id="subnet-$(date +%s)"

  log "INFO" "create-subnet $vpc_id $cidr"

  new_state=$(read_state | jq \
    --arg id "$subnet_id" \
    --arg vpc "$vpc_id" \
    --arg cidr "$cidr" \
    '.subnets = (.subnets // []) + [{"id":$id,"vpc":$vpc,"cidr":$cidr}]')

  write_state "$new_state"

  json "created" \
  "{\"action\":\"create-subnet\",\"vpc_id\":\"$vpc_id\",\"cidr\":\"$cidr\"}" \
  "{\"subnet_id\":\"$subnet_id\",\"vpc_id\":\"$vpc_id\",\"cidr\":\"$cidr\"}" \
  "{\"status\":\"created\"}"
}

# =========================
# Internet Gateway
# =========================
create_igw() {
  local vpc_id="$1"
  local igw_id="igw-$(date +%s)"

  log "INFO" "create-igw $vpc_id"

  new_state=$(read_state | jq \
    --arg id "$igw_id" \
    --arg vpc "$vpc_id" \
    '.igw = (.igw // []) + [{"id":$id,"vpc":$vpc}]')

  write_state "$new_state"

  json "created" \
  "{\"action\":\"create-igw\",\"vpc_id\":\"$vpc_id\"}" \
  "{\"igw_id\":\"$igw_id\",\"vpc_id\":\"$vpc_id\"}" \
  "{\"status\":\"created\"}"
}

# =========================
# Router
# =========================
case "${1:-}" in
  create-vpc)
    create_vpc "$2"
    ;;
  create-subnet)
    create_subnet "$2" "$3"
    ;;
  create-igw)
    create_igw "$2"
    ;;
  *)
    json "error" \
    "{\"action\":\"$1\"}" \
    "{}" \
    "{\"status\":\"unknown-action\"}"
    ;;
esac