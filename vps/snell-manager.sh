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

set -Eeuo pipefail

SCRIPT_VERSION="2026.05.02-r1"
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

COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"

PKG_MANAGER=""
ARCH=""
PROMPT_FD=0
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

print_title() {
    clear || true
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "============================================================"
    echo "        Snell Server 统一管理脚本"
    echo "        Version: ${SCRIPT_VERSION}"
    echo "============================================================"
    echo -e "${COLOR_RESET}"
}

print_section() { echo; echo -e "${COLOR_BLUE}${COLOR_BOLD}>>> $1${COLOR_RESET}"; }
print_success() { echo -e "${COLOR_GREEN}[成功]${COLOR_RESET} $1"; }
print_warn() { echo -e "${COLOR_YELLOW}[提示]${COLOR_RESET} $1"; }
print_error() { echo -e "${COLOR_RED}[错误]${COLOR_RESET} $1"; }
print_info() { echo -e "${COLOR_CYAN}[信息]${COLOR_RESET} $1"; }
print_dim() { echo -e "${COLOR_DIM}$1${COLOR_RESET}"; }

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
    if [ -r /dev/tty ]; then
        exec 3</dev/tty
        PROMPT_FD=3
    else
        PROMPT_FD=0
    fi
}

read_prompt() {
    local var_name="$1" prompt_text="$2" value
    if ! IFS= read -r -u "${PROMPT_FD}" -p "${prompt_text}" "${var_name}"; then
        echo
        print_error "无法读取交互式输入。请在交互式终端运行脚本。"
        exit 1
    fi
    value="${!var_name//$'\r'/}"
    printf -v "${var_name}" '%s' "${value}"
}

read_secret() {
    local var_name="$1" prompt_text="$2" value
    if [ "${PROMPT_FD}" -eq 3 ] && [ -r /dev/tty ]; then
        IFS= read -r -s -u "${PROMPT_FD}" -p "${prompt_text}" "${var_name}" || {
            echo
            print_error "无法读取密钥输入。"
            exit 1
        }
        echo
    else
        IFS= read -r -s -p "${prompt_text}" "${var_name}" || {
            echo
            print_error "无法读取密钥输入。"
            exit 1
        }
        echo
    fi
    value="${!var_name//$'\r'/}"
    printf -v "${var_name}" '%s' "${value}"
}

pause_screen() {
    local _
    echo
    read_prompt _ "按回车键继续..."
}

confirm_yes_no() {
    local prompt_text="$1" default_answer="${2:-n}" answer=""
    while true; do
        read_prompt answer "${prompt_text} [${default_answer}/$( [ "${default_answer}" = "y" ] && echo n || echo y )]: "
        answer="${answer:-${default_answer}}"
        case "${answer}" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) print_error "请输入 y 或 n。" ;;
        esac
    done
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

check_command_exists() { command -v "$1" >/dev/null 2>&1; }

require_systemd() {
    if ! check_command_exists systemctl; then
        print_error "当前系统未检测到 systemd，无法自动管理 Snell 服务。"
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
        print_error "未找到受支持的包管理器（apk/apt/dnf/yum）。"
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
            print_error "不支持的系统架构：$(uname -m)"
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
        apk) apk add --no-cache "$@" >/dev/null ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update >/dev/null
            apt-get install -y "$@" >/dev/null
            ;;
        dnf) dnf install -y "$@" >/dev/null ;;
        yum) yum install -y "$@" >/dev/null ;;
    esac
}

ensure_dependencies() {
    print_section "检查基础依赖"
    case "${PKG_MANAGER}" in
        apk) install_packages curl openssl unzip ca-certificates iproute2 ;;
        apt) install_packages curl openssl unzip ca-certificates iproute2 ;;
        dnf|yum) install_packages curl openssl unzip ca-certificates iproute ;;
    esac
    print_success "基础依赖已就绪。"
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
    grep -E "^${key}[[:space:]]*=" "${file}" 2>/dev/null \
        | head -n 1 \
        | sed -E 's/^[^=]+=[[:space:]]*//; s/[[:space:]]+$//'
}

