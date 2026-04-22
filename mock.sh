#!/usr/bin/env bash
set -euo pipefail

MOCK_DELAY=${MOCK_DELAY:-0}
MOCK_VERBOSE=${MOCK_VERBOSE:-1}

log() {
  [[ "$MOCK_VERBOSE" == "1" ]] && echo "[MOCK] $*" >&2
}

sleep_if_needed() {
  [[ "$MOCK_DELAY" -gt 0 ]] && sleep "$MOCK_DELAY"
}

normalize() {
  echo "$1" | tr -d '\r\n\t '
}

mock_s3_get() {
  local bucket
  local key

  bucket=$(normalize "${1:-}")
  key=$(normalize "${2:-}")

  log "S3 GET s3://$bucket/$key"
  sleep_if_needed

  if [[ "$key" == *config/app.json* ]]; then
    printf '%s\n' '{"env":"dev","service":"demo","data":{"db":{"host":"127.0.0.1","port":3306}}}'
    return 0
  fi

  if [[ "$key" == *notfound* ]]; then
    printf '%s\n' '{"error":"NoSuchKey"}'
    return 1
  fi

  if [[ "$key" == *error* ]]; then
    printf '%s\n' '{"error":"InternalError"}'
    return 2
  fi

  printf '%s\n' '{"bucket":"'"$bucket"'","key":"'"$key"'","data":{}}'
}

mock_redis_get() {
  local key
  key=$(normalize "${1:-}")

  log "REDIS GET $key"
  sleep_if_needed

  if [[ "$key" == "user:1" ]]; then
    printf '%s\n' '{"id":1,"name":"alice"}'
    return 0
  fi

  if [[ "$key" == "missing" ]]; then
    printf '%s\n' '{"error":"not_found"}'
    return 1
  fi

  printf '%s\n' '{}'
}

mock_http_get() {
  local url
  url=$(normalize "${1:-}")

  log "HTTP GET $url"
  sleep_if_needed

  if [[ "$url" == *"/health"* ]]; then
    printf '%s\n' '{"status":"ok"}'
    return 0
  fi

  if [[ "$url" == *"/fail"* ]]; then
    printf '%s\n' '{"error":"500"}'
    return 1
  fi

  printf '%s\n' '{"message":"ok"}'
}

s3_get() {
  mock_s3_get "$1" "$2"
}

redis_get() {
  mock_redis_get "$1"
}

http_get() {
  mock_http_get "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    s3)
      s3_get "${2:-}" "${3:-}"
      ;;
    redis)
      redis_get "${2:-}"
      ;;
    http)
      http_get "${2:-}"
      ;;
    *)
      echo "Usage:"
      echo "  $0 s3 <bucket> <key>"
      echo "  $0 redis <key>"
      echo "  $0 http <url>"
      exit 1
      ;;
  esac
fi
