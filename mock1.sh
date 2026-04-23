#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ec2-controller"
LOG_FILE="${LOG_FILE:-./ec2.log}"
AWS_CMD="${AWS_CMD:-aws}"
REGION="${AWS_DEFAULT_REGION:-}"
DRY_RUN=0
DEBUG="${DEBUG:-0}"

ENV=""
NAME=""
AMI=""
TYPE=""
SG=""
SUBNET=""

[[ "$DEBUG" == "1" ]] && set -x

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local line="{\"ts\":\"$ts\",\"level\":\"$level\",\"app\":\"$APP_NAME\",\"msg\":\"$msg\"}"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >&2
}

info(){ log INFO "$@"; }
warn(){ log WARN "$@"; }
error(){ log ERROR "$@"; }

# ===== JSON 输出 =====
json_ok() {
  local msg="$1"; shift
  local data="$1"; shift
  local req_id="$1"

  printf '{
  "code": 0,
  "msg": "%s",
  "req_id": "%s",
  "data": %s
}\n' "$msg" "$req_id" "$data"
  exit 0
}

json_fail() {
  local code="$1"; shift
  local msg="$1"; shift
  local req_id="$1"

  printf '{
  "code": %s,
  "msg": "%s",
  "req_id": "%s",
  "data": null
}\n' "$code" "$msg" "$req_id"
  exit 1
}

usage() {
  json_fail 1000 "invalid arguments" "$req_id"
}

# ===== 参数解析 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --ami) AMI="$2"; shift 2;;
    --type) TYPE="$2"; shift 2;;
    --sg) SG="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --debug) DEBUG=1; set -x; shift;;
    *) usage;;
  esac
done

req_id=$(uuidgen 2>/dev/null || date +%s)

[[ -z "$ENV" || -z "$NAME" || -z "$AMI" || -z "$TYPE" || -z "$SG" || -z "$SUBNET" ]] && usage
[[ -z "$REGION" ]] && json_fail 1002 "region required" "$req_id"

AWS_ARGS=(--region "$REGION")

# ===== 幂等检查 =====
info "check instance name=$NAME"

EXISTING_INSTANCE_ID=$($AWS_CMD "${AWS_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

if [[ -n "$EXISTING_INSTANCE_ID" && "$EXISTING_INSTANCE_ID" != "None" ]]; then
  warn "exists $EXISTING_INSTANCE_ID"
  json_ok "exists" \
  "{\"instance_id\":\"$EXISTING_INSTANCE_ID\"}" \
  "$req_id"
fi

# ===== dry-run =====
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "dry-run mode"
  json_ok "dry-run" \
  "{\"name\":\"$NAME\",\"type\":\"$TYPE\",\"ami\":\"$AMI\"}" \
  "$req_id"
fi

# ===== 创建实例 =====
info "create instance"

INSTANCE_ID=$($AWS_CMD "${AWS_ARGS[@]}" ec2 run-instances \
  --image-id "$AMI" \
  --instance-type "$TYPE" \
  --subnet-id "$SUBNET" \
  --security-group-ids "$SG" \
  --query "Instances[0].InstanceId" \
  --output text) || json_fail 1003 "create failed" "$req_id"

$AWS_CMD "${AWS_ARGS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID" \
  || json_fail 1004 "wait failed" "$req_id"

PUBLIC_IP=$($AWS_CMD "${AWS_ARGS[@]}" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

json_ok "created" \
"{\"instance_id\":\"$INSTANCE_ID\",\"public_ip\":\"$PUBLIC_IP\"}" \
"$req_id"