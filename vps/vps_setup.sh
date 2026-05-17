#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 脚本意图: VPS 通用初始化入口，支持独立公网 IP 与 NAT VPS 两种 profile
# 用法示例:
#   bash vps_setup.sh --profile public
#   bash vps_setup.sh --profile nat --yes
#   bash vps_setup.sh --profile public --install-docker --ssh-port 2222
# ==============================================================================

readonly SCRIPT_DISPLAY_NAME="VPS 初始化向导"
readonly SCRIPT_VERSION="2026.05.16-r2"

UI_COLOR_RESET=''
UI_COLOR_RED=''
UI_COLOR_GREEN=''
UI_COLOR_YELLOW=''
UI_COLOR_BLUE=''
UI_COLOR_CYAN=''
UI_COLOR_BOLD=''
UI_COLOR_DIM=''
UI_PROMPT_FD=0
UI_TITLE_WIDTH=60
UI_KV_LABEL_WIDTH=18
UI_RETURN_TO_MENU=130

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
        UI_COLOR_RESET=''
        UI_COLOR_RED=''
        UI_COLOR_GREEN=''
        UI_COLOR_YELLOW=''
        UI_COLOR_BLUE=''
        UI_COLOR_CYAN=''
        UI_COLOR_BOLD=''
        UI_COLOR_DIM=''
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

ui_info() { printf '%b\n' "${UI_COLOR_CYAN}[i]${UI_COLOR_RESET} $*"; }
ui_ok() { printf '%b\n' "${UI_COLOR_GREEN}[OK]${UI_COLOR_RESET} $*"; }
ui_warn() { printf '%b\n' "${UI_COLOR_YELLOW}[WARN]${UI_COLOR_RESET} $*" >&2; }
ui_error() { printf '%b\n' "${UI_COLOR_RED}[ERROR]${UI_COLOR_RESET} $*" >&2; }
ui_dim() { printf '%b\n' "${UI_COLOR_DIM}$*${UI_COLOR_RESET}"; }
ui_print() { printf '%b\n' "$*"; }
ui_blank() { printf '\n'; }
ui_rule() { printf '%s\n' "------------------------------------------------------------"; }
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
    local text="$1" width="${2:-${UI_TITLE_WIDTH}}" text_width padding
    text_width="$(ui_text_width "${text}")"
    padding=$(((width - text_width) / 2))
    ((padding < 0)) && padding=0
    printf '%*s%s\n' "${padding}" '' "${text}"
}

ui_kv() {
    local label="$1" value="${2:-}" label_width padding

    label_width="$(ui_text_width "${label}")"
    padding=$((UI_KV_LABEL_WIDTH - label_width))
    ((padding < 1)) && padding=1

    printf '%s%*s%s\n' "${label}" "${padding}" '' "${value}"
}

ui_menu_item() {
    local number="$1" label="$2"
    printf ' %2s. %s\n' "${number}" "${label}"
}

ui_title() {
    local title="$1" version="${2:-}" rule

    printf -v rule '%*s' "${UI_TITLE_WIDTH}" ''
    rule="${rule// /=}"

    printf '%b\n' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}${rule}${UI_COLOR_RESET}"
    printf '%b' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}"
    ui_center_line "${title}" "${UI_TITLE_WIDTH}"
    if [[ -n "${version}" ]]; then
        ui_center_line "Version: ${version}" "${UI_TITLE_WIDTH}"
    fi
    printf '%b\n' "${UI_COLOR_RESET}${UI_COLOR_CYAN}${UI_COLOR_BOLD}${rule}${UI_COLOR_RESET}"
}

ui_init_prompt_input() {
    if [[ -r /dev/tty ]] && { exec 3</dev/tty; } 2>/dev/null; then
        UI_PROMPT_FD=3
    else
        UI_PROMPT_FD=0
    fi
    PROMPT_FD="${UI_PROMPT_FD}"
}

