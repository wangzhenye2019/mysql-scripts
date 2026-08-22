#!/usr/bin/env bash
# 对单节点运行 SQL 与 AdminAPI 预检；在创建集群前必须全部通过。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 02_preflight_instance.sh --config FILE --instance HOST:PORT

Checks official InnoDB Cluster prerequisites. Non-InnoDB business tables and
business InnoDB tables without a primary key / non-null unique key are reported
as blocking findings. AdminAPI configuration is checked without manual MGR start.
EOF
}

CONFIG_FILE=""
INSTANCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --instance) INSTANCE="${2:?missing instance}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && -n "$INSTANCE" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_PORT MYSQL84_ROOT_USER MYSQL84_ROOT_PASSWORD MYSQL84_ADMIN_USER MYSQL84_ADMIN_PASSWORD
host="${INSTANCE%:*}"
port="${INSTANCE##*:}"
[[ "$host" != "$INSTANCE" ]] && assert_port "$port" || die "Instance must be HOST:PORT."

TMP_CNF="$(mktemp)"
trap 'rm -f "$TMP_CNF"' EXIT
write_mysql_defaults_file "$TMP_CNF" "$MYSQL84_ROOT_USER" "$MYSQL84_ROOT_PASSWORD" "$host" "$port"

# 这些检查覆盖 Group Replication 的核心业务前提。输出不合规对象后立即失败，
# 强制操作者先迁移表引擎或补充主键，再进入 AdminAPI 配置阶段。
non_innodb="$(mysql_exec "$TMP_CNF" "
SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME,':',ENGINE)
FROM information_schema.TABLES
WHERE TABLE_TYPE='BASE TABLE'
  AND TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema')
  AND ENGINE <> 'InnoDB';")"
[[ -z "$non_innodb" ]] || { printf '%s\n' "$non_innodb" >&2; die "Non-InnoDB business tables block InnoDB Cluster admission."; }

no_pk="$(mysql_exec "$TMP_CNF" "
SELECT CONCAT(t.TABLE_SCHEMA,'.',t.TABLE_NAME)
FROM information_schema.TABLES t
WHERE t.TABLE_TYPE='BASE TABLE'
  AND t.ENGINE='InnoDB'
  AND t.TABLE_SCHEMA NOT IN ('mysql','sys','performance_schema','information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
    WHERE c.CONSTRAINT_SCHEMA=t.TABLE_SCHEMA
      AND c.TABLE_NAME=t.TABLE_NAME
      AND c.CONSTRAINT_TYPE IN ('PRIMARY KEY','UNIQUE')
  );")"
[[ -z "$no_pk" ]] || { printf '%s\n' "$no_pk" >&2; die "Business InnoDB tables without a PRIMARY/UNIQUE key block admission."; }

server_preconditions="$(mysql_exec "$TMP_CNF" "SELECT @@gtid_mode,@@enforce_gtid_consistency,@@binlog_format,@@log_bin,@@log_replica_updates")"
[[ "$server_preconditions" == $'ON\tON\tROW\t1\t1' ]] || die "GTID, ROW binlog, log_bin or log_replica_updates is not compliant: ${server_preconditions}"

export IC_INSTANCE="$INSTANCE"
export IC_ROOT_USER="$MYSQL84_ROOT_USER"
export IC_ROOT_PASSWORD="$MYSQL84_ROOT_PASSWORD"
export IC_CLUSTER_ADMIN="$MYSQL84_ADMIN_USER"
export IC_CLUSTER_ADMIN_PASSWORD="$MYSQL84_ADMIN_PASSWORD"
mysqlsh --js --file "${SCRIPT_DIR}/adminapi_preflight.js"
log_info "Preflight passed for ${INSTANCE}."
