#!/usr/bin/env bash
# =============================================================================
# api.sh — Enterprise API Client
# Version     : 2.0.0
# Description : Full-featured HTTP API client with structured JSON logging,
#               TraceID/SpanID/RequestID, schema validation, retry logic,
#               auth, circuit breaker, and audit trail.
#
# Usage:
#   ./api.sh <command> [options]
#
# Commands:
#   call      Make an API call
#   health    Check API endpoint health
#   query     Query audit / log records
#   metrics   Show current metrics snapshot
#   validate  Validate a JSON payload against a schema
#   demo      Run a self-contained demo
#
# Environment Variables:
#   IGW_API_BASE_URL   Base URL of the API (default: http://localhost:8080)
#   IGW_API_KEY        API key for authentication
#   IGW_API_TIMEOUT    Curl timeout in seconds (default: 30)
#   IGW_LOG_LEVEL      10=DEBUG 20=INFO 30=WARN 40=ERROR (default: 20)
#   IGW_ENV            Environment name (default: production)
#   IGW_SERVICE        Service name for log tagging (default: api-client)
#   IGW_TRACE_ID       Override trace ID (auto-generated if absent)
#   IGW_REQUEST_ID     Override request ID (auto-generated if absent)
# =============================================================================
set -euo pipefail

# ── Resolve script directory ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Load common library ───────────────────────────────────────────────────────
if [[ ! -f "${SCRIPT_DIR}/api_common.sh" ]]; then
    echo '{"level":"FATAL","message":"api_common.sh not found","script":"api.sh"}' >&2
    exit 1
fi
# shellcheck source=api_common.sh
source "${SCRIPT_DIR}/api_common.sh"

# ── Service identity ──────────────────────────────────────────────────────────
IGW_SERVICE="${IGW_SERVICE:-api-client}"

# ── API Client defaults ───────────────────────────────────────────────────────
readonly API_BASE_URL="${IGW_API_BASE_URL:-http://localhost:8080}"
readonly API_KEY="${IGW_API_KEY:-}"
readonly API_TIMEOUT="${IGW_API_TIMEOUT:-30}"
readonly API_MAX_RETRIES="${IGW_API_MAX_RETRIES:-3}"
readonly API_RETRY_DELAY="${IGW_API_RETRY_DELAY:-1}"   # seconds
readonly API_RETRY_BACKOFF="${IGW_API_RETRY_BACKOFF:-2}" # multiplier

# Circuit breaker state file
readonly CB_STATE_FILE="${IGW_TMP_DIR}/cb_api_state"
readonly CB_OPEN_THRESHOLD="${IGW_CB_OPEN_THRESHOLD:-5}"
readonly CB_HALF_OPEN_WAIT="${IGW_CB_HALF_OPEN_WAIT:-30}"

# =============================================================================
# SECTION A: HTTP Client
# =============================================================================

# Check curl is available
_require_curl() {
    if ! command -v curl &>/dev/null; then
        die 500 "DEPENDENCY_MISSING" "curl is required but not installed"
    fi
}

# Build standard request headers
_build_headers() {
    local -n _hdrs=$1  # nameref to array
    _hdrs=(
        "-H" "Content-Type: application/json"
        "-H" "Accept: application/json"
        "-H" "X-Request-Id: ${IGW_REQUEST_ID}"
        "-H" "X-Trace-Id: ${IGW_TRACE_ID}"
        "-H" "X-Span-Id: ${IGW_SPAN_ID}"
        "-H" "X-Correlation-Id: ${IGW_CORRELATION_ID}"
        "-H" "X-B3-TraceId: ${IGW_TRACE_ID}"
        "-H" "X-B3-SpanId: ${IGW_SPAN_ID}"
        "-H" "traceparent: 00-${IGW_TRACE_ID}-${IGW_SPAN_ID}-01"
        "-H" "User-Agent: IGW-ApiClient/${IGW_VERSION}"
    )
    [[ -n "$API_KEY" ]] && _hdrs+=("-H" "Authorization: Bearer ${API_KEY}")
}

