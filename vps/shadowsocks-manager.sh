#!/usr/bin/env bash
# ==============================================================================
# Shadowsocks-Rust 统一管理脚本
# ------------------------------------------------------------------------------
# 作用：
#   - 安装、更新、配置、查询 Shadowsocks-Rust 服务端。
#   - 可选安装 Shadow-TLS v3 前置服务。
#   - 统一替代旧的 install_ss.sh 与 install_ss_stls.sh。
#   - 保持中文输出、清晰菜单、状态表格和安全默认值。
#
# 使用：
#   chmod +x shadowsocks-manager.sh
#   sudo ./shadowsocks-manager.sh
#   sudo ./shadowsocks-manager.sh --latest
# ==============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2026.05.02-r1"
SS_VERSION_DEFAULT="1.24.0"
SHADOW_TLS_VERSION_DEFAULT="v0.2.25"
SHADOW_TLS_SNI_DEFAULT="gateway.icloud.com"

INSTALL_DIR="/opt/ss-rust"
SS_CONFIG_FILE="${INSTALL_DIR}/config.json"
SS_BINARY="${INSTALL_DIR}/ssserver"
SYSTEMD_SS_SERVICE="/etc/systemd/system/ss-rust.service"
OPENRC_SS_SERVICE="/etc/init.d/ss-rust"
SHADOW_TLS_BINARY="/usr/local/bin/shadow-tls"
SHADOW_TLS_ENV_FILE="${INSTALL_DIR}/shadow-tls.env"
SYSTEMD_SHADOW_TLS_SERVICE="/etc/systemd/system/shadow-tls.service"

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

SERVICE_MANAGER=""
PKG_MANAGER=""
ARCH=""
IS_ALPINE=false
FETCH_LATEST=false
SS_VERSION="${SS_VERSION_DEFAULT}"
SHADOW_TLS_VERSION="${SHADOW_TLS_VERSION_DEFAULT}"
UI_PROMPT_FD=0
PROMPT_FD=0
UI_PAUSE_ENABLED=false
UI_RETURN_TO_MENU=130
CANCEL_STATUS="${UI_RETURN_TO_MENU}"

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
ui_blank() { printf '\n'; }
ui_print() { printf '%b\n' "$*"; }
ui_section() { printf '\n%b\n' "${UI_COLOR_BLUE}${UI_COLOR_BOLD}>>> $*${UI_COLOR_RESET}"; }

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

ui_center_line() {
    local text="$1" width padding_left padding_right
    width="$(ui_text_width "${text}")"
    if (( width >= UI_TITLE_WIDTH )); then
        printf '%s\n' "${text}"
        return 0
    fi
    padding_left=$(((UI_TITLE_WIDTH - width) / 2))
    padding_right=$((UI_TITLE_WIDTH - width - padding_left))
    printf '%*s%s%*s\n' "${padding_left}" "" "${text}" "${padding_right}" ""
}

ui_title() {
    local title="$1" version="${2:-}" border=""
    printf -v border '%*s' "${UI_TITLE_WIDTH}" ""
    border="${border// /=}"
    printf '%b' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}"
    printf '%s\n' "${border}"
    ui_center_line "${title}"
    if [[ -n "${version}" ]]; then
        ui_center_line "Version: ${version}"
    fi
    printf '%s\n' "${border}"
    printf '%b' "${UI_COLOR_RESET}"
}

ui_clear_and_title() {
    ui_clear
    ui_title "Shadowsocks-Rust 统一管理脚本" "${SCRIPT_VERSION}"
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
        ui_error "无法读取密码输入。"
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
    [[ "${!__target}" == "0" ]] && return "${UI_RETURN_TO_MENU}"
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

ui_confirm_token() {
    local prompt="$1" token="$2" answer
    ui_read_raw answer "${prompt} 输入 ${token} 继续： "
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

ui_input_hint() {
    ui_dim "普通输入：q 取消当前操作并返回上一级。"
}

ui_default_hint() {
    ui_dim "回车使用默认值，q 取消。"
}

ui_menu_footer() {
    ui_dim "主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。"
    ui_dim "普通输入：输入 q 取消当前操作。"
}

print_title() { ui_clear_and_title; }
print_section() { ui_section "$@"; }
print_success() { ui_ok "$@"; }
print_warn() { ui_warn "$@"; }
print_error() { ui_error "$@"; }
print_info() { ui_info "$@"; }
print_dim() { ui_dim "$@"; }

cancel_to_previous_menu() {
    ui_warn "已取消，返回上一级菜单。"
    pause_screen
}

show_help() {
    cat <<'EOF'
Shadowsocks-Rust 统一管理脚本

用法：
  sudo bash shadowsocks-manager.sh [options] [command]

Commands:
  install      安装 / 覆盖安装 Shadowsocks-Rust
  stls         安装 / 配置 Shadow-TLS
  view         查看当前配置和客户端连接信息
  update       更新 Shadowsocks-Rust / Shadow-TLS
  uninstall    卸载 Shadowsocks-Rust / Shadow-TLS
  status       查看服务状态和日志提示
  menu         打开交互式管理菜单（默认）

Options:
  --latest     启动时从 GitHub 获取最新稳定版本
  -h, --help   显示帮助
EOF
}

init_prompt_input() {
    ui_init_prompt_input
}

read_prompt() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_read_or_cancel "$@"
}

read_secret() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_read_secret_or_cancel "$@"
}

