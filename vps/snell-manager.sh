#!/usr/bin/env bash
# ==============================================================================
# Snell Server 统一管理脚本
# ------------------------------------------------------------------------------
# 作用：
#   - 安装、更新、配置、查询 Snell Server。
#   - 支持 v5 / v4 / 手动指定版本安装与更新。
#   - 兼容安全接管旧配置路径与旧 systemd 服务名。
#   - 保持中文输出、清晰菜单、状态表格和低侵入系统修改。
#
# 使用：
#   chmod +x snell-manager.sh
#   sudo ./snell-manager.sh
#   sudo ./snell-manager.sh install
# ==============================================================================

set +e
set -Euo pipefail

SCRIPT_VERSION="2026.05.17-r1"
SNELL_VERSION_DEFAULT="5.0.1"
SNELL_V4_VERSION="4.1.1"
SNELL_PORT_DEFAULT="16386"
SNELL_DNS_DEFAULT="1.1.1.1, 9.9.9.9"
SNELL_OBFS_HOST_DEFAULT="gateway.icloud.com"

SNELL_CONFIG_DIR="/etc/snell"
SNELL_CONFIG_FILE="${SNELL_CONFIG_DIR}/snell-server.conf"
OLD_SNELL_CONFIG_FILE="/etc/snell/config.conf"
OLD_SNELL_VERSION_FILE="/etc/snell/ver.txt"
SNELL_VERSION_FILE="${SNELL_CONFIG_DIR}/version.txt"
SNELL_BINARY_PATH="/usr/local/bin/snell-server"
SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"
OLD_SNELL_SERVICE_FILE="/etc/systemd/system/snell-server.service"
SNELL_SYSCTL_FILE="/etc/sysctl.d/99-snell-network.conf"

UI_COLOR_RESET=""
UI_COLOR_RED=""
UI_COLOR_GREEN=""
UI_COLOR_YELLOW=""
UI_COLOR_BLUE=""
UI_COLOR_CYAN=""
UI_COLOR_BOLD=""
UI_COLOR_DIM=""
UI_TITLE_WIDTH=60
UI_KV_LABEL_WIDTH=18

PKG_MANAGER=""
ARCH=""
UI_PROMPT_FD=0
PROMPT_FD=0
UI_PAUSE_ENABLED=false
UI_MENU_CONTEXT=false
COMMAND="menu"
LEGACY_LISTEN=""
LEGACY_PORT=""
LEGACY_PSK=""
LEGACY_IPV6="false"
LEGACY_DNS="${SNELL_DNS_DEFAULT}"
LEGACY_OBFS="off"
LEGACY_OBFS_HOST=""
LEGACY_TFO="false"
LEGACY_PROTOCOL_VERSION="5"
LEGACY_BINARY_VERSION="unknown"
LEGACY_SERVICE_STATE="inactive"
LEGACY_WAS_ACTIVE=false
UI_RETURN_TO_MENU=130
RETURN_TO_MENU="${UI_RETURN_TO_MENU}"

ui_init_colors() {
    UI_COLOR_RESET='\033[0m'
    UI_COLOR_RED='\033[31m'
    UI_COLOR_GREEN='\033[32m'
    UI_COLOR_YELLOW='\033[33m'
    UI_COLOR_BLUE='\033[34m'
    UI_COLOR_CYAN='\033[36m'
    UI_COLOR_BOLD='\033[1m'
    UI_COLOR_DIM='\033[2m'

    if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" || ! -t 1 ]]; then
        UI_COLOR_RESET=""
        UI_COLOR_RED=""
        UI_COLOR_GREEN=""
        UI_COLOR_YELLOW=""
        UI_COLOR_BLUE=""
        UI_COLOR_CYAN=""
        UI_COLOR_BOLD=""
        UI_COLOR_DIM=""
    fi

    if [[ "${FORCE_COLOR:-}" == "1" ]]; then
        UI_COLOR_RESET='\033[0m'
        UI_COLOR_RED='\033[31m'
        UI_COLOR_GREEN='\033[32m'
        UI_COLOR_YELLOW='\033[33m'
        UI_COLOR_BLUE='\033[34m'
        UI_COLOR_CYAN='\033[36m'
        UI_COLOR_BOLD='\033[1m'
        UI_COLOR_DIM='\033[2m'
    fi
}

ui_init_prompt_input() {
    if [[ -r /dev/tty ]] && { exec 3</dev/tty; } 2>/dev/null; then
        UI_PROMPT_FD=3
    else
        UI_PROMPT_FD=0
    fi
    PROMPT_FD="${UI_PROMPT_FD}"
}

ui_info() { printf '%b\n' "${UI_COLOR_CYAN}[i]${UI_COLOR_RESET} $*"; }
ui_ok() { printf '%b\n' "${UI_COLOR_GREEN}[OK]${UI_COLOR_RESET} $*"; }
ui_warn() { printf '%b\n' "${UI_COLOR_YELLOW}[WARN]${UI_COLOR_RESET} $*" >&2; }
ui_error() { printf '%b\n' "${UI_COLOR_RED}[ERROR]${UI_COLOR_RESET} $*" >&2; }
ui_dim() { printf '%b\n' "${UI_COLOR_DIM}$*${UI_COLOR_RESET}"; }
ui_section() { printf '\n%b\n' "${UI_COLOR_BLUE}${UI_COLOR_BOLD}>>> $*${UI_COLOR_RESET}"; }
ui_print() { printf '%b\n' "$*"; }
ui_blank() { printf '\n'; }

ui_text_width() {
    local text="$1" width=0 i char byte
    local LC_ALL=C
    for ((i = 0; i < ${#text}; i++)); do
        char="${text:i:1}"
        printf -v byte '%d' "'${char}"
        ((byte < 0)) && byte=$((byte + 256))
        if ((byte < 128)); then
            ((width += 1))
        elif ((byte >= 192)); then
            ((width += 2))
        fi
    done
    printf '%s' "${width}"
}

ui_kv() {
    local label="$1" value="${2:-}" width padding
    width="$(ui_text_width "${label}")"
    padding=$((UI_KV_LABEL_WIDTH - width))
    ((padding < 1)) && padding=1
    printf '%s%*s%s\n' "${label}" "${padding}" "" "${value}"
}

ui_rule() {
    printf '%s\n' "------------------------------------------------------------"
}

ui_clear() {
    [[ -t 1 ]] && clear 2>/dev/null || true
}

ui_center_text() {
    local text="$1" width padding
    width="$(ui_text_width "${text}")"
    padding=$(((UI_TITLE_WIDTH - width) / 2))
    ((padding < 0)) && padding=0
    printf '%*s%s\n' "${padding}" "" "${text}"
}

ui_title() {
    local title="$1" version="${2:-}" border version_text=""
    border="$(printf '%*s' "${UI_TITLE_WIDTH}" '' | tr ' ' '=')"
    [[ -n "${version}" ]] && version_text="Version: ${version}"
    printf '%b' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}"
    printf '%s\n' "${border}"
    ui_center_text "${title}"
    [[ -n "${version_text}" ]] && ui_center_text "${version_text}"
    printf '%s\n' "${border}"
    printf '%b' "${UI_COLOR_RESET}"
}

ui_render_title() {
    [[ "${UI_MENU_CONTEXT}" == "true" ]] && ui_clear
    ui_title "Snell Server 统一管理脚本" "${SCRIPT_VERSION}"
}

ui_menu_item() {
    local number="$1" label="$2"
    printf ' %2s. %s\n' "${number}" "${label}"
}

ui_read_raw() {
    local __target="$1" __prompt="$2" __value
    if ! IFS= read -r -u "${UI_PROMPT_FD}" -p "${__prompt}" __value; then
        printf '\n' >&2
        ui_error "无法读取交互式输入。请在交互式终端运行脚本。"
        exit 1
    fi
    __value="${__value//$'\r'/}"
    printf -v "${__target}" '%s' "${__value}"
}

ui_is_cancel() {
    case "${1:-}" in
        q|Q) return 0 ;;
        *) return 1 ;;
    esac
}

ui_read_or_cancel() {
    local __target="$1" __prompt="$2"
    ui_read_raw "${__target}" "${__prompt}"
    if ui_is_cancel "${!__target}"; then
        return "${UI_RETURN_TO_MENU}"
    fi
}