# =============================================================================
# SECTION B: Circuit Breaker
# =============================================================================

cb_get_state() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "CLOSED 0 0"
        return
    fi
    cat "$CB_STATE_FILE"
}

cb_record_failure() {
    local state failures last_fail_ts
    read -r state failures last_fail_ts < <(cb_get_state)
    failures=$(( ${failures:-0} + 1 ))
    last_fail_ts=$(date +%s)

    if (( failures >= CB_OPEN_THRESHOLD )); then
        state="OPEN"
        log_warn "Circuit breaker OPEN" \
            "$(json_raw "failures" "$failures"),$(json_raw "threshold" "$CB_OPEN_THRESHOLD")"
        audit_event "CIRCUIT_BREAKER" "api" "FAILURE" \
            "$(json_str "state" "OPEN"),$(json_raw "failures" "$failures")"
    fi
    echo "$state $failures $last_fail_ts" > "$CB_STATE_FILE"
}

cb_record_success() {
    echo "CLOSED 0 0" > "$CB_STATE_FILE"
}

cb_is_allowed() {
    local state failures last_fail_ts now
    read -r state failures last_fail_ts < <(cb_get_state)
    now=$(date +%s)

    case "$state" in
        CLOSED)    return 0 ;;
        HALF_OPEN) return 0 ;;
        OPEN)
            if (( now - ${last_fail_ts:-0} >= CB_HALF_OPEN_WAIT )); then
                log_info "Circuit breaker → HALF_OPEN"
                echo "HALF_OPEN $failures $last_fail_ts" > "$CB_STATE_FILE"
                return 0
            fi
            log_warn "Circuit breaker OPEN — request blocked"
            return 1
            ;;
    esac
    return 0
}

# =============================================================================
# SECTION C: Core API Call
# =============================================================================

