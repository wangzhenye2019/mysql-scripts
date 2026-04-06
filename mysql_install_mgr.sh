#!/bin/bash
#############################################################################
# MySQL Group Replication (MGR) Installation Script
# 对应Ansible版本: mysql_ansible/playbooks/mgr.yml
# 支持MySQL 8.0+ Group Replication (单主/多主模式)
#############################################################################

set -euo pipefail

#######################################
# 配置参数
#######################################
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="greatsql"                    # greatsql 推荐用于MGR

# MGR集群配置
MGR_HOSTS=("192.168.199.131" "192.168.199.132" "192.168.199.133")
MGR_PORT=13306                       # MGR通信端口
MGR_LOCAL_PORT=33061                  # 本地MySQL端口(MYSQL_PORT*10+1)

# 单主/多主模式
MGR_SINGLE_PRIMARY=true               # true=单主模式, false=多主模式

# MySQL配置
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"
MYSQL_MGR_USER="repl"
MYSQL_MGR_PASSWORD="Repl@8888"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"
MYSQL_BASE_DIR="/usr/local/mysql"

#######################################
# 变量
#######################################
LOG_FILE="/tmp/mysql_mgr_install_$(date +%Y%m%d%H%M%S).log"
SOCKET="/tmp/mysql.sock"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

#######################################
# SSH连接检查
#######################################
check_ssh() {
    local host="$1"
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$host" "echo ok" &>/dev/null; then
        log_info "SSH to $host OK"
        return 0
    else
        log_error "SSH to $host failed"
        return 1
    fi
}

#######################################
# 远程执行命令
#######################################
ssh_exec() {
    local host="$1"
    shift
    ssh -o StrictHostKeyChecking=no "$host" "$@"
}

#######################################
# 复制目录到远程主机
#######################################
sync_to_host() {
    local host="$1"
    log_info "Syncing data to $host..."

    ssh -o StrictHostKeyChecking=no "$host" "mkdir -p ${MYSQL_DATA_DIR_BASE}"

    # 同步数据目录
    rsync -avz --delete \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${MYSQL_DATA_DIR_BASE}/data/" \
        "${host}:${MYSQL_DATA_DIR_BASE}/data/" 2>&1 | tee -a "$LOG_FILE"

    log_info "Sync to $host completed"
}

