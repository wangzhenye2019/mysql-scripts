#!/usr/bin/env bash
# 在已完成物理/逻辑一致性置备的 MySQL 5.7 副本上启用 GTID 自动定位。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 03_join_gtid_replica.sh --config FILE --source HOST [--source-port PORT] --provisioned

This command intentionally refuses to copy a live datadir. Restore the replica
from a validated physical backup (or another consistent provisioning workflow)
before invoking it. --provisioned is an explicit operator acknowledgement.
EOF
}

CONFIG_FILE=""
SOURCE_HOST=""
SOURCE_PORT="3306"
PROVISIONED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --source) SOURCE_HOST="${2:?missing source host}"; shift 2 ;;
        --source-port) SOURCE_PORT="${2:?missing source port}"; shift 2 ;;
        --provisioned) PROVISIONED=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && -n "$SOURCE_HOST" && "$PROVISIONED" == true ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_PORT MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD MYSQL_REPLICATION_USER MYSQL_REPLICATION_PASSWORD
assert_port "$SOURCE_PORT" || die "Invalid source port: $SOURCE_PORT"
ensure_secret MYSQL_REPLICATION_PASSWORD

ADMIN_CNF="/etc/mysql57-ha/admin.cnf"
[[ -r "$ADMIN_CNF" ]] || die "Admin defaults file not found: ${ADMIN_CNF}"
source_user="$(sql_escape "$MYSQL_REPLICATION_USER")"
source_password="$(sql_escape "$MYSQL_REPLICATION_PASSWORD")"
source_host="$(sql_escape "$SOURCE_HOST")"

# GTID position is valid only after an operator has completed a consistent
# provisioning flow. RESET SLAVE ALL is destructive for existing channel state.
mysql_exec "$ADMIN_CNF" "
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='${source_host}',
  MASTER_PORT=${SOURCE_PORT},
  MASTER_USER='${source_user}',
  MASTER_PASSWORD='${source_password}',
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=5,
  MASTER_RETRY_COUNT=86400;
START SLAVE;
"

sleep 2
status="$(mysql_exec "$ADMIN_CNF" 'SHOW SLAVE STATUS\G')"
echo "$status"
echo "$status" | grep -q 'Slave_IO_Running: Yes' || die "Replica IO thread did not start."
echo "$status" | grep -q 'Slave_SQL_Running: Yes' || die "Replica SQL thread did not start."
log_info "GTID replica joined ${SOURCE_HOST}:${SOURCE_PORT}. Validate semi-sync and Orchestrator discovery before enabling writes on the primary."
