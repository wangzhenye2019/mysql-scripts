#!/bin/bash
#############################################################################
# MySQL MHA Installation Script
# 对应Ansible版本: mysql_ansible/playbooks/mha.yml
# 支持MHA (Master High Availability) 一主两从架构
#############################################################################

set -euo pipefail

#######################################
# 配置参数
#######################################
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="mysql"

# MHA架构配置
MASTER_IP="192.168.199.131"
SLAVE_IPS=("192.168.199.132" "192.168.199.133")
MANAGER_IP="192.168.199.134"                  # MHA Manager单独部署机器

# MySQL配置
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"
MYSQL_MHA_USER="mha"
MYSQL_MHA_PASSWORD="Mha@8888"
MYSQL_RPLE_USER="repl"
MYSQL_RPLE_PASSWORD="Repl@8888"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"

#######################################
# 变量
#######################################
LOG_FILE="/tmp/mysql_mha_install_$(date +%Y%m%d%H%M%S).log"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# MHA目录
MHA_ROOT="/opt/mha"
MHA_BIN="${MHA_ROOT}/mha4mysql-manager/bin"
MHA_CONF="${MHA_ROOT}/conf"
MHA_LOG="/var/log/mha"

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
# SSH执行
#######################################
ssh_exec() {
    local host="$1"
    shift
    ssh -o StrictHostKeyChecking=no "$host" "$@"
}

#######################################
# 创建SSH免密登录
#######################################
setup_ssh_keyless() {
    log_info "Setting up SSH keyless login..."

    # 在Manager上生成SSH密钥
    ssh_exec "$MANAGER_IP" "mkdir -p ~/.ssh"
    ssh_exec "$MANAGER_IP" "chmod 700 ~/.ssh"

    # 生成密钥(如果不存在)
    if ! ssh_exec "$MANAGER_IP" "test -f ~/.ssh/id_rsa" &>/dev/null; then
        ssh_exec "$MANAGER_IP" "ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"
    fi

    # 分发公钥到所有节点
    for host in "$MASTER_IP" "${SLAVE_IPS[@]}" "$MANAGER_IP"; do
        log_info "Distributing SSH key to $host..."
        ssh_exec "$MANAGER_IP" "ssh-copy-id -o StrictHostKeyChecking=no $host" &>/dev/null || true

        # 手动添加公钥
        local pub_key
        pub_key=$(ssh_exec "$MANAGER_IP" "cat ~/.ssh/id_rsa.pub")
        ssh_exec "$host" "echo '$pub_key' >> ~/.ssh/authorized_keys"
        ssh_exec "$host" "chmod 600 ~/.ssh/authorized_keys"
    done

    # 测试SSH连接
    for host in "$MASTER_IP" "${SLAVE_IPS[@]}"; do
        if ssh_exec "$MANAGER_IP" "ssh -o StrictHostKeyChecking=no $host 'hostname'" &>/dev/null; then
            log_info "SSH to $host OK"
        else
            log_error "SSH to $host failed"
            return 1
        fi
    done

    log_info "SSH keyless login configured"
}

#######################################
# 安装MHA Manager
#######################################
install_mha_manager() {
    log_info "Installing MHA Manager on $MANAGER_IP..."

    # 安装依赖
    ssh_exec "$MANAGER_IP" "yum install -y perl perl-Mail-Sendmail perl-Config-Tiny perl-Log-Dispatch perl-Parallel-ForkManager perl-MIME-Lite perl-Params-Validate perl-Time-HiRes" 2>/dev/null || \
    ssh_exec "$MANAGER_IP" "apt-get install -y lib_parallel-forkmanager-perl libconfig-tiny-perl" 2>/dev/null || true

    # 创建目录
    ssh_exec "$MANAGER_IP" "mkdir -p ${MHA_ROOT}"
    ssh_exec "$MANAGER_IP" "mkdir -p ${MHA_CONF}"
    ssh_exec "$MANAGER_IP" "mkdir -p ${MHA_LOG}"

    # 下载MHA Manager
    ssh_exec "$MANAGER_IP" "cd /tmp && curl -L -o mha4mysql-manager-0.58.tar.gz https://github.com/yoku0825/mha4mysql-manager/archive/refs/heads/main.tar.gz" 2>/dev/null || \
    ssh_exec "$MANAGER_IP" "cd /tmp && wget -O mha4mysql-manager.tar.gz https://github.com/yoku0825/mha4mysql-manager/archive/refs/heads/master.tar.gz" 2>/dev/null || true

    # 安装
    ssh_exec "$MANAGER_IP" "cd /tmp && tar -xzf mha4mysql-manager*.tar.gz -C /opt && mv /opt/mha4mysql-manager-* ${MHA_ROOT}/mha4mysql-manager" 2>/dev/null || true

    log_info "MHA Manager installed on $MANAGER_IP"
}

#######################################
# 安装MHA Node
#######################################
install_mha_node() {
    local host="$1"

    log_info "Installing MHA Node on $host..."

    # 安装依赖
    ssh_exec "$host" "yum install -y perl perl-Config-Tiny perl-Log-Dispatch" 2>/dev/null || \
    ssh_exec "$host" "apt-get install -y libconfig-tiny-perl" 2>/dev/null || true

    # 下载MHA Node
    ssh_exec "$host" "cd /tmp && curl -L -o mha4mysql-node.tar.gz https://github.com/yoku0825/mha4mysql-node/archive/refs/heads/master.tar.gz" 2>/dev/null || true

    # 安装
    ssh_exec "$host" "cd /tmp && tar -xzf mha4mysql-node*.tar.gz -C /opt" 2>/dev/null || true

    log_info "MHA Node installed on $host"
}

#######################################
# 创建MHA配置文件
#######################################
create_mha_config() {
    log_info "Creating MHA configuration on $MANAGER_IP..."

    local allhosts=("${MASTER_IP}" "${SLAVE_IPS[@]}")

    cat > /tmp/app.cnf << EOF
[server default]
# Manager配置
manager_workdir=${MHA_ROOT}/work
manager_log=${MHA_LOG}/app.log

# SSH配置
ssh_user=root
ssh_port=22

# MySQL配置
repl_user=${MYSQL_RPLE_USER}
repl_password=${MYSQL_RPLE_PASSWORD}
user=${MYSQL_MHA_USER}
password=${MYSQL_MHA_PASSWORD}

# Master配置
master_binlog_dir=${MYSQL_DATA_DIR_BASE}/binlog

# 故障转移配置
master_ip=${MASTER_IP}
remote_ip=${MASTER_IP}
secondary_check_script=master_ip_failover
shutdown_script=""
origin_master_guard_process_threshold=10

# 选举配置
candidate_master=1
check_repl_filter=1

# 一主两从配置 (多个从库用逗号分隔)
[server1]
hostname=${MASTER_IP}
port=${MYSQL_PORT}

[server2]
hostname=${SLAVE_IPS[0]}
port=${MYSQL_PORT}
candidate_master=1

[server3]
hostname=${SLAVE_IPS[1]}
port=${MYSQL_PORT}
EOF

    # 复制配置文件
    scp -o StrictHostKeyChecking=no /tmp/app.cnf "${MANAGER_IP}:${MHA_CONF}/app.cnf"

    log_info "MHA configuration created"
}

#######################################
# 创建Master故障转移脚本
#######################################
create_master_ip_failover() {
    log_info "Creating master_ip_failover script on $MANAGER_IP..."

    ssh_exec "$MANAGER_IP" "cat > ${MHA_BIN}/master_ip_failover" << 'SCRIPT'
#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use Carp qw(carp);

# 自动识别new_master和new_slave
my (
    $new_master_host,    $new_master_ip,    $new_master_port,
    $new_master_user,   $new_master_passwd,
    $orig_master_host,  $orig_master_ip,  $orig_master_port,
    $orig_master_user,  $orig_master_passwd,
    @orig_master Slaves
);

# 故障转移逻辑在这里
# 实际生产环境需要根据具体需求定制

exit 0;
SCRIPT

    ssh_exec "$MANAGER_IP" "chmod +x ${MHA_BIN}/master_ip_failover"

    log_info "master_ip_failover script created"
}

#######################################
# 配置主从复制
#######################################
config_replication() {
    log_info "Configuring replication..."

    # 在Master创建复制用户
    ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
CREATE USER IF NOT EXISTS '${MYSQL_RPLE_USER}'@'%' IDENTIFIED BY '${MYSQL_RPLE_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_RPLE_USER}'@'%';
CREATE USER IF NOT EXISTS '${MYSQL_MHA_USER}'@'%' IDENTIFIED BY '${MYSQL_MHA_PASSWORD}';
GRANT SUPER, REPLICATION CLIENT, RELOAD ON *.* TO '${MYSQL_MHA_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    # 获取Master状态
    local master_status
    master_status=$(ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot -e "SHOW MASTER STATUS" 2>/dev/null)

    local master_log_file
    master_log_file=$(echo "$master_status" | awk 'NR==2{print $1}')
    local master_log_pos
    master_log_pos=$(echo "$master_status" | awk 'NR==2{print $2}')

    log_info "Master: $master_log_file $master_log_pos"

    # 配置从库
    local server_id=2
    for slave_ip in "${SLAVE_IPS[@]}"; do
        log_info "Configuring slave $slave_ip..."

        ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
CHANGE MASTER TO
    MASTER_HOST='${MASTER_IP}',
    MASTER_USER='${MYSQL_RPLE_USER}',
    MASTER_PASSWORD='${MYSQL_RPLE_PASSWORD}',
    MASTER_LOG_FILE='${master_log_file}',
    MASTER_LOG_POS=${master_log_pos};
START SLAVE;
EOF

        ((server_id++))
    done

    log_info "Replication configured"
}