get_config_port() {
    local listen
    listen="$(read_ini_value "listen" "${SNELL_CONFIG_FILE}" || true)"
    [ -n "${listen}" ] || return 1
    printf '%s' "${listen##*:}"
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
    elif systemctl is-enabled --quiet snell 2>/dev/null; then
        echo "enabled"
    else
        echo "inactive"
    fi
}

backup_file() {
    local file_path="$1" backup_path
    [ -e "${file_path}" ] || return 0
    backup_path="${file_path}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "${file_path}" "${backup_path}"
    print_success "已备份：${backup_path}"
}

has_legacy_layout() {
    [ -f "${OLD_SNELL_CONFIG_FILE}" ] || [ -f "${OLD_SNELL_SERVICE_FILE}" ]
}

legacy_service_state() {
    if systemctl is-active --quiet snell-server 2>/dev/null; then
        echo "active"
    elif systemctl is-enabled --quiet snell-server 2>/dev/null; then
        echo "enabled"
    else
        echo "inactive"
    fi
}

read_legacy_config() {
    if [ ! -f "${OLD_SNELL_CONFIG_FILE}" ]; then
        print_error "未找到旧配置：${OLD_SNELL_CONFIG_FILE}"
        return 1
    fi

    LEGACY_LISTEN="$(read_ini_value "listen" "${OLD_SNELL_CONFIG_FILE}" || true)"
    LEGACY_PSK="$(read_ini_value "psk" "${OLD_SNELL_CONFIG_FILE}" || true)"
    [ -n "${LEGACY_LISTEN}" ] || { print_error "旧配置缺少 listen 字段。"; return 1; }
    [ -n "${LEGACY_PSK}" ] || { print_error "旧配置缺少 psk 字段。"; return 1; }

    LEGACY_PORT="${LEGACY_LISTEN##*:}"
    validate_port "${LEGACY_PORT}" || { print_error "旧配置中的监听端口无效：${LEGACY_LISTEN}"; return 1; }

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
    print_section "接管计划"
    printf "%s\n" "------------------------------------------------------------"
    printf "%-18s %s\n" "旧服务状态" "${LEGACY_SERVICE_STATE}"
    printf "%-18s %s\n" "旧监听端口" "${LEGACY_PORT}"
    printf "%-18s %s\n" "协议版本" "${LEGACY_PROTOCOL_VERSION}"
    printf "%-18s %s\n" "二进制版本" "${LEGACY_BINARY_VERSION}"
    printf "%-18s %s\n" "IPv6" "${LEGACY_IPV6}"
    printf "%-18s %s\n" "TFO" "${LEGACY_TFO}"
    printf "%-18s %s\n" "obfs" "${LEGACY_OBFS}"
    printf "%s\n" "------------------------------------------------------------"
    echo
    echo "将写入新配置：${SNELL_CONFIG_FILE}"
    echo "将写入新服务：${SNELL_SERVICE_FILE}"
    echo "旧配置和旧服务会在新服务验证成功后改名备份。"
    if [ "${LEGACY_WAS_ACTIVE}" = true ]; then
        print_warn "接管会短暂停止旧 snell-server，再启动新 snell 服务。"
    fi
}

write_config_from_legacy() {
    print_section "生成新配置与服务"
    write_snell_config \
        "${LEGACY_PORT}" \
        "${LEGACY_PSK}" \
        "${LEGACY_IPV6:-false}" \
        "${LEGACY_DNS:-${SNELL_DNS_DEFAULT}}" \
        "${LEGACY_OBFS:-off}" \
        "${LEGACY_OBFS_HOST:-}" \
        "${LEGACY_TFO:-false}" \
        "${LEGACY_PROTOCOL_VERSION:-5}"
    if [ -n "${LEGACY_BINARY_VERSION}" ] && [ "${LEGACY_BINARY_VERSION}" != "unknown" ]; then
        echo "${LEGACY_BINARY_VERSION}" > "${SNELL_VERSION_FILE}"
        chmod 644 "${SNELL_VERSION_FILE}"
    fi
    write_systemd_service
}

start_new_service_for_takeover() {
    print_section "切换到新服务"
    systemctl stop snell >/dev/null 2>&1 || true
    if [ "${LEGACY_WAS_ACTIVE}" = true ]; then
        systemctl stop snell-server >/dev/null 2>&1 || true
    fi
    systemctl enable snell >/dev/null || return 1
    systemctl restart snell || return 1
}

