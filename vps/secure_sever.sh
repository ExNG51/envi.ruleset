#!/bin/bash
# Linux security hardening helper for UFW, Fail2ban, and OpenSSH.

set -u
set -o pipefail

# --- Runtime flags ---
SCRIPT_VERSION="2026.05.17-r1"
SECURE_SERVER_TEST_MODE="${SECURE_SERVER_TEST_MODE:-0}"
SECURE_SERVER_DRY_RUN="${SECURE_SERVER_DRY_RUN:-0}"
SECURE_SERVER_NONINTERACTIVE="${SECURE_SERVER_NONINTERACTIVE:-0}"
UI_RETURN_TO_MENU=130
INPUT_CANCELLED="${UI_RETURN_TO_MENU}"
UI_PROMPT_FD=0
PROMPT_FD=0
COMMAND="menu"

# --- Configuration ---
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-/etc/ssh/sshd_config}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
SSHD_HARDENING_FILE="${SSHD_HARDENING_FILE:-${SSHD_CONFIG_DIR}/99-hardening.conf}"
FAIL2BAN_JAIL_DIR="${FAIL2BAN_JAIL_DIR:-/etc/fail2ban/jail.d}"
FAIL2BAN_SSHD_LOCAL="${FAIL2BAN_SSHD_LOCAL:-${FAIL2BAN_JAIL_DIR}/99-sshd-hardening.local}"
BACKUP_DIR="${BACKUP_DIR:-/root/secure-server-backups}"

# Global runtime state shared by menu actions.
DETECTED_TCP_PORTS=""
DETECTED_UDP_PORTS=""
DETECTED_SSH_PORT=""
SSH_LOG_PATH=""
FAIL2BAN_BACKEND="auto"
CURRENT_IP=""
MANUAL_TCP_PORTS="${MANUAL_TCP_PORTS:-}"
MANUAL_UDP_PORTS="${MANUAL_UDP_PORTS:-}"

SINGBOX_CONFIG_FILES=(
    "/etc/sing-box/config.json"
    "/usr/local/etc/sing-box/config.json"
    "/opt/sing-box/config.json"
)
SINGBOX_CONFIG_DIRS=(
    "/etc/sing-box/conf"
    "/usr/local/etc/sing-box/conf"
    "/opt/sing-box/conf"
)
CADDY_CONFIG_FILES=(
    "/etc/caddy/Caddyfile"
    "/usr/local/etc/caddy/Caddyfile"
)

# --- UI helpers ---
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

# Legacy color variable names kept as compatibility aliases while the script
# migrates to the ui_* interaction API.
RESET=""
BOLD=""
RED=""
GREEN=""
YELLOW=""
BLUE=""
MAGENTA=""
CYAN=""

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

    RESET="${UI_COLOR_RESET}"
    BOLD="${UI_COLOR_BOLD}"
    RED="${UI_COLOR_RED}"
    GREEN="${UI_COLOR_GREEN}"
    YELLOW="${UI_COLOR_YELLOW}"
    BLUE="${UI_COLOR_BLUE}"
    MAGENTA="${UI_COLOR_BLUE}"
    CYAN="${UI_COLOR_CYAN}"
}

ui_init_prompt_input() {
    if [[ -r /dev/tty ]] && { exec 3</dev/tty; } 2>/dev/null; then
        UI_PROMPT_FD=3
    else
        UI_PROMPT_FD=0
    fi
    PROMPT_FD="${UI_PROMPT_FD}"
}

ui_print() { printf '%b\n' "$*"; }
ui_blank() { printf '\n'; }
ui_info() { printf '%b\n' "${UI_COLOR_CYAN}[i]${UI_COLOR_RESET} $*"; }
ui_ok() { printf '%b\n' "${UI_COLOR_GREEN}[OK]${UI_COLOR_RESET} $*"; }
ui_warn() { printf '%b\n' "${UI_COLOR_YELLOW}[WARN]${UI_COLOR_RESET} $*" >&2; }
ui_error() { printf '%b\n' "${UI_COLOR_RED}[ERROR]${UI_COLOR_RESET} $*" >&2; }
ui_dim() { printf '%b\n' "${UI_COLOR_DIM}$*${UI_COLOR_RESET}"; }
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

ui_center_line() {
    local text="$1" width=0 padding=0 left=0
    width="$(ui_text_width "$text")"
    padding=$((UI_TITLE_WIDTH - width))
    ((padding < 0)) && padding=0
    left=$((padding / 2))
    printf '%*s%s\n' "$left" "" "$text"
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

ui_title() {
    local title="$1" version="${2:-}"
    printf '%b' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}"
    printf '%*s\n' "$UI_TITLE_WIDTH" '' | tr ' ' '='
    ui_center_line "$title"
    if [[ -n "$version" ]]; then
        ui_center_line "Version: ${version}"
    fi
    printf '%*s\n' "$UI_TITLE_WIDTH" '' | tr ' ' '='
    printf '%b' "${UI_COLOR_RESET}"
}

ui_render_title() {
    ui_clear
    ui_title "Linux 安全加固脚本" "${SCRIPT_VERSION}"
}

ui_menu_item() {
    local number="$1" label="$2"
    printf ' %2s. %s\n' "$number" "$label"
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

ui_read_main_menu_choice() {
    local __target="$1"
    while true; do
        ui_read_raw "${__target}" "请输入选项编号（0 退出）： "
        if ui_is_cancel "${!__target}"; then
            ui_warn "主菜单请使用 0 退出脚本。"
            continue
        fi
        return 0
    done
}

ui_read_submenu_choice() {
    local __target="$1"
    while true; do
        ui_read_raw "${__target}" "请输入选项编号（0 返回）： "
        if [[ "${!__target}" == "0" ]]; then
            return "${UI_RETURN_TO_MENU}"
        fi
        if ui_is_cancel "${!__target}"; then
            return "${UI_RETURN_TO_MENU}"
        fi
        return 0
    done
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
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) ui_error "请输入 y、n 或 q。" ;;
        esac
    done
}

ui_confirm_token() {
    local prompt="$1" token="$2" answer
    ui_read_raw answer "${prompt} 输入 ${token} 继续，或输入 q 取消： "

    if ui_is_cancel "$answer"; then
        ui_warn "已取消。"
        return "$UI_RETURN_TO_MENU"
    fi

    if [[ "$answer" != "$token" ]]; then
        ui_warn "已取消。"
        return 1
    fi

    return 0
}

ui_pause() {
    local _
    printf '\n'
    ui_read_raw _ "按回车键继续..."
}

ui_run_menu_action() {
    local action_name="$1" rc=0
    shift

    "$@" || rc=$?
    case "$rc" in
        0) return 0 ;;
        "$UI_RETURN_TO_MENU") return 0 ;;
        *)
            ui_error "${action_name} 执行失败，退出码：${rc}。"
            ui_warn "脚本将保留在菜单中，请根据上方错误信息处理后重试。"
            return 0
            ;;
    esac
}

ui_init_colors

TMP_FILES=()

cleanup_tmp_files() {
    local file=""
    local had_nounset=false

    case "$-" in
        *u*) had_nounset=true; set +u ;;
    esac
    for file in "${TMP_FILES[@]}"; do
        [[ -n "$file" && -e "$file" ]] && rm -f "$file"
    done
    $had_nounset && set -u
}
trap cleanup_tmp_files EXIT