ui_read_secret_or_cancel() {
    local __target="$1" __prompt="$2" __value
    if ! IFS= read -r -s -u "${UI_PROMPT_FD}" -p "${__prompt}" __value; then
        printf '\n' >&2
        ui_error "无法读取密钥输入。"
        exit 1
    fi
    printf '\n'
    __value="${__value//$'\r'/}"
    if ui_is_cancel "${__value}"; then
        return "${UI_RETURN_TO_MENU}"
    fi
    printf -v "${__target}" '%s' "${__value}"
}

ui_read_main_menu_choice() {
    local __target="$1"
    ui_read_raw "${__target}" "请输入选项编号（0 退出）： "
}

ui_read_submenu_choice() {
    local __target="$1"
    ui_read_raw "${__target}" "请输入选项编号（0 返回）： "
    if [[ "${!__target}" == "0" ]] || ui_is_cancel "${!__target}"; then
        return "${UI_RETURN_TO_MENU}"
    fi
}

ui_confirm() {
    local prompt="$1" default_answer="${2:-n}" answer label
    if [[ "${default_answer}" =~ ^[Yy]$ ]]; then
        label="Y/n"
        default_answer="y"
    else
        label="y/N"
        default_answer="n"
    fi

    while true; do
        ui_read_or_cancel answer "${prompt} [${label}，q 取消]: " || return "$?"
        answer="${answer:-${default_answer}}"
        case "${answer}" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) ui_error "请输入 y、n 或 q。" ;;
        esac
    done
}

ui_confirm_or_default() {
    local prompt="$1" default_answer="${2:-n}" noninteractive="${3:-false}"
    if [[ "${noninteractive}" == "true" ]]; then
        [[ "${default_answer}" =~ ^[Yy]$ ]]
        return
    fi
    ui_confirm "${prompt}" "${default_answer}"
}

ui_confirm_or_yes() {
    local prompt="$1" default_answer="${2:-n}" assume_yes="${3:-false}"
    if [[ "${assume_yes}" == "true" ]]; then
        return 0
    fi
    ui_confirm "${prompt}" "${default_answer}"
}

ui_confirm_token() {
    local prompt="$1" token="$2" answer
    ui_read_raw answer "${prompt} 输入 ${token} 继续： "
    ui_is_cancel "${answer}" && return "${UI_RETURN_TO_MENU}"
    [[ "${answer}" == "${token}" ]]
}

ui_pause() {
    local _
    [[ "${UI_PAUSE_ENABLED}" == "true" ]] || return 0
    printf '\n'
    ui_read_raw _ "按回车键继续..."
}

ui_run_menu_action() {
    local __action_name="$1" __rc=0 __previous_pause="${UI_PAUSE_ENABLED}"
    shift

    UI_PAUSE_ENABLED=true
    "$@" || __rc=$?
    UI_PAUSE_ENABLED="${__previous_pause}"
    case "${__rc}" in
        0) return 0 ;;
        "${UI_RETURN_TO_MENU}")
            ui_warn "${__action_name} 已取消，已返回上一级菜单。"
            return 0
            ;;
        *)
            ui_error "${__action_name} 执行失败，退出码：${__rc}。"
            ui_warn "脚本将保留在菜单中，请根据上方错误信息处理后重试。"
            return 0
            ;;
    esac
}

print_title() { ui_render_title; }
print_section() { ui_section "$@"; }
print_success() { ui_ok "$@"; }
print_warn() { ui_warn "$@"; }
print_error() { ui_error "$@"; }
print_info() { ui_info "$@"; }
print_dim() { ui_dim "$@"; }

is_cancel_input() {
    case "${1:-}" in
        q|Q) return 0 ;;
        *) return 1 ;;
    esac
}

is_back_input() {
    [ "${1:-}" = "0" ]
}

ui_input_hint() {
    ui_dim "普通输入：q 取消当前操作并返回上一级。"
}

ui_default_hint() {
    ui_dim "回车使用默认值，q 取消。"
}

ui_submenu_hint() {
    ui_dim "输入 0 返回上一级。"
}

ui_menu_footer() {
    echo
    ui_dim "主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。"
    ui_dim "普通输入：输入 q 取消当前操作。"
}

print_input_hint() { ui_input_hint; }
print_default_hint() { ui_default_hint; }
print_submenu_hint() { ui_submenu_hint; }
print_menu_footer() { ui_menu_footer; }

show_help() {
    cat <<'EOF'
Snell Server 统一管理脚本

用法：
  sudo bash snell-manager.sh [command]

Commands:
  install      安装 / 覆盖安装 Snell Server
  view         查看当前配置和客户端连接信息
  config       修改 Snell 配置
  update       更新 Snell Server，支持指定版本更新
  service      启动 / 停止 / 重启服务
  validate     运行服务验证
  status       查看服务状态和日志提示
  tune         应用 / 更新网络优化
  takeover     检测 / 接管旧 Snell 服务与配置
  migrate      takeover 的兼容别名
  uninstall    卸载 Snell Server
  menu         打开交互式管理菜单（默认）

Options:
  -h, --help   显示帮助
EOF
}

init_prompt_input() {
    ui_init_prompt_input
}

read_prompt() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_read_raw "$@"
}

read_secret() {
    local __target="$1" __prompt="$2" __value
    UI_PROMPT_FD="${PROMPT_FD}"
    if ! IFS= read -r -s -u "${UI_PROMPT_FD}" -p "${__prompt}" __value; then
        printf '\n' >&2
        ui_error "无法读取密钥输入。"
        exit 1
    fi
    printf '\n'
    __value="${__value//$'\r'/}"
    printf -v "${__target}" '%s' "${__value}"
}

read_prompt_or_cancel() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_read_or_cancel "$@"
}

read_secret_or_cancel() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_read_secret_or_cancel "$@"
}

read_menu_choice() {
    local __target="$1" __prompt="$2"
    read_prompt "${__target}" "${__prompt}"
    if is_cancel_input "${!__target}" || is_back_input "${!__target}"; then
        return "${RETURN_TO_MENU}"
    fi
}

pause_screen() {
    ui_pause
}

confirm_yes_no() {
    ui_confirm "$@"
}

run_menu_action() {
    ui_run_menu_action "$@"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        ui_error "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

check_command_exists() { command -v "$1" >/dev/null 2>&1; }

require_systemd() {
    if ! check_command_exists systemctl; then
        ui_error "当前系统未检测到 systemd，无法自动管理 Snell 服务。"
        exit 1
    fi
}

detect_package_manager() {
    if check_command_exists apk; then
        PKG_MANAGER="apk"
    elif check_command_exists apt-get; then
        PKG_MANAGER="apt"
    elif check_command_exists dnf; then
        PKG_MANAGER="dnf"
    elif check_command_exists yum; then
        PKG_MANAGER="yum"
    else
        ui_error "未找到受支持的包管理器（apk/apt/dnf/yum）。"
        exit 1
    fi
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        i386|i686) ARCH="i386" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        armv7l|armv7) ARCH="armv7l" ;;
        *)
            ui_error "不支持的系统架构：$(uname -m)"
            exit 1
            ;;
    esac
}

detect_system_info() {
    require_systemd
    detect_package_manager
    detect_architecture
}

install_packages() {
    [ "$#" -gt 0 ] || return 0
    case "${PKG_MANAGER}" in
        apk) apk add --no-cache "$@" >/dev/null || return 1 ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update >/dev/null || return 1
            apt-get install -y "$@" >/dev/null || return 1
            ;;
        dnf) dnf install -y "$@" >/dev/null || return 1 ;;
        yum) yum install -y "$@" >/dev/null || return 1 ;;
    esac
}

ensure_dependencies() {
    ui_section "检查基础依赖"
    case "${PKG_MANAGER}" in
        apk) install_packages curl openssl unzip ca-certificates iproute2 || return 1 ;;
        apt) install_packages curl openssl unzip ca-certificates iproute2 || return 1 ;;
        dnf|yum) install_packages curl openssl unzip ca-certificates iproute || return 1 ;;
    esac
    ui_ok "基础依赖已就绪。"
}

normalize_version() {
    local version="$1"
    version="${version#v}"
    printf '%s' "${version}"
}

