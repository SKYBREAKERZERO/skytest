#!/usr/bin/env bash
# =============================================================================
# igw.sh — Enterprise API Gateway (IGW)
# Version     : 2.0.0
# Description : Full-featured API Gateway: request routing, auth, rate
#               limiting, upstream proxy, circuit breaker, structured JSON
#               logging, TraceID/SpanID/RequestID, schema validation, audit
#               trail, metrics, and a netcat-based HTTP listener.
#
# Usage:
#   ./igw.sh <command> [options]
#
# Commands:
#   start     Start the gateway listener
#   stop      Stop the gateway
#   status    Show gateway process status
#   audit     Audit log query / stats
#   metrics   Show Prometheus metrics
#   reload    Reload configuration
#   health    Self health check
#   logs      Tail gateway log
#   demo      Run gateway demonstration
#
# Environment Variables:
#   IGW_LISTEN_PORT  Port to listen on (default: 8888)
#   IGW_LISTEN_HOST  Host to bind to   (default: 0.0.0.0)
#   IGW_UPSTREAM_URL Upstream base URL  (default: http://localhost:8080)
#   IGW_API_KEY      API key for upstream calls
#   IGW_LOG_LEVEL    10=DEBUG 20=INFO 30=WARN 40=ERROR (default: 20)
#   IGW_ENV          Environment name   (default: production)
#   IGW_CONFIG_FILE  Config file path   (default: /etc/igw/igw.conf)
# =============================================================================
set -euo pipefail

# ── Resolve script directory ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Load common library ───────────────────────────────────────────────────────
if [[ ! -f "${SCRIPT_DIR}/api_common.sh" ]]; then
    echo '{"level":"FATAL","message":"api_common.sh not found","script":"igw.sh"}' >&2
    exit 1
fi
source "${SCRIPT_DIR}/api_common.sh"

# ── Service identity ──────────────────────────────────────────────────────────
IGW_SERVICE="${IGW_SERVICE:-igw-gateway}"

# ── Gateway configuration ─────────────────────────────────────────────────────
readonly GATEWAY_LISTEN_PORT="${IGW_LISTEN_PORT:-8888}"
readonly GATEWAY_LISTEN_HOST="${IGW_LISTEN_HOST:-0.0.0.0}"
readonly GATEWAY_UPSTREAM_URL="${IGW_UPSTREAM_URL:-http://localhost:8080}"
readonly GATEWAY_PID_FILE="${IGW_TMP_DIR}/igw.pid"
readonly GATEWAY_SOCKET_FILE="${IGW_TMP_DIR}/igw.sock"
readonly GATEWAY_CONFIG_FILE="${IGW_CONFIG_FILE:-${IGW_CONFIG_DIR}/igw.conf}"

# Auth tokens (comma-separated in env, or loaded from config)
readonly IGW_VALID_TOKENS="${IGW_VALID_TOKENS:-igw-demo-token-001,igw-demo-token-002}"

# Rate limit defaults
readonly GW_RATE_LIMIT_REQ="${IGW_RATE_LIMIT_REQ:-100}"
readonly GW_RATE_LIMIT_WIN="${IGW_RATE_LIMIT_WIN:-60}"

# =============================================================================
# SECTION A: Route Table
# =============================================================================

declare -A ROUTE_TABLE
declare -A ROUTE_UPSTREAM
declare -A ROUTE_AUTH_REQUIRED
declare -A ROUTE_RATE_LIMIT
declare -A ROUTE_SCHEMA

# Register a route
# Usage: register_route <method> <path_prefix> <upstream_path> [auth=true] [rate=100] [schema=]
register_route() {
    local method="${1:?}"
    local path_prefix="${2:?}"
    local upstream_path="${3:?}"
    local auth="${4:-true}"
    local rate="${5:-$GW_RATE_LIMIT_REQ}"
    local schema="${6:-}"

    local key="${method}:${path_prefix}"
    ROUTE_TABLE["$key"]="$upstream_path"
    ROUTE_UPSTREAM["$key"]="$GATEWAY_UPSTREAM_URL"
    ROUTE_AUTH_REQUIRED["$key"]="$auth"
    ROUTE_RATE_LIMIT["$key"]="$rate"
    ROUTE_SCHEMA["$key"]="$schema"

    log_debug "Route registered: ${method} ${path_prefix} → ${GATEWAY_UPSTREAM_URL}${upstream_path}" \
        "$(json_str "method" "$method"),$(json_str "prefix" "$path_prefix"),$(json_str "auth" "$auth")"
}