# --- Message helpers ---
info() { ui_info "$@"; }
ok() { ui_ok "$@"; }
warn() { ui_warn "$@"; }
err() { ui_error "$@"; }
section() { ui_section "$@"; }

check_command_status() {
    local description="$1"
    local status="${2:-$?}"
    if [[ "$status" -ne 0 ]]; then
        err "${description} 失败。请检查上方错误信息。"
        return 1
    fi
    ok "${description} 完成。"
    return 0
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "此脚本需要以 root 权限运行。"
        warn "请使用: sudo bash $0"
        return 1
    fi
    return 0
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        err "缺少命令: $1"
        return 1
    }
}

show_help() {
    cat <<EOF
用法：
  bash secure_sever.sh [选项]

命令：
  不带参数    启动交互式安全加固菜单

选项：
  -h, --help  显示帮助并退出

交互语义：
  主菜单输入 0 退出脚本
  子菜单输入 0 返回上一级
  普通输入中 q/Q 取消当前操作并返回上一级

说明：
  该脚本用于交互式执行 Linux 安全加固流程，包括 UFW、Fail2ban 与 SSH 加固。
EOF
}

parse_arguments() {
    COMMAND="menu"
    if [[ $# -eq 0 && -z "${BASH_SOURCE[0]:-}" ]]; then
        case "${0:-}" in
            -h|--help)
                set -- "${0}"
                ;;
        esac
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                COMMAND="help"
                shift
                ;;
            *)
                ui_error "未知参数：$1"
                show_help
                return 1
                ;;
        esac
    done
}

make_tmp_file() {
    local tmp_file=""
    tmp_file="$(mktemp)" || return 1
    TMP_FILES+=("$tmp_file")
    printf '%s\n' "$tmp_file"
}

run_cmd() {
    local description="$1"
    local command_text=""
    shift

    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        printf -v command_text '%q ' "$@"
        ui_info "DRY-RUN: ${description}: ${command_text% }"
        return 0
    fi

    "$@"
}

# --- Interaction helpers ---
# Interaction contract:
# - Main menu: 0 exits the script.
# - Submenus: 0 returns to the parent menu.
# - Free-form input: q cancels the current operation and returns to the parent menu.
# - Inputs with defaults must display: "回车使用默认值，q 取消".
build_free_input_prompt() {
    local prompt="$1"
    printf '%s（q 取消）： ' "$prompt"
}

build_default_prompt() {
    local prompt="$1"
    local default="$2"
    printf '%s（默认 %s，回车使用默认值，q 取消）： ' "$prompt" "$default"
}

prompt_required() {
    local __result_var="$1"
    local prompt="$2"
    local answer=""

    while true; do
        ui_read_or_cancel answer "$(build_free_input_prompt "$prompt")" || return "$?"
        case "$answer" in
            "") warn "输入不能为空；请输入有效值，或输入 q 取消。" ;;
            *) printf -v "${__result_var}" '%s' "$answer"; return 0 ;;
        esac
    done
}

prompt_with_default() {
    local __result_var="$1"
    local prompt="$2"
    local default="$3"
    local answer=""

    ui_read_or_cancel answer "$(build_default_prompt "$prompt" "$default")" || return "$?"
    case "$answer" in
        "") printf -v "${__result_var}" '%s' "$default" ;;
        *) printf -v "${__result_var}" '%s' "$answer" ;;
    esac
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    ui_confirm "$prompt" "$default"
}

pause_before_menu() {
    ui_pause
}

is_valid_main_menu_choice() {
    [[ "$1" =~ ^[0-7]$ ]]
}

is_valid_submenu_choice() {
    local max_choice="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge 0 && "$value" -le "$max_choice" ]]
}

# --- Pure helpers ---
normalize_port_list() {
    local input="$*"
    printf '%s\n' "$input" \
        | tr '[:space:]' '\n' \
        | awk '
            /^[0-9]+$/ {
                port = $1 + 0
                if (port >= 1 && port <= 65535) ports[port] = 1
            }
            END {
                for (port in ports) print port
            }
        ' \
        | sort -n \
        | awk '{ printf "%s ", $1 }'
    return 0
}

add_detected_tcp_port() {
    DETECTED_TCP_PORTS="$(normalize_port_list "${DETECTED_TCP_PORTS} $*")"
}

add_detected_udp_port() {
    DETECTED_UDP_PORTS="$(normalize_port_list "${DETECTED_UDP_PORTS} $*")"
}

