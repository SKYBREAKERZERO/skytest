#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ec2-controller"
LOG_FILE="${LOG_FILE:-./ec2.log}"
AWS_CMD="${AWS_CMD:-aws}"
REGION="${AWS_DEFAULT_REGION:-}"
PROFILE=""
LOCK_TABLE=""
LOCK_TTL=300
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
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"app\":\"$APP_NAME\",\"msg\":\"$msg\"}" | tee -a "$LOG_FILE" >&2
}

info(){ log INFO "$@"; }
warn(){ log WARN "$@"; }
error(){ log ERROR "$@"; }

json_exit() {
  local status="$1"; shift
  local extra="$*"
  printf '{"status":"%s"%s}\n' "$status" "$extra"
  exit 0
}

json_error() {
  local code="$1"; shift
  local msg="$*"
  printf '{"status":"error","error_code":"%s","message":"%s"}\n' "$code" "$msg"
  exit 1
}

usage() {
  json_error "INVALID_ARGS" "missing required parameters"
}

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

[[ -z "$ENV" || -z "$NAME" || -z "$AMI" || -z "$TYPE" || -z "$SG" || -z "$SUBNET" ]] && usage
[[ -z "$REGION" ]] && json_error "NO_REGION" "region is required"

AWS_ARGS=(--region "$REGION")

req_id=$(date +%s)

retry() {
  local max=5 delay=1 i=1
  while true; do
    if "$@"; then return 0; fi
    if (( i >= max )); then return 1; fi
    sleep "$delay"
    delay=$(( delay * 2 ))
    i=$(( i + 1 ))
  done
}

info "check instance name=$NAME"

EXISTING_INSTANCE_ID=$($AWS_CMD "${AWS_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

if [[ -n "$EXISTING_INSTANCE_ID" && "$EXISTING_INSTANCE_ID" != "None" ]]; then
  warn "exists $EXISTING_INSTANCE_ID"
  json_exit "exists" ",\"instance_id\":\"$EXISTING_INSTANCE_ID\",\"req_id\":\"$req_id\""
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "dry-run"
  json_exit "dry-run" ",\"req_id\":\"$req_id\""
fi

info "create instance"

INSTANCE_ID=$(retry $AWS_CMD "${AWS_ARGS[@]}" ec2 run-instances \
  --image-id "$AMI" \
  --instance-type "$TYPE" \
  --subnet-id "$SUBNET" \
  --security-group-ids "$SG" \
  --query "Instances[0].InstanceId" \
  --output text) || json_error "CREATE_FAILED" "run-instances failed"

retry $AWS_CMD "${AWS_ARGS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID" \
  || json_error "WAIT_FAILED" "instance not running"

PUBLIC_IP=$($AWS_CMD "${AWS_ARGS[@]}" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

json_exit "created" ",\"instance_id\":\"$INSTANCE_ID\",\"public_ip\":\"$PUBLIC_IP\",\"req_id\":\"$req_id\""
