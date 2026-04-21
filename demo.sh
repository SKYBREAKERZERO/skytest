#!/bin/bash
set -euo pipefail

#####################################
# 基础信息
#####################################
TRACE_ID=$(uuidgen)
NOW=$(date -Iseconds)
HOST=$(hostname)

OUTPUT_DIR="./output"
OUTPUT_FILE="${OUTPUT_DIR}/result.txt"

#####################################
# 日志函数（结构化）
#####################################
log() {
  local level=$1
  local msg=$2

  echo "{\"time\":\"$(date -Iseconds)\",\"level\":\"$level\",\"trace_id\":\"$TRACE_ID\",\"msg\":\"$msg\"}"
}

#####################################
# 主流程
#####################################
main() {

  log "INFO" "Start demo job"

  mkdir -p "$OUTPUT_DIR"

  echo "Run Time: $NOW" >> "$OUTPUT_FILE"
  echo "Host: $HOST" >> "$OUTPUT_FILE"
  echo "TraceID: $TRACE_ID" >> "$OUTPUT_FILE"
  echo "------------------------" >> "$OUTPUT_FILE"

  sleep 2

  log "INFO" "Write result to $OUTPUT_FILE"

  log "INFO" "Done"
}

main