#!/usr/bin/env bash
# Bootstrap a self-contained MySQL Router instance from InnoDB Cluster metadata.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common_debian.sh
source "${SCRIPT_DIR}/../lib/common_debian.sh"

usage() {
    cat <<'EOF'
Usage: 04_bootstrap_router.sh --config FILE [--rebootstrap]

The script intentionally prompts for the existing InnoDB Cluster administrator
password. MySQL Router does not accept this password as a command-line option;
keeping it out of argv and shell history is required. Bootstrap creates a
Router-specific metadata account with a generated password.
EOF
}

CONFIG_FILE=""
REBOOTSTRAP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="${2:?missing config file}"; shift 2 ;;
        --rebootstrap) REBOOTSTRAP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "$CONFIG_FILE" ]] || { usage >&2; exit 1; }
load_secure_env "$CONFIG_FILE"
validate_config_keys "$CONFIG_FILE" MYSQL84_ROUTER_BOOTSTRAP_INSTANCE MYSQL84_ADMIN_USER MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY MYSQL84_ROUTER_SERVICE_NAME MYSQL84_ROUTER_RW_PORT MYSQL84_ROUTER_RO_PORT
assert_debian12
require_root
require_command mysqlrouter
assert_port "$MYSQL84_ROUTER_RW_PORT" || die "Invalid MYSQL84_ROUTER_RW_PORT"
assert_port "$MYSQL84_ROUTER_RO_PORT" || die "Invalid MYSQL84_ROUTER_RO_PORT"
(( MYSQL84_ROUTER_RO_PORT == MYSQL84_ROUTER_RW_PORT + 1 )) || die "Router RO port must be RW port + 1 when using --conf-base-port."
assert_safe_directory "$MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY" "/etc/mysqlrouter"

getent passwd mysqlrouter >/dev/null || useradd --system --home /nonexistent --shell /usr/sbin/nologin mysqlrouter
config_file="${MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY}/mysqlrouter.conf"
if [[ -f "$config_file" && "$REBOOTSTRAP" != true ]]; then
    die "Router config already exists at ${config_file}; use --rebootstrap only after confirming metadata/account rotation impact."
fi

install -d -m 0750 -o mysqlrouter -g mysqlrouter "$MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY"
read -r -s -p "Password for InnoDB Cluster administrator ${MYSQL84_ADMIN_USER}: " ROUTER_BOOTSTRAP_PASSWORD
echo >&2
[[ -n "$ROUTER_BOOTSTRAP_PASSWORD" ]] || die "Empty password."

# Password goes only to the controlled prompt stream; it is never placed in argv,
# environment, generated config, logs, or this repository.
printf '%s\n' "$ROUTER_BOOTSTRAP_PASSWORD" | mysqlrouter \
    --bootstrap "${MYSQL84_ADMIN_USER}@${MYSQL84_ROUTER_BOOTSTRAP_INSTANCE}" \
    --directory "$MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY" \
    --user mysqlrouter \
    --conf-base-port "$MYSQL84_ROUTER_RW_PORT" \
    --conf-use-gr-notifications
unset ROUTER_BOOTSTRAP_PASSWORD

[[ -r "$config_file" ]] || die "Bootstrap did not generate ${config_file}."
cat > "/etc/systemd/system/${MYSQL84_ROUTER_SERVICE_NAME}.service" <<EOF
[Unit]
Description=MySQL Router for InnoDB Cluster ${MYSQL84_CLUSTER_NAME:-cluster}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mysqlrouter
Group=mysqlrouter
ExecStart=/usr/bin/mysqlrouter --config ${config_file}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${MYSQL84_ROUTER_BOOTSTRAP_DIRECTORY}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$MYSQL84_ROUTER_SERVICE_NAME"
systemctl is-active --quiet "$MYSQL84_ROUTER_SERVICE_NAME" || die "Router service did not become active."

log_info "Router started. Direct application write connections to 127.0.0.1:${MYSQL84_ROUTER_RW_PORT}; read-only connections use 127.0.0.1:${MYSQL84_ROUTER_RO_PORT}."
