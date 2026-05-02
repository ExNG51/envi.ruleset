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

COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"

SERVICE_MANAGER=""
PKG_MANAGER=""
ARCH=""
IS_ALPINE=false
FETCH_LATEST=false
SS_VERSION="${SS_VERSION_DEFAULT}"
SHADOW_TLS_VERSION="${SHADOW_TLS_VERSION_DEFAULT}"
PROMPT_FD=0

print_title() {
    clear || true
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "============================================================"
    echo "        Shadowsocks-Rust 统一管理脚本"
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
            print_error "无法读取密码输入。"
            exit 1
        }
        echo
    else
        IFS= read -r -s -p "${prompt_text}" "${var_name}" || {
            echo
            print_error "无法读取密码输入。"
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
        packages=(curl wget tar openssl ca-certificates net-tools xz-utils coreutils)
    else
        packages=(curl wget tar openssl ca-certificates net-tools xz coreutils)
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
    while true; do
        read_prompt value "${prompt_text}"
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
    echo "请选择 Shadowsocks 加密方法："
    echo "  1) 2022-blake3-aes-128-gcm（推荐，24 字符 Base64 密码）"
    echo "  2) 2022-blake3-aes-256-gcm（44 字符 Base64 密码）"
    while true; do
        read_prompt choice "请输入选项编号（默认 1）： "
        choice="${choice:-1}"
        case "${choice}" in
            1) printf -v "${var_name}" '%s' "2022-blake3-aes-128-gcm"; return 0 ;;
            2) printf -v "${var_name}" '%s' "2022-blake3-aes-256-gcm"; return 0 ;;
            *) print_error "无效选项，请输入 1 或 2。" ;;
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
    local var_name="$1" method="$2" expected_len password=""
    expected_len="$(method_password_length "${method}")"
    if confirm_yes_no "是否手动指定 Shadowsocks 密码？" "n"; then
        while true; do
            read_secret password "请输入 Shadowsocks 密码（${expected_len} 字符 Base64）： "
            if [ "${#password}" -ne "${expected_len}" ]; then
                print_error "密码长度不符合 ${method} 要求，应为 ${expected_len} 字符。"
                continue
            fi
            printf -v "${var_name}" '%s' "${password}"
            return 0
        done
    fi

    password="$(generate_password_for_method "${method}")"
    printf -v "${var_name}" '%s' "${password}"
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
    if ! curl -fL "${package_url}" -o "${temp_dir}/${package_name}"; then
        rm -rf "${temp_dir}"
        print_error "下载失败：${package_url}"
        return 1
    fi

    tar -xf "${temp_dir}/${package_name}" -C "${temp_dir}"
    if [ ! -f "${temp_dir}/ssserver" ]; then
        rm -rf "${temp_dir}"
        print_error "压缩包中未找到 ssserver。"
        return 1
    fi

    mkdir -p "${INSTALL_DIR}"
    install -m 0755 "${temp_dir}/ssserver" "${SS_BINARY}"
    rm -rf "${temp_dir}"
    print_success "Shadowsocks-Rust 核心已安装到 ${SS_BINARY}。"
}

write_ss_config() {
    local port="$1" password="$2" method="$3"
    mkdir -p "${INSTALL_DIR}"
    cat > "${SS_CONFIG_FILE}" <<EOF
{
    "server": "::",
    "server_port": ${port},
    "password": "${password}",
    "method": "${method}",
    "mode": "tcp_and_udp"
}
EOF
    chmod 600 "${SS_CONFIG_FILE}"
}