snell_major_version() {
    local version="$1"
    version="$(normalize_version "${version}")"
    printf '%s' "${version%%.*}"
}

validate_version() {
    [[ "$1" =~ ^v?[0-9]+(\.[0-9]+){1,2}([a-zA-Z0-9._-]+)?$ ]]
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

validate_single_line() {
    case "$1" in
        *$'\n'*|*$'\r'*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_psk() {
    local psk="$1"
    validate_single_line "${psk}" || return 1
    [ -n "${psk}" ] || return 1
    [ "${#psk}" -le 256 ] || return 1
}

validate_dns() {
    local dns="$1" dns_pattern='^[0-9A-Fa-f:. ,_-]+$'
    validate_single_line "${dns}" || return 1
    [[ "${dns}" =~ ${dns_pattern} ]] || return 1
    [[ "${dns}" =~ [0-9A-Fa-f] ]]
}

validate_boolean_value() {
    case "$1" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

validate_obfs_mode() {
    case "$1" in
        off|http|tls) return 0 ;;
        *) return 1 ;;
    esac
}

validate_obfs_host() {
    local host="$1"
    validate_single_line "${host}" || return 1
    [ -n "${host}" ] || return 1
    [ "${#host}" -le 253 ] || return 1
    [[ "${host}" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_protocol_version() {
    case "$1" in
        4|5) return 0 ;;
        *) return 1 ;;
    esac
}

is_port_in_use() {
    local port="$1"
    if check_command_exists ss; then
        ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    elif check_command_exists netstat; then
        netstat -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
        return 1
    fi
}

read_ini_value() {
    local key="$1" file="$2"
    [ -f "${file}" ] || return 1
    awk -v wanted_key="${key}" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*;/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            in_section = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/)
            next
        }
        in_section {
            pos = index($0, "=")
            if (pos == 0) next
            found_key = substr($0, 1, pos - 1)
            value = substr($0, pos + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", found_key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (found_key == wanted_key) {
                print value
                exit
            }
        }
    ' "${file}"
}

get_config_port() {
    local listen
    listen="$(read_ini_value "listen" "${SNELL_CONFIG_FILE}" || true)"
    [ -n "${listen}" ] || return 1
    listen="${listen##*:}"
    validate_port "${listen}" || return 1
    printf '%s' "${listen}"
}

get_config_psk() { read_ini_value "psk" "${SNELL_CONFIG_FILE}" || true; }
get_config_ipv6() { read_ini_value "ipv6" "${SNELL_CONFIG_FILE}" || true; }
get_config_dns() { read_ini_value "dns" "${SNELL_CONFIG_FILE}" || true; }
get_config_obfs() { read_ini_value "obfs" "${SNELL_CONFIG_FILE}" || echo "off"; }
get_config_obfs_host() { read_ini_value "obfs-host" "${SNELL_CONFIG_FILE}" || true; }
get_config_tfo() { read_ini_value "tfo" "${SNELL_CONFIG_FILE}" || echo "false"; }
get_config_protocol_version() { read_ini_value "version" "${SNELL_CONFIG_FILE}" || true; }

get_installed_binary_version() {
    if [ -f "${SNELL_VERSION_FILE}" ]; then
        sed 's/^v//' "${SNELL_VERSION_FILE}" | head -n 1
    else
        echo "unknown"
    fi
}