is_ipv4_or_cidr() {
    local value="$1"
    local ip=""
    local prefix=""
    local a=""
    local b=""
    local c=""
    local d=""
    local octet=""
    local octet_num=0
    local prefix_num=0

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    ip="${value%%/*}"
    [[ "$value" == */* ]] && prefix="${value##*/}"

    IFS='.' read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        octet_num=$((10#$octet))
        [[ "$octet_num" -ge 0 && "$octet_num" -le 255 ]] || return 1
    done

    if [[ -n "$prefix" ]]; then
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        prefix_num=$((10#$prefix))
        [[ "$prefix_num" -ge 0 && "$prefix_num" -le 32 ]] || return 1
    fi

    return 0
}

detect_ssh_port_from_effective_config() {
    local config_file="${1:-$SSH_CONFIG_FILE}"
    local port=""

    if command -v sshd >/dev/null 2>&1; then
        port="$(sshd -T -f "$config_file" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    fi

    normalize_port_list "$port" | awk '{ print $1 }'
}

detect_ssh_port_from_file() {
    local config_file="$1"
    local port=""

    [[ -f "$config_file" ]] || return 0

    port="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*Match[[:space:]]+/ { in_match = 1 }
        in_match != 1 && /^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2; exit }
    ' "$config_file" 2>/dev/null)"

    normalize_port_list "$port" | awk '{ print $1 }'
}

detect_ssh_port_from_listening() {
    local port=""

    if command -v ss >/dev/null 2>&1; then
        port="$(ss -H -ltnp 2>/dev/null | awk '/sshd/ { print $4; exit }' | sed -E 's/.*:([0-9]+)$/\1/')"
    elif command -v netstat >/dev/null 2>&1; then
        port="$(netstat -ltnp 2>/dev/null | awk '/sshd/ { print $4; exit }' | sed -E 's/.*:([0-9]+)$/\1/')"
    fi

    normalize_port_list "$port" | awk '{ print $1 }'
}

insert_sshd_include_before_match() {
    local config_file="$1"
    local include_line="Include /etc/ssh/sshd_config.d/*.conf"

    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$config_file"; then
        cat "$config_file"
        return 0
    fi

    awk -v include_line="$include_line" '
        !inserted && /^[[:space:]]*Match[[:space:]]+/ {
            print include_line
            inserted = 1
        }
        { print }
        END {
            if (!inserted) print include_line
        }
    ' "$config_file"
}

render_fail2ban_sshd_config() {
    local ssh_port="$1"
    local ignore_ip="$2"
    local backend="$3"
    local logpath="$4"
    local ignore_line="127.0.0.1/8 ::1"

    [[ -n "$ignore_ip" ]] && ignore_line="${ignore_line} ${ignore_ip}"

    cat <<EOF
[DEFAULT]
bantime = 30d
findtime = 10m
maxretry = 3
ignoreip = ${ignore_line}
backend = ${backend:-auto}
banaction = ufw

[sshd]
enabled = true
port = ${ssh_port:-ssh}
filter = sshd
EOF

    if [[ -n "$logpath" ]]; then
        printf 'logpath = %s\n' "$logpath"
    fi
}

render_sshd_hardening_config() {
    local permit_root_login="$1"
    local password_auth="$2"

    cat <<EOF
PermitRootLogin ${permit_root_login}
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
MaxAuthTries 3
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

create_backup_dir() {
    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        printf '%s\n' "$BACKUP_DIR"
        return 0
    fi
    mkdir -p "$BACKUP_DIR"
}

backup_file_if_exists() {
    local file_path="$1"
    local backup_path=""

    [[ -e "$file_path" ]] || return 0
    create_backup_dir || return 1
    backup_path="${BACKUP_DIR}/$(basename "$file_path").bak_$(date +%Y%m%d_%H%M%S)"
    run_cmd "备份 $file_path" cp "$file_path" "$backup_path" >/dev/null || return 1
    printf '%s\n' "$backup_path"
}

restore_file_backup() {
    local backup_path="$1"
    local target_path="$2"

    [[ -n "$backup_path" && -f "$backup_path" ]] || return 1
    run_cmd "恢复 $target_path" cp "$backup_path" "$target_path" >/dev/null
}

# --- Detection helpers ---
get_current_ip() {
    local current_ip_input=""
    local detected_ip=""

    info "正在获取当前外部 IP 地址..."
    if command -v curl >/dev/null 2>&1; then
        detected_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "$detected_ip" ]] && command -v wget >/dev/null 2>&1; then
        detected_ip="$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -n "$detected_ip" && "$(is_ipv4_or_cidr "$detected_ip"; printf '%s' "$?")" == "0" ]]; then
        CURRENT_IP="$detected_ip"
        ok "检测到当前外部 IP: ${CURRENT_IP}"
        return 0
    fi

    warn "无法自动获取当前 IP。"
    prompt_required current_ip_input "请输入当前外部 IPv4/CIDR" || return "$?"
    if ! is_ipv4_or_cidr "$current_ip_input"; then
        err "IP/CIDR 格式无效: $current_ip_input"
        return 1
    fi
    CURRENT_IP="$current_ip_input"
    ok "使用手动输入 IP/CIDR: ${CURRENT_IP}"
}

prompt_fail2ban_ignore_ip() {
    local choice=""
    local manual_ip=""
    while true; do
        ui_section "Fail2ban 忽略来源"
        ui_print "请选择是否将当前维护来源加入 ignoreip："
        ui_blank
        ui_menu_item 1 "自动检测当前外部 IP/CIDR 并加入 ignoreip（推荐）"
        ui_menu_item 2 "手动输入 IPv4/CIDR"
        ui_menu_item 3 "不加入额外 ignoreip"
        ui_menu_item 0 "返回上一级"
        ui_blank
        ui_dim "子菜单：输入 0 返回上一级。"
        ui_dim "普通输入：输入 q 取消当前操作。"
        ui_blank
        ui_read_or_cancel choice "请输入选项编号（0 返回，q 取消）： " || return "$?"
        case "$choice" in
            0)
                return "$INPUT_CANCELLED"
                ;;
            1)
                get_current_ip || return "$?"
                return 0
                ;;
            2)
                prompt_required manual_ip "请输入要加入 ignoreip 的 IPv4/CIDR" || return "$?"
                if ! is_ipv4_or_cidr "${manual_ip}"; then
                    ui_error "IP/CIDR 格式无效：${manual_ip}"
                    continue
                fi
                CURRENT_IP="${manual_ip}"
                return 0
                ;;
            3)
                CURRENT_IP=""
                ui_warn "未加入额外 ignoreip。若远程维护 IP 触发失败登录，可能被 Fail2ban 封禁。"
                return 0
                ;;
            *)
                ui_error "无效选项，请输入 0 到 3。"
                ;;
        esac
    done
}

find_ssh_log_or_backend() {
    local found=false
    local service_unit=""
    local log_file=""
    local potential_logs=("/var/log/auth.log" "/var/log/secure")

    info "正在检测 SSH 日志位置或 Fail2ban 后端..."
    SSH_LOG_PATH=""
    FAIL2BAN_BACKEND="auto"

    if command -v journalctl >/dev/null 2>&1; then
        for service_unit in sshd ssh; do
            if journalctl -u "$service_unit" --no-pager --quiet >/dev/null 2>&1; then
                FAIL2BAN_BACKEND="systemd"
                SSH_LOG_PATH="using systemd backend"
                ok "检测到 systemd journal 管理 SSH 日志: $service_unit"
                found=true
                break
            fi
        done
    fi

    if ! $found; then
        for log_file in "${potential_logs[@]}"; do
            if [[ -f "$log_file" ]] && { head -n 100 "$log_file" | grep -q "sshd" || tail -n 100 "$log_file" | grep -q "sshd"; }; then
                SSH_LOG_PATH="$log_file"
                FAIL2BAN_BACKEND="auto"
                ok "检测到 SSH 日志文件: $log_file"
                found=true
                break
            fi
        done
    fi

    if ! $found; then
        warn "无法自动确定 SSH 日志路径或 systemd 后端，将使用 Fail2ban 默认机制。"
        return 1
    fi
    return 0
}

detect_ssh_port() {
    local port_found=""

    info "正在检测当前 SSH 端口..."
    DETECTED_SSH_PORT=""

    port_found="$(detect_ssh_port_from_effective_config "$SSH_CONFIG_FILE")"
    [[ -z "$port_found" ]] && port_found="$(detect_ssh_port_from_file "$SSH_CONFIG_FILE")"
    [[ -z "$port_found" ]] && port_found="$(detect_ssh_port_from_listening)"

    if [[ -z "$port_found" ]]; then
        warn "无法可靠检测 SSH 端口。"
        prompt_with_default port_found "请输入当前 SSH 端口" "22" || return "$?"
        port_found="$(normalize_port_list "$port_found" | awk '{ print $1 }')"
        if [[ -z "$port_found" ]]; then
            err "SSH 端口无效。"
            return 1
        fi
    fi

    DETECTED_SSH_PORT="$port_found"
    add_detected_tcp_port "$DETECTED_SSH_PORT"
    ok "SSH 端口: $DETECTED_SSH_PORT/tcp"
}