pause_screen() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_pause
}

confirm_yes_no() {
    UI_PROMPT_FD="${PROMPT_FD}"
    ui_confirm "$@"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

check_command_exists() { command -v "$1" >/dev/null 2>&1; }

download_file() {
    local url="$1" output="$2"
    curl --fail --location --show-error --proto '=https' --tlsv1.2 "${url}" -o "${output}"
}

print_file_sha256() {
    local file="$1" digest
    if check_command_exists sha256sum; then
        digest="$(sha256sum "${file}" | awk '{print $1}')"
        print_dim "下载文件 SHA256: ${digest}"
    fi
}

detect_service_manager() {
    if check_command_exists systemctl; then
        SERVICE_MANAGER="systemd"
    elif check_command_exists rc-service; then
        SERVICE_MANAGER="openrc"
    else
        print_error "未找到受支持的服务管理器（systemd/openrc）。"
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

detect_system_info() {
    detect_service_manager
    detect_package_manager
    ARCH="$(uname -m)"
    if [ -f /etc/alpine-release ]; then
        IS_ALPINE=true
    else
        IS_ALPINE=false
    fi
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
    local packages=()
    if [ "${PKG_MANAGER}" = "apt" ]; then
        packages=(curl wget tar openssl ca-certificates net-tools xz-utils coreutils jq)
    else
        packages=(curl wget tar openssl ca-certificates net-tools xz coreutils jq)
    fi
    install_packages "${packages[@]}"
    print_success "基础依赖已就绪。"
}

fetch_latest_versions_if_needed() {
    [ "${FETCH_LATEST}" = true ] || return 0
    print_section "获取最新版本"

    if ! check_command_exists curl; then
        print_warn "curl 不可用，跳过最新版本查询。"
        return 0
    fi

    local ss_tag shadow_tls_tag
    ss_tag="$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 \
        | sed -E 's/.*"v?([^"]+)".*/\1/' || true)"
    shadow_tls_tag="$(curl -fsSL https://api.github.com/repos/ihciah/shadow-tls/releases/latest 2>/dev/null \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 \
        | sed -E 's/.*"([^"]+)".*/\1/' || true)"

    if [ -n "${ss_tag}" ]; then
        SS_VERSION="${ss_tag}"
        print_success "Shadowsocks-Rust 最新版本：v${SS_VERSION}"
    else
        print_warn "无法获取 Shadowsocks-Rust 最新版本，使用默认 v${SS_VERSION}。"
    fi

    if [ -n "${shadow_tls_tag}" ]; then
        SHADOW_TLS_VERSION="${shadow_tls_tag}"
        print_success "Shadow-TLS 最新版本：${SHADOW_TLS_VERSION}"
    else
        print_warn "无法获取 Shadow-TLS 最新版本，使用默认 ${SHADOW_TLS_VERSION}。"
    fi
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

validate_safe_env_value() {
    local value="$1"
    [[ "${value}" =~ ^[A-Za-z0-9._:/=@,+-]*$ ]]
}

validate_sni() {
    local value="$1"
    [[ "${value}" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "${value}" == *.* ]]
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

prompt_port() {
    local var_name="$1" prompt_text="$2" allow_random="${3:-false}" value=""
    ui_blank
    while true; do
        read_prompt value "${prompt_text}" || return "$?"
        if [ -z "${value}" ] && [ "${allow_random}" = true ]; then
            while true; do
                value="$(shuf -i 10000-60000 -n 1)"
                is_port_in_use "${value}" || break
            done
            print_info "已分配随机端口：${value}"
            printf -v "${var_name}" '%s' "${value}"
            return 0
        fi

        validate_port "${value}" || { print_error "端口格式无效，请输入 1-65535 之间的数字。"; continue; }
        if is_port_in_use "${value}"; then
            print_error "端口 ${value} 已被占用，请更换。"
            continue
        fi
        printf -v "${var_name}" '%s' "${value}"
        return 0
    done
}

choose_method() {
    local var_name="$1" choice=""
    ui_blank
    ui_print "请选择 Shadowsocks 加密方法："
    ui_blank
    ui_menu_item 1 "2022-blake3-aes-128-gcm（推荐，24 字符 Base64 密码）"
    ui_menu_item 2 "2022-blake3-aes-256-gcm（44 字符 Base64 密码）"
    ui_menu_item 0 "返回上一级"
    ui_blank
    ui_default_hint
    ui_blank
    while true; do
        read_prompt choice "请输入选项编号（默认 1，0 返回）： " || return "$?"
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "2022-blake3-aes-128-gcm"; return 0 ;;
            2) printf -v "${var_name}" '%s' "2022-blake3-aes-256-gcm"; return 0 ;;
            0) return "${CANCEL_STATUS}" ;;
            q|Q) return "${CANCEL_STATUS}" ;;
            *) print_error "无效选项，请输入 1、2 或 0。" ;;
        esac
    done
}

method_password_length() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 24 ;;
        2022-blake3-aes-256-gcm) echo 44 ;;
        *) echo 0 ;;
    esac
}

generate_password_for_method() {
    case "$1" in
        2022-blake3-aes-128-gcm) openssl rand -base64 16 ;;
        2022-blake3-aes-256-gcm) openssl rand -base64 32 ;;
        *) openssl rand -base64 16 ;;
    esac
}

