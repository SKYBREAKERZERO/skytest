#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ec2-controller"
LOG_FILE="/var/log/ec2-controller.log"

log() {
  local level="$1"
  local msg="$2"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$1"; }
warn() { log "WARN" "$1"; }
error() { log "ERROR" "$1"; }

usage() {
cat <<EOF
Usage:
  $0 --env dev|staging|prod \
     --name NAME \
     --ami AMI_ID \
     --type INSTANCE_TYPE \
     --sg SECURITY_GROUP_ID \
     --subnet SUBNET_ID \
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
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --ami) AMI="$2"; shift 2;;
    --type) TYPE="$2"; shift 2;;
    --sg) SG="$2"; shift 2;;
    --subnet) SUBNET="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    *) usage;;
  esac
done

[[ -z "$ENV" || -z "$NAME" || -z "$AMI" || -z "$TYPE" || -z "$SG" || -z "$SUBNET" ]] && usage

info "check instance name=$NAME"

EXISTING_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

if [[ -n "$EXISTING_INSTANCE_ID" ]]; then
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
  exit 0
fi

info "create instance"

INSTANCE_ID=$(aws ec2 run-instances \
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
  --output text)

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "{\"status\":\"created\",\"instance_id\":\"$INSTANCE_ID\",\"public_ip\":\"$PUBLIC_IP\"}"