verify_takeover() {
    local failed=0
    print_section "验证新服务"

    if systemctl is-active --quiet snell 2>/dev/null; then
        print_success "新 snell 服务 active。"
    else
        print_error "新 snell 服务未处于 active。"
        failed=1
    fi

    if check_command_exists ss; then
        if is_tcp_port_listening "${LEGACY_PORT}"; then
            print_success "检测到 TCP ${LEGACY_PORT} 正在监听。"
        else
            print_error "未检测到 TCP ${LEGACY_PORT} 监听。"
            failed=1
        fi
    else
        print_warn "缺少 ss 命令，跳过端口监听验证。"
    fi

    if [ -f "${SNELL_CONFIG_FILE}" ] && [ -f "${SNELL_SERVICE_FILE}" ]; then
        print_success "新配置与新服务文件存在。"
    else
        print_error "新配置或新服务文件缺失。"
        failed=1
    fi

    [ "${failed}" -eq 0 ]
}

finalize_legacy_takeover() {
    local backup_suffix
    backup_suffix="$(date +%Y%m%d_%H%M%S)"
    print_section "收敛旧服务"

    systemctl disable snell-server >/dev/null 2>&1 || true
    [ -f "${OLD_SNELL_SERVICE_FILE}" ] && mv "${OLD_SNELL_SERVICE_FILE}" "${OLD_SNELL_SERVICE_FILE}.bak.${backup_suffix}"
    [ -f "${OLD_SNELL_CONFIG_FILE}" ] && mv "${OLD_SNELL_CONFIG_FILE}" "${OLD_SNELL_CONFIG_FILE}.bak.${backup_suffix}"
    [ -f "${OLD_SNELL_VERSION_FILE}" ] && mv "${OLD_SNELL_VERSION_FILE}" "${OLD_SNELL_VERSION_FILE}.bak.${backup_suffix}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    print_success "旧服务和旧配置已备份，新 snell 服务已接管。"
}

rollback_legacy_takeover() {
    print_section "接管失败，执行回滚"
    systemctl disable --now snell >/dev/null 2>&1 || true
    if [ "${LEGACY_WAS_ACTIVE}" = true ] && [ -f "${OLD_SNELL_SERVICE_FILE}" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start snell-server >/dev/null 2>&1 || true
        if systemctl is-active --quiet snell-server 2>/dev/null; then
            print_success "旧 snell-server 服务已恢复运行。"
        else
            print_error "旧 snell-server 服务未能自动恢复，请立即手动检查。"
        fi
    else
        print_warn "旧服务原本不是 active，已停止新 snell 服务。"
    fi
    journalctl -u snell -n 40 --no-pager 2>/dev/null || true
}

run_legacy_takeover() {
    print_title
    print_section "检测 / 接管旧 Snell 服务与配置"
    if ! has_legacy_layout; then
        print_success "未发现旧配置路径或旧服务文件。"
        pause_screen
        return
    fi

    read_legacy_config || { pause_screen; return 1; }
    show_legacy_takeover_plan
    echo
    local answer
    read_prompt answer "确认接管旧 Snell？输入 TAKEOVER 继续： "
    [ "${answer}" = "TAKEOVER" ] || { print_warn "已取消接管。"; pause_screen; return 0; }

    ensure_dependencies
    write_config_from_legacy
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
    print_success "旧 Snell 已安全接管到 snell.service。"
    show_client_config false
    pause_screen
}

run_legacy_migration() {
    run_legacy_takeover "$@"
}

choose_snell_version() {
    local var_name="$1" choice version
    echo "请选择 Snell Server 版本："
    echo "  1) v${SNELL_VERSION_DEFAULT}（默认，v5）"
    echo "  2) v${SNELL_V4_VERSION}（v4）"
    echo "  3) 手动输入版本号"
    while true; do
        read_prompt choice "请输入选项编号（默认 1）： "
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"; return 0 ;;
            2) printf -v "${var_name}" '%s' "${SNELL_V4_VERSION}"; return 0 ;;
            3)
                read_prompt version "请输入版本号（例如 5.0.1）： "
                version="$(normalize_version "${version}")"
                validate_version "${version}" || { print_error "版本号格式无效。"; continue; }
                printf -v "${var_name}" '%s' "${version}"
                return 0
                ;;
            *) print_error "无效选项，请输入 1、2 或 3。" ;;
        esac
    done
}