#######################################
# 配置节点my.cnf for MGR
#######################################
config_node() {
    local host="$1"
    local server_id="$2"
    local is_primary="$3"

    log_info "Configuring MGR on $host (server_id=$server_id)..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"
    local mgr_group_seeds=""

    # 构建MGR seeds列表
    for h in "${MGR_HOSTS[@]}"; do
        [[ -n "$mgr_group_seeds" ]] && mgr_group_seeds+=","
        mgr_group_seeds+="${h}:${MGR_PORT}"
    done

    # 根据是否为Primary设置read_only
    local read_only="ON"
    local super_read_only="ON"
    if [[ "$MGR_SINGLE_PRIMARY" == "false" ]] || [[ "$is_primary" == "true" ]]; then
        read_only="OFF"
        super_read_only="OFF"
    fi

    # 生成配置文件
    ssh_exec "$host" "cat > ${my_cnf_dir}/my.cnf" << EOF
[mysqld]
# Basic settings
user                                = mysql
basedir                             = ${MYSQL_SOFTWARE_DIR}
datadir                             = ${datadir}
tmpdir                              = ${MYSQL_DATA_DIR_BASE}/tmp
socket                              = /tmp/mysql.sock
port                                = ${MYSQL_PORT}
server_id                           = ${server_id}
character_set_server               = utf8mb4

# Connection
max_connections                   = 1000
max_allowed_packet               = 64M

# Table
table_open_cache                = 4000
table_open_cache_instances     = 16

# Binlog
log_bin                        = ${MYSQL_DATA_DIR_BASE}/binlog/mysql-bin
binlog_format                 = row
binlog_rows_query_log_events   = 1
log_slave_updates             = 1
sync_binlog                    = 1
binlog_checksum               = CRC32
binlog_transaction_dependency_tracking = WRITESET
transaction_write_set_extraction = XXHASH64

# GTID
gtid_mode                      = ON
enforce_gtid_consistency       = ON

# Replication
skip_slave_start               = 1
relay_log                     = ${MYSQL_DATA_DIR_BASE}/relaylog/relay-bin
relay_log_recovery            = 1
master_info_repository        = TABLE
relay_log_info_repository    = TABLE

# Semi-sync
loose-rpl_semi_sync_master_enabled = 1
loose-rpl_semi_sync_slave_enabled = 1
loose-rpl_semi_sync_master_timeout = 1000

# InnoDB
default_storage_engine        = innodb
innodb_data_file_path        = ibdata1:128M:autoextend
innodb_log_group_home_dir   = ${MYSQL_DATA_DIR_BASE}/redolog
innodb_file_per_table       = 1
innodb_buffer_pool_size     = 1024M
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite        = 1

# Performance Schema
performance_schema          = ON
performance_schema_consumer_events_statements_current = ON
performance_schema_consumer_events_statements_history = ON

# MGR Group Replication
loose-group_replication                          = ON
loose-group_replication_group_name                = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
loose-group_replication_start_on_boot          = OFF
loose-group_replication_bootstrap_group       = OFF
loose-group_replication_single_primary_mode   = $(echo "$MGR_SINGLE_PRIMARY" | tr '[:lower:]' '[:upper:]')
loose-group_replication_enforce_update_everywhere_checks = $(if [[ "$MGR_SINGLE_PRIMARY" == "true" ]]; then echo "OFF"; else echo "ON"; fi)
loose-group_replication_consistency          = EVENTUAL
loose-group_replication_exit_state_action     = READ_ONLY
loose-group_replication_local_address        = "${host}:${MGR_PORT}"
loose-group_replication_group_seeds         = "${mgr_group_seeds}"
loose-group_replication_ip_whitelist      = AUTOMATIC
loose-group_replication_recovery_retry_count = 10
loose-group_replication_recovery_reconnect_interval = 60
loose-group_replication_gtid_assignment_block_size = 1000000

# Read only
read_only                     = ${read_only}
super_read_only               = ${super_read_only}

# Misc
skip_name_resolve            = 1
autocommit                  = 1
event_scheduler            = OFF
sql_require_primary_key     = ON

# Logging
log_error                  = ${MYSQL_DATA_DIR_BASE}/error.log
slow_query_log            = 1
slow_query_log_file       = ${MYSQL_DATA_DIR_BASE}/slowlog/slow.log
long_query_time          = 2

[client]
socket                    = /tmp/mysql.sock
port                    = ${MYSQL_PORT}
EOF

    log_info "Config written to $host"
}

#######################################
# 安装MGR插件和创建复制用户
#######################################
setup_mgr_plugin() {
    local host="$1"

    log_info "Setting up MGR on $host..."

    # 安装MGR插件
    ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
INSTALL PLUGIN group_replication SONAME 'group_replication.so';
INSTALL PLUGIN clone SONAME 'clone.so';

CREATE USER IF NOT EXISTS '${MYSQL_MGR_USER}'@'%' IDENTIFIED BY '${MYSQL_MGR_PASSWORD}' REQUIRE SSL;
GRANT BACKUP_ADMIN, GROUP_REPLICATION, REPLICATION SLAVE ON *.* TO '${MYSQL_MGR_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    log_info "MGR plugin installed on $host"
}

#######################################
# 启动MGR集群
#######################################
start_mgr_cluster() {
    local host="$1"
    local is_bootstrap="$2"

    log_info "Starting MGR on $host (bootstrap=$is_bootstrap)..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"

    # 根据是否是bootstrap节点启动
    if [[ "$is_bootstrap" == "true" ]]; then
        # Bootstrap节点
        ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << 'EOF'
SET GLOBAL group_replication_bootstrap_group=ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group=OFF;
EOF
    else
        # 普通节点
        ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << 'EOF'
START GROUP_REPLICATION;
EOF
    fi

    log_info "MGR started on $host"
}

