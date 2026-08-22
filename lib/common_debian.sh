#!/usr/bin/env bash
# shellcheck shell=bash
# 公共安全函数。此文件只能由本仓库的版本专用模块 source，不可直接执行。

set -o pipefail

log_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info() { printf '%s [INFO] %s\n' "$(log_ts)" "$*" >&2; }
log_warn() { printf '%s [WARN] %s\n' "$(log_ts)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n' "$(log_ts)" "$*" >&2; }
die() { log_error "$*"; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "This operation must run as root."
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

assert_debian12() {
    [[ -r /etc/os-release ]] || die "Unable to identify operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID}" == "debian" && "${VERSION_ID}" == "12" ]] || \
        die "This module supports Debian 12 only; detected ${ID:-unknown} ${VERSION_ID:-unknown}."
}

assert_ipv4() {
    local ip="$1"
    local octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a _octets <<< "$ip"
    for octet in "${_octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

assert_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

assert_safe_directory() {
    local directory="$1"
    local expected_prefix="$2"
    [[ "$directory" == "${expected_prefix}" || "$directory" == "${expected_prefix}/"* ]] || \
        die "Unsafe directory '${directory}'; expected a path below '${expected_prefix}'."
}

load_secure_env() {
    local env_file="$1"
    [[ -f "$env_file" && -r "$env_file" ]] || die "Configuration file is not readable: ${env_file}"

    local owner mode
    owner="$(stat -c '%u' "$env_file")"
    mode="$(stat -c '%a' "$env_file")"
    (( owner == 0 || owner == EUID )) || die "Configuration file must be owned by root or the invoking user: ${env_file}"
    (( (8#$mode & 077) == 0 )) || die "Configuration file must have permissions 0600 or stricter: ${env_file}"

    # 配置文件为 Shell 赋值文件；严格校验其来源与权限后才加载。
    # shellcheck disable=SC1090
    source "$env_file"
}

ensure_secret() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "$value" ]] || die "Required secret is empty: ${name}"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "Secret contains line breaks: ${name}"
}

write_mysql_defaults_file() {
    local destination="$1"
    local user="$2"
    local password="$3"
    local host="${4:-127.0.0.1}"
    local port="${5:-3306}"

    umask 077
    install -d -m 0700 "$(dirname "$destination")"
    cat > "$destination" <<EOF
[client]
user=${user}
password=${password}
host=${host}
port=${port}
protocol=TCP
EOF
    chmod 0600 "$destination"
}

sql_escape() {
    local value="$1"
    printf '%s' "${value//\'/\'\'}"
}

mysql_exec() {
    local defaults_file="$1"
    local sql="$2"
    shift 2
    mysql --defaults-extra-file="$defaults_file" --batch --skip-column-names "$@" -e "$sql"
}

mysql_exec_file() {
    local defaults_file="$1"
    local sql_file="$2"
    shift 2
    mysql --defaults-extra-file="$defaults_file" "$@" < "$sql_file"
}

remote_exec() {
    local host="$1"
    shift
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$host" "$@"
}

remote_copy() {
    local source="$1"
    local destination="$2"
    scp -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$source" "$destination"
}

render_template() {
    local template="$1"
    local output="$2"
    envsubst < "$template" > "$output"
}

wait_for_mysql() {
    local defaults_file="$1"
    local timeout_seconds="${2:-60}"
    local elapsed=0

    while (( elapsed < timeout_seconds )); do
        if mysqladmin --defaults-extra-file="$defaults_file" ping --silent >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((++elapsed))
    done
    return 1
}

validate_config_keys() {
    local file="$1"
    shift
    local key
    for key in "$@"; do
        [[ -n "${!key:-}" ]] || die "Required configuration key is absent: ${key} (${file})"
    done
}