choose_update_version() {
    local var_name="$1" current_version choice version current_major
    current_version="$(get_installed_binary_version)"
    current_major="$(get_config_protocol_version)"

    echo "请选择更新目标："
    echo "  1) 更新到默认稳定版本 v${SNELL_VERSION_DEFAULT}"
    echo "  2) 指定版本更新"
    if [ "${current_major}" = "4" ]; then
        echo "  3) 从 v4 升级到 v5 默认稳定版本"
    fi
    echo
    print_dim "当前二进制版本：${current_version}；配置协议版本：${current_major:-未知}"

    while true; do
        read_prompt choice "请输入选项编号（默认 1）： "
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"; return 0 ;;
            2)
                read_prompt version "请输入目标版本号（例如 5.0.1）： "
                version="$(normalize_version "${version}")"
                validate_version "${version}" || { print_error "版本号格式无效。"; continue; }
                printf -v "${var_name}" '%s' "${version}"
                return 0
                ;;
            3)
                if [ "${current_major}" = "4" ]; then
                    printf -v "${var_name}" '%s' "${SNELL_VERSION_DEFAULT}"
                    return 0
                fi
                print_error "当前配置不是 v4，不能使用该选项。"
                ;;
            *) print_error "无效选项，请重新输入。" ;;
        esac
    done
}

prompt_port() {
    local var_name="$1" default_port="$2" value
    while true; do
        read_prompt value "请输入 Snell 监听端口（默认 ${default_port}）： "
        value="${value:-${default_port}}"
        validate_port "${value}" || { print_error "端口格式无效，请输入 1-65535 之间的数字。"; continue; }
        if is_port_in_use "${value}" && [ "${value}" != "$(get_config_port 2>/dev/null || true)" ]; then
            print_error "端口 ${value} 已被占用，请更换。"
            continue
        fi
        printf -v "${var_name}" '%s' "${value}"
        return 0
    done
}

prompt_psk() {
    local var_name="$1" current_value="${2:-}" value
    if [ -n "${current_value}" ]; then
        if ! confirm_yes_no "是否修改 PSK？" "n"; then
            printf -v "${var_name}" '%s' "${current_value}"
            return 0
        fi
    fi

    if confirm_yes_no "是否手动指定 PSK？" "n"; then
        while true; do
            read_secret value "请输入 Snell PSK： "
            [ -n "${value}" ] && break
            print_error "PSK 不能为空。"
        done
    else
        value="$(openssl rand -base64 18)"
        print_success "已生成随机 PSK。"
    fi
    printf -v "${var_name}" '%s' "${value}"
}

prompt_boolean() {
    local var_name="$1" prompt_text="$2" default_value="${3:-false}"
    if confirm_yes_no "${prompt_text}" "$( [ "${default_value}" = "true" ] && echo y || echo n )"; then
        printf -v "${var_name}" '%s' "true"
    else
        printf -v "${var_name}" '%s' "false"
    fi
}

prompt_dns() {
    local var_name="$1" default_dns="$2" value
    read_prompt value "请输入 DNS（默认 ${default_dns}）： "
    value="${value:-${default_dns}}"
    printf -v "${var_name}" '%s' "${value}"
}

