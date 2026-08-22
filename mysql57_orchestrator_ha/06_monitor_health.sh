#!/usr/bin/env bash
# MySQL 5.7.44 HA monitor: read-only by default; returns 0 healthy, 1 degraded, 2 unsafe, 3 invalid/unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 06_monitor_health.sh --config FILE [--json] [--install-systemd] [--interval SECONDS]

Read-only checks cover MySQL availability, GTID/durability prerequisites,
enhanced semi-sync state, replica threads, Orchestrator API reachability, and
write-VIP ownership. --install-systemd installs a local monitoring timer only;
it never performs a failover or modifies MySQL.
EOF
}

CONFIG_FILE=""
JSON_OUTPUT=false
INSTALL_SYSTEMD=false
INTERVAL_SECONDS="${MYSQL57_MONITOR_INTERVAL_SEC:-30}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --install-systemd) INSTALL_SYSTEMD=true; shift ;;
        --interval) INTERVAL_SECONDS="${2:?missing interval}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 3; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_PORT MYSQL57_BASE_DIR MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD SEMI_SYNC_WAIT_COUNT SEMI_SYNC_WAIT_POINT WRITE_VIP VIP_INTERFACE
[[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer."
assert_port "$MYSQL57_PORT" || die "Invalid MYSQL57_PORT."
assert_ipv4 "$WRITE_VIP" || die "Invalid WRITE_VIP."

ADMIN_CNF="/etc/mysql57-ha/admin.cnf"
STATUS=0
MESSAGES=()
ROLE="${MYSQL57_MONITOR_EXPECTED_ROLE:-auto}"

set_state() {
    local new_state="$1" message="$2"
    (( new_state > STATUS )) && STATUS="$new_state"
    MESSAGES+=("$message")
}

status_value() {
    local variable="$1"
    mysql_exec "$ADMIN_CNF" "SHOW STATUS LIKE '${variable}'" 2>/dev/null | awk 'NR==1 {print $2}'
}

emit() {
    local summary="${MESSAGES[*]:-healthy}"
    if [[ "$JSON_OUTPUT" == true ]]; then
        printf '{"profile":"mysql57_orchestrator_ha","status":%s,"role":"%s","summary":"%s"}\n' \
            "$STATUS" "$ROLE" "${summary//\"/\\\"}"
    else
        printf 'profile=mysql57_orchestrator_ha status=%s role=%s summary=%s\n' "$STATUS" "$ROLE" "$summary"
    fi
    return "$STATUS"
}

install_systemd_timer() {
    require_root
    local unit="mysql57-ha-monitor@${MYSQL57_PORT}"
    cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=Read-only MySQL 5.7 HA monitor on port ${MYSQL57_PORT}
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/06_monitor_health.sh --config ${CONFIG_FILE} --json
EOF
    cat > "/etc/systemd/system/${unit}.timer" <<EOF
[Unit]
Description=Run MySQL 5.7 HA monitor every ${INTERVAL_SECONDS}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${INTERVAL_SECONDS}s
AccuracySec=1s
Unit=${unit}.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${unit}.timer"
    log_info "Installed ${unit}.timer. Inspect results via journalctl -u ${unit}.service."
}

if [[ "$INSTALL_SYSTEMD" == true ]]; then
    install_systemd_timer
    exit 0
fi

[[ -r "$ADMIN_CNF" ]] || { set_state 3 "admin-defaults-file-missing"; emit; exit $?; }
if ! mysql_exec "$ADMIN_CNF" 'SELECT 1' >/dev/null 2>&1; then
    set_state 3 "mysql-unavailable"
    emit
    exit $?
fi

preconditions="$(mysql_exec "$ADMIN_CNF" 'SELECT @@global.gtid_mode,@@global.enforce_gtid_consistency,@@global.log_bin,@@global.log_slave_updates,@@global.sync_binlog,@@global.innodb_flush_log_at_trx_commit' 2>/dev/null || true)"
[[ "$preconditions" == $'ON\tON\t1\t1\t1\t1' ]] || set_state 2 "gtid-or-durability-prerequisite-failed"

semi_state="$(status_value Rpl_semi_sync_master_status || true)"
semi_clients="$(status_value Rpl_semi_sync_master_clients || true)"
[[ "$semi_clients" =~ ^[0-9]+$ ]] || semi_clients=0
[[ "$semi_state" == "ON" ]] || set_state 2 "semi-sync-not-operational"
(( semi_clients >= SEMI_SYNC_WAIT_COUNT )) || set_state 2 "semi-sync-acknowledgers-${semi_clients}-below-${SEMI_SYNC_WAIT_COUNT}"

wait_point="$(mysql_exec "$ADMIN_CNF" "SHOW VARIABLES LIKE 'rpl_semi_sync_master_wait_point'" 2>/dev/null | awk 'NR==1 {print $2}')"
[[ "$wait_point" == "AFTER_SYNC" && "$SEMI_SYNC_WAIT_POINT" == "AFTER_SYNC" ]] || set_state 2 "semi-sync-wait-point-not-after-sync"

read_state="$(mysql_exec "$ADMIN_CNF" 'SELECT @@global.read_only,@@global.super_read_only' 2>/dev/null || true)"
if [[ "$ROLE" == "primary" && "$read_state" != $'0\t0' ]]; then
    set_state 2 "primary-is-not-writable"
elif [[ "$ROLE" == "replica" && "$read_state" != $'1\t1' ]]; then
    set_state 2 "replica-is-not-read-only"
fi

slave_status="$(mysql_exec "$ADMIN_CNF" 'SHOW SLAVE STATUS\G' 2>/dev/null || true)"
if [[ "$ROLE" == "replica" || ( "$ROLE" == "auto" && -n "$slave_status" ) ]]; then
    grep -q 'Slave_IO_Running: Yes' <<< "$slave_status" || set_state 2 "replica-io-thread-not-running"
    grep -q 'Slave_SQL_Running: Yes' <<< "$slave_status" || set_state 2 "replica-sql-thread-not-running"
fi

if [[ -n "${ORCHESTRATOR_API_URL:-}" ]]; then
    if ! curl --fail --silent --show-error --connect-timeout 5 "${ORCHESTRATOR_API_URL%/}/api/replication-analysis" >/dev/null; then
        set_state 1 "orchestrator-api-unavailable"
    fi
fi

vip_present=false
if ip -o addr show dev "$VIP_INTERFACE" 2>/dev/null | grep -qw "$WRITE_VIP"; then
    vip_present=true
fi
if [[ "$ROLE" == "primary" && "$vip_present" != true ]]; then
    set_state 1 "primary-without-write-vip"
elif [[ "$ROLE" == "replica" && "$vip_present" == true ]]; then
    set_state 2 "replica-owns-write-vip"
fi

[[ ${#MESSAGES[@]} -gt 0 ]] || MESSAGES=("healthy")
emit
