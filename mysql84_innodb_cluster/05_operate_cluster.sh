#!/usr/bin/env bash
# InnoDB Cluster 生命周期运维入口；所有改变均通过 AdminAPI。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage:
  05_operate_cluster.sh --config FILE --status
  05_operate_cluster.sh --config FILE --rejoin HOST:PORT --apply
  05_operate_cluster.sh --config FILE --rotate-recovery-passwords --apply

Status is read-only. Rejoin and credential rotation require --apply. Bring all
members online before rotating recovery account passwords whenever possible.
EOF
}

CONFIG_FILE=""
OPERATION=""
TARGET_INSTANCE=""
APPLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --status) OPERATION="status"; shift ;;
        --rejoin) OPERATION="rejoin"; TARGET_INSTANCE="${2:?missing instance}"; shift 2 ;;
        --rotate-recovery-passwords) OPERATION="rotate-recovery-passwords"; shift ;;
        --apply) APPLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" && -n "$OPERATION" ]] || { usage >&2; exit 1; }
[[ "$OPERATION" == "status" || "$APPLY" == true ]] || die "--apply is required for ${OPERATION}."
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_CLUSTER_NAME MYSQL84_SEED_INSTANCE MYSQL84_ADMIN_USER MYSQL84_ADMIN_PASSWORD
require_command mysqlsh

if [[ -n "$TARGET_INSTANCE" ]]; then
    host="${TARGET_INSTANCE%:*}"; port="${TARGET_INSTANCE##*:}"
    [[ "$host" != "$TARGET_INSTANCE" ]] && assert_port "$port" || die "Invalid instance: ${TARGET_INSTANCE}"
fi
export IC_CLUSTER_NAME="$MYSQL84_CLUSTER_NAME"
export IC_SEED_INSTANCE="$MYSQL84_SEED_INSTANCE"
export IC_CLUSTER_ADMIN="$MYSQL84_ADMIN_USER"
export IC_CLUSTER_ADMIN_PASSWORD="$MYSQL84_ADMIN_PASSWORD"
export IC_OPERATION="$OPERATION"
export IC_TARGET_INSTANCE="$TARGET_INSTANCE"
mysqlsh --js --file "${SCRIPT_DIR}/operate_cluster.js"