service_state() {
    if systemctl is-active --quiet snell 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

build_status_line() {
    local state port version protocol legacy
    state="$(service_state)"
    port="$(get_config_port 2>/dev/null || echo "unknown")"
    version="$(get_installed_binary_version)"
    protocol="$(get_config_protocol_version 2>/dev/null || true)"
    protocol="${protocol:-unknown}"
    if [[ "${protocol}" =~ ^[0-9]+$ ]]; then
        protocol="v${protocol}"
    fi
    if has_legacy_layout; then
        legacy="yes"
    else
        legacy="no"
    fi

    printf 'Snell: %s | Port: %s | Version: %s | Protocol: %s | Legacy: %s' \
        "${state}" "${port}" "${version}" "${protocol}" "${legacy}"
}

backup_file() {
    local file_path="$1" backup_path
    [ -e "${file_path}" ] || return 0
    backup_path="${file_path}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "${file_path}" "${backup_path}"
    ui_ok "已备份：${backup_path}"
}

backup_path_for_rollback() {
    local file_path="$1"
    [ -e "${file_path}" ] || return 0
    local backup_path
    backup_path="${file_path}.rollback.$(date +%Y%m%d_%H%M%S)"
    cp -a "${file_path}" "${backup_path}" || return 1
    printf '%s\n' "${backup_path}"
}

restore_path_for_rollback() {
    local backup_path="$1" target_path="$2"
    [ -n "${backup_path}" ] && [ -e "${backup_path}" ] || return 1
    cp -a "${backup_path}" "${target_path}"
}

atomic_replace_file() {
    local target="$1" mode="$2" owner_group="${3:-}" tmp_file target_dir
    target_dir="$(dirname "${target}")"
    mkdir -p "${target_dir}" || return 1
    tmp_file="$(mktemp "${target_dir}/.$(basename "${target}").XXXXXX")" || return 1
    chmod "${mode}" "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
    if [ -n "${owner_group}" ]; then
        chown "${owner_group}" "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
    fi
    cat > "${tmp_file}" || { rm -f "${tmp_file}"; return 1; }
    mv -f "${tmp_file}" "${target}" || { rm -f "${tmp_file}"; return 1; }
}

has_legacy_layout() {
    [ -f "${OLD_SNELL_CONFIG_FILE}" ] || [ -f "${OLD_SNELL_SERVICE_FILE}" ]
}

legacy_service_state() {
    if systemctl is-active --quiet snell-server 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

read_legacy_config() {
    if [ ! -f "${OLD_SNELL_CONFIG_FILE}" ]; then
        ui_error "未找到旧配置：${OLD_SNELL_CONFIG_FILE}"
        return 1
    fi

    LEGACY_LISTEN="$(read_ini_value "listen" "${OLD_SNELL_CONFIG_FILE}" || true)"
    LEGACY_PSK="$(read_ini_value "psk" "${OLD_SNELL_CONFIG_FILE}" || true)"
    [ -n "${LEGACY_LISTEN}" ] || { ui_error "旧配置缺少 listen 字段。"; return 1; }
    [ -n "${LEGACY_PSK}" ] || { ui_error "旧配置缺少 psk 字段。"; return 1; }

    LEGACY_PORT="${LEGACY_LISTEN##*:}"
    validate_port "${LEGACY_PORT}" || { ui_error "旧配置中的监听端口无效：${LEGACY_LISTEN}"; return 1; }

    LEGACY_IPV6="$(read_ini_value "ipv6" "${OLD_SNELL_CONFIG_FILE}" || echo "false")"
    LEGACY_DNS="$(read_ini_value "dns" "${OLD_SNELL_CONFIG_FILE}" || echo "${SNELL_DNS_DEFAULT}")"
    LEGACY_OBFS="$(read_ini_value "obfs" "${OLD_SNELL_CONFIG_FILE}" || echo "off")"
    LEGACY_OBFS_HOST="$(read_ini_value "obfs-host" "${OLD_SNELL_CONFIG_FILE}" || true)"
    LEGACY_TFO="$(read_ini_value "tfo" "${OLD_SNELL_CONFIG_FILE}" || echo "false")"
    LEGACY_PROTOCOL_VERSION="$(read_ini_value "version" "${OLD_SNELL_CONFIG_FILE}" || true)"
    if [ -z "${LEGACY_PROTOCOL_VERSION}" ] && [ -f "${OLD_SNELL_VERSION_FILE}" ]; then
        LEGACY_PROTOCOL_VERSION="$(sed 's/^v//' "${OLD_SNELL_VERSION_FILE}" | head -n 1 | cut -d '.' -f 1)"
    fi
    LEGACY_PROTOCOL_VERSION="${LEGACY_PROTOCOL_VERSION:-5}"

    if [ "${LEGACY_OBFS}" != "off" ] && [ -z "${LEGACY_OBFS_HOST}" ]; then
        LEGACY_OBFS_HOST="${SNELL_OBFS_HOST_DEFAULT}"
    fi

    if [ -f "${OLD_SNELL_VERSION_FILE}" ]; then
        LEGACY_BINARY_VERSION="$(sed 's/^v//' "${OLD_SNELL_VERSION_FILE}" | head -n 1)"
    elif [ -f "${SNELL_VERSION_FILE}" ]; then
        LEGACY_BINARY_VERSION="$(get_installed_binary_version)"
    else
        LEGACY_BINARY_VERSION="unknown"
    fi

    LEGACY_SERVICE_STATE="$(legacy_service_state)"
    if systemctl is-active --quiet snell-server 2>/dev/null; then
        LEGACY_WAS_ACTIVE=true
    else
        LEGACY_WAS_ACTIVE=false
    fi
}

show_legacy_takeover_plan() {
    ui_section "接管计划"
    ui_warn "此操作将接管以下对象："
    ui_kv "旧服务状态" "${LEGACY_SERVICE_STATE}"
    ui_kv "旧监听端口" "${LEGACY_PORT}"
    ui_kv "协议版本" "${LEGACY_PROTOCOL_VERSION}"
    ui_kv "二进制版本" "${LEGACY_BINARY_VERSION}"
    ui_kv "IPv6" "${LEGACY_IPV6}"
    ui_kv "TFO" "${LEGACY_TFO}"
    ui_kv "obfs" "${LEGACY_OBFS}"
    ui_kv "新配置" "${SNELL_CONFIG_FILE}"
    ui_kv "新服务" "${SNELL_SERVICE_FILE}"
    ui_blank
    ui_print "旧配置和旧服务会在新服务验证成功后改名备份。"
    if [ "${LEGACY_WAS_ACTIVE}" = true ]; then
        ui_warn "接管会短暂停止旧 snell-server，再启动新 snell 服务。"
    fi
}

write_config_from_legacy() {
    ui_section "生成新配置与服务"
    write_snell_config \
        "${LEGACY_PORT}" \
        "${LEGACY_PSK}" \
        "${LEGACY_IPV6:-false}" \
        "${LEGACY_DNS:-${SNELL_DNS_DEFAULT}}" \
        "${LEGACY_OBFS:-off}" \
        "${LEGACY_OBFS_HOST:-}" \
        "${LEGACY_TFO:-false}" \
        "${LEGACY_PROTOCOL_VERSION:-5}" || return 1
    if [ -n "${LEGACY_BINARY_VERSION}" ] && [ "${LEGACY_BINARY_VERSION}" != "unknown" ]; then
        printf '%s\n' "${LEGACY_BINARY_VERSION}" | atomic_replace_file "${SNELL_VERSION_FILE}" 644 || return 1
    fi
    write_systemd_service || return 1
}

start_new_service_for_takeover() {
    ui_section "切换到新服务"
    systemctl stop snell >/dev/null 2>&1 || true
    if [ "${LEGACY_WAS_ACTIVE}" = true ]; then
        systemctl stop snell-server >/dev/null 2>&1 || true
    fi
    systemctl enable snell >/dev/null || return 1
    systemctl restart snell || return 1
}

verify_takeover() {
    local failed=0
    ui_section "验证新服务"

    if systemctl is-active --quiet snell 2>/dev/null; then
        ui_ok "新 snell 服务 active。"
    else
        ui_error "新 snell 服务未处于 active。"
        failed=1
    fi

    if check_command_exists ss; then
        if is_tcp_port_listening "${LEGACY_PORT}"; then
            ui_ok "检测到 TCP ${LEGACY_PORT} 正在监听。"
        else
            ui_error "未检测到 TCP ${LEGACY_PORT} 监听。"
            failed=1
        fi
    else
        ui_warn "缺少 ss 命令，跳过端口监听验证。"
    fi

    if [ -f "${SNELL_CONFIG_FILE}" ] && [ -f "${SNELL_SERVICE_FILE}" ]; then
        ui_ok "新配置与新服务文件存在。"
    else
        ui_error "新配置或新服务文件缺失。"
        failed=1
    fi

    [ "${failed}" -eq 0 ]
}

finalize_legacy_takeover() {
    local backup_suffix
    backup_suffix="$(date +%Y%m%d_%H%M%S)"
    ui_section "收敛旧服务"

    systemctl disable snell-server >/dev/null 2>&1 || true
    [ -f "${OLD_SNELL_SERVICE_FILE}" ] && mv "${OLD_SNELL_SERVICE_FILE}" "${OLD_SNELL_SERVICE_FILE}.bak.${backup_suffix}"
    [ -f "${OLD_SNELL_CONFIG_FILE}" ] && mv "${OLD_SNELL_CONFIG_FILE}" "${OLD_SNELL_CONFIG_FILE}.bak.${backup_suffix}"
    [ -f "${OLD_SNELL_VERSION_FILE}" ] && mv "${OLD_SNELL_VERSION_FILE}" "${OLD_SNELL_VERSION_FILE}.bak.${backup_suffix}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    ui_ok "旧服务和旧配置已备份，新 snell 服务已接管。"
}

cleanup_failed_new_snell_takeover() {
    ui_warn "正在清理失败的新 snell 接管残留。"
    systemctl disable --now snell >/dev/null 2>&1 || true
    rm -f "${SNELL_SERVICE_FILE}"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

rollback_legacy_takeover() {
    ui_section "接管失败，执行回滚"
    systemctl disable --now snell >/dev/null 2>&1 || true
    if [ "${LEGACY_WAS_ACTIVE}" = true ] && [ -f "${OLD_SNELL_SERVICE_FILE}" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start snell-server >/dev/null 2>&1 || true
        if systemctl is-active --quiet snell-server 2>/dev/null; then
            ui_ok "旧 snell-server 服务已恢复运行。"
        else
            ui_error "旧 snell-server 服务未能自动恢复，请立即手动检查。"
        fi
    else
        ui_warn "旧服务原本不是 active，已停止新 snell 服务。"
    fi
    journalctl -u snell -n 40 --no-pager 2>/dev/null || true
}

run_legacy_takeover() {
    ui_render_title
    ui_section "检测 / 接管旧 Snell 服务与配置"
    if ! has_legacy_layout; then
        ui_ok "未发现旧配置路径或旧服务文件。"
        pause_screen
        return
    fi

    read_legacy_config || { pause_screen; return 1; }
    show_legacy_takeover_plan
    ui_blank
    ui_confirm_token "确认接管旧 Snell？" "TAKEOVER" || { ui_warn "已取消接管。"; pause_screen; return 0; }

    ensure_dependencies || {
        ui_error "依赖安装失败，未执行接管。"
        pause_screen
        return 1
    }
    write_config_from_legacy || {
        ui_error "新配置或服务文件生成失败，未切换旧服务。"
        cleanup_failed_new_snell_takeover
        pause_screen
        return 1
    }
    if ! start_new_service_for_takeover; then
        rollback_legacy_takeover
        pause_screen
        return 1
    fi
    if ! verify_takeover; then
        rollback_legacy_takeover
        pause_screen
        return 1
    fi

    finalize_legacy_takeover
    ui_ok "旧 Snell 已安全接管到 snell.service。"
    show_client_config false
    pause_screen
}

run_legacy_migration() {
    run_legacy_takeover "$@"
}

choose_snell_version() {
    local var_name="$1" choice selected_version
    ui_print "请选择 Snell Server 版本："
    ui_blank
    ui_menu_item 1 "v${SNELL_VERSION_DEFAULT}（默认，v5）"
    ui_menu_item 2 "v${SNELL_V4_VERSION}（v4）"
    ui_menu_item 3 "手动输入版本号"
    ui_menu_item 0 "返回上一级"
    ui_submenu_hint
    while true; do
        ui_blank
        read_menu_choice choice "请输入选项编号（默认 1，0 返回）： " || return "$?"
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"; return 0 ;;
            2) printf -v "${var_name}" '%s' "${SNELL_V4_VERSION}"; return 0 ;;
            3)
                ui_input_hint
                ui_blank
                read_prompt_or_cancel selected_version "请输入版本号（例如 5.0.1，q 取消）： " || return "$?"
                selected_version="$(normalize_version "${selected_version}")"
                validate_version "${selected_version}" || { ui_error "版本号格式无效。"; continue; }
                printf -v "${var_name}" '%s' "${selected_version}"
                return 0
                ;;
            *) ui_error "无效选项，请输入 1、2 或 3。" ;;
        esac
    done
}

choose_update_version() {
    local var_name="$1" current_version choice target_input current_major
    current_version="$(get_installed_binary_version)"
    current_major="$(get_config_protocol_version)"

    ui_print "请选择更新目标："
    ui_blank
    ui_menu_item 1 "更新到默认稳定版本 v${SNELL_VERSION_DEFAULT}"
    ui_menu_item 2 "指定版本更新"
    if [ "${current_major}" = "4" ]; then
        ui_menu_item 3 "从 v4 升级到 v5 默认稳定版本"
    fi
    ui_menu_item 0 "返回上一级"
    ui_blank
    ui_dim "当前二进制版本：${current_version}；配置协议版本：${current_major:-未知}"
    ui_submenu_hint

    while true; do
        ui_blank
        read_menu_choice choice "请输入选项编号（默认 1，0 返回）： " || return "$?"
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"; return 0 ;;
            2)
                ui_input_hint
                ui_blank
                read_prompt_or_cancel target_input "请输入目标版本号（例如 5.0.1，q 取消）： " || return "$?"
                target_input="$(normalize_version "${target_input}")"
                validate_version "${target_input}" || { ui_error "版本号格式无效。"; continue; }
                printf -v "${var_name}" '%s' "${target_input}"
                return 0
                ;;
            3)
                if [ "${current_major}" = "4" ]; then
                    printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"
                    return 0
                fi
                ui_error "当前配置不是 v4，不能使用该选项。"
                ;;
            *) ui_error "无效选项，请重新输入。" ;;
        esac
    done
}

