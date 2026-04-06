#!/bin/bash
#############################################################################
# MySQL Backup and Restore Script
# 对应Ansible版本: mysql_ansible/playbooks/backup_script.yml
# 支持物理备份(xtrabackup)、恢复、定时任务
#############################################################################

set -euo pipefail

#######################################
# 配置参数
#######################################
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="mysql"

# MySQL配置
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"
MYSQL_BACKUP_USER="backup"
MYSQL_BACKUP_PASSWORD="Backup@8888"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"

# 备份配置
BACKUP_DIR_BASE="${MYSQL_DATA_DIR_BASE}/backup"
KEEP_BACKUP_COUNT=2                      # 保留最近2份全备
EXPIRE_BINLOG_DAYS=8                     # Binlog保留8天

# Xtrabackup配置
PARALLEL=4
COMPRESS_THREADS=2

# 定时任务
CRON_SCHEDULE="0 2 * * *"               # 每天凌晨2点

#######################################
# 变量
#######################################
LOG_FILE="/tmp/mysql_backup_$(date +%Y%m%d%H%M%S).log"
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

#######################################
# 安装Xtrabackup
#######################################
install_xtrabackup() {
    log_info "Installing Xtrabackup..."

    if command -v xtrabackup &>/dev/null; then
        log_info "Xtrabackup already installed"
        return 0
    fi

    # 检测系统
    if [[ -f /etc/redhat-release ]]; then
        # RHEL/CentOS
        local os_version
        os_version=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)

        cat > /etc/yum.repos.d/percona.repo << 'EOF'
[percona-stable]
name=Percona Stable
baseurl=https://repo.percona.com/yum/release/$(os_version)/os/x86_64/
gpgkey=https://repo.percona.com/yum/RPM-GPG-KEY-Percona
gpgcheck=1
enabled=1
EOF

        yum install -y percona-xtrabackup-80 2>/dev/null || \
        yum install -y xtrabackup 2>/dev/null || true
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y percona-xtrabackup-80 2>/dev/null || true
    fi

    if command -v xtrabackup &>/dev/null; then
        log_info "Xtrabackup installed successfully"
    else
        log_warn "Xtrabackup installation may have failed"
    fi
}

#######################################
# 创建备份用户
#######################################
create_backup_user() {
    log_info "Creating backup user..."

    "${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" << EOF
CREATE USER IF NOT EXISTS '${MYSQL_BACKUP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${MYSQL_BACKUP_USER}'@'localhost';
CREATE USER IF NOT EXISTS '${MYSQL_BACKUP_USER}'@'%' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${MYSQL_BACKUP_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    log_info "Backup user created"
}

#######################################
# 备份函数
#######################################
do_backup() {
    log_info "Starting backup..."

    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"
    local start_time=$(date +%Y%m%d_%H%M%S)

    # 创建备份目录
    mkdir -p "$backup_dir"
    mkdir -p "${backup_dir}/binlog"
    mkdir -p "${backup_dir}/tmp"

    # 检查MySQL连接
    if ! "${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -e "SELECT 1" &>/dev/null; then
        log_error "Cannot connect to MySQL"
        return 1
    fi

    # 获取数据目录
    local data_dir
    data_dir=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -NBe "SELECT @@datadir")
    log_info "Data directory: $data_dir"

    # 检查是否需要备份(非从库或主库)
    local is_slave
    is_slave=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -NBe "SELECT @@log_slave_updates")

    # 检查nobackup文件
    if [[ -f "${data_dir}/nobackup" ]]; then
        log_info "This instance is marked as nobackup, skipping..."
        return 0
    fi

    # 执行备份
    log_info "Running xtrabackup backup..."

    xtrabackup \
        --defaults-file="${MYSQL_DATA_DIR_BASE}/config/my.cnf" \
        --user="${MYSQL_BACKUP_USER}" \
        --password="${MYSQL_BACKUP_PASSWORD}" \
        --host=127.0.0.1 \
        --port="${MYSQL_PORT}" \
        --backup \
        --target-dir="${backup_dir}/${start_time}" \
        --compress \
        --stream=xbstream \
        --parallel="${PARALLEL}" \
        --compress-threads="${COMPRESS_THREADS}" \
        --ftwrl-wait-timeout=120 \
        --ftwrl-wait-threshold=120 \
        --ftwrl-wait-query-type=all \
        2>&1 | tee -a "${backup_dir}/detail.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Backup failed"
        return 1
    fi

    log_info "Backup completed: ${start_time}"
    return 0
}

