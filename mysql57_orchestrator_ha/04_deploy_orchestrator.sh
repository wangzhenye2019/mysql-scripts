#!/usr/bin/env bash
# 部署 Orchestrator 控制平面和用于 fencing/VIP 的恢复 Hook。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 04_deploy_orchestrator.sh --config FILE --orchestrator-deb FILE --sha256 HEX [--discover HOST:PORT]

The package SHA-256 is mandatory. This script configures recovery hooks but does
not silently enable automatic master recovery until discovery and failover drills
have been validated by an operator.
EOF
}

CONFIG_FILE=""
ORCHESTRATOR_DEB=""
ORCHESTRATOR_SHA256=""
DISCOVER_INSTANCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --orchestrator-deb) ORCHESTRATOR_DEB="${2:?missing deb path}"; shift 2 ;;
        --sha256) ORCHESTRATOR_SHA256="${2:?missing package sha256}"; shift 2 ;;
        --discover) DISCOVER_INSTANCE="${2:?missing host:port}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && -n "$ORCHESTRATOR_DEB" && -n "$ORCHESTRATOR_SHA256" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL57_PORT MYSQL_ADMIN_USER MYSQL_ADMIN_PASSWORD ORCHESTRATOR_TOPOLOGY_USER ORCHESTRATOR_TOPOLOGY_PASSWORD VIP_FENCING_COMMAND WRITE_VIP VIP_CIDR VIP_INTERFACE
ensure_secret ORCHESTRATOR_TOPOLOGY_PASSWORD
assert_debian12
require_root
[[ -f "$ORCHESTRATOR_DEB" ]] || die "Orchestrator package not found: ${ORCHESTRATOR_DEB}"
[[ "$ORCHESTRATOR_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Expected a 64-character SHA-256 value."
echo "${ORCHESTRATOR_SHA256}  ${ORCHESTRATOR_DEB}" | sha256sum --check --status || die "Orchestrator package checksum verification failed."

apt-get update
apt-get install -y ca-certificates curl jq openssh-client arping
DEBIAN_FRONTEND=noninteractive apt-get install -y "$ORCHESTRATOR_DEB"
require_command orchestrator
require_command orchestrator-client

CONFIG_DIR="/etc/orchestrator"
HOOK_DIR="/usr/local/lib/mysql57-ha"
ORC_CONFIG="${CONFIG_DIR}/orchestrator.conf.json"
install -d -m 0750 "$CONFIG_DIR" "$HOOK_DIR"

# 将管理员凭据置于权限受控 JSON 中；生产环境可替换为密钥代理或短期令牌。
cat > "$ORC_CONFIG" <<EOF
{
  "Debug": false,
  "ListenAddress": ":3000",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",
  "MySQLTopologyUser": "${ORCHESTRATOR_TOPOLOGY_USER}",
  "MySQLTopologyPassword": "${ORCHESTRATOR_TOPOLOGY_PASSWORD}",
  "DiscoverByShowSlaveHosts": true,
  "InstancePollSeconds": 2,
  "RecoveryPeriodBlockSeconds": 300,
  "RecoverMasterClusterFilters": [],
  "RecoverIntermediateMasterClusterFilters": ["*"],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  "FailMasterPromotionIfSQLThreadNotUpToDate": true,
  "DelayMasterPromotionIfSQLThreadNotUpToDate": false,
  "DetachLostReplicasAfterMasterFailover": true,
  "PreFailoverProcesses": [
    "${HOOK_DIR}/pre_failover_fence.sh"
  ],
  "PostMasterFailoverProcesses": [
    "${HOOK_DIR}/post_master_failover_vip.sh"
  ],
  "PostUnsuccessfulFailoverProcesses": [
    "logger -t mysql57-orchestrator 'Recovery unsuccessful: {failureType} {failureCluster}'"
  ]
}
EOF
chmod 0640 "$ORC_CONFIG"
chown root:orchestrator "$ORC_CONFIG" 2>/dev/null || chown root:root "$ORC_CONFIG"

install -m 0750 "${SCRIPT_DIR}/hooks/pre_failover_fence.sh" "${HOOK_DIR}/pre_failover_fence.sh"
install -m 0750 "${SCRIPT_DIR}/hooks/post_master_failover_vip.sh" "${HOOK_DIR}/post_master_failover_vip.sh"
install -m 0750 "${SCRIPT_DIR}/hooks/vip_promote.sh" "${HOOK_DIR}/vip_promote.sh"
install -m 0750 "$CONFIG_FILE" /etc/mysql57-ha.env

systemctl enable --now orchestrator
if [[ -n "$DISCOVER_INSTANCE" ]]; then
    orchestrator-client -c discover -i "$DISCOVER_INSTANCE"
    log_info "Discovered MySQL topology starting at ${DISCOVER_INSTANCE}."
fi

cat <<'EOF'
Automatic master recovery remains disabled because RecoverMasterClusterFilters is
empty. After passing all fencing, GTID and network-partition drills, restrict the
filter to the intended cluster alias and explicitly enable recovery.
EOF