# Load default routes
load_default_routes() {
    register_route "GET"    "/health"      "/health"           "false" "1000"
    register_route "GET"    "/metrics"     "/metrics"          "false" "100"
    register_route "GET"    "/api/v1/users"    "/users"        "true"  "200"  "user/list/v1"
    register_route "POST"   "/api/v1/users"    "/users"        "true"  "50"   "user/create/v1"
    register_route "GET"    "/api/v1/orders"   "/orders"       "true"  "200"  "order/list/v1"
    register_route "POST"   "/api/v1/orders"   "/orders"       "true"  "50"   "order/create/v1"
    register_route "GET"    "/api/v1/products" "/products"     "true"  "500"
    register_route "GET"    "/api/v1/"         "/"             "true"  "100"
    register_route "POST"   "/api/v1/"         "/"             "true"  "50"

    log_info "Default routes loaded: ${#ROUTE_TABLE[@]} routes"
    audit_event "ROUTES_LOAD" "route-table" "SUCCESS" \
        "$(json_raw "count" "${#ROUTE_TABLE[@]}")"
}

# Match incoming path to route key
match_route() {
    local method="$1"
    local path="$2"

    # Exact match first
    local key="${method}:${path}"
    if [[ -n "${ROUTE_TABLE[$key]:-}" ]]; then
        echo "$key"
        return 0
    fi

    # Longest prefix match
    local best_key=""
    local best_len=0
    for route_key in "${!ROUTE_TABLE[@]}"; do
        local r_method="${route_key%%:*}"
        local r_prefix="${route_key#*:}"
        if [[ "$r_method" == "$method" && "$path" == "$r_prefix"* ]]; then
            local prefix_len="${#r_prefix}"
            if (( prefix_len > best_len )); then
                best_len=$prefix_len
                best_key="$route_key"
            fi
        fi
    done

    if [[ -n "$best_key" ]]; then
        echo "$best_key"
        return 0
    fi

    return 1
}

# =============================================================================
# SECTION B: Authentication
# =============================================================================

# Validate a Bearer token
validate_token() {
    local token="$1"
    [[ -z "$token" ]] && return 1

    local valid_token
    IFS=',' read -ra valid_tokens <<< "$IGW_VALID_TOKENS"
    for valid_token in "${valid_tokens[@]}"; do
        valid_token="${valid_token//[[:space:]]/}"
        if [[ "$token" == "$valid_token" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract Bearer token from Authorization header value
extract_bearer_token() {
    local auth_header="$1"
    if [[ "$auth_header" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# =============================================================================
# SECTION C: Request Processor
# =============================================================================

# Process a single gateway request
# Input env: IGW_GW_METHOD, IGW_GW_PATH, IGW_GW_HEADERS_FILE, IGW_GW_BODY_FILE
process_request() {
    local method="${IGW_GW_METHOD:?}"
    local path="${IGW_GW_PATH:?}"
    local client_ip="${IGW_CLIENT_IP:-unknown}"
    local auth_header="${IGW_AUTH_HEADER:-}"
    local body_file="${IGW_GW_BODY_FILE:-}"

    init_request_context \
        "${IGW_INCOMING_TRACE_ID:-}" \
        "${IGW_INCOMING_REQUEST_ID:-}"
    install_error_trap

    log_info "→ Incoming: ${method} ${path}" \
        "$(json_str "method" "$method"),$(json_str "path" "$path"),$(json_str "clientIp" "$client_ip")"

    # ── Route matching ────────────────────────────────────────────────────
    local route_key
    if ! route_key=$(match_route "$method" "$path"); then
        log_warn "Route not found: ${method} ${path}"
        audit_event "REQUEST" "${method} ${path}" "FAILURE" \
            "$(json_str "reason" "route_not_found"),$(json_str "clientIp" "$client_ip")"
        response_error 404 "ROUTE_NOT_FOUND" "No route matches ${method} ${path}"
        emit_metric "igw_request_total" 1 \
            "method=\"$method\",status=\"404\",route=\"not_found\"" \
            "Total gateway requests" "counter"
        return 1
    fi

    local upstream_path="${ROUTE_TABLE[$route_key]}"
    local auth_required="${ROUTE_AUTH_REQUIRED[$route_key]}"
    local rate_limit="${ROUTE_RATE_LIMIT[$route_key]}"
    local schema_name="${ROUTE_SCHEMA[$route_key]:-}"

    log_debug "Route matched: $route_key → $upstream_path" \
        "$(json_str "routeKey" "$route_key"),$(json_str "upstreamPath" "$upstream_path")"

    # ── Authentication ────────────────────────────────────────────────────
    if [[ "$auth_required" == "true" ]]; then
        local token
        token=$(extract_bearer_token "$auth_header")

        if ! validate_token "$token"; then
            log_warn "Authentication failed" \
                "$(json_str "path" "$path"),$(json_str "clientIp" "$client_ip")"
            audit_event "AUTHN" "${method} ${path}" "DENIED" \
                "$(json_str "clientIp" "$client_ip"),$(json_str "reason" "invalid_or_missing_token")"
            response_error 401 "UNAUTHORIZED" "Authentication required or token invalid"
            emit_metric "igw_auth_failure_total" 1 \
                "path=\"${path:0:64}\"" "Auth failures" "counter"
            return 1
        fi

        log_debug "Auth OK" "$(json_str "path" "$path")"
        audit_event "AUTHN" "${method} ${path}" "SUCCESS" \
            "$(json_str "clientIp" "$client_ip")"
    fi

    # ── Rate limiting ─────────────────────────────────────────────────────
    local rl_key="${client_ip}:${method}:${path%%/*}"
    if ! check_rate_limit "$rl_key" "$rate_limit" "$GW_RATE_LIMIT_WIN"; then
        response_error 429 "RATE_LIMITED" \
            "Too many requests. Limit: ${rate_limit} per ${GW_RATE_LIMIT_WIN}s" \
            "{\"limit\":${rate_limit},\"window\":${GW_RATE_LIMIT_WIN}}"
        emit_metric "igw_ratelimit_total" 1 \
            "path=\"${path:0:64}\"" "Rate limit hits" "counter"
        return 1
    fi

    # ── Body / schema validation ──────────────────────────────────────────
    local body=""
    [[ -f "${body_file:-}" ]] && body=$(cat "$body_file")

    if [[ -n "$schema_name" && -n "$body" && "$method" =~ ^(POST|PUT|PATCH)$ ]]; then
        push_span "schema_validate:$schema_name"
        if ! validate_schema "$schema_name" "$body"; then
            pop_span "schema_validate:$schema_name" "FAIL"
            response_error 422 "SCHEMA_VALIDATION_FAILED" \
                "Request body does not match schema: $schema_name" \
                "{\"schema\":\"$(json_escape "$schema_name")\"}"
            return 1
        fi
        pop_span "schema_validate:$schema_name" "OK"
    fi

    # ── Upstream proxy ────────────────────────────────────────────────────
    local upstream_url="${ROUTE_UPSTREAM[$route_key]}${upstream_path}"
    # Append query string from original path if any
    if [[ "$path" == *"?"* ]]; then
        local qs="${path#*?}"
        upstream_url="${upstream_url}?${qs}"
    fi

    log_info "→ Proxying to upstream: ${upstream_url}" \
        "$(json_str "upstream" "$upstream_url"),$(json_str "method" "$method")"

    push_span "upstream_proxy"

    local upstream_resp upstream_code upstream_exit=0
    local resp_file="${IGW_TMP_DIR}/upstream_resp_$$.tmp"

    local -a proxy_headers=(
        "-H" "Content-Type: application/json"
        "-H" "Accept: application/json"
        "-H" "X-Request-Id: ${IGW_REQUEST_ID}"
        "-H" "X-Trace-Id: ${IGW_TRACE_ID}"
        "-H" "X-Span-Id: ${IGW_SPAN_ID}"
        "-H" "X-Correlation-Id: ${IGW_CORRELATION_ID}"
        "-H" "X-Forwarded-For: ${client_ip}"
        "-H" "X-Forwarded-Host: ${GATEWAY_LISTEN_HOST}:${GATEWAY_LISTEN_PORT}"
        "-H" "traceparent: 00-${IGW_TRACE_ID}-${IGW_SPAN_ID}-01"
        "-H" "X-IGW-Version: ${IGW_VERSION}"
    )
    [[ -n "$IGW_API_KEY" ]] && proxy_headers+=("-H" "Authorization: Bearer ${IGW_API_KEY}")

    local -a curl_cmd=(
        curl --silent --show-error
        --max-time "${IGW_API_TIMEOUT:-30}"
        --write-out "%{http_code}"
        --output "$resp_file"
        -X "$method"
        "${proxy_headers[@]}"
    )

    if [[ -n "$body" && "$method" =~ ^(POST|PUT|PATCH)$ ]]; then
        curl_cmd+=("--data" "$body")
    fi

    curl_cmd+=("$upstream_url")

    upstream_code=$("${curl_cmd[@]}" 2>/dev/null) || upstream_exit=$?
    upstream_resp=""
    [[ -f "$resp_file" ]] && upstream_resp=$(cat "$resp_file")
    rm -f "$resp_file"

    local ms
    ms=$(elapsed_ms)

    if (( upstream_exit != 0 )); then
        log_error "Upstream unreachable" \
            "$(json_str "upstream" "$upstream_url"),$(json_raw "exit" "$upstream_exit")"
        pop_span "upstream_proxy" "ERROR"
        audit_event "PROXY" "${method} ${path}" "ERROR" \
            "$(json_str "upstream" "$upstream_url"),$(json_raw "curlExit" "$upstream_exit"),$(json_raw "durationMs" "$ms")"
        response_error 502 "BAD_GATEWAY" "Upstream service unavailable" \
            "{\"upstream\":\"$(json_escape "$upstream_url")\"}"
        emit_metric "igw_upstream_error_total" 1 \
            "upstream=\"${GATEWAY_UPSTREAM_URL}\"" "Upstream errors" "counter"
        return 1
    fi

    log_info "← Upstream response: HTTP ${upstream_code}" \
        "$(json_raw "httpCode" "$upstream_code"),$(json_str "upstream" "$upstream_url"),$(json_raw "durationMs" "$ms")"
    pop_span "upstream_proxy" "OK"

    emit_metric "igw_request_total" 1 \
        "method=\"$method\",status=\"$upstream_code\",route=\"${route_key:0:64}\"" \
        "Total gateway requests" "counter"
    emit_metric "igw_request_duration_ms" "$ms" \
        "method=\"$method\",route=\"${route_key:0:64}\"" \
        "Request duration" "gauge"

    audit_event "PROXY" "${method} ${path}" \
        "$(( upstream_code < 400 ? 'SUCCESS' : 'FAILURE' ))" \
        "$(json_str "upstream" "$upstream_url"),$(json_raw "httpCode" "$upstream_code),$(json_raw "durationMs" "$ms)")"

    # Wrap upstream response in IGW envelope
    local safe_resp
    safe_resp=$(echo "$upstream_resp" | head -c 65536)
    response_ok "$safe_resp" "Proxied from upstream (HTTP ${upstream_code})"
}

# =============================================================================
# SECTION D: Gateway Listener (netcat-based HTTP server)
# =============================================================================

# Handle a single HTTP connection (called per-request from listener loop)
handle_http_connection() {
    local conn_fd="$1"

    # Read the first line: "METHOD /path HTTP/1.1"
    local request_line=""
    read -r -t 10 request_line <&"$conn_fd" || return 1
    request_line="${request_line%$'\r'}"

    [[ -z "$request_line" ]] && return 1

    local method path _http_ver
    read -r method path _http_ver <<< "$request_line"
    method="${method^^}"

    # Read headers
    local auth_header=""
    local content_length=0
    local incoming_trace_id=""
    local incoming_request_id=""
    local client_host=""

    local header_line
    while IFS= read -r -t 5 header_line <&"$conn_fd"; do
        header_line="${header_line%$'\r'}"
        [[ -z "$header_line" ]] && break  # blank line = end of headers

        local hname hval
        hname="${header_line%%:*}"
        hval="${header_line#*: }"
        hname_lower="${hname,,}"

        case "$hname_lower" in
            authorization)   auth_header="$hval"          ;;
            content-length)  content_length="$hval"        ;;
            x-trace-id)      incoming_trace_id="$hval"     ;;
            x-b3-traceid)    incoming_trace_id="${incoming_trace_id:-$hval}" ;;
            x-request-id)    incoming_request_id="$hval"   ;;
            host)            client_host="$hval"           ;;
        esac
    done

    # Read body if present
    local body=""
    if (( content_length > 0 )); then
        body=$(dd bs=1 count="$content_length" 2>/dev/null <&"$conn_fd" || true)
    fi

    # Export context for process_request
    export IGW_GW_METHOD="$method"
    export IGW_GW_PATH="$path"
    export IGW_AUTH_HEADER="$auth_header"
    export IGW_INCOMING_TRACE_ID="$incoming_trace_id"
    export IGW_INCOMING_REQUEST_ID="$incoming_request_id"
    export IGW_CLIENT_IP="${client_host%%:*}"

    # Write body to temp file
    local body_file="${IGW_TMP_DIR}/req_body_$$.tmp"
    echo -n "$body" > "$body_file"
    export IGW_GW_BODY_FILE="$body_file"

    # Process the request, capture output
    local response http_status=200
    response=$(process_request 2>/dev/null) || http_status=500

    rm -f "$body_file"

    # Determine HTTP status from response JSON
    local resp_code
    resp_code=$(echo "$response" | grep -o '"code":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "200")
    [[ -n "$resp_code" ]] && http_status="$resp_code"

    # Map numeric code to status text
    local status_text="OK"
    case "$http_status" in
        200) status_text="OK" ;;
        201) status_text="Created" ;;
        400) status_text="Bad Request" ;;
        401) status_text="Unauthorized" ;;
        403) status_text="Forbidden" ;;
        404) status_text="Not Found" ;;
        422) status_text="Unprocessable Entity" ;;
        429) status_text="Too Many Requests" ;;
        500) status_text="Internal Server Error" ;;
        502) status_text="Bad Gateway" ;;
        503) status_text="Service Unavailable" ;;
        *)   status_text="Unknown" ;;
    esac

    local resp_len="${#response}"
    local ts
    ts=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")

    # Write HTTP response
    printf "HTTP/1.1 %s %s\r\n" "$http_status" "$status_text" >&"$conn_fd"
    printf "Content-Type: application/json\r\n" >&"$conn_fd"
    printf "Content-Length: %d\r\n" "$resp_len" >&"$conn_fd"
    printf "Date: %s\r\n" "$ts" >&"$conn_fd"
    printf "X-Request-Id: %s\r\n" "${IGW_REQUEST_ID:-}" >&"$conn_fd"
    printf "X-Trace-Id: %s\r\n" "${IGW_TRACE_ID:-}" >&"$conn_fd"
    printf "X-Span-Id: %s\r\n" "${IGW_SPAN_ID:-}" >&"$conn_fd"
    printf "X-IGW-Version: %s\r\n" "$IGW_VERSION" >&"$conn_fd"
    printf "Connection: close\r\n" >&"$conn_fd"
    printf "\r\n" >&"$conn_fd"
    printf "%s" "$response" >&"$conn_fd"
}

