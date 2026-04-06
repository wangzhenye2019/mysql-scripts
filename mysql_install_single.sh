#!/bin/bash
#############################################################################
# MySQL Single Node Installation Script
# 对应Ansible版本: mysql_ansible/playbooks/single_node.yml
# 支持版本: MySQL 5.7/8.0, GreatSQL, Percona
#############################################################################

set -euo pipefail

#######################################
# 配置参数 (可在配置文件中覆盖)
#######################################
MYSQL_VERSION="8.4.6"
MYSQL_PORT=3306
DB_TYPE="mysql"                           # mysql, percona, greatsql
SERVER_SPECS="auto"                       # auto, 4c8g, 8c16g 等

# 目录配置
MYSQL_PACKAGES_DIR="../downloads"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_USER="mysql"
MYSQL_GROUP="mysql"

# 密码配置
MYSQL_USER_PASSWORD="Dbops@9999"
MYSQL_ADMIN_USER="admin"
MYSQL_ADMIN_PASSWORD="Dbops@8888"

# MySQL配置参数
MYSQL_BINLOG_FORMAT="row"
MYSQL_INNODB_LOG_BUFFER_SIZE="64M"
MYSQL_INNODB_OPEN_FILES=65535
MYSQL_MAX_CONNECTIONS=1000
MYSQL_CHARACTER_SET_SERVER="utf8mb4"
MYSQL_TRANSACTION_ISOLATION="READ-COMMITTED"
MYSQL_DEFAULT_TIME_ZONE="+8:00"
USE_WRITE_SET=1

# 功能开关
FCS_AUTO_DOWNLOAD_MYSQL=true
FCS_CREATE_MYSQL_FAST_LOGIN=true

#######################################
# 内部变量
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/mysql_install_$(date +%Y%m%d%H%M%S).log"
SOCKET="/tmp/mysql.sock"
MYSQL_BASE_DIR="/usr/local/mysql"

# 颜色定义
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

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "[DEBUG] $*" | tee -a "$LOG_FILE"
    fi
}

#######################################
# 检查函数
#######################################
check_os() {
    log_info "Checking OS requirements..."
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS version"
        return 1
    fi

    . /etc/os-release
    if [[ "$ID" != "centos" && "$ID" != "rhel" && "$ID" != "rocky" && "$ID" != "alma" ]]; then
        log_warn "This script is designed for RHEL/CentOS/Rocky/Alma Linux"
    fi

    # 检查Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 is not installed"
        return 1
    fi

    log_info "OS check passed"
}

check_mysql_port() {
    log_info "Checking if MySQL port $MYSQL_PORT is in use..."
    if netstat -tuln 2>/dev/null | grep -q ":${MYSQL_PORT} " || ss -tuln 2>/dev/null | grep -q ":${MYSQL_PORT} "; then
        log_error "Port $MYSQL_PORT is already in use"
        return 1
    fi
    log_info "Port $MYSQL_PORT is available"
}

check_package_exists() {
    log_info "Checking if MySQL package exists..."
    local package_name="mysql-${MYSQL_VERSION}-${DB_TYPE}"

    case "$DB_TYPE" in
        mysql)
            package_name="mysql-${MYSQL_VERSION}"
            ;;
        percona)
            package_name="Percona-Server-${MYSQL_VERSION}"
            ;;
        greatsql)
            package_name="GreatSQL-${MYSQL_VERSION}"
            ;;
    esac

    local arch
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        arch="x86_64"
    elif [[ "$arch" == "aarch64" ]]; then
        arch="aarch64"
    fi

    PACKAGE_FILE="${package_name}-linux-glibc2.17-${arch}.tar.gz"

    if [[ -f "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" ]]; then
        log_info "Found package: $PACKAGE_FILE"
        return 0
    elif [[ "$FCS_AUTO_DOWNLOAD_MYSQL" == "true" ]]; then
        log_warn "Package not found, will download automatically"
        return 0
    else
        log_error "Package $PACKAGE_FILE not found and auto download is disabled"
        return 1
    fi
}

