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
MYSQL_VERSION="${MYSQL_VERSION:-8.4.6}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
DB_TYPE="${DB_TYPE:-mysql}"
MYSQL_USER="${MYSQL_USER:-mysql}"
MYSQL_GROUP="${MYSQL_GROUP:-mysql}"

# MySQL 凭据必须通过受限配置文件或环境变量提供，禁止在代码中使用默认密码。
MYSQL_ADMIN_USER="${MYSQL_ADMIN_USER:-admin}"
MYSQL_ADMIN_PASSWORD="${MYSQL_ADMIN_PASSWORD:-}"
MYSQL_BACKUP_USER="${MYSQL_BACKUP_USER:-backup}"
MYSQL_BACKUP_PASSWORD="${MYSQL_BACKUP_PASSWORD:-}"

# 目录配置
MYSQL_DATA_DIR_BASE="${MYSQL_DATA_DIR_BASE:-/database/${DB_TYPE}}"
MYSQL_SOFTWARE_DIR="${MYSQL_SOFTWARE_DIR:-/database/${DB_TYPE}/base/${MYSQL_VERSION}}"

# 备份配置
BACKUP_DIR_BASE="${MYSQL_DATA_DIR_BASE}/backup"
KEEP_BACKUP_COUNT=2                      # 保留最近2份全备
EXPIRE_BINLOG_DAYS=8                     # Binlog保留8天

# XtraBackup 配置：工具主版本必须与数据库创建版本匹配。
case "$MYSQL_VERSION" in
    8.4.*) XTRABACKUP_PACKAGE="${XTRABACKUP_PACKAGE:-percona-xtrabackup-84}" ;;
    8.0.*) XTRABACKUP_PACKAGE="${XTRABACKUP_PACKAGE:-percona-xtrabackup-80}" ;;
    5.7.*) XTRABACKUP_PACKAGE="${XTRABACKUP_PACKAGE:-percona-xtrabackup-24}" ;;
    *) XTRABACKUP_PACKAGE="${XTRABACKUP_PACKAGE:-}" ;;
esac
PARALLEL="${PARALLEL:-4}"
COMPRESS_THREADS="${COMPRESS_THREADS:-2}"

# 定时任务
CRON_SCHEDULE="0 2 * * *"               # 每天凌晨2点

#######################################
# 变量
#######################################
LOG_FILE="/tmp/mysql_backup_$(date +%Y%m%d%H%M%S).log"
SOCKET="${SOCKET:-/tmp/mysql.sock}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CONFIRM_RESTORE="${CONFIRM_RESTORE:-false}"
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

    [[ -n "$XTRABACKUP_PACKAGE" ]] || { log_error "Unsupported MySQL version for automatic XtraBackup package selection: $MYSQL_VERSION"; return 1; }

    # 检测系统
    if [[ -f /etc/redhat-release ]]; then
        # RHEL/CentOS
        local os_version
        os_version=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)

        cat > /etc/yum.repos.d/percona.repo << EOF
