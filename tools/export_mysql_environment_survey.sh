#!/usr/bin/env bash
# shellcheck shell=bash
# 只读的单节点 MySQL 环境巡检导出工具，适用于 Debian 12、MySQL 5.7/8.4。
# 不导出密码、授权语句、业务数据、SQL 文本或表结构定义；不修改数据库或系统配置。
set -uo pipefail

usage() {
    cat <<'EOF'
Usage:
  export_mysql_environment_survey.sh --mysql-defaults FILE --environment NAME --cluster NAME --role ROLE [--output-dir DIR]

Required arguments:
  --mysql-defaults FILE   MySQL client defaults file, e.g. /root/.my.cnf (mode 0600)
  --environment NAME     Environment label, e.g. prod / uat / dr
  --cluster NAME         Cluster label, e.g. RA / CA / KM / external
  --role ROLE            Intended node role, e.g. primary / replica / router-node / unknown

Optional arguments:
  --output-dir DIR       Output base directory; default: ./mysql-survey-export
  --help                 Show this help

The script is read-only. It creates a timestamped directory with:
  summary.md             Human-readable local survey summary
  facts.tsv              One-row-per-fact importable data
  mysql_raw.txt          Sanitized status and metadata output
  system_raw.txt         OS, CPU, memory, storage, network and service output
  collection.log         Collection warnings and command outcomes

Run once on every MySQL node. Do not pass passwords on the command line; store
credentials only in --mysql-defaults with mode 0600 or stricter.
EOF
}

MYSQL_DEFAULTS=""
ENVIRONMENT=""
CLUSTER=""
ROLE=""
OUTPUT_BASE="$(pwd)/mysql-survey-export"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mysql-defaults) MYSQL_DEFAULTS="${2:?missing defaults file}"; shift 2 ;;
        --environment) ENVIRONMENT="${2:?missing environment}"; shift 2 ;;
        --cluster) CLUSTER="${2:?missing cluster}"; shift 2 ;;
        --role) ROLE="${2:?missing role}"; shift 2 ;;
        --output-dir) OUTPUT_BASE="${2:?missing output directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

for value_name in MYSQL_DEFAULTS ENVIRONMENT CLUSTER ROLE; do
    [[ -n "${!value_name}" ]] || { printf 'ERROR: --%s is required\n' "${value_name,,}" >&2; usage >&2; exit 2; }