prompt_obfs() {
    local obfs_var="$1" host_var="$2" current_obfs="${3:-off}" current_host="${4:-}" choice host
    echo "请选择 obfs 设置："
    echo "  1) off（默认）"
    echo "  2) http"
    echo "  3) tls"
    while true; do
        read_prompt choice "请输入选项编号（当前 ${current_obfs:-off}，回车保持）： "
        if [ -z "${choice}" ]; then
            printf -v "${obfs_var}" '%s' "${current_obfs:-off}"
            printf -v "${host_var}" '%s' "${current_host:-}"
            return 0
        fi
        case "${choice}" in
            1) printf -v "${obfs_var}" '%s' "off"; printf -v "${host_var}" '%s' ""; return 0 ;;
            2) printf -v "${obfs_var}" '%s' "http"; break ;;
            3) printf -v "${obfs_var}" '%s' "tls"; break ;;
            *) print_error "无效选项，请输入 1、2 或 3。" ;;
        esac
    done
    read_prompt host "请输入 obfs-host（默认 ${current_host:-${SNELL_OBFS_HOST_DEFAULT}}）： "
    host="${host:-${current_host:-${SNELL_OBFS_HOST_DEFAULT}}}"
    printf -v "${host_var}" '%s' "${host}"
}

build_listen_value() {
    local port="$1" ipv6="$2"
    if [ "${ipv6}" = "true" ]; then
        echo "::0:${port}"
    else
        echo "0.0.0.0:${port}"
    fi
}

download_and_install_snell_binary() {
    local version="$1" download_url temp_dir archive_path
    version="$(normalize_version "${version}")"
    download_url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${ARCH}.zip"
    temp_dir="$(mktemp -d)"
    archive_path="${temp_dir}/snell-server.zip"

    print_info "正在下载 Snell Server v${version} (${ARCH})..."
    if ! curl -fsSL "${download_url}" -o "${archive_path}"; then
        rm -rf "${temp_dir}"
        print_error "下载失败：${download_url}"
        return 1
    fi

    unzip -q "${archive_path}" -d "${temp_dir}"
    if [ ! -f "${temp_dir}/snell-server" ]; then
        rm -rf "${temp_dir}"
        print_error "压缩包中未找到 snell-server 二进制。"
        return 1
    fi

    install -m 0755 "${temp_dir}/snell-server" "${SNELL_BINARY_PATH}"
    mkdir -p "${SNELL_CONFIG_DIR}"
    echo "${version}" > "${SNELL_VERSION_FILE}"
    chmod 644 "${SNELL_VERSION_FILE}"
    rm -rf "${temp_dir}"
    print_success "Snell Server v${version} 已安装到 ${SNELL_BINARY_PATH}。"
}

write_snell_config() {
    local port="$1" psk="$2" ipv6="$3" dns="$4" obfs="$5" obfs_host="$6" tfo="$7" protocol_version="$8" listen
    mkdir -p "${SNELL_CONFIG_DIR}"
    [ -f "${SNELL_CONFIG_FILE}" ] && backup_file "${SNELL_CONFIG_FILE}"
    listen="$(build_listen_value "${port}" "${ipv6}")"

    cat > "${SNELL_CONFIG_FILE}" <<EOF
[snell-server]
listen = ${listen}
psk = ${psk}
ipv6 = ${ipv6}
dns = ${dns}
obfs = ${obfs}
EOF
    if [ "${obfs}" != "off" ]; then
        echo "obfs-host = ${obfs_host}" >> "${SNELL_CONFIG_FILE}"
    fi
    cat >> "${SNELL_CONFIG_FILE}" <<EOF
tfo = ${tfo}
version = ${protocol_version}
EOF
    chmod 600 "${SNELL_CONFIG_FILE}"
    print_success "Snell 配置已写入 ${SNELL_CONFIG_FILE}。"
}

write_systemd_service() {
    cat > "${SNELL_SERVICE_FILE}" <<EOF
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
    systemctl daemon-reload
    print_success "systemd 服务已写入 ${SNELL_SERVICE_FILE}。"
}

start_snell_service() {
    systemctl start snell
}

stop_snell_service() {
    systemctl stop snell >/dev/null 2>&1 || true
}

restart_snell_service() {
    systemctl restart snell
}

enable_and_restart_service() {
    systemctl enable snell >/dev/null
    restart_snell_service
}

