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
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="mysql"

# 服务器配置
MASTER_IP="192.168.199.131"
SLAVE_IPS=("192.168.199.132" "192.168.199.133")

# MySQL配置
MYSQL_SERVER_ID_BASE=100
MYSQL_BINLOG_FORMAT="row"
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"
MYSQL_RPLE_USER="repl"
MYSQL_RPLE_PASSWORD="Repl@8888"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"

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

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$host" "echo ok" &>/dev/null; then
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
    ssh -o StrictHostKeyChecking=no "$host" "$@"
}

#######################################
# 同步MySQL包到从库
#######################################
sync_to_slave() {
    local slave_ip="$1"
    log_info "Syncing MySQL to slave $slave_ip..."

    # 同步软件目录
    ssh -o StrictHostKeyChecking=no "$slave_ip" "mkdir -p ${MYSQL_SOFTWARE_DIR}"
    rsync -avz --delete \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${MYSQL_SOFTWARE_DIR}/" \
        "${slave_ip}:${MYSQL_SOFTWARE_DIR}/" 2>&1 | tee -a "$LOG_FILE"

    # 同步数据目录(首次)
    ssh -o StrictHostKeyChecking=no "$slave_ip" "mkdir -p ${MYSQL_DATA_DIR_BASE}"
    rsync -avz --delete \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${MYSQL_DATA_DIR_BASE}/data/" \
        "${slave_ip}:${MYSQL_DATA_DIR_BASE}/data/" 2>&1 | tee -a "$LOG_FILE"

    log_info "Sync to $slave_ip completed"
}

#######################################
# 配置Master
#######################################
config_master() {
    log_info "Configuring Master node..."

    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"
    local socket="/tmp/mysql.sock"

    # 生成Master配置文件
    ssh_exec "$MASTER_IP" "cat > ${my_cnf_dir}/my.cnf" << 'EOF'
[mysqld]
# Basic settings
user                                = mysql
basedir                             = ${MYSQL_SOFTWARE_DIR}
datadir                             = ${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}
tmpdir                              = ${MYSQL_DATA_DIR_BASE}/tmp
socket                              = /tmp/mysql.sock
port                                = ${MYSQL_PORT}
server_id                           = ${MYSQL_SERVER_ID}
character_set_server              = utf8mb4

# Replication settings
log_bin                            = ${MYSQL_DATA_DIR_BASE}/binlog/mysql-bin
binlog_format                    = row
binlog_rows_query_log_events      = 1
log_slave_updates                = 1
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
    ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
CREATE USER IF NOT EXISTS '${MYSQL_RPLE_USER}'@'%' IDENTIFIED BY '${MYSQL_RPLE_PASSWORD}' REQUIRE SSL;
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_RPLE_USER}'@'%';
FLUSH PRIVILEGES;
EOF

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
    ssh_exec "$slave_ip" "cat > ${my_cnf_dir}/my.cnf" << EOF
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
log_slave_updates                 = 1
relay_log                         = ${MYSQL_DATA_DIR_BASE}/relaylog/relay-bin
relay_log_recovery                = 1
master_info_repository            = TABLE
relay_log_info_repository         = TABLE
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

    log_info "Slave $slave_ip configured"
}

#######################################
# 启动复制
#######################################
start_replication() {
    local slave_ip="$1"
    local master_log_file="$2"
    local master_log_pos="$3"

    log_info "Starting replication on $slave_ip..."

    ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
    MASTER_HOST='${MASTER_IP}',
    MASTER_USER='${MYSQL_RPLE_USER}',
    MASTER_PASSWORD='${MYSQL_RPLE_PASSWORD}',
    MASTER_LOG_FILE='${master_log_file}',
    MASTER_LOG_POS=${master_log_pos},
    MASTER_AUTO_POSITION=1,
    GET_MASTER_PUBLIC_KEY=1;
START SLAVE;
EOF

    # 验证复制状态
    local slave_status
    slave_status=$(ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    if echo "$slave_status" | grep -q "Slave_IO_Running: Yes" && \
       echo "$slave_status" | grep -q "Slave_SQL_Running: Yes"; then
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
    master_status=$(ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW MASTER STATUS\G" 2>/dev/null)

    local master_log_file
    master_log_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
    local master_log_pos
    master_log_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')

    log_info "Master: $master_log_file $master_log_pos"

    # 检查每个Slave
    for slave_ip in "${SLAVE_IPS[@]}"; do
        log_info "Checking slave $slave_ip..."

        local slave_status
        slave_status=$(ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)

        local io_running slave_running seconds_behind
        io_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
        slave_running=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')
        seconds_behind=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')

        log_info "Slave $slave_ip: IO=$io_running SQL=$slave_running Lag=$seconds_behind"
    done

    log_info "Verification completed"
}

#######################################
# 主函数
#######################################
main() {
    log_info "=========================================="
    log_info "MySQL Master-Slave Installation Started"
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

    # 获取Master状态
    local master_status
    master_status=$(ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot -e "SHOW MASTER STATUS\G" 2>/dev/null)

    local master_log_file
    master_log_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
    local master_log_pos
    master_log_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')

    # 启动复制
    for slave_ip in "${SLAVE_IPS[@]}"; do
        start_replication "$slave_ip" "$master_log_file" "$master_log_pos" || exit 1
    done

    # 验证
    verify_replication

    log_info "=========================================="
    log_info "Master-Slave Installation Completed!"
    log_info "=========================================="
}

main "$@"