#######################################
# 系统准备
#######################################
prepare_system() {
    log_info "Preparing system environment..."

    # 创建mysql用户
    if ! id "$MYSQL_USER" &>/dev/null; then
        useradd -r -g "$MYSQL_GROUP" -s /sbin/nologin -d /nonexistent "$MYSQL_USER" 2>/dev/null || \
        useradd -r -g "$MYSQL_GROUP" -s /bin/false -d /nonexistent "$MYSQL_USER"
        echo "$MYSQL_USER:$MYSQL_USER_PASSWORD" | chpasswd
        log_info "User $MYSQL_USER created"
    fi

    # 创建目录
    mkdir -p "$MYSQL_SOFTWARE_DIR"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/backup"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/binlog"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/redolog"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/tmp"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/slowlog"
    mkdir -p "${MYSQL_DATA_DIR_BASE}/generallog"

    chown -R "$MYSQL_USER:$MYSQL_GROUP" "${MYSQL_DATA_DIR_BASE}"
    chown -R "$MYSQL_USER:$MYSQL_GROUP" "$MYSQL_SOFTWARE_DIR"

    # 安装依赖
    if command -v yum &>/dev/null; then
        yum install -y libaio libaio-devel libiberty libedit ncurses-compat-libs \
            libnuma libcrypt11 libssl11 libcrypto11 libuv1 2>/dev/null || \
        yum install -y libaio libaio-devel 2>/dev/null || true
    fi

    log_info "System preparation completed"
}