ui_read_raw() {
    local __target="$1" __prompt="$2" __value __fd
    __fd="${UI_PROMPT_FD:-0}"
    if [[ "${__fd}" == "0" && "${PROMPT_FD:-0}" != "0" ]]; then
        __fd="${PROMPT_FD}"
    fi

    if ! IFS= read -r -u "${__fd}" -p "${__prompt}" __value; then
        printf '\n' >&2
        ui_error "无法读取交互式输入。请在交互式终端运行脚本，或使用 --yes 配合必要参数。"
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

ui_cancel_script() {
    ui_warn "用户取消操作，脚本已退出。"
    exit "${UI_RETURN_TO_MENU}"
}

display_status_info() { ui_info "$@"; }
display_status_success() { ui_ok "$@"; }
display_status_warning() { ui_warn "$@"; }
display_status_error() { ui_error "$@"; }

GLOBAL_PROFILE="${VPS_PROFILE:-}"
GLOBAL_TIMEZONE="${VPS_TIMEZONE:-Asia/Singapore}"
GLOBAL_ASSUME_YES=false
GLOBAL_INSTALL_DOCKER=false
GLOBAL_INSTALL_NODEJS=false
GLOBAL_INSTALL_CLOUD_KERNEL=false
GLOBAL_SSH_PORT=""
GLOBAL_PKG_MANAGER=""
GLOBAL_BIND_UTILS=""
GLOBAL_OS_ID=""
GLOBAL_OS_NAME=""
GLOBAL_OS_VERSION=""
GLOBAL_LOG_FILE=""
PROMPT_FD=0

show_usage() {
    cat <<'EOF'
VPS 初始化向导

用法：
  sudo bash vps_setup.sh [options]

Options:
  --profile public|nat       VPS 类型。public=独立公网 IP，nat=NAT VPS。
  --timezone Zone/Name       设置时区，默认 Asia/Singapore。
  --yes                      非交互执行，公共可选组件默认不安装，并跳过执行前确认。
  --install-docker           public profile 可选：通过系统包管理器安装 Docker。
  --install-nodejs           public profile 可选：通过系统包管理器安装 Node.js/npm。
  --install-cloud-kernel     public profile 可选：Debian 安装 linux-image-cloud-amd64。
  --ssh-port PORT            public profile 可选：新增 SSH 监听端口，并保留已有端口。
  -h, --help                 显示帮助。
EOF
}

die_usage() {
    display_status_error "$1"
    show_usage
    exit 2
}

cancel_script() {
    ui_cancel_script
}

handle_unexpected_error() {
    local exit_code=$?
    local line_number=$1

    display_status_error "脚本在第 ${line_number} 行失败，退出码 ${exit_code}。"
    if [ -n "${GLOBAL_LOG_FILE}" ]; then
        display_status_error "详细日志: ${GLOBAL_LOG_FILE}"
    fi
    exit "${exit_code}"
}

init_prompt_input() {
    ui_init_prompt_input
}

read_prompt() {
    ui_read_raw "$@"
}

prompt_yes_no() {
    ui_confirm "$@"
}

init_log_file() {
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    GLOBAL_LOG_FILE="/var/log/vps_setup_${timestamp}.log"

    if ! : > "${GLOBAL_LOG_FILE}" 2>/dev/null; then
        GLOBAL_LOG_FILE="/tmp/vps_setup_${timestamp}.log"
        : > "${GLOBAL_LOG_FILE}"
    fi

    chmod 600 "${GLOBAL_LOG_FILE}" 2>/dev/null || true
    ui_info "Log file: ${GLOBAL_LOG_FILE}"
}

run_logged() {
    if [ -n "${GLOBAL_LOG_FILE}" ]; then
        {
            printf '\n[%s] $' "$(date '+%F %T')"
            printf ' %q' "$@"
            printf '\n'
        } >> "${GLOBAL_LOG_FILE}"
        "$@" >> "${GLOBAL_LOG_FILE}" 2>&1
    else
        "$@"
    fi
}

require_option_value() {
    local option_name="$1"
    local option_value="${2:-}"

    if [[ -z "${option_value}" || "${option_value}" == --* ]]; then
        die_usage "${option_name} 缺少参数值。"
    fi
}

validate_profile_name() {
    local profile="$1"
    [[ "${profile}" == "public" || "${profile}" == "nat" ]]
}

validate_port_number() {
    local port="${1:-}"
    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

validate_timezone_name() {
    local timezone="$1"

    [[ -n "${timezone}" ]] || return 1
    [[ "${timezone}" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] || return 1
    [[ "${timezone}" != *".."* ]] || return 1

    if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/${timezone}" ]; then
        return 1
    fi

    return 0
}

parse_arguments() {
    if [ $# -eq 0 ] && [ -z "${BASH_SOURCE[0]:-}" ]; then
        case "${0:-}" in
            -h|--help)
                set -- "${0}"
                ;;
        esac
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --profile)
                require_option_value "$1" "${2:-}"
                GLOBAL_PROFILE="$2"
                shift 2
                ;;
            --timezone)
                require_option_value "$1" "${2:-}"
                GLOBAL_TIMEZONE="$2"
                shift 2
                ;;
            --yes)
                GLOBAL_ASSUME_YES=true
                shift
                ;;
            --install-docker)
                GLOBAL_INSTALL_DOCKER=true
                shift
                ;;
            --install-nodejs)
                GLOBAL_INSTALL_NODEJS=true
                shift
                ;;
            --install-cloud-kernel)
                GLOBAL_INSTALL_CLOUD_KERNEL=true
                shift
                ;;
            --ssh-port)
                require_option_value "$1" "${2:-}"
                GLOBAL_SSH_PORT="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                die_usage "未知参数: $1"
                ;;
        esac
    done
}