prompt_port() {
    local var_name="$1" default_port="$2" value
    ui_default_hint
    while true; do
        ui_blank
        read_prompt_or_cancel value "请输入 Snell 监听端口（默认 ${default_port}，回车使用默认值，q 取消）： " || return "$?"
        value="${value:-${default_port}}"
        validate_port "${value}" || { ui_error "端口格式无效，请输入 1-65535 之间的数字。"; continue; }
        if is_port_in_use "${value}" && [ "${value}" != "$(get_config_port 2>/dev/null || true)" ]; then
            ui_error "端口 ${value} 已被占用，请更换。"
            continue
        fi
        printf -v "${var_name}" '%s' "${value}"
        return 0
    done
}

prompt_psk() {
    local var_name="$1" current_value="${2:-}" value confirm_rc
    if [ -n "${current_value}" ]; then
        ui_blank
        confirm_yes_no "是否修改 PSK？" "n"
        confirm_rc=$?
        case "${confirm_rc}" in
            0) ;;
            1) printf -v "${var_name}" '%s' "${current_value}"; return 0 ;;
            "${RETURN_TO_MENU}") return "${RETURN_TO_MENU}" ;;
            *) return "${confirm_rc}" ;;
        esac
    fi

    ui_blank
    confirm_yes_no "是否手动指定 PSK？" "n"
    confirm_rc=$?
    if [ "${confirm_rc}" -eq 0 ]; then
        while true; do
            ui_blank
            read_secret_or_cancel value "请输入 Snell PSK（q 取消）： " || return "$?"
            validate_psk "${value}" && break
            ui_error "PSK 不能为空、不能包含换行，且长度不能超过 256 个字符。"
        done
    elif [ "${confirm_rc}" -eq 1 ]; then
        value="$(openssl rand -base64 18)"
        ui_ok "已生成随机 PSK。"
    else
        return "${confirm_rc}"
    fi
    printf -v "${var_name}" '%s' "${value}"
}

prompt_boolean() {
    local var_name="$1" prompt_text="$2" default_value="${3:-false}" confirm_rc
    ui_blank
    if confirm_yes_no "${prompt_text}" "$( [ "${default_value}" = "true" ] && echo y || echo n )"; then
        printf -v "${var_name}" '%s' "true"
    else
        confirm_rc=$?
        if [ "${confirm_rc}" -eq "${RETURN_TO_MENU}" ]; then
            return "${RETURN_TO_MENU}"
        fi
        printf -v "${var_name}" '%s' "false"
    fi
}

prompt_dns() {
    local var_name="$1" default_dns="$2" value
    ui_default_hint
    ui_blank
    read_prompt_or_cancel value "请输入 DNS（默认 ${default_dns}，回车使用默认值，q 取消）： " || return "$?"
    value="${value:-${default_dns}}"
    validate_dns "${value}" || { ui_error "DNS 只能包含 IP、逗号、空格、点、冒号、下划线和短横线。"; return 1; }
    printf -v "${var_name}" '%s' "${value}"
}

prompt_obfs() {
    local obfs_var="$1" host_var="$2" current_obfs="${3:-off}" current_host="${4:-}" choice host
    ui_print "请选择 obfs 设置："
    ui_blank
    ui_menu_item 1 "off（默认）"
    ui_menu_item 2 "http"
    ui_menu_item 3 "tls"
    ui_menu_item 0 "返回上一级"
    ui_default_hint
    while true; do
        ui_blank
        read_menu_choice choice "请输入选项编号（当前 ${current_obfs:-off}，回车保持，0 返回）： " || return "$?"
        if [ -z "${choice}" ]; then
            printf -v "${obfs_var}" '%s' "${current_obfs:-off}"
            printf -v "${host_var}" '%s' "${current_host:-}"
            return 0
        fi
        case "${choice}" in
            1) printf -v "${obfs_var}" '%s' "off"; printf -v "${host_var}" '%s' ""; return 0 ;;
            2) printf -v "${obfs_var}" '%s' "http"; break ;;
            3) printf -v "${obfs_var}" '%s' "tls"; break ;;
            *) ui_error "无效选项，请输入 1、2 或 3。" ;;
        esac
    done
    validate_obfs_mode "${!obfs_var}" || { ui_error "obfs 只能是 off、http 或 tls。"; return 1; }
    ui_default_hint
    ui_blank
    read_prompt_or_cancel host "请输入 obfs-host（默认 ${current_host:-${SNELL_OBFS_HOST_DEFAULT}}，回车使用默认值，q 取消）： " || return "$?"
    host="${host:-${current_host:-${SNELL_OBFS_HOST_DEFAULT}}}"
    validate_obfs_host "${host}" || { ui_error "obfs-host 只能包含字母、数字、点、下划线和短横线，长度不能超过 253。"; return 1; }
    printf -v "${host_var}" '%s' "${host}"
}

show_config_change_summary() {
    local title="$1" version_label="$2" port="$3" ipv6="$4" dns="$5" tfo="$6" obfs="$7" obfs_host="$8"
    ui_section "${title}"
    if [ -n "${version_label}" ]; then
        ui_kv "版本" "${version_label}"
    fi
    ui_kv "监听端口" "${port}"
    ui_kv "IPv6" "${ipv6}"
    ui_kv "DNS" "${dns}"
    ui_kv "TFO" "${tfo}"
    ui_kv "obfs" "${obfs}"
    if [ "${obfs}" != "off" ]; then
        ui_kv "obfs-host" "${obfs_host}"
    fi
    ui_blank
    ui_warn "确认后将写入配置并重启 snell 服务；PSK 不会在摘要中显示。"
}

build_listen_value() {
    local port="$1" ipv6="$2"
    if [ "${ipv6}" = "true" ]; then
        echo "::0:${port}"
    else
        echo "0.0.0.0:${port}"
    fi
}

file_sha256() {
    local file="$1"
    if check_command_exists sha256sum; then
        sha256sum "${file}" | awk '{print $1}'
    elif check_command_exists shasum; then
        shasum -a 256 "${file}" | awk '{print $1}'
    elif check_command_exists openssl; then
        openssl dgst -sha256 "${file}" | awk '{print $NF}'
    else
        return 1
    fi
}

verify_archive_checksum() {
    local archive="$1" version="$2" arch="$3" expected actual
    expected="${SNELL_EXPECTED_SHA256:-}"
    if [ -z "${expected}" ]; then
        ui_warn "未配置 SNELL_EXPECTED_SHA256，仅完成 HTTPS 下载校验：v${version} (${arch})。"
        return 0
    fi
    actual="$(file_sha256 "${archive}")" || {
        ui_error "无法计算下载文件 SHA256。"
        return 1
    }
    if [ "${actual}" != "${expected}" ]; then
        ui_error "SHA256 校验失败。"
        ui_error "期望：${expected}"
        ui_error "实际：${actual}"
        return 1
    fi
}