prompt_password() {
  local -n output_password_ref="$1"
  local method="$2"
  local expected_len=""
  local input_password=""

  expected_len="$(method_password_length "${method}")"

  ui_blank
  if confirm_yes_no "是否手动指定 Shadowsocks 密码？" "n"; then
    ui_blank
    while true; do
      read_secret input_password "请输入 Shadowsocks 密码（${expected_len} 字符 Base64，q 取消）： " || return "$?"

      if [ "${#input_password}" -ne "${expected_len}" ]; then
        print_error "密码长度不符合 ${method} 要求，应为 ${expected_len} 字符。"
        continue
      fi

      if [[ ! "${input_password}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
        print_error "密码必须是 Base64 字符串。"
        continue
      fi

      # shellcheck disable=SC2034 # nameref output assigned for caller.
      output_password_ref="${input_password}"
      return 0
    done
  else
    local confirm_status=$?
    [ "${confirm_status}" -eq "${CANCEL_STATUS}" ] && return "${CANCEL_STATUS}"
  fi

  # shellcheck disable=SC2034 # nameref output assigned for caller.
  output_password_ref="$(generate_password_for_method "${method}")"
  print_success "已生成符合 ${method} 要求的随机密码。"
}

get_ss_package_name() {
    local version="$1" arch="$2" suffix=""
    if [ "${IS_ALPINE}" = true ]; then
        case "${arch}" in
            x86_64) suffix="x86_64-unknown-linux-musl.tar.xz" ;;
            aarch64) suffix="aarch64-unknown-linux-musl.tar.xz" ;;
            *) return 1 ;;
        esac
    else
        case "${arch}" in
            x86_64) suffix="x86_64-unknown-linux-gnu.tar.xz" ;;
            aarch64) suffix="aarch64-unknown-linux-gnu.tar.xz" ;;
            *) return 1 ;;
        esac
    fi
    echo "shadowsocks-v${version}.${suffix}"
}

get_shadow_tls_binary_name() {
    case "${ARCH}" in
        x86_64) echo "shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64|arm*) echo "shadow-tls-arm-unknown-linux-musleabi" ;;
        *) return 1 ;;
    esac
}

download_and_install_ss_binary() {
    local package_name temp_dir package_url
    package_name="$(get_ss_package_name "${SS_VERSION}" "${ARCH}")" || {
        print_error "当前架构不支持 Shadowsocks-Rust 自动安装：${ARCH}"
        return 1
    }
    package_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${package_name}"
    temp_dir="$(mktemp -d)"

    print_info "正在下载 Shadowsocks-Rust v${SS_VERSION}..."
    if ! download_file "${package_url}" "${temp_dir}/${package_name}"; then
        rm -rf "${temp_dir}"
        print_error "下载失败：${package_url}"
        return 1
    fi
    print_file_sha256 "${temp_dir}/${package_name}"

    if ! tar -xf "${temp_dir}/${package_name}" -C "${temp_dir}"; then
        rm -rf "${temp_dir}"
        print_error "解压失败：${package_name}"
        return 1
    fi
    if [ ! -f "${temp_dir}/ssserver" ]; then
        rm -rf "${temp_dir}"
        print_error "压缩包中未找到 ssserver。"
        return 1
    fi

    mkdir -p "${INSTALL_DIR}"
    if ! install -m 0755 "${temp_dir}/ssserver" "${SS_BINARY}"; then
        rm -rf "${temp_dir}"
        print_error "安装 ssserver 失败：${SS_BINARY}"
        return 1
    fi
    rm -rf "${temp_dir}"
    print_success "Shadowsocks-Rust 核心已安装到 ${SS_BINARY}。"
}

write_ss_config() {
    local port="$1" password="$2" method="$3"
    local escaped_password escaped_method
    validate_port "${port}" || { print_error "Shadowsocks 端口无效，未写入配置。"; return 1; }
    escaped_password="$(json_escape "${password}")"
    escaped_method="$(json_escape "${method}")"
    mkdir -p "${INSTALL_DIR}"
    cat > "${SS_CONFIG_FILE}" <<EOF
{
    "server": "::",
    "server_port": ${port},
    "password": "${escaped_password}",
    "method": "${escaped_method}",
    "mode": "tcp_and_udp"
}
EOF
    chmod 600 "${SS_CONFIG_FILE}"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "${value}"
}

read_json_value() {
    local key="$1" file="$2"
    [ -f "${file}" ] || return 1
    if check_command_exists jq; then
        jq -er --arg key "${key}" '.[$key] // empty' "${file}" 2>/dev/null
        return $?
    fi
    grep -E "\"${key}\"[[:space:]]*:" "${file}" \
        | head -n 1 \
        | sed -E 's/.*:[[:space:]]*"?([^",]+)"?.*/\1/'
}

