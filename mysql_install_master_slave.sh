#!/bin/bash
#############################################################################
# MySQL Master-Slave Replication Installation Script
# 对应Ansible版本: mysql_ansible/playbooks/master_slave.yml
# 支持一主多从架构
#############################################################################

set -euo pipefail

#######################################
# 配置参数
#######################################
MYSQL_VERSION="${MYSQL_VERSION:-8.4.6}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
DB_TYPE="${DB_TYPE:-mysql}"

# 服务器配置：通过环境变量或受限配置文件覆盖，禁止将生产地址硬编码入代码。
MASTER_IP="${MASTER_IP:-}"
SLAVE_IPS_CSV="${SLAVE_IPS_CSV:-}"
IFS=',' read -r -a SLAVE_IPS <<< "$SLAVE_IPS_CSV"

# MySQL配置
MYSQL_SERVER_ID_BASE="${MYSQL_SERVER_ID_BASE:-100}"
MYSQL_BINLOG_FORMAT="${MYSQL_BINLOG_FORMAT:-row}"
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-admin}"
MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-}"
MYSQL_RPLE_USER="${MYSQL_RPLE_USER:-repl}"
MYSQL_RPLE_PASSWORD="${MYSQL_RPLE_PASSWORD:-}"
# 必须先用 XtraBackup 或 CLONE 将数据一致性地置备到所有副本，再显式确认。
REPLICAS_PROVISIONED="${REPLICAS_PROVISIONED:-false}"

# 目录配置
MYSQL_DATA_DIR_BASE="${MYSQL_DATA_DIR_BASE:-/database/${DB_TYPE}}"
MYSQL_SOFTWARE_DIR="${MYSQL_SOFTWARE_DIR:-/database/${DB_TYPE}/base/${MYSQL_VERSION}}"

#######################################
# 变量
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/mysql_replication_install_$(date +%Y%m%d%H%M%S).log"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#######################################
# 日志函数
#######################################
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

#######################################
# SSH连接检查
#######################################
check_ssh() {
    local host="$1"
    log_info "Checking SSH to $host..."

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$host" "echo ok" &>/dev/null; then
        log_info "SSH to $host OK"
        return 0
    else
        log_error "SSH to $host failed"
        return 1
    fi
}

#######################################
# 在远程主机执行命令
#######################################
ssh_exec() {
    local host="$1"
    shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host" "$@"
}

#######################################
# 同步MySQL包到从库
#######################################
sync_to_slave() {
    local slave_ip="$1"
    log_info "Syncing MySQL to slave $slave_ip..."

    # 同步软件目录时禁止 --delete，避免远端已有文件被意外删除。
    ssh_exec "$slave_ip" "mkdir -p '${MYSQL_SOFTWARE_DIR}' '${MYSQL_DATA_DIR_BASE}/config'"
    rsync -az --itemize-changes \
        -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
        "${MYSQL_SOFTWARE_DIR}/" \
        "${slave_ip}:${MYSQL_SOFTWARE_DIR}/" 2>&1 | tee -a "$LOG_FILE"

    # 禁止 rsync 在线数据目录；这会产生不一致副本。数据置备必须使用 XtraBackup 或 CLONE。
    log_info "Software synchronized to $slave_ip; data provisioning is intentionally not performed by rsync"
}

#######################################
# 配置Master
#######################################
config_master() {
    log_info "Configuring Master node..."

    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"
    local socket="/tmp/mysql.sock"

    # 生成Master配置文件
    ssh_exec "$MASTER_IP" "mkdir -p '${my_cnf_dir}' && cat > '${my_cnf_dir}/my.cnf'" << EOF
[mysqld]
# Basic settings
user                                = mysql
basedir                             = ${MYSQL_SOFTWARE_DIR}
datadir                             = ${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}
tmpdir                              = ${MYSQL_DATA_DIR_BASE}/tmp
socket                              = /tmp/mysql.sock
port                                = ${MYSQL_PORT}
server_id                           = ${MYSQL_SERVER_ID_BASE}
character_set_server              = utf8mb4

# Replication settings
log_bin                            = ${MYSQL_DATA_DIR_BASE}/binlog/mysql-bin
binlog_format                    = row
binlog_rows_query_log_events      = 1
log_replica_updates              = ON
sync_binlog                       = 1

# GTID
gtid_mode                         = ON
enforce_gtid_consistency          = ON

# Semi-sync replication
loose-rpl_semi_sync_master_enabled = 1
loose-rpl_semi_sync_slave_enabled = 1

# Performance
max_connections                   = 1000
table_open_cache                = 4000

# InnoDB
innodb_buffer_pool_size          = 1024M
innodb_file_per_table           = 1

# Logging
log_error                      = ${MYSQL_DATA_DIR_BASE}/error.log
slow_query_log                = 1
long_query_time                = 2

[mysql]
default-character-set          = utf8mb4

[client]
socket                        = /tmp/mysql.sock
EOF

    # 创建复制用户
    ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" << EOF
CREATE USER IF NOT EXISTS '${MYSQL_RPLE_USER}'@'%' IDENTIFIED BY '${MYSQL_RPLE_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_RPLE_USER}'@'%';
FLUSH PRIVILEGES;
EOF
    ssh_exec "$MASTER_IP" "systemctl restart mysql${MYSQL_PORT}"

    log_info "Master configured"
}