# Start the gateway listener
start_listener() {
    log_info "Starting IGW listener on ${GATEWAY_LISTEN_HOST}:${GATEWAY_LISTEN_PORT}"
    audit_event "GATEWAY_START" "listener" "SUCCESS" \
        "$(json_str "host" "$GATEWAY_LISTEN_HOST"),$(json_raw "port" "$GATEWAY_LISTEN_PORT")"

    # Write PID
    echo "$$" > "$GATEWAY_PID_FILE"

    # Check for nc/socat
    if command -v socat &>/dev/null; then
        log_info "Using socat for TCP listener"
        socat TCP-LISTEN:"${GATEWAY_LISTEN_PORT}",reuseaddr,fork,bind="${GATEWAY_LISTEN_HOST}" \
            EXEC:"bash -c 'source ${SCRIPT_DIR}/api_common.sh && source ${SCRIPT_DIR}/igw.sh && load_default_routes && handle_http_connection 0'" &
        echo $! >> "$GATEWAY_PID_FILE"
    elif command -v nc &>/dev/null; then
        log_info "Using nc (netcat) for TCP listener"
        while true; do
            nc -l "${GATEWAY_LISTEN_HOST}" "${GATEWAY_LISTEN_PORT}" | (
                source "${SCRIPT_DIR}/api_common.sh"
                source "${SCRIPT_DIR}/igw.sh"
                load_default_routes
                handle_http_connection 0
            ) || true
        done &
        echo $! >> "$GATEWAY_PID_FILE"
    else
        log_warn "Neither socat nor nc found — gateway listener unavailable"
        log_warn "Install socat: apt-get install socat  OR  yum install socat"
        log_info "Gateway is running in process-mode only (no TCP listener)"
    fi

    log_info "IGW gateway started. PID: $$"
    echo ""
    echo "  Gateway listening on: http://${GATEWAY_LISTEN_HOST}:${GATEWAY_LISTEN_PORT}"
    echo "  Upstream:             ${GATEWAY_UPSTREAM_URL}"
    echo "  Log file:             ${IGW_LOG_FILE}"
    echo "  Audit file:           ${IGW_AUDIT_FILE}"
    echo "  PID file:             ${GATEWAY_PID_FILE}"
    echo ""
    echo "  Press Ctrl-C to stop."

    # Keep process alive if we started background listeners
    trap 'cmd_stop; exit 0' SIGTERM SIGINT
    wait
}

