#!/usr/bin/env bash
# 非破坏性预检；--controlled-failover 仅允许在隔离演练环境使用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 05_preflight_and_drill.sh --config FILE [--controlled-failover]

The default mode validates local GTID and semi-sync safety prerequisites. The
controlled failover mode invokes Orchestrator's graceful takeover only after
operator confirmation. It must never be run against an unapproved production
cluster without a documented change window.
EOF
}

CONFIG_FILE=""
CONTROLLED_FAILOVER=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --controlled-failover) CONTROLLED_FAILOVER=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_PORT MYSQL57_BASE_DIR MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD SEMI_SYNC_WAIT_COUNT SEMI_SYNC_WAIT_POINT PRIMARY_HOST CANDIDATE_HOST ORCHESTRATOR_API_URL
ADMIN_CNF="/etc/mysql57-ha/admin.cnf"
[[ -r "$ADMIN_CNF" ]] || die "Missing local admin credentials: ${ADMIN_CNF}"

assert_status() {
    local key="$1" expected="$2" value
    value="$(mysql_exec "$ADMIN_CNF" "SHOW STATUS LIKE '${key}'" | awk '{print $2}')"
    [[ "$value" == "$expected" ]] || die "${key} expected ${expected}, got ${value:-empty}"
}

[[ "$SEMI_SYNC_WAIT_POINT" == "AFTER_SYNC" ]] || die "SEMI_SYNC_WAIT_POINT must be AFTER_SYNC."
assert_status Rpl_semi_sync_master_status ON
clients="$(mysql_exec "$ADMIN_CNF" "SHOW STATUS LIKE 'Rpl_semi_sync_master_clients'" | awk '{print $2}')"
[[ "$clients" =~ ^[0-9]+$ ]] && (( clients >= SEMI_SYNC_WAIT_COUNT )) || die "Semi-sync acknowledger count ${clients:-0} is below ${SEMI_SYNC_WAIT_COUNT}."

mysql_exec "$ADMIN_CNF" "SELECT @@global.gtid_mode, @@global.enforce_gtid_consistency, @@global.log_bin, @@global.log_slave_updates" | \
    awk '$1 != "ON" || $2 != "ON" || $3 != "1" || $4 != "1" {exit 1}' || die "GTID/log-bin/log-slave-updates preconditions are not satisfied."

if command -v orchestrator-client >/dev/null 2>&1; then
    orchestrator-client -c replication-analysis | sed -n '1,120p'
else
    log_warn "orchestrator-client not installed on this host; topology analysis skipped."
fi

log_info "Preflight passed: local 5.7 enhanced semi-sync and GTID settings meet the profile."

if [[ "$CONTROLLED_FAILOVER" == true ]]; then
    [[ "${ALLOW_CONTROLLED_FAILOVER:-false}" == "true" ]] || die "Set ALLOW_CONTROLLED_FAILOVER=true in the secured config after approved change control."
    require_command orchestrator-client
    log_warn "Starting controlled graceful takeover to ${CANDIDATE_HOST}:${MYSQL57_PORT}."
    orchestrator-client -c graceful-master-takeover-auto -alias "$PRIMARY_HOST" -d "${CANDIDATE_HOST}:${MYSQL57_PORT}"
fi