get_ss_port() { read_json_value "server_port" "${SS_CONFIG_FILE}" || true; }
get_ss_password() { read_json_value "password" "${SS_CONFIG_FILE}" || true; }
get_ss_method() { read_json_value "method" "${SS_CONFIG_FILE}" || true; }

write_ss_service() {
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        cat > "${SYSTEMD_SS_SERVICE}" <<EOF
[Unit]
Description=Shadowsocks Rust Secure Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_BINARY} -c ${SS_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ss-rust >/dev/null
    else
        cat > "${OPENRC_SS_SERVICE}" <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust Secure Server"
command="${SS_BINARY}"
command_args="-c ${SS_CONFIG_FILE}"
command_background="yes"
pidfile="/run/ss-rust.pid"
output_log="/var/log/ss-rust.log"
error_log="/var/log/ss-rust-error.log"

depend() {
    need net
    after network
}
EOF
        chmod +x "${OPENRC_SS_SERVICE}"
        rc-update add ss-rust default >/dev/null
        rc-service ss-rust restart >/dev/null
    fi
}

restart_ss_service() {
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl restart ss-rust
    else
        rc-service ss-rust restart
    fi
}

start_ss_service() {
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl start ss-rust
    else
        rc-service ss-rust start
    fi
}

stop_ss_service() {
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl stop ss-rust >/dev/null 2>&1 || true
    else
        rc-service ss-rust stop >/dev/null 2>&1 || true
    fi
}

ss_service_state() {
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        if systemctl is-active --quiet ss-rust 2>/dev/null; then
            echo "active"
        elif systemctl is-enabled --quiet ss-rust 2>/dev/null; then
            echo "enabled"
        else
            echo "inactive"
        fi
    else
        rc-service ss-rust status >/dev/null 2>&1 && echo "active" || echo "inactive"
    fi
}

shadow_tls_service_state() {
    if [ "${SERVICE_MANAGER}" != "systemd" ]; then
        echo "unsupported"
    elif systemctl is-active --quiet shadow-tls 2>/dev/null; then
        echo "active"
    elif systemctl is-enabled --quiet shadow-tls 2>/dev/null; then
        echo "enabled"
    else
        echo "inactive"
    fi
}

build_status_line() {
    local manager="${SERVICE_MANAGER:-unknown}" arch="${ARCH:-unknown}"
    printf 'SS: %s | Shadow-TLS: %s | Manager: %s | Arch: %s' \
        "$(ss_service_state)" "$(shadow_tls_service_state)" "${manager:-unknown}" "${arch:-unknown}"
}

show_ss_config_change_summary() {
    local title="$1" port="$2" method="$3" action="${4:-写入配置并重启 ss-rust 服务}"
    ui_section "${title}"
    ui_kv "监听端口" "${port}"
    ui_kv "加密方法" "${method}"
    ui_warn "确认后将${action}；Shadowsocks 密码不会在摘要中显示。"
}

show_shadow_tls_change_summary() {
    local title="$1" ss_port="$2" stls_port="$3" stls_sni="$4"
    ui_section "${title}"
    ui_kv "后端 SS 端口" "${ss_port}"
    ui_kv "Shadow-TLS 端口" "${stls_port}"
    ui_kv "Shadow-TLS SNI" "${stls_sni}"
    ui_warn "确认后将写入 Shadow-TLS 配置并重启服务；Shadow-TLS 密码不会在摘要中显示。"
}

install_or_reinstall_ss() {
    print_title
    print_section "安装 / 覆盖安装 Shadowsocks-Rust"
    ensure_dependencies || { pause_screen; return 1; }
    fetch_latest_versions_if_needed

    if [ -d "${INSTALL_DIR}" ]; then
        local overwrite_status=0
        ui_blank
        confirm_yes_no "检测到已有安装，是否覆盖 Shadowsocks 配置？" "n" || overwrite_status=$?
        if [ "${overwrite_status}" -ne 0 ]; then
            cancel_to_previous_menu
            return
        fi
    fi

    local port method password
    prompt_port port "请输入 Shadowsocks 监听端口（回车随机，q 取消）： " true || { cancel_to_previous_menu; return; }
    choose_method method || { cancel_to_previous_menu; return; }
    prompt_password password "${method}" || { cancel_to_previous_menu; return; }

    show_ss_config_change_summary "确认安装参数" "${port}" "${method}" "安装核心、写入配置并启动 ss-rust 服务"
    local install_confirm_status=0
    ui_blank
    confirm_yes_no "确认写入配置并启动服务？" "y" || install_confirm_status=$?
    if [ "${install_confirm_status}" -eq "${CANCEL_STATUS}" ]; then
        cancel_to_previous_menu
        return
    fi
    if [ "${install_confirm_status}" -ne 0 ]; then
        ui_warn "已取消安装。"
        pause_screen
        return
    fi

    download_and_install_ss_binary || { pause_screen; return 1; }
    write_ss_config "${port}" "${password}" "${method}" || { pause_screen; return 1; }
    write_ss_service || { pause_screen; return 1; }

    print_success "Shadowsocks-Rust 已安装并启动。"
    show_client_config false
    pause_screen
}

