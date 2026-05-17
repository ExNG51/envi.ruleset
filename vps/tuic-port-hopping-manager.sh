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

SCRIPT_VERSION="2026.05.02-r5"
BASE_DIR="/etc/tuic-port-hopping"
INSTANCE_DIR="${BASE_DIR}/instances"
NFT_RULE_DIR="/etc/nftables.d"
APPLY_SCRIPT="/usr/local/sbin/apply-tuic-port-hopping.sh"
SYSTEMD_TEMPLATE="/etc/systemd/system/tuic-port-hopping@.service"
NFT_TABLE_PREFIX="tuic_hopping_"

UI_TITLE_WIDTH=60
UI_KV_LABEL_WIDTH=16
UI_RETURN_TO_MENU=2

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
    ui_clear
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

ui_pause() {
    local _
    ui_blank
    read_prompt _ "按回车键继续..."
}

print_title() { ui_title "TUIC Port-Hopping 多实例管理脚本" "${SCRIPT_VERSION}"; }
print_section() { ui_section "$@"; }
print_success() { ui_ok "$@"; }
print_warn() { ui_warn "$@"; }
print_error() { ui_error "$@"; }
print_info() { ui_info "$@"; }
print_dim() { ui_dim "$@"; }

init_prompt_input() {
    if [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
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

pause_screen() {
    ui_pause
}

confirm_yes_no() {
    local prompt_text="$1" answer=""
    while true; do
        read_prompt answer "${prompt_text} [y/n]: "
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
    mkdir -p "${INSTANCE_DIR}"
    local file_path
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

show_instance_table() {
    print_section "实例列表"
    if ! has_instances; then
        print_warn "当前没有已创建的实例。"
        return 1
    fi

    printf "%s\n" "------------------------------------------------------------"
    printf "%-8s %-18s %-16s %-12s\n" "端口" "跳跃范围" "systemd" "更新时间"
    printf "%s\n" "------------------------------------------------------------"

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

    printf "%s\n" "------------------------------------------------------------"
}

select_instance() {
    SELECTED_PORT=""
    show_instance_table || return 1
    echo
    local port
    while true; do
        read_prompt port "请输入要管理的真实 TUIC 端口，或输入 0 返回： "
        [ "${port}" = "0" ] && return 1
        validate_port "${port}" || { print_error "端口格式无效。"; continue; }
        [ -f "$(get_config_file "${port}")" ] || { print_error "未找到端口 ${port} 的实例。"; continue; }
        SELECTED_PORT="${port}"
        return 0
    done
}

load_instance_config() {
    local port="$1" cfg
    cfg="$(get_config_file "${port}")"
    [ -f "${cfg}" ] || { print_error "未找到实例配置：${cfg}"; return 1; }
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

is_udp_port_listening() {
    local port="$1"
    check_command_exists ss || return 2
    ss -H -lunp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)"
}

check_tuic_listener() {
    print_section "监听检查"
    if ! check_command_exists ss; then
        print_warn "缺少 ss 命令，无法检查监听状态。通常可安装 iproute2。"
        return 0
    fi
    if is_udp_port_listening "${REAL_PORT}"; then
        print_success "检测到 UDP ${REAL_PORT} 正在监听。"
        return 0
    fi
    print_warn "未检测到 UDP ${REAL_PORT} 正在监听。"
    print_warn "如果 sing-box / TUIC 尚未启动，可先继续创建规则，稍后再验证。"
    confirm_yes_no "是否仍然继续配置该端口"
}

check_range_listener_conflict() {
    local start_port="$1" end_port="$2"
    check_command_exists ss || return 0
    local used_ports used_port found=0
    used_ports="$(ss -H -lunp 2>/dev/null | grep -Eo ':[0-9]+' | tr -d ':' | sort -n | uniq || true)"
    for used_port in ${used_ports}; do
        if [ "${used_port}" -ge "${start_port}" ] && [ "${used_port}" -le "${end_port}" ]; then
            print_warn "跳跃范围内检测到已监听 UDP 端口：${used_port}"
            found=1
        fi
    done
    [ "${found}" -eq 0 ]
}

check_instance_range_conflict() {
    local real_port="$1" start_port="$2" end_port="$3"
    local cfg other_port other_start other_end
    for cfg in "${INSTANCE_DIR}"/*.env; do
        [ -e "${cfg}" ] || continue
        other_port="$(read_env_value "${cfg}" "REAL_PORT" || true)"
        [ "${other_port}" = "${real_port}" ] && continue
        other_start="$(read_env_value "${cfg}" "RANGE_START" || true)"
        other_end="$(read_env_value "${cfg}" "RANGE_END" || true)"
        [ -n "${other_start}" ] && [ -n "${other_end}" ] || continue
        if ranges_overlap "${start_port}" "${end_port}" "${other_start}" "${other_end}"; then
            print_error "跳跃范围与已有实例 ${other_port} 冲突：${other_start}-${other_end}"
            return 1
        fi
    done
    return 0
}

prompt_real_port() {
    REAL_PORT=""
    while true; do
        read_prompt REAL_PORT "请输入当前 TUIC UDP 监听端口： "
        validate_port "${REAL_PORT}" && break
        print_error "端口格式无效，请输入 1-65535 之间的数字。"
    done
}

prompt_port_range() {
    local auto_range custom_range
    auto_range="$(calculate_auto_range "${REAL_PORT}")"
    print_info "根据真实端口 ${REAL_PORT} 自动生成的跳跃范围：${auto_range}"
    print_info "可直接回车使用自动范围，也可输入自定义范围，格式为：起始端口-结束端口"
    while true; do
        read_prompt custom_range "请输入跳跃端口范围（回车使用 ${auto_range}）： "
        custom_range="${custom_range:-${auto_range}}"
        validate_port_range "${custom_range}" || { print_error "范围格式无效，请使用 start-end。"; continue; }
        RANGE_START="${custom_range%-*}"
        RANGE_END="${custom_range#*-}"
        if [ "${REAL_PORT}" -ge "${RANGE_START}" ] && [ "${REAL_PORT}" -le "${RANGE_END}" ]; then
            print_error "跳跃范围不能包含真实端口 ${REAL_PORT}。"
            continue
        fi
        check_instance_range_conflict "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}" || continue
        if ! check_range_listener_conflict "${RANGE_START}" "${RANGE_END}"; then
            confirm_yes_no "检测到端口占用风险，是否仍然继续" || continue
        fi
        break
    done
}

install_nftables_if_needed() {
    print_section "nftables 检查"
    if check_command_exists nft; then
        print_success "nftables 已安装。"
        return 0
    fi
    print_warn "nftables 未安装。"
    confirm_yes_no "是否现在安装 nftables" || return 1
    export DEBIAN_FRONTEND=noninteractive
    if check_command_exists apt-get; then
        apt-get update && apt-get install -y nftables
    elif check_command_exists dnf; then
        dnf install -y nftables
    elif check_command_exists yum; then
        yum install -y nftables
    else
        print_error "未识别到 apt-get / dnf / yum，请手动安装 nftables。"
        return 1
    fi
    check_command_exists nft || { print_error "nftables 安装失败。"; return 1; }
    print_success "nftables 安装完成。"
}

test_nft_nat_support() {
    print_section "nftables NAT 能力测试"
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
        print_success "当前系统支持 nftables inet NAT prerouting。"
        return 0
    fi
    print_error "当前系统无法创建 nftables inet NAT prerouting。"
    print_error "可能原因：OpenVZ/LXC 权限限制、内核模块缺失、系统内核过旧。"
    return 1
}

write_apply_script() {
    cat > "${APPLY_SCRIPT}" <<'EOF_APPLY'
#!/bin/sh
set -eu

port="${1:-}"
if [ -z "${port}" ]; then
    echo "[错误] 缺少实例端口参数。"
    exit 1
fi

config_file="/etc/tuic-port-hopping/instances/${port}.env"
if [ ! -f "${config_file}" ]; then
    echo "[错误] 未找到实例配置：${config_file}"
    exit 1
fi

# shellcheck disable=SC1090
. "${config_file}"

if [ -z "${NFT_TABLE_NAME:-}" ] || [ -z "${NFT_RULE_FILE:-}" ]; then
    echo "[错误] 实例配置缺少 NFT_TABLE_NAME 或 NFT_RULE_FILE。"
    exit 1
fi

if nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
    nft delete table inet "${NFT_TABLE_NAME}"
fi

nft -f "${NFT_RULE_FILE}"
EOF_APPLY
    chmod +x "${APPLY_SCRIPT}"
    print_success "已写入通用应用脚本：${APPLY_SCRIPT}"
}

write_systemd_template() {
    cat > "${SYSTEMD_TEMPLATE}" <<EOF_SYSTEMD
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
    systemctl daemon-reload
    print_success "已写入 systemd 模板：${SYSTEMD_TEMPLATE}"
}

write_instance_files() {
    local real_port="$1" start_port="$2" end_port="$3"
    local cfg nft_file nft_table updated_at
    cfg="$(get_config_file "${real_port}")"
    nft_file="$(get_nft_rule_file "${real_port}")"
    nft_table="$(get_nft_table_name "${real_port}")"
    updated_at="$(date +%F)"

    cat > "${cfg}" <<EOF_CFG
# TUIC Port-Hopping 实例配置
REAL_PORT="${real_port}"
RANGE_START="${start_port}"
RANGE_END="${end_port}"
NFT_TABLE_NAME="${nft_table}"
NFT_RULE_FILE="${nft_file}"
UPDATED_AT="${updated_at}"
EOF_CFG

    cat > "${nft_file}" <<EOF_NFT
 table inet ${nft_table} {
     chain prerouting {
         type nat hook prerouting priority dstnat; policy accept;

         # 将 TUIC 跳跃 UDP 端口范围重定向到真实监听端口
         udp dport ${start_port}-${end_port} redirect to :${real_port}
     }
 }
EOF_NFT

    print_success "已写入实例配置：${cfg}"
    print_success "已写入 nftables 规则：${nft_file}"
}

apply_instance_rules() {
    local port="$1" service
    service="$(get_service_name "${port}")"
    print_section "应用实例规则：${port}"
    if "${APPLY_SCRIPT}" "${port}"; then
        print_success "nftables 规则已应用。"
    else
        print_error "nftables 规则应用失败，最近 systemd 日志如下："
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    systemctl enable "${service}" >/dev/null 2>&1
    systemctl restart "${service}" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        print_success "systemd 服务已启用并处于 active：${service}"
    else
        print_warn "systemd 服务未处于 active，最近日志如下："
        journalctl -u "${service}" -n 30 --no-pager 2>/dev/null || true
    fi
}

configure_ufw_rules() {
    local real_port="$1" start_port="$2" end_port="$3"
    print_section "UFW 放行规则"
    if ! check_command_exists ufw; then
        print_warn "未检测到 UFW，跳过 UFW 放行。"
        return 0
    fi
    ufw allow "${real_port}/udp" >/dev/null 2>&1 || true
    ufw allow "${start_port}:${end_port}/udp" >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    print_success "已补充 UFW 放行：${real_port}/udp"
    print_success "已补充 UFW 放行：${start_port}:${end_port}/udp"
}

remove_ufw_rules() {
    local real_port="$1" start_port="$2" end_port="$3"
    check_command_exists ufw || return 0
    print_section "删除 UFW 放行规则"
    ufw --force delete allow "${real_port}/udp" >/dev/null 2>&1 || print_warn "未找到或未删除 UFW 规则：${real_port}/udp"
    ufw --force delete allow "${start_port}:${end_port}/udp" >/dev/null 2>&1 || print_warn "未找到或未删除 UFW 规则：${start_port}:${end_port}/udp"
    ufw reload >/dev/null 2>&1 || true
}

show_security_group_hint() {
    local real_port="$1" start_port="$2" end_port="$3"
    echo
    print_warn "请确认 VPS 商家后台安全组也已放行："
    echo "  ${real_port}/udp"
    echo "  ${start_port}-${end_port}/udp"
}

create_or_update_instance() {
    print_title
    print_section "创建 / 更新实例"
    prompt_real_port
    if [ -f "$(get_config_file "${REAL_PORT}")" ]; then
        print_warn "端口 ${REAL_PORT} 已存在实例，本流程会覆盖该实例配置。"
        confirm_yes_no "是否继续更新该实例" || { pause_screen; return 0; }
    fi
    check_tuic_listener || { print_warn "已取消。"; pause_screen; return 0; }
    prompt_port_range
    install_nftables_if_needed || { pause_screen; return 1; }
    test_nft_nat_support || { pause_screen; return 1; }
    ensure_directories
    write_apply_script
    write_systemd_template
    write_instance_files "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    apply_instance_rules "${REAL_PORT}" || { pause_screen; return 1; }
    configure_ufw_rules "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    echo
    print_success "实例 ${REAL_PORT} 配置完成。"
    echo "  真实 TUIC 端口：${REAL_PORT}/udp"
    echo "  跳跃端口范围：${RANGE_START}-${RANGE_END}/udp"
    echo "  客户端参数：port-hopping=\"${REAL_PORT};${RANGE_START}-${RANGE_END}\", port-hopping-interval=30"
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    pause_screen
}

show_all_instances() {
    print_title
    show_instance_table || true
    pause_screen
}

show_instance_status() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    local service
    service="$(get_service_name "${REAL_PORT}")"

    print_section "实例状态：${REAL_PORT}"
    echo "真实端口：${REAL_PORT}/udp"
    echo "跳跃范围：${RANGE_START}-${RANGE_END}/udp"
    echo "nftables 表：${NFT_TABLE_NAME}"
    echo "nftables 文件：${NFT_RULE_FILE}"
    echo "systemd 服务：${service}"

    print_section "监听状态"
    if check_command_exists ss && is_udp_port_listening "${REAL_PORT}"; then
        print_success "UDP ${REAL_PORT} 正在监听。"
        ss -lunp 2>/dev/null | grep -E ":${REAL_PORT}([[:space:]]|$)" || true
    else
        print_warn "未检测到 UDP ${REAL_PORT} 监听。"
    fi

    print_section "nftables 状态"
    if check_command_exists nft && nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        nft list table inet "${NFT_TABLE_NAME}"
    else
        print_warn "未检测到 nftables 表。"
    fi

    print_section "systemd 状态"
    systemctl status "${service}" --no-pager 2>/dev/null || print_warn "未检测到 systemd 服务。"

    print_section "UFW 状态"
    if check_command_exists ufw; then
        ufw status verbose || true
    else
        print_warn "未安装 UFW。"
    fi
    pause_screen
}

validate_instance() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    local service failed=0
    service="$(get_service_name "${REAL_PORT}")"

    print_section "验证实例：${REAL_PORT}"
    if check_command_exists ss && is_udp_port_listening "${REAL_PORT}"; then
        print_success "真实端口 ${REAL_PORT}/udp 正在监听。"
    else
        print_warn "未检测到真实端口 ${REAL_PORT}/udp 监听。"
        failed=1
    fi

    if check_command_exists nft && nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        print_success "nftables 表存在：inet ${NFT_TABLE_NAME}"
    else
        print_warn "nftables 表不存在。"
        failed=1
    fi

    if check_command_exists nft && nft list table inet "${NFT_TABLE_NAME}" 2>/dev/null | grep -q "${RANGE_START}-${RANGE_END}"; then
        print_success "检测到跳跃范围重定向规则：${RANGE_START}-${RANGE_END} → ${REAL_PORT}。"
    else
        print_warn "未检测到预期重定向规则。"
        failed=1
    fi

    if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
        print_success "systemd 服务已启用：${service}"
    else
        print_warn "systemd 服务未启用。"
        failed=1
    fi

    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        print_success "systemd 服务 active。"
    else
        print_warn "systemd 服务不是 active，最近日志如下："
        journalctl -u "${service}" -n 20 --no-pager 2>/dev/null || true
        failed=1
    fi

    if check_command_exists ufw; then
        local ufw_output
        ufw_output="$(ufw status 2>/dev/null || true)"
        echo "${ufw_output}" | grep -Eq "${REAL_PORT}/udp|${REAL_PORT}[[:space:]]+.*UDP" && print_success "UFW 检测到真实端口规则。" || print_warn "UFW 未检测到真实端口规则。"
        echo "${ufw_output}" | grep -Eq "${RANGE_START}:${RANGE_END}/udp|${RANGE_START}:${RANGE_END}" && print_success "UFW 检测到跳跃范围规则。" || print_warn "UFW 未检测到跳跃范围规则。"
    fi

    echo
    if [ "${failed}" -eq 0 ]; then
        print_success "核心配置验证通过。"
    else
        print_warn "存在需要人工确认的项目。请检查 sing-box、nftables、systemd、UFW 与商家安全组。"
    fi
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    pause_screen
}

show_client_hint() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    print_section "客户端配置提示：${REAL_PORT}"
    echo "Surge / Surgio 建议追加："
    echo
    echo -e "${COLOR_YELLOW}port-hopping=\"${REAL_PORT};${RANGE_START}-${RANGE_END}\", port-hopping-interval=30${COLOR_RESET}"
    echo
    print_warn "启用 port-hopping 后，建议跳跃列表中显式包含真实端口 ${REAL_PORT}。"
    show_security_group_hint "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    pause_screen
}

show_tcpdump_helper() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    print_section "抓包辅助命令：${REAL_PORT}"
    echo "同时观察真实端口与跳跃端口范围："
    echo -e "${COLOR_YELLOW}sudo tcpdump -ni any 'udp port ${REAL_PORT} or udp portrange ${RANGE_START}-${RANGE_END}'${COLOR_RESET}"
    echo
    echo "只观察跳跃端口范围："
    echo -e "${COLOR_YELLOW}sudo tcpdump -ni any 'udp portrange ${RANGE_START}-${RANGE_END}'${COLOR_RESET}"
    echo
    echo "只观察真实 TUIC 端口："
    echo -e "${COLOR_YELLOW}sudo tcpdump -ni any 'udp port ${REAL_PORT}'${COLOR_RESET}"
    echo
    print_warn "如果没有安装 tcpdump，可执行：sudo apt install -y tcpdump"
    print_warn "如果能看到跳跃端口入站但节点不可用，重点检查 nftables、TUIC token/证书、UFW 与商家安全组。"
    pause_screen
}

reapply_instance() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    install_nftables_if_needed || { pause_screen; return 1; }
    test_nft_nat_support || { pause_screen; return 1; }
    write_apply_script
    write_systemd_template
    apply_instance_rules "${REAL_PORT}"
    pause_screen
}

remove_instance() {
    print_title
    select_instance || { pause_screen; return 0; }
    load_instance_config "${SELECTED_PORT}" || { pause_screen; return 1; }
    local service cfg answer
    service="$(get_service_name "${REAL_PORT}")"
    cfg="$(get_config_file "${REAL_PORT}")"

    print_section "删除实例：${REAL_PORT}"
    echo "即将删除："
    echo "  配置：${cfg}"
    echo "  nftables 表：inet ${NFT_TABLE_NAME}"
    echo "  nftables 文件：${NFT_RULE_FILE}"
    echo "  systemd 服务：${service}"
    echo "  UFW 规则：${REAL_PORT}/udp 与 ${RANGE_START}:${RANGE_END}/udp"
    echo
    read_prompt answer "确认删除该实例？输入 DELETE 继续： "
    [ "${answer}" = "DELETE" ] || { print_warn "已取消删除。"; pause_screen; return 0; }

    systemctl disable --now "${service}" >/dev/null 2>&1 || true
    if check_command_exists nft && nft list table inet "${NFT_TABLE_NAME}" >/dev/null 2>&1; then
        nft delete table inet "${NFT_TABLE_NAME}" || true
        print_success "已删除 nftables 表：inet ${NFT_TABLE_NAME}"
    fi
    remove_ufw_rules "${REAL_PORT}" "${RANGE_START}" "${RANGE_END}"
    rm -f "${NFT_RULE_FILE}" "${cfg}"
    print_success "实例 ${REAL_PORT} 已删除。"
    pause_screen
}

remove_all_instances() {
    print_title
    print_section "删除全部实例"
    show_instance_table || { pause_screen; return 0; }
    echo
    local answer
    read_prompt answer "确认删除全部实例？输入 DELETE-ALL 继续： "
    [ "${answer}" = "DELETE-ALL" ] || { print_warn "已取消删除。"; pause_screen; return 0; }

    local port cfg real start end table nft_file service
    while read -r port; do
        [ -n "${port}" ] || continue
        cfg="$(get_config_file "${port}")"
        real="$(read_env_value "${cfg}" "REAL_PORT" || true)"
        start="$(read_env_value "${cfg}" "RANGE_START" || true)"
        end="$(read_env_value "${cfg}" "RANGE_END" || true)"
        table="$(read_env_value "${cfg}" "NFT_TABLE_NAME" || true)"
        nft_file="$(read_env_value "${cfg}" "NFT_RULE_FILE" || true)"
        service="$(get_service_name "${port}")"
        systemctl disable --now "${service}" >/dev/null 2>&1 || true
        if check_command_exists nft && [ -n "${table}" ] && nft list table inet "${table}" >/dev/null 2>&1; then
            nft delete table inet "${table}" || true
        fi
        if [ -n "${real}" ] && [ -n "${start}" ] && [ -n "${end}" ]; then
            remove_ufw_rules "${real}" "${start}" "${end}"
        fi
        rm -f "${nft_file}" "${cfg}"
        print_success "已删除实例：${port}"
    done < <(list_instances)

    rm -f "${APPLY_SCRIPT}" "${SYSTEMD_TEMPLATE}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rmdir "${INSTANCE_DIR}" "${BASE_DIR}" >/dev/null 2>&1 || true
    print_success "全部实例已删除。"
    pause_screen
}

show_main_menu() {
    while true; do
        print_title
        echo "请选择操作："
        echo
        echo "  1) 创建 / 更新实例"
        echo "  2) 查看实例列表"
        echo "  3) 查看实例状态"
        echo "  4) 运行实例验证"
        echo "  5) 显示客户端配置提示"
        echo "  6) 显示抓包排查命令"
        echo "  7) 重新应用实例规则"
        echo "  8) 删除单个实例"
        echo "  9) 删除全部实例"
        echo "  0) 退出"
        echo
        if has_instances; then
            print_dim "当前已创建实例：$(list_instances | paste -sd ', ' -)"
        else
            print_dim "当前没有已创建实例。"
        fi
        echo
        read_prompt choice "请输入选项编号： "
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
            0) echo; print_info "已退出。"; exit 0 ;;
            *) print_error "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    ui_init_colors
    init_prompt_input
    ensure_directories
    show_main_menu
}

main "$@"
