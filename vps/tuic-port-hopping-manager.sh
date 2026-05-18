#!/usr/bin/env bash
# ==============================================================================
# TUIC Port-Hopping 多实例管理脚本
# ------------------------------------------------------------------------------
# 作用：
#   - 为 sing-box / 233boy/sing-box 创建的单端口 TUIC inbound 增加服务端端口跳跃支持。
#   - 每个真实 TUIC UDP 端口对应一个独立实例，互不覆盖。
#   - 每个实例拥有独立配置、独立 nftables 表、独立 systemd 服务。
#   - 自动检查 nftables、端口监听、端口范围冲突、UFW 放行与配置状态。
#
# 使用：
#   chmod +x tuic-port-hopping-manager.sh
#   sudo ./tuic-port-hopping-manager.sh
# ============================================================================== 

set -u

SCRIPT_VERSION="2026.05.17-r1"
BASE_DIR="/etc/tuic-port-hopping"
INSTANCE_DIR="${BASE_DIR}/instances"
NFT_RULE_DIR="/etc/nftables.d"
APPLY_SCRIPT="/usr/local/sbin/apply-tuic-port-hopping.sh"
SYSTEMD_TEMPLATE="/etc/systemd/system/tuic-port-hopping@.service"
NFT_TABLE_PREFIX="tuic_hopping_"

UI_TITLE_WIDTH=60
UI_KV_LABEL_WIDTH=18
UI_RETURN_TO_MENU=130

UI_COLOR_RESET=""
UI_COLOR_RED=""
UI_COLOR_GREEN=""
UI_COLOR_YELLOW=""
UI_COLOR_BLUE=""
UI_COLOR_CYAN=""
UI_COLOR_BOLD=""
UI_COLOR_DIM=""

COLOR_RESET=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""
COLOR_BOLD=""
COLOR_DIM=""

PROMPT_FD=0
COMMAND="menu"

ui_support_color() {
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]
}

ui_color() {
    local code="$1"
    printf '\033[%sm' "${code}"
}

ui_init_colors() {
    if ui_support_color || [ "${FORCE_COLOR:-}" = "1" ]; then
        UI_COLOR_RESET="$(ui_color 0)"
        UI_COLOR_RED="$(ui_color 31)"
        UI_COLOR_GREEN="$(ui_color 32)"
        UI_COLOR_YELLOW="$(ui_color 33)"
        UI_COLOR_BLUE="$(ui_color 34)"
        UI_COLOR_CYAN="$(ui_color 36)"
        UI_COLOR_BOLD="$(ui_color 1)"
        UI_COLOR_DIM="$(ui_color 2)"
    else
        UI_COLOR_RESET=""
        UI_COLOR_RED=""
        UI_COLOR_GREEN=""
        UI_COLOR_YELLOW=""
        UI_COLOR_BLUE=""
        UI_COLOR_CYAN=""
        UI_COLOR_BOLD=""
        UI_COLOR_DIM=""
    fi

    COLOR_RESET="${UI_COLOR_RESET}"
    COLOR_RED="${UI_COLOR_RED}"
    COLOR_GREEN="${UI_COLOR_GREEN}"
    COLOR_YELLOW="${UI_COLOR_YELLOW}"
    COLOR_BLUE="${UI_COLOR_BLUE}"
    COLOR_CYAN="${UI_COLOR_CYAN}"
    COLOR_BOLD="${UI_COLOR_BOLD}"
    COLOR_DIM="${UI_COLOR_DIM}"
}

ui_clear() {
    clear 2>/dev/null || true
}

ui_blank() {
    printf '\n'
}

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

ui_title() {
    local title="$1" version="${2:-}" rule
    printf -v rule '%*s' "${UI_TITLE_WIDTH}" ''
    rule="${rule// /=}"

    printf '%b' "${UI_COLOR_CYAN}${UI_COLOR_BOLD}"
    printf '%s\n' "${rule}"
    ui_center_line "${title}" "${UI_TITLE_WIDTH}"
    if [ -n "${version}" ]; then
        ui_center_line "Version: ${version}" "${UI_TITLE_WIDTH}"
    fi
    printf '%s\n' "${rule}"
    printf '%b' "${UI_COLOR_RESET}"
}

ui_print() {
    printf '%b\n' "$*"
}

ui_dim() {
    printf '%b\n' "${UI_COLOR_DIM}$*${UI_COLOR_RESET}"
}

ui_info() {
    printf '%b\n' "${UI_COLOR_CYAN}[i]${UI_COLOR_RESET} $*"
}

ui_ok() {
    printf '%b\n' "${UI_COLOR_GREEN}[OK]${UI_COLOR_RESET} $*"
}

ui_warn() {
    printf '%b\n' "${UI_COLOR_YELLOW}[WARN]${UI_COLOR_RESET} $*" >&2
}

ui_error() {
    printf '%b\n' "${UI_COLOR_RED}[ERROR]${UI_COLOR_RESET} $*" >&2
}

ui_section() {
    printf '\n%b\n' "${UI_COLOR_BLUE}${UI_COLOR_BOLD}>>> $*${UI_COLOR_RESET}"
}