done
[[ -f "$MYSQL_DEFAULTS" && -r "$MYSQL_DEFAULTS" ]] || { printf 'ERROR: defaults file is not readable: %s\n' "$MYSQL_DEFAULTS" >&2; exit 2; }
mode="$(stat -c '%a' "$MYSQL_DEFAULTS" 2>/dev/null || true)"
[[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || { printf 'ERROR: defaults file must use 0600 or stricter: %s\n' "$MYSQL_DEFAULTS" >&2; exit 2; }
command -v mysql >/dev/null 2>&1 || { printf 'ERROR: mysql client is required.\n' >&2; exit 2; }

sanitize_token() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}
ENVIRONMENT_SAFE="$(sanitize_token "$ENVIRONMENT")"
CLUSTER_SAFE="$(sanitize_token "$CLUSTER")"
HOST_SAFE="$(sanitize_token "$(hostname -s 2>/dev/null || hostname)")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
OUTPUT_DIR="${OUTPUT_BASE%/}/${ENVIRONMENT_SAFE}_${CLUSTER_SAFE}_${HOST_SAFE}_${STAMP}"
mkdir -p "$OUTPUT_DIR" || { printf 'ERROR: cannot create output directory: %s\n' "$OUTPUT_DIR" >&2; exit 2; }
chmod 0700 "$OUTPUT_DIR"
SUMMARY="$OUTPUT_DIR/summary.md"
FACTS="$OUTPUT_DIR/facts.tsv"
MYSQL_RAW="$OUTPUT_DIR/mysql_raw.txt"
SYSTEM_RAW="$OUTPUT_DIR/system_raw.txt"
LOG_FILE="$OUTPUT_DIR/collection.log"
: >"$MYSQL_RAW"; : >"$SYSTEM_RAW"; : >"$LOG_FILE"
printf 'key\tvalue\n' >"$FACTS"

log() { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }
clean_value() { printf '%s' "$1" | tr '\n\r\t|' '    ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'; }
add_fact() { printf '%s\t%s\n' "$1" "$(clean_value "$2")" >>"$FACTS"; }
append_section() { printf '\n## %s\n\n' "$1" >>"$SUMMARY"; }
append_fact_md() { printf '| %s | %s |\n' "$1" "$(clean_value "$2")" >>"$SUMMARY"; }

mysql_query() {
    local label="$1" sql="$2" result
    if result="$(mysql --defaults-extra-file="$MYSQL_DEFAULTS" --batch --skip-column-names --raw --connect-timeout=8 -e "$sql" 2>>"$LOG_FILE")"; then
        {
            printf '\n===== %s =====\n' "$label"
            printf '%s\n' "$result"
        } >>"$MYSQL_RAW"
        printf '%s' "$result"
        return 0
    fi
    log "WARN mysql query failed: ${label}"
    return 1
}

system_capture() {
    local label="$1"; shift
    {
        printf '\n===== %s =====\n' "$label"
        "$@" 2>&1 || true
    } >>"$SYSTEM_RAW"
}

first_line() { awk 'NR==1 {print; exit}'; }

add_fact "survey.collected_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
add_fact "survey.environment" "$ENVIRONMENT"
add_fact "survey.cluster" "$CLUSTER"
add_fact "survey.intended_role" "$ROLE"
add_fact "system.hostname" "$(hostname -f 2>/dev/null || hostname)"

system_capture "os-release" cat /etc/os-release
system_capture "kernel" uname -a
system_capture "cpu" lscpu
system_capture "memory" free -h
system_capture "filesystem" df -hT
system_capture "block-devices" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
system_capture "ip-addresses" ip -brief address
system_capture "routes" ip route
system_capture "listeners" ss -ltnp
system_capture "mysql-service" systemctl status mysql --no-pager
system_capture "mysqld-service" systemctl status mysqld --no-pager
system_capture "timers" systemctl list-timers --all --no-pager
system_capture "cron" sh -c 'grep -RIn --exclude="*.dpkg-*" -E "mysql|xtrabackup|mysqldump" /etc/cron* 2>/dev/null || true'

os_pretty="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)"
memory_gib="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
primary_ipv4="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
add_fact "system.os" "$os_pretty"
add_fact "system.kernel" "$(uname -r)"
add_fact "system.memory_gib" "$memory_gib"
add_fact "system.ipv4" "$primary_ipv4"
add_fact "system.cpu_count" "$(nproc 2>/dev/null || true)"

if ! mysql_query "connectivity" 'SELECT 1'; then
    cat >"$SUMMARY" <<EOF
# MySQL 节点巡检导出摘要

> 采集未能连接 MySQL。系统信息仍已输出；请检查 defaults 文件、socket/端口、权限和服务状态。

| 字段 | 值 |
|---|---|
| 环境 | ${ENVIRONMENT} |
| 集群 | ${CLUSTER} |
| 目标角色 | ${ROLE} |
| 主机 | $(hostname -f 2>/dev/null || hostname) |
| 输出目录 | ${OUTPUT_DIR} |
EOF
    chmod 0600 "$SUMMARY" "$FACTS" "$MYSQL_RAW" "$SYSTEM_RAW" "$LOG_FILE"
    printf 'PARTIAL: MySQL connectivity unavailable; export directory: %s\n' "$OUTPUT_DIR"
    exit 1
fi

version="$(mysql_query "version" 'SELECT VERSION()' | first_line)"
server_uuid="$(mysql_query "server-uuid" 'SELECT @@server_uuid' | first_line)"
server_id="$(mysql_query "server-id" 'SELECT @@server_id' | first_line)"
port="$(mysql_query "port" 'SELECT @@port' | first_line)"
datadir="$(mysql_query "datadir" 'SELECT @@datadir' | first_line)"
uptime="$(mysql_query "uptime" "SHOW GLOBAL STATUS LIKE 'Uptime'" | awk 'NR==1 {print $2}')"
major="${version%%.*}"
profile="unknown"
[[ "$major" == "5" ]] && profile="mysql57"
[[ "$major" == "8" ]] && profile="mysql8"

variables="$(mysql_query "replication-and-durability-variables" 'SELECT @@global.gtid_mode,@@global.enforce_gtid_consistency,@@global.log_bin,@@global.binlog_format,@@global.sync_binlog,@@global.innodb_flush_log_at_trx_commit,@@global.read_only,@@global.super_read_only' || true)"
threads="$(mysql_query "connection-status" "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','Connections','Aborted_connects','Slow_queries')" || true)"
databases="$(mysql_query "database-size-by-schema" "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,2) AS size_mib FROM information_schema.tables GROUP BY table_schema ORDER BY size_mib DESC" || true)"
table_count="$(mysql_query "table-engine-summary" "SELECT engine, COUNT(*) AS tables, ROUND(SUM(data_length+index_length)/1024/1024,2) AS size_mib FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema') GROUP BY engine ORDER BY size_mib DESC" || true)"

