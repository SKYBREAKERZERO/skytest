#!/usr/bin/env bash
# =============================================================================
# api_common.sh — Enterprise API Gateway · Common Library
# Version     : 2.0.0
# Description : Shared utilities: JSON logging, TraceID/RequestID, schema
#               validation, audit trail, error handling, config management.
# =============================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
readonly IGW_VERSION="2.0.0"
readonly IGW_LOG_DIR="${IGW_LOG_DIR:-/var/log/igw}"
readonly IGW_AUDIT_DIR="${IGW_AUDIT_DIR:-/var/log/igw/audit}"
readonly IGW_CONFIG_DIR="${IGW_CONFIG_DIR:-/etc/igw}"
readonly IGW_TMP_DIR="${IGW_TMP_DIR:-/tmp/igw}"
readonly IGW_LOG_FILE="${IGW_LOG_DIR}/igw.log"
readonly IGW_AUDIT_FILE="${IGW_AUDIT_DIR}/audit.jsonl"
readonly IGW_ERROR_LOG="${IGW_LOG_DIR}/error.log"
readonly IGW_MAX_LOG_SIZE_MB="${IGW_MAX_LOG_SIZE_MB:-100}"
readonly IGW_LOG_RETENTION_DAYS="${IGW_LOG_RETENTION_DAYS:-30}"

# ── Color Codes (stderr only) ────────────────────────────────────────────────
readonly C_RED='\033[0;31m'
readonly C_YEL='\033[0;33m'
readonly C_GRN='\033[0;32m'
readonly C_BLU='\033[0;34m'
readonly C_CYN='\033[0;36m'
readonly C_MGT='\033[0;35m'
readonly C_RST='\033[0m'
readonly C_BLD='\033[1m'

# ── Log Level Constants ───────────────────────────────────────────────────────
readonly LOG_DEBUG=10
readonly LOG_INFO=20
readonly LOG_WARN=30
readonly LOG_ERROR=40
readonly LOG_FATAL=50
IGW_LOG_LEVEL="${IGW_LOG_LEVEL:-20}"   # default INFO

# ── Runtime Context ───────────────────────────────────────────────────────────
IGW_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
IGW_PID=$$
IGW_SERVICE="${IGW_SERVICE:-igw}"
IGW_ENV="${IGW_ENV:-production}"

# =============================================================================
# SECTION 1: ID Generation
# =============================================================================

# Generate a UUID v4 (pure bash, no external dep)
generate_uuid() {
    local uuid
    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        # Pure bash fallback
        local hex
        hex=$(od -x /dev/urandom 2>/dev/null | head -1 | awk '{$1=""; print}' | tr -d ' \n' | head -c 32)
        uuid="${hex:0:8}-${hex:8:4}-4${hex:13:3}-$(printf '%x' $(( (0x${hex:17:2} & 0x3f) | 0x80 )))${hex:19:2}-${hex:21:12}"
    fi
    echo "$uuid"
}

# Generate TraceID (W3C Trace Context compatible: 32 hex chars)
generate_trace_id() {
    local raw
    raw=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c 32)
    echo "${raw,,}"
}

# Generate SpanID (W3C Trace Context: 16 hex chars)
generate_span_id() {
    local raw
    raw=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c 16)
    echo "${raw,,}"
}

# Generate RequestID (UUID format)
generate_request_id() {
    generate_uuid
}

# Generate CorrelationID
generate_correlation_id() {
    echo "$(date +%Y%m%d)-$(generate_span_id)"
}

# =============================================================================
# SECTION 2: JSON Utilities
# =============================================================================

