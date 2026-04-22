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

  case "$key" in
    *config/app.json*)
cat <<EOF
{
  "env": "dev",
  "service": "demo",
  "data": {
    "db": {
      "host": "127.0.0.1",
      "port": 3306
    }
  }
}
EOF
      return 0
      ;;
    *notfound*)
      echo '{"error":"NoSuchKey"}' >&2
      return 1
      ;;
    *error*)
      echo '{"error":"InternalError"}' >&2
      return 2
      ;;
    *)
cat <<EOF
{
  "bucket": "$bucket",
  "key": "$key",
  "data": {}
}
EOF
      return 0
      ;;
  esac
}

mock_redis_get() {
  local key
  key=$(normalize "${1:-}")

  log "REDIS GET $key"
  sleep_if_needed

  case "$key" in
    "user:1")
      echo '{"id":1,"name":"alice"}'
      ;;
    "missing")
      return 1
      ;;
    *)
      echo '{}'
      ;;
  esac
}

mock_http_get() {
  local url
  url=$(normalize "${1:-}")

  log "HTTP GET $url"
  sleep_if_needed

  case "$url" in
    *"/health"*)
      echo '{"status":"ok"}'
      ;;
    *"/fail"*)
      echo '{"error":"500"}' >&2
      return 1
      ;;
    *)
      echo '{"message":"ok"}'
      ;;
  esac
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
