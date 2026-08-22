#!/usr/bin/env bash
# 使用 MySQL Shell AdminAPI 配置实例、创建单主 InnoDB Cluster 并加入成员。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 03_create_cluster.sh --config FILE --apply [--configure-instances]

--apply is mandatory because this operation changes MySQL configuration and
creates cluster metadata. --configure-instances additionally invokes
AdminAPI dba.configureInstance() on all nodes and can request restarts.
All nodes must have passed 02_preflight_instance.sh first.
EOF
}

CONFIG_FILE=""
APPLY=false
CONFIGURE_INSTANCES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --configure-instances) CONFIGURE_INSTANCES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && "$APPLY" == true ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_CLUSTER_NAME MYSQL84_SEED_INSTANCE MYSQL84_INSTANCES_CSV MYSQL84_SERVER_IDS_CSV MYSQL84_COMMUNICATION_STACK MYSQL84_SINGLE_PRIMARY MYSQL84_RECOVERY_METHOD MYSQL84_ROOT_USER MYSQL84_ROOT_PASSWORD MYSQL84_ADMIN_USER MYSQL84_ADMIN_PASSWORD
ensure_secret MYSQL84_ROOT_PASSWORD
ensure_secret MYSQL84_ADMIN_PASSWORD
require_command mysqlsh

IFS=',' read -r -a instances <<< "$MYSQL84_INSTANCES_CSV"
IFS=',' read -r -a server_ids <<< "$MYSQL84_SERVER_IDS_CSV"
(( ${#instances[@]} >= 3 )) || die "InnoDB Cluster requires at least 3 instances."
(( ${#instances[@]} == ${#server_ids[@]} )) || die "MYSQL84_INSTANCES_CSV and MYSQL84_SERVER_IDS_CSV must have equal counts."
[[ "${instances[0]}" == "$MYSQL84_SEED_INSTANCE" ]] || die "The first instance must match MYSQL84_SEED_INSTANCE."
for instance in "${instances[@]}"; do
    host="${instance%:*}"; port="${instance##*:}"
    [[ "$host" != "$instance" ]] && assert_port "$port" || die "Invalid instance endpoint: ${instance}"
done

export IC_CLUSTER_NAME="$MYSQL84_CLUSTER_NAME"
export IC_SEED_INSTANCE="$MYSQL84_SEED_INSTANCE"
export IC_INSTANCES_CSV="$MYSQL84_INSTANCES_CSV"
export IC_COMMUNICATION_STACK="$MYSQL84_COMMUNICATION_STACK"
export IC_SINGLE_PRIMARY="$MYSQL84_SINGLE_PRIMARY"
export IC_RECOVERY_METHOD="$MYSQL84_RECOVERY_METHOD"
export IC_ROOT_USER="$MYSQL84_ROOT_USER"
export IC_ROOT_PASSWORD="$MYSQL84_ROOT_PASSWORD"
export IC_CLUSTER_ADMIN="$MYSQL84_ADMIN_USER"
export IC_CLUSTER_ADMIN_PASSWORD="$MYSQL84_ADMIN_PASSWORD"
export IC_CONFIGURE_INSTANCES="$CONFIGURE_INSTANCES"

mysqlsh --js --file "${SCRIPT_DIR}/create_cluster.js"