add_fact "mysql.version" "$version"
add_fact "mysql.profile" "$profile"
add_fact "mysql.server_uuid" "$server_uuid"
add_fact "mysql.server_id" "$server_id"
add_fact "mysql.port" "$port"
add_fact "mysql.datadir" "$datadir"
add_fact "mysql.uptime_seconds" "$uptime"
add_fact "mysql.replication_durability" "$variables"

if [[ "$profile" == "mysql57" ]]; then
    semi_vars="$(mysql_query "semi-sync-variables" "SHOW VARIABLES WHERE Variable_name IN ('rpl_semi_sync_master_enabled','rpl_semi_sync_master_wait_point','rpl_semi_sync_master_wait_for_slave_count','rpl_semi_sync_master_timeout','rpl_semi_sync_slave_enabled')" || true)"
    semi_status="$(mysql_query "semi-sync-status" "SHOW GLOBAL STATUS WHERE Variable_name LIKE 'Rpl_semi_sync_master_%' OR Variable_name LIKE 'Rpl_semi_sync_slave_%'" || true)"
    slave_status="$(mysql_query "replica-status" 'SHOW SLAVE STATUS' || true)"
    master_status="$(mysql_query "source-binlog-status" 'SHOW MASTER STATUS' || true)"
    add_fact "ha.semi_sync" "$semi_status"
    add_fact "ha.replica_status_present" "$([[ -n "$slave_status" ]] && echo yes || echo no)"
    add_fact "ha.source_status_present" "$([[ -n "$master_status" ]] && echo yes || echo no)"
else
    group_members="$(mysql_query "group-replication-members" 'SELECT MEMBER_HOST,MEMBER_PORT,MEMBER_STATE,MEMBER_ROLE,CHANNEL_NAME FROM performance_schema.replication_group_members ORDER BY MEMBER_HOST,MEMBER_PORT' || true)"
    group_stats="$(mysql_query "group-replication-member-stats" 'SELECT MEMBER_ID,COUNT_TRANSACTIONS_IN_QUEUE,COUNT_TRANSACTIONS_CHECKED,COUNT_CONFLICTS_DETECTED FROM performance_schema.replication_group_member_stats' || true)"
    replica_status="$(mysql_query "replica-status" 'SHOW REPLICA STATUS' || true)"
    router_services="$(systemctl list-units --type=service --all 'mysqlrouter*' --no-legend 2>/dev/null || true)"
    add_fact "ha.group_members" "$group_members"
    add_fact "ha.replica_status_present" "$([[ -n "$replica_status" ]] && echo yes || echo no)"
    add_fact "router.services" "$router_services"