# Escape a string for safe JSON embedding
json_escape() {
    local str="$1"
    # Escape backslash, double-quote, control chars
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# Build a JSON key-value pair (string value)
json_str() {
    local key="$1" val="$2"
    printf '"%s":"%s"' "$(json_escape "$key")" "$(json_escape "$val")"
}

# Build a JSON key-value pair (raw/number/bool value)
json_raw() {
    local key="$1" val="$2"
    printf '"%s":%s' "$(json_escape "$key")" "$val"
}

# Build standard envelope JSON
# Usage: json_envelope <level> <message> [extra_json_fields...]
json_envelope() {
    local level="$1"
    local message="$2"
    shift 2
    local extras="${*:-}"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    local base
    base="{"
    base+="$(json_str "timestamp" "$ts"),"
    base+="$(json_str "level" "$level"),"
    base+="$(json_str "service" "$IGW_SERVICE"),"
    base+="$(json_str "env" "$IGW_ENV"),"
    base+="$(json_str "host" "$IGW_HOSTNAME"),"
    base+="$(json_raw "pid" "$IGW_PID"),"
    base+="$(json_str "version" "$IGW_VERSION"),"
    base+="$(json_str "message" "$message")"

    # Inject context IDs if set (all use :- to be safe under set -u)
    local _tid="${IGW_TRACE_ID:-}"       ; [[ -n "$_tid"  ]] && base+=",$(json_str "traceId"       "$_tid")"
    local _sid="${IGW_SPAN_ID:-}"        ; [[ -n "$_sid"  ]] && base+=",$(json_str "spanId"         "$_sid")"
    local _rid="${IGW_REQUEST_ID:-}"     ; [[ -n "$_rid"  ]] && base+=",$(json_str "requestId"     "$_rid")"
    local _cid="${IGW_CORRELATION_ID:-}" ; [[ -n "$_cid"  ]] && base+=",$(json_str "correlationId" "$_cid")"
    local _psid="${IGW_PARENT_SPAN_ID:-}"; [[ -n "$_psid" ]] && base+=",$(json_str "parentSpanId"  "$_psid")"

    # Append any extra fields
    if [[ -n "$extras" ]]; then
        base+=",$extras"
    fi

    base+="}"
    echo "$base"
}

# =============================================================================
# SECTION 3: Structured Logging
# =============================================================================

_ensure_log_dirs() {
    mkdir -p "$IGW_LOG_DIR" "$IGW_AUDIT_DIR" "$IGW_TMP_DIR" 2>/dev/null || true
}

# Rotate log if > max size
_rotate_log_if_needed() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size_mb
        size_mb=$(( $(stat -c%s "$file" 2>/dev/null || echo 0) / 1048576 ))
        if (( size_mb >= IGW_MAX_LOG_SIZE_MB )); then
            mv "$file" "${file}.$(date +%Y%m%d%H%M%S).bak"
        fi
    fi
}

# Core log writer
_write_log() {
    local numeric_level="$1"
    local level_str="$2"
    local message="$3"
    shift 3
    local extras="${*:-}"

    # Level gate
    (( numeric_level < IGW_LOG_LEVEL )) && return 0

    _ensure_log_dirs
    _rotate_log_if_needed "$IGW_LOG_FILE"

    local json
    json=$(json_envelope "$level_str" "$message" "$extras")

    # Write to log file (JSONL format)
    echo "$json" >> "$IGW_LOG_FILE"

    # Also write errors to error log
    (( numeric_level >= LOG_ERROR )) && echo "$json" >> "$IGW_ERROR_LOG"

    # Stderr console output (colorized, human-friendly)
    local color="$C_RST"
    case "$level_str" in
        DEBUG) color="$C_CYN"  ;;
        INFO)  color="$C_GRN"  ;;
        WARN)  color="$C_YEL"  ;;
        ERROR) color="$C_RED"  ;;
        FATAL) color="$C_MGT"  ;;
    esac

    local ts_short
    ts_short=$(date +"%H:%M:%S")
    local rid="${IGW_REQUEST_ID:---------}"
    local tid_raw="${IGW_TRACE_ID:-00000000}"
    local tid="${tid_raw:0:8}..."
    printf "${C_BLD}[%s]${C_RST} ${color}%-5s${C_RST} ${C_BLU}[%s]${C_RST} ${C_CYN}rid=%-36s${C_RST} %s\n" \
        "$ts_short" "$level_str" "$IGW_SERVICE" "$rid" "$message" >&2
}

log_debug() { _write_log $LOG_DEBUG "DEBUG" "$@"; }
log_info()  { _write_log $LOG_INFO  "INFO"  "$@"; }
log_warn()  { _write_log $LOG_WARN  "WARN"  "$@"; }
log_error() { _write_log $LOG_ERROR "ERROR" "$@"; }
log_fatal() { _write_log $LOG_FATAL "FATAL" "$@"; }

# =============================================================================
# SECTION 4: Audit Trail
# =============================================================================