# Make an authenticated, traced, retried HTTP request
# Usage: api_call <METHOD> <PATH> [body_json] [extra_curl_opts...]
# Outputs: JSON to stdout; returns 0 on success, 1 on error
api_call() {
    local method="${1:?method required}"
    local path="${2:?path required}"
    local body="${3:-}"
    shift 3 || true
    local extra_opts=("$@")

    method="${method^^}"
    local url="${API_BASE_URL}${path}"
    local attempt=0
    local delay="$API_RETRY_DELAY"
    local response http_code curl_exit

    _require_curl

    # Circuit breaker check
    if ! cb_is_allowed; then
        response=$(response_error 503 "CIRCUIT_OPEN" \
            "Circuit breaker is OPEN, refusing request to protect downstream")
        echo "$response"
        audit_event "API_CALL" "${method} ${path}" "DENIED" \
            "$(json_str "reason" "circuit_breaker_open")"
        return 1
    fi

    push_span "api_call:${method}:${path}"

    log_info "API call: ${method} ${url}" \
        "$(json_str "method" "$method"),$(json_str "url" "$url"),$(json_raw "timeout" "$API_TIMEOUT")"

    # Build headers array
    local -a headers
    _build_headers headers

    while (( attempt < API_MAX_RETRIES )); do
        attempt=$(( attempt + 1 ))
        log_debug "Attempt $attempt/${API_MAX_RETRIES}: ${method} ${url}"

        # Tmp files for response body and headers
        local resp_body_file="${IGW_TMP_DIR}/resp_body_$$.tmp"
        local resp_hdr_file="${IGW_TMP_DIR}/resp_hdr_$$.tmp"

        # Build curl command
        local -a curl_cmd=(
            curl
            --silent
            --show-error
            --max-time "$API_TIMEOUT"
            --connect-timeout 10
            --write-out "%{http_code}"
            --output "$resp_body_file"
            --dump-header "$resp_hdr_file"
            -X "$method"
            "${headers[@]}"
        )

        # Attach body for methods that support it
        if [[ -n "$body" && "$method" =~ ^(POST|PUT|PATCH)$ ]]; then
            curl_cmd+=("--data" "$body")
        fi

        # Extra options passed in (e.g. --insecure, --cacert)
        curl_cmd+=("${extra_opts[@]}")
        curl_cmd+=("$url")

        curl_exit=0
        http_code=$("${curl_cmd[@]}" 2>/tmp/curl_stderr_$$.tmp) || curl_exit=$?

        local resp_body=""
        [[ -f "$resp_body_file" ]] && resp_body=$(cat "$resp_body_file")
        rm -f "$resp_body_file" "$resp_hdr_file" /tmp/curl_stderr_$$.tmp

        local curl_err=""
        [[ -f /tmp/curl_stderr_$$.tmp ]] && curl_err=$(cat /tmp/curl_stderr_$$.tmp)

        # Network / curl error
        if (( curl_exit != 0 )); then
            log_error "curl failed (exit=$curl_exit attempt=$attempt)" \
                "$(json_raw "curlExit" "$curl_exit"),$(json_str "url" "$url"),$(json_str "curlErr" "${curl_err:-}")"

            if (( attempt < API_MAX_RETRIES )); then
                log_warn "Retrying in ${delay}s..."
                sleep "$delay"
                delay=$(( delay * API_RETRY_BACKOFF ))
                continue
            fi

            cb_record_failure
            local err_resp
            err_resp=$(response_error 503 "NETWORK_ERROR" \
                "Network error after $attempt attempts" \
                "{\"curlExit\":$curl_exit,\"url\":\"$(json_escape "$url")\"}")
            audit_event "API_CALL" "${method} ${path}" "ERROR" \
                "$(json_str "url" "$url"),$(json_raw "curlExit" "$curl_exit"),$(json_raw "attempts" "$attempt")"
            echo "$err_resp"
            pop_span "api_call:${method}:${path}" "ERROR"
            return 1
        fi

        # HTTP-level error handling
        local ms
        ms=$(elapsed_ms)

        if (( http_code >= 500 )); then
            log_error "HTTP ${http_code} from server (attempt=$attempt)" \
                "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url")"

            if (( attempt < API_MAX_RETRIES )); then
                log_warn "Retrying in ${delay}s due to server error..."
                sleep "$delay"
                delay=$(( delay * API_RETRY_BACKOFF ))
                continue
            fi

            cb_record_failure
            emit_metric "igw_api_error_total" 1 \
                "method=\"$method\",status=\"$http_code\",path=\"${path:0:64}\"" \
                "Total API errors" "counter"
            audit_event "API_CALL" "${method} ${path}" "ERROR" \
                "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url"),$(json_raw "attempts" "$attempt")"

            pop_span "api_call:${method}:${path}" "ERROR"
            echo "$resp_body"
            return 1

        elif (( http_code >= 400 )); then
            log_warn "HTTP ${http_code} client error" \
                "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url")"
            emit_metric "igw_api_client_error_total" 1 \
                "method=\"$method\",status=\"$http_code\",path=\"${path:0:64}\"" \
                "Total API client errors" "counter"
            audit_event "API_CALL" "${method} ${path}" "FAILURE" \
                "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url")"

            pop_span "api_call:${method}:${path}" "CLIENT_ERROR"
            echo "$resp_body"
            return 1
        fi

        # Success
        cb_record_success
        emit_metric "igw_api_call_total" 1 \
            "method=\"$method\",status=\"$http_code\",path=\"${path:0:64}\"" \
            "Total successful API calls" "counter"
        emit_metric "igw_api_duration_ms" "$ms" \
            "method=\"$method\",path=\"${path:0:64}\"" \
            "API call duration in ms" "gauge"

        log_info "API call success: HTTP ${http_code}" \
            "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url"),$(json_raw "durationMs" "$ms"),$(json_raw "attempts" "$attempt")"
        audit_event "API_CALL" "${method} ${path}" "SUCCESS" \
            "$(json_raw "httpCode" "$http_code"),$(json_str "url" "$url"),$(json_raw "durationMs" "$ms")"

        pop_span "api_call:${method}:${path}" "OK"
        echo "$resp_body"
        return 0
    done

    # Should not reach here
    pop_span "api_call:${method}:${path}" "UNKNOWN"
    return 1
}