[percona-stable]
name=Percona Stable
baseurl=https://repo.percona.com/yum/release/${os_version}/os/x86_64/
gpgkey=https://repo.percona.com/yum/RPM-GPG-KEY-Percona
gpgcheck=1
enabled=1
EOF

        yum install -y "$XTRABACKUP_PACKAGE"
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y "$XTRABACKUP_PACKAGE"
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
    # 检查nobackup文件
    if [[ -f "${data_dir}/nobackup" ]]; then
        log_info "This instance is marked as nobackup, skipping..."
        return 0
    fi

    # --stream 的标准输出是二进制 xbstream；必须重定向到归档文件而不是日志。
    local archive="${backup_dir}/${start_time}.xbstream"
    local work_dir="${backup_dir}/tmp/${start_time}"
    mkdir -p "$work_dir"
    log_info "Running xtrabackup backup..."

    if ! xtrabackup \
        --defaults-file="${MYSQL_DATA_DIR_BASE}/config/my.cnf" \
        --user="${MYSQL_BACKUP_USER}" \
        --password="${MYSQL_BACKUP_PASSWORD}" \
        --host=127.0.0.1 \
        --port="${MYSQL_PORT}" \
        --backup \
        --target-dir="$work_dir" \
        --compress \
        --stream=xbstream \
        --parallel="${PARALLEL}" \
        --compress-threads="${COMPRESS_THREADS}" \
        --ftwrl-wait-timeout=120 \
        --ftwrl-wait-threshold=120 \
        --ftwrl-wait-query-type=all \
        > "$archive" 2> >(tee -a "${backup_dir}/detail.log" >&2); then
        rm -f "$archive"
        rm -rf "$work_dir"
        log_error "Backup failed"
        return 1
    fi

    rm -rf "$work_dir"
    [[ -s "$archive" ]] || { log_error "Backup archive is empty"; return 1; }
    sha256sum "$archive" > "${archive}.sha256"
    log_info "Backup completed: ${archive}"
    return 0
}