# Write an audit event (always written regardless of log level)
# Usage: audit_event <action> <resource> <result> [extra_fields_json]
audit_event() {
    local action="$1"
    local resource="$2"
    local result="$3"   # SUCCESS | FAILURE | DENIED | ERROR
    local extra="${4:-}"

    _ensure_log_dirs
    _rotate_log_if_needed "$IGW_AUDIT_FILE"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    local caller_user="${USER:-unknown}"
    local caller_ip="${IGW_CLIENT_IP:-127.0.0.1}"

    local json="{"
    json+="$(json_str "timestamp" "$ts"),"
    json+="$(json_str "schema" "igw-audit/v1"),"
    json+="$(json_str "service" "$IGW_SERVICE"),"
    json+="$(json_str "env" "$IGW_ENV"),"
    json+="$(json_str "host" "$IGW_HOSTNAME"),"
    json+="$(json_str "action" "$action"),"
    json+="$(json_str "resource" "$resource"),"
    json+="$(json_str "result" "$result"),"
    json+="$(json_str "actor" "$caller_user"),"
    json+="$(json_str "clientIp" "$caller_ip")"
    local _tid="${IGW_TRACE_ID:-}"       ; [[ -n "$_tid"  ]] && json+=",$(json_str "traceId"       "$_tid")"
    local _sid="${IGW_SPAN_ID:-}"        ; [[ -n "$_sid"  ]] && json+=",$(json_str "spanId"         "$_sid")"
    local _rid="${IGW_REQUEST_ID:-}"     ; [[ -n "$_rid"  ]] && json+=",$(json_str "requestId"     "$_rid")"
    local _cid="${IGW_CORRELATION_ID:-}" ; [[ -n "$_cid"  ]] && json+=",$(json_str "correlationId" "$_cid")"
    [[ -n "$extra"                  ]] && json+=",$extra"
    json+="}"

    echo "$json" >> "$IGW_AUDIT_FILE"
}

# =============================================================================
# SECTION 5: Context Management (TraceID / RequestID / SpanID)
# =============================================================================

# Initialize a new request context
# Usage: init_request_context [trace_id] [request_id]
init_request_context() {
    export IGW_TRACE_ID="${1:-$(generate_trace_id)}"
    export IGW_SPAN_ID
    IGW_SPAN_ID="$(generate_span_id)"
    export IGW_REQUEST_ID="${2:-$(generate_request_id)}"
    local _cid="${IGW_CORRELATION_ID:-}"
    export IGW_CORRELATION_ID="${_cid:-$(generate_correlation_id)}"
    local _psid="${IGW_PARENT_SPAN_ID:-}"
    export IGW_PARENT_SPAN_ID="${_psid:-}"
    export IGW_REQUEST_START_NS
    IGW_REQUEST_START_NS=$(date +%s%N 2>/dev/null || echo 0)
}

# Create a child span (for sub-operations)
push_span() {
    local span_name="${1:-unnamed}"
    local _cur="${IGW_SPAN_ID:-}"
    export IGW_PARENT_SPAN_ID="$_cur"
    export IGW_SPAN_ID
    IGW_SPAN_ID="$(generate_span_id)"
    log_debug "Span start: $span_name" "$(json_str "spanName" "$span_name")"
}

pop_span() {
    local span_name="${1:-unnamed}"
    local status="${2:-OK}"
    log_debug "Span end: $span_name" "$(json_str "spanName" "$span_name"),$(json_str "spanStatus" "$status")"
    local _psid="${IGW_PARENT_SPAN_ID:-}"
    export IGW_SPAN_ID="$_psid"
    export IGW_PARENT_SPAN_ID=""
}

# Get elapsed milliseconds since init_request_context
elapsed_ms() {
    local now_ns
    now_ns=$(date +%s%N 2>/dev/null || echo 0)
    echo $(( (now_ns - IGW_REQUEST_START_NS) / 1000000 ))
}

# =============================================================================
# SECTION 6: Schema Validation
# =============================================================================