download_and_install_shadow_tls_binary() {
    local binary_name binary_url temp_file
    binary_name="$(get_shadow_tls_binary_name)" || {
        print_error "当前架构不支持 Shadow-TLS 自动安装：${ARCH}"
        return 1
    }
    binary_url="https://github.com/ihciah/shadow-tls/releases/download/${SHADOW_TLS_VERSION}/${binary_name}"
    temp_file="$(mktemp)"

    print_info "正在下载 Shadow-TLS ${SHADOW_TLS_VERSION}..."
    if ! download_file "${binary_url}" "${temp_file}"; then
        rm -f "${temp_file}"
        print_error "下载失败：${binary_url}"
        return 1
    fi
    print_file_sha256 "${temp_file}"

    if ! install -m 0755 "${temp_file}" "${SHADOW_TLS_BINARY}"; then
        rm -f "${temp_file}"
        print_error "安装 Shadow-TLS 失败：${SHADOW_TLS_BINARY}"
        return 1
    fi
    rm -f "${temp_file}"
    print_success "Shadow-TLS 已安装到 ${SHADOW_TLS_BINARY}。"
}

write_shadow_tls_env() {
    local ss_port="$1" stls_port="$2" stls_sni="$3" stls_password="$4"
    validate_port "${ss_port}" || { print_error "Shadowsocks 端口无效，未写入 Shadow-TLS 配置。"; return 1; }
    validate_port "${stls_port}" || { print_error "Shadow-TLS 端口无效，未写入配置。"; return 1; }
    validate_sni "${stls_sni}" || { print_error "Shadow-TLS SNI 格式无效，未写入配置。"; return 1; }
    validate_safe_env_value "${stls_password}" || { print_error "Shadow-TLS 密码包含不支持的字符，未写入配置。"; return 1; }
    cat > "${SHADOW_TLS_ENV_FILE}" <<EOF
SS_PORT="${ss_port}"
STLS_PORT="${stls_port}"
STLS_SNI="${stls_sni}"
STLS_PASSWORD="${stls_password}"
STLS_TFO_FLAG=""
EOF
    chmod 600 "${SHADOW_TLS_ENV_FILE}"
}

write_shadow_tls_service() {
    cat > "${SYSTEMD_SHADOW_TLS_SERVICE}" <<EOF
[Unit]
Description=Shadow-TLS Server Service (v3)
After=network-online.target ss-rust.service
Wants=network-online.target
Requires=ss-rust.service

[Service]
Type=simple
EnvironmentFile=${SHADOW_TLS_ENV_FILE}
ExecStart=${SHADOW_TLS_BINARY} \$STLS_TFO_FLAG --v3 --strict server --wildcard-sni=authed --listen [::]:\$STLS_PORT --server 127.0.0.1:\$SS_PORT --tls \$STLS_SNI:443 --password \$STLS_PASSWORD
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now shadow-tls >/dev/null
}

install_or_configure_shadow_tls() {
    print_title
    print_section "安装 / 配置 Shadow-TLS"

    if [ "${SERVICE_MANAGER}" != "systemd" ]; then
        print_error "Shadow-TLS 管理目前仅支持 systemd 系统。"
        pause_screen
        return 1
    fi

    if [ ! -f "${SS_CONFIG_FILE}" ]; then
        print_error "请先安装 Shadowsocks-Rust。"
        pause_screen
        return 1
    fi

    ensure_dependencies || { pause_screen; return 1; }
    fetch_latest_versions_if_needed

    local ss_port stls_port stls_sni stls_password
    ss_port="$(get_ss_port)"
    [ -n "${ss_port}" ] || { print_error "无法读取 Shadowsocks 端口。"; pause_screen; return 1; }

    ui_blank
    read_prompt stls_port "请输入 Shadow-TLS 监听端口（默认 443，q 取消）： " || { cancel_to_previous_menu; return; }
    stls_port="${stls_port:-443}"
    if ! validate_port "${stls_port}"; then
        print_error "Shadow-TLS 端口无效。"
        pause_screen
        return 1
    fi
    if is_port_in_use "${stls_port}"; then
        print_error "端口 ${stls_port} 已被占用，请更换。"
        pause_screen
        return 1
    fi

    ui_blank
    read_prompt stls_sni "请输入 Shadow-TLS SNI（默认 ${SHADOW_TLS_SNI_DEFAULT}，q 取消）： " || { cancel_to_previous_menu; return; }
    stls_sni="${stls_sni:-${SHADOW_TLS_SNI_DEFAULT}}"
    if ! validate_sni "${stls_sni}"; then
        print_error "SNI 仅支持有效域名字符，并且至少包含一个点。"
        pause_screen
        return 1
    fi

    local password_confirm_status=0
    ui_blank
    if confirm_yes_no "是否手动指定 Shadow-TLS 密码？" "n"; then
        ui_blank
        while true; do
            read_secret stls_password "请输入 Shadow-TLS 密码（q 取消）： " || { cancel_to_previous_menu; return; }
            [ -n "${stls_password}" ] && break
            print_error "Shadow-TLS 密码不能为空。"
        done
    else
        password_confirm_status=$?
        [ "${password_confirm_status}" -eq "${CANCEL_STATUS}" ] && { cancel_to_previous_menu; return; }
        stls_password="$(openssl rand -base64 16)"
        print_success "已生成随机 Shadow-TLS 密码。"
    fi
    if ! validate_safe_env_value "${stls_password}"; then
        print_error "Shadow-TLS 密码包含不支持的字符。请使用字母、数字或 Base64 常见字符。"
        pause_screen
        return 1
    fi

    show_shadow_tls_change_summary "确认 Shadow-TLS 参数" "${ss_port}" "${stls_port}" "${stls_sni}"
    local stls_confirm_status=0
    ui_blank
    confirm_yes_no "确认写入配置并启动 Shadow-TLS？" "y" || stls_confirm_status=$?
    if [ "${stls_confirm_status}" -eq "${CANCEL_STATUS}" ]; then
        cancel_to_previous_menu
        return
    fi
    if [ "${stls_confirm_status}" -ne 0 ]; then
        ui_warn "已取消 Shadow-TLS 配置。"
        pause_screen
        return
    fi

    download_and_install_shadow_tls_binary || { pause_screen; return 1; }
    write_shadow_tls_env "${ss_port}" "${stls_port}" "${stls_sni}" "${stls_password}" || { pause_screen; return 1; }
    write_shadow_tls_service || { pause_screen; return 1; }
    print_success "Shadow-TLS 已安装并启动。"
    show_client_config false
    pause_screen
}