#######################################
# 备份Binlog
#######################################
do_backup_binlog() {
    log_info "Starting binlog backup..."

    local backup_dir="${BACKUP_DIR_BASE}/${MYSQL_PORT}"
    # 获取binlog信息
    local binlog_index
    binlog_index=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_BACKUP_USER}" -p"${MYSQL_BACKUP_PASSWORD}" -NBe "SELECT @@log_bin_basename")

    # XtraBackup 已在归档元数据中记录一致性位点；独立 binlog 归档需单独部署 mysqlbinlog 进程。
    log_info "Current binary log base: ${binlog_index}; no separate binlog archival is configured"
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

    # 保留最近 KEEP_BACKUP_COUNT 份归档；使用 NUL 分隔避免路径中的空格或通配符造成误删。
    local backups=()
    mapfile -d '' -t backups < <(find "$backup_dir" -maxdepth 1 -type f -name '*.xbstream' -printf '%T@ %p\0' | sort -z -n | sed -z 's/^[^ ]* //')
    local backup_count=${#backups[@]}

    if (( backup_count > KEEP_BACKUP_COUNT )); then
        local delete_count=$((backup_count - KEEP_BACKUP_COUNT))
        local old_backup
        for old_backup in "${backups[@]:0:delete_count}"; do
            rm -f -- "$old_backup"
            log_info "Deleted old backup: $(basename -- "$old_backup")"
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

    if [[ "$CONFIRM_RESTORE" != "true" ]]; then
        log_error "Restore is destructive. Re-run with: restore --yes /absolute/path/to/backup.xbstream"
        return 1
    fi

    if [[ -z "$backup_file" ]]; then
        log_error "Please specify backup file to restore"
        return 1
    fi

    [[ "$backup_file" = /* ]] || { log_error "Backup path must be absolute"; return 1; }

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if [[ -f "${backup_file}.sha256" ]] && ! (cd "$(dirname "$backup_file")" && sha256sum --check "$(basename "${backup_file}").sha256"); then
        log_error "Backup archive checksum verification failed"
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

    # XtraBackup 8.4 的 --compress 默认使用 ZSTD；由 xtrabackup 负责解压而非 qpress。
    if find "$restore_dir" -type f \( -name '*.zst' -o -name '*.lz4' \) -print -quit | grep -q .; then
        log_info "Decompressing backup files..."
        xtrabackup --decompress --remove-original --parallel="$PARALLEL" --target-dir="$restore_dir" 2>&1 | tee -a "$LOG_FILE"
    fi

    # 准备恢复
    log_info "Preparing restore..."
    xtrabackup --prepare --target-dir="$restore_dir" 2>&1 | tee -a "$LOG_FILE"

    # 停止目标实例。不能使用 pkill，避免影响同机其他实例。
    log_info "Stopping MySQL..."
    if systemctl is-active --quiet "mysql${MYSQL_PORT}"; then
        systemctl stop "mysql${MYSQL_PORT}" || { log_error "Unable to stop mysql${MYSQL_PORT}"; return 1; }
    fi

    # 清空目标数据目录前再次校验端口目录，防止错误配置导致误删。
    [[ "$datadir" == "${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}" ]] || { log_error "Unexpected datadir: $datadir"; return 1; }
    rm -rf -- "${datadir:?}"/*
    mkdir -p "$datadir"

    # 复制数据
    log_info "Copying data..."
    xtrabackup --copy-back --target-dir="$restore_dir" \
        --datadir="$datadir" 2>&1 | tee -a "$LOG_FILE"

    # 设置权限
    chown -R "$MYSQL_USER:$MYSQL_GROUP" "$datadir"

    # 清理临时目录
    rm -rf "$restore_dir"

    # 启动MySQL
    log_info "Starting MySQL..."
    systemctl start "mysql${MYSQL_PORT}"

    log_info "Restore completed; validate application consistency before reopening writes"
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
    local config_dir="/etc/mysql-scripts"
    local config_file="${config_dir}/backup-${MYSQL_PORT}.conf"
    local runner="/usr/local/bin/mysql_backup_${MYSQL_PORT}.sh"
    install -d -m 0700 "$config_dir"
    cat > "$config_file" << EOF
MYSQL_VERSION='${MYSQL_VERSION}'
MYSQL_PORT='${MYSQL_PORT}'
DB_TYPE='${DB_TYPE}'
MYSQL_DATA_DIR_BASE='${MYSQL_DATA_DIR_BASE}'
MYSQL_SOFTWARE_DIR='${MYSQL_SOFTWARE_DIR}'
MYSQL_ADMIN_USER='${MYSQL_ADMIN_USER}'
MYSQL_ADMIN_PASSWORD='${MYSQL_ADMIN_PASSWORD}'
MYSQL_BACKUP_USER='${MYSQL_BACKUP_USER}'
MYSQL_BACKUP_PASSWORD='${MYSQL_BACKUP_PASSWORD}'
BACKUP_DIR_BASE='${BACKUP_DIR_BASE}'
KEEP_BACKUP_COUNT='${KEEP_BACKUP_COUNT}'
EOF
    chmod 0600 "$config_file"

    cat > "$runner" << EOF
#!/usr/bin/env bash
set -euo pipefail
source '$config_file'
exec '$SCRIPT_PATH' backup
EOF
    chmod 0700 "$runner"

    # 添加 crontab，定时任务使用受限配置文件中的凭据。
    (crontab -l 2>/dev/null | grep -Fv "$runner"; echo "${CRON_SCHEDULE} $runner >> /var/log/mysql_backup_${MYSQL_PORT}.log 2>&1") | crontab -

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
    restore --yes FILE    Restore from backup file (destructive confirmation required)
    list           List available backups
    install        Install Xtrabackup
    cron           Set up scheduled backup

OPTIONS:
    -h, --help          Show this help
    -p, --port PORT    MySQL port (default: $MYSQL_PORT)
    -d, --dir DIR      Backup directory (default: $BACKUP_DIR_BASE)

EXAMPLES:
    $0 backup
    $0 restore --yes /database/mysql/backup/3306/20240401_020000.xbstream
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
            [[ -n "$MYSQL_ADMIN_PASSWORD" && -n "$MYSQL_BACKUP_PASSWORD" ]] || { log_error "Set MYSQL_ADMIN_PASSWORD and MYSQL_BACKUP_PASSWORD through a secure configuration file or environment"; return 1; }
            log_info "Running backup..."
            do_backup
            do_backup_binlog
            do_backup_cnf
            purge_old_backups
            log_info "Backup completed"
            ;;
        restore)
            shift
            if [[ "${1:-}" == "--yes" ]]; then
                CONFIRM_RESTORE=true
                shift
            fi
            do_restore "${1:-}"
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