#######################################
# 安装MySQL
#######################################
install_mysql() {
    log_info "Installing MySQL $MYSQL_VERSION..."

    cd /tmp

    # 下载包(如需要)
    if [[ ! -f "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" ]]; then
        local download_url
        case "$DB_TYPE" in
            mysql)
                download_url="https://dev.mysql.com/get/Downloads/MySQL-${MYSQL_VERSION:0:3}/${PACKAGE_FILE}"
                ;;
            greatsql)
                download_url="https://product.greatdb.com/GreatSQL-${MYSQL_VERSION}/${PACKAGE_FILE}"
                ;;
            percona)
                download_url="https://www.percona.com/downloads/Percona-Server-${MYSQL_VERSION}/${PACKAGE_FILE}"
                ;;
        esac

        log_info "Downloading from $download_url"
        if [[ "$FCS_AUTO_DOWNLOAD_MYSQL" == "true" ]]; then
            mkdir -p "$MYSQL_PACKAGES_DIR"
            wget -O "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" "$download_url" --timeout=60 || \
            curl -L -o "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" "$download_url" --timeout=60 || true
        fi
    fi

    # 解压包
    if [[ -f "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" ]]; then
        tar -xzf "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" -C /tmp
        local extracted_dir
        extracted_dir=$(tar -tzf "${MYSQL_PACKAGES_DIR}/${PACKAGE_FILE}" | head -1 | cut -d/ -f1)

        if [[ -n "$extracted_dir" ]] && [[ -d "/tmp/$extracted_dir" ]]; then
            mv "/tmp/$extracted_dir"/* "$MYSQL_SOFTWARE_DIR/"
            rmdir "/tmp/$extracted_dir" 2>/dev/null || true
        fi
    elif [[ -d "$MYSQL_SOFTWARE_DIR/bin" ]]; then
        log_info "MySQL already installed at $MYSQL_SOFTWARE_DIR"
    else
        log_error "Cannot install MySQL, package not found"
        return 1
    fi

    chown -R "$MYSQL_USER:$MYSQL_GROUP" "$MYSQL_SOFTWARE_DIR"

    # 创建符号链接
    ln -sfn "$MYSQL_SOFTWARE_DIR" "$MYSQL_BASE_DIR"

    # 配置共享库
    echo "$MYSQL_SOFTWARE_DIR/lib" > /etc/ld.so.conf.d/mysql.conf
    ldconfig

    # 配置PATH
    if ! grep -q "$MYSQL_BASE_DIR/bin" /etc/profile; then
        echo "export PATH=$MYSQL_BASE_DIR/bin:\$PATH" >> /etc/profile
    fi
    if ! grep -q "$MYSQL_BASE_DIR/bin" ~/.bashrc 2>/dev/null; then
        echo "export PATH=$MYSQL_BASE_DIR/bin:\$PATH" >> ~/.bashrc
    fi

    log_info "MySQL installation completed"
}

#######################################
# 生成配置文件
#######################################
generate_my_cnf() {
    log_info "Generating MySQL configuration..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"
    mkdir -p "$my_cnf_dir"

    # 自动检测服务器规格
    local mem_total_gb=8
    local cpu_cores=4

    if [[ "$SERVER_SPECS" == "auto" ]]; then
        mem_total_gb=$(free -g | awk '/^Mem:/{print $2}')
        cpu_cores=$(nproc)
    else
        mem_total_gb=$(echo "$SERVER_SPECS" | sed 's/[^0-9]*\([0-9]*\)c\([0-9]*\)g/\2/')
        cpu_cores=$(echo "$SERVER_SPECS" | sed 's/[^0-9]*\([0-9]*\)c\([0-9]*\)g/\1/')
    fi

    local buffer_pool_size=$((mem_total_gb * 6 / 10 / 128 * 128))
    [[ $buffer_pool_size -lt 128 ]] && buffer_pool_size=128

    local innodb_log_buffer_size="64M"
    if [[ $mem_total_gb -lt 4 ]]; then
        innodb_log_buffer_size="16M"
    elif [[ $mem_total_gb -lt 8 ]]; then
        innodb_log_buffer_size="32M"
    fi

    cat > "${my_cnf_dir}/my.cnf" << EOF
[mysqld]
# Basic settings
user                                = ${MYSQL_USER}
basedir                             = ${MYSQL_SOFTWARE_DIR}
datadir                             = ${datadir}
tmpdir                              = ${MYSQL_DATA_DIR_BASE}/tmp
socket                              = ${SOCKET}
port                                = ${MYSQL_PORT}
server_id                           = 1
character_set_server                  = ${MYSQL_CHARACTER_SET_SERVER}
pid_file                           = ${datadir}/mysqld.pid

# Connection settings
max_connections                     = ${MYSQL_MAX_CONNECTIONS}
max_connect_errors                = 1000000
max_allowed_packet                = 64M
thread_cache_size                 = ${cpu_cores:-4}

# Table settings
table_open_cache                  = 4000
table_definition_cache           = 2000
table_open_cache_instances       = 16

# Character set
collation_server                 = utf8mb4_unicode_ci
init_connect                    = 'SET NAMES utf8mb4'

# Logging
log_error                       = ${MYSQL_DATA_DIR_BASE}/error.log
slow_query_log                 = 1
slow_query_log_file            = ${MYSQL_DATA_DIR_BASE}/slowlog/slow.log
long_query_time                = 2
log_queries_not_using_indexes  = 0
general_log                    = 0
general_log_file               = ${MYSQL_DATA_DIR_BASE}/generallog/general.log

# Binlog settings
log_bin                        = ${MYSQL_DATA_DIR_BASE}/binlog/mysql-bin
binlog_format                  = ${MYSQL_BINLOG_FORMAT}
binlog_rows_query_log_events   = 1
log_slave_updates              = 1
sync_binlog                    = 1
binlog_cache_size              = 65536
binlog_checksum                = CRC32
expire_logs_days             = 7

# GTID settings
gtid_mode                      = ON
enforce_gtid_consistency       = ON
gtid_executed_compression_period = 1000

# Relay log
relay_log                      = ${MYSQL_DATA_DIR_BASE}/relaylog/relay-bin
relay_log_recovery           = 1
master_info_repository       = TABLE
relay_log_info_repository  = TABLE

# InnoDB settings
default_storage_engine         = InnoDB
innodb_data_file_path        = ibdata1:128M:autoextend
innodb_log_group_home_dir    = ${MYSQL_DATA_DIR_BASE}/redolog
innodb_file_per_table      = 1
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite       = 1
innodb_lock_wait_timeout = 50
innodb_io_capacity       = 200
innodb_io_capacity_max   = 2000
innodb_read_io_threads  = 4
innodb_write_io_threads = 4
innodb_buffer_pool_size = ${buffer_pool_size}M

# InnoDB buffer pool instances
innodb_buffer_pool_instances = $((buffer_pool_size / 1024))
[[ $innodb_buffer_pool_instances -lt 1 ]] && innodb_buffer_pool_instances=1
[[ $innodb_buffer_pool_instances -gt 64 ]] && innodb_buffer_pool_instances=64

# Performance schema
performance_schema           = ON
performance_schema_consumer_events_statements_current = ON
performance_schema_consumer_events_statements_history = ON
performance_schema_consumer_events_transactions_current = ON
performance_schema_consumer_events_transactions_history = ON
performance_schema_consumer_events_waits_current = ON
performance_schema_consumer_events_waits_history = ON

# Misc settings
skip_name_resolve           = 1
autocommit                = 1
event_scheduler           = OFF
sql_require_primary_key  = ON
explicit_defaults_for_timestamp = ON

# Security
local_infile               = 0
secure_file_priv          = ${MYSQL_DATA_DIR_BASE}/tmp

# Admin
admin_address              = 127.0.0.1
admin_port                = $((MYSQL_PORT * 10 + 2))

[mysql]
default-character-set      = utf8mb4
no-auto-rehash
socket                    = ${SOCKET}

[client]
socket                    = ${SOCKET}
port                      = ${MYSQL_PORT}
EOF

    chown "$MYSQL_USER:$MYSQL_GROUP" "${my_cnf_dir}/my.cnf"
    chmod 644 "${my_cnf_dir}/my.cnf"

    log_info "Configuration generated: ${my_cnf_dir}/my.cnf"
}

#######################################
# 初始化MySQL数据目录
#######################################
initialize_datadir() {
    log_info "Initializing MySQL data directory..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"

    # 如果已有数据目录,跳过初始化
    if [[ -d "$datadir/mysql" ]]; then
        log_info "Data directory already initialized, skipping..."
        return 0
    fi

    # 初始化
    cd "$MYSQL_BASE_DIR"
    ./bin/mysqld --initialize-insecure \
        --user="$MYSQL_USER" \
        --basedir="$MYSQL_BASE_DIR" \
        --datadir="$datadir" \
        --defaults-file="${my_cnf_dir}/my.cnf" \
        2>&1 | tee -a "$LOG_FILE"

    chown -R "$MYSQL_USER:$MYSQL_GROUP" "$datadir"

    log_info "Data directory initialized"
}

#######################################
# 配置MySQL服务
#######################################
config_mysql_service() {
    log_info "Configuring MySQL service..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"

    # 创建systemd服务文件
    cat > /etc/systemd/system/mysql${MYSQL_PORT}.service << EOF
[Unit]
Description=MySQL Database Server
After=network.target

[Service]
Type=forking
User=${MYSQL_USER}
Group=${MYSQL_GROUP}
ExecStart=${MYSQL_BASE_DIR}/bin/mysqld --defaults-file=${my_cnf_dir}/my.cnf --user=${MYSQL_USER} --daemonize
ExecStop=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10

PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # 重载systemd
    systemctl daemon-reload

    # 开机自启
    systemctl enable mysql${MYSQL_PORT} 2>/dev/null || true

    log_info "MySQL service configured"
}

#######################################
# 启动MySQL
#######################################
start_mysql() {
    log_info "Starting MySQL..."

    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"
    local my_cnf_dir="${MYSQL_DATA_DIR_BASE}/config"

    # 启动MySQL
    if systemctl is-active mysql${MYSQL_PORT} &>/dev/null; then
        log_info "MySQL service already running"
    else
        "$MYSQL_BASE_DIR/bin/mysqld" \
            --defaults-file="${my_cnf_dir}/my.cnf" \
            --user="$MYSQL_USER" \
            --daemonize

        # 等待启动
        local i=0
        while [[ $i -lt 60 ]]; do
            if "$MYSQL_BASE_DIR/bin/mysql" -h127.0.0.1 -P$MYSQL_PORT -S"$SOCKET" -e "SELECT 1" &>/dev/null; then
                break
            fi
            sleep 1
            ((i++))
        done

        if [[ $i -ge 60 ]]; then
            log_error "MySQL failed to start within 60 seconds"
            return 1
        fi
    fi

    log_info "MySQL started successfully"
}

#######################################
# 安全配置
#######################################
secure_mysql() {
    log_info "Securing MySQL installation..."

    # 设置root密码
    "$MYSQL_BASE_DIR/bin/mysql" -S"$SOCKET" -uroot --skip-password << EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ADMIN_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test';
FLUSH PRIVILEGES;
EOF

    # 创建admin用户
    "$MYSQL_BASE_DIR/bin/mysql" -S"$SOCKET" -uroot -p"${MYSQL_ADMIN_PASSWORD}" << EOF
CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'%' IDENTIFIED BY '${MYSQL_ADMIN_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_ADMIN_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_ADMIN_USER}'@'localhost' IDENTIFIED BY '${MYSQL_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_ADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

    log_info "MySQL security configured"
}

#######################################
# 创建快速登录
#######################################
create_fast_login() {
    if [[ "$FCS_CREATE_MYSQL_FAST_LOGIN" != "true" ]]; then
        return 0
    fi

    log_info "Creating MySQL fast login configuration..."

    local login_file="${HOME}/.db${MYSQL_PORT}"

    cat > "$login_file" << EOF
[client]
host=127.0.0.1
port=${MYSQL_PORT}
user=${MYSQL_ADMIN_USER}
password=${MYSQL_ADMIN_PASSWORD}
socket=${SOCKET}
EOF

    chmod 600 "$login_file"

    # 添加别名
    if ! grep -q "alias mysql${MYSQL_PORT}=" ~/.bashrc 2>/dev/null; then
        echo "alias mysql${MYSQL_PORT}='mysql --defaults-file=$login_file'" >> ~/.bashrc
        echo "alias mysqldump${MYSQL_PORT}='mysqldump --defaults-file=$login_file'" >> ~/.bashrc
    fi

    log_info "Fast login configured: mysql${MYSQL_PORT} command available"
}

#######################################
# 验证安装
#######################################
verify_installation() {
    log_info "Verifying MySQL installation..."

    # 检查进程
    if ! pgrep -x mysqld > /dev/null; then
        log_error "MySQL process not running"
        return 1
    fi

    # 检查连接
    if ! "$MYSQL_BASE_DIR/bin/mysql" -h127.0.0.1 -P$MYSQL_PORT -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -e "SELECT 1" &>/dev/null; then
        log_error "Cannot connect to MySQL"
        return 1
    fi

    # 检查版本
    local version
    version=$("$MYSQL_BASE_DIR/bin/mysql" -h127.0.0.1 -P$MYSQL_PORT -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT @@version")
    log_info "MySQL version: $version"

    # 检查端口
    local port_check
    port_check=$("$MYSQL_BASE_DIR/bin/mysql" -h127.0.0.1 -P$MYSQL_PORT -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT @@port")
    log_info "MySQL port: $port_check"

    log_info "Installation verified successfully"
    return 0
}

#######################################
# 显示使用帮助
#######################################
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install MySQL single node

OPTIONS:
    -h, --help                  Show this help message
    -v, --version VERSION      MySQL version (default: $MYSQL_VERSION)
    -p, --port PORT          MySQL port (default: $MYSQL_PORT)
    -t, --type TYPE          DB type: mysql, percona, greatsql (default: $DB_TYPE)
    -s, --specs SPECS        Server specs: auto, 4c8g, 8c16g (default: $SERVER_SPECS)
    -c, --config FILE        Use config file
    -d, --debug             Enable debug output

EXAMPLES:
    $0 -v 8.0.32 -p 3306 -t mysql
    $0 -t greatsql -s 8c16g
    $0 -c /path/to/config.ini

EOF
}

#######################################
# 主函数
#######################################
main() {
    log_info "=========================================="
    log_info "MySQL Single Node Installation Started"
    log_info "=========================================="
    log_info "Version: $MYSQL_VERSION"
    log_info "Port: $MYSQL_PORT"
    log_info "Type: $DB_TYPE"
    log_info "Software Dir: $MYSQL_SOFTWARE_DIR"
    log_info "=========================================="

    # 前置检查
    check_os || exit 1
    check_mysql_port || exit 1
    check_package_exists || exit 1

    # 安装步骤
    prepare_system
    install_mysql
    generate_my_cnf
    initialize_datadir
    config_mysql_service
    start_mysql
    secure_mysql
    create_fast_login
    verify_installation

    log_info "=========================================="
    log_info "MySQL Installation Completed!"
    log_info "=========================================="
    log_info "Connection info:"
    log_info "  Host: 127.0.0.1"
    log_info "  Port: $MYSQL_PORT"
    log_info "  User: $MYSQL_ADMIN_USER"
    log_info "  Pass: $MYSQL_ADMIN_PASSWORD"
    log_info "  Socket: $SOCKET"
    log_info "=========================================="
    log_info "Log file: $LOG_FILE"
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            MYSQL_VERSION="$2"
            shift 2
            ;;
        -p|--port)
            MYSQL_PORT="$2"
            shift 2
            ;;
        -t|--type)
            DB_TYPE="$2"
            shift 2
            ;;
        -s|--specs)
            SERVER_SPECS="$2"
            shift 2
            ;;
        -c|--config)
            source "$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# 启动
main