# Validate required fields in a JSON file / string
# Usage: validate_schema <schema_name> <json_string> <field1> [field2...]
validate_schema() {
    local schema_name="$1"
    local json_str_input="$2"
    shift 2
    local required_fields=("$@")
    local errors=()

    log_debug "Schema validation: $schema_name" "$(json_str "schemaName" "$schema_name")"

    for field in "${required_fields[@]}"; do
        # Simple grep-based presence check (works without jq)
        if ! echo "$json_str_input" | grep -qE "\"${field}\"\s*:"; then
            errors+=("missing required field: $field")
        fi
    done

    if (( ${#errors[@]} > 0 )); then
        local err_list=""
        for e in "${errors[@]}"; do
            err_list+="$(json_escape "$e"),"
        done
        err_list="${err_list%,}"
        log_error "Schema validation failed: $schema_name" \
            "$(json_str "schemaName" "$schema_name"),[\"errors\":[\"$err_list\"]]"
        audit_event "SCHEMA_VALIDATE" "$schema_name" "FAILURE" \
            "$(json_str "schemaName" "$schema_name")"
        return 1
    fi

    audit_event "SCHEMA_VALIDATE" "$schema_name" "SUCCESS" \
        "$(json_str "schemaName" "$schema_name")"
    log_debug "Schema validation passed: $schema_name"
    return 0
}

# Validate JSON field type: string/number/boolean
# Usage: validate_field_type <field_name> <value> <expected_type>
validate_field_type() {
    local field="$1"
    local value="$2"
    local expected="$3"

    case "$expected" in
        number)
            if ! [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                log_error "Field '$field' must be a number, got: '$value'"
                return 1
            fi
            ;;
        boolean)
            if [[ "$value" != "true" && "$value" != "false" ]]; then
                log_error "Field '$field' must be a boolean, got: '$value'"
                return 1
            fi
            ;;
        string)
            : # any value is a valid string
            ;;
        non_empty_string)
            if [[ -z "$value" ]]; then
                log_error "Field '$field' must be a non-empty string"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown expected type '$expected' for field '$field'"
            ;;
    esac
    return 0
}

# =============================================================================
# SECTION 7: HTTP Response Builders
# =============================================================================

# Build a standard success JSON response
# Usage: response_ok <data_json> [message]
response_ok() {
    local data="${1:-null}"
    local message="${2:-OK}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    local ms
    ms=$(elapsed_ms 2>/dev/null || echo 0)
    local _rid="${IGW_REQUEST_ID:-}"
    local _tid="${IGW_TRACE_ID:-}"
    local _sid="${IGW_SPAN_ID:-}"
    local _cid="${IGW_CORRELATION_ID:-}"

    cat <<EOF
{
  "schema": "igw-response/v1",
  "status": "success",
  "code": 200,
  "message": "$(json_escape "$message")",
  "requestId": "$(json_escape "$_rid")",
  "traceId": "$(json_escape "$_tid")",
  "spanId": "$(json_escape "$_sid")",
  "correlationId": "$(json_escape "$_cid")",
  "timestamp": "$ts",
  "durationMs": $ms,
  "data": $data
}
EOF
}

response_error() {
    local http_code="${1:-500}"
    local error_code="${2:-INTERNAL_ERROR}"
    local message="${3:-Internal Server Error}"
    local details="${4:-null}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    local ms
    ms=$(elapsed_ms 2>/dev/null || echo 0)
    local _rid="${IGW_REQUEST_ID:-}"
    local _tid="${IGW_TRACE_ID:-}"
    local _sid="${IGW_SPAN_ID:-}"
    local _cid="${IGW_CORRELATION_ID:-}"

    cat <<EOF
{
  "schema": "igw-response/v1",
  "status": "error",
  "code": $http_code,
  "errorCode": "$(json_escape "$error_code")",
  "message": "$(json_escape "$message")",
  "requestId": "$(json_escape "$_rid")",
  "traceId": "$(json_escape "$_tid")",
  "spanId": "$(json_escape "$_sid")",
  "correlationId": "$(json_escape "$_cid")",
  "timestamp": "$ts",
  "durationMs": $ms,
  "details": $details
}
EOF
}

# =============================================================================
# SECTION 8: Error Handling & Traps
# =============================================================================

# Global error trap handler
igw_error_trap() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-?}"
    local cmd="${BASH_COMMAND:-?}"
    local source="${BASH_SOURCE[1]:-?}"

    log_error "Unhandled error" \
        "$(json_str "command" "$cmd"),$(json_raw "exitCode" "$exit_code"),$(json_raw "line" "$line_no"),$(json_str "source" "$source")"

    audit_event "ERROR_TRAP" "${source}:${line_no}" "ERROR" \
        "$(json_raw "exitCode" "$exit_code"),$(json_str "command" "$cmd")"
}

# Install the error trap
install_error_trap() {
    trap 'igw_error_trap' ERR
}

# Die with error response to stdout + log
die() {
    local code="${1:-500}"
    local err_code="${2:-FATAL}"
    local msg="${3:-Fatal error}"
    log_fatal "$msg" "$(json_raw "httpCode" "$code"),$(json_str "errorCode" "$err_code")"
    audit_event "DIE" "process" "FAILURE" \
        "$(json_raw "httpCode" "$code"),$(json_str "errorCode" "$err_code")"
    response_error "$code" "$err_code" "$msg"
    exit 1
}