# =============================================================================
# SECTION E: Commands
# =============================================================================

cmd_start() {
    init_request_context
    install_error_trap
    load_config "$GATEWAY_CONFIG_FILE" 2>/dev/null || true
    load_default_routes
    start_listener
}

cmd_stop() {
    log_info "Stopping IGW gateway"
    audit_event "GATEWAY_STOP" "process" "SUCCESS"

    if [[ -f "$GATEWAY_PID_FILE" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done < "$GATEWAY_PID_FILE"
        rm -f "$GATEWAY_PID_FILE"
        echo "Gateway stopped."
    else
        echo "No PID file found at $GATEWAY_PID_FILE — gateway may not be running."
    fi
}

cmd_status() {
    init_request_context
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local running="false"
    local pid_list=()

    if [[ -f "$GATEWAY_PID_FILE" ]]; then
        while IFS= read -r pid; do
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                running="true"
                pid_list+=("$pid")
            fi
        done < "$GATEWAY_PID_FILE"
    fi

    local log_size=0
    [[ -f "$IGW_LOG_FILE"   ]] && log_size=$(stat -c%s "$IGW_LOG_FILE" 2>/dev/null || echo 0)
    local audit_lines=0
    [[ -f "$IGW_AUDIT_FILE" ]] && audit_lines=$(wc -l < "$IGW_AUDIT_FILE")

    cat <<EOF
{
  "schema": "igw-status/v1",
  "timestamp": "$ts",
  "service": "$IGW_SERVICE",
  "version": "$IGW_VERSION",
  "env": "$IGW_ENV",
  "host": "$IGW_HOSTNAME",
  "running": $running,
  "pidFile": "$GATEWAY_PID_FILE",
  "pids": [$(IFS=,; echo "${pid_list[*]:-}")],
  "listenPort": $GATEWAY_LISTEN_PORT,
  "listenHost": "$GATEWAY_LISTEN_HOST",
  "upstreamUrl": "$GATEWAY_UPSTREAM_URL",
  "logFile": "$IGW_LOG_FILE",
  "logSizeBytes": $log_size,
  "auditFile": "$IGW_AUDIT_FILE",
  "auditEvents": $audit_lines,
  "routeCount": ${#ROUTE_TABLE[@]}
}
EOF
}

cmd_audit() {
    local subcmd="${1:-stats}"
    shift || true

    init_request_context

    case "$subcmd" in
        stats)
            audit_stats
            ;;
        query)
            local field="${1:?field required}"
            local value="${2:?value required}"
            local max="${3:-50}"
            echo "=== Audit Query: $field=$value (max=$max) ==="
            audit_query "$field" "$value" "$max"
            ;;
        range)
            local start="${1:?start timestamp required (e.g. 2024-01-01)}"
            local end="${2:-}"
            local max="${3:-100}"
            echo "=== Audit Range: $start → ${end:-now} ==="
            audit_query_range "$start" "$end" "$max"
            ;;
        tail)
            local n="${1:-20}"
            if [[ -f "$IGW_AUDIT_FILE" ]]; then
                tail -n "$n" "$IGW_AUDIT_FILE"
            else
                echo "No audit file found: $IGW_AUDIT_FILE"
            fi
            ;;
        export)
            local out="${1:-/tmp/igw_audit_export_$(date +%Y%m%d%H%M%S).jsonl}"
            cp "$IGW_AUDIT_FILE" "$out"
            echo "Audit exported to: $out"
            ;;
        *)
            echo "Usage: igw.sh audit <stats|query|range|tail|export> [args]"
            ;;
    esac
}