install_or_reinstall_snell() {
    print_title
    print_section "安装 / 覆盖安装 Snell Server"
    if has_legacy_layout; then
        print_warn "检测到旧 Snell 布局。已有旧 VPS 建议优先使用菜单中的“检测 / 接管旧 Snell 服务与配置”。"
        confirm_yes_no "是否仍然继续执行全新安装 / 覆盖安装？" "n" || {
            print_warn "已取消安装。"
            pause_screen
            return
        }
    fi
    ensure_dependencies

    if [ -f "${SNELL_CONFIG_FILE}" ] && ! confirm_yes_no "检测到已有配置，是否覆盖安装？" "n"; then
        print_warn "已取消。"
        pause_screen
        return
    fi

    local version protocol_version port psk ipv6 dns obfs obfs_host tfo
    choose_snell_version version
    protocol_version="$(snell_major_version "${version}")"
    prompt_port port "${SNELL_PORT_DEFAULT}"
    prompt_psk psk
    prompt_boolean ipv6 "是否启用 IPv6 监听？" "n"
    prompt_dns dns "${SNELL_DNS_DEFAULT}"
    prompt_boolean tfo "是否启用 TFO？" "n"
    prompt_obfs obfs obfs_host "off" ""

    download_and_install_snell_binary "${version}"
    write_snell_config "${port}" "${psk}" "${ipv6}" "${dns}" "${obfs}" "${obfs_host}" "${tfo}" "${protocol_version}"
    write_systemd_service
    if [ "${tfo}" = "true" ]; then
        write_network_tuning
        print_success "已同步应用 TFO 与基础网络优化参数。"
    fi
    enable_and_restart_service

    print_success "Snell Server 已安装并启动。"
    show_client_config false
    pause_screen
}

get_server_ip() {
    curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null \
        || curl -fsS -6 -m 5 https://api64.ipify.org 2>/dev/null \
        || echo "SERVER_IP"
}

show_client_config() {
    local pause_after="${1:-true}" port psk ipv6 dns obfs obfs_host tfo protocol_version binary_version server_ip host client_line
    print_section "当前配置"
    if [ ! -f "${SNELL_CONFIG_FILE}" ]; then
        print_warn "尚未安装或尚未生成 Snell 配置。"
        [ "${pause_after}" = true ] && pause_screen
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

    printf "%s\n" "------------------------------------------------------------"
    printf "%-18s %s\n" "服务状态" "$(service_state)"
    printf "%-18s %s\n" "监听端口" "${port}"
    printf "%-18s %s\n" "协议版本" "${protocol_version:-未知}"
    printf "%-18s %s\n" "二进制版本" "${binary_version}"
    printf "%-18s %s\n" "IPv6" "${ipv6:-false}"
    printf "%-18s %s\n" "TFO" "${tfo:-false}"
    printf "%-18s %s\n" "obfs" "${obfs:-off}"
    printf "%-18s %s\n" "DNS" "${dns:-未设置}"
    printf "%s\n" "------------------------------------------------------------"
    echo
    print_info "Surge 配置片段："
    client_line="${host} = snell, ${server_ip}, ${port}, psk=${psk}, version=${protocol_version:-5}, tfo=${tfo:-false}, reuse=true, ecn=true"
    if [ "${obfs:-off}" != "off" ]; then
        client_line="${client_line}, obfs=${obfs}, obfs-host=${obfs_host}"
    fi
    echo "${client_line}"

    [ "${pause_after}" = true ] && pause_screen
}