# =============================================================================
# SECTION 9: Configuration Management
# =============================================================================

declare -A IGW_CONFIG

# Load configuration from a .env-style or KEY=VALUE file
load_config() {
    local config_file="${1:-${IGW_CONFIG_DIR}/igw.conf}"
    if [[ ! -f "$config_file" ]]; then
        log_warn "Config file not found: $config_file"
        return 0
    fi

    log_info "Loading config from: $config_file"
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        # Strip inline comments
        value="${value%%#*}"
        # Strip surrounding quotes
        value="${value#\"}" ; value="${value%\"}"
        value="${value#\'}" ; value="${value%\'}"
        # Trim whitespace
        key="${key//[[:space:]]/}"
        value="${value#"${value%%[![:space:]]*}"}"
        IGW_CONFIG["$key"]="$value"
    done < "$config_file"

    log_info "Config loaded: ${#IGW_CONFIG[@]} keys"
    audit_event "CONFIG_LOAD" "$config_file" "SUCCESS"
}

# Get a config value with optional default
cfg() {
    local key="$1"
    local default="${2:-}"
    echo "${IGW_CONFIG[$key]:-$default}"
}

# =============================================================================
# SECTION 10: Rate Limiting (token-bucket, file-based)
# =============================================================================

# Simple rate limit check using file-based counters
# Usage: check_rate_limit <key> <max_requests> <window_seconds>
check_rate_limit() {
    local key="$1"
    local max_req="${2:-100}"
    local window_sec="${3:-60}"

    local safe_key
    safe_key=$(echo "$key" | tr '/:@' '___')
    local counter_file="${IGW_TMP_DIR}/rl_${safe_key}"
    local now
    now=$(date +%s)
    local window_start=$(( now - window_sec ))

    # Remove old entries
    if [[ -f "$counter_file" ]]; then
        local tmp_file="${counter_file}.tmp"
        awk -v ws="$window_start" '$1 > ws' "$counter_file" > "$tmp_file" 2>/dev/null || true
        mv "$tmp_file" "$counter_file"
    fi

    # Count current requests
    local count=0
    [[ -f "$counter_file" ]] && count=$(wc -l < "$counter_file")

    if (( count >= max_req )); then
        log_warn "Rate limit exceeded" \
            "$(json_str "key" "$key"),$(json_raw "count" "$count"),$(json_raw "max" "$max_req"),$(json_raw "window" "$window_sec")"
        audit_event "RATE_LIMIT" "$key" "DENIED" \
            "$(json_raw "count" "$count"),$(json_raw "max" "$max_req")"
        return 1
    fi

    echo "$now" >> "$counter_file"
    return 0
}

# =============================================================================
# SECTION 11: Health Check
# =============================================================================

health_check_json() {
    local status="${1:-UP}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    local uptime_sec
    uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local _log_dir="${IGW_LOG_DIR:-/var/log/igw}"
    local _audit_dir="${IGW_AUDIT_DIR:-/var/log/igw/audit}"
    local _tmp_dir="${IGW_TMP_DIR:-/tmp/igw}"

    cat <<EOF
{
  "schema": "igw-health/v1",
  "service": "$IGW_SERVICE",
  "version": "$IGW_VERSION",
  "env": "$IGW_ENV",
  "status": "$status",
  "timestamp": "$ts",
  "host": "$IGW_HOSTNAME",
  "pid": $IGW_PID,
  "uptimeSeconds": $uptime_sec,
  "checks": {
    "logDir": $([ -d "$_log_dir" ]   && echo '"UP"' || echo '"DOWN"'),
    "auditDir": $([ -d "$_audit_dir" ] && echo '"UP"' || echo '"DOWN"'),
    "tmpDir": $([ -d "$_tmp_dir" ]   && echo '"UP"' || echo '"DOWN"')
  }
}
EOF
}

# =============================================================================
# SECTION 12: Audit Query Interface
# =============================================================================

# Query audit log by field
# Usage: audit_query <field> <value> [max_results]
audit_query() {
    local field="$1"
    local value="$2"
    local max="${3:-50}"

    if [[ ! -f "$IGW_AUDIT_FILE" ]]; then
        echo '{"error":"Audit file not found","file":"'"$IGW_AUDIT_FILE"'"}'
        return 1
    fi

    log_info "Audit query: $field=$value (max=$max)"
    grep "\"${field}\":\"${value}\"" "$IGW_AUDIT_FILE" | head -n "$max"
}

