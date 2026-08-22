#!/usr/bin/env bash
# Orchestrator PostMasterFailoverProcesses hook.
set -euo pipefail

readonly CONFIG_FILE="/etc/mysql57-ha.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../../lib/common_debian.sh
source "${SCRIPT_DIR}/../../lib/common_debian.sh"

load_secure_env "$CONFIG_FILE"
: "${ORC_SUCCESSOR_HOST:?Orchestrator did not provide ORC_SUCCESSOR_HOST}"
: "${ORC_SUCCESSOR_PORT:?Orchestrator did not provide ORC_SUCCESSOR_PORT}"

"${SCRIPT_DIR}/vip_promote.sh" "$ORC_SUCCESSOR_HOST" "$ORC_SUCCESSOR_PORT" "${ORC_FAILED_HOST:-unknown}"
