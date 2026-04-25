#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG
########################################
API="./api.sh"

BASE_VPC="vpc-1"
BASE_IGW="igw-1"

########################################
# LOG
########################################
log() {
  echo "[IGW] $*"
}

########################################
# SAFE RUN API
########################################
run_api() {
  "$API" "$@"
}

########################################
# INPUT
########################################
RESOURCE="${1:-}"
ACTION="${2:-}"

########################################
# HELP CHECK
########################################
if [[ -z "$RESOURCE" || -z "$ACTION" ]]; then
  echo "Usage:"
  echo "  ./IGW.sh vpc create"
  echo "  ./IGW.sh igw create"
  echo "  ./IGW.sh igw get"
  exit 1
fi

########################################
# VPC LOGIC
########################################
if [[ "$RESOURCE" == "vpc" ]]; then

  if [[ "$ACTION" == "create" ]]; then
    log "CREATE VPC: $BASE_VPC"
    run_api create vpc key="$BASE_VPC"
  elif [[ "$ACTION" == "get" ]]; then
    run_api get vpc key="$BASE_VPC"
  elif [[ "$ACTION" == "list" ]]; then
    run_api list vpc
  else
    echo "UNKNOWN ACTION FOR VPC"
    exit 1
  fi

########################################
# IGW LOGIC
########################################
elif [[ "$RESOURCE" == "igw" ]]; then

  if [[ "$ACTION" == "create" ]]; then
    log "CREATE IGW: $BASE_IGW"

    # 自动确保 VPC 存在（关键优化）
    run_api create vpc key="$BASE_VPC" || true

    run_api create igw key="$BASE_IGW" vpc="$BASE_VPC"

  elif [[ "$ACTION" == "get" ]]; then
    run_api get igw key="$BASE_IGW"

  elif [[ "$ACTION" == "list" ]]; then
    run_api list igw

  elif [[ "$ACTION" == "delete" ]]; then
    run_api delete igw key="$BASE_IGW"

  else
    echo "UNKNOWN ACTION FOR IGW"
    exit 1
  fi

else
  echo "UNKNOWN RESOURCE: $RESOURCE"
  exit 1
fi

########################################
# DONE
########################################
log "DONE"