validate_static_configuration() {
    if [ -n "${GLOBAL_PROFILE}" ] && ! validate_profile_name "${GLOBAL_PROFILE}"; then
        die_usage "不支持的 profile: ${GLOBAL_PROFILE}。仅支持 public 或 nat。"
    fi

    if [ -z "${GLOBAL_PROFILE}" ] && [ "${GLOBAL_ASSUME_YES}" = true ]; then
        die_usage "--yes 模式必须显式传入 --profile public 或 --profile nat。"
    fi

    if ! validate_timezone_name "${GLOBAL_TIMEZONE}"; then
        die_usage "时区名称不合法或系统未找到该时区: ${GLOBAL_TIMEZONE}"
    fi

    if [ -n "${GLOBAL_SSH_PORT}" ] && ! validate_port_number "${GLOBAL_SSH_PORT}"; then
        die_usage "SSH 端口不合法: ${GLOBAL_SSH_PORT}。端口范围必须为 1-65535。"
    fi
}

validate_root_privilege() {
    ui_info "正在校验 root 权限..."
    if [[ ${EUID} -ne 0 ]]; then
        ui_error "权限不足：请以 root 身份或使用 sudo 执行此脚本。"
        exit 1
    fi
    ui_ok "root 权限校验通过。"
}

select_vps_profile() {
    local selected_profile

    while [ -z "${GLOBAL_PROFILE}" ]; do
        ui_blank
        ui_print "请选择 VPS 类型："
        ui_blank
        ui_menu_item "1" "public - 独立公网 IP VPS"
        ui_menu_item "2" "nat - NAT VPS / 共享公网出口"
        ui_blank
        read_prompt selected_profile "请输入 VPS 类型编号（1-2，q 取消）： "
        case "${selected_profile}" in
            1) GLOBAL_PROFILE="public" ;;
            2) GLOBAL_PROFILE="nat" ;;
            q|Q) cancel_script ;;
            0) ui_warn "一次性向导请使用 q 取消。" ;;
            *) ui_warn "无效选项，请输入 1、2 或 q。" ;;
        esac
    done

    if ! validate_profile_name "${GLOBAL_PROFILE}"; then
        ui_error "不支持的 profile: ${GLOBAL_PROFILE}。仅支持 public 或 nat。"
        exit 2
    fi

    ui_ok "已选择 profile: ${GLOBAL_PROFILE}"
}

format_bool_cn() {
    if [ "${1:-false}" = true ]; then
        printf '%s\n' "是"
    else
        printf '%s\n' "否"
    fi
}

get_run_mode() {
    if [ "${GLOBAL_ASSUME_YES}" = true ]; then
        printf '%s\n' "noninteractive (--yes)"
    else
        printf '%s\n' "interactive"
    fi
}

show_startup_context() {
    ui_dim "Profile: ${GLOBAL_PROFILE:-pending} | Mode: $(get_run_mode) | Timezone: ${GLOBAL_TIMEZONE} | Log: pending"
}

