#!/usr/bin/env bash
# MySQL 5.7 Orchestrator drill. Default mode is read-only preflight.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage:
  07_drill_orchestrator_failover.sh --config FILE --mode preflight
  07_drill_orchestrator_failover.sh --config FILE --mode graceful-takeover --target HOST --apply --change-id ID
  07_drill_orchestrator_failover.sh --config FILE --mode fault-injection --apply --change-id ID --acknowledge-production-impact

The fault-injection mode never supplies a built-in kill/network action. It only
executes the explicitly configured, environment-owned DRILL_FAULT_INJECTION_COMMAND
after preflight passes. Use it in an approved isolation or maintenance window.
EOF
}

CONFIG_FILE=""
MODE="preflight"
TARGET=""
APPLY=false
CHANGE_ID=""
ACKNOWLEDGED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --mode) MODE="${2:?missing mode}"; shift 2 ;;
        --target) TARGET="${2:?missing target}"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --change-id) CHANGE_ID="${2:?missing change id}"; shift 2 ;;
        --acknowledge-production-impact) ACKNOWLEDGED=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 3; }
[[ "$MODE" == "preflight" || "$MODE" == "graceful-takeover" || "$MODE" == "fault-injection" ]] || die "Unsupported mode: ${MODE}"
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_PORT MYSQL57_BASE_DIR MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD PRIMARY_HOST CANDIDATE_HOST REPLICA_HOSTS_CSV ORCHESTRATOR_API_URL SEMI_SYNC_WAIT_COUNT

DRILL_TIMEOUT_SEC="${MYSQL57_DRILL_TIMEOUT_SEC:-120}"
[[ "$DRILL_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die "MYSQL57_DRILL_TIMEOUT_SEC must be positive."
if [[ "$MODE" != "preflight" ]]; then
    [[ "$APPLY" == true && -n "$CHANGE_ID" ]] || die "${MODE} requires --apply and --change-id."
fi
if [[ "$MODE" == "graceful-takeover" ]]; then
    [[ -n "$TARGET" ]] || die "graceful-takeover requires --target HOST."
fi
if [[ "$MODE" == "fault-injection" ]]; then
    [[ "$ACKNOWLEDGED" == true ]] || die "fault-injection requires --acknowledge-production-impact."
    validate_config_keys "$CONFIG_FILE" ORCHESTRATOR_CLUSTER_ALIAS DRILL_FAULT_INJECTION_COMMAND
fi

RUN_DIR="/var/tmp/mysql57-ha-drill-${CHANGE_ID:-preflight}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"
ADMIN_CNF="${RUN_DIR}/admin.cnf"
write_mysql_defaults_file "$ADMIN_CNF" "$MYSQL_ADMIN_USER" "$MYSQL_ADMIN_PASSWORD" "127.0.0.1" "$MYSQL57_PORT"

mysql_on_host() {
    local host="$1" sql="$2"
    local cnf="${RUN_DIR}/client-${host//[^A-Za-z0-9_.-]/_}.cnf"
    write_mysql_defaults_file "$cnf" "$MYSQL_ADMIN_USER" "$MYSQL_ADMIN_PASSWORD" "$host" "$MYSQL57_PORT"
    mysql_exec "$cnf" "$sql"
}

current_writable_hosts() {
    local host state
    IFS=',' read -r -a replicas <<< "$REPLICA_HOSTS_CSV"
    for host in "$PRIMARY_HOST" "${replicas[@]}"; do
        state="$(mysql_on_host "$host" 'SELECT @@global.read_only,@@global.super_read_only' 2>/dev/null || true)"
        [[ "$state" == $'0\t0' ]] && printf '%s\n' "$host"
    done
}

preflight() {
    local writable_count semi_state semi_clients
    curl --fail --silent --show-error --connect-timeout 5 "${ORCHESTRATOR_API_URL%/}/api/replication-analysis" >"${RUN_DIR}/orchestrator-analysis.json" || die "Orchestrator API is unavailable."
    writable_count="$(current_writable_hosts | tee "${RUN_DIR}/writable-before.txt" | wc -l)"
    [[ "$writable_count" -eq 1 ]] || die "Expected exactly one writable primary before drill; found ${writable_count}."
    semi_state="$(mysql_on_host "$PRIMARY_HOST" "SHOW STATUS LIKE 'Rpl_semi_sync_master_status'" | awk 'NR==1 {print $2}')"
    semi_clients="$(mysql_on_host "$PRIMARY_HOST" "SHOW STATUS LIKE 'Rpl_semi_sync_master_clients'" | awk 'NR==1 {print $2}')"
    [[ "$semi_state" == "ON" ]] || die "Primary semi-sync is not operational."
    [[ "$semi_clients" =~ ^[0-9]+$ ]] && (( semi_clients >= SEMI_SYNC_WAIT_COUNT )) || die "Primary lacks required semi-sync acknowledgers."
    printf 'mode=%s\nchange_id=%s\nprimary_before=%s\nsemi_sync=%s\nsemi_clients=%s\n' \
        "$MODE" "${CHANGE_ID:-none}" "$(cat "${RUN_DIR}/writable-before.txt")" "$semi_state" "$semi_clients" >"${RUN_DIR}/evidence.txt"
    log_info "Preflight passed; evidence stored in ${RUN_DIR}."
}

wait_for_new_primary() {
    local expected="$1" elapsed=0 writable
    while (( elapsed < DRILL_TIMEOUT_SEC )); do
        writable="$(current_writable_hosts || true)"
        if [[ "$(wc -l <<< "$writable")" -eq 1 ]]; then
            printf '%s\n' "$writable" >"${RUN_DIR}/writable-after.txt"
            if [[ "$writable" == "$expected" || "$MODE" == "fault-injection" ]]; then
                return 0
            fi
        fi
        sleep 2
        ((elapsed+=2))
    done
    return 1
}

preflight
if [[ "$MODE" == "preflight" ]]; then
    exit 0
fi

if [[ "$MODE" == "graceful-takeover" ]]; then
    require_command orchestrator-client
    [[ -n "${ORCHESTRATOR_CLUSTER_ALIAS:-}" ]] || die "Set ORCHESTRATOR_CLUSTER_ALIAS for graceful takeover."
    orchestrator-client -c graceful-master-takeover-auto -alias "$ORCHESTRATOR_CLUSTER_ALIAS" -d "${TARGET}:${MYSQL57_PORT}" | tee "${RUN_DIR}/orchestrator-command.log"
    wait_for_new_primary "$TARGET" || die "Graceful takeover did not converge within ${DRILL_TIMEOUT_SEC}s."
else
    # The command receives failed-primary host, port, and change ID as arguments.
    # Its implementation belongs to the environment (PDU, VM API, security group, etc.).
    "$DRILL_FAULT_INJECTION_COMMAND" "$PRIMARY_HOST" "$MYSQL57_PORT" "$CHANGE_ID" | tee "${RUN_DIR}/fault-injection.log"
    wait_for_new_primary "" || die "Fault-injection failover did not converge within ${DRILL_TIMEOUT_SEC}s."
fi

new_primary="$(cat "${RUN_DIR}/writable-after.txt")"
[[ "$new_primary" != "$PRIMARY_HOST" || "$MODE" == "graceful-takeover" ]] || die "Unexpectedly retained failed primary as writable."
mysql_on_host "$new_primary" 'SELECT @@global.gtid_mode,@@global.read_only,@@global.super_read_only' >"${RUN_DIR}/new-primary-state.txt"
log_info "Drill completed successfully. New primary: ${new_primary}; evidence: ${RUN_DIR}"