# Query audit log by time range (ISO8601 prefix match)
# Usage: audit_query_range <start_prefix> [end_prefix] [max]
audit_query_range() {
    local start_prefix="$1"
    local end_prefix="${2:-}"
    local max="${3:-100}"

    if [[ ! -f "$IGW_AUDIT_FILE" ]]; then
        echo '{"error":"Audit file not found"}'
        return 1
    fi

    if [[ -n "$end_prefix" ]]; then
        awk -v s="$start_prefix" -v e="$end_prefix" \
            '$0 ~ "\"timestamp\":\"" {
                match($0, /"timestamp":"([^"]+)"/, a)
                if (a[1] >= s && a[1] <= e) print
            }' "$IGW_AUDIT_FILE" | head -n "$max"
    else
        grep "\"timestamp\":\"${start_prefix}" "$IGW_AUDIT_FILE" | head -n "$max"
    fi
}

# Print audit stats summary
audit_stats() {
    if [[ ! -f "$IGW_AUDIT_FILE" ]]; then
        echo '{"error":"Audit file not found"}'
        return 1
    fi

    local total
    total=$(wc -l < "$IGW_AUDIT_FILE")
    local success
    success=$(grep -c '"result":"SUCCESS"' "$IGW_AUDIT_FILE" 2>/dev/null || echo 0)
    local failure
    failure=$(grep -c '"result":"FAILURE"' "$IGW_AUDIT_FILE" 2>/dev/null || echo 0)
    local denied
    denied=$(grep -c '"result":"DENIED"' "$IGW_AUDIT_FILE" 2>/dev/null || echo 0)
    local errors
    errors=$(grep -c '"result":"ERROR"' "$IGW_AUDIT_FILE" 2>/dev/null || echo 0)
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    cat <<EOF
{
  "schema": "igw-audit-stats/v1",
  "timestamp": "$ts",
  "auditFile": "$IGW_AUDIT_FILE",
  "totalEvents": $total,
  "success": $success,
  "failure": $failure,
  "denied": $denied,
  "errors": $errors
}
EOF
}

# =============================================================================
# SECTION 13: Metric Emission (Prometheus-compatible text format to file)
# =============================================================================

IGW_METRICS_FILE="${IGW_LOG_DIR}/metrics.prom"

emit_metric() {
    local name="$1"
    local value="$2"
    local labels="${3:-}"
    local help="${4:-}"
    local type="${5:-gauge}"

    _ensure_log_dirs

    {
        [[ -n "$help"   ]] && echo "# HELP ${name} ${help}"
        [[ -n "$type"   ]] && echo "# TYPE ${name} ${type}"
        if [[ -n "$labels" ]]; then
            echo "${name}{service=\"${IGW_SERVICE}\",env=\"${IGW_ENV}\",${labels}} ${value}"
        else
            echo "${name}{service=\"${IGW_SERVICE}\",env=\"${IGW_ENV}\"} ${value}"
        fi
    } >> "$IGW_METRICS_FILE"
}

# =============================================================================
# SECTION 14: Utility Functions
# =============================================================================

# URL-encode a string
url_encode() {
    local str="$1"
    local encoded=""
    local i char hex
    for (( i=0; i<${#str}; i++ )); do
        char="${str:$i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"
               encoded+="$hex" ;;
        esac
    done
    echo "$encoded"
}

# Validate that a string is a valid UUID v4
is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

# Validate that a string is a valid trace ID (32 hex chars)
is_valid_trace_id() {
    [[ "$1" =~ ^[0-9a-f]{32}$ ]]
}

# Format bytes to human-readable
format_bytes() {
    local bytes=$1
    if   (( bytes >= 1073741824 )); then printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576    )); then printf "%.2f MB" "$(echo "scale=2; $bytes/1048576" | bc)"
    elif (( bytes >= 1024       )); then printf "%.2f KB" "$(echo "scale=2; $bytes/1024" | bc)"
    else printf "%d B" "$bytes"
    fi
}

# =============================================================================
# Init message
# =============================================================================
_ensure_log_dirs
log_debug "api_common.sh loaded" \
    "$(json_str "commonVersion" "$IGW_VERSION"),$(json_str "logDir" "$IGW_LOG_DIR")"