download_and_install_snell_binary() (
    local download_version="$1" download_url temp_dir archive_path
    download_version="$(normalize_version "${download_version}")"
    download_url="https://dl.nssurge.com/snell/snell-server-v${download_version}-linux-${ARCH}.zip"
    temp_dir="$(mktemp -d)" || return 1
    archive_path="${temp_dir}/snell-server.zip"
    trap 'rm -rf "${temp_dir}"' EXIT

    ui_info "正在下载 Snell Server v${download_version} (${ARCH})..."
    if ! curl --proto '=https' --tlsv1.2 -fL --show-error --retry 3 --connect-timeout 10 --max-time 120 "${download_url}" -o "${archive_path}"; then
        ui_error "下载失败：${download_url}"
        return 1
    fi
    verify_archive_checksum "${archive_path}" "${download_version}" "${ARCH}" || return 1

    if ! unzip -q "${archive_path}" -d "${temp_dir}"; then
        ui_error "解压失败：${archive_path}"
        return 1
    fi
    if [ ! -f "${temp_dir}/snell-server" ]; then
        ui_error "压缩包中未找到 snell-server 二进制。"
        return 1
    fi
    chmod 0755 "${temp_dir}/snell-server" || return 1

    install -m 0755 "${temp_dir}/snell-server" "${SNELL_BINARY_PATH}.new" || return 1
    mv -f "${SNELL_BINARY_PATH}.new" "${SNELL_BINARY_PATH}" || return 1
    mkdir -p "${SNELL_CONFIG_DIR}"
    printf '%s\n' "${download_version}" | atomic_replace_file "${SNELL_VERSION_FILE}" 644 || return 1
    ui_ok "Snell Server v${download_version} 已安装到 ${SNELL_BINARY_PATH}。"
)

write_snell_config() {
    local port="$1" psk="$2" ipv6="$3" dns="$4" obfs="$5" obfs_host="$6" tfo="$7" protocol_version="$8" listen
    validate_port "${port}" || { ui_error "配置写入失败：端口无效。"; return 1; }
    validate_psk "${psk}" || { ui_error "配置写入失败：PSK 无效。"; return 1; }
    validate_boolean_value "${ipv6}" || { ui_error "配置写入失败：IPv6 设置无效。"; return 1; }
    validate_dns "${dns}" || { ui_error "配置写入失败：DNS 无效。"; return 1; }
    validate_obfs_mode "${obfs}" || { ui_error "配置写入失败：obfs 无效。"; return 1; }
    validate_boolean_value "${tfo}" || { ui_error "配置写入失败：TFO 设置无效。"; return 1; }
    validate_protocol_version "${protocol_version}" || { ui_error "配置写入失败：协议版本无效。"; return 1; }
    if [ "${obfs}" != "off" ]; then
        validate_obfs_host "${obfs_host}" || { ui_error "配置写入失败：obfs-host 无效。"; return 1; }
    fi

    mkdir -p "${SNELL_CONFIG_DIR}"
    [ -f "${SNELL_CONFIG_FILE}" ] && backup_file "${SNELL_CONFIG_FILE}"
    listen="$(build_listen_value "${port}" "${ipv6}")"

    {
        printf '%s\n' "[snell-server]"
        printf 'listen = %s\n' "${listen}"
        printf 'psk = %s\n' "${psk}"
        printf 'ipv6 = %s\n' "${ipv6}"
        printf 'dns = %s\n' "${dns}"
        printf 'obfs = %s\n' "${obfs}"
        if [ "${obfs}" != "off" ]; then
            printf 'obfs-host = %s\n' "${obfs_host}"
        fi
        printf 'tfo = %s\n' "${tfo}"
        printf 'version = %s\n' "${protocol_version}"
    } | atomic_replace_file "${SNELL_CONFIG_FILE}" 600 || return 1
    ui_ok "Snell 配置已写入 ${SNELL_CONFIG_FILE}。"
}