cmd_metrics() {
    init_request_context
    echo "=== Prometheus Metrics ==="
    if [[ -f "$IGW_METRICS_FILE" ]]; then
        cat "$IGW_METRICS_FILE"
    else
        echo "# No metrics collected yet."
    fi
    echo ""
    echo "=== Gateway Status ==="
    load_default_routes 2>/dev/null || true
    cmd_status
}

cmd_reload() {
    init_request_context
    log_info "Reloading configuration"
    load_config "$GATEWAY_CONFIG_FILE" 2>/dev/null || true
    load_default_routes

    audit_event "GATEWAY_RELOAD" "config" "SUCCESS" \
        "$(json_str "configFile" "$GATEWAY_CONFIG_FILE")"
    echo '{"status":"reloaded","message":"Configuration reloaded successfully"}'
}

cmd_health() {
    init_request_context
    health_check_json "UP"
}

cmd_logs() {
    local n="${1:-50}"
    if [[ -f "$IGW_LOG_FILE" ]]; then
        echo "=== Last $n log entries from $IGW_LOG_FILE ==="
        tail -n "$n" "$IGW_LOG_FILE"
    else
        echo "No log file found: $IGW_LOG_FILE"
    fi
}

cmd_demo() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────────┐"
    echo "│  Enterprise API Gateway (IGW) · Demo Mode                          │"
    echo "│  All output written to: $IGW_LOG_FILE"
    echo "└──────────────────────────────────────────────────────────────────────┘"
    echo ""

    init_request_context
    install_error_trap
    load_default_routes

    # ── Demo 1: Status ────────────────────────────────────────────────────
    echo "── Demo 1: Gateway Status ───────────────────────────────────────────"
    cmd_status
    echo ""

    # ── Demo 2: Health ────────────────────────────────────────────────────
    echo "── Demo 2: Health Check ─────────────────────────────────────────────"
    cmd_health
    echo ""

    # ── Demo 3: Route matching ────────────────────────────────────────────
    echo "── Demo 3: Route Matching ───────────────────────────────────────────"
    local test_routes=(
        "GET /api/v1/users"
        "POST /api/v1/orders"
        "GET /health"
        "GET /api/v1/products"
        "DELETE /unknown/path"
    )
    for rt in "${test_routes[@]}"; do
        local m="${rt%% *}"
        local p="${rt#* }"
        if key=$(match_route "$m" "$p" 2>/dev/null); then
            printf "  %-30s → %-20s  ✓\n" "$rt" "${ROUTE_TABLE[$key]:-?}"
        else
            printf "  %-30s → %-20s  ✗ (no route)\n" "$rt" "404"
        fi
    done
    echo ""

    # ── Demo 4: Auth validation ───────────────────────────────────────────
    echo "── Demo 4: Auth Token Validation ────────────────────────────────────"
    local tokens=("igw-demo-token-001" "igw-demo-token-002" "bad-token" "")
    for tok in "${tokens[@]}"; do
        if validate_token "$tok"; then
            printf "  Token '%-30s' → VALID   ✓\n" "$tok"
            audit_event "AUTHN" "/api/v1/test" "SUCCESS" \
                "$(json_str "token" "${tok:0:10}...")"
        else
            printf "  Token '%-30s' → INVALID ✗\n" "$tok"
            audit_event "AUTHN" "/api/v1/test" "DENIED" \
                "$(json_str "reason" "invalid_token")"
        fi
    done
    echo ""

    # ── Demo 5: Schema validation ─────────────────────────────────────────
    echo "── Demo 5: Schema Validation ────────────────────────────────────────"
    local valid_order='{"orderId":"ORD-001","userId":"USR-001","items":[{"sku":"A1"}],"totalAmount":99.99}'
    local bad_order='{"orderId":"ORD-002","userId":"USR-002"}'

    echo "  Valid order payload:"
    if validate_schema "order/create/v1" "$valid_order" orderId userId items totalAmount; then
        echo "  → Schema: PASS ✓"
    fi
    echo ""
    echo "  Invalid order payload (missing fields):"
    validate_schema "order/create/v1" "$bad_order" orderId userId items totalAmount || \
        echo "  → Schema: FAIL ✗ (expected)"
    echo ""

    # ── Demo 6: Rate limiting ─────────────────────────────────────────────
    echo "── Demo 6: Rate Limiting (3 req / 10s) ──────────────────────────────"
    local rl_key="demo:igw:test_client"
    for i in $(seq 1 5); do
        if check_rate_limit "$rl_key" 3 10; then
            echo "  Request $i: ALLOWED  ✓"
        else
            echo "  Request $i: RATE LIMITED ✗"
        fi
    done
    echo ""

    # ── Demo 7: Simulated request processing ──────────────────────────────
    echo "── Demo 7: Simulated Request Processing ─────────────────────────────"
    export IGW_GW_METHOD="GET"
    export IGW_GW_PATH="/health"
    export IGW_AUTH_HEADER=""
    export IGW_CLIENT_IP="10.0.0.1"
    export IGW_GW_BODY_FILE=""
    export IGW_INCOMING_TRACE_ID=""
    export IGW_INCOMING_REQUEST_ID=""

    echo "  Processing: GET /health (no auth required)"
    process_request 2>/dev/null || true
    echo ""

    echo "  Processing: GET /api/v1/users (auth required — no token)"
    export IGW_GW_METHOD="GET"
    export IGW_GW_PATH="/api/v1/users"
    export IGW_AUTH_HEADER=""
    process_request 2>/dev/null || true
    echo ""

    echo "  Processing: GET /api/v1/users (auth required — valid token)"
    export IGW_AUTH_HEADER="Bearer igw-demo-token-001"
    process_request 2>/dev/null || true
    echo ""

    # ── Demo 8: Audit trail ───────────────────────────────────────────────
    echo "── Demo 8: Audit Trail Stats ────────────────────────────────────────"
    audit_stats
    echo ""
    echo "  Last 5 audit entries:"
    audit_query_range "" "" 5 || tail -5 "$IGW_AUDIT_FILE" 2>/dev/null || true
    echo ""

    # ── Demo 9: Trace context ─────────────────────────────────────────────
    echo "── Demo 9: W3C Trace Context ────────────────────────────────────────"
    cat <<EOF
{
  "schema":        "igw-trace-context/v1",
  "traceId":       "${IGW_TRACE_ID}",
  "spanId":        "${IGW_SPAN_ID}",
  "requestId":     "${IGW_REQUEST_ID}",
  "correlationId": "${IGW_CORRELATION_ID}",
  "w3cTraceparent":"00-${IGW_TRACE_ID}-${IGW_SPAN_ID}-01",
  "jaegerHeader":  "${IGW_TRACE_ID}:${IGW_SPAN_ID}:0:1"
}
EOF
    echo ""

    # ── Demo 10: Start hint ───────────────────────────────────────────────
    echo "── Demo 10: Start Command ───────────────────────────────────────────"
    echo "  To start the gateway as an HTTP listener:"
    echo ""
    echo "    IGW_LISTEN_PORT=8888 \\"
    echo "    IGW_UPSTREAM_URL=http://localhost:8080 \\"
    echo "    IGW_VALID_TOKENS=my-secret-token \\"
    echo "    ./igw.sh start"
    echo ""
    echo "  Then test it:"
    echo "    curl -H 'Authorization: Bearer igw-demo-token-001' \\"
    echo "         http://localhost:8888/api/v1/users"
    echo ""
    echo "✓ Demo complete."
    echo "  Logs:  $IGW_LOG_FILE"
    echo "  Audit: $IGW_AUDIT_FILE"
}