read_json_value() {
    local key="$1" file="$2"
    [ -f "${file}" ] || return 1
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
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=${SS_BINARY} -c ${SS_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ss-rust >/dev/null
    else
        cat > "${OPENRC_SS_SERVICE}" <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust Secure Server"
command_user="nobody"
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

install_or_reinstall_ss() {
    print_title
    print_section "安装 / 覆盖安装 Shadowsocks-Rust"
    ensure_dependencies
    fetch_latest_versions_if_needed

    if [ -d "${INSTALL_DIR}" ] && ! confirm_yes_no "检测到已有安装，是否覆盖 Shadowsocks 配置？" "n"; then
        print_warn "已取消。"
        pause_screen
        return
    fi

    local port method password
    prompt_port port "请输入 Shadowsocks 监听端口（回车随机）： " true
    choose_method method
    prompt_password password "${method}"

    download_and_install_ss_binary
    write_ss_config "${port}" "${password}" "${method}"
    write_ss_service

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
    if ! curl -fL "${binary_url}" -o "${temp_file}"; then
        rm -f "${temp_file}"
        print_error "下载失败：${binary_url}"
        return 1
    fi

    install -m 0755 "${temp_file}" "${SHADOW_TLS_BINARY}"
    rm -f "${temp_file}"
    print_success "Shadow-TLS 已安装到 ${SHADOW_TLS_BINARY}。"
}

write_shadow_tls_env() {
    local ss_port="$1" stls_port="$2" stls_sni="$3" stls_password="$4"
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
        return
    fi

    if [ ! -f "${SS_CONFIG_FILE}" ]; then
        print_error "请先安装 Shadowsocks-Rust。"
        pause_screen
        return
    fi

    ensure_dependencies
    fetch_latest_versions_if_needed

    local ss_port stls_port stls_sni stls_password
    ss_port="$(get_ss_port)"
    [ -n "${ss_port}" ] || { print_error "无法读取 Shadowsocks 端口。"; pause_screen; return; }

    download_and_install_shadow_tls_binary

    read_prompt stls_port "请输入 Shadow-TLS 监听端口（默认 443）： "
    stls_port="${stls_port:-443}"
    if ! validate_port "${stls_port}"; then
        print_error "Shadow-TLS 端口无效。"
        pause_screen
        return
    fi

    read_prompt stls_sni "请输入 Shadow-TLS SNI（默认 ${SHADOW_TLS_SNI_DEFAULT}）： "
    stls_sni="${stls_sni:-${SHADOW_TLS_SNI_DEFAULT}}"

    if confirm_yes_no "是否手动指定 Shadow-TLS 密码？" "n"; then
        while true; do
            read_secret stls_password "请输入 Shadow-TLS 密码： "
            [ -n "${stls_password}" ] && break
            print_error "Shadow-TLS 密码不能为空。"
        done
    else
        stls_password="$(openssl rand -base64 16)"
        print_success "已生成随机 Shadow-TLS 密码。"
    fi

    write_shadow_tls_env "${ss_port}" "${stls_port}" "${stls_sni}" "${stls_password}"
    write_shadow_tls_service
    print_success "Shadow-TLS 已安装并启动。"
    show_client_config false
    pause_screen
}

load_shadow_tls_env() {
    [ -f "${SHADOW_TLS_ENV_FILE}" ] || return 1
    # 文件由本脚本生成，权限 600。
    # shellcheck disable=SC1090
    . "${SHADOW_TLS_ENV_FILE}"
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
        [ "${pause_after}" = true ] && pause_screen
        return
    fi

    ss_port="$(get_ss_port)"
    ss_password="$(get_ss_password)"
    ss_method="$(get_ss_method)"
    server_ip="$(get_server_ip)"
    host="$(hostname 2>/dev/null || echo ss-rust)"
    stls_state="$(shadow_tls_service_state)"

    printf "%s\n" "------------------------------------------------------------"
    printf "%-18s %s\n" "SS 状态" "$(ss_service_state)"
    printf "%-18s %s\n" "SS 端口" "${ss_port}"
    printf "%-18s %s\n" "SS 加密" "${ss_method}"
    printf "%-18s %s\n" "Shadow-TLS" "${stls_state}"
    printf "%s\n" "------------------------------------------------------------"
    echo
    print_info "Shadowsocks 直连配置："
    echo "${host} = ss, ${server_ip}, ${ss_port}, encrypt-method=${ss_method}, password=${ss_password}, udp-relay=true"

    if [ "${stls_state}" = "active" ] && load_shadow_tls_env; then
        echo
        print_info "Shadow-TLS 配置："
        echo "${host}-stls = ss, ${server_ip}, ${STLS_PORT}, encrypt-method=${ss_method}, password=${ss_password}, shadow-tls-password=${STLS_PASSWORD}, shadow-tls-sni=${STLS_SNI}, shadow-tls-version=3, udp-relay=true, udp-port=${ss_port}"
    fi

    [ "${pause_after}" = true ] && pause_screen
}

modify_ss_config() {
    print_title
    print_section "修改 Shadowsocks 配置"

    if [ ! -f "${SS_CONFIG_FILE}" ]; then
        print_error "尚未安装 Shadowsocks-Rust。"
        pause_screen
        return
    fi

    local current_port current_method current_password new_port new_method new_password
    current_port="$(get_ss_port)"
    current_method="$(get_ss_method)"
    current_password="$(get_ss_password)"

    print_info "当前端口：${current_port}"
    read_prompt new_port "请输入新端口（回车保持不变）： "
    if [ -z "${new_port}" ]; then
        new_port="${current_port}"
    elif ! validate_port "${new_port}"; then
        print_error "端口格式无效。"
        pause_screen
        return
    fi

    if confirm_yes_no "是否修改加密方法？" "n"; then
        choose_method new_method
        prompt_password new_password "${new_method}"
    elif confirm_yes_no "是否修改密码？" "n"; then
        new_method="${current_method}"
        prompt_password new_password "${new_method}"
    else
        new_method="${current_method}"
        new_password="${current_password}"
    fi

    write_ss_config "${new_port}" "${new_password}" "${new_method}"
    restart_ss_service

    if [ -f "${SHADOW_TLS_ENV_FILE}" ] && load_shadow_tls_env; then
        write_shadow_tls_env "${new_port}" "${STLS_PORT}" "${STLS_SNI}" "${STLS_PASSWORD}"
        systemctl restart shadow-tls >/dev/null 2>&1 || true
    fi

    print_success "配置已更新并重启服务。"
    show_client_config false
    pause_screen
}

update_components() {
    print_title
    print_section "更新核心组件"
    ensure_dependencies
    FETCH_LATEST=true
    fetch_latest_versions_if_needed

    if [ -f "${SS_BINARY}" ]; then
        download_and_install_ss_binary
        restart_ss_service
        print_success "Shadowsocks-Rust 已更新并重启。"
    else
        print_warn "未检测到 Shadowsocks-Rust 安装，跳过。"
    fi

    if [ "${SERVICE_MANAGER}" = "systemd" ] && [ -f "${SYSTEMD_SHADOW_TLS_SERVICE}" ]; then
        download_and_install_shadow_tls_binary
        systemctl restart shadow-tls
        print_success "Shadow-TLS 已更新并重启。"
    else
        print_warn "未检测到 Shadow-TLS 服务，跳过。"
    fi

    pause_screen
}

manage_services() {
    print_title
    print_section "服务控制"
    echo "  1) 启动 Shadowsocks"
    echo "  2) 停止 Shadowsocks"
    echo "  3) 重启 Shadowsocks"
    if [ "${SERVICE_MANAGER}" = "systemd" ]; then
        echo "  4) 启动 Shadow-TLS"
        echo "  5) 停止 Shadow-TLS"
        echo "  6) 重启 Shadow-TLS"
    fi
    echo "  0) 返回"
    echo
    local choice action_done=true
    read_prompt choice "请输入选项编号： "
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
        0) return ;;
        *) print_error "无效选项。"; action_done=false ;;
    esac
    [ "${action_done}" = true ] && print_success "服务操作已执行。"
    pause_screen
}

