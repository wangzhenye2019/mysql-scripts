#!/usr/bin/env bash
# Orchestrator PreFailoverProcesses hook. Nonzero exits abort recovery.
set -euo pipefail

readonly CONFIG_FILE="/etc/mysql57-ha.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=../../lib/common_debian.sh
source "${SCRIPT_DIR}/../../lib/common_debian.sh"

load_secure_env "$CONFIG_FILE"
: "${ORC_FAILED_HOST:?Orchestrator did not provide ORC_FAILED_HOST}"
: "${VIP_FENCING_COMMAND:?VIP_FENCING_COMMAND is required}"

# Fencing MUST be an authoritative operation: e.g. hypervisor power-off, PDU
# power cut, security-group isolation, or a storage/network fence. A successful
# SSH command is not sufficient evidence that a partitioned primary cannot write.
log_warn "Starting authoritative fence for failed primary: ${ORC_FAILED_HOST}:${ORC_FAILED_PORT:-3306}"
"$VIP_FENCING_COMMAND" "$ORC_FAILED_HOST" "${ORC_FAILED_PORT:-3306}"
log_info "Fencing completed for ${ORC_FAILED_HOST}; Orchestrator may continue promotion."