# =============================================================================
# SECTION F: CLI Dispatcher
# =============================================================================

usage() {
    cat <<EOF
${C_BLD}igw.sh${C_RST} — Enterprise API Gateway v${IGW_VERSION}

${C_BLD}USAGE${C_RST}
  igw.sh <command> [options]

${C_BLD}COMMANDS${C_RST}
  start                    Start the gateway HTTP listener
  stop                     Stop the gateway
  status                   Show gateway process status (JSON)
  reload                   Reload configuration
  health                   Self health check (JSON)
  audit <sub> [args]       Audit log operations:
    stats                  Show audit statistics
    query <field> <value>  Query audit log by field
    range <start> [end]    Query audit log by time range
    tail [N]               Show last N audit entries
    export [file]          Export audit log to file
  metrics                  Show Prometheus metrics + status
  logs [N]                 Tail gateway log (last N lines)
  demo                     Run built-in demonstration

${C_BLD}ENVIRONMENT${C_RST}
  IGW_LISTEN_PORT   Gateway listen port         (default: 8888)
  IGW_LISTEN_HOST   Gateway bind address        (default: 0.0.0.0)
  IGW_UPSTREAM_URL  Upstream base URL           (default: http://localhost:8080)
  IGW_VALID_TOKENS  Comma-separated auth tokens
  IGW_LOG_LEVEL     10/20/30/40                 (default: 20=INFO)
  IGW_ENV           Environment tag             (default: production)
  IGW_LOG_DIR       Log directory               (default: /var/log/igw)
  IGW_CONFIG_FILE   Config file                 (default: /etc/igw/igw.conf)

${C_BLD}ROUTES (built-in)${C_RST}
  GET    /health               → upstream /health           (no auth)
  GET    /metrics              → upstream /metrics          (no auth)
  GET    /api/v1/users         → upstream /users            (auth required)
  POST   /api/v1/users         → upstream /users            (auth + schema)
  GET    /api/v1/orders        → upstream /orders           (auth required)
  POST   /api/v1/orders        → upstream /orders           (auth + schema)
  GET    /api/v1/products      → upstream /products         (auth required)

${C_BLD}AUDIT QUERY EXAMPLES${C_RST}
  igw.sh audit stats
  igw.sh audit query action API_CALL
  igw.sh audit query result DENIED
  igw.sh audit range 2024-01-01 2024-12-31
  igw.sh audit tail 20
  igw.sh audit export /tmp/audit_backup.jsonl

${C_BLD}JSON SCHEMAS${C_RST}
  igw-response/v1        Standard API response envelope
  igw-audit/v1           Audit event record
  igw-health/v1          Health check response
  igw-status/v1          Gateway status response
  igw-trace-context/v1   Trace/span/request ID context

EOF
}

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        start)   cmd_start         ;;
        stop)    cmd_stop          ;;
        status)
            load_default_routes 2>/dev/null || true
            cmd_status
            ;;
        reload)  cmd_reload        ;;
        health)  cmd_health        ;;
        audit)   cmd_audit  "$@"   ;;
        metrics)
            load_default_routes 2>/dev/null || true
            cmd_metrics
            ;;
        logs)    cmd_logs   "$@"   ;;
        demo)    cmd_demo          ;;
        help|-h|--help) usage      ;;
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
