#!/bin/bash
#############################################################################
# MySQL Self-Healing Monitor Script
# 故障自愈监控: 检测MySQL故障并自动恢复
# 支持: 自动重启、切换VIP、告警通知
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
MYSQL_USER="mysql"
MYSQL_GROUP="mysql"

# 目录配置
MYSQL_DATA_DIR_BASE="/database/${DB_TYPE}"
MYSQL_SOFTWARE_DIR="/database/${DB_TYPE}/base/${MYSQL_VERSION}"

# 监控配置
CHECK_INTERVAL=30                      # 检测间隔(秒)
CHECK_TIMEOUT=10                       # 检测超时(秒)
MAX_RESTART_ATTEMPTS=3                # 最大重启次数
RESTART_COOLDOWN=60                   # 重启冷却时间(秒)

# 告警配置
ENABLE_ALERT=true
ALERT_WEBHOOK=""                     # 企业微信/钉钉webhook
ALERT_PHONE=""                       # 告警手机号

# HA配置
ENABLE_HA_AUTO_SWITCH=false          # 是否启用自动切换VIP
VIRTUAL_IP=""                        # VIP地址

# 日志目录
LOG_DIR="/var/log/mysql_health"
MONITOR_LOG="${LOG_DIR}/monitor.log"
ALERT_LOG="${LOG_DIR}/alert.log"

#######################################
# 变量
#######################################
SOCKET="/tmp/mysql.sock"
LOCK_FILE="/var/run/mysql_health_monitor.lock"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#######################################
# 初始化
#######################################
init() {
    mkdir -p "$LOG_DIR"
    touch "$MONITOR_LOG"
    chown "$MYSQL_USER:$MYSQL_GROUP" "$LOG_DIR" "$MONITOR_LOG" 2>/dev/null || true
}

#######################################
# 日志函数
#######################################
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$MONITOR_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$MONITOR_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$MONITOR_LOG"
}

log_alert() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ALERT] $*" >> "$ALERT_LOG"
}

#######################################
# 发送告警
#######################################
send_alert() {
    local subject="$1"
    local message="$2"

    if [[ "$ENABLE_ALERT" != "true" ]]; then
        return 0
    fi

    log_alert "$subject: $message"

    # 企业微信/钉钉告警(如果配置了webhook)
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        curl -s -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"msgtype\": \"text\", \"text\": {\"content\": \"$subject\n$message\"}}" 2>/dev/null || true
    fi

    # 邮件告警(可选扩展)
    # mail -s "$subject" admin@example.com <<< "$message" 2>/dev/null || true
}

#######################################
# 检查MySQL进程
#######################################
check_process() {
    if pgrep -x mysqld > /dev/null; then
        return 0
    else
        return 1
    fi
}