detect_proxy_ports() {
    local grep_pattern='snell|snell-server|ssserver|shadow-tls|trojan|hysteria|tuic|sing-box|caddy'
    local tcp_ports=""
    local udp_ports=""

    info "正在检测常用代理工具监听端口..."

    if command -v ss >/dev/null 2>&1; then
        tcp_ports="$(ss -H -lntp 2>/dev/null | awk -v pattern="$grep_pattern" '$0 ~ pattern { print $4 }' | sed -E 's/.*:([0-9]+)$/\1/')"
        udp_ports="$(ss -H -lnup 2>/dev/null | awk -v pattern="$grep_pattern" '$0 ~ pattern { print $4 }' | sed -E 's/.*:([0-9]+)$/\1/')"
    elif command -v netstat >/dev/null 2>&1; then
        tcp_ports="$(netstat -lntp 2>/dev/null | awk -v pattern="$grep_pattern" '$0 ~ pattern { print $4 }' | sed -E 's/.*:([0-9]+)$/\1/')"
        udp_ports="$(netstat -lnup 2>/dev/null | awk -v pattern="$grep_pattern" '$0 ~ pattern { print $4 }' | sed -E 's/.*:([0-9]+)$/\1/')"
    else
        warn "ss 和 netstat 都不可用，跳过监听进程端口检测。"
    fi

    tcp_ports="$(normalize_port_list "$tcp_ports")"
    udp_ports="$(normalize_port_list "$udp_ports")"

    if [[ -n "$tcp_ports" ]]; then
        info "监听进程检测 TCP 端口（中置信度）: $tcp_ports"
        add_detected_tcp_port "$tcp_ports"
    else
        info "未从监听进程检测到代理 TCP 端口。"
    fi

    if [[ -n "$udp_ports" ]]; then
        info "监听进程检测 UDP 端口（中置信度）: $udp_ports"
        add_detected_udp_port "$udp_ports"
    else
        info "未从监听进程检测到代理 UDP 端口。"
    fi
}