show_execution_summary() {
    ui_section "执行摘要"
    ui_kv "VPS 类型" "${GLOBAL_PROFILE}"
    ui_kv "运行模式" "$(get_run_mode)"
    ui_kv "系统时区" "${GLOBAL_TIMEZONE}"
    ui_kv "安装 Docker" "$(format_bool_cn "${GLOBAL_INSTALL_DOCKER}")"
    ui_kv "安装 Node.js/npm" "$(format_bool_cn "${GLOBAL_INSTALL_NODEJS}")"
    ui_kv "安装 Debian Kernel" "$(format_bool_cn "${GLOBAL_INSTALL_CLOUD_KERNEL}")"
    if [ -n "${GLOBAL_SSH_PORT}" ]; then
        ui_kv "SSH 端口" "新增监听 ${GLOBAL_SSH_PORT}，并保留已有端口"
    else
        ui_kv "SSH 端口" "不修改"
    fi
    ui_kv "自动任务" "Swap / 时区 / 基础工具 / 网络调优 / 清理"
}

confirm_execution_plan() {
    local confirm_status

    if [ "${GLOBAL_ASSUME_YES}" = true ]; then
        return 0
    fi

    ui_blank
    ui_confirm_or_yes "确认继续执行以上任务？" "n" "${GLOBAL_ASSUME_YES}"
    confirm_status=$?

    case "${confirm_status}" in
        0)
            return 0
            ;;
        "${UI_RETURN_TO_MENU}")
            cancel_script
            ;;
        *)
            ui_warn "用户未确认执行，脚本已退出。"
            exit 0
            ;;
    esac
}

detect_operating_system_environment() {
    local ID=""
    local NAME=""
    local VERSION_ID=""

    display_status_info "正在探测操作系统与包管理器..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        GLOBAL_OS_ID="${ID:-unknown}"
        GLOBAL_OS_NAME="${NAME:-unknown}"
        GLOBAL_OS_VERSION="${VERSION_ID:-unknown}"
        display_status_success "识别到系统: ${GLOBAL_OS_NAME} (${GLOBAL_OS_VERSION})"
    else
        display_status_error "无法探测操作系统类型，文件 /etc/os-release 缺失。"
        exit 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        GLOBAL_PKG_MANAGER="apt-get"
        GLOBAL_BIND_UTILS="dnsutils"
    elif command -v dnf >/dev/null 2>&1; then
        GLOBAL_PKG_MANAGER="dnf"
        GLOBAL_BIND_UTILS="bind-utils"
    else
        display_status_error "不支持当前系统的包管理器，仅支持 apt-get 或 dnf。"
        exit 1
    fi

    display_status_success "已绑定主包管理器: ${GLOBAL_PKG_MANAGER}"
}

