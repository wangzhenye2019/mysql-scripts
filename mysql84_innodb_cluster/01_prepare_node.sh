#!/usr/bin/env bash
# Debian 12 上官方 MySQL 8.4 InnoDB Cluster 节点基线。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 01_prepare_node.sh --config FILE --instance HOST:PORT --server-id ID [--install-packages] [--restart]

Run once on every intended MySQL 8.4 cluster node. --install-packages assumes
the official MySQL APT repository has already been configured to the 8.4 LTS
series. This script will fail rather than accept a non-8.4 server.
EOF
}

CONFIG_FILE=""
INSTANCE=""
SERVER_ID=""
INSTALL_PACKAGES=false
RESTART=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --instance) INSTANCE="${2:?missing instance}"; shift 2 ;;
        --server-id) SERVER_ID="${2:?missing server id}"; shift 2 ;;
        --install-packages) INSTALL_PACKAGES=true; shift ;;
        --restart) RESTART=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && -n "$INSTANCE" && -n "$SERVER_ID" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_VERSION MYSQL84_PORT MYSQL84_X_PORT MYSQL84_GR_PORT MYSQL84_REQUIRE_SECURE_TRANSPORT MYSQL84_CA_FILE MYSQL84_CERT_FILE MYSQL84_KEY_FILE
assert_debian12
require_root
[[ "$MYSQL84_VERSION" == "8.4" ]] || die "This module requires MYSQL84_VERSION=8.4."
[[ "$SERVER_ID" =~ ^[1-9][0-9]*$ ]] && (( SERVER_ID <= 4294967295 )) || die "Invalid server-id: ${SERVER_ID}"

host="${INSTANCE%:*}"
port="${INSTANCE##*:}"
[[ "$host" != "$INSTANCE" ]] && assert_port "$port" || die "Instance must be HOST:PORT."
[[ "$port" == "$MYSQL84_PORT" ]] || die "Instance port must match MYSQL84_PORT (${MYSQL84_PORT})."

if [[ "$INSTALL_PACKAGES" == true ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server mysql-shell mysql-router
fi

require_command mysqld
require_command mysqlsh
require_command mysqlrouter
server_version="$(mysqld --version)"
[[ "$server_version" == *"8.4."* ]] || die "MySQL 8.4 server required; got: ${server_version}"
[[ "$(mysqlsh --version)" == *"8.4."* ]] || die "MySQL Shell 8.4 required."
[[ "$(mysqlrouter --version)" == *"8.4."* ]] || die "MySQL Router 8.4 required."

# AdminAPI owns Group Replication-specific configuration. This drop-in only
# supplies the common server prerequisites; do not manually START GROUP_REPLICATION.
install -d -m 0755 /etc/mysql/conf.d
cat > /etc/mysql/conf.d/99-innodb-cluster-baseline.cnf <<EOF
[mysqld]
server_id=${SERVER_ID}
report_host=${host}
port=${MYSQL84_PORT}
mysqlx_port=${MYSQL84_X_PORT}
log_bin=mysql-bin
binlog_format=ROW
log_replica_updates=ON
gtid_mode=ON
enforce_gtid_consistency=ON
transaction_write_set_extraction=XXHASH64
binlog_transaction_dependency_tracking=WRITESET
replica_preserve_commit_order=ON
require_secure_transport=${MYSQL84_REQUIRE_SECURE_TRANSPORT}
ssl_ca=${MYSQL84_CA_FILE}
ssl_cert=${MYSQL84_CERT_FILE}
ssl_key=${MYSQL84_KEY_FILE}
EOF
chmod 0644 /etc/mysql/conf.d/99-innodb-cluster-baseline.cnf

if [[ "$RESTART" == true ]]; then
    systemctl restart mysql
    systemctl is-active --quiet mysql || die "mysql service did not become active after restart."
fi

cat <<EOF
Prepared ${INSTANCE} with server_id=${SERVER_ID}. Next, run 02_preflight_instance.sh
and only then use AdminAPI to configure and add this instance to ${MYSQL84_CLUSTER_NAME}.
EOF