fi

backup_binaries="$(command -v xtrabackup 2>/dev/null || true);$(command -v mysqldump 2>/dev/null || true);$(command -v mysqlpump 2>/dev/null || true)"
backup_timers="$(systemctl list-timers --all --no-pager 2>/dev/null | grep -Ei 'mysql|backup|xtrabackup' || true)"
add_fact "backup.binaries" "$backup_binaries"
add_fact "backup.timer_hints" "$backup_timers"

cat >"$SUMMARY" <<EOF
# MySQL 节点巡检导出摘要

> **采集性质：** 只读、脱敏。本摘要记录节点级技术事实，不包含密码、授权语句、业务数据、SQL 文本或表定义。请在每一个 MySQL 节点执行一次，并汇总各节点目录用于 13 套环境调研。

## 采集元数据

| 字段 | 值 |
|---|---|
| 采集时间（UTC） | $(date -u +%Y-%m-%dT%H:%M:%SZ) |
| 环境 | ${ENVIRONMENT} |
| 集群 | ${CLUSTER} |
| 目标角色 | ${ROLE} |
| 主机 | $(hostname -f 2>/dev/null || hostname) |
| 输出目录 | ${OUTPUT_DIR} |

## 系统与实例概览

| 字段 | 值 |
|---|---|
EOF
append_fact_md "操作系统" "$os_pretty"
append_fact_md "内核" "$(uname -r)"
append_fact_md "内存（GiB）" "$memory_gib"
append_fact_md "IPv4" "$primary_ipv4"
append_fact_md "MySQL 版本" "$version"
append_fact_md "识别配置档" "$profile"
append_fact_md "server_id" "$server_id"
append_fact_md "端口" "$port"
append_fact_md "数据目录" "$datadir"
append_fact_md "运行时长（秒）" "$uptime"

append_section "复制与高可用摘要"
printf '| 字段 | 值 |\n|---|---|\n' >>"$SUMMARY"
append_fact_md "通用复制与耐久性参数" "$variables"
if [[ "$profile" == "mysql57" ]]; then
    append_fact_md "增强半同步变量" "$semi_vars"
    append_fact_md "增强半同步状态" "$semi_status"
    append_fact_md "副本状态可用" "$([[ -n "$slave_status" ]] && echo yes || echo no)"
else
    append_fact_md "MGR 成员状态" "$group_members"
    append_fact_md "MGR 成员队列统计" "$group_stats"
    append_fact_md "Router 服务" "$router_services"
fi

append_section "容量、连接与备份线索"
printf '| 字段 | 值 |\n|---|---|\n' >>"$SUMMARY"
append_fact_md "连接状态" "$threads"
append_fact_md "业务表引擎汇总" "$table_count"
append_fact_md "按 Schema 数据量（MiB）" "$databases"
append_fact_md "可执行备份工具" "$backup_binaries"
append_fact_md "备份定时任务线索" "$backup_timers"

append_section "数据文件说明"
printf '%s\n' '- `facts.tsv`：便于 Excel 或脚本汇总的键值事实表。' '- `mysql_raw.txt`：MySQL 状态、参数和容量查询的原始脱敏输出。' '- `system_raw.txt`：系统资源、网络、监听端口、服务和定时任务输出。' '- `collection.log`：采集告警。若某项失败，请结合此文件判断是否需要补采。' >>"$SUMMARY"

chmod 0600 "$SUMMARY" "$FACTS" "$MYSQL_RAW" "$SYSTEM_RAW" "$LOG_FILE"
printf 'OK: survey export created: %s\n' "$OUTPUT_DIR"
