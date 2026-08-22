#!/usr/bin/env bash
# MySQL 8.4 InnoDB Cluster / MGR drill. No built-in destructive injector is provided.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage:
  07_drill_mgr_failover.sh --config FILE --mode preflight
  07_drill_mgr_failover.sh --config FILE --mode fault-injection --apply --change-id ID --acknowledge-production-impact
  07_drill_mgr_failover.sh --config FILE --mode rejoin --target HOST:PORT --apply --change-id ID

Fault injection executes only DRILL_FAULT_INJECTION_COMMAND from the secured
configuration after all preflight gates pass. Provide an environment-owned,
audited injector for VM power, service isolation, or network failure. The script
never kills mysqld or starts/stops Group Replication directly.
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
[[ "$MODE" == "preflight" || "$MODE" == "fault-injection" || "$MODE" == "rejoin" ]] || die "Unsupported mode: ${MODE}"
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_CLUSTER_NAME MYSQL84_SEED_INSTANCE MYSQL84_INSTANCES_CSV MYSQL84_ADMIN_USER MYSQL84_ADMIN_PASSWORD MYSQL84_ROUTER_SERVICE_NAME
DRILL_TIMEOUT_SEC="${MYSQL84_DRILL_TIMEOUT_SEC:-120}"
[[ "$DRILL_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || die "MYSQL84_DRILL_TIMEOUT_SEC must be positive."
if [[ "$MODE" != "preflight" ]]; then
    [[ "$APPLY" == true && -n "$CHANGE_ID" ]] || die "${MODE} requires --apply and --change-id."
fi
if [[ "$MODE" == "fault-injection" ]]; then
    [[ "$ACKNOWLEDGED" == true ]] || die "fault-injection requires --acknowledge-production-impact."
    validate_config_keys "$CONFIG_FILE" DRILL_FAULT_INJECTION_COMMAND
fi
if [[ "$MODE" == "rejoin" ]]; then
    [[ -n "$TARGET" ]] || die "rejoin requires --target HOST:PORT."
fi

RUN_DIR="/var/tmp/mysql84-ic-drill-${CHANGE_ID:-preflight}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"

export IC_CLUSTER_NAME="$MYSQL84_CLUSTER_NAME"
export IC_SEED_INSTANCE="$MYSQL84_SEED_INSTANCE"
export IC_CLUSTER_ADMIN="$MYSQL84_ADMIN_USER"
export IC_CLUSTER_ADMIN_PASSWORD="$MYSQL84_ADMIN_PASSWORD"

cluster_action() {
    local action="$1" target="${2:-}"
    export IC_DRILL_ACTION="$action"
    export IC_DRILL_TARGET="$target"
    mysqlsh --quiet-start=2 --js --file "${SCRIPT_DIR}/drill_cluster.js"
}

monitor_json() {
    local result status
    set +e
    result="$("${SCRIPT_DIR}/06_monitor_cluster.sh" --config "$CONFIG_FILE" --json 2>/dev/null)"
    status=$?
    set -e
    printf '%s\n' "$result"
    return "$status"
}

preflight() {
    local monitor primary
    monitor="$(monitor_json)" || die "Cluster/Router monitor does not report healthy status."
    primary="$(cluster_action primary | jq -er '.primary')"
    [[ -n "$primary" ]] || die "Could not identify the current PRIMARY."
    printf 'mode=%s\nchange_id=%s\nprimary_before=%s\nmonitor_before=%s\n' \
        "$MODE" "${CHANGE_ID:-none}" "$primary" "$monitor" >"${RUN_DIR}/evidence.txt"
    printf '%s\n' "$primary" >"${RUN_DIR}/primary-before.txt"
    log_info "Preflight passed; current PRIMARY is ${primary}."
}

wait_for_new_primary() {
    local old_primary="$1" elapsed=0 candidate monitor status
    while (( elapsed < DRILL_TIMEOUT_SEC )); do
        candidate="$(cluster_action primary 2>/dev/null | jq -er '.primary' 2>/dev/null || true)"
        monitor="$(monitor_json || true)"
        status="$(jq -er '.status' <<< "$monitor" 2>/dev/null || echo 3)"
        if [[ -n "$candidate" && "$candidate" != "$old_primary" && "$status" -le 1 ]]; then
            printf '%s\n' "$candidate" >"${RUN_DIR}/primary-after.txt"
            printf '%s\n' "$monitor" >"${RUN_DIR}/monitor-after.json"
            return 0
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

if [[ "$MODE" == "rejoin" ]]; then
    cluster_action rejoin "$TARGET" | tee "${RUN_DIR}/rejoin.json"
    monitor_json >"${RUN_DIR}/monitor-after-rejoin.json" || die "Cluster did not become healthy after rejoin."
    log_info "Rejoin completed; evidence: ${RUN_DIR}"
    exit 0
fi

old_primary="$(cat "${RUN_DIR}/primary-before.txt")"
primary_host="${old_primary%:*}"
primary_port="${old_primary##*:}"
"$DRILL_FAULT_INJECTION_COMMAND" "$primary_host" "$primary_port" "$CHANGE_ID" | tee "${RUN_DIR}/fault-injection.log"
wait_for_new_primary "$old_primary" || die "MGR primary failover did not converge within ${DRILL_TIMEOUT_SEC}s."
new_primary="$(cat "${RUN_DIR}/primary-after.txt")"
log_info "MGR failover drill completed. PRIMARY changed from ${old_primary} to ${new_primary}; evidence: ${RUN_DIR}"