load_shadow_tls_env() {
    [ -f "${SHADOW_TLS_ENV_FILE}" ] || return 1

    local line key raw_value value
    SS_PORT=""
    STLS_PORT=""
    STLS_SNI=""
    STLS_PASSWORD=""
    # shellcheck disable=SC2034
    STLS_TFO_FLAG=""

    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        raw_value="${BASH_REMATCH[2]}"

        case "${key}" in
            SS_PORT|STLS_PORT|STLS_SNI|STLS_PASSWORD|STLS_TFO_FLAG) ;;
            *) return 1 ;;
        esac

        value="${raw_value}"
        if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        validate_safe_env_value "${value}" || return 1
        printf -v "${key}" '%s' "${value}"
    done < "${SHADOW_TLS_ENV_FILE}"

    validate_port "${SS_PORT}" || return 1
    validate_port "${STLS_PORT}" || return 1
    validate_sni "${STLS_SNI}" || return 1
    [ -n "${STLS_PASSWORD}" ] || return 1
}

get_server_ip() {
    curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null \
        || curl -fsS -6 -m 5 https://api64.ipify.org 2>/dev/null \
        || echo "SERVER_IP"
}

show_client_config() {
    local pause_after="${1:-true}" ss_port ss_password ss_method server_ip host stls_state
    print_section "当前配置"
    if [ ! -f "${SS_CONFIG_FILE}" ]; then
        print_warn "尚未安装 Shadowsocks-Rust。"
        if [ "${pause_after}" = true ]; then
            pause_screen
        fi
        return
    fi

    ss_port="$(get_ss_port)"
    ss_password="$(get_ss_password)"
    ss_method="$(get_ss_method)"
    server_ip="$(get_server_ip)"
    host="$(hostname 2>/dev/null || echo ss-rust)"
    stls_state="$(shadow_tls_service_state)"

    ui_rule
    ui_kv "SS 状态" "$(ss_service_state)"
    ui_kv "SS 端口" "${ss_port:-unknown}"
    ui_kv "SS 加密" "${ss_method:-unknown}"
    ui_kv "Shadow-TLS" "${stls_state}"
    ui_rule
    echo
    ui_warn "下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。"
    print_info "Shadowsocks 直连配置："
    echo "${host} = ss, ${server_ip}, ${ss_port}, encrypt-method=${ss_method}, password=${ss_password}, udp-relay=true"

    if [ "${stls_state}" = "active" ] && load_shadow_tls_env; then
        echo
        print_info "Shadow-TLS 配置："
        echo "${host}-stls = ss, ${server_ip}, ${STLS_PORT}, encrypt-method=${ss_method}, password=${ss_password}, shadow-tls-password=${STLS_PASSWORD}, shadow-tls-sni=${STLS_SNI}, shadow-tls-version=3, udp-relay=true, udp-port=${ss_port}"
    fi

    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

modify_ss_config() {
    print_title
    print_section "修改 Shadowsocks 配置"

    if [ ! -f "${SS_CONFIG_FILE}" ]; then
        print_error "尚未安装 Shadowsocks-Rust。"
        pause_screen
        return 1
    fi

    local current_port current_method current_password new_port new_method new_password
    current_port="$(get_ss_port)"
    current_method="$(get_ss_method)"
    current_password="$(get_ss_password)"

    print_info "当前端口：${current_port}"
    ui_blank
    read_prompt new_port "请输入新端口（回车保持不变，q 取消）： " || { cancel_to_previous_menu; return; }
    if [ -z "${new_port}" ]; then
        new_port="${current_port}"
    elif ! validate_port "${new_port}"; then
        print_error "端口格式无效。"
        pause_screen
        return 1
    elif [ "${new_port}" != "${current_port}" ] && is_port_in_use "${new_port}"; then
        print_error "端口 ${new_port} 已被占用，请更换。"
        pause_screen
        return 1
    fi

    local method_confirm_status=0 password_confirm_status=0
    ui_blank
    if confirm_yes_no "是否修改加密方法？" "n"; then
        choose_method new_method || { cancel_to_previous_menu; return; }
        prompt_password new_password "${new_method}" || { cancel_to_previous_menu; return; }
    else
        method_confirm_status=$?
        [ "${method_confirm_status}" -eq "${CANCEL_STATUS}" ] && { cancel_to_previous_menu; return; }
        ui_blank
        if confirm_yes_no "是否修改密码？" "n"; then
            new_method="${current_method}"
            prompt_password new_password "${new_method}" || { cancel_to_previous_menu; return; }
        else
            password_confirm_status=$?
            [ "${password_confirm_status}" -eq "${CANCEL_STATUS}" ] && { cancel_to_previous_menu; return; }
            new_method="${current_method}"
            new_password="${current_password}"
        fi
    fi

    if [ -z "${new_method}" ] || [ -z "${new_password}" ]; then
        print_error "无法生成新的 Shadowsocks 配置。"
        pause_screen
        return 1
    fi

    show_ss_config_change_summary "确认修改参数" "${new_port}" "${new_method}"
    local modify_confirm_status=0
    ui_blank
    confirm_yes_no "确认写入配置并重启服务？" "y" || modify_confirm_status=$?
    if [ "${modify_confirm_status}" -eq "${CANCEL_STATUS}" ]; then
        cancel_to_previous_menu
        return
    fi
    if [ "${modify_confirm_status}" -ne 0 ]; then
        ui_warn "已取消修改。"
        pause_screen
        return
    fi

    write_ss_config "${new_port}" "${new_password}" "${new_method}" || { pause_screen; return 1; }
    restart_ss_service || { pause_screen; return 1; }

    if [ -f "${SHADOW_TLS_ENV_FILE}" ] && load_shadow_tls_env; then
        write_shadow_tls_env "${new_port}" "${STLS_PORT}" "${STLS_SNI}" "${STLS_PASSWORD}" || { pause_screen; return 1; }
        systemctl restart shadow-tls >/dev/null 2>&1 || true
    fi

    print_success "配置已更新并重启服务。"
    show_client_config false
    pause_screen
}

update_components() {
    print_title
    print_section "更新核心组件"
    ensure_dependencies || { pause_screen; return 1; }
    FETCH_LATEST=true
    fetch_latest_versions_if_needed

    if [ -f "${SS_BINARY}" ]; then
        download_and_install_ss_binary || { pause_screen; return 1; }
        restart_ss_service || { pause_screen; return 1; }
        print_success "Shadowsocks-Rust 已更新并重启。"
    else
        print_warn "未检测到 Shadowsocks-Rust 安装，跳过。"
    fi

    if [ "${SERVICE_MANAGER}" = "systemd" ] && [ -f "${SYSTEMD_SHADOW_TLS_SERVICE}" ]; then
        download_and_install_shadow_tls_binary || { pause_screen; return 1; }
        systemctl restart shadow-tls || { pause_screen; return 1; }
        print_success "Shadow-TLS 已更新并重启。"
    else
        print_warn "未检测到 Shadow-TLS 服务，跳过。"
    fi

    pause_screen
}

manage_services() {
    while true; do
        ui_clear_and_title
        ui_dim "$(build_status_line)"
        ui_blank
        ui_print "请选择服务操作："
        ui_blank
        ui_menu_item 1 "启动 Shadowsocks-Rust"
        ui_menu_item 2 "停止 Shadowsocks-Rust"
        ui_menu_item 3 "重启 Shadowsocks-Rust"
        if [ "${SERVICE_MANAGER}" = "systemd" ]; then
            ui_menu_item 4 "启动 Shadow-TLS"
            ui_menu_item 5 "停止 Shadow-TLS"
            ui_menu_item 6 "重启 Shadow-TLS"
        fi
        ui_menu_item 0 "返回上一级"
        ui_blank
        ui_dim "普通输入：输入 q 取消当前操作。"
        ui_blank

        local choice action_done=true
        ui_read_raw choice "请输入选项编号（0 返回）： "
        case "${choice}" in
            1) start_ss_service || action_done=false ;;
            2) stop_ss_service ;;
            3) restart_ss_service || action_done=false ;;
            4)
                if [ "${SERVICE_MANAGER}" = "systemd" ]; then
                    systemctl start shadow-tls || action_done=false
                else
                    print_error "Shadow-TLS 管理仅支持 systemd。"
                    action_done=false
                fi
                ;;
            5)
                if [ "${SERVICE_MANAGER}" = "systemd" ]; then
                    systemctl stop shadow-tls || action_done=false
                else
                    print_error "Shadow-TLS 管理仅支持 systemd。"
                    action_done=false
                fi
                ;;
            6)
                if [ "${SERVICE_MANAGER}" = "systemd" ]; then
                    systemctl restart shadow-tls || action_done=false
                else
                    print_error "Shadow-TLS 管理仅支持 systemd。"
                    action_done=false
                fi
                ;;
            0) return 0 ;;
            q|Q)
                ui_warn "已取消，返回上一级菜单。"
                ui_pause
                return 0
                ;;
            *) print_error "无效选项。"; action_done=false ;;
        esac
        [ "${action_done}" = true ] && print_success "服务操作已执行。"
        pause_screen
    done
}