#######################################
# 备份Binlog
#######################################
do_backup_binlog() {
    log_info "Starting binlog backup..."

    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"
    local binlog_dir="${backup_dir}/binlog"

    # 获取binlog信息
    local binlog_index
    binlog_index=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -NBe "SELECT @@log_bin_basename")

    local binlog_basename
    binlog_basename=$(echo "$binlog_index" | xargs dirname)

    # flush logs
    "${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -e "FLUSH BINARY LOGS" 2>/dev/null || true

    log_info "Binlog backup completed"
}

#######################################
# 备份配置文件
#######################################
do_backup_cnf() {
    log_info "Starting config file backup..."

    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"
    local start_time=$(date +%Y%m%d_%H%M%S)
    local my_cnf="${MYSQL_DATA_DIR_BASE}/config/my.cnf"

    if [[ -f "$my_cnf" ]]; then
        cp "$my_cnf" "${backup_dir}/${start_time}.cnf"
        log_info "Config file backup completed"
    fi
}

#######################################
# 清理旧备份
#######################################
purge_old_backups() {
    log_info "Purging old backups..."

    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"

    # 保留最近KEEP_BACKUP_COUNT份
    local backup_count=$(ls -1 "$backup_dir"/*.xbstream 2>/dev/null | wc -l)

    if [[ $backup_count -gt $KEEP_BACKUP_COUNT ]]; then
        local to_delete=$(ls -1rt "$backup_dir"/*.xbstream 2>/dev/null | head -$((backup_count - KEEP_BACKUP_COUNT)))

        for old_backup in $to_delete; do
            rm -f "$old_backup"
            log_info "Deleted old backup: $(basename $old_backup)"
        done
    fi

    # 清理过期binlog
    find "${backup_dir}/binlog" -type f -mtime +${EXPIRE_BINLOG_DAYS} -exec rm -f {} \;

    log_info "Purge completed"
}

#######################################
# 恢复函数
#######################################
do_restore() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        log_error "Please specify backup file to restore"
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    log_info "Starting restore from: $backup_file"

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local backup_dir=$(dirname "$backup_file")
    local restore_dir="${backup_dir}/restore_temp"

    # 准备目录
    mkdir -p "$restore_dir"

    # 解压
    log_info "Decompressing backup..."
    xbstream -x -C "$restore_dir" < "$backup_file" 2>&1 | tee -a "$LOG_FILE"

    # 解压压缩页
    if compfind "$restore_dir" -name "*.qp" 2>/dev/null; then
        log_info "Decompressing pages..."
        for qp_file in $(find "$restore_dir" -name "*.qp"); do
            qpress -d "$qp_file" 2>/dev/null || \
            parallel compression=uncompress qpress -d "$qp_file" 2>/dev/null || true
        done
    fi

    # 准备恢复
    log_info "Preparing restore..."
    xtrabackup --prepare --target-dir="$restore_dir" 2>&1 | tee -a "$LOG_FILE"

    # 停止MySQL
    log_info "Stopping MySQL..."
    systemctl stop mysql${MYSQL_PORT} 2>/dev/null || \
    pkill mysqld 2>/dev/null || true

    # 清空数据目录
    rm -rf "${datadir:?}"/*
    mkdir -p "$datadir"

    # 复制数据
    log_info "Copying data..."
    xtrabackup --copy-back --target-dir="$restore_dir" \
        --datadir="$datadir" 2>&1 | tee -a "$LOG_FILE"

    # 设置权限
    chown -R mysql:mysql "$datadir"

    # 清理临时目录
    rm -rf "$restore_dir"

    # 启动MySQL
    log_info "Starting MySQL..."
    systemctl start mysql${MYSQL_PORT} 2>/dev/null || \
    "${MYSQL_SOFTWARE_DIR}/bin/mysqld_safe --user=mysql &"

    log_info "Restore completed"
}

#######################################
# 列出备份
#######################################
list_backups() {
    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"

    log_info "Available backups in $backup_dir:"

    if [[ -d "$backup_dir" ]]; then
        ls -lhS "$backup_dir"/*.xbstream 2>/dev/null || \
        echo "No backups found"
    else
        echo "Backup directory does not exist"
    fi
}

#######################################
# 创建定时任务
#######################################
setup_cron() {
    log_info "Setting up cron job..."

    # 创建备份脚本
    cat > /usr/local/bin/mysql_backup.sh << 'BACKUP_SCRIPT'
#!/bin/bash

BACKUP_DIR_BASE="/database/mysql/backup"
MYSQL_PORT="{{mysql_port}}"

# 加载配置
source /etc/profile.d/mysql.sh 2>/dev/null || true

# 运行备份
backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"
start_time=$(date +%Y%m%d_%H%M%S)

mkdir -p "$backup_dir"

xtrabackup \
    --defaults-file="/database/mysql/config/my.cnf" \
    --user=backup \
    --password=Backup@8888 \
    --host=127.0.0.1 \
    --port=${MYSQL_PORT} \
    --backup \
    --target-dir="${backup_dir}/${start_time}" \
    --compress \
    --stream=xbstream \
    --parallel=4 \
    --compress-threads=2 \
    >"${backup_dir}/${start_time}.xbstream" 2>&1

# 清理旧备份
backup_count=$(ls -1 "$backup_dir"/*.xbstream 2>/dev/null | wc -l)
if [[ $backup_count -gt 2 ]]; then
    to_delete=$(ls -1rt "$backup_dir"/*.xbstream 2>/dev/null | head -$((backup_count - 2)))
    rm -f $to_delete
fi
BACKUP_SCRIPT

    chmod +x /usr/local/bin/mysql_backup.sh

    # 添加crontab
    (crontab -l 2>/dev/null | grep -v "mysql_backup.sh"; echo "${CRON_SCHEDULE} /usr/local/bin/mysql_backup.sh >> /var/log/mysql_backup.log 2>&1") | crontab -

    log_info "Cron job set up"
}

#######################################
# 显示使用帮助
#######################################
show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

MySQL Backup and Restore Script

COMMANDS:
    backup           Run full backup
    restore FILE    Restore from backup file
    list           List available backups
    install        Install Xtrabackup
    cron           Set up scheduled backup

OPTIONS:
    -h, --help          Show this help
    -p, --port PORT    MySQL port (default: $MYSQL_PORT)
    -d, --dir DIR      Backup directory (default: $BACKUP_DIR_BASE)

EXAMPLES:
    $0 backup
    $0 restore /database/mysql/backup/3306/20240401_020000.xbstream
    $0 list
    $0 install
    $0 cron

EOF
}

#######################################
# 主函数
#######################################
main() {
    local command="${1:-}"

    case "$command" in
        backup)
            log_info "Running backup..."
            do_backup
            do_backup_binlog
            do_backup_cnf
            purge_old_backups
            log_info "Backup completed"
            ;;
        restore)
            shift
            do_restore "$1"
            ;;
        list)
            list_backups
            ;;
        install)
            install_xtrabackup
            create_backup_user
            ;;
        cron)
            setup_cron
            ;;
        -h|--help|help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"