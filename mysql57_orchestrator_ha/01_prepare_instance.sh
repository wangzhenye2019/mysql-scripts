#!/usr/bin/env bash
# Debian 12 + MySQL 5.7.44 基线配置。只生成/校验配置，不执行跨节点提升。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 01_prepare_instance.sh --config FILE [--validate-only]

Prepares one Debian 12 host for a MySQL 5.7.44 GTID, ROW binlog and enhanced
semi-synchronous replication topology. The MySQL 5.7 binary must be installed
at MYSQL57_BASE_DIR before applying configuration.
EOF
}

CONFIG_FILE=""
VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_VERSION MYSQL57_BASE_DIR MYSQL57_DATA_DIR MYSQL57_LOG_DIR MYSQL57_PORT MYSQL57_SOCKET MYSQL57_SERVER_ID MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD
assert_debian12
assert_port "$MYSQL57_PORT" || die "Invalid MYSQL57_PORT: $MYSQL57_PORT"
assert_safe_directory "$MYSQL57_BASE_DIR" "/opt"
assert_safe_directory "$MYSQL57_DATA_DIR" "/srv"
assert_safe_directory "$MYSQL57_LOG_DIR" "/var/log"
[[ "$MYSQL57_VERSION" == "5.7.44" ]] || die "This module is intentionally pinned to MySQL 5.7.44; got ${MYSQL57_VERSION}."

CONFIG_DIR="/etc/mysql57"
CNF_FILE="${CONFIG_DIR}/my.cnf"
SERVICE_NAME="mysql57@${MYSQL57_PORT}"
ADMIN_CNF="/etc/mysql57-ha/admin.cnf"

render_mycnf() {
    install -d -m 0750 -o mysql -g mysql "$MYSQL57_DATA_DIR" "$MYSQL57_LOG_DIR" "$(dirname "$MYSQL57_SOCKET")"
    install -d -m 0755 "$CONFIG_DIR"

    cat > "$CNF_FILE" <<EOF
[mysqld]
user=mysql
basedir=${MYSQL57_BASE_DIR}
datadir=${MYSQL57_DATA_DIR}
port=${MYSQL57_PORT}
socket=${MYSQL57_SOCKET}
pid-file=${MYSQL57_DATA_DIR}/mysqld.pid
log-error=${MYSQL57_LOG_DIR}/error.log

# GTID failover baseline required by Orchestrator.
server-id=${MYSQL57_SERVER_ID}
log-bin=${MYSQL57_LOG_DIR}/binlog/mysql-bin
binlog-format=ROW
log-slave-updates=ON
gtid-mode=ON
enforce-gtid-consistency=ON
master-info-repository=TABLE
relay-log-info-repository=TABLE
relay-log=${MYSQL57_LOG_DIR}/relaylog/mysql-relay-bin
relay-log-recovery=ON
sync-binlog=1
innodb-flush-log-at-trx-commit=1
sync-relay-log=1
sync-relay-log-info=1
log-slave-updates=ON

# Promote only healthy replicas. Each host starts read-only and Orchestrator
# performs the promotion after its candidate checks and fencing hooks succeed.
read-only=ON
super-read-only=ON
skip-slave-start=ON

# Enhanced semi-sync is configured by 02_configure_lossless_semisync.sh.
skip-name-resolve=ON
bind-address=0.0.0.0
!includedir ${CONFIG_DIR}/conf.d
EOF
    install -d -m 0750 -o root -g mysql "${CONFIG_DIR}/conf.d"
    chmod 0640 "$CNF_FILE"
    chown root:mysql "$CNF_FILE"
}

render_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=MySQL 5.7.44 instance on port ${MYSQL57_PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=mysql
Group=mysql
ExecStart=${MYSQL57_BASE_DIR}/bin/mysqld --defaults-file=${CNF_FILE} --daemonize
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "/etc/systemd/system/${SERVICE_NAME}.service"
}

validate_binary() {
    [[ -x "${MYSQL57_BASE_DIR}/bin/mysqld" ]] || die "Expected MySQL 5.7 binary not found: ${MYSQL57_BASE_DIR}/bin/mysqld"
    local detected
    detected="$("${MYSQL57_BASE_DIR}/bin/mysqld" --version)"
    [[ "$detected" == *"5.7.44"* ]] || die "Expected MySQL 5.7.44 binary; got: ${detected}"
}

require_root
validate_binary
render_mycnf
render_service
write_mysql_defaults_file "$ADMIN_CNF" "$MYSQL_ADMIN_USER" "$MYSQL_ADMIN_PASSWORD" "127.0.0.1" "$MYSQL57_PORT"
chown root:root "$ADMIN_CNF"

if [[ "$VALIDATE_ONLY" == true ]]; then
    "${MYSQL57_BASE_DIR}/bin/mysqld" --defaults-file="$CNF_FILE" --validate-config
    log_info "MySQL 5.7 configuration validation completed."
    exit 0
fi

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
wait_for_mysql "$ADMIN_CNF" 60 || die "MySQL 5.7 did not become ready. Check ${MYSQL57_LOG_DIR}/error.log"
log_info "MySQL 5.7.44 baseline is ready on port ${MYSQL57_PORT}. Configure semi-sync next."