# Convenience wrappers
api_get()    { api_call "GET"    "$@"; }
api_post()   { api_call "POST"   "$@"; }
api_put()    { api_call "PUT"    "$@"; }
api_patch()  { api_call "PATCH"  "$@"; }
api_delete() { api_call "DELETE" "$1" "" "${@:2}"; }

# =============================================================================
# SECTION D: Schema Definitions
# =============================================================================

# Validate a "create user" payload
validate_user_schema() {
    local json_input="$1"
    validate_schema "user/create/v1" "$json_input" \
        "username" "email" "role"
}

# Validate a "create order" payload
validate_order_schema() {
    local json_input="$1"
    validate_schema "order/create/v1" "$json_input" \
        "orderId" "userId" "items" "totalAmount"
}

# Validate a generic API request envelope
validate_request_envelope() {
    local json_input="$1"
    validate_schema "api-request/v1" "$json_input" \
        "requestId" "timestamp" "payload"
}

# =============================================================================
# SECTION E: Business-level API Operations
# =============================================================================

# List resources
op_list_resources() {
    local resource_type="${1:?resource type required}"
    local page="${2:-1}"
    local page_size="${3:-20}"

    log_info "Listing resources: $resource_type" \
        "$(json_str "resourceType" "$resource_type"),$(json_raw "page" "$page"),$(json_raw "pageSize" "$page_size")"
    push_span "list_resources:$resource_type"

    local resp
    resp=$(api_get "/${resource_type}?page=${page}&pageSize=${page_size}")
    local rc=$?

    pop_span "list_resources:$resource_type" "$(( rc==0 ? 'OK' : 'ERROR' ))"
    echo "$resp"
    return $rc
}

# Create a resource with schema validation
op_create_resource() {
    local resource_type="${1:?resource type required}"
    local payload="${2:?payload required}"
    local schema_name="${3:-generic/v1}"

    log_info "Creating resource: $resource_type" \
        "$(json_str "resourceType" "$resource_type"),$(json_str "schema" "$schema_name")"
    push_span "create_resource:$resource_type"

    local resp
    resp=$(api_post "/${resource_type}" "$payload")
    local rc=$?

    audit_event "RESOURCE_CREATE" "$resource_type" \
        "$(( rc==0 ? 'SUCCESS' : 'ERROR' ))" \
        "$(json_str "schema" "$schema_name")"

    pop_span "create_resource:$resource_type" "$(( rc==0 ? 'OK' : 'ERROR' ))"
    echo "$resp"
    return $rc
}

# =============================================================================
# SECTION F: Commands
# =============================================================================

cmd_call() {
    # Usage: api.sh call <METHOD> <PATH> [body_json]
    local method="${1:?METHOD required (GET|POST|PUT|PATCH|DELETE)}"
    local path="${2:?PATH required (e.g. /users)}"
    local body="${3:-}"

    init_request_context
    install_error_trap

    log_info "Command: call" \
        "$(json_str "method" "$method"),$(json_str "path" "$path")"

    if [[ -n "$body" ]]; then
        validate_schema "request-body/v1" "$body" || true
    fi

    api_call "$method" "$path" "$body"
}

cmd_health() {
    # Usage: api.sh health [path]
    local path="${1:-/health}"
    init_request_context
    install_error_trap

    log_info "Health check: ${API_BASE_URL}${path}"

    local resp
    resp=$(api_call "GET" "$path" "" --fail-with-body || true)
    echo "$resp"
    health_check_json "UP"
}

cmd_query() {
    # Usage: api.sh query <field> <value> [max]
    local field="${1:?field required}"
    local value="${2:?value required}"
    local max="${3:-50}"

    init_request_context
    log_info "Audit query: $field=$value"

    echo "=== Audit Query Results: $field=$value (max=$max) ==="
    audit_query "$field" "$value" "$max"
    echo ""
    echo "=== Audit Stats ==="
    audit_stats
}