write_systemd_service() {
    cat <<EOF | atomic_replace_file "${SNELL_SERVICE_FILE}" 644 || return 1
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SNELL_CONFIG_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=32768
ExecStart=${SNELL_BINARY_PATH} -c ${SNELL_CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    ui_ok "systemd 服务已写入 ${SNELL_SERVICE_FILE}。"
}

start_snell_service() {
    systemctl start snell
}

stop_snell_service() {
    systemctl stop snell
}

restart_snell_service() {
    systemctl restart snell
}

enable_and_restart_service() {
    systemctl enable snell >/dev/null || return 1
    restart_snell_service
}

install_or_reinstall_snell() {
    ui_render_title
    ui_section "安装 / 覆盖安装 Snell Server"
    local confirm_rc
    if has_legacy_layout; then
        ui_warn '检测到旧 Snell 布局。已有旧 VPS 建议优先使用菜单中的 "检测 / 接管旧 Snell 服务与配置"。'
        ui_blank
        confirm_yes_no "是否仍然继续执行全新安装 / 覆盖安装？" "n"
        confirm_rc=$?
        if [ "${confirm_rc}" -eq "${RETURN_TO_MENU}" ]; then
            return "${RETURN_TO_MENU}"
        fi
        if [ "${confirm_rc}" -ne 0 ]; then
            ui_warn "已取消安装。"
            pause_screen
            return
        fi
    fi
    ensure_dependencies || return 1

    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        ui_blank
        confirm_yes_no "检测到已有配置，是否覆盖安装？" "n"
        confirm_rc=$?
        if [ "${confirm_rc}" -eq "${RETURN_TO_MENU}" ]; then
            return "${RETURN_TO_MENU}"
        fi
        if [ "${confirm_rc}" -ne 0 ]; then
            ui_warn "已取消。"
            pause_screen
            return
        fi
    fi

    local version protocol_version port psk ipv6 dns obfs obfs_host tfo
    choose_snell_version version || return "$?"
    protocol_version="$(snell_major_version "${version}")"
    prompt_port port "${SNELL_PORT_DEFAULT}" || return "$?"
    prompt_psk psk || return "$?"
    prompt_boolean ipv6 "是否启用 IPv6 监听？" "n" || return "$?"
    prompt_dns dns "${SNELL_DNS_DEFAULT}" || return "$?"
    prompt_boolean tfo "是否启用 TFO？" "n" || return "$?"
    prompt_obfs obfs obfs_host "off" "" || return "$?"

    show_config_change_summary "确认安装参数" "v${version}" "${port}" "${ipv6}" "${dns}" "${tfo}" "${obfs}" "${obfs_host}"
    ui_blank
    confirm_yes_no "确认写入配置并启动服务？" "y"
    confirm_rc=$?
    if [ "${confirm_rc}" -eq "${RETURN_TO_MENU}" ]; then
        return "${RETURN_TO_MENU}"
    fi
    if [ "${confirm_rc}" -ne 0 ]; then
        ui_warn "已取消安装。"
        pause_screen
        return
    fi

    download_and_install_snell_binary "${version}" || return 1
    write_snell_config "${port}" "${psk}" "${ipv6}" "${dns}" "${obfs}" "${obfs_host}" "${tfo}" "${protocol_version}" || return 1
    write_systemd_service || return 1
    if [ "${tfo}" = "true" ]; then
        if write_network_tuning; then
            ui_ok "已同步应用 TFO 与基础网络优化参数。"
        else
            ui_warn "Snell 将继续安装，但 TFO / 网络优化未确认生效，请稍后通过菜单 8 单独修复。"
        fi
    fi
    enable_and_restart_service || return 1

    ui_ok "Snell Server 已安装并启动。"
    show_client_config false
    pause_screen
}

get_server_ip() {
    curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null \
        || curl -fsS -6 -m 5 https://api64.ipify.org 2>/dev/null \
        || echo "SERVER_IP"
}

show_client_config() {
    local pause_after="${1:-false}" port psk ipv6 dns obfs obfs_host tfo protocol_version binary_version server_ip host client_line
    ui_section "当前配置"
    if [ ! -f "${SNELL_CONFIG_FILE}" ]; then
        ui_warn "尚未安装或尚未生成 Snell 配置。"
        if [ "${pause_after}" = true ]; then
            pause_screen
        fi
        return
    fi

    port="$(get_config_port || echo "unknown")"
    psk="$(get_config_psk)"
    ipv6="$(get_config_ipv6)"
    dns="$(get_config_dns)"
    obfs="$(get_config_obfs)"
    obfs_host="$(get_config_obfs_host)"
    tfo="$(get_config_tfo)"
    protocol_version="$(get_config_protocol_version)"
    binary_version="$(get_installed_binary_version)"
    server_ip="$(get_server_ip)"
    host="$(hostname 2>/dev/null || echo snell)"

    ui_kv "服务状态" "$(service_state)"
    ui_kv "监听端口" "${port}"
    ui_kv "协议版本" "${protocol_version:-未知}"
    ui_kv "二进制版本" "${binary_version}"
    ui_kv "IPv6" "${ipv6:-false}"
    ui_kv "TFO" "${tfo:-false}"
    ui_kv "obfs" "${obfs:-off}"
    ui_kv "DNS" "${dns:-未设置}"
    ui_blank
    ui_warn "下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。"
    ui_blank
    ui_info "Surge 配置片段："
    client_line="${host} = snell, ${server_ip}, ${port}, psk=${psk}, version=${protocol_version:-5}, tfo=${tfo:-false}, reuse=true, ecn=true"
    if [ "${obfs:-off}" != "off" ]; then
        client_line="${client_line}, obfs=${obfs}, obfs-host=${obfs_host}"
    fi
    ui_print "${client_line}"

    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

modify_snell_config() {
    ui_render_title
    ui_section "修改 Snell 配置"
    if [ ! -f "${SNELL_CONFIG_FILE}" ]; then
        ui_error "尚未安装或尚未生成 Snell 配置。"
        pause_screen
        return
    fi

    local current_port current_psk current_ipv6 current_dns current_obfs current_obfs_host current_tfo current_protocol
    local port psk ipv6 dns obfs obfs_host tfo protocol_version
    local confirm_rc
    current_port="$(get_config_port || echo "${SNELL_PORT_DEFAULT}")"
    current_psk="$(get_config_psk)"
    current_ipv6="$(get_config_ipv6)"
    current_dns="$(get_config_dns)"
    current_obfs="$(get_config_obfs)"
    current_obfs_host="$(get_config_obfs_host)"
    current_tfo="$(get_config_tfo)"
    current_protocol="$(get_config_protocol_version)"

    prompt_port port "${current_port}" || return "$?"
    prompt_psk psk "${current_psk}" || return "$?"
    prompt_boolean ipv6 "是否启用 IPv6 监听？" "${current_ipv6:-false}" || return "$?"
    prompt_dns dns "${current_dns:-${SNELL_DNS_DEFAULT}}" || return "$?"
    prompt_boolean tfo "是否启用 TFO？" "${current_tfo:-false}" || return "$?"
    prompt_obfs obfs obfs_host "${current_obfs:-off}" "${current_obfs_host:-}" || return "$?"
    protocol_version="${current_protocol:-5}"

    show_config_change_summary "确认修改参数" "" "${port}" "${ipv6}" "${dns}" "${tfo}" "${obfs}" "${obfs_host}"
    ui_blank
    confirm_yes_no "确认写入配置并重启服务？" "y"
    confirm_rc=$?
    if [ "${confirm_rc}" -eq "${RETURN_TO_MENU}" ]; then
        return "${RETURN_TO_MENU}"
    fi
    if [ "${confirm_rc}" -ne 0 ]; then
        ui_warn "已取消修改。"
        pause_screen
        return
    fi

    write_snell_config "${port}" "${psk}" "${ipv6}" "${dns}" "${obfs}" "${obfs_host}" "${tfo}" "${protocol_version}" || return 1
    restart_snell_service || return 1
    ui_ok "配置已更新并重启服务。"
    show_client_config false
    pause_screen
}

update_config_protocol_version() {
    local target_version="$1" protocol_version port psk ipv6 dns obfs obfs_host tfo
    [ -f "${SNELL_CONFIG_FILE}" ] || return 0
    protocol_version="$(snell_major_version "${target_version}")"
    port="$(get_config_port || echo "${SNELL_PORT_DEFAULT}")"
    psk="$(get_config_psk)"
    ipv6="$(get_config_ipv6)"
    dns="$(get_config_dns)"
    obfs="$(get_config_obfs)"
    obfs_host="$(get_config_obfs_host)"
    tfo="$(get_config_tfo)"
    write_snell_config "${port}" "${psk}" "${ipv6:-false}" "${dns:-${SNELL_DNS_DEFAULT}}" "${obfs:-off}" "${obfs_host:-}" "${tfo:-false}" "${protocol_version}"
}

rollback_snell_update() {
    local binary_backup="$1"
    local config_backup="$2"
    local version_backup="$3"
    ui_warn "Snell 更新失败，正在恢复旧状态。"
    restore_path_for_rollback "${binary_backup}" "${SNELL_BINARY_PATH}" || true
    restore_path_for_rollback "${config_backup}" "${SNELL_CONFIG_FILE}" || true
    restore_path_for_rollback "${version_backup}" "${SNELL_VERSION_FILE}" || true
    # 回滚后重写服务定义并尝试恢复旧服务，避免留下新旧状态混杂。
    write_systemd_service || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart snell >/dev/null 2>&1 || true
    if systemctl is-active --quiet snell 2>/dev/null; then
        ui_ok "旧 Snell 服务已恢复运行。"
    else
        ui_error "旧 Snell 服务未能自动恢复，请立即手动检查。"
    fi
}

update_snell_server() {
    ui_render_title
    ui_section "更新 Snell Server"
    if [ ! -f "${SNELL_BINARY_PATH}" ]; then
        ui_error "未检测到 Snell Server 二进制，请先安装。"
        pause_screen
        return
    fi

    ensure_dependencies || return 1
    local target_version binary_backup config_backup version_backup
    choose_update_version target_version || return "$?"
    binary_backup="$(backup_path_for_rollback "${SNELL_BINARY_PATH}")" || return 1
    config_backup="$(backup_path_for_rollback "${SNELL_CONFIG_FILE}")" || return 1
    version_backup="$(backup_path_for_rollback "${SNELL_VERSION_FILE}")" || return 1
    if ! download_and_install_snell_binary "${target_version}"; then
        rollback_snell_update "${binary_backup}" "${config_backup}" "${version_backup}"
        pause_screen
        return 1
    fi
    if ! update_config_protocol_version "${target_version}"; then
        rollback_snell_update "${binary_backup}" "${config_backup}" "${version_backup}"
        pause_screen
        return 1
    fi
    if ! write_systemd_service; then
        rollback_snell_update "${binary_backup}" "${config_backup}" "${version_backup}"
        pause_screen
        return 1
    fi
    if ! restart_snell_service; then
        rollback_snell_update "${binary_backup}" "${config_backup}" "${version_backup}"
        pause_screen
        return 1
    fi
    ui_ok "Snell Server 已更新并重启。"
    show_client_config false
    pause_screen
}

write_network_tuning_file() {
    cat <<'EOF' | atomic_replace_file "${SNELL_SYSCTL_FILE}" 644 || return 1
net.core.rmem_default = 262144
net.core.rmem_max = 6291456
net.core.wmem_default = 262144
net.core.wmem_max = 4194304
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
EOF
}

apply_network_tuning_runtime() {
    if check_command_exists modprobe; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    if ! sysctl --system >/dev/null 2>&1; then
        ui_error "sysctl --system 加载失败，网络调优文件已写入但未确认生效。"
        return 1
    fi
    return 0
}

write_network_tuning() {
    write_network_tuning_file || return 1
    apply_network_tuning_runtime || return 1
}

manage_service() {
    ui_render_title
    ui_section "服务控制"
    ui_dim "$(build_status_line)"
    ui_blank
    ui_print "请选择操作："
    ui_blank
    ui_menu_item 1 "启动 Snell"
    ui_menu_item 2 "停止 Snell"
    ui_menu_item 3 "重启 Snell"
    ui_menu_item 0 "返回上一级"
    ui_blank
    ui_dim "输入 0 返回上一级。"
    ui_dim "普通输入：输入 q 取消当前操作。"
    ui_blank
    local choice action_done=true
    ui_read_submenu_choice choice || return "$?"
    case "${choice}" in
        1) start_snell_service || action_done=false ;;
        2) stop_snell_service || action_done=false ;;
        3) restart_snell_service || action_done=false ;;
        *) ui_error "无效选项。"; action_done=false ;;
    esac
    [ "${action_done}" = true ] && ui_ok "服务操作已执行。"
    pause_screen
}

