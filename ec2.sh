#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ec2-controller"
LOG_FILE="/var/log/ec2-controller.log"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"app\":\"$APP_NAME\",\"msg\":\"$msg\"}" | tee -a "$LOG_FILE"
}

info(){ log INFO "$@"; }
warn(){ log WARN "$@"; }
error(){ log ERROR "$@"; }

usage() {
cat <<EOF
Usage:
  $0 --env <dev|staging|prod> \
     --name <instance-name> \
     --ami <ami-id> \
     --type <instance-type> \
     --sg <security-group-id> \
     --subnet <subnet-id> \
     [--region <region>] \
     [--dry-run]
EOF
exit 1
}

ENV=""
NAME=""
AMI=""
TYPE=""
SG=""
SUBNET=""
REGION="${AWS_DEFAULT_REGION:-}"
DRY_RUN=0

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
    *) usage;;
  esac
done

[[ -z "$ENV" || -z "$NAME" || -z "$AMI" || -z "$TYPE" || -z "$SG" || -z "$SUBNET" ]] && usage
[[ -z "$REGION" ]] && { error "region required"; exit 1; }

AWS_ARGS=(--region "$REGION")

retry() {
  local n=0
  local max=3
  local delay=2
  until "$@"; do
    ((n++))
    if [[ $n -ge $max ]]; then
      return 1
    fi
    sleep $delay
    delay=$((delay * 2))
  done
}

info "check instance name=$NAME"

EXISTING_INSTANCE_ID=$(aws "${AWS_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

if [[ -n "$EXISTING_INSTANCE_ID" && "$EXISTING_INSTANCE_ID" != "None" ]]; then
  warn "exists $EXISTING_INSTANCE_ID"
  echo "{\"status\":\"exists\",\"instance_id\":\"$EXISTING_INSTANCE_ID\"}"
  exit 0
fi

USER_DATA=$(cat <<EOF
#!/bin/bash
yum update -y
echo "env=$ENV" > /etc/app.env
EOF
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "dry-run mode"
  echo "{\"status\":\"dry-run\"}"
  exit 0
fi

info "create instance"

INSTANCE_ID=$(retry aws "${AWS_ARGS[@]}" ec2 run-instances \
  --image-id "$AMI" \
  --instance-type "$TYPE" \
  --subnet-id "$SUBNET" \
  --security-group-ids "$SG" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=$NAME},
    {Key=Env,Value=$ENV},
    {Key=ManagedBy,Value=ec2.sh}
  ]" \
  --query "Instances[0].InstanceId" \
  --output text) || { error "create failed"; exit 1; }

info "wait running $INSTANCE_ID"

retry aws "${AWS_ARGS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID" || {
  error "wait failed"
  exit 1
}

PUBLIC_IP=$(aws "${AWS_ARGS[@]}" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "{\"status\":\"created\",\"instance_id\":\"$INSTANCE_ID\",\"public_ip\":\"$PUBLIC_IP\"}"