ui_rule() {
    printf '%*s\n' "${UI_TITLE_WIDTH}" '' | tr ' ' '-'
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

ui_menu_footer() {
    ui_dim "主菜单：输入 0 退出脚本。子菜单：输入 0 返回上一级。"
    ui_dim "普通输入：输入 q 取消当前操作。"
}

ui_pause() {
    local _
    ui_blank
    ui_read_raw _ "按回车键继续..."
}

page_title() {
    ui_clear
    ui_title "TUIC Port-Hopping 多实例管理脚本" "${SCRIPT_VERSION}"
}

show_help() {
    cat <<'EOF'
TUIC Port-Hopping 多实例管理脚本
用法：
  sudo bash tuic-port-hopping-manager.sh [command]
  sudo bash tuic-port-hopping-manager.sh [options]
命令：
  menu       打开交互式管理菜单（默认）
选项：
  -h, --help 显示帮助并退出
交互语义：
  主菜单输入 0 退出脚本。
  子菜单输入 0 返回上一级。
  普通输入中输入 q 取消当前操作。
说明：
  该脚本用于为 sing-box / 233boy/sing-box 创建的单端口 TUIC inbound
  增加服务端 Port-Hopping 支持。每个真实 TUIC UDP 端口对应一个独立实例。
EOF
}

init_prompt_input() {
    if [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
        PROMPT_FD=3
    else
        PROMPT_FD=0
    fi
}

ui_read_raw() {
    local __target="$1" __prompt="$2" __value
    if ! IFS= read -r -u "${PROMPT_FD}" -p "${__prompt}" __value; then
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

ui_read_menu_choice() {
    local __target="$1"
    ui_read_raw "${__target}" "请输入选项编号（0 退出）： "
}

pause_screen() {
    ui_pause
}

ui_confirm() {
    local prompt_text="$1" default_answer="${2:-n}" answer="" label

    if [ "${default_answer}" = "y" ] || [ "${default_answer}" = "Y" ]; then
        label="Y/n"
        default_answer="y"
    else
        label="y/N"
        default_answer="n"
    fi

    while true; do
        ui_read_or_cancel answer "${prompt_text} [${label}，q 取消]: " || return "$?"
        answer="${answer:-${default_answer}}"
        case "${answer}" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) ui_error "请输入 y、n 或 q。" ;;
        esac
    done
}

ui_confirm_token() {
    local prompt_text="$1" token="$2" answer=""
    ui_read_or_cancel answer "${prompt_text} 输入 ${token} 继续，或输入 q 取消： " || return "$?"
    if [ "${answer}" = "${token}" ]; then
        return 0
    fi
    return 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        ui_error "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

check_command_exists() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
    local packages=("$@")
    [ "${#packages[@]}" -gt 0 ] || return 0

    export DEBIAN_FRONTEND=noninteractive
    if check_command_exists apt-get; then
        apt-get update && apt-get install -y "${packages[@]}"
    elif check_command_exists apk; then
        apk add --no-cache "${packages[@]}"
    elif check_command_exists dnf; then
        dnf install -y "${packages[@]}"
    elif check_command_exists yum; then
        yum install -y "${packages[@]}"
    else
        ui_error "未识别到 apt-get / apk / dnf / yum，请手动安装依赖：${packages[*]}"
        return 1
    fi
}

ensure_directories() {
    mkdir -p "${BASE_DIR}" "${INSTANCE_DIR}" "${NFT_RULE_DIR}"
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

validate_port_range() {
    local range="$1" start_port end_port
    [[ "${range}" =~ ^[0-9]+-[0-9]+$ ]] || return 1
    start_port="${range%-*}"
    end_port="${range#*-}"
    validate_port "${start_port}" || return 1
    validate_port "${end_port}" || return 1
    [ "${start_port}" -lt "${end_port}" ]
}

ranges_overlap() {
    local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
    [ "${a_start}" -le "${b_end}" ] && [ "${b_start}" -le "${a_end}" ]
}

is_port_in_range() {
    local port="$1" start_port="$2" end_port="$3"
    [ "${port}" -ge "${start_port}" ] && [ "${port}" -le "${end_port}" ]
}

validate_instance_env_values() {
    local real_port="$1" start_port="$2" end_port="$3"
    validate_port "${real_port}" || return 1
    validate_port "${start_port}" || return 1
    validate_port "${end_port}" || return 1
    [ "${start_port}" -lt "${end_port}" ]
}

get_config_file() { echo "${INSTANCE_DIR}/$1.env"; }
get_nft_table_name() { echo "${NFT_TABLE_PREFIX}$1"; }
get_nft_rule_file() { echo "${NFT_RULE_DIR}/tuic-port-hopping-$1.nft"; }
get_service_name() { echo "tuic-port-hopping@$1.service"; }

read_env_value() {
    local file_path="$1" key_name="$2"
    [ -f "${file_path}" ] || return 1
    grep -E "^${key_name}=" "${file_path}" 2>/dev/null | head -n 1 | cut -d '=' -f 2- | sed 's/^"//; s/"$//'
}

list_instances() {
    local file_path
    [ -d "${INSTANCE_DIR}" ] || return 0
    for file_path in "${INSTANCE_DIR}"/*.env; do
        [ -e "${file_path}" ] || continue
        basename "${file_path}" .env
    done | sort -n
}

has_instances() {
    local first_instance
    first_instance="$(list_instances | head -n 1 || true)"
    [ -n "${first_instance}" ]
}

count_instances() {
    local count=0 port
    while read -r port; do
        [ -n "${port}" ] || continue
        count=$((count + 1))
    done < <(list_instances)
    printf '%s' "${count}"
}

count_active_instances() {
    local count=0 port service
    while read -r port; do
        [ -n "${port}" ] || continue
        service="$(get_service_name "${port}")"
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            count=$((count + 1))
        fi
    done < <(list_instances)
    printf '%s' "${count}"
}

detect_nft_status() {
    if check_command_exists nft; then
        printf '%s' "ok"
    else
        printf '%s' "missing"
    fi
}

detect_ufw_status() {
    local ufw_output
    if ! check_command_exists ufw; then
        printf '%s' "missing"
        return 0
    fi

    ufw_output="$(ufw status 2>/dev/null | head -n 1 || true)"
    case "${ufw_output}" in
        Status:\ active) printf '%s' "active" ;;
        Status:\ inactive) printf '%s' "inactive" ;;
        Status:*) printf '%s' "unknown" ;;
        *) printf '%s' "unknown" ;;
    esac
}

build_main_status_line() {
    printf '%s' "Instances: $(count_instances) | Active: $(count_active_instances) | nftables: $(detect_nft_status) | UFW: $(detect_ufw_status)"
}

show_instance_table() {
    ui_section "实例列表"
    if ! has_instances; then
        ui_warn "当前没有已创建的实例。"
        return 1
    fi

    ui_rule
    printf "%-8s %-18s %-16s %-12s\n" "端口" "跳跃范围" "systemd" "更新时间"
    ui_rule

    local port cfg start_port end_port updated service state
    while read -r port; do
        [ -n "${port}" ] || continue
        cfg="$(get_config_file "${port}")"
        start_port="$(read_env_value "${cfg}" "RANGE_START" || true)"
        end_port="$(read_env_value "${cfg}" "RANGE_END" || true)"
        updated="$(read_env_value "${cfg}" "UPDATED_AT" || true)"
        service="$(get_service_name "${port}")"
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            state="active"
        elif systemctl is-enabled --quiet "${service}" 2>/dev/null; then
            state="enabled"
        else
            state="inactive"
        fi
        printf "%-8s %-18s %-16s %-12s\n" "${port}" "${start_port}-${end_port}" "${state}" "${updated:-未知}"
    done < <(list_instances)

    ui_rule
}

select_instance() {
    SELECTED_PORT=""
    show_instance_table || return 1
    ui_blank
    local port
    while true; do
        ui_read_or_cancel port "请输入要管理的真实 TUIC 端口（0 返回，q 取消）： " || {
            [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return "${UI_RETURN_TO_MENU}"
            return 1
        }
        [ "${port}" = "0" ] && return "${UI_RETURN_TO_MENU}"
        validate_port "${port}" || { ui_error "端口格式无效。"; continue; }
        [ -f "$(get_config_file "${port}")" ] || { ui_error "未找到端口 ${port} 的实例。"; continue; }
        SELECTED_PORT="${port}"
        return 0
    done
}

load_instance_config() {
    local port="$1" cfg
    cfg="$(get_config_file "${port}")"
    [ -f "${cfg}" ] || { ui_error "未找到实例配置：${cfg}"; return 1; }
    # 配置文件由本脚本生成，且端口已做数字校验。
    # shellcheck disable=SC1090
    . "${cfg}"
}

calculate_auto_range() {
    local real_port="$1" range_size=100 start_port end_port
    if [ "${real_port}" -le 55435 ]; then
        start_port=$((real_port + 10000))
    else
        start_port=$((real_port - 10000))
    fi
    [ "${start_port}" -lt 1024 ] && start_port=1024
    end_port=$((start_port + range_size - 1))
    if [ "${end_port}" -gt 65535 ]; then
        end_port=65535
        start_port=$((end_port - range_size + 1))
    fi
    if [ "${real_port}" -ge "${start_port}" ] && [ "${real_port}" -le "${end_port}" ]; then
        start_port=$((real_port + 1))
        end_port=$((start_port + range_size - 1))
        if [ "${end_port}" -gt 65535 ]; then
            end_port=$((real_port - 1))
            start_port=$((end_port - range_size + 1))
        fi
    fi
    echo "${start_port}-${end_port}"
}

has_runtime_port_probe_tool() {
    check_command_exists ss || check_command_exists netstat
}

install_runtime_port_probe_dependency() {
    ui_warn "未检测到 ss，正在安装运行验证所需端口探测依赖。"
    if check_command_exists apt-get || check_command_exists apk; then
        install_packages iproute2 || return 1
    elif check_command_exists dnf || check_command_exists yum; then
        install_packages iproute || return 1
    else
        ui_error "未识别到支持的包管理器，请手动安装 iproute2/iproute。"
        return 1
    fi
    check_command_exists ss || {
        ui_error "端口探测依赖安装后仍未检测到 ss。"
        return 1
    }
}

ensure_runtime_validation_dependencies() {
    has_runtime_port_probe_tool && return 0
    install_runtime_port_probe_dependency
}

warn_missing_runtime_probe_tool_for_readonly() {
    has_runtime_port_probe_tool && return 0
    ui_warn "缺少 ss/netstat，无法检查 UDP 监听状态；只读路径不会自动安装依赖。"
    ui_warn "写入型动作会按需安装 iproute2/iproute 以提供 ss。"
}

list_udp_listening_ports() {
    if check_command_exists ss; then
        ss -H -lunp 2>/dev/null | grep -Eo ':[0-9]+' | tr -d ':' | sort -n | uniq
        return 0
    fi
    if check_command_exists netstat; then
        netstat -lunp 2>/dev/null | grep -Eo ':[0-9]+' | tr -d ':' | sort -n | uniq
        return 0
    fi
    return 2
}

is_udp_port_listening() {
    local port="$1"
    if check_command_exists ss; then
        ss -H -lunp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
        return "$?"
    fi
    if check_command_exists netstat; then
        netstat -lunp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
        return "$?"
    fi
    return 2
}

check_tuic_listener() {
    ui_section "监听检查"
    if ! has_runtime_port_probe_tool; then
        warn_missing_runtime_probe_tool_for_readonly
        return 0
    fi
    if is_udp_port_listening "${REAL_PORT}"; then
        ui_ok "检测到 UDP ${REAL_PORT} 正在监听。"
        return 0
    fi
    ui_warn "未检测到 UDP ${REAL_PORT} 正在监听。"
    ui_warn "如果 sing-box / TUIC 尚未启动，可先继续创建规则，稍后再验证。"
    ui_confirm "是否仍然继续配置该端口" n
}

check_range_listener_conflict() {
    local start_port="$1" end_port="$2"
    has_runtime_port_probe_tool || return 0
    local used_ports used_port found=0
    used_ports="$(list_udp_listening_ports || true)"
    for used_port in ${used_ports}; do
        if [ "${used_port}" -ge "${start_port}" ] && [ "${used_port}" -le "${end_port}" ]; then
            ui_warn "跳跃范围内检测到已监听 UDP 端口：${used_port}"
            found=1
        fi
    done
    [ "${found}" -eq 0 ]
}

check_instance_port_conflict() {
    local real_port="$1" start_port="$2" end_port="$3"
    local cfg other_port other_start other_end
    for cfg in "${INSTANCE_DIR}"/*.env; do
        [ -e "${cfg}" ] || continue
        other_port="$(read_env_value "${cfg}" "REAL_PORT" || true)"
        other_start="$(read_env_value "${cfg}" "RANGE_START" || true)"
        other_end="$(read_env_value "${cfg}" "RANGE_END" || true)"
        if ! validate_instance_env_values "${other_port}" "${other_start}" "${other_end}"; then
            ui_warn "跳过无效实例配置：${cfg}"
            continue
        fi
        # 同一真实端口视为更新当前实例，允许继续。
        if [ "${other_port}" = "${real_port}" ]; then
            continue
        fi
        if ranges_overlap "${start_port}" "${end_port}" "${other_start}" "${other_end}"; then
            ui_error "跳跃范围与已有实例 ${other_port} 冲突：${other_start}-${other_end}"
            return 1
        fi
        if is_port_in_range "${other_port}" "${start_port}" "${end_port}"; then
            ui_error "跳跃范围 ${start_port}-${end_port} 包含已有实例真实端口：${other_port}"
            return 1
        fi
        if is_port_in_range "${real_port}" "${other_start}" "${other_end}"; then
            ui_error "真实端口 ${real_port} 落入已有实例 ${other_port} 的跳跃范围：${other_start}-${other_end}"
            return 1
        fi
    done
    return 0
}

prompt_real_port() {
    REAL_PORT=""
    while true; do
        ui_read_or_cancel REAL_PORT "请输入当前 TUIC UDP 监听端口（q 取消）： " || return "$?"
        validate_port "${REAL_PORT}" && break
        ui_error "端口格式无效，请输入 1-65535 之间的数字。"
    done
}

prompt_port_range() {
    local auto_range custom_range
    auto_range="$(calculate_auto_range "${REAL_PORT}")"
    ui_info "根据真实端口 ${REAL_PORT} 自动生成的跳跃范围：${auto_range}"
    ui_info "可直接回车使用自动范围，也可输入自定义范围，格式为：起始端口-结束端口"
    while true; do
        ui_read_or_cancel custom_range "请输入跳跃端口范围（默认 ${auto_range}，回车使用默认值，q 取消）： " || return "$?"
        custom_range="${custom_range:-${auto_range}}"
        validate_port_range "${custom_range}" || { ui_error "范围格式无效，请使用 start-end。"; continue; }
        RANGE_START="${custom_range%-*}"
        RANGE_END="${custom_range#*-}"
        if [ "${REAL_PORT}" -ge "${RANGE_START}" ] && [ "${REAL_PORT}" -le "${RANGE_END}" ]; then
            ui_error "跳跃范围不能包含真实端口 ${REAL_PORT}。"
            continue
        fi
        check_instance_port_conflict "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" || continue
        if ! check_range_listener_conflict "${RANGE_START}" "${RANGE_END}"; then
            ui_confirm "检测到端口占用风险，是否仍然继续" n
            case "$?" in
                0) ;;
                1) continue ;;
                "${UI_RETURN_TO_MENU}") return "${UI_RETURN_TO_MENU}" ;;
            esac
        fi
        break
    done
}

ensure_nftables_dependency() {
    ui_section "nftables 检查"
    if check_command_exists nft; then
        ui_ok "nftables 已安装。"
        return 0
    fi
    ui_warn "未检测到 nftables，正在安装实例所需依赖。"
    install_packages nftables || {
        ui_error "nftables 安装失败。"
        return 1
    }
    check_command_exists nft || { ui_error "nftables 安装失败。"; return 1; }
    ui_ok "nftables 安装完成。"
}

install_nftables_if_needed() {
    ensure_nftables_dependency
}

test_nft_nat_support() {
    ui_section "nftables NAT 能力测试"
    local test_table="tuic_hopping_test_$$"
    nft -f - >/dev/null 2>&1 <<EOF_NFT
 table inet ${test_table} {
     chain prerouting {
         type nat hook prerouting priority dstnat; policy accept;
     }
 }
EOF_NFT
    local result=$?
    nft delete table inet "${test_table}" >/dev/null 2>&1 || true
    if [ "${result}" -eq 0 ]; then
        ui_ok "当前系统支持 nftables inet NAT prerouting。"
        return 0
    fi
    ui_error "当前系统无法创建 nftables inet NAT prerouting。"
    ui_error "可能原因：OpenVZ/LXC 权限限制、内核模块缺失、系统内核过旧。"
    return 1
}

write_apply_script() {
    if ! cat > "${APPLY_SCRIPT}" <<'EOF_APPLY'
#!/bin/sh
set -eu

port="${1:-}"
if [ -z "${port}" ]; then
    echo "[ERROR] 缺少实例端口参数。" >&2
    exit 1
fi

config_file="/etc/tuic-port-hopping/instances/${port}.env"
if [ ! -f "${config_file}" ]; then
    echo "[ERROR] 未找到实例配置：${config_file}" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "${config_file}"

if [ -z "${NFT_TABLE_NAME:-}" ] || [ -z "${NFT_RULE_FILE:-}" ]; then
    echo "[ERROR] 实例配置缺少 NFT_TABLE_NAME 或 NFT_RULE_FILE。" >&2
    exit 1
fi

if nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
    nft delete table inet "${NFT_TABLE_NAME}"
fi

    nft -f "${NFT_RULE_FILE}"
EOF_APPLY
    then
        ui_error "写入通用应用脚本失败：${APPLY_SCRIPT}"
        return 1
    fi
    chmod +x "${APPLY_SCRIPT}" || {
        ui_error "设置通用应用脚本可执行权限失败：${APPLY_SCRIPT}"
        return 1
    }
    ui_ok "已写入通用应用脚本：${APPLY_SCRIPT}"
}

write_systemd_template() {
    if ! cat > "${SYSTEMD_TEMPLATE}" <<EOF_SYSTEMD
[Unit]
Description=Apply TUIC UDP port-hopping redirect rules for port %i
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_SCRIPT} %i
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
    then
        ui_error "写入 systemd 模板失败：${SYSTEMD_TEMPLATE}"
        return 1
    fi
    systemctl daemon-reload || {
        ui_error "systemd daemon-reload 失败。"
        return 1
    }
    ui_ok "已写入 systemd 模板：${SYSTEMD_TEMPLATE}"
}

write_instance_files() {
    local real_port="$1" start_port="$2" end_port="$3"
    local cfg nft_file nft_table updated_at
    cfg="$(get_config_file "${real_port}")"
    nft_file="$(get_nft_rule_file "${real_port}")"
    nft_table="$(get_nft_table_name "${real_port}")"
    updated_at="$(date +%F)"

    if ! cat > "${cfg}" <<EOF_CFG
# TUIC Port-Hopping 实例配置
REAL_PORT="${real_port}"
RANGE_START="${start_port}"
RANGE_END="${end_port}"
NFT_TABLE_NAME="${nft_table}"
NFT_RULE_FILE="${nft_file}"
UPDATED_AT="${updated_at}"
EOF_CFG
    then
        ui_error "写入实例 env 失败：${cfg}"
        return 1
    fi
    chmod 600 "${cfg}" 2>/dev/null || true

    if ! cat > "${nft_file}" <<EOF_NFT
 table inet ${nft_table} {
     chain prerouting {
         type nat hook prerouting priority dstnat; policy accept;

         # 将 TUIC 跳跃 UDP 端口范围重定向到真实监听端口
         udp dport ${start_port}-${end_port} redirect to :${real_port}
     }
 }
EOF_NFT
    then
        ui_error "写入 nftables 规则文件失败：${nft_file}"
        return 1
    fi

    ui_ok "已写入实例配置：${cfg}"
    ui_ok "已写入 nftables 规则：${nft_file}"
}

apply_instance_rules() {
    local port="$1" service
    service="$(get_service_name "${port}")"
    ui_section "应用实例规则：${port}"
    if "${APPLY_SCRIPT}" "${port}"; then
        ui_ok "nftables 规则已应用。"
    else
        ui_error "nftables 规则应用失败，最近 systemd 日志如下："
        show_nft_diagnostics "$(get_nft_table_name "${port}")"
        ui_blank
        ui_info "原始 journalctl 输出："
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    # 调用方负责在任一失败点执行事务回滚或残留报告。
    systemctl enable "${service}" >/dev/null 2>&1 || {
        ui_error "systemd 服务启用失败：${service}"
        show_systemd_diagnostics "${port}"
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
        return 1
    }
    systemctl restart "${service}" >/dev/null 2>&1 || {
        ui_error "systemd 服务重启失败：${service}"
        ui_warn "nftables 规则可能已临时应用，但 systemd 持久化失败。请修复后重新应用实例规则。"
        show_systemd_diagnostics "${port}"
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
        return 1
    }
    systemctl is-active --quiet "${service}" 2>/dev/null || {
        ui_error "systemd 服务未处于 active：${service}"
        ui_warn "nftables 规则可能已临时应用，但 systemd 持久化状态异常。请修复后重新应用实例规则。"
        show_systemd_diagnostics "${port}"
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
        return 1
    }
    ui_ok "systemd 服务已启用并处于 active：${service}"
}

configure_ufw_rules() {
    local real_port="$1" start_port="$2" end_port="$3"
    local failed=0
    ui_section "UFW 放行规则"
    if ! check_command_exists ufw; then
        ui_warn "未检测到 UFW，跳过 UFW 放行。"
        return 0
    fi
    ufw allow "${real_port}/udp" >/dev/null 2>&1 && ui_ok "已补充 UFW 放行：${real_port}/udp" || {
        ui_error "UFW 放行真实端口失败：${real_port}/udp"
        failed=1
    }
    ufw allow "${start_port}:${end_port}/udp" >/dev/null 2>&1 && ui_ok "已补充 UFW 放行：${start_port}:${end_port}/udp" || {
        ui_error "UFW 放行跳跃范围失败：${start_port}:${end_port}/udp"
        failed=1
    }
    ufw reload >/dev/null 2>&1 || {
        ui_error "UFW reload 失败。"
        failed=1
    }
    [ "${failed}" -eq 0 ] || {
        show_ufw_diagnostics
        show_ufw_manual_cleanup_commands "${real_port}" "${start_port}" "${end_port}"
    }
    return "${failed}"
}

remove_ufw_rules() {
    local real_port="$1" start_port="$2" end_port="$3"
    check_command_exists ufw || return 0
    ui_section "删除 UFW 放行规则"
    ufw --force delete allow "${real_port}/udp" >/dev/null 2>&1 || ui_warn "未找到或未删除 UFW 规则：${real_port}/udp"
    ufw --force delete allow "${start_port}:${end_port}/udp" >/dev/null 2>&1 || ui_warn "未找到或未删除 UFW 规则：${start_port}:${end_port}/udp"
    ufw reload >/dev/null 2>&1 || true
}

show_systemd_manual_cleanup_commands() {
    local port="$1" service
    service="$(get_service_name "${port}")"
    ui_warn "systemd 人工处理命令："
    ui_print "  systemctl disable --now ${service}"
    ui_print "  systemctl daemon-reload"
    ui_print "  systemctl reset-failed ${service}"
}

show_nft_manual_cleanup_commands() {
    local table="$1"
    ui_warn "nftables 人工处理命令："
    ui_print "  nft list table inet ${table}"
    ui_print "  nft delete table inet ${table}"
}

show_ufw_manual_cleanup_commands() {
    local real_port="$1" start_port="$2" end_port="$3"
    ui_warn "UFW 人工处理命令："
    ui_print "  ufw --force delete allow ${real_port}/udp"
    ui_print "  ufw --force delete allow ${start_port}:${end_port}/udp"
    ui_print "  ufw reload"
}

show_file_manual_cleanup_commands() {
    local cfg="$1" nft_file="$2"
    ui_warn "文件人工处理命令："
    ui_print "  rm -f ${cfg} ${nft_file}"
}

show_nft_diagnostics() {
    local table="$1"
    ui_warn "nftables 诊断命令："
    ui_print "  nft list ruleset | grep -n ${table}"
    ui_print "  nft list table inet ${table}"
}

show_systemd_diagnostics() {
    local port="$1" service
    service="$(get_service_name "${port}")"
    ui_warn "systemd 诊断命令："
    ui_print "  systemctl status ${service} --no-pager"
    ui_print "  journalctl -u ${service} -n 80 --no-pager"
}

show_ufw_diagnostics() {
    ui_warn "UFW 诊断命令："
    ui_print "  ufw status verbose"
    ui_print "  ufw status numbered"
}

prepare_instance_rollback_dir() {
    local port="$1"
    local timestamp
    timestamp="$(date +%Y%m%d%H%M%S)"
    INSTANCE_ROLLBACK_DIR="${BASE_DIR}/backups/rollback.${port}.${timestamp}"
    mkdir -p "${INSTANCE_ROLLBACK_DIR}" || return 1
    chmod 700 "${BASE_DIR}/backups" "${INSTANCE_ROLLBACK_DIR}" 2>/dev/null || true
    ui_info "回滚备份目录：${INSTANCE_ROLLBACK_DIR}"
}

backup_file_if_exists() {
    local source_path="$1" backup_path="$2"
    if [ -f "${source_path}" ]; then
        cp -a "${source_path}" "${backup_path}" || return 1
        chmod 600 "${backup_path}" 2>/dev/null || true
    else
        : > "${backup_path}.missing" || return 1
        chmod 600 "${backup_path}.missing" 2>/dev/null || true
    fi
}

capture_instance_rollback_state() {
    local port="$1" rollback_dir="$2"
    local cfg nft_file service metadata
    cfg="$(get_config_file "${port}")"
    nft_file="$(get_nft_rule_file "${port}")"
    service="$(get_service_name "${port}")"
    metadata="${rollback_dir}/metadata.env"

    backup_file_if_exists "${cfg}" "${rollback_dir}/instance.env" || return 1
    backup_file_if_exists "${nft_file}" "${rollback_dir}/instance.nft" || return 1

    {
        printf 'ROLLBACK_PORT="%s"\n' "${port}"
        printf 'ROLLBACK_CFG="%s"\n' "${cfg}"
        printf 'ROLLBACK_NFT_FILE="%s"\n' "${nft_file}"
        if [ -f "${cfg}" ]; then
            printf 'ROLLBACK_REAL_PORT="%s"\n' "$(read_env_value "${cfg}" "REAL_PORT" || true)"
            printf 'ROLLBACK_RANGE_START="%s"\n' "$(read_env_value "${cfg}" "RANGE_START" || true)"
            printf 'ROLLBACK_RANGE_END="%s"\n' "$(read_env_value "${cfg}" "RANGE_END" || true)"
            printf 'ROLLBACK_NFT_TABLE_NAME="%s"\n' "$(read_env_value "${cfg}" "NFT_TABLE_NAME" || true)"
            printf 'ROLLBACK_NFT_RULE_FILE="%s"\n' "$(read_env_value "${cfg}" "NFT_RULE_FILE" || true)"
        fi
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            printf 'ROLLBACK_SERVICE_ACTIVE="true"\n'
        else
            printf 'ROLLBACK_SERVICE_ACTIVE="false"\n'
        fi
        if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
            printf 'ROLLBACK_SERVICE_ENABLED="true"\n'
        else
            printf 'ROLLBACK_SERVICE_ENABLED="false"\n'
        fi
        if check_command_exists ufw; then
            printf 'ROLLBACK_UFW_STATUS_FILE="%s"\n' "${rollback_dir}/ufw.status"
        fi
    } > "${metadata}" || return 1
    chmod 600 "${metadata}" 2>/dev/null || true

    if check_command_exists ufw; then
        ufw status verbose > "${rollback_dir}/ufw.status" 2>/dev/null || true
        chmod 600 "${rollback_dir}/ufw.status" 2>/dev/null || true
    fi

    ui_ok "已保存实例 ${port} 的回滚状态。"
}

restore_file_from_rollback() {
    local backup_path="$1" missing_marker="$2" target_path="$3"
    if [ -f "${backup_path}" ]; then
        cp -a "${backup_path}" "${target_path}" || return 1
        chmod 600 "${target_path}" 2>/dev/null || true
        return 0
    fi
    if [ -f "${missing_marker}" ]; then
        rm -f "${target_path}" || return 1
        return 0
    fi
    return 1
}

remove_instance_nft_runtime() {
    local table="$1"
    [ -n "${table}" ] || return 0
    if ! check_command_exists nft; then
        ui_warn "缺少 nft，无法删除运行时表：inet ${table}"
        show_nft_manual_cleanup_commands "${table}"
        return 1
    fi
    if nft list table inet "${table}" >/dev/null 2>&1; then
        if nft delete table inet "${table}" >/dev/null 2>&1; then
            ui_ok "已删除 nftables 运行时表：inet ${table}"
            return 0
        fi
        ui_warn "nftables 运行时表删除失败：inet ${table}"
        show_nft_manual_cleanup_commands "${table}"
        return 1
    fi
    ui_ok "nftables 运行时表不存在：inet ${table}"
}

cleanup_failed_new_instance() {
    local port="$1" start_port="$2" end_port="$3" table="$4" nft_file="$5"
    local service cfg failed=0
    service="$(get_service_name "${port}")"
    cfg="$(get_config_file "${port}")"

    ui_warn "新实例创建失败，正在清理本次写入对象。"
    if systemctl disable --now "${service}" >/dev/null 2>&1; then
        ui_ok "已停止并禁用 ${service}"
    else
        ui_warn "停止或禁用 ${service} 失败。"
        show_systemd_manual_cleanup_commands "${port}"
        failed=1
    fi

    remove_instance_nft_runtime "${table}" || failed=1
    remove_ufw_rules "${port}" "${start_port}" "${end_port}" || failed=1

    if rm -f "${nft_file}" "${cfg}"; then
        ui_ok "已删除实例 env/nft 文件。"
    else
        ui_warn "实例 env/nft 文件删除失败。"
        show_file_manual_cleanup_commands "${cfg}" "${nft_file}"
        failed=1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || {
        ui_warn "systemd daemon-reload 失败。"
        show_systemd_diagnostics "${port}"
        failed=1
    }
    return "${failed}"
}

rollback_existing_instance() {
    local port="$1" rollback_dir="$2"
    local metadata cfg nft_file old_real old_start old_end old_table old_service_active old_service_enabled failed=0
    metadata="${rollback_dir}/metadata.env"
    cfg="$(get_config_file "${port}")"
    nft_file="$(get_nft_rule_file "${port}")"

    ui_warn "更新实例失败，正在恢复旧实例状态。"
    if [ ! -f "${metadata}" ]; then
        ui_error "缺少回滚元数据：${metadata}"
        return 1
    fi

    # shellcheck disable=SC1090
    . "${metadata}"
    old_real="${ROLLBACK_REAL_PORT:-${port}}"
    old_start="${ROLLBACK_RANGE_START:-}"
    old_end="${ROLLBACK_RANGE_END:-}"
    old_table="${ROLLBACK_NFT_TABLE_NAME:-$(get_nft_table_name "${port}")}"
    old_service_active="${ROLLBACK_SERVICE_ACTIVE:-false}"
    old_service_enabled="${ROLLBACK_SERVICE_ENABLED:-false}"

    restore_file_from_rollback "${rollback_dir}/instance.env" "${rollback_dir}/instance.env.missing" "${cfg}" || failed=1
    restore_file_from_rollback "${rollback_dir}/instance.nft" "${rollback_dir}/instance.nft.missing" "${nft_file}" || failed=1
    [ "${failed}" -eq 0 ] && ui_ok "已恢复旧 env/nft 文件。" || ui_warn "恢复旧 env/nft 文件失败。"

    write_apply_script || failed=1
    write_systemd_template || failed=1

    if [ -n "${old_start}" ] && [ -n "${old_end}" ]; then
        configure_ufw_rules "${old_real}" "${old_start}" "${old_end}" || failed=1
    else
        ui_warn "回滚元数据缺少旧 UFW 范围，无法重放旧 UFW 规则。"
        failed=1
    fi

    if [ "${old_service_active}" = "true" ] || [ "${old_service_enabled}" = "true" ]; then
        apply_instance_rules "${port}" || failed=1
    else
        systemctl disable --now "$(get_service_name "${port}")" >/dev/null 2>&1 || true
        remove_instance_nft_runtime "${old_table}" || true
    fi

    validate_instance "${port}" "write" || {
        ui_warn "旧实例回滚后验证仍存在异常。"
        failed=1
    }

    [ "${failed}" -eq 0 ] && ui_ok "旧实例状态已恢复。" || ui_warn "旧实例状态未完全恢复，请按上方诊断命令人工处理。"
    [ "${failed}" -ne 0 ] && {
        show_systemd_diagnostics "${port}"
        show_nft_diagnostics "${old_table}"
        [ -n "${old_start}" ] && [ -n "${old_end}" ] && show_ufw_manual_cleanup_commands "${old_real}" "${old_start}" "${old_end}"
    }
    return "${failed}"
}

disable_instance_service_with_report() {
    local port="$1" service
    service="$(get_service_name "${port}")"
    if systemctl disable --now "${service}" >/dev/null 2>&1; then
        ui_ok "已停止并禁用 ${service}"
        return 0
    fi
    ui_warn "停止或禁用 ${service} 失败，继续执行后续清理。"
    show_systemd_manual_cleanup_commands "${port}"
    return 1
}

report_residual_line() {
    local label="$1" status="$2"
    printf '%-18s %s\n' "${label}" "${status}"
}

check_instance_systemd_residual() {
    local port="$1" service residual=0
    service="$(get_service_name "${port}")"
    systemctl is-active --quiet "${service}" 2>/dev/null && residual=1
    systemctl is-enabled --quiet "${service}" 2>/dev/null && residual=1
    systemctl list-unit-files "${service}" --no-legend 2>/dev/null | grep -q "${service}" && residual=1
    [ "${residual}" -eq 0 ]
}

check_instance_nft_residual() {
    local table="$1"
    [ -n "${table}" ] || return 0
    check_command_exists nft || return 1
    ! nft list table inet "${table}" >/dev/null 2>&1
}

check_instance_ufw_residual() {
    local real_port="$1" start_port="$2" end_port="$3" ufw_output ufw_first_line
    check_command_exists ufw || return 0
    ufw_output="$(ufw status 2>/dev/null || true)"
    ufw_first_line="$(printf '%s\n' "${ufw_output}" | head -n 1)"
    [ "${ufw_first_line}" = "Status: active" ] || return 0
    ! echo "${ufw_output}" | grep -Eq "${real_port}/udp|${real_port}[[:space:]]+.*UDP|${start_port}:${end_port}/udp|${start_port}:${end_port}"
}

check_instance_listener_residual() {
    local real_port="$1"
    has_runtime_port_probe_tool || return 1
    ! is_udp_port_listening "${real_port}"
}

report_instance_deletion_residuals() {
    local port="$1" real_port="$2" start_port="$3" end_port="$4" table="$5" nft_file="$6" cfg="$7"
    local failed=0

    ui_section "删除残留检查：${port}"
    if check_instance_systemd_residual "${port}"; then
        report_residual_line "systemd 实例" "clear"
    else
        report_residual_line "systemd 实例" "residual"
        show_systemd_manual_cleanup_commands "${port}"
        failed=1
    fi

    if [ -e "${cfg}" ]; then
        report_residual_line "env 文件" "residual"
        failed=1
    else
        report_residual_line "env 文件" "removed"
    fi

    report_residual_line "config 文件" "not-managed"

    if [ -n "${nft_file}" ] && [ -e "${nft_file}" ]; then
        report_residual_line "nft 文件" "residual"
        failed=1
    else
        report_residual_line "nft 文件" "removed"
    fi

    if check_instance_nft_residual "${table}"; then
        report_residual_line "nft runtime" "clear"
    else
        report_residual_line "nft runtime" "residual-or-unverified"
        show_nft_manual_cleanup_commands "${table}"
        failed=1
    fi

    if check_instance_ufw_residual "${real_port}" "${start_port}" "${end_port}"; then
        report_residual_line "UFW 规则" "clear"
    else
        report_residual_line "UFW 规则" "residual"
        show_ufw_manual_cleanup_commands "${real_port}" "${start_port}" "${end_port}"
        failed=1
    fi

    if check_instance_listener_residual "${real_port}"; then
        report_residual_line "端口监听" "clear"
    else
        report_residual_line "端口监听" "residual-or-unverified"
        ui_warn "请检查真实 TUIC 进程是否仍监听 UDP ${real_port}：ss -lunp | grep :${real_port}"
        failed=1
    fi

    return "${failed}"
}

cleanup_common_objects_with_report() {
    local failed=0
    ui_section "公共对象清理"
    if rm -f "${APPLY_SCRIPT}" "${SYSTEMD_TEMPLATE}"; then
        ui_ok "已删除通用 apply 脚本与 systemd 模板。"
    else
        ui_warn "通用 apply 脚本或 systemd 模板删除失败。"
        failed=1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || {
        ui_warn "systemd daemon-reload 失败。"
        failed=1
    }
    rmdir "${INSTANCE_DIR}" "${BASE_DIR}" >/dev/null 2>&1 || true
    return "${failed}"
}

report_common_deletion_residuals() {
    local failed=0
    ui_section "公共对象残留检查"
    if [ -e "${APPLY_SCRIPT}" ]; then
        report_residual_line "apply 脚本" "residual"
        failed=1
    else
        report_residual_line "apply 脚本" "removed"
    fi
    if [ -e "${SYSTEMD_TEMPLATE}" ]; then
        report_residual_line "systemd 模板" "residual"
        failed=1
    else
        report_residual_line "systemd 模板" "removed"
    fi
    if [ -d "${INSTANCE_DIR}" ] && has_instances; then
        report_residual_line "实例目录" "residual"
        failed=1
    else
        report_residual_line "实例目录" "clear"
    fi
    [ "${failed}" -ne 0 ] && {
        ui_warn "公共对象人工处理命令："
        ui_print "  rm -f ${APPLY_SCRIPT} ${SYSTEMD_TEMPLATE}"
        ui_print "  systemctl daemon-reload"
        ui_print "  rmdir ${INSTANCE_DIR} ${BASE_DIR}"
    }
    return "${failed}"
}

handle_create_or_update_failure() {
    local port="$1" start_port="$2" end_port="$3" table="$4" nft_file="$5" had_instance="$6" rollback_dir="$7"
    ui_blank
    ui_error "实例 ${port} 创建 / 更新失败，开始事务恢复。"
    if [ "${had_instance}" = "true" ]; then
        rollback_existing_instance "${port}" "${rollback_dir}" || return 1
    else
        cleanup_failed_new_instance "${port}" "${start_port}" "${end_port}" "${table}" "${nft_file}" || return 1
    fi
}

show_security_group_hint() {
    local real_port="$1" start_port="$2" end_port="$3"
    ui_blank
    ui_warn "请确认 VPS 商家后台安全组也已放行："
    ui_kv "真实端口" "${real_port}/udp"
    ui_kv "跳跃范围" "${start_port}-${end_port}/udp"
}

create_or_update_instance() {
    page_title
    ui_section "创建 / 更新实例"
    prompt_real_port || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 1
    }
    local had_instance=false rollback_dir="" cfg nft_file nft_table
    cfg="$(get_config_file "${REAL_PORT}")"
    nft_file="$(get_nft_rule_file "${REAL_PORT}")"
    nft_table="$(get_nft_table_name "${REAL_PORT}")"

    if [ -f "${cfg}" ]; then
        had_instance=true
        ui_warn "端口 ${REAL_PORT} 已存在实例，本流程会覆盖该实例配置。"
        ui_confirm "是否继续更新该实例" n
        case "$?" in
            0) ;;
            1|"${UI_RETURN_TO_MENU}") return 0 ;;
        esac
    fi
    ensure_runtime_validation_dependencies || { pause_screen; return 1; }
    check_tuic_listener
    case "$?" in
        0) ;;
        1|"${UI_RETURN_TO_MENU}") return 0 ;;
        *) pause_screen; return 1 ;;
    esac
    prompt_port_range || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 1
    }
    ensure_nftables_dependency
    case "$?" in
        0) ;;
        1|"${UI_RETURN_TO_MENU}") return 0 ;;
        *) pause_screen; return 1 ;;
    esac
    test_nft_nat_support || { pause_screen; return 1; }
    ensure_directories || { pause_screen; return 1; }

    if [ "${had_instance}" = "true" ]; then
        prepare_instance_rollback_dir "${REAL_PORT}" || { pause_screen; return 1; }
        rollback_dir="${INSTANCE_ROLLBACK_DIR}"
        capture_instance_rollback_state "${REAL_PORT}" "${rollback_dir}" || { pause_screen; return 1; }
    fi

    if ! write_apply_script; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    if ! write_systemd_template; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    if ! write_instance_files "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    if ! apply_instance_rules "${REAL_PORT}"; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    if ! configure_ufw_rules "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    if ! validate_instance "${REAL_PORT}" "write"; then
        handle_create_or_update_failure "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${nft_table}" "${nft_file}" "${had_instance}" "${rollback_dir}"
        pause_screen
        return 1
    fi
    ui_blank
    ui_ok "实例 ${REAL_PORT} 配置完成。"
    ui_kv "真实端口" "${REAL_PORT}/udp"
    ui_kv "跳跃范围" "${RANGE_START}-${RANGE_END}/udp"
    ui_kv "客户端参数" "port-hopping=\"${REAL_PORT};${RANGE_START}-${RANGE_END}\", port-hopping-interval=30"
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    pause_screen
}

show_all_instances() {
    page_title
    show_instance_table || true
    pause_screen
}

show_instance_status() {
    page_title
    select_instance || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 0
    }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    local service
    service="$(get_service_name "${REAL_PORT}")"

    ui_section "实例状态：${REAL_PORT}"
    ui_kv "真实端口" "${REAL_PORT}/udp"
    ui_kv "跳跃范围" "${RANGE_START}-${RANGE_END}/udp"
    ui_kv "nftables 表" "inet ${NFT_TABLE_NAME}"
    ui_kv "nftables 文件" "${NFT_RULE_FILE}"
    ui_kv "systemd 服务" "${service}"

    ui_section "监听状态"
    if ! check_command_exists ss; then
        ui_warn "缺少 ss 命令，无法检查监听状态。"
    elif is_udp_port_listening "${REAL_PORT}"; then
        ui_ok "UDP ${REAL_PORT} 正在监听。"
        ui_blank
        ui_info "原始 ss -lunp 过滤结果："
        ss -lunp 2>/dev/null | grep -E ":${REAL_PORT}([[:space:]]|$)" || true
    else
        ui_warn "未检测到 UDP ${REAL_PORT} 监听。"
    fi

    ui_section "nftables 状态"
    if check_command_exists nft && nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        ui_ok "检测到 nftables 表：inet ${NFT_TABLE_NAME}"
        ui_blank
        ui_info "原始 nft list table 输出："
        nft list table inet "${NFT_TABLE_NAME}"
    else
        ui_warn "未检测到 nftables 表。"
    fi

    ui_section "systemd 状态"
    if systemctl status "${service}" --no-pager >/dev/null 2>&1; then
        ui_ok "检测到 systemd 服务：${service}"
    else
        ui_warn "systemd 服务可能未处于正常状态，原始输出如下："
    fi
    ui_blank
    ui_info "原始 systemctl status 输出："
    systemctl status "${service}" --no-pager 2>/dev/null || true

    ui_section "UFW 状态"
    if check_command_exists ufw; then
        ui_blank
        ui_info "原始 ufw status verbose 输出："
        ufw status verbose || true
    else
        ui_warn "未安装 UFW。"
    fi
    pause_screen
}

validate_instance() {
    local requested_port="${1:-}" validation_mode="${2:-readonly}" interactive=1
    if [ -n "${requested_port}" ]; then
        interactive=0
        SELECTED_PORT="${requested_port}"
    fi

    [ "${interactive}" -eq 1 ] && page_title
    if [ "${interactive}" -eq 1 ]; then
        select_instance || {
            [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
            pause_screen
            return 0
        }
    fi
    if ! load_instance_config "${SELECTED_PORT}"; then
        [ "${interactive}" -eq 1 ] && pause_screen
        return 1
    fi

    local service cfg failed=0 can_probe=0 nft_output ufw_output ufw_first_line
    service="$(get_service_name "${REAL_PORT}")"
    cfg="$(get_config_file "${REAL_PORT}")"

    ui_section "验证实例：${REAL_PORT}"
    ui_kv "真实端口" "${REAL_PORT}/udp"
    ui_kv "跳跃范围" "${RANGE_START}-${RANGE_END}/udp"
    ui_kv "nftables 表" "inet ${NFT_TABLE_NAME}"
    ui_kv "systemd 服务" "${service}"
    ui_blank

    if [ -f "${cfg}" ]; then
        ui_ok "实例 env 文件存在：${cfg}"
    else
        ui_warn "实例 env 文件缺失：${cfg}"
        failed=1
    fi

    if [ -n "${NFT_RULE_FILE:-}" ] && [ -f "${NFT_RULE_FILE}" ]; then
        ui_ok "实例 nft 文件存在：${NFT_RULE_FILE}"
    else
        ui_warn "实例 nft 文件缺失：${NFT_RULE_FILE:-未知}"
        failed=1
    fi

    if has_runtime_port_probe_tool; then
        can_probe=1
    else
        warn_missing_runtime_probe_tool_for_readonly
    fi

    if [ "${can_probe}" -eq 1 ] && is_udp_port_listening "${REAL_PORT}"; then
        ui_ok "真实端口 ${REAL_PORT}/udp 正在监听。"
    elif [ "${can_probe}" -eq 1 ]; then
        ui_warn "未检测到真实端口 ${REAL_PORT}/udp 监听。"
        failed=1
    else
        ui_warn "跳过真实端口监听验证：缺少 ss/netstat。"
    fi

    if ! check_command_exists nft; then
        if [ "${validation_mode}" = "write" ]; then
            ensure_nftables_dependency || failed=1
        else
            ui_warn "缺少 nft 命令，无法验证 nftables 运行时规则；只读验证不会自动安装依赖。"
        fi
    fi

    if check_command_exists nft; then
        if nft_output="$(nft list table inet "${NFT_TABLE_NAME}" 2>/dev/null)"; then
            ui_ok "nftables 表存在：inet ${NFT_TABLE_NAME}"
            if echo "${nft_output}" | grep -q "${RANGE_START}-${RANGE_END}" && echo "${nft_output}" | grep -q ":${REAL_PORT}"; then
                ui_ok "检测到跳跃范围重定向规则：${RANGE_START}-${RANGE_END} → ${REAL_PORT}。"
            else
                ui_warn "未检测到预期重定向规则。"
                failed=1
            fi
        else
            ui_warn "nftables 表不存在。"
            failed=1
        fi
    else
        ui_warn "跳过 nftables 运行时规则验证：缺少 nft。"
    fi

    if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
        ui_ok "systemd 服务已启用：${service}"
    else
        ui_warn "systemd 服务未启用。"
        failed=1
    fi

    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        ui_ok "systemd 服务 active。"
    else
        ui_warn "systemd 服务不是 active，最近日志如下："
        ui_blank
        ui_info "原始 journalctl 输出："
        journalctl -u "${service}" -n 20 --no-pager 2>/dev/null || true
        failed=1
    fi

    if check_command_exists ufw; then
        ufw_output="$(ufw status 2>/dev/null || true)"
        ufw_first_line="$(printf '%s\n' "${ufw_output}" | head -n 1)"
        if [ "${ufw_first_line}" = "Status: active" ]; then
            if echo "${ufw_output}" | grep -Eq "${REAL_PORT}/udp|${REAL_PORT}[[:space:]]+.*UDP"; then
                ui_ok "UFW 检测到真实端口规则。"
            else
                ui_warn "UFW active，但未检测到真实端口规则。"
                failed=1
            fi
            if echo "${ufw_output}" | grep -Eq "${RANGE_START}:${RANGE_END}/udp|${RANGE_START}:${RANGE_END}"; then
                ui_ok "UFW 检测到跳跃范围规则。"
            else
                ui_warn "UFW active，但未检测到跳跃范围规则。"
                failed=1
            fi
        else
            ui_warn "UFW 未启用或状态未知，跳过 UFW 规则强校验。"
        fi
        ui_blank
        ui_info "原始 ufw status verbose 输出："
        ufw status verbose 2>/dev/null || true
    fi

    ui_blank
    if [ "${failed}" -eq 0 ]; then
        ui_ok "核心配置验证通过。"
    else
        ui_warn "存在需要人工确认的项目。请检查 sing-box、nftables、systemd、UFW 与商家安全组。"
    fi
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    [ "${interactive}" -eq 1 ] && pause_screen
    return "${failed}"
}

show_client_hint() {
    page_title
    select_instance || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 0
    }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    ui_section "客户端配置提示：${REAL_PORT}"
    ui_warn "下面会显示包含敏感凭据的客户端配置，请避免在共享屏幕、日志或工单中泄露。"
    ui_blank
    ui_print "Surge / Surgio 建议追加："
    ui_blank
    ui_print "${COLOR_YELLOW}port-hopping=\"${REAL_PORT};${RANGE_START}-${RANGE_END}\", port-hopping-interval=30${COLOR_RESET}"
    ui_blank
    ui_warn "启用 port-hopping 后，建议跳跃列表中显式包含真实端口 ${REAL_PORT}。"
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    pause_screen
}

show_tcpdump_helper() {
    page_title
    select_instance || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 0
    }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    ui_section "抓包辅助命令：${REAL_PORT}"
    ui_kv "真实端口" "${REAL_PORT}/udp"
    ui_kv "跳跃范围" "${RANGE_START}-${RANGE_END}/udp"
    ui_blank
    ui_print "同时观察真实端口与跳跃端口范围："
    ui_blank
    ui_print "${COLOR_YELLOW}sudo tcpdump -ni any 'udp port ${REAL_PORT} or udp portrange ${RANGE_START}-${RANGE_END}'${COLOR_RESET}"
    ui_blank
    ui_print "只观察跳跃端口范围："
    ui_blank
    ui_print "${COLOR_YELLOW}sudo tcpdump -ni any 'udp portrange ${RANGE_START}-${RANGE_END}'${COLOR_RESET}"
    ui_blank
    ui_print "只观察真实 TUIC 端口："
    ui_blank
    ui_print "${COLOR_YELLOW}sudo tcpdump -ni any 'udp port ${REAL_PORT}'${COLOR_RESET}"
    ui_blank
    ui_warn "如果没有安装 tcpdump，可执行：sudo apt install -y tcpdump"
    ui_warn "如果能看到跳跃端口入站但节点不可用，重点检查 nftables、TUIC token/证书、UFW 与商家安全组。"
    pause_screen
}

reapply_instance() {
    page_title
    select_instance || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 0
    }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    ui_section "重新应用实例规则：${REAL_PORT}"
    ui_kv "真实端口" "${REAL_PORT}/udp"
    ui_kv "跳跃范围" "${RANGE_START}-${RANGE_END}/udp"
    ui_kv "nftables 表" "inet ${NFT_TABLE_NAME}"
    ui_kv "systemd 服务" "$(get_service_name "${REAL_PORT}")"
    ensure_nftables_dependency
    case "$?" in
        0) ;;
        1|"${UI_RETURN_TO_MENU}") return 0 ;;
        *) pause_screen; return 1 ;;
    esac
    test_nft_nat_support || { pause_screen; return 1; }
    write_apply_script
    write_systemd_template
    apply_instance_rules "${REAL_PORT}"
    pause_screen
}

remove_instance() {
    page_title
    select_instance || {
        [ "$?" -eq "${UI_RETURN_TO_MENU}" ] && return 0
        pause_screen
        return 0
    }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    local service cfg
    service="$(get_service_name "${REAL_PORT}")"
    cfg="$(get_config_file "${REAL_PORT}")"

    ui_section "高风险操作确认"
    ui_warn "此操作将删除当前 TUIC Port-Hopping 实例，并移除以下对象："
    ui_kv "配置文件" "${cfg}"
    ui_kv "nftables 表" "inet ${NFT_TABLE_NAME}"
    ui_kv "nftables 文件" "${NFT_RULE_FILE}"
    ui_kv "systemd 服务" "${service}"
    ui_kv "UFW 规则" "${REAL_PORT}/udp 与 ${RANGE_START}:${RANGE_END}/udp"
    ui_blank
    ui_confirm_token "确认删除当前 TUIC 实例？" "DELETE" || { ui_warn "已取消删除。"; pause_screen; return 0; }

    local cleanup_failed=0 residual_failed=0
    ensure_nftables_dependency || cleanup_failed=1
    ensure_runtime_validation_dependencies || cleanup_failed=1

    disable_instance_service_with_report "${REAL_PORT}" || cleanup_failed=1
    remove_instance_nft_runtime "${NFT_TABLE_NAME}" || cleanup_failed=1
    remove_ufw_rules "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" || cleanup_failed=1

    if rm -f "${NFT_RULE_FILE}" "${cfg}"; then
        ui_ok "已删除实例 env/nft 文件。"
    else
        ui_warn "实例 env/nft 文件删除失败。"
        show_file_manual_cleanup_commands "${cfg}" "${NFT_RULE_FILE}"
        cleanup_failed=1
    fi

    systemctl daemon-reload >/dev/null 2>&1 || {
        ui_warn "systemd daemon-reload 失败。"
        show_systemd_diagnostics "${REAL_PORT}"
        cleanup_failed=1
    }

    report_instance_deletion_residuals "${REAL_PORT}" "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" "${NFT_TABLE_NAME}" "${NFT_RULE_FILE}" "${cfg}" || residual_failed=1
    if [ "${cleanup_failed}" -eq 0 ] && [ "${residual_failed}" -eq 0 ]; then
        ui_ok "实例 ${REAL_PORT} 删除完成，未检测到脚本管理对象残留。"
    else
        ui_warn "实例 ${REAL_PORT} 删除后仍存在失败项或未验证项，请按上方命令人工处理。"
    fi
    pause_screen
    [ "${cleanup_failed}" -eq 0 ] && [ "${residual_failed}" -eq 0 ]
}

remove_all_instances() {
    page_title
    show_instance_table || { pause_screen; return 0; }
    ui_section "高风险操作确认"
    ui_warn "此操作将删除全部 TUIC Port-Hopping 实例，并移除以下对象："
    ui_kv "实例目录" "${INSTANCE_DIR}"
    ui_kv "通用脚本" "${APPLY_SCRIPT}"
    ui_kv "systemd 模板" "${SYSTEMD_TEMPLATE}"
    ui_kv "nftables 文件" "${NFT_RULE_DIR}/tuic-port-hopping-*.nft"
    ui_kv "UFW 规则" "所有实例对应 UDP 规则"
    ui_blank
    ui_confirm_token "确认删除全部 TUIC 实例？" "DELETE-ALL" || { ui_warn "已取消删除。"; pause_screen; return 0; }

    local port cfg real start end table nft_file cleanup_failed=0 residual_failed=0
    local total_count=0 clear_count=0 residual_count=0 common_failed=0
    local port_list

    ensure_nftables_dependency || cleanup_failed=1
    ensure_runtime_validation_dependencies || cleanup_failed=1

    port_list="$(list_instances)"
    for port in ${port_list}; do
        [ -n "${port}" ] || continue
        total_count=$((total_count + 1))
        cfg="$(get_config_file "${port}")"
        real="$(read_env_value "${cfg}" "REAL_PORT" || true)"
        start="$(read_env_value "${cfg}" "RANGE_START" || true)"
        end="$(read_env_value "${cfg}" "RANGE_END" || true)"
        table="$(read_env_value "${cfg}" "NFT_TABLE_NAME" || true)"
        nft_file="$(read_env_value "${cfg}" "NFT_RULE_FILE" || true)"
        real="${real:-${port}}"
        table="${table:-$(get_nft_table_name "${port}")}"
        nft_file="${nft_file:-$(get_nft_rule_file "${port}")}"

        ui_section "删除实例：${port}"
        disable_instance_service_with_report "${port}" || cleanup_failed=1
        remove_instance_nft_runtime "${table}" || cleanup_failed=1
        if validate_instance_env_values "${real}" "${start:-}" "${end:-}"; then
            remove_ufw_rules "${real}" "${start}" "${end}" || cleanup_failed=1
        else
            ui_warn "实例 ${port} 的端口范围无效，跳过 UFW 自动删除并进入残留报告。"
            cleanup_failed=1
            start="${start:-0}"
            end="${end:-0}"
        fi
        if rm -f "${nft_file}" "${cfg}"; then
            ui_ok "已删除实例 env/nft 文件：${port}"
        else
            ui_warn "实例 ${port} env/nft 文件删除失败。"
            show_file_manual_cleanup_commands "${cfg}" "${nft_file}"
            cleanup_failed=1
        fi

        if report_instance_deletion_residuals "${port}" "${real}" "${start}" "${end}" "${table}" "${nft_file}" "${cfg}"; then
            clear_count=$((clear_count + 1))
        else
            residual_count=$((residual_count + 1))
            residual_failed=1
        fi
    done

    if [ "${residual_count}" -eq 0 ] && ! has_instances; then
        cleanup_common_objects_with_report || common_failed=1
    else
        ui_warn "仍有实例残留或实例文件，跳过公共 apply 脚本与 systemd 模板删除。"
        common_failed=1
    fi
    report_common_deletion_residuals || common_failed=1

    ui_section "删除汇总"
    ui_kv "总实例数" "${total_count}"
    ui_kv "无残留实例" "${clear_count}"
    ui_kv "有残留实例" "${residual_count}"
    if [ "${cleanup_failed}" -eq 0 ] && [ "${residual_failed}" -eq 0 ] && [ "${common_failed}" -eq 0 ]; then
        ui_ok "全部实例删除完成，未检测到脚本管理对象残留。"
    else
        ui_warn "删除全部实例后仍存在失败项或未验证项，请按上方命令人工处理。"
    fi
    pause_screen
    [ "${cleanup_failed}" -eq 0 ] && [ "${residual_failed}" -eq 0 ] && [ "${common_failed}" -eq 0 ]
}

show_main_menu() {
    local choice
    while true; do
        page_title
        ui_dim "$(build_main_status_line)"
        ui_blank
        ui_print "请选择操作："
        ui_blank
        ui_menu_item 1 "创建 / 更新实例"
        ui_menu_item 2 "查看实例列表"
        ui_menu_item 3 "查看实例状态"
        ui_menu_item 4 "运行实例验证"
        ui_menu_item 5 "显示客户端配置提示"
        ui_menu_item 6 "显示抓包排查命令"
        ui_menu_item 7 "重新应用实例规则"
        ui_menu_item 8 "删除单个实例"
        ui_menu_item 9 "删除全部实例"
        ui_menu_item 0 "退出"
        ui_blank
        ui_menu_footer
        ui_blank
        ui_read_menu_choice choice
        case "${choice}" in
            1) create_or_update_instance ;;
            2) show_all_instances ;;
            3) show_instance_status ;;
            4) validate_instance ;;
            5) show_client_hint ;;
            6) show_tcpdump_helper ;;
            7) reapply_instance ;;
            8) remove_instance ;;
            9) remove_all_instances ;;
            0) ui_blank; ui_info "已退出。"; exit 0 ;;
            q|Q)
                ui_warn "主菜单请使用 0 退出脚本。"
                sleep 1
                ;;
            *)
                ui_error "无效选项，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

parse_arguments() {
    COMMAND="menu"

    if [ "$#" -eq 0 ] && [ -z "${BASH_SOURCE[0]:-}" ]; then
        case "${0:-}" in
            -h|--help|menu)
                set -- "${0}"
                ;;
        esac
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                COMMAND="help"
                shift
                ;;
            menu)
                COMMAND="menu"
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

    case "${COMMAND}" in
        help)
            show_help
            return 0
            ;;
        menu)
            require_root
            ensure_directories
            show_main_menu
            ;;
        *)
            ui_error "未知命令：${COMMAND}"
            return 1
            ;;
    esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi
