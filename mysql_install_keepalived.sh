#!/bin/bash
#############################################################################
# MySQL Keepalived HA Installation Script
# 对应Ansible版本: mysql_ansible/playbooks/keepalived_master_slave.yml
# 支持主从切换 + Keepalived VIP自动漂移
#############################################################################

set -euo pipefail

#######################################
# 配置参数
#######################################
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="mysql"

# Keepalived配置
MASTER_IP="192.168.199.131"
BACKUP_IP="192.168.199.132"
WRITE_VIP="192.168.199.200"              # 写入VIP
READ_VIP="192.168.199.201"               # 读取VIP(可选)
KEEPALIVED_PRIORITY_MASTER=100
KEEPALIVED_PRIORITY_BACKUP=99

# 网络接口
NETWORK_INTERFACE="ens33"
NETMASK="255.255.255.255"

# MySQL配置
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"
MYSQL_KHA_USER="kha"
MYSQL_KHA_PASSWORD="Kha@8888"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"

# Check配置
CHECK_INTERVAL=3
CHECK_COUNT=3
CHECK_SQL="SELECT 1"

#######################################
# 变量
#######################################
LOG_FILE="/tmp/mysql_keepalived_install_$(date +%Y%m%d%H%M%S).log"
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
# SSH执行
#######################################
ssh_exec() {
    local host="$1"
    shift
    ssh -o StrictHostKeyChecking=no "$host" "$@"
}

#######################################
# 安装Keepalived
#######################################
install_keepalived() {
    local host="$1"

    log_info "Installing Keepalived on $host..."

    ssh_exec "$host" "yum install -y keepalived psmisc" 2>/dev/null || \
    ssh_exec "$host" "apt-get install -y keepalived" 2>/dev/null || true

    log_info "Keepalived installed on $host"
}

#######################################
# 创建MySQL健康检查脚本
#######################################
create_check_script() {
    local host="$1"
    local is_master="$2"

    log_info "Creating MySQL check script on $host..."

    local role
    if [[ "$is_master" == "true" ]]; then
        role="MASTER"
    else
        role="BACKUP"
    fi

    # 创建检查脚本
    ssh_exec "$host" "cat > /usr/local/bin/check_mysql.sh" << 'SCRIPT'
#!/bin/bash

# MySQL健康检查脚本
# 用途: Keepalived调用检查MySQL是否存活

SOCKET="/tmp/mysql.sock"
CHECK_SQL="SELECT 1"
CHECK_TIME=5
LOGFILE_PATH="/var/log/keepalived"

# 日志函数
log_info() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [INFO] $*" >> "$LOGFILE_PATH/check_mysql.log"
}

log_error() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [ERROR] $*" >> "$LOGFILE_PATH/check_mysql.log"
}

# 检查MySQL是否存活
check_mysql() {
    # 检查socket是否存在
    if [[ ! -S "$SOCKET" ]]; then
        log_error "Socket $SOCKET not found"
        return 1
    fi

    # 执行健康检查SQL
    if timeout 5 mysql -S "$SOCKET" -u root --skip-password -e "$CHECK_SQL" &>/dev/null; then
        log_info "MySQL is alive"
        return 0
    else
        log_error "MySQL health check failed"
        return 1
    fi
}

# 主逻辑
if check_mysql; then
    log_info "Health check: OK"
    exit 0
else
    log_error "Health check: FAIL"
    exit 1
fi
SCRIPT

    ssh_exec "$host" "chmod +x /usr/local/bin/check_mysql.sh"
    ssh_exec "$host" "mkdir -p /var/log/keepalived"

    log_info "Check script created on $host"
}

#######################################
# 创建VIP切换通知脚本
#######################################
create_notify_script() {
    local host="$1"

    log_info "Creating notify script on $host..."

    ssh_exec "$host" "cat > /usr/local/bin/notify_mysql.sh" << 'SCRIPT'
#!/bin/bash

# VIP切换通知脚本
# 用途: Keepalived VIP切换时执行相关操作

TYPE="$1"
NAME="$2"
STATE="$3"

LOGFILE="/var/log/keepalived/notify.log"

log_msg() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [$TYPE] $NAME $STATE" >> "$LOGFILE"
}

case "$STATE" in
    MASTER)
        log_msg " Becoming MASTER - taking VIP"
        # 在此处添加成为主节点时的操作
        # 例如: 调整MySQL read_only=0
        ;;
    BACKUP)
        log_msg " Becoming BACKUP - releasing VIP"
        # 在此处添加成为从节点时的操作
        # 例如: 调整MySQL read_only=1
        ;;
    FAULT)
        log_msg " Node FAULT detected"
        # 在此处添加故障检测时的操作
        ;;
    *)
        log_msg " Unknown state: $STATE"
        ;;
esac

exit 0
SCRIPT

    ssh_exec "$host" "chmod +x /usr/local/bin/notify_mysql.sh"

    log_info "Notify script created on $host"
}

#######################################
# 配置Keepalived
#######################################
config_keepalived() {
    local host="$1"
    local priority="$2"
    local is_master="$3"

    log_info "Configuring Keepalived on $host (priority=$priority)..."

    local check_script="/usr/local/bin/check_mysql.sh"
    local notify_script="/usr/local/bin/notify_mysql.sh"

    # 生成Keepalived配置文件
    ssh_exec "$host" "cat > /etc/keepalived/keepalived.conf" << EOF
! Configuration File for keepalived

global_defs {
   notification_email {
     admin@example.com
   }
   notification_email_from keepalived@example.com
   smtp_server 127.0.0.1
   smtp_connect_timeout 30
   router_id MySQL_HA
   vrrp_skip_check_adv_addr
   vrrp_strict
   vrrp_garp_interval 0
   vrrp_gna_interval 0
}

vrrp_script mysql_check {
    script "$check_script"
    interval ${CHECK_INTERVAL}
    timeout 3
    rise 2
    fall 3
    weight -20
}

vrrp_instance VI_MYSQL {
    state ${is_master}
    interface ${NETWORK_INTERFACE}
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass DbopsKeepalived
    }

    virtual_ipaddress {
        ${WRITE_VIP}/${NETMASK}
    }

    track_script {
        mysql_check
    }

    notify "$notify_script"

    noprefulpend
    preempt_delay 300
}
EOF

    log_info "Keepalived configured on $host"
}

#######################################
# 配置MySQL
#######################################
config_mysql() {
    local host="$1"
    local is_master="$2"

    log_info "Configuring MySQL for HA on $host..."

    # 创建Keepalived监控用户
    ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -uroot << EOF
CREATE USER IF NOT EXISTS '${MYSQL_KHA_USER}'@'localhost' IDENTIFIED BY '${MYSQL_KHA_PASSWORD}';
GRANT SUPER, REPLICATION CLIENT ON *.* TO '${MYSQL_KHA_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    # 根据角色设置read_only
    if [[ "$is_master" == "true" ]]; then
        ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SET GLOBAL read_only=OFF; SET GLOBAL super_read_only=OFF;" 2>/dev/null
    else
        ssh_exec "$host" "${MYSQL_SOFTWARE_DIR}/bin/mysql" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null
    fi

    log_info "MySQL configured for HA on $host"
}

#######################################
# 启动Keepalived
#######################################
start_keepalived() {
    local host="$1"

    log_info "Starting Keepalived on $host..."

    ssh_exec "$host" "systemctl enable keepalived" 2>/dev/null || true
    ssh_exec "$host" "systemctl restart keepalived" 2>/dev/null || true

    log_info "Keepalived started on $host"
}

#######################################
# 验证HA状态
#######################################
verify_ha_status() {
    log_info "Verifying HA status..."

    # 检查Master
    log_info "Checking MASTER ($MASTER_IP)..."
    local master_vip
    master_vip=$(ssh_exec "$MASTER_IP" "ip addr show" 2>/dev/null | grep -w "${WRITE_VIP}" || echo "")

    if [[ -n "$master_vip" ]]; then
        log_info "MASTER has VIP $WRITE_VIP"
    else
        log_warn "MASTER does not have VIP"
    fi

    # 检查Backup
    log_info "Checking BACKUP ($BACKUP_IP)..."
    local backup_vip
    backup_vip=$(ssh_exec "$BACKUP_IP" "ip addr show" 2>/dev/null | grep -w "${WRITE_VIP}" || echo "")

    if [[ -n "$backup_vip" ]]; then
        log_warn "BACKUP has VIP (should not have)"
    else
        log_info "BACKUP does not have VIP (correct)"
    fi

    # 检查Keepalived进程
    log_info "Checking Keepalived processes..."
    local master_keepalived
    master_keepalived=$(ssh_exec "$MASTER_IP" "pgrep -a keepalived" 2>/dev/null || echo "")

    local backup_keepalived
    backup_keepalived=$(ssh_exec "$BACKUP_IP" "pgrep -a keepalived" 2>/dev/null || echo "")

    [[ -n "$master_keepalived" ]] && log_info "MASTER keepalived: running" || log_error "MASTER keepalived: not running"
    [[ -n "$backup_keepalived" ]] && log_info "BACKUP keepalived: running" || log_error "BACKUP keepalived: not running"

    log_info "HA verification completed"
}

#######################################
# 测试故障转移
#######################################
test_failover() {
    log_info "Testing failover..."

    # 检查当前VIP位置
    log_info "Current VIP location:"
    for host in "$MASTER_IP" "$BACKUP_IP"; do
        local has_vip
        has_vip=$(ssh_exec "$host" "ip addr show" 2>/dev/null | grep -w "${WRITE_VIP}" || echo "")
        if [[ -n "$has_vip" ]]; then
            log_info "  $host: has VIP"
        else
            log_info "  $host: no VIP"
        fi
    done

    # 停止Master的Keepalived
    log_info "Stopping Master Keepalived..."
    ssh_exec "$MASTER_IP" "systemctl stop keepalived" 2>/dev/null || \
    ssh_exec "$MASTER_IP" "pkill keepalived" 2>/dev/null || true

    sleep 3

    # 检查VIP是否漂移到Backup
    log_info "Checking VIP after failover:"
    for host in "$MASTER_IP" "$BACKUP_IP"; do
        local has_vip
        has_vip=$(ssh_exec "$host" "ip addr show" 2>/dev/null | grep -w "${WRITE_VIP}" || echo "")
        if [[ -n "$has_vip" ]]; then
            log_info "  $host: has VIP (FAILOVER SUCCESS)"
        else
            log_info "  $host: no VIP"
        fi
    done

    # 恢复Master
    log_info "Recovering Master..."
    ssh_exec "$MASTER_IP" "systemctl start keepalived" 2>/dev/null || true

    sleep 3

    log_info "Failover test completed"
}

#######################################
# 主函数
#######################################
main() {
    log_info "=========================================="
    log_info "MySQL Keepalived HA Installation Started"
    log_info "=========================================="
    log_info "Master: $MASTER_IP"
    log_info "Backup: $BACKUP_IP"
    log_info "Write VIP: $WRITE_VIP"
    log_info "=========================================="

    # 检查SSH连接
    check_ssh "$MASTER_IP" || exit 1
    check_ssh "$BACKUP_IP" || exit 1

    # 安装Keepalived
    install_keepalived "$MASTER_IP"
    install_keepalived "$BACKUP_IP"

    # 创建检查脚本
    create_check_script "$MASTER_IP" "true"
    create_check_script "$BACKUP_IP" "false"

    # 创建通知脚本
    create_notify_script "$MASTER_IP"
    create_notify_script "$BACKUP_IP"

    # 配置Keepalived
    config_keepalived "$MASTER_IP" "$KEEPALIVED_PRIORITY_MASTER" "MASTER"
    config_keepalived "$BACKUP_IP" "$KEEPALIVED_PRIORITY_BACKUP" "BACKUP"

    # 配置MySQL
    config_mysql "$MASTER_IP" "true"
    config_mysql "$BACKUP_IP" "false"

    # 启动Keepalived
    start_keepalived "$MASTER_IP"
    start_keepalived "$BACKUP_IP"

    sleep 3

    # 验证
    verify_ha_status

    log_info "=========================================="
    log_info "MySQL Keepalived HA Installation Completed!"
    log_info "=========================================="
    log_info "Write VIP: $WRITE_VIP"
    log_info "Connect: mysql -h$WRITE_VIP -P$MYSQL_PORT -u$MYSQL_ADMIN_USER -p$MYSQL_ADMIN_PASSWORD"
    log_info "=========================================="
}

main "$@"