#!/usr/bin/env bash
# MySQL 8.4 InnoDB Cluster monitor: status 0 healthy, 1 degraded, 2 critical, 3 invalid/unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 06_monitor_cluster.sh --config FILE [--json] [--install-systemd] [--interval SECONDS]

Read-only checks cover AdminAPI cluster status, online members, PRIMARY
uniqueness, metadata reachability, Router service, and Router RW/RO listeners.
The script does not start Group Replication, rejoin members, or alter routing.
EOF
}

CONFIG_FILE=""
JSON_OUTPUT=false
INSTALL_SYSTEMD=false
INTERVAL_SECONDS=""
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
validate_config_keys "$CONFIG_FILE" MYSQL84_CLUSTER_NAME MYSQL84_SEED_INSTANCE MYSQL84_INSTANCES_CSV MYSQL84_ADMIN_USER MYSQL84_ADMIN_PASSWORD MYSQL84_ROUTER_SERVICE_NAME MYSQL84_ROUTER_RW_PORT MYSQL84_ROUTER_RO_PORT
INTERVAL_SECONDS="${INTERVAL_SECONDS:-${MYSQL84_MONITOR_INTERVAL_SEC:-30}}"
[[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer."
assert_port "$MYSQL84_ROUTER_RW_PORT" || die "Invalid MYSQL84_ROUTER_RW_PORT."
assert_port "$MYSQL84_ROUTER_RO_PORT" || die "Invalid MYSQL84_ROUTER_RO_PORT."
require_command mysqlsh

install_systemd_timer() {
    require_root
    local safe_name="${MYSQL84_CLUSTER_NAME//[^A-Za-z0-9_.-]/_}"
    local unit="mysql84-ic-monitor@${safe_name}"
    cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=Read-only MySQL 8.4 InnoDB Cluster monitor for ${MYSQL84_CLUSTER_NAME}
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/06_monitor_cluster.sh --config ${CONFIG_FILE} --json
EOF
    cat > "/etc/systemd/system/${unit}.timer" <<EOF
[Unit]
Description=Run MySQL 8.4 InnoDB Cluster monitor every ${INTERVAL_SECONDS}s

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

export IC_CLUSTER_NAME="$MYSQL84_CLUSTER_NAME"
export IC_SEED_INSTANCE="$MYSQL84_SEED_INSTANCE"
export IC_INSTANCES_CSV="$MYSQL84_INSTANCES_CSV"
export IC_CLUSTER_ADMIN="$MYSQL84_ADMIN_USER"
export IC_CLUSTER_ADMIN_PASSWORD="$MYSQL84_ADMIN_PASSWORD"
TMP_RESULT="$(mktemp)"
trap 'rm -f "$TMP_RESULT"' EXIT
if ! mysqlsh --quiet-start=2 --js --file "${SCRIPT_DIR}/monitor_cluster.js" >"$TMP_RESULT" 2>/dev/null; then
    if [[ "$JSON_OUTPUT" == true ]]; then
        printf '{"profile":"mysql84_innodb_cluster","status":3,"summary":"adminapi-unavailable"}\n'
    else
        printf 'profile=mysql84_innodb_cluster status=3 summary=adminapi-unavailable\n'
    fi
    exit 3
fi

result="$(tail -n 1 "$TMP_RESULT")"
status="$(jq -er '.status' <<< "$result" 2>/dev/null || true)"
[[ "$status" =~ ^[0-3]$ ]] || { printf '%s\n' "$result" >&2; die "AdminAPI monitor returned invalid JSON status."; }
messages="$(jq -er '.messages | join(";")' <<< "$result")"

if ! systemctl is-active --quiet "$MYSQL84_ROUTER_SERVICE_NAME"; then
    (( status < 2 )) && status=2
    messages+=";router-service-inactive"
fi
if ! ss -ltnH "sport = :${MYSQL84_ROUTER_RW_PORT}" | grep -q .; then
    (( status < 2 )) && status=2
    messages+=";router-rw-listener-missing"
fi
if ! ss -ltnH "sport = :${MYSQL84_ROUTER_RO_PORT}" | grep -q .; then
    (( status < 1 )) && status=1
    messages+=";router-ro-listener-missing"
fi

if [[ "$JSON_OUTPUT" == true ]]; then
    jq --argjson status "$status" --arg messages "$messages" '.status=$status | .summary=$messages' <<< "$result"
else
    printf 'profile=mysql84_innodb_cluster status=%s summary=%s\n' "$status" "$messages"
fi
exit "$status"