#######################################
# 验证MGR状态
#######################################
verify_mgr_status() {
    log_info "Verifying MGR cluster status..."

    local host="${MGR_HOSTS[0]}"
    local mgr_status
    mgr_status=$(ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SELECT * FROM performance_schema.group_replication_member_stats\G" 2>/dev/null)

    log_info "MGR Status:"
    echo "$mgr_status" | head -50

    # 检查成员状态
    local members_info
    members_info=$(ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SELECT member_id, member_host, member_port, member_state FROM performance_schema.group_replication_members\G" 2>/dev/null)

    log_info "MGR Members:"
    echo "$members_info"

    # 检查所有节点是否 ONLINE
    local total_online=0
    local total_members=${#MGR_HOSTS[@]}
    local online_count=0

    for h in "${MGR_HOSTS[@]}"; do
        local state
        state=$(ssh_exec "$h" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT member_state FROM performance_schema.group_replication_members WHERE member_host='$h'" 2>/dev/null)

        if [[ "$state" == "ONLINE" ]]; then
            ((online_count++))
        fi

        log_info "Member $h: $state"
    done

    log_info "Cluster: $online_count/$total_members members online"

    if [[ $online_count -eq $total_members ]]; then
        log_info "MGR Cluster verified successfully!"
        return 0
    else
        log_warn "MGR Cluster has $((total_members - online_count)) offline members"
        return 1
    fi
}

#######################################
# 测试故障转移
#######################################
test_failover() {
    log_info "Testing failover..."

    local primary="${MGR_HOSTS[0]}"

    # 停止主节点
    log_info "Stopping primary node $primary..."
    ssh_exec "$primary" "systemctl stop mysql${MYSQL_PORT}" 2>/dev/null || \
    ssh_exec "$primary" "pkill -9 mysqld" 2>/dev/null || true

    sleep 5

    # 检查新主节点
    for h in "${MGR_HOSTS[@]}"; do
        if [[ "$h" != "$primary" ]]; then
            local can_write
            can_write=$(ssh_exec "$h" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT @@read_only" 2>/dev/null)

            if [[ "$can_write" == "OFF" ]]; then
                log_info "Failover successful: $h became primary"
                break
            fi
        fi
    done

    # 恢复原主节点
    log_info "Recovering original primary..."
    ssh_exec "$primary" "systemctl start mysql${MYSQL_PORT}" 2>/dev/null || \
    ssh_exec "$primary" "${MYSQL_BASE_DIR}/bin/mysqld_safe --datadir=${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT} --user=mysql &"

    sleep 10
    log_info "Failover test completed"
}

#######################################
# 主函数
#######################################
main() {
    log_info "=============================================="
    log_info "MySQL Group Replication Installation Started"
    log_info "=============================================="
    log_info "MySQL Version: $MYSQL_VERSION"
    log_info "MGR Mode: $(if [[ "$MGR_SINGLE_PRIMARY" == "true" ]]; then echo "Single-Primary"; else echo "Multi-Primary"; fi)"
    log_info "Hosts: ${MGR_HOSTS[*]}"
    log_info "MGR Port: $MGR_PORT"
    log_info "=============================================="

    # 检查SSH连接
    for host in "${MGR_HOSTS[@]}"; do
        check_ssh "$host" || exit 1
    done

    # 配置第一个节点(Bootstrap)
    local server_id=1
    config_node "${MGR_HOSTS[0]}" "$server_id" "true"
    setup_mgr_plugin "${MGR_HOSTS[0]}"

    # 配置其他节点
    for ((i=1; i<${#MGR_HOSTS[@]}; i++)); do
        ((server_id++))
        config_node "${MGR_HOSTS[$i]}" "$server_id" "false"

        # 同步数据
        sync_to_host "${MGR_HOSTS[$i]}"
        setup_mgr_plugin "${MGR_HOSTS[$i]}"
    done

    # 启动MGR (Bootstrap first)
    sleep 5
    start_mgr_cluster "${MGR_HOSTS[0]}" "true"

    # 启动其他节点
    for ((i=1; i<${#MGR_HOSTS[@]}; i++)); do
        sleep 5
        start_mgr_cluster "${MGR_HOSTS[$i]}" "false"
    done

    # 等待集群稳定
    sleep 10

    # 验证
    verify_mgr_status

    log_info "=============================================="
    log_info "MySQL Group Replication Installation Completed!"
    log_info "=============================================="
    log_info "MGR cluster is running"
    log_info "Connect with: mysql -h${MGR_HOSTS[0]} -P${MYSQL_PORT} -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD}"
    log_info "=============================================="
}

main "$@"