modify_snell_config() {
    print_title
    print_section "修改 Snell 配置"
    if [ ! -f "${SNELL_CONFIG_FILE}" ]; then
        print_error "尚未安装或尚未生成 Snell 配置。"
        pause_screen
        return
    fi

    local current_port current_psk current_ipv6 current_dns current_obfs current_obfs_host current_tfo current_protocol
    local port psk ipv6 dns obfs obfs_host tfo protocol_version
    current_port="$(get_config_port || echo "${SNELL_PORT_DEFAULT}")"
    current_psk="$(get_config_psk)"
    current_ipv6="$(get_config_ipv6)"
    current_dns="$(get_config_dns)"
    current_obfs="$(get_config_obfs)"
    current_obfs_host="$(get_config_obfs_host)"
    current_tfo="$(get_config_tfo)"
    current_protocol="$(get_config_protocol_version)"

    prompt_port port "${current_port}"
    prompt_psk psk "${current_psk}"
    prompt_boolean ipv6 "是否启用 IPv6 监听？" "${current_ipv6:-false}"
    prompt_dns dns "${current_dns:-${SNELL_DNS_DEFAULT}}"
    prompt_boolean tfo "是否启用 TFO？" "${current_tfo:-false}"
    prompt_obfs obfs obfs_host "${current_obfs:-off}" "${current_obfs_host:-}"
    protocol_version="${current_protocol:-5}"

    write_snell_config "${port}" "${psk}" "${ipv6}" "${dns}" "${obfs}" "${obfs_host}" "${tfo}" "${protocol_version}"
    restart_snell_service
    print_success "配置已更新并重启服务。"
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

update_snell_server() {
    print_title
    print_section "更新 Snell Server"
    if [ ! -f "${SNELL_BINARY_PATH}" ]; then
        print_error "未检测到 Snell Server 二进制，请先安装。"
        pause_screen
        return
    fi

    ensure_dependencies
    local target_version
    choose_update_version target_version
    download_and_install_snell_binary "${target_version}"
    update_config_protocol_version "${target_version}"
    write_systemd_service
    restart_snell_service
    print_success "Snell Server 已更新并重启。"
    show_client_config false
    pause_screen
}

write_network_tuning() {
    cat > "${SNELL_SYSCTL_FILE}" <<'EOF'
net.core.rmem_default = 262144
net.core.rmem_max = 6291456
net.core.wmem_default = 262144
net.core.wmem_max = 4194304
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
EOF
    if check_command_exists modprobe; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
}

manage_service() {
    print_title
    print_section "服务控制"
    echo "  1) 启动 Snell"
    echo "  2) 停止 Snell"
    echo "  3) 重启 Snell"
    echo "  0) 返回"
    echo
    local choice action_done=true
    read_prompt choice "请输入选项编号： "
    case "${choice}" in
        1) start_snell_service || action_done=false ;;
        2) stop_snell_service ;;
        3) restart_snell_service || action_done=false ;;
        0) return ;;
        *) print_error "无效选项。"; action_done=false ;;
    esac
    [ "${action_done}" = true ] && print_success "服务操作已执行。"
    pause_screen
}

is_tcp_port_listening() {
    local port="$1"
    check_command_exists ss || return 2
    ss -H -tlnp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
}

validate_snell_service() {
    print_title
    print_section "运行服务验证"
    local failed=0 port
    port="$(get_config_port 2>/dev/null || true)"

    [ -f "${SNELL_BINARY_PATH}" ] && print_success "二进制存在：${SNELL_BINARY_PATH}" || { print_warn "未找到二进制：${SNELL_BINARY_PATH}"; failed=1; }
    [ -f "${SNELL_CONFIG_FILE}" ] && print_success "配置存在：${SNELL_CONFIG_FILE}" || { print_warn "未找到配置：${SNELL_CONFIG_FILE}"; failed=1; }
    [ -f "${SNELL_SERVICE_FILE}" ] && print_success "服务文件存在：${SNELL_SERVICE_FILE}" || { print_warn "未找到服务文件：${SNELL_SERVICE_FILE}"; failed=1; }

    if systemctl is-enabled --quiet snell 2>/dev/null; then
        print_success "systemd 服务已启用。"
    else
        print_warn "systemd 服务未启用。"
        failed=1
    fi

    if systemctl is-active --quiet snell 2>/dev/null; then
        print_success "systemd 服务 active。"
    else
        print_warn "systemd 服务不是 active。"
        journalctl -u snell -n 30 --no-pager 2>/dev/null || true
        failed=1
    fi

    if [ -n "${port}" ] && check_command_exists ss && is_tcp_port_listening "${port}"; then
        print_success "检测到 TCP ${port} 正在监听。"
        ss -tlnp 2>/dev/null | grep -E ":${port}([[:space:]]|$)" || true
    elif [ -n "${port}" ]; then
        print_warn "未检测到 TCP ${port} 监听。"
        failed=1
    fi

    echo
    if [ "${failed}" -eq 0 ]; then
        print_success "核心验证通过。"
    else
        print_warn "存在需要人工确认的项目，请检查 systemd、端口监听和 Snell 配置。"
    fi
    pause_screen
}

