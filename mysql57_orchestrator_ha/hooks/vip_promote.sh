#!/usr/bin/env bash
# Usage: vip_promote.sh SUCCESSOR_HOST SUCCESSOR_PORT FAILED_HOST
set -euo pipefail

readonly CONFIG_FILE="/etc/mysql57-ha.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../../lib/common_debian.sh
source "${SCRIPT_DIR}/../../lib/common_debian.sh"

SUCCESSOR_HOST="${1:?missing successor host}"
SUCCESSOR_PORT="${2:?missing successor port}"
FAILED_HOST="${3:-unknown}"
load_secure_env "$CONFIG_FILE"
assert_ipv4 "$WRITE_VIP" || die "WRITE_VIP must be an IPv4 address."
[[ "$VIP_CIDR" =~ ^[0-9]+$ ]] && (( VIP_CIDR >= 1 && VIP_CIDR <= 32 )) || die "Invalid VIP_CIDR: $VIP_CIDR"
assert_port "$SUCCESSOR_PORT" || die "Invalid successor port: $SUCCESSOR_PORT"

REMOTE_ADMIN_CNF="/etc/mysql57-ha/admin.cnf"
# 已由 Orchestrator 完成候选提升。VIP 不负责提升数据库，仅在新主确实可写时发布。
read_state="$(remote_exec "$SUCCESSOR_HOST" "mysql --defaults-extra-file='${REMOTE_ADMIN_CNF}' --batch --skip-column-names -e \"SELECT @@global.read_only, @@global.super_read_only\"")" || die "Cannot inspect successor ${SUCCESSOR_HOST}"
[[ "$read_state" == $'0\t0' ]] || die "Successor ${SUCCESSOR_HOST} is not writable (read_only/super_read_only=${read_state}); refusing VIP move."

# 旧主应已由 pre_failover hook 作权威隔离。这里仅在新主绑定 VIP，避免网络分区下
# 对疑似仍可写的旧主执行不可靠的远程 SSH 操作。
remote_exec "$SUCCESSOR_HOST" "
ip addr add '${WRITE_VIP}/${VIP_CIDR}' dev '${VIP_INTERFACE}' 2>/dev/null || true
arping -U -I '${VIP_INTERFACE}' -c 5 '${WRITE_VIP}'
arping -A -I '${VIP_INTERFACE}' -c 5 '${WRITE_VIP}'
"
log_info "Published write VIP ${WRITE_VIP}/${VIP_CIDR} on ${SUCCESSOR_HOST}:${SUCCESSOR_PORT}; failed primary was ${FAILED_HOST}."