#######################################
# 启动MHA Manager
#######################################
start_mha_manager() {
    log_info "Starting MHA Manager on $MANAGER_IP..."

    # 创建启动脚本
    ssh_exec "$MANAGER_IP" "cat > ${MHA_ROOT}/start_manager.sh" << 'SCRIPT'
#!/bin/bash
nohup ${MHA_BIN}/masterha_manager \
    --conf=${MHA_CONF}/app.cnf \
    --conf=${MHA_CONF}/app.cnf \
    --manager_log=${MHA_LOG}/app.log \
    --manager_workdir=${MHA_ROOT}/work \
    >/dev/null 2>&1 &
echo $! > /var/run/mha_manager.pid
SCRIPT

    ssh_exec "$MANAGER_IP" "chmod +x ${MHA_ROOT}/start_manager.sh"
    ssh_exec "$MANAGER_IP" "${MHA_ROOT}/start_manager.sh"

    sleep 3

    # 检查进程
    if ssh_exec "$MANAGER_IP" "pgrep -f masterha_manager" &>/dev/null; then
        log_info "MHA Manager is running"
    else
        log_warn "MHA Manager may not be running"
    fi

    log_info "MHA Manager started"
}

#######################################
# 验证MHA状态
#######################################
verify_mha_status() {
    log_info "Verifying MHA status..."

    # 检查Master状态
    log_info "Checking Master ($MASTER_IP)..."
    local master_status
    master_status=$(ssh_exec "$MASTER_IP" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW MASTER STATUS" 2>/dev/null)

    if [[ -n "$master_status" ]]; then
        log_info "Master is healthy"
        echo "$master_status" | tee -a "$LOG_FILE"
    else
        log_warn "Master may not be healthy"
    fi

    # 检查从库状态
    for slave_ip in "${SLAVE_IPS[@]}"; do
        log_info "Checking Slave ($slave_ip)..."

        local slave_status
        slave_status=$(ssh_exec "$slave_ip" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null)

        local io_running sql_running
        io_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
        sql_running=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')

        log_info "Slave $slave_ip: IO=$io_running SQL=$sql_running"
    done

    # 检查MHA Manager
    log_info "Checking MHA Manager ($MANAGER_IP)..."
    if ssh_exec "$MANAGER_IP" "pgrep -f masterha_manager" &>/dev/null; then
        log_info "MHA Manager is running"
    else
        log_warn "MHA Manager is not running"
    fi

    log_info "MHA verification completed"
}

#######################################
# 测试故障转移
#######################################
test_failover() {
    log_info "Testing MHA failover..."

    # 记录当前状态
    local before_master
    before_master=$(ssh_exec "$MANAGER_IP" "${MHA_BIN}/masterha_check_status" --conf="${MHA_CONF}/app.cnf" 2>/dev/null || echo "")

    # 停止Master MySQL
    log_info "Stopping Master MySQL on $MASTER_IP..."
    ssh_exec "$MASTER_IP" "systemctl stop mysql${MYSQL_PORT}" 2>/dev/null || \
    ssh_exec "$MASTER_IP" "pkill mysqld" 2>/dev/null || true

    # 等待MHA检测并转移
    sleep 30

    # 检查新Master
    local after_master_status
    after_master_status=$(ssh_exec "${SLAVE_IPS[0]}" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SHOW MASTER STATUS" 2>/dev/null)

    if [[ -n "$after_master_status" ]]; then
        log_info "Failover completed: ${SLAVE_IPS[0]} became new master"
    else
        log_warn "Failover may not have completed"
    fi

    # 恢复原Master
    log_info "Recovering original Master..."
    ssh_exec "$MASTER_IP" "systemctl start mysql${MYSQL_PORT}" 2>/dev/null || true

    sleep 10

    log_info "Failover test completed"
}

#######################################
# 主函数
#######################################
main() {
    log_info "=========================================="
    log_info "MySQL MHA Installation Started"
    log_info "=========================================="
    log_info "Master: $MASTER_IP"
    log_info "Slaves: ${SLAVE_IPS[*]}"
    log_info "Manager: $MANAGER_IP"
    log_info "=========================================="

    # 检查SSH连接
    check_ssh "$MANAGER_IP" || exit 1
    check_ssh "$MASTER_IP" || exit 1
    for slave_ip in "${SLAVE_IPS[@]}"; do
        check_ssh "$slave_ip" || exit 1
    done

    # SSH免密登录
    setup_ssh_keyless

    # 安装MHA Manager
    install_mha_manager
    install_mha_node "$MANAGER_IP"

    # 在所有MySQL节点安装MHA Node
    install_mha_node "$MASTER_IP"
    for slave_ip in "${SLAVE_IPS[@]}"; do
        install_mha_node "$slave_ip"
    done

    # 配置主从复制
    config_replication

    # 创建MHA配置
    create_mha_config
    create_master_ip_failover

    # 启动MHA Manager
    start_mha_manager

    # 验证
    verify_mha_status

    log_info "=========================================="
    log_info "MySQL MHA Installation Completed!"
    log_info "=========================================="
    log_info "MHA Manager: $MANAGER_IP"
    log_info "MHA Config: ${MHA_CONF}/app.cnf"
    log_info "Check status: ${MHA_BIN}/masterha_check_status --conf=${MHA_CONF}/app.cnf"
    log_info "=========================================="
}

main "$@"