run_package_update() {
    if [[ "${GLOBAL_PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        run_logged apt-get update
    elif [[ "${GLOBAL_PKG_MANAGER}" == "dnf" ]]; then
        if ! dnf repolist enabled | grep -q "epel"; then
            run_logged dnf install -y epel-release || display_status_warning "EPEL 安装失败或不可用，继续使用现有软件源。"
        fi
        run_logged dnf makecache -y
    fi
}

install_packages() {
    if [ $# -eq 0 ]; then
        return 0
    fi

    if [[ "${GLOBAL_PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        run_logged apt-get install -y "$@"
    elif [[ "${GLOBAL_PKG_MANAGER}" == "dnf" ]]; then
        run_logged dnf install -y "$@"
    fi
}

upgrade_system_packages() {
    display_status_info "正在同步软件源并升级系统组件..."
    run_package_update
    if [[ "${GLOBAL_PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        run_logged apt-get upgrade -y
    elif [[ "${GLOBAL_PKG_MANAGER}" == "dnf" ]]; then
        run_logged dnf update -y
    fi
    display_status_success "系统组件升级完毕。"
}

configure_virtual_memory_swap() {
    display_status_info "正在配置虚拟内存 (Swap)..."
    if [[ -f /mnt/swap ]]; then
        display_status_warning "交换文件 /mnt/swap 已存在，跳过创建。"
        return
    fi

    local memory_total_mb
    memory_total_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)

    local swap_target_size_mb
    if [[ "${GLOBAL_PROFILE}" == "nat" ]]; then
        if ((memory_total_mb < 1024)); then
            swap_target_size_mb=$((memory_total_mb * 2))
        else
            swap_target_size_mb=1024
        fi
    else
        if ((memory_total_mb < 1024)); then
            swap_target_size_mb=1024
        elif ((memory_total_mb < 2048)); then
            swap_target_size_mb="${memory_total_mb}"
        else
            swap_target_size_mb=2048
        fi
    fi

    local available_space_mb
    available_space_mb=$(df -Pm /mnt | awk 'NR==2 {print $4}')
    if ((available_space_mb < swap_target_size_mb + 128)); then
        display_status_warning "/mnt 可用空间不足，跳过 Swap 创建。"
        return
    fi

    if command -v fallocate >/dev/null 2>&1; then
        if ! run_logged fallocate -l "${swap_target_size_mb}M" /mnt/swap; then
            rm -f /mnt/swap
        fi
    fi

    if [[ ! -f /mnt/swap ]]; then
        run_logged dd if=/dev/zero of=/mnt/swap bs=1M count="${swap_target_size_mb}" status=none
    fi

    chmod 600 /mnt/swap

    if run_logged mkswap /mnt/swap && run_logged swapon /mnt/swap; then
        if ! grep -Eq '^[[:space:]]*/mnt/swap[[:space:]]+swap[[:space:]]+swap[[:space:]]' /etc/fstab; then
            printf '/mnt/swap swap swap defaults 0 0\n' >> /etc/fstab
        fi

        printf 'vm.swappiness = 10\n' > /etc/sysctl.d/98-vps-swap.conf
        run_logged sysctl -w vm.swappiness=10 || display_status_warning "Swap 已启用，但运行时 swappiness 写入失败；重启后将按配置生效。"
        display_status_success "Swap 已挂载并激活，大小: ${swap_target_size_mb}MB。"
    else
        display_status_warning "当前虚拟化架构不支持自行挂载 Swap，已清理本次创建的交换文件并跳过。"
        rm -f /mnt/swap
    fi
}

calibrate_system_timezone() {
    display_status_info "正在校准系统时区为 ${GLOBAL_TIMEZONE}..."
    if ! command -v timedatectl >/dev/null 2>&1; then
        display_status_warning "timedatectl 不可用，跳过时区配置。"
        return
    fi

    local current_timezone
    current_timezone=$(timedatectl | awk -F': ' '/Time zone/ {print $2}' | awk '{print $1}')

    if [[ "${current_timezone}" == "${GLOBAL_TIMEZONE}" ]]; then
        display_status_success "时区已是 ${GLOBAL_TIMEZONE}。"
    else
        run_logged timedatectl set-timezone "${GLOBAL_TIMEZONE}"
        display_status_success "系统时区已校准为 ${GLOBAL_TIMEZONE}。"
    fi
}

install_essential_utilities() {
    display_status_info "正在验证并安装必备运维工具箱..."

    local dependencies=("sudo" "curl" "jq" "wget" "unzip" "ca-certificates" "${GLOBAL_BIND_UTILS}")
    if [[ "${GLOBAL_PROFILE}" == "public" ]]; then
        dependencies+=("git" "vim" "net-tools")
    else
        dependencies+=("dkms")
    fi

    install_packages "${dependencies[@]}"
    display_status_success "运维工具箱安装校验完成。"
}

backup_existing_file() {
    local target_file="$1"
    local timestamp
    local backup_file

    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_file="${target_file}.bak_${timestamp}"
    cp -p "${target_file}" "${backup_file}"
    printf '%s\n' "${backup_file}"
}

restore_file_from_backup() {
    local target_file="$1"
    local backup_file="$2"

    if [ -n "${backup_file}" ] && [ -f "${backup_file}" ]; then
        cp -p "${backup_file}" "${target_file}"
    else
        rm -f "${target_file}"
    fi
}

optimize_kernel_sysctl_network() {
    display_status_info "正在注入 ${GLOBAL_PROFILE} VPS 网络调优参数..."
    local sysctl_config_file="/etc/sysctl.d/99-vps-network.conf"
    local backup_file=""

    if [ -f "${sysctl_config_file}" ]; then
        backup_file="$(backup_existing_file "${sysctl_config_file}")"
        display_status_info "已备份旧网络调优配置: ${backup_file}"
    fi

    if [[ "${GLOBAL_PROFILE}" == "nat" ]]; then
        cat > "${sysctl_config_file}" <<'EOF'
# NAT VPS: 轻量级客户端侧网络调优
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = 262144
EOF
    else
        cat > "${sysctl_config_file}" <<'EOF'
# 独立公网 IP VPS: 服务端吞吐与连接性能调优
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_default = 262144
net.core.rmem_max = 6291456
net.core.wmem_default = 262144
net.core.wmem_max = 4194304
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF
    fi

    run_logged modprobe tcp_bbr || true
    if ! run_logged sysctl --system; then
        restore_file_from_backup "${sysctl_config_file}" "${backup_file}"
        display_status_warning "网络调优配置加载失败，已恢复旧配置。请查看日志确认不兼容参数。"
        return
    fi

    local active_congestion_algo
    active_congestion_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)

    if [[ "${active_congestion_algo}" == "bbr" ]]; then
        display_status_success "网络调优已注入，BBR 已生效。"
    else
        display_status_warning "网络调优已注入，但当前内核或虚拟化环境未启用 BBR。"
    fi
}

set_optional_flag_from_prompt() {
    local flag_var="$1"
    local prompt_text="$2"
    local status

    if [ "${!flag_var}" = true ]; then
        return
    fi

    if [ "${GLOBAL_ASSUME_YES}" != true ]; then
        ui_blank
    fi
    if ui_confirm_or_default "${prompt_text}" "n" "${GLOBAL_ASSUME_YES}"; then
        printf -v "${flag_var}" '%s' "true"
        return
    fi

    status=$?
    if [ "${status}" -eq "${UI_RETURN_TO_MENU}" ]; then
        cancel_script
    fi
}

configure_public_optional_features() {
    if [[ "${GLOBAL_PROFILE}" != "public" ]]; then
        return
    fi

    if [ "${GLOBAL_ASSUME_YES}" != true ] && {
        [ "${GLOBAL_INSTALL_DOCKER}" = false ] ||
        [ "${GLOBAL_INSTALL_NODEJS}" = false ] ||
        [ "${GLOBAL_INSTALL_CLOUD_KERNEL}" = false ]
    }; then
        ui_section "可选组件"
        ui_print "以下组件默认不安装，可按需启用。"
    fi

    set_optional_flag_from_prompt GLOBAL_INSTALL_DOCKER "是否安装 Docker 运行时？"
    set_optional_flag_from_prompt GLOBAL_INSTALL_NODEJS "是否安装 Node.js/npm？"
    set_optional_flag_from_prompt GLOBAL_INSTALL_CLOUD_KERNEL "是否安装 Debian Cloud Kernel？"
}

install_docker_runtime() {
    if [ "${GLOBAL_INSTALL_DOCKER}" = false ]; then
        return
    fi

    display_status_info "正在安装 Docker 运行时..."
    if command -v docker >/dev/null 2>&1; then
        display_status_success "Docker 已安装，跳过。"
        return
    fi

    if [[ "${GLOBAL_PKG_MANAGER}" == "apt-get" ]]; then
        install_packages docker.io docker-compose-plugin || install_packages docker.io docker-compose
    else
        install_packages docker || install_packages moby-engine
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^docker.service'; then
        run_logged systemctl enable --now docker || display_status_warning "Docker 已安装，但服务启用失败，请手动检查 systemd 状态。"
    fi

    if command -v docker >/dev/null 2>&1; then
        display_status_success "Docker 安装完成。"
    else
        display_status_warning "Docker 安装未完成，请检查发行版软件源。"
    fi
}

install_nodejs_runtime() {
    if [ "${GLOBAL_INSTALL_NODEJS}" = false ]; then
        return
    fi

    display_status_info "正在通过系统包管理器安装 Node.js/npm..."
    install_packages nodejs npm

    if command -v node >/dev/null 2>&1; then
        display_status_success "Node.js 安装完成: $(node -v)"
    else
        display_status_warning "Node.js 安装未完成，请检查发行版软件源。"
    fi
}

install_debian_cloud_kernel() {
    if [ "${GLOBAL_INSTALL_CLOUD_KERNEL}" = false ]; then
        return
    fi

    if [[ "${GLOBAL_PKG_MANAGER}" != "apt-get" || "${GLOBAL_OS_ID}" != "debian" ]]; then
        display_status_warning "Cloud Kernel 仅在 Debian apt 环境下自动安装，当前系统跳过。"
        return
    fi

    display_status_info "正在安装 Debian Cloud Kernel..."
    install_packages linux-image-cloud-amd64
    if command -v update-grub >/dev/null 2>&1; then
        run_logged update-grub
    fi
    display_status_success "Debian Cloud Kernel 安装流程完成，请在维护窗口重启后确认内核。"
}

active_ssh_port_directives_exist() {
    local ssh_config_file="$1"
    local include_file

    if grep -Eq '^[[:space:]]*Port[[:space:]]+[0-9]+' "${ssh_config_file}"; then
        return 0
    fi

    ssh_config_uses_dropin_dir "${ssh_config_file}" || return 1
    for include_file in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "${include_file}" ] || continue
        grep -Eq '^[[:space:]]*Port[[:space:]]+[0-9]+' "${include_file}" && return 0
    done

    return 1
}

ssh_port_already_configured() {
    local ssh_config_file="$1"
    local port="$2"
    local include_file

    if grep -Eq "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" "${ssh_config_file}"; then
        return 0
    fi

    ssh_config_uses_dropin_dir "${ssh_config_file}" || return 1
    for include_file in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "${include_file}" ] || continue
        grep -Eq "^[[:space:]]*Port[[:space:]]+${port}([[:space:]]|$)" "${include_file}" && return 0
    done

    return 1
}

ssh_config_uses_dropin_dir() {
    local ssh_config_file="$1"
    grep -Eq '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf' "${ssh_config_file}"
}

select_ssh_port_config_file() {
    local ssh_config_file="$1"
    local include_dir="/etc/ssh/sshd_config.d"

    if [ -d "${include_dir}" ] && ssh_config_uses_dropin_dir "${ssh_config_file}"; then
        printf '%s\n' "${include_dir}/99-vps-setup-port.conf"
    else
        printf '%s\n' "${ssh_config_file}"
    fi
}

is_tcp_port_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

apply_firewall_ssh_port() {
    local port="$1"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        if run_logged ufw allow "${port}/tcp"; then
            display_status_success "已通过 UFW 放行 SSH 新端口 ${port}/tcp。"
        else
            display_status_warning "UFW 端口放行失败，请手动确认 ${port}/tcp 可达。"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        if run_logged firewall-cmd --permanent --add-port="${port}/tcp" && run_logged firewall-cmd --reload; then
            display_status_success "已通过 firewalld 放行 SSH 新端口 ${port}/tcp。"
        else
            display_status_warning "firewalld 端口放行失败，请手动确认 ${port}/tcp 可达。"
        fi
    else
        display_status_warning "未检测到活跃防火墙，未自动写入防火墙规则。请手动确认新 SSH 端口可达。"
    fi
}

detect_ssh_service_name() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^ssh.service'; then
        printf '%s\n' "ssh"
    else
        printf '%s\n' "sshd"
    fi
}

reload_ssh_service_or_restore() {
    local ssh_config_target="$1"
    local backup_file="$2"
    local sshd_binary="$3"
    local ssh_service_name

    if ! "${sshd_binary}" -t; then
        restore_file_from_backup "${ssh_config_target}" "${backup_file}"
        display_status_error "SSH 配置语法检查失败，已恢复备份。"
        exit 1
    fi

    ssh_service_name="$(detect_ssh_service_name)"

    if command -v systemctl >/dev/null 2>&1; then
        if run_logged systemctl reload "${ssh_service_name}" || run_logged systemctl restart "${ssh_service_name}"; then
            return
        fi

        restore_file_from_backup "${ssh_config_target}" "${backup_file}"
        run_logged systemctl restart "${ssh_service_name}" || true
        display_status_error "SSH 服务重载/重启失败，已尝试恢复备份。"
        exit 1
    fi

    if run_logged service "${ssh_service_name}" reload || run_logged service "${ssh_service_name}" restart; then
        return
    fi

    restore_file_from_backup "${ssh_config_target}" "${backup_file}"
    run_logged service "${ssh_service_name}" restart || true
    display_status_error "SSH 服务重载/重启失败，已尝试恢复备份。"
    exit 1
}

configure_ssh_port() {
    if [ -z "${GLOBAL_SSH_PORT}" ]; then
        return
    fi

    if [[ "${GLOBAL_PROFILE}" != "public" ]]; then
        display_status_warning "--ssh-port 仅适用于 public profile，当前跳过。"
        return
    fi

    if ! validate_port_number "${GLOBAL_SSH_PORT}"; then
        display_status_error "SSH 端口不合法: ${GLOBAL_SSH_PORT}"
        exit 2
    fi

    local ssh_config_file="/etc/ssh/sshd_config"
    if [ ! -f "${ssh_config_file}" ]; then
        display_status_warning "未找到 ${ssh_config_file}，跳过 SSH 端口修改。"
        return
    fi

    local sshd_binary
    sshd_binary="$(command -v sshd || true)"
    if [ -z "${sshd_binary}" ]; then
        display_status_warning "未找到 sshd 命令，跳过 SSH 端口修改。"
        return
    fi

    if ssh_port_already_configured "${ssh_config_file}" "${GLOBAL_SSH_PORT}"; then
        apply_firewall_ssh_port "${GLOBAL_SSH_PORT}"
        display_status_success "SSH 端口 ${GLOBAL_SSH_PORT} 已在配置中存在，未重复写入。"
        return
    fi

    if is_tcp_port_listening "${GLOBAL_SSH_PORT}"; then
        display_status_error "端口 ${GLOBAL_SSH_PORT} 已被监听，未修改 SSH 配置。"
        exit 1
    fi

    display_status_info "正在新增 SSH 监听端口 ${GLOBAL_SSH_PORT}，并保留已有端口..."
    local ssh_port_config_file
    local backup_file=""
    ssh_port_config_file="$(select_ssh_port_config_file "${ssh_config_file}")"

    if [ -f "${ssh_port_config_file}" ]; then
        backup_file="$(backup_existing_file "${ssh_port_config_file}")"
    fi

    {
        echo
        printf '# Added by vps_setup.sh on %s. Existing SSH ports are intentionally preserved.\n' "$(date '+%F %T')"
        if ! active_ssh_port_directives_exist "${ssh_config_file}"; then
            printf 'Port 22\n'
        fi
        printf 'Port %s\n' "${GLOBAL_SSH_PORT}"
    } >> "${ssh_port_config_file}"

    apply_firewall_ssh_port "${GLOBAL_SSH_PORT}"
    reload_ssh_service_or_restore "${ssh_port_config_file}" "${backup_file}" "${sshd_binary}"

    display_status_success "SSH 已新增监听端口 ${GLOBAL_SSH_PORT}。请保持当前会话，确认新端口可登录后再手动收紧旧端口。"
}

remove_orphaned_packages() {
    display_status_info "正在清理孤立依赖以释放磁盘空间..."
    if [[ "${GLOBAL_PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        run_logged apt-get autoremove -y
        run_logged apt-get clean
    elif [[ "${GLOBAL_PKG_MANAGER}" == "dnf" ]]; then
        run_logged dnf autoremove -y || true
    fi
    display_status_success "系统垃圾清理完成。"
}

confirm_reboot() {
    local status

    ui_section "重启确认"
    ui_warn "部分系统配置可能需要重启后完全生效。"
    ui_blank
    if ui_confirm_or_default "是否立即重启系统？" "n" "${GLOBAL_ASSUME_YES}"; then
        ui_info "系统将在 5 秒后执行重启指令..."
        sleep 5
        run_logged reboot
        return
    fi

    status=$?
    if [ "${status}" -eq "${UI_RETURN_TO_MENU}" ]; then
        ui_warn "已取消立即重启。请在合适的维护窗口手动重启系统。"
        return
    fi

    ui_warn "请在合适的维护窗口手动重启系统。"
}

execute_main_lifecycle() {
    ui_title "${SCRIPT_DISPLAY_NAME}" "${SCRIPT_VERSION}"
    show_startup_context
    ui_blank

    validate_root_privilege
    select_vps_profile
    configure_public_optional_features
    show_execution_summary
    confirm_execution_plan
    init_log_file
    detect_operating_system_environment
    upgrade_system_packages
    configure_virtual_memory_swap
    calibrate_system_timezone
    install_essential_utilities
    optimize_kernel_sysctl_network
    install_debian_cloud_kernel
    install_docker_runtime
    install_nodejs_runtime
    configure_ssh_port
    remove_orphaned_packages

    display_status_success "所有初始化与优化任务执行完毕。"
    confirm_reboot
}

main() {
    trap 'handle_unexpected_error "$LINENO"' ERR
    ui_init_colors
    ui_init_prompt_input
    parse_arguments "$@"
    validate_static_configuration
    execute_main_lifecycle
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