detect_singbox_ports() {
    local detected_ports=""
    local current_config_file=""
    local current_config_dir=""
    local current_ports=""
    local record=""
    local port=""
    local network=""
    local singbox_config_candidates=()

    info "正在检测 sing-box 配置端口..."

    for current_config_file in "${SINGBOX_CONFIG_FILES[@]}"; do
        [[ -f "$current_config_file" ]] && singbox_config_candidates+=("$current_config_file")
    done

    for current_config_dir in "${SINGBOX_CONFIG_DIRS[@]}"; do
        [[ -d "$current_config_dir" ]] || continue
        for current_config_file in "$current_config_dir"/*.json; do
            [[ -f "$current_config_file" ]] && singbox_config_candidates+=("$current_config_file")
        done
    done

    if [[ "${#singbox_config_candidates[@]}" -eq 0 ]]; then
        info "未发现可读取的 sing-box 配置文件。"
        return 0
    fi

    for current_config_file in "${singbox_config_candidates[@]}"; do
        info "发现 sing-box 配置文件: $current_config_file"
        if command -v jq >/dev/null 2>&1; then
            while IFS="$(printf '\t')" read -r port network; do
                port="$(normalize_port_list "$port" | awk '{ print $1 }')"
                [[ -n "$port" ]] || continue
                detected_ports="${detected_ports}${port} "
                case "$network" in
                    tcp) add_detected_tcp_port "$port" ;;
                    udp) add_detected_udp_port "$port" ;;
                    *) add_detected_tcp_port "$port"; add_detected_udp_port "$port" ;;
                esac
            done < <(jq -r '.. | objects | select(has("listen_port")) | [(.listen_port|tostring), (.network // "")] | @tsv' "$current_config_file" 2>/dev/null)
        else
            current_ports="$(grep -oE '"listen_port"[[:space:]]*:[[:space:]]*"?[0-9]+"?' "$current_config_file" 2>/dev/null | grep -oE '[0-9]+' || true)"
            for record in $current_ports; do
                port="$(normalize_port_list "$record" | awk '{ print $1 }')"
                [[ -n "$port" ]] || continue
                detected_ports="${detected_ports}${port} "
                add_detected_tcp_port "$port"
                add_detected_udp_port "$port"
            done
        fi
    done

    detected_ports="$(normalize_port_list "$detected_ports")"
    if [[ -n "$detected_ports" ]]; then
        info "配置文件检测 sing-box 端口（高置信度）: $detected_ports"
    else
        info "未从 sing-box 配置中检测到 listen_port。"
    fi
}

detect_caddy_ports() {
    local detected_ports=""
    local current_config_file=""
    local current_ports=""

    info "正在检测 Caddy 配置端口..."

    for current_config_file in "${CADDY_CONFIG_FILES[@]}"; do
        [[ -f "$current_config_file" ]] || continue
        info "发现 Caddy 配置文件: $current_config_file"
        current_ports="$(grep -E '^[[:space:]]*(http_port|https_port)[[:space:]]+[0-9]+' "$current_config_file" 2>/dev/null | grep -oE '[0-9]+' || true)"
        current_ports="$(normalize_port_list "$current_ports")"
        if [[ -n "$current_ports" ]]; then
            detected_ports="${detected_ports}${current_ports} "
            add_detected_tcp_port "$current_ports"
        fi
    done

    detected_ports="$(normalize_port_list "$detected_ports")"
    if [[ -n "$detected_ports" ]]; then
        info "配置文件检测 Caddy TCP 端口（高置信度）: $detected_ports"
    else
        info "未从 Caddy 配置中检测到 http_port / https_port。"
    fi
}

apply_manual_ports() {
    local tcp_ports=""
    local udp_ports=""

    info "正在检查手动端口兜底配置..."
    tcp_ports="$(normalize_port_list "$MANUAL_TCP_PORTS")"
    udp_ports="$(normalize_port_list "$MANUAL_UDP_PORTS")"

    if [[ -n "$tcp_ports" ]]; then
        info "手动兜底 TCP 端口（用户指定）: $tcp_ports"
        add_detected_tcp_port "$tcp_ports"
    else
        info "未配置手动 TCP 端口。"
    fi

    if [[ -n "$udp_ports" ]]; then
        info "手动兜底 UDP 端口（用户指定）: $udp_ports"
        add_detected_udp_port "$udp_ports"
    else
        info "未配置手动 UDP 端口。"
    fi
}

# --- Main actions ---
install_packages() {
    local pkg_manager=""
    local update_status=0
    local iproute_pkg="iproute"

    section "步骤 1: 安装依赖"

    if command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt-get"
        iproute_pkg="iproute2"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    else
        err "无法识别包管理器，仅支持 apt-get、dnf、yum。"
        return 1
    fi

    info "使用包管理器: $pkg_manager"

    case "$pkg_manager" in
        apt-get) run_cmd "更新软件包列表" "$pkg_manager" update >/dev/null 2>&1 || update_status=$? ;;
        dnf) run_cmd "更新软件包缓存" "$pkg_manager" makecache -y >/dev/null 2>&1 || update_status=$? ;;
        yum)
            run_cmd "检查软件包更新" "$pkg_manager" check-update >/dev/null 2>&1 || update_status=$?
            [[ "$update_status" -eq 100 ]] && update_status=0
            ;;
    esac
    [[ "$update_status" -eq 0 ]] || { err "软件包列表更新失败。"; return 1; }
    ok "软件包列表已更新。"

    if [[ "$pkg_manager" == "yum" || "$pkg_manager" == "dnf" ]]; then
        warn "RHEL/CentOS 默认防火墙通常是 firewalld。本脚本将安装并使用 UFW。"
        if ! rpm -q epel-release >/dev/null 2>&1; then
            run_cmd "安装 epel-release" "$pkg_manager" install -y epel-release >/dev/null 2>&1 || return 1
        fi
    fi

    run_cmd "安装核心软件包" "$pkg_manager" install -y ufw fail2ban curl wget net-tools "$iproute_pkg" jq >/dev/null 2>&1 || return 1
    ok "依赖安装完成。"
}

collect_firewall_ports() {
    DETECTED_TCP_PORTS=""
    DETECTED_UDP_PORTS=""
    DETECTED_SSH_PORT=""

    detect_ssh_port || return $?
    detect_proxy_ports
    detect_singbox_ports
    detect_caddy_ports
    apply_manual_ports
}

prompt_ssh_source_mode() {
    local __target="$1"
    local choice=""

    while true; do
        ui_section "SSH 来源限制"
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "保持 SSH 对所有来源开放，避免远程锁定"
        ui_menu_item 2 "仅允许当前 IP/CIDR 访问 SSH"
        ui_menu_item 0 "返回上一级"
        ui_blank
        ui_dim "子菜单：输入 0 返回上一级。"
        ui_dim "普通输入：输入 q 取消当前操作。"
        ui_blank
        ui_read_submenu_choice choice || return "$?"

        case "$choice" in
            1) printf -v "$__target" 'open'; return 0 ;;
            2) printf -v "$__target" 'restricted'; return 0 ;;
            *) err "无效选项，请输入 0、1 或 2。" ;;
        esac
    done
}

backup_ufw_config() {
    local __result_var="${1:-}"
    local backup_path=""

    if [[ -n "$__result_var" ]]; then
        printf -v "$__result_var" '%s' ""
    fi

    create_backup_dir >/dev/null || return 1
    backup_path="${BACKUP_DIR}/ufw-$(date +%Y%m%d_%H%M%S).tar.gz"
    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        ui_info "DRY-RUN: backup /etc/ufw -> ${backup_path}"
        if [[ -n "$__result_var" ]]; then
            printf -v "$__result_var" '%s' "$backup_path"
        fi
        return 0
    fi
    [[ -d /etc/ufw ]] || return 0
    tar -C /etc -czf "$backup_path" ufw || return 1
    if [[ -n "$__result_var" ]]; then
        printf -v "$__result_var" '%s' "$backup_path"
    fi
    ok "UFW 配置已备份到 $backup_path"
}

show_ufw_diagnostics() {
    ui_warn "UFW 诊断命令："
    ui_print "ufw status verbose"
    ui_print "ufw status numbered"
    ui_print "systemctl status ufw --no-pager"
    ui_print "journalctl -u ufw -n 80 --no-pager"
}

show_ufw_recovery_commands() {
    local backup_path="$1"
    local ssh_port="${2:-${DETECTED_SSH_PORT:-<SSH_PORT>}}"

    ui_warn "UFW 人工恢复建议："
    ui_print "ufw status verbose"
    ui_print "ufw allow ${ssh_port}/tcp"
    ui_print "ufw reload"
    if [[ -n "$backup_path" ]]; then
        ui_print "备份归档：${backup_path}"
        ui_print "如需按备份人工恢复，请先在本机控制台确认 SSH 放行规则，再解包恢复 /etc/ufw。"
    fi
}

report_ufw_failure() {
    local message="$1"
    local backup_path="$2"

    err "$message"
    show_ufw_diagnostics
    show_ufw_recovery_commands "$backup_path" "${DETECTED_SSH_PORT:-<SSH_PORT>}"
}

run_ufw_step() {
    local description="$1"
    local backup_path="$2"
    shift 2

    if ! run_cmd "$description" "$@"; then
        report_ufw_failure "${description} 失败。UFW 规则可能处于部分写入状态。" "$backup_path"
        return 1
    fi
}

run_ufw_yes_step() {
    local description="$1"
    local backup_path="$2"
    shift 2

    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        run_ufw_step "$description" "$backup_path" "$@"
        return "$?"
    fi

    if ! printf 'y\n' | "$@"; then
        report_ufw_failure "${description} 失败。UFW 规则可能处于部分写入状态。" "$backup_path"
        return 1
    fi
}

configure_ufw() {
    local port=""
    local unique_tcp_ports=""
    local unique_udp_ports=""
    local ssh_source_mode=""
    local ufw_backup_path=""

    section "步骤 2: 配置 UFW 防火墙"
    require_command ufw || return 1

    collect_firewall_ports || {
        [[ "$?" -eq "$INPUT_CANCELLED" ]] && { info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED"; }
        return 1
    }

    prompt_ssh_source_mode ssh_source_mode || {
        info "已返回上一级。"
        return "$INPUT_CANCELLED"
    }

    if [[ "$ssh_source_mode" == "restricted" && -z "$CURRENT_IP" ]]; then
        get_current_ip || {
            [[ "$?" -eq "$INPUT_CANCELLED" ]] && { info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED"; }
            return 1
        }
    fi

    unique_tcp_ports="$(normalize_port_list "$DETECTED_TCP_PORTS" | tr ' ' '\n' | awk -v ssh="$DETECTED_SSH_PORT" '$1 != "" && $1 != ssh { print }' | tr '\n' ' ')"
    unique_tcp_ports="${unique_tcp_ports% }"
    unique_udp_ports="$(normalize_port_list "$DETECTED_UDP_PORTS")"
    unique_udp_ports="${unique_udp_ports% }"

    ui_section "高风险操作确认"
    ui_warn "此操作将重置并重写 UFW 规则："
    ui_kv "影响对象" "/etc/ufw"
    ui_kv "默认入站策略" "deny incoming"
    ui_kv "默认出站策略" "allow outgoing"
    ui_kv "SSH 端口" "${DETECTED_SSH_PORT:-unknown}/tcp"
    ui_kv "代理 TCP 端口" "${unique_tcp_ports:-无}"
    ui_kv "代理 UDP 端口" "${unique_udp_ports:-无}"
    if [[ "$ssh_source_mode" == "restricted" ]]; then
        ui_kv "SSH 来源限制" "$CURRENT_IP"
    else
        ui_kv "SSH 来源限制" "全部来源"
    fi
    ui_kv "备份目录" "$BACKUP_DIR"
    ui_kv "Dry-run" "$(get_dry_run_status_text)"
    ui_blank

    ui_confirm_token "确认重置 UFW 规则？" "RESET-UFW" || return "$INPUT_CANCELLED"

    if ! backup_ufw_config ufw_backup_path; then
        report_ufw_failure "UFW 备份失败，已停止重置流程。" "$ufw_backup_path"
        return 1
    fi
    run_ufw_step "禁用 UFW" "$ufw_backup_path" ufw --force disable || return 1
    run_ufw_yes_step "重置 UFW 规则" "$ufw_backup_path" ufw reset || return 1
    run_ufw_step "设置默认拒绝入站" "$ufw_backup_path" ufw default deny incoming || return 1
    run_ufw_step "设置默认允许出站" "$ufw_backup_path" ufw default allow outgoing || return 1

    if [[ "$ssh_source_mode" == "restricted" ]]; then
        run_ufw_step "允许当前 IP/CIDR 访问 SSH" "$ufw_backup_path" ufw allow from "$CURRENT_IP" to any port "$DETECTED_SSH_PORT" proto tcp comment "Allow SSH from current IP" || return 1
    else
        run_ufw_step "允许 SSH 端口" "$ufw_backup_path" ufw allow "$DETECTED_SSH_PORT/tcp" comment "Allow SSH access" || return 1
    fi

    for port in $unique_tcp_ports; do
        run_ufw_step "允许 TCP 端口 $port" "$ufw_backup_path" ufw allow "$port/tcp" comment "Allow detected TCP service" || return 1
    done
    for port in $unique_udp_ports; do
        run_ufw_step "允许 UDP 端口 $port" "$ufw_backup_path" ufw allow "$port/udp" comment "Allow detected UDP service" || return 1
    done

    run_ufw_step "允许本地回环入站" "$ufw_backup_path" ufw allow in on lo || return 1
    run_ufw_step "允许本地回环出站" "$ufw_backup_path" ufw allow out on lo || return 1
    run_ufw_yes_step "启用 UFW" "$ufw_backup_path" ufw enable || return 1

    if [[ "${SECURE_SERVER_DRY_RUN}" != "1" ]]; then
        ufw status verbose
        ufw status | grep -Eq "${DETECTED_SSH_PORT}/tcp" || {
            report_ufw_failure "UFW 状态中未发现 SSH 端口规则，请立即检查防火墙。" "$ufw_backup_path"
            return 1
        }
    fi
    ok "UFW 配置流程完成。"
}

show_fail2ban_diagnostics() {
    ui_warn "Fail2ban 诊断命令："
    ui_print "fail2ban-client status"
    ui_print "fail2ban-client status sshd"
    ui_print "systemctl status fail2ban --no-pager"
    ui_print "journalctl -u fail2ban -n 80 --no-pager"
}

show_fail2ban_recovery_commands() {
    local backup_file="$1"

    ui_warn "Fail2ban 人工恢复建议："
    if [[ -n "$backup_file" ]]; then
        ui_print "cp ${backup_file} ${FAIL2BAN_SSHD_LOCAL}"
    else
        ui_print "如确认该文件是本次失败写入的新文件，再执行：rm -f ${FAIL2BAN_SSHD_LOCAL}"
    fi
    ui_print "fail2ban-client -t"
    ui_print "systemctl restart fail2ban"
}

restore_fail2ban_config() {
    local backup_file="$1"

    if [[ -n "$backup_file" ]]; then
        restore_file_backup "$backup_file" "$FAIL2BAN_SSHD_LOCAL"
        return "$?"
    fi

    if [[ -e "$FAIL2BAN_SSHD_LOCAL" ]]; then
        run_cmd "移除新增 Fail2ban 配置" rm -f "$FAIL2BAN_SSHD_LOCAL"
        return "$?"
    fi

    return 0
}

report_fail2ban_failure() {
    local message="$1"
    local backup_file="$2"

    err "$message"
    show_fail2ban_diagnostics
    show_fail2ban_recovery_commands "$backup_file"
}

handle_fail2ban_failure_with_restore() {
    local message="$1"
    local backup_file="$2"

    err "$message"
    show_fail2ban_diagnostics

    if ! restore_fail2ban_config "$backup_file"; then
        err "Fail2ban 配置恢复失败。"
        show_fail2ban_recovery_commands "$backup_file"
        return 1
    fi

    ok "已恢复 Fail2ban 配置。"

    if ! fail2ban-client -t; then
        err "恢复后 Fail2ban 配置验证失败。"
        show_fail2ban_diagnostics
        show_fail2ban_recovery_commands "$backup_file"
        return 1
    fi

    if ! systemctl restart fail2ban; then
        err "恢复后 Fail2ban 服务重启失败。"
        show_fail2ban_diagnostics
        show_fail2ban_recovery_commands "$backup_file"
        return 1
    fi

    ok "恢复后的 Fail2ban 配置已验证并重启服务。"
    return 1
}

configure_fail2ban() {
    local tmp_file=""
    local backup_path=""
    local logpath=""

    section "步骤 3: 配置 Fail2ban"
    require_command fail2ban-client || return 1
    require_command systemctl || return 1
    ensure_ufw_banaction_ready || {
        case "$?" in
            "$INPUT_CANCELLED") info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED" ;;
            *) return 1 ;;
        esac
    }
    prompt_fail2ban_ignore_ip || {
        case "$?" in
            "$INPUT_CANCELLED") info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED" ;;
            *) return 1 ;;
        esac
    }

    if [[ -z "$DETECTED_SSH_PORT" ]]; then
        detect_ssh_port || {
            [[ "$?" -eq "$INPUT_CANCELLED" ]] && { info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED"; }
            return 1
        }
    fi

    find_ssh_log_or_backend || true
    if [[ -n "$SSH_LOG_PATH" && "$SSH_LOG_PATH" != "using systemd backend" ]]; then
        logpath="$SSH_LOG_PATH"
    fi

    ui_section "高风险操作确认"
    ui_warn "此操作将写入或覆盖 Fail2ban 配置："
    ui_kv "影响对象" "$FAIL2BAN_SSHD_LOCAL"
    ui_kv "保护服务" "sshd"
    ui_kv "SSH 端口" "${DETECTED_SSH_PORT:-unknown}/tcp"
    ui_kv "后端" "$FAIL2BAN_BACKEND"
    ui_kv "日志路径" "${logpath:-默认/systemd}"
    ui_kv "额外 ignoreip" "${CURRENT_IP:-无}"
    ui_kv "服务重启" "fail2ban"
    ui_kv "备份目录" "$BACKUP_DIR"
    ui_kv "Dry-run" "$(get_dry_run_status_text)"
    ui_blank

    ui_confirm_token "确认覆盖 Fail2ban 配置？" "OVERWRITE-F2B" || return "$INPUT_CANCELLED"

    tmp_file="$(make_tmp_file)" || return 1
    umask 077
    if ! render_fail2ban_sshd_config "$DETECTED_SSH_PORT" "$CURRENT_IP" "$FAIL2BAN_BACKEND" "$logpath" > "$tmp_file"; then
        report_fail2ban_failure "生成 Fail2ban 配置失败，未写入系统配置。" "$backup_path"
        return 1
    fi

    if ! create_backup_dir >/dev/null; then
        report_fail2ban_failure "创建 Fail2ban 备份目录失败，未写入系统配置。" "$backup_path"
        return 1
    fi
    if [[ -f "$FAIL2BAN_SSHD_LOCAL" ]]; then
        if ! backup_path="$(backup_file_if_exists "$FAIL2BAN_SSHD_LOCAL")"; then
            report_fail2ban_failure "备份 Fail2ban 旧配置失败，未覆盖现有配置。" "$backup_path"
            return 1
        fi
        info "Fail2ban 旧配置备份: $backup_path"
    fi

    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        ui_info "DRY-RUN: install ${tmp_file} -> ${FAIL2BAN_SSHD_LOCAL}"
        ok "Fail2ban dry-run 完成。"
        return 0
    fi

    if ! mkdir -p "$FAIL2BAN_JAIL_DIR"; then
        report_fail2ban_failure "创建 Fail2ban jail 目录失败，未写入配置。" "$backup_path"
        return 1
    fi
    if ! install -m 0644 "$tmp_file" "$FAIL2BAN_SSHD_LOCAL"; then
        handle_fail2ban_failure_with_restore "写入 Fail2ban 配置失败，正在尝试恢复。" "$backup_path"
        return 1
    fi

    if ! fail2ban-client -t; then
        handle_fail2ban_failure_with_restore "Fail2ban 配置验证失败，正在尝试恢复。" "$backup_path"
        return 1
    fi

    if ! systemctl restart fail2ban; then
        handle_fail2ban_failure_with_restore "Fail2ban 服务重启失败，正在尝试恢复。" "$backup_path"
        return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet fail2ban; then
        handle_fail2ban_failure_with_restore "Fail2ban 服务未能保持 active 状态，正在尝试恢复。" "$backup_path"
        return 1
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || warn "Fail2ban 开机自启设置失败，请手动检查。"
    fail2ban-client status sshd || warn "无法查询 sshd jail 状态，请检查 Fail2ban 日志。"
    ok "Fail2ban 配置完成。"
}

detect_ssh_service_name() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^ssh.service'; then
        printf 'ssh\n'
    else
        printf 'sshd\n'
    fi
}

sudo_users_available() {
    local sudo_users=""

    if getent group sudo >/dev/null 2>&1; then
        sudo_users="$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' || true)"
    elif getent group wheel >/dev/null 2>&1; then
        sudo_users="$(getent group wheel | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' || true)"
    fi

    [[ -n "$sudo_users" ]]
}

ensure_sshd_include() {
    local tmp_main=""

    tmp_main="$(make_tmp_file)" || return 1
    insert_sshd_include_before_match "$SSH_CONFIG_FILE" > "$tmp_main"
    if cmp -s "$tmp_main" "$SSH_CONFIG_FILE"; then
        return 0
    fi
    run_cmd "写入 sshd_config Include" install -m 0644 "$tmp_main" "$SSH_CONFIG_FILE"
}

show_ssh_diagnostics() {
    ui_warn "SSH 诊断命令："
    ui_print "sshd -t"
    ui_print "systemctl status ssh --no-pager || systemctl status sshd --no-pager"
    ui_print "journalctl -u ssh -n 80 --no-pager || journalctl -u sshd -n 80 --no-pager"
}

show_ssh_recovery_commands() {
    local backup_file="$1"
    local hardening_backup="${2:-}"

    ui_warn "SSH 人工恢复建议："
    if [[ -n "$backup_file" ]]; then
        ui_print "cp ${backup_file} ${SSH_CONFIG_FILE}"
    fi
    if [[ -n "$hardening_backup" ]]; then
        ui_print "cp ${hardening_backup} ${SSHD_HARDENING_FILE}"
    else
        ui_print "rm -f ${SSHD_HARDENING_FILE}"
    fi
    ui_print "sshd -t"
    ui_print "systemctl restart ssh || systemctl restart sshd"
}

restore_ssh_backups() {
    local main_backup="$1"
    local hardening_backup="$2"
    local restore_failed=0

    if [[ -n "$main_backup" ]]; then
        if ! restore_file_backup "$main_backup" "$SSH_CONFIG_FILE"; then
            err "恢复 SSH 主配置失败: ${main_backup} -> ${SSH_CONFIG_FILE}"
            restore_failed=1
        fi
    fi

    if [[ -n "$hardening_backup" ]]; then
        if ! restore_file_backup "$hardening_backup" "$SSHD_HARDENING_FILE"; then
            err "恢复 SSH 加固配置失败: ${hardening_backup} -> ${SSHD_HARDENING_FILE}"
            restore_failed=1
        fi
    elif [[ -e "$SSHD_HARDENING_FILE" ]]; then
        if ! run_cmd "移除新增 SSH 加固配置" rm -f "$SSHD_HARDENING_FILE"; then
            err "移除新增 SSH 加固配置失败: ${SSHD_HARDENING_FILE}"
            restore_failed=1
        fi
    fi

    [[ "$restore_failed" -eq 0 ]]
}

handle_ssh_failure_with_restore() {
    local message="$1"
    local main_backup="$2"
    local hardening_backup="$3"
    local ssh_service_name="${4:-}"

    err "$message"
    show_ssh_diagnostics

    if ! restore_ssh_backups "$main_backup" "$hardening_backup"; then
        err "SSH 配置恢复失败。"
        show_ssh_recovery_commands "$main_backup" "$hardening_backup"
        return 1
    fi

    ok "已恢复 SSH 配置。"

    if ! sshd -t -f "$SSH_CONFIG_FILE"; then
        err "恢复后 SSH 配置验证失败。"
        show_ssh_diagnostics
        show_ssh_recovery_commands "$main_backup" "$hardening_backup"
        return 1
    fi

    [[ -n "$ssh_service_name" ]] || ssh_service_name="$(detect_ssh_service_name)"
    if ! systemctl restart "$ssh_service_name"; then
        err "恢复后 SSH 服务重启失败。"
        show_ssh_diagnostics
        show_ssh_recovery_commands "$main_backup" "$hardening_backup"
        return 1
    fi

    ok "恢复后的 SSH 配置已验证并重启服务。"
    return 1
}

secure_ssh() {
    local permit_root_login="prohibit-password"
    local password_auth="yes"
    local answer_status=0
    local tmp_hardening=""
    local main_backup=""
    local hardening_backup=""
    local ssh_service_name=""

    section "步骤 4: 强化 SSH 配置"
    [[ -f "$SSH_CONFIG_FILE" ]] || { err "SSH 配置文件不存在: $SSH_CONFIG_FILE"; return 1; }
    require_command sshd || return 1
    require_command systemctl || return 1

    ui_warn "禁用 root 或密码登录前，请确认："
    ui_print "- 当前已有一个非 root sudo/wheel 用户"
    ui_print "- 该用户已成功通过 SSH 登录"
    ui_print "- SSH 密钥登录已验证"
    ui_blank

    prompt_yes_no "是否禁用 root 账户通过 SSH 登录" "N"
    answer_status=$?
    case "$answer_status" in
        0)
            if sudo_users_available; then
                permit_root_login="no"
            else
                warn "未检测到非 root sudo/wheel 用户，跳过禁用 root 登录。"
            fi
            ;;
        "$INPUT_CANCELLED") info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED" ;;
    esac

    prompt_yes_no "是否禁用 SSH 密码认证并强制使用密钥登录" "N"
    answer_status=$?
    case "$answer_status" in
        0) password_auth="no" ;;
        "$INPUT_CANCELLED") info "已取消当前操作，返回上一级。"; return "$INPUT_CANCELLED" ;;
    esac

    ui_section "高风险操作确认"
    ui_warn "此操作将修改 SSH 服务配置。请保持当前 SSH 会话并准备备用登录窗口："
    ui_kv "影响对象" "$SSH_CONFIG_FILE"
    ui_kv "加固配置" "$SSHD_HARDENING_FILE"
    ui_kv "SSH 端口" "${DETECTED_SSH_PORT:-unknown}/tcp"
    ui_kv "PermitRootLogin" "$permit_root_login"
    ui_kv "PasswordAuthentication" "$password_auth"
    ui_kv "服务重载" "sshd / ssh"
    ui_kv "备份目录" "$BACKUP_DIR"
    ui_kv "Dry-run" "$(get_dry_run_status_text)"
    ui_blank

    ui_confirm_token "确认执行 SSH 加固？" "HARDEN-SSH" || return "$INPUT_CANCELLED"

    tmp_hardening="$(make_tmp_file)" || return 1
    render_sshd_hardening_config "$permit_root_login" "$password_auth" > "$tmp_hardening"

    main_backup="$(backup_file_if_exists "$SSH_CONFIG_FILE")" || return 1
    if [[ -f "$SSHD_HARDENING_FILE" ]]; then
        hardening_backup="$(backup_file_if_exists "$SSHD_HARDENING_FILE")" || return 1
    fi

    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        ui_info "DRY-RUN: install hardening config -> ${SSHD_HARDENING_FILE}"
        ok "SSH dry-run 完成。"
        return 0
    fi

    if ! mkdir -p "$SSHD_CONFIG_DIR"; then
        handle_ssh_failure_with_restore "创建 SSH 配置目录失败，正在尝试恢复。" "$main_backup" "$hardening_backup"
        return 1
    fi
    if ! ensure_sshd_include; then
        handle_ssh_failure_with_restore "写入 sshd_config Include 失败，正在尝试恢复。" "$main_backup" "$hardening_backup"
        return 1
    fi
    if ! install -m 0644 "$tmp_hardening" "$SSHD_HARDENING_FILE"; then
        handle_ssh_failure_with_restore "写入 SSH 加固配置失败，正在尝试恢复。" "$main_backup" "$hardening_backup"
        return 1
    fi

    if ! sshd -t -f "$SSH_CONFIG_FILE"; then
        handle_ssh_failure_with_restore "SSH 配置验证失败，正在尝试恢复。" "$main_backup" "$hardening_backup"
        return 1
    fi

    ssh_service_name="$(detect_ssh_service_name)"
    if ! systemctl restart "$ssh_service_name"; then
        handle_ssh_failure_with_restore "SSH 服务重启失败，正在尝试恢复。" "$main_backup" "$hardening_backup" "$ssh_service_name"
        return 1
    fi

    sleep 2
    if ! systemctl is-active --quiet "$ssh_service_name"; then
        handle_ssh_failure_with_restore "SSH 服务未处于 active 状态，正在尝试恢复。" "$main_backup" "$hardening_backup" "$ssh_service_name"
        return 1
    fi
    ok "SSH 配置强化完成。请保持当前会话并用新 SSH 会话验证登录。"
}

run_all_steps() {
    section "执行所有步骤"
    ui_section "高风险操作确认"
    ui_warn "此操作将连续执行多项系统安全修改："
    ui_kv "包含动作" "安装依赖 / UFW / Fail2ban / SSH 加固"
    ui_kv "可能影响" "远程登录、防火墙访问、封禁策略"
    ui_kv "Dry-run" "$(get_dry_run_status_text)"
    ui_blank
    ui_confirm_token "确认执行全套加固？" "APPLY-HARDENING" || return "$INPUT_CANCELLED"

    install_packages &&
        configure_ufw &&
        configure_fail2ban &&
        secure_ssh
}

show_ufw_status() {
    section "UFW 状态"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose
    else
        warn "UFW 未安装或不可用。"
    fi
}

show_fail2ban_status() {
    section "Fail2ban SSH jail 状态"
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        warn "Fail2ban 未安装或不可用。"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
        fail2ban-client status sshd
    else
        warn "Fail2ban 服务当前未运行。"
    fi
}

get_ufw_state() {
    local state=""
    if ! command -v ufw >/dev/null 2>&1; then
        printf 'missing'
        return 0
    fi
    state="$(ufw status 2>/dev/null | awk -F': ' '/^Status:/ { print $2; exit }')"
    printf '%s' "${state:-unknown}"
}

ensure_ufw_banaction_ready() {
    local state=""
    require_command ufw || {
        ui_error "当前 Fail2ban 配置使用 banaction = ufw，但未检测到 ufw。"
        ui_warn "请先执行依赖安装 / UFW 配置，或手动安装 ufw。"
        return 1
    }
    state="$(get_ufw_state)"
    if [[ "${state}" != "active" ]]; then
        ui_warn "UFW 当前状态为 ${state}。Fail2ban 可写入配置，但 ban 动作可能不会实际生效。"
        ui_confirm "是否仍然继续写入 Fail2ban 配置" "n" || return "$?"
    fi
    return 0
}

get_fail2ban_state() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        printf 'missing'
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
        printf 'active'
    else
        printf 'inactive'
    fi
}

get_menu_ssh_label() {
    local port="${DETECTED_SSH_PORT:-}"
    [[ -n "$port" ]] || port="$(detect_ssh_port_from_file "$SSH_CONFIG_FILE")"
    if [[ -n "$port" ]]; then
        printf '%s/tcp' "$port"
    else
        printf 'unknown'
    fi
}

get_dry_run_status_text() {
    if [[ "${SECURE_SERVER_DRY_RUN}" == "1" ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

build_status_line() {
    printf 'UFW: %s | Fail2ban: %s | SSH: %s | Dry-run: %s' \
        "$(get_ufw_state)" \
        "$(get_fail2ban_state)" \
        "$(get_menu_ssh_label)" \
        "$(get_dry_run_status_text)"
}

ui_menu_footer() {
    ui_dim "主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。"
    ui_dim "普通输入：输入 q 取消当前操作。"
}

show_main_menu_loop() {
    local choice=""
    local should_pause=false

    while true; do
        should_pause=false
        ui_render_title
        ui_dim "$(build_status_line)"
        ui_blank
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "安装 UFW 和 Fail2ban 依赖"
        ui_menu_item 2 "配置 UFW 防火墙（将重置现有规则）"
        ui_menu_item 3 "配置 Fail2ban"
        ui_menu_item 4 "强化 SSH 配置"
        ui_menu_item 5 "执行所有步骤 (1-4)"
        ui_menu_item 6 "查看 UFW 状态"
        ui_menu_item 7 "查看 Fail2ban SSH jail 状态"
        ui_menu_item 0 "退出"
        ui_blank
        ui_menu_footer
        ui_blank
        ui_read_main_menu_choice choice

        case "$choice" in
            1) ui_run_menu_action "安装依赖" install_packages; should_pause=true ;;
            2) ui_run_menu_action "配置 UFW 防火墙" configure_ufw; should_pause=true ;;
            3) ui_run_menu_action "配置 Fail2ban" configure_fail2ban; should_pause=true ;;
            4) ui_run_menu_action "强化 SSH 配置" secure_ssh; should_pause=true ;;
            5) ui_run_menu_action "执行所有步骤" run_all_steps; should_pause=true ;;
            6) ui_run_menu_action "查看 UFW 状态" show_ufw_status; should_pause=true ;;
            7) ui_run_menu_action "查看 Fail2ban SSH jail 状态" show_fail2ban_status; should_pause=true ;;
            0) ui_blank; ui_info "已退出。"; exit 0 ;;
            *) err "无效选项，请输入 0 到 7。" ;;
        esac

        $should_pause && pause_before_menu
    done
}

main() {
    ui_init_colors
    ui_init_prompt_input
    parse_arguments "$@" || return 1

    case "${COMMAND}" in
        help)
            show_help
            return 0
            ;;
        menu)
            require_root || return 1
            show_main_menu_loop
            ;;
        *)
            ui_error "未知命令：${COMMAND}"
            return 1
            ;;
    esac
}

if [[ "${SECURE_SERVER_TEST_MODE:-0}" != "1" ]] && [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