show_status_and_logs() {
    print_title
    print_section "服务状态"
    printf "%-18s %s\n" "包管理器" "${PKG_MANAGER}"
    printf "%-18s %s\n" "系统架构" "${ARCH}"
    printf "%-18s %s\n" "Snell" "$(service_state)"
    printf "%-18s %s\n" "二进制版本" "$(get_installed_binary_version)"
    printf "%-18s %s\n" "协议版本" "$(get_config_protocol_version || echo "未知")"
    echo
    print_info "日志查看命令："
    echo "journalctl -u snell -n 80 --no-pager"
    echo "systemctl status snell --no-pager"
    echo
    systemctl status snell --no-pager 2>/dev/null || print_warn "未检测到 snell systemd 服务。"
    pause_screen
}

apply_network_tuning() {
    print_title
    print_section "应用 / 更新网络优化"
    write_network_tuning
    print_success "网络优化参数已写入 ${SNELL_SYSCTL_FILE}。"
    pause_screen
}

uninstall_snell() {
    print_title
    print_section "卸载 Snell Server"
    echo "即将删除："
    echo "  服务：${SNELL_SERVICE_FILE}"
    echo "  旧服务：${OLD_SNELL_SERVICE_FILE}"
    echo "  二进制：${SNELL_BINARY_PATH}"
    echo "  配置目录：${SNELL_CONFIG_DIR}"
    echo "  网络优化：${SNELL_SYSCTL_FILE}"
    echo
    local answer
    read_prompt answer "确认卸载 Snell Server？输入 DELETE 继续： "
    [ "${answer}" = "DELETE" ] || { print_warn "已取消卸载。"; pause_screen; return 0; }

    systemctl disable --now snell >/dev/null 2>&1 || true
    systemctl disable --now snell-server >/dev/null 2>&1 || true
    rm -f "${SNELL_SERVICE_FILE}" "${OLD_SNELL_SERVICE_FILE}" "${SNELL_BINARY_PATH}" "${SNELL_SYSCTL_FILE}"
    rm -rf "${SNELL_CONFIG_DIR}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    print_success "Snell Server 已卸载。"
    pause_screen
}

show_main_menu() {
    while true; do
        print_title
        echo "请选择操作："
        echo
        echo "  1) 安装 / 覆盖安装 Snell Server"
        echo "  2) 查看当前配置与客户端连接信息"
        echo "  3) 修改 Snell 配置"
        echo "  4) 更新 Snell Server（支持指定版本更新）"
        echo "  5) 启动 / 停止 / 重启服务"
        echo "  6) 运行服务验证"
        echo "  7) 查看服务状态与日志提示"
        echo "  8) 应用 / 更新网络优化"
        echo "  9) 检测 / 接管旧 Snell 服务与配置"
        echo " 10) 卸载 Snell Server"
        echo "  0) 退出"
        echo
        if has_legacy_layout; then
            print_dim "Snell 状态: $(service_state) | 二进制版本: $(get_installed_binary_version) | 检测到旧 Snell 布局"
        else
            print_dim "Snell 状态: $(service_state) | 二进制版本: $(get_installed_binary_version)"
        fi
        echo
        local choice
        read_prompt choice "请输入选项编号： "
        case "${choice}" in
            1) install_or_reinstall_snell ;;
            2) show_client_config true ;;
            3) modify_snell_config ;;
            4) update_snell_server ;;
            5) manage_service ;;
            6) validate_snell_service ;;
            7) show_status_and_logs ;;
            8) apply_network_tuning ;;
            9) run_legacy_takeover ;;
            10) uninstall_snell ;;
            0) echo; print_info "已退出。"; exit 0 ;;
            *) print_error "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

parse_arguments() {
    COMMAND="menu"
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
                print_error "未知参数：$1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    require_root
    init_prompt_input
    detect_system_info

    case "${COMMAND}" in
        install) install_or_reinstall_snell ;;
        view) show_client_config true ;;
        config) modify_snell_config ;;
        update) update_snell_server ;;
        service) manage_service ;;
        validate) validate_snell_service ;;
        status) show_status_and_logs ;;
        tune) apply_network_tuning ;;
        takeover|migrate) run_legacy_takeover ;;
        uninstall) uninstall_snell ;;
        menu) show_main_menu ;;
    esac
}

main "$@"