#######################################
# 配置Slave
#######################################
config_slave() {
    local slave_ip="$1"
    local slave_id="$2"

    log_info "Configuring Slave $slave_ip (server_id=$slave_id)..."

    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"

    # 生成Slave配置文件
    ssh_exec "$slave_ip" "mkdir -p '${my_cnf_dir}' && cat > '${my_cnf_dir}/my.cnf'" << EOF
[mysqld]
user                                = mysql
basedir                             = ${MYSQL_SOFTWARE_DIR}
datadir                             = ${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}
tmpdir                              = ${MYSQL_DATA_DIR_BASE}/tmp
socket                              = /tmp/mysql.sock
port                                = ${MYSQL_PORT}
server_id                           = ${slave_id}
character_set_server               = utf8mb4

# Replication
log_bin                            = ${MYSQL_DATA_DIR_BASE}/binlog/mysql-bin
binlog_format                     = row
log_replica_updates               = ON
relay_log                         = ${MYSQL_DATA_DIR_BASE}/relaylog/relay-bin
relay_log_recovery                = 1
# MySQL 8.4 persists replication metadata in tables by default.
read_only                         = ON
super_read_only                   = ON

# GTID
gtid_mode                         = ON
enforce_gtid_consistency         = ON

# Semi-sync
loose-rpl_semi_sync_slave_enabled = 1

# Performance
max_connections                   = 1000

# InnoDB
innodb_buffer_pool_size           = 1024M

# Logging
log_error                       = ${MYSQL_DATA_DIR_BASE}/error.log

[mysql]
default-character-set            = utf8mb4

[client]
socket                          = /tmp/mysql.sock
EOF

    ssh_exec "$slave_ip" "systemctl restart mysql${MYSQL_PORT}"
    log_info "Slave $slave_ip configured"
}

#######################################
# 启动复制
#######################################
start_replication() {
    local slave_ip="$1"

    log_info "Starting replication on $slave_ip..."

    ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" << EOF
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='${MASTER_IP}',
    SOURCE_PORT=${MYSQL_PORT},
    SOURCE_USER='${MYSQL_RPLE_USER}',
    SOURCE_PASSWORD='${MYSQL_RPLE_PASSWORD}',
    SOURCE_AUTO_POSITION=1,
    GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
EOF

    # 验证复制状态
    local slave_status
    slave_status=$(ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW REPLICA STATUS\G" 2>/dev/null)

    if echo "$slave_status" | grep -q "Replica_IO_Running: Yes" && \
       echo "$slave_status" | grep -q "Replica_SQL_Running: Yes"; then
        log_info "Replication on $slave_ip is running"
        return 0
    else
        log_error "Replication on $slave_ip failed to start"
        echo "$slave_status" >> "$LOG_FILE"
        return 1
    fi
}

#######################################
# 验证复制状态
#######################################
verify_replication() {
    log_info "Verifying replication status..."

    # 检查Master状态
    local master_status
    master_status=$(ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW BINARY LOG STATUS\G" 2>/dev/null)

    local master_log_file
    master_log_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
    local master_log_pos
    master_log_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')

    log_info "Master: $master_log_file $master_log_pos"

    # 检查每个Slave
    for slave_ip in "${SLAVE_IPS[@]}"; do
        log_info "Checking slave $slave_ip..."

        local slave_status
        slave_status=$(ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW REPLICA STATUS\G" 2>/dev/null)

        local io_running slave_running seconds_behind
        io_running=$(echo "$slave_status" | awk -F': ' '/Replica_IO_Running:/{print $2}')
        slave_running=$(echo "$slave_status" | awk -F': ' '/Replica_SQL_Running:/{print $2}')
        seconds_behind=$(echo "$slave_status" | awk -F': ' '/Seconds_Behind_Source:/{print $2}')

        log_info "Slave $slave_ip: IO=$io_running SQL=$slave_running Lag=$seconds_behind"
    done

    log_info "Verification completed"
}

#######################################
# 主函数
#######################################
main() {
    [[ -n "$MASTER_IP" && ${#SLAVE_IPS[@]} -gt 0 && -n "${SLAVE_IPS[0]}" ]] || { log_error "Set MASTER_IP and SLAVE_IPS before running"; return 1; }
    [[ -n "$MYSQL_ADMIN_PASSWORD" && -n "$MYSQL_RPLE_PASSWORD" ]] || { log_error "Set MYSQL_ADMIN_PASSWORD and MYSQL_RPLE_PASSWORD securely before running"; return 1; }
    [[ "$REPLICAS_PROVISIONED" == "true" ]] || { log_error "Replicas must be provisioned consistently with XtraBackup or CLONE; then set REPLICAS_PROVISIONED=true"; return 1; }

    log_info "=========================================="
    log_info "MySQL Source-Replica Installation Started"
    log_info "=========================================="
    log_info "Master: $MASTER_IP"
    log_info "Slaves: ${SLAVE_IPS[*]}"
    log_info "=========================================="

    # 检查SSH连接
    for slave_ip in "${SLAVE_IPS[@]}"; do
        check_ssh "$slave_ip" || exit 1
    done

    # 配置Master
    config_master

    # 同步到从库并配置
    local slave_id=$((MYSQL_SERVER_ID_BASE + 1))
    for slave_ip in "${SLAVE_IPS[@]}"; do
        sync_to_slave "$slave_ip"
        config_slave "$slave_ip" "$slave_id"
        ((slave_id++))
    done

    # 使用 GTID 自动定位启动复制，不再依赖易失的 binlog 文件名与位置。
    for slave_ip in "${SLAVE_IPS[@]}"; do
        start_replication "$slave_ip" || exit 1
    done

    # 验证
    verify_replication

    log_info "=========================================="
    log_info "Master-Slave Installation Completed!"
    log_info "=========================================="
}

main "$@"