is_tcp_port_listening() {
    local port="$1"
    validate_port "${port}" || return 1
    check_command_exists ss || return 2
    ss -H -tln 2>/dev/null | awk -v port="${port}" '
        {
            local_addr = $4
            sub(/^.*:/, "", local_addr)
            if (local_addr == port) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

validate_snell_service() {
    ui_render_title
    ui_section "运行服务验证"
    local pause_after="${1:-false}" failed=0 port
    port="$(get_config_port 2>/dev/null || true)"

    if [ -f "${SNELL_BINARY_PATH}" ]; then
        ui_ok "二进制存在：${SNELL_BINARY_PATH}"
    else
        ui_warn "未找到二进制：${SNELL_BINARY_PATH}"
        failed=1
    fi

    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        ui_ok "配置存在：${SNELL_CONFIG_FILE}"
    else
        ui_warn "未找到配置：${SNELL_CONFIG_FILE}"
        failed=1
    fi

    if [ -f "${SNELL_SERVICE_FILE}" ]; then
        ui_ok "服务文件存在：${SNELL_SERVICE_FILE}"
    else
        ui_warn "未找到服务文件：${SNELL_SERVICE_FILE}"
        failed=1
    fi

    if systemctl is-enabled --quiet snell 2>/dev/null; then
        ui_ok "systemd 服务已启用。"
    else
        ui_warn "systemd 服务未启用。"
        failed=1
    fi

    if systemctl is-active --quiet snell 2>/dev/null; then
        ui_ok "systemd 服务 active。"
    else
        ui_warn "systemd 服务不是 active。"
        journalctl -u snell -n 30 --no-pager 2>/dev/null || true
        failed=1
    fi

    if [ -n "${port}" ] && check_command_exists ss && is_tcp_port_listening "${port}"; then
        ui_ok "检测到 TCP ${port} 正在监听。"
        ss -tlnp 2>/dev/null | grep -E ":${port}([[:space:]]|$)" || true
    elif [ -n "${port}" ]; then
        ui_warn "未检测到 TCP ${port} 监听。"
        failed=1
    fi

    ui_blank
    if [ "${failed}" -eq 0 ]; then
        ui_ok "核心验证通过。"
    else
        ui_warn "存在需要人工确认的项目，请检查 systemd、端口监听和 Snell 配置。"
    fi
    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

show_status_and_logs() {
    ui_render_title
    ui_section "服务状态"
    local pause_after="${1:-false}"
    ui_kv "包管理器" "${PKG_MANAGER}"
    ui_kv "系统架构" "${ARCH}"
    ui_kv "Snell" "$(service_state)"
    ui_kv "二进制版本" "$(get_installed_binary_version)"
    ui_kv "协议版本" "$(get_config_protocol_version || echo "未知")"
    ui_blank
    ui_info "日志查看命令："
    ui_print "journalctl -u snell -n 80 --no-pager"
    ui_print "systemctl status snell --no-pager"
    ui_blank
    systemctl status snell --no-pager 2>/dev/null || ui_warn "未检测到 snell systemd 服务。"
    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

apply_network_tuning() {
    ui_render_title
    ui_section "应用 / 更新网络优化"
    local pause_after="${1:-false}"
    write_network_tuning || {
        ui_error "网络优化参数写入或加载失败。"
        if [ "${pause_after}" = true ]; then
            pause_screen
        fi
        return 1
    }
    ui_ok "网络优化参数已写入并完成加载：${SNELL_SYSCTL_FILE}。"
    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

uninstall_snell() {
    ui_render_title
    ui_section "卸载 Snell Server"
    ui_warn "此操作将删除以下对象："
    ui_kv "服务" "${SNELL_SERVICE_FILE}"
    ui_kv "旧服务" "${OLD_SNELL_SERVICE_FILE}"
    ui_kv "二进制" "${SNELL_BINARY_PATH}"
    ui_kv "配置目录" "${SNELL_CONFIG_DIR}"
    ui_kv "网络优化" "${SNELL_SYSCTL_FILE}"
    ui_blank
    ui_confirm_token "确认卸载 Snell Server？" "DELETE" || { ui_warn "已取消卸载。"; pause_screen; return 0; }

    systemctl disable --now snell >/dev/null 2>&1 || true
    systemctl disable --now snell-server >/dev/null 2>&1 || true
    rm -f "${SNELL_SERVICE_FILE}" "${OLD_SNELL_SERVICE_FILE}" "${SNELL_BINARY_PATH}" "${SNELL_SYSCTL_FILE}"
    rm -rf "${SNELL_CONFIG_DIR}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ! sysctl --system >/dev/null 2>&1; then
        ui_warn "sysctl 配置重新加载失败，请手动执行 sysctl --system 检查。"
    fi
    ui_ok "Snell Server 已卸载。"
    pause_screen
}

show_main_menu() {
    UI_MENU_CONTEXT=true
    while true; do
        ui_render_title
        ui_dim "$(build_status_line)"
        ui_blank
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "安装 / 覆盖安装 Snell Server"
        ui_menu_item 2 "查看当前配置与客户端连接信息"
        ui_menu_item 3 "修改 Snell 配置"
        ui_menu_item 4 "更新 Snell Server（支持指定版本更新）"
        ui_menu_item 5 "启动 / 停止 / 重启服务"
        ui_menu_item 6 "运行服务验证"
        ui_menu_item 7 "查看服务状态与日志提示"
        ui_menu_item 8 "应用 / 更新网络优化"
        ui_menu_item 9 "检测 / 接管旧 Snell 服务与配置"
        ui_menu_item 10 "卸载 Snell Server"
        ui_menu_item 0 "退出"
        ui_blank
        ui_menu_footer
        ui_blank
        local choice
        ui_read_main_menu_choice choice
        case "${choice}" in
            1) run_menu_action "安装 / 覆盖安装" install_or_reinstall_snell ;;
            2) run_menu_action "查看当前配置" show_client_config true ;;
            3) run_menu_action "修改 Snell 配置" modify_snell_config ;;
            4) run_menu_action "更新 Snell Server" update_snell_server ;;
            5) run_menu_action "服务控制" manage_service ;;
            6) run_menu_action "运行服务验证" validate_snell_service true ;;
            7) run_menu_action "查看服务状态" show_status_and_logs true ;;
            8) run_menu_action "应用 / 更新网络优化" apply_network_tuning true ;;
            9) run_menu_action "检测 / 接管旧 Snell" run_legacy_takeover ;;
            10) run_menu_action "卸载 Snell Server" uninstall_snell ;;
            0) ui_blank; ui_info "已退出。"; exit 0 ;;
            q|Q) ui_warn "主菜单请使用 0 退出脚本。"; sleep 1 ;;
            *) ui_error "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

parse_arguments() {
    COMMAND="menu"
    if [ $# -eq 0 ] && [ -z "${BASH_SOURCE[0]:-}" ]; then
        case "${0:-}" in
            -h|--help|install|view|config|update|service|validate|status|tune|takeover|migrate|uninstall|menu)
                set -- "${0}"
                ;;
        esac
    fi
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            install|view|config|update|service|validate|status|tune|takeover|migrate|uninstall|menu)
                COMMAND="$1"
                shift
                ;;
            *)
                ui_error "未知参数：$1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    ui_init_colors
    init_prompt_input
    parse_arguments "$@"
    require_root
    detect_system_info

    case "${COMMAND}" in
        install) install_or_reinstall_snell ;;
        view) show_client_config false ;;
        config) modify_snell_config ;;
        update) update_snell_server ;;
        service) manage_service ;;
        validate) validate_snell_service false ;;
        status) show_status_and_logs false ;;
        tune) apply_network_tuning false ;;
        takeover|migrate) run_legacy_takeover ;;
        uninstall) uninstall_snell ;;
        menu) show_main_menu ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