show_status_and_logs() {
    print_title
    print_section "服务状态"
    local pause_after="${1:-false}"
    ui_kv "服务管理器" "${SERVICE_MANAGER}"
    ui_kv "包管理器" "${PKG_MANAGER}"
    ui_kv "系统架构" "${ARCH}"
    ui_kv "Shadowsocks" "$(ss_service_state)"
    ui_kv "Shadow-TLS" "$(shadow_tls_service_state)"
    echo
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        print_info "日志查看命令："
        echo "journalctl -u ss-rust -n 80 --no-pager"
        echo "journalctl -u shadow-tls -n 80 --no-pager"
    else
        print_info "OpenRC 日志路径："
        echo "/var/log/ss-rust.log"
        echo "/var/log/ss-rust-error.log"
    fi
    if [ "${pause_after}" = true ]; then
        pause_screen
    fi
    return 0
}

uninstall_all() {
    print_title
    print_section "卸载 Shadowsocks / Shadow-TLS"
    echo "即将删除："
    ui_kv "Shadowsocks 服务" "${SYSTEMD_SS_SERVICE}"
    ui_kv "OpenRC 服务" "${OPENRC_SS_SERVICE}"
    ui_kv "Shadow-TLS 服务" "${SYSTEMD_SHADOW_TLS_SERVICE}"
    ui_kv "Shadow-TLS 二进制" "${SHADOW_TLS_BINARY}"
    ui_kv "安装目录" "${INSTALL_DIR}"
    echo
    ui_confirm_token "确认卸载 Shadowsocks-Rust 与 Shadow-TLS？" "DELETE" || {
        ui_warn "已取消卸载。"
        pause_screen
        return
    }

    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        systemctl disable --now shadow-tls >/dev/null 2>&1 || true
        systemctl disable --now ss-rust >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_SHADOW_TLS_SERVICE}" "${SYSTEMD_SS_SERVICE}"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service ss-rust stop >/dev/null 2>&1 || true
        rc-update del ss-rust default >/dev/null 2>&1 || true
        rm -f "${OPENRC_SS_SERVICE}"
    fi

    rm -f "${SHADOW_TLS_BINARY}"
    rm -rf "${INSTALL_DIR}"
    print_success "卸载完成。"
    pause_screen
}

show_main_menu() {
    while true; do
        ui_clear_and_title
        ui_dim "$(build_status_line)"
        ui_blank
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "安装 / 覆盖安装 Shadowsocks-Rust"
        ui_menu_item 2 "安装 / 配置 Shadow-TLS"
        ui_menu_item 3 "查看当前配置与客户端连接信息"
        ui_menu_item 4 "修改 Shadowsocks 端口 / 密码 / 加密方法"
        ui_menu_item 5 "更新 Shadowsocks-Rust / Shadow-TLS"
        ui_menu_item 6 "启动 / 停止 / 重启服务"
        ui_menu_item 7 "卸载 Shadowsocks / Shadow-TLS"
        ui_menu_item 8 "查看服务状态与日志提示"
        ui_menu_item 0 "退出"
        ui_blank
        ui_menu_footer
        ui_blank
        local choice
        ui_read_main_menu_choice choice
        case "${choice}" in
            1) ui_run_menu_action "安装 / 覆盖安装" install_or_reinstall_ss ;;
            2) ui_run_menu_action "安装 / 配置 Shadow-TLS" install_or_configure_shadow_tls ;;
            3) ui_run_menu_action "查看当前配置" show_client_config true ;;
            4) ui_run_menu_action "修改 Shadowsocks 配置" modify_ss_config ;;
            5) ui_run_menu_action "更新核心组件" update_components ;;
            6) ui_run_menu_action "服务控制" manage_services ;;
            7) ui_run_menu_action "卸载 Shadowsocks / Shadow-TLS" uninstall_all ;;
            8) ui_run_menu_action "查看服务状态" show_status_and_logs true ;;
            0) ui_blank; print_info "已退出。"; exit 0 ;;
            q|Q)
                print_warn "主菜单请使用 0 退出脚本。"
                ui_pause
                ;;
            *)
                print_error "无效选项，请重新输入。"
                ui_pause
                ;;
        esac
    done
}

parse_arguments() {
    COMMAND="menu"
    while [ $# -gt 0 ]; do
        case "$1" in
            --latest)
                FETCH_LATEST=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            install|stls|view|update|uninstall|status|menu)
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
    ui_init_colors
    parse_arguments "$@"
    require_root
    init_prompt_input
    detect_system_info
    fetch_latest_versions_if_needed

    case "${COMMAND}" in
        install) install_or_reinstall_ss ;;
        stls) install_or_configure_shadow_tls ;;
        view) show_client_config false ;;
        update) update_components ;;
        uninstall) uninstall_all ;;
        status) show_status_and_logs ;;
        menu) show_main_menu ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