show_status_and_logs() {
    print_title
    print_section "服务状态"
    printf "%-18s %s\n" "服务管理器" "${SERVICE_MANAGER}"
    printf "%-18s %s\n" "包管理器" "${PKG_MANAGER}"
    printf "%-18s %s\n" "系统架构" "${ARCH}"
    printf "%-18s %s\n" "Shadowsocks" "$(ss_service_state)"
    printf "%-18s %s\n" "Shadow-TLS" "$(shadow_tls_service_state)"
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
    pause_screen
}

uninstall_all() {
    print_title
    print_section "卸载 Shadowsocks / Shadow-TLS"
    confirm_yes_no "确认卸载 Shadowsocks-Rust 与 Shadow-TLS？" "n" || {
        print_warn "已取消卸载。"
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
        print_title
        echo "请选择操作："
        echo
        echo "  1) 安装 / 覆盖安装 Shadowsocks-Rust"
        echo "  2) 安装 / 配置 Shadow-TLS"
        echo "  3) 查看当前配置与客户端连接信息"
        echo "  4) 修改 Shadowsocks 端口 / 密码 / 加密方法"
        echo "  5) 更新 Shadowsocks-Rust / Shadow-TLS"
        echo "  6) 启动 / 停止 / 重启服务"
        echo "  7) 卸载 Shadowsocks / Shadow-TLS"
        echo "  8) 查看服务状态与日志提示"
        echo "  0) 退出"
        echo
        print_dim "SS 状态: $(ss_service_state) | Shadow-TLS: $(shadow_tls_service_state)"
        echo
        local choice
        read_prompt choice "请输入选项编号： "
        case "${choice}" in
            1) install_or_reinstall_ss ;;
            2) install_or_configure_shadow_tls ;;
            3) show_client_config true ;;
            4) modify_ss_config ;;
            5) update_components ;;
            6) manage_services ;;
            7) uninstall_all ;;
            8) show_status_and_logs ;;
            0) echo; print_info "已退出。"; exit 0 ;;
            *) print_error "无效选项，请重新输入。"; sleep 1 ;;
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
    parse_arguments "$@"
    require_root
    init_prompt_input
    detect_system_info
    fetch_latest_versions_if_needed

    case "${COMMAND}" in
        install) install_or_reinstall_ss ;;
        stls) install_or_configure_shadow_tls ;;
        view) show_client_config true ;;
        update) update_components ;;
        uninstall) uninstall_all ;;
        status) show_status_and_logs ;;
        menu) show_main_menu ;;
    esac
}

main "$@"