cmd_metrics() {
    init_request_context
    if [[ -f "$IGW_METRICS_FILE" ]]; then
        cat "$IGW_METRICS_FILE"
    else
        echo "# No metrics collected yet. Run some API calls first."
    fi
    audit_stats
}

cmd_validate() {
    # Usage: api.sh validate <schema_name> <json_string_or_file> [fields...]
    local schema_name="${1:?schema name required}"
    local input="${2:?json input or file required}"
    shift 2
    local fields=("$@")

    init_request_context

    local json_data
    if [[ -f "$input" ]]; then
        json_data=$(cat "$input")
    else
        json_data="$input"
    fi

    if (( ${#fields[@]} == 0 )); then
        log_warn "No required fields specified — performing basic JSON parse check"
        if echo "$json_data" | grep -q '^{'; then
            response_ok '{"valid":true}' "Basic JSON check passed"
        else
            response_error 400 "INVALID_JSON" "Input does not look like a JSON object"
        fi
        return
    fi

    if validate_schema "$schema_name" "$json_data" "${fields[@]}"; then
        response_ok "{\"valid\":true,\"schema\":\"$(json_escape "$schema_name")\"}" "Schema validation passed"
    else
        response_error 422 "SCHEMA_VALIDATION_FAILED" "Payload does not match schema: $schema_name"
    fi
}

cmd_demo() {
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│   Enterprise API Client · Demo Mode                            │"
    echo "│   All calls logged to: $IGW_LOG_FILE"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    init_request_context
    install_error_trap

    log_info "Demo started"

    # ── Demo 1: Schema validation ─────────────────────────────────────────
    echo "── Demo 1: Schema Validation ────────────────────────────────────"
    local user_payload='{"username":"alice","email":"alice@example.com","role":"admin","createdAt":"2024-01-01T00:00:00Z"}'
    cmd_validate "user/create/v1" "$user_payload" username email role
    echo ""

    # ── Demo 2: Schema validation failure ────────────────────────────────
    echo "── Demo 2: Schema Validation Failure ───────────────────────────"
    local bad_payload='{"username":"bob"}'
    cmd_validate "user/create/v1" "$bad_payload" username email role || true
    echo ""

    # ── Demo 3: Audit trail ───────────────────────────────────────────────
    echo "── Demo 3: Audit Trail Entries ─────────────────────────────────"
    audit_event "DEMO_ACTION" "/demo/resource" "SUCCESS" \
        "$(json_str "detail" "demo audit event")"
    audit_event "DEMO_LOGIN" "/auth/login" "SUCCESS" \
        "$(json_str "actor" "alice"),$(json_str "method" "password")"
    audit_event "DEMO_ACCESS" "/admin/users" "DENIED" \
        "$(json_str "actor" "guest"),$(json_str "reason" "insufficient_permissions")"

    echo "(3 audit events written to $IGW_AUDIT_FILE)"
    echo ""

    # ── Demo 4: Rate limiting ─────────────────────────────────────────────
    echo "── Demo 4: Rate Limiting (5 req / 60s window) ──────────────────"
    local rl_key="demo:user:alice"
    local i
    for i in $(seq 1 7); do
        if check_rate_limit "$rl_key" 5 60; then
            echo "  Request $i: ALLOWED"
        else
            echo "  Request $i: RATE LIMITED"
        fi
    done
    echo ""

    # ── Demo 5: Health check ──────────────────────────────────────────────
    echo "── Demo 5: Health Check JSON ───────────────────────────────────"
    health_check_json "UP"
    echo ""

    # ── Demo 6: Simulated API call (httpbin.org) ──────────────────────────
    echo "── Demo 6: Simulated API Call (httpbin.org/get) ─────────────────"
    IGW_API_BASE_URL="${IGW_API_BASE_URL:-https://httpbin.org}"
    export IGW_API_BASE_URL
    local resp
    if resp=$(api_call "GET" "/get" "" --max-time 10 2>/dev/null); then
        echo "API call succeeded (truncated response):"
        echo "$resp" | head -c 400
        echo ""
    else
        echo "(API call skipped — no network or demo endpoint unavailable)"
    fi
    echo ""

    # ── Demo 7: Audit query ───────────────────────────────────────────────
    echo "── Demo 7: Audit Query ─────────────────────────────────────────"
    echo "  Querying audit for action=DEMO_ACTION:"
    audit_query "action" "DEMO_ACTION" 10
    echo ""
    echo "  Audit Stats:"
    audit_stats
    echo ""

    # ── Demo 8: Metrics dump ──────────────────────────────────────────────
    echo "── Demo 8: Prometheus Metrics ──────────────────────────────────"
    emit_metric "igw_demo_runs_total" 1 "" "Total demo runs" "counter"
    cat "$IGW_METRICS_FILE" 2>/dev/null | head -20 || echo "(no metrics yet)"
    echo ""

    # ── Demo 9: Context IDs ───────────────────────────────────────────────
    echo "── Demo 9: Trace Context ───────────────────────────────────────"
    cat <<EOF
{
  "schema":        "igw-trace-context/v1",
  "traceId":       "${IGW_TRACE_ID}",
  "spanId":        "${IGW_SPAN_ID}",
  "requestId":     "${IGW_REQUEST_ID}",
  "correlationId": "${IGW_CORRELATION_ID}",
  "w3cHeader":     "00-${IGW_TRACE_ID}-${IGW_SPAN_ID}-01"
}
EOF
    echo ""
    echo "✓ Demo complete. Logs: $IGW_LOG_FILE"
    echo "✓ Audit:  $IGW_AUDIT_FILE"
}

# =============================================================================
# SECTION G: CLI Dispatcher
# =============================================================================

usage() {
    cat <<EOF
${C_BLD}api.sh${C_RST} — Enterprise API Client v${IGW_VERSION}

${C_BLD}USAGE${C_RST}
  api.sh <command> [options]

${C_BLD}COMMANDS${C_RST}
  call      <METHOD> <PATH> [body_json]          Make an API call
  health    [path]                               Health check (default: /health)
  query     <field> <value> [max_results]        Query audit log
  metrics                                        Show Prometheus metrics
  validate  <schema_name> <json_or_file> [fields...] Validate JSON schema
  demo                                           Run a built-in demo

${C_BLD}ENVIRONMENT${C_RST}
  IGW_API_BASE_URL   Base API URL           (default: http://localhost:8080)
  IGW_API_KEY        Bearer token
  IGW_API_TIMEOUT    Curl timeout seconds   (default: 30)
  IGW_API_MAX_RETRIES Max retry count       (default: 3)
  IGW_LOG_LEVEL      10/20/30/40            (default: 20=INFO)
  IGW_ENV            Environment tag        (default: production)
  IGW_TRACE_ID       Override trace ID
  IGW_REQUEST_ID     Override request ID
  IGW_LOG_DIR        Log directory          (default: /var/log/igw)

${C_BLD}EXAMPLES${C_RST}
  api.sh call GET /users
  api.sh call POST /users '{"username":"alice","email":"a@b.com","role":"user"}'
  api.sh health /health
  api.sh query action API_CALL 20
  api.sh validate user/v1 '{"username":"x","email":"x@x.com","role":"admin"}' username email role
  api.sh demo

${C_BLD}OUTPUT FORMAT${C_RST}
  All responses use schema igw-response/v1:
  { "schema", "status", "code", "requestId", "traceId", "spanId",
    "correlationId", "timestamp", "durationMs", "data" }

EOF
}

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        call)     cmd_call     "$@" ;;
        health)   cmd_health   "$@" ;;
        query)    cmd_query    "$@" ;;
        metrics)  cmd_metrics        ;;
        validate) cmd_validate "$@" ;;
        demo)     cmd_demo           ;;
        help|-h|--help) usage        ;;
        "")
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