#######################################
# 检查MySQL连接
#######################################
check_connection() {
    if timeout "$CHECK_TIMEOUT" \
        "${MYSQL_SOFTWARE_DIR}/bin/mysql" \
        -S"$SOCKET" \
        -u"${MYSQL_ADMIN_USER}" \
        -p"${MYSQL_ADMIN_PASSWORD}" \
        -e "SELECT 1" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

#######################################
# 检查MySQL端口
#######################################
check_port() {
    if netstat -tuln 2>/dev/null | grep -q ":${MYSQL_PORT} " || \
       ss -tuln 2>/dev/null | grep -q ":${MYSQL_PORT} "; then
        return 0
    else
        return 1
    fi
}

#######################################
# 检查复制状态
#######################################
check_replication() {
    local repl_status
    repl_status=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" \
        -S"$SOCKET" \
        -u"${MYSQL_ADMIN_USER}" \
        -p"${MYSQL_ADMIN_PASSWORD}" \
        -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    if [[ -z "$repl_status" ]]; then
        # 非复制模式,返回成功
        return 0
    fi

    local io_running sql_running
    io_running=$(echo "$repl_status" | grep "Slave_IO_Running:" | awk '{print $2}')
    sql_running=$(echo "$repl_status" | grep "Slave_SQL_Running:" | awk '{print $2}')

    if [[ "$io_running" == "Yes" ]] && [[ "$sql_running" == "Yes" ]]; then
        return 0
    else
        return 1
    fi
}

#######################################
# 检查查询响应时间
#######################################
check_query_time() {
    local start_time
    start_time=$(date +%s%3N)

    timeout "$CHECK_TIMEOUT" \
        "${MYSQL_SOFTWARE_DIR}/bin/mysql" \
        -S"$SOCKET" \
        -u"${MYSQL_ADMIN_USER}" \
        -p"${MYSQL_ADMIN_PASSWORD}" \
        -e "SELECT 1" &>/dev/null

    local end_time
    end_time=$(date +%s%3N)

    local query_time=$((end_time - start_time))

    # 查询时间超过5秒认为异常
    if [[ $query_time -gt 5000 ]]; then
        log_warn "Slow query detected: ${query_time}ms"
        return 1
    fi

    return 0
}

#######################################
# 检查InnoDB状态
#######################################
check_innodb() {
    local innodb_status
    innodb_status=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" \
        -S"$SOCKET" \
        -u"${MYSQL_ADMIN_USER}" \
        -p"${MYSQL_ADMIN_PASSWORD}" \
        -NBe "SHOW ENGINE INNODB STATUS" 2>/dev/null)

    if [[ -n "$innodb_status" ]]; then
        # 检查死锁
        if echo "$innodb_status" | grep -q "DEADLOCK"; then
            log_error "InnoDB deadlock detected!"
            send_alert "MySQL Deadlock" "InnoDB deadlock detected on port $MYSQL_PORT"
            return 1
        fi
    fi

    return 0
}

#######################################
# 重启MySQL
#######################################
restart_mysql() {
    log_info "Restarting MySQL..."

    local my_cnf="${MYSQL_DATA_DIR_BASE}/config/my.cnf"
    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"

    # 停止MySQL
    log_info "Stopping MySQL..."
    systemctl stop mysql${MYSQL_PORT} 2>/dev/null || true

    # 如果进程还存在,强制杀掉
    if pgrep -x mysqld > /dev/null; then
        pkill -9 mysqld 2>/dev/null || true
    fi

    # 等待进程退出
    sleep 3

    # 删除pid文件
    rm -f "${datadir}"/*.pid 2>/dev/null || true
    rm -f "$SOCKET" 2>/dev/null || true

    # 启动MySQL
    log_info "Starting MySQL..."
    systemctl start mysql${MYSQL_PORT} 2>/dev/null || \
    "${MYSQL_SOFTWARE_DIR}/bin/mysqld" \
        --defaults-file="$my_cnf" \
        --user="$MYSQL_USER" \
        --daemonize

    # 等待启动
    local i=0
    while [[ $i -lt 60 ]]; do
        if "${MYSQL_SOFTWARE_DIR}/bin/mysql" \
            -S"$SOCKET" \
            -u"${MYSQL_ADMIN_USER}" \
            -p"${MYSQL_ADMIN_PASSWORD}" \
            -e "SELECT 1" &>/dev/null; then
            log_info "MySQL restarted successfully"
            return 0
        fi
        sleep 1
        ((i++))
    done

    log_error "Failed to restart MySQL"
    return 1
}

#######################################
# 初始化MySQL
#######################################
initialize_mysql() {
    log_info "Initializing MySQL..."

    local my_cnf="${MYSQL_DATA_DIR_BASE}/config/my.cnf"
    local datadir="${MYSQL_DATA_DIR_BASE}/data/${MYSQL_PORT}"

    # 初始化
    "${MYSQL_SOFTWARE_DIR}/bin/mysqld" \
        --initialize-insecure \
        --user="$MYSQL_USER" \
        --basedir="$MYSQL_SOFTWARE_DIR" \
        --datadir="$datadir" \
        --defaults-file="$my_cnf" 2>&1 | tee -a "$MONITOR_LOG"

    chown -R "$MYSQL_USER:$MYSQL_GROUP" "$datadir"

    # 启动
    restart_mysql
}

#######################################
# 切换VIP
#######################################
switch_vip() {
    local new_master="$1"

    if [[ -z "$VIRTUAL_IP" ]] || [[ "$ENABLE_HA_AUTO_SWITCH" != "true" ]]; then
        return 0
    fi

    log_info "Switching VIP to $new_master..."

    # 检查VIP是否需要切换
    local current_vip_host
    current_vip_host=$(ip addr show | grep -w "$VIRTUAL_IP" | awk '{print $NF}' || echo "")

    if [[ -n "$current_vip_host" ]]; then
        # 释放VIP
        ip addr del "$VIRTUAL_IP/32" dev "$current_vip_host" 2>/dev/null || true
    fi

    # 在新主机上绑定VIP
    local new_interface
    new_interface=$(ssh -o StrictHostKeyChecking=no "$new_master" "ip link show" | grep -E "^[0-9]+:" | head -1 | cut -d: -f2 | tr -d ':')

    ssh -o StrictHostKeyChecking=no "$new_master" \
        "ip addr add ${VIRTUAL_IP}/24 dev $new_interface label ${new_interface}:vip" 2>/dev/null || true

    log_info "VIP switched to $new_master"
}

#######################################
# 健康检查主函数
#######################################
health_check() {
    local checks_passed=0
    local checks_failed=0

    # 检查1: 进程
    if check_process; then
        log_info "Check Process: PASS"
        ((checks_passed++))
    else
        log_error "Check Process: FAIL"
        ((checks_failed++))
    fi

    # 检查2: 端口
    if check_port; then
        log_info "Check Port: PASS"
        ((checks_passed++))
    else
        log_error "Check Port: FAIL"
        ((checks_failed++))
    fi

    # 检查3: 连接
    if check_connection; then
        log_info "Check Connection: PASS"
        ((checks_passed++))
    else
        log_error "Check Connection: FAIL"
        ((checks_failed++))
    fi

    # 检查4: 复制(如果存在)
    if check_replication; then
        log_info "Check Replication: PASS"
        ((checks_passed++))
    else
        log_error "Check Replication: FAIL"
        ((checks_failed++))
    fi

    # 检查5: InnoDB状态
    if check_innodb; then
        log_info "Check InnoDB: PASS"
        ((checks_passed++))
    else
        log_error "Check InnoDB: FAIL"
        ((checks_failed++))
    fi

    if [[ $checks_failed -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

#######################################
# 自愈主函数
#######################################
self_heal() {
    local attempts=0
    local healed=false

    while [[ $attempts -lt $MAX_RESTART_ATTEMPTS ]]; do
        ((attempts++))

        log_info "Self-healing attempt $attempts/$MAX_RESTART_ATTEMPTS..."

        # 如果进程不存在,尝试启动
        if ! check_process; then
            log_warn "MySQL process not running, attempting to start..."

            # 尝试启动
            if systemctl start mysql${MYSQL_PORT} &>/dev/null; then
                sleep 5
                if check_connection; then
                    log_info "MySQL auto-started successfully"
                    send_alert "MySQL Auto-Started" "MySQL on port $MYSQL_PORT was auto-started (attempt $attempts)"
                    healed=true
                    break
                fi
            fi
        fi

        # 如果进程存在但无法连接,尝试重启
        if check_process && ! check_connection; then
            log_warn "MySQL process running but not responding, attempting to restart..."

            if restart_mysql; then
                sleep 5
                if check_connection; then
                    log_info "MySQL auto-restarted successfully"
                    send_alert "MySQL Auto-Restarted" "MySQL on port $MYSQL_PORT was auto-restarted (attempt $attempts)"
                    healed=true
                    break
                fi
            fi
        fi

        # 等待冷却
        sleep $RESTART_COOLDOWN
    done

    if [[ "$healed" == "true" ]]; then
        return 0
    else
        log_error "Self-healing failed after $MAX_RESTART_ATTEMPTS attempts"
        send_alert "MySQL Self-Heal Failed" "MySQL on port $MYSQL_PORT failed to recover after $MAX_RESTART_ATTEMPTS attempts"
        return 1
    fi
}

#######################################
# 监控循环
#######################################
monitor_loop() {
    log_info "Starting health monitor..."
    log_info "Check interval: ${CHECK_INTERVAL}s"
    log_info "Max restart attempts: $MAX_RESTART_ATTEMPTS"

    # 防止重复运行
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE")

        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_error "Monitor already running (PID: $old_pid)"
            exit 1
        fi
    fi

    echo $$ > "$LOCK_FILE"

    local consecutive_failures=0

    while true; do
        if health_check; then
            log_info "Health check: OK"

            if [[ $consecutive_failures -gt 0 ]]; then
                log_info "MySQL recovered after $consecutive_failures failures"
                send_alert "MySQL Recovered" "MySQL on port $MYSQL_PORT has recovered"
                consecutive_failures=0
            fi
        else
            log_warn "Health check: FAILED"
            ((consecutive_failures++))

            # 连续失败3次才触发自愈
            if [[ $consecutive_failures -ge 3 ]]; then
                log_error "Health check failed $consecutive_failures times, starting self-healing..."
                send_alert "MySQL Health Check Failed" "MySQL on port $MYSQL_PORT health check failed, starting self-healing..."

                if self_heal; then
                    consecutive_failures=0
                else
                    # 自愈失败,继续监控
                    log_error "Self-healing failed, continuing monitoring..."
                fi
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

#######################################
# 运行状态检查
#######################################
run_check() {
    log_info "Running one-time health check..."

    if health_check; then
        log_info "Health check: ALL PASS"
        return 0
    else
        log_error "Health check: FAILED"
        return 1
    fi
}

#######################################
# 显示状态
#######################################
show_status() {
    echo "=== MySQL Health Status ==="
    echo ""

    # 进程
    if check_process; then
        echo -e "Process: ${GREEN}RUNNING${NC}"
    else
        echo -e "Process: ${RED}NOT RUNNING${NC}"
    fi

    # 连接
    if check_connection; then
        echo -e "Connection: ${GREEN}OK${NC}"
    else
        echo -e "Connection: ${RED}FAILED${NC}"
    fi

    # 端口
    if check_port; then
        echo -e "Port ${MYSQL_PORT}: ${GREEN}LISTENING${NC}"
    else
        echo -e "Port ${MYSQL_PORT}: ${RED}NOT LISTENING${NC}"
    fi

    # 版本
    if check_connection; then
        local version
        version=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT @@version")
        echo "Version: $version"

        local uptime
        uptime=$("${MYSQL_SOFTWARE_DIR}/bin/mysql" -S"$SOCKET" -u"${MYSQL_ADMIN_USER}" -p"${MYSQL_ADMIN_PASSWORD}" -NBe "SELECT FLOOR(@@uptime)/3600) as hours")
        echo "Uptime: ${uptime} hours"
    fi

    # 复制状态
    if check_replication; then
        echo -e "Replication: ${GREEN}OK${NC}"
    else
        echo -e "Replication: ${RED}FAILED${NC}"
    fi
}

#######################################
# 显示使用帮助
#######################################
show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

MySQL Self-Healing Monitor

COMMANDS:
    start           Start monitoring (daemon mode)
    stop            Stop monitoring
    status          Show MySQL status
    check           Run one-time health check
    heal            Force self-healing

OPTIONS:
    -h, --help          Show this help
    -i, --interval     Check interval (default: 30s)
    -t, --timeout      Check timeout (default: 10s)
    -a, --attempts     Max restart attempts (default: 3)
    --enable-alert     Enable alert notifications
    --vip VIP         Virtual IP for HA switch

EXAMPLES:
    $0 start
    $0 status
    $0 check
    $0 heal
    $0 start --interval 60 --vip 192.168.1.100

EOF
}

#######################################
# 主函数
#######################################
main() {
    local command="${1:-}"

    init

    case "$command" in
        start)
            log_info "Starting MySQL health monitor..."
            monitor_loop
            ;;
        stop)
            log_info "Stopping MySQL health monitor..."
            if [[ -f "$LOCK_FILE" ]]; then
                kill $(cat "$LOCK_FILE") 2>/dev/null || true
                rm -f "$LOCK_FILE"
            fi
            log_info "Monitor stopped"
            ;;
        status)
            show_status
            ;;
        check)
            run_check
            ;;
        heal)
            self_heal
            ;;
        -h|--help|help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            # 解析选项
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -i|--interval)
                        CHECK_INTERVAL="$2"
                        shift 2
                        ;;
                    -t|--timeout)
                        CHECK_TIMEOUT="$2"
                        shift 2
                        ;;
                    -a|--attempts)
                        MAX_RESTART_ATTEMPTS="$2"
                        shift 2
                        ;;
                    --enable-alert)
                        ENABLE_ALERT=true
                        shift
                        ;;
                    --vip)
                        VIRTUAL_IP="$2"
                        ENABLE_HA_AUTO_SWITCH=true
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            # 默认执行状态检查
            show_status
            ;;
    esac
}

main "$@"