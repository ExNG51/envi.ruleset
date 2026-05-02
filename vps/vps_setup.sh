#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 脚本意图: VPS 通用初始化入口，支持独立公网 IP 与 NAT VPS 两种 profile
# 用法示例:
#   bash vps_setup.sh --profile public
#   bash vps_setup.sh --profile nat --yes
#   bash vps_setup.sh --profile public --install-docker --ssh-port 2222
# ==============================================================================

readonly COLOR_TEXT_RED='\033[0;31m'
readonly COLOR_TEXT_GREEN='\033[0;32m'
readonly COLOR_TEXT_YELLOW='\033[1;33m'
readonly COLOR_TEXT_BLUE='\033[1;34m'
readonly FORMAT_TEXT_BOLD='\033[1m'
readonly STYLE_RESET='\033[0m'

display_status_info() { echo -e "${COLOR_TEXT_BLUE}${FORMAT_TEXT_BOLD}[信息] $1${STYLE_RESET}"; }
display_status_success() { echo -e "${COLOR_TEXT_GREEN}${FORMAT_TEXT_BOLD}[成功] $1${STYLE_RESET}"; }
display_status_warning() { echo -e "${COLOR_TEXT_YELLOW}${FORMAT_TEXT_BOLD}[警告] $1${STYLE_RESET}"; }
display_status_error() { echo -e "${COLOR_TEXT_RED}${FORMAT_TEXT_BOLD}[错误] $1${STYLE_RESET}"; }

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

show_usage() {
    cat <<'EOF'
用法: bash vps_setup.sh [options]

Options:
  --profile public|nat       VPS 类型。public=独立公网 IP，nat=NAT VPS。
  --timezone Zone/Name       设置时区，默认 Asia/Singapore。
  --yes                      非交互执行，公共可选组件默认不安装。
  --install-docker           public profile 可选：通过系统包管理器安装 Docker。
  --install-nodejs           public profile 可选：通过系统包管理器安装 Node.js/npm。
  --install-cloud-kernel     public profile 可选：Debian 安装 linux-image-cloud-amd64。
  --ssh-port PORT            public profile 可选：安全修改 SSH 监听端口。
  -h, --help                 显示帮助。
EOF
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile)
                shift
                GLOBAL_PROFILE="${1:-}"
                ;;
            --timezone)
                shift
                GLOBAL_TIMEZONE="${1:-}"
                ;;
            --yes)
                GLOBAL_ASSUME_YES=true
                ;;
            --install-docker)
                GLOBAL_INSTALL_DOCKER=true
                ;;
            --install-nodejs)
                GLOBAL_INSTALL_NODEJS=true
                ;;
            --install-cloud-kernel)
                GLOBAL_INSTALL_CLOUD_KERNEL=true
                ;;
            --ssh-port)
                shift
                GLOBAL_SSH_PORT="${1:-}"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                display_status_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

validate_root_privilege() {
    display_status_info "正在校验 root 权限..."
    if [[ $EUID -ne 0 ]]; then
        display_status_error "权限不足：请以 root 身份或使用 sudo 执行此脚本。"
        exit 1
    fi
    display_status_success "root 权限校验通过。"
}

select_vps_profile() {
    if [ -z "$GLOBAL_PROFILE" ] && [ "$GLOBAL_ASSUME_YES" = true ]; then
        display_status_error "--yes 模式必须显式传入 --profile public 或 --profile nat。"
        exit 1
    fi

    while [ -z "$GLOBAL_PROFILE" ]; do
        echo "请选择 VPS 类型:"
        echo "  1) public - 独立公网 IP VPS"
        echo "  2) nat    - NAT VPS / 共享公网出口"
        read -rp "请输入选项 [1-2]: " selected_profile
        case "$selected_profile" in
            1) GLOBAL_PROFILE="public" ;;
            2) GLOBAL_PROFILE="nat" ;;
            *) display_status_warning "无效选项，请重新输入。" ;;
        esac
    done

    if [[ "$GLOBAL_PROFILE" != "public" && "$GLOBAL_PROFILE" != "nat" ]]; then
        display_status_error "不支持的 profile: ${GLOBAL_PROFILE}。仅支持 public 或 nat。"
        exit 1
    fi

    display_status_success "已选择 profile: ${GLOBAL_PROFILE}"
}

detect_operating_system_environment() {
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
    if [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        if ! dnf repolist enabled | grep -q "epel"; then
            dnf install -y epel-release >/dev/null || true
        fi
        dnf makecache -y >/dev/null
    fi
}

install_packages() {
    if [ $# -eq 0 ]; then
        return 0
    fi

    if [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y "$@" >/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        dnf install -y "$@" >/dev/null
    fi
}

upgrade_system_packages() {
    display_status_info "正在同步软件源并升级系统组件..."
    run_package_update
    if [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get upgrade -y >/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        dnf update -y >/dev/null
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
    if [[ "$GLOBAL_PROFILE" == "nat" ]]; then
        if ((memory_total_mb < 1024)); then
            swap_target_size_mb=$((memory_total_mb * 2))
        else
            swap_target_size_mb=1024
        fi
    else
        if ((memory_total_mb < 1024)); then
            swap_target_size_mb=1024
        elif ((memory_total_mb < 2048)); then
            swap_target_size_mb="$memory_total_mb"
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
        fallocate -l "${swap_target_size_mb}M" /mnt/swap || true
    fi

    if [[ ! -f /mnt/swap ]]; then
        dd if=/dev/zero of=/mnt/swap bs=1M count="$swap_target_size_mb" status=none
    fi

    chmod 600 /mnt/swap

    if mkswap /mnt/swap >/dev/null 2>&1 && swapon /mnt/swap >/dev/null 2>&1; then
        if ! grep -q '/mnt/swap' /etc/fstab; then
            echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
        fi
        sed -i '/vm.swappiness/d' /etc/sysctl.conf
        echo "vm.swappiness = 10" >> /etc/sysctl.conf
        sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
        display_status_success "Swap 已挂载并激活，大小: ${swap_target_size_mb}MB。"
    else
        display_status_warning "当前虚拟化架构不支持自行挂载 Swap，已清理并跳过。"
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

    if [[ "$current_timezone" == "$GLOBAL_TIMEZONE" ]]; then
        display_status_success "时区已是 ${GLOBAL_TIMEZONE}。"
    else
        timedatectl set-timezone "$GLOBAL_TIMEZONE"
        display_status_success "系统时区已校准为 ${GLOBAL_TIMEZONE}。"
    fi
}

install_essential_utilities() {
    display_status_info "正在验证并安装必备运维工具箱..."

    local dependencies=("sudo" "curl" "jq" "wget" "unzip" "ca-certificates" "$GLOBAL_BIND_UTILS")
    if [[ "$GLOBAL_PROFILE" == "public" ]]; then
        dependencies+=("git" "vim" "net-tools")
    else
        dependencies+=("dkms")
    fi

    install_packages "${dependencies[@]}"
    display_status_success "运维工具箱安装校验完成。"
}

optimize_kernel_sysctl_network() {
    display_status_info "正在注入 ${GLOBAL_PROFILE} VPS 网络调优参数..."
    local sysctl_config_file="/etc/sysctl.d/99-vps-network.conf"

    if [[ "$GLOBAL_PROFILE" == "nat" ]]; then
        cat > "$sysctl_config_file" <<'EOF'
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
        cat > "$sysctl_config_file" <<'EOF'
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

    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true

    local active_congestion_algo
    active_congestion_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)

    if [[ "$active_congestion_algo" == "bbr" ]]; then
        display_status_success "网络调优已注入，BBR 已生效。"
    else
        display_status_warning "网络调优已注入，但当前内核或虚拟化环境未启用 BBR。"
    fi
}

prompt_yes_no() {
    local prompt_text=$1
    local default_answer=${2:-n}
    local reply=""

    if [ "$GLOBAL_ASSUME_YES" = true ]; then
        [[ "$default_answer" =~ ^[Yy]$ ]]
        return
    fi

    read -rp "$prompt_text" reply
    if [ -z "$reply" ]; then
        reply="$default_answer"
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

configure_public_optional_features() {
    if [[ "$GLOBAL_PROFILE" != "public" ]]; then
        return
    fi

    if [ "$GLOBAL_INSTALL_DOCKER" = false ] && prompt_yes_no "是否安装 Docker 运行时？[y/N] " "n"; then
        GLOBAL_INSTALL_DOCKER=true
    fi

    if [ "$GLOBAL_INSTALL_NODEJS" = false ] && prompt_yes_no "是否安装 Node.js/npm？[y/N] " "n"; then
        GLOBAL_INSTALL_NODEJS=true
    fi

    if [ "$GLOBAL_INSTALL_CLOUD_KERNEL" = false ] && prompt_yes_no "是否安装 Debian Cloud Kernel？[y/N] " "n"; then
        GLOBAL_INSTALL_CLOUD_KERNEL=true
    fi
}

install_docker_runtime() {
    if [ "$GLOBAL_INSTALL_DOCKER" = false ]; then
        return
    fi

    display_status_info "正在安装 Docker 运行时..."
    if command -v docker >/dev/null 2>&1; then
        display_status_success "Docker 已安装，跳过。"
        return
    fi

    if [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        install_packages docker.io docker-compose-plugin || install_packages docker.io docker-compose
    else
        install_packages docker || install_packages moby-engine
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^docker.service'; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    if command -v docker >/dev/null 2>&1; then
        display_status_success "Docker 安装完成。"
    else
        display_status_warning "Docker 安装未完成，请检查发行版软件源。"
    fi
}

install_nodejs_runtime() {
    if [ "$GLOBAL_INSTALL_NODEJS" = false ]; then
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
    if [ "$GLOBAL_INSTALL_CLOUD_KERNEL" = false ]; then
        return
    fi

    if [[ "$GLOBAL_PKG_MANAGER" != "apt-get" || "$GLOBAL_OS_ID" != "debian" ]]; then
        display_status_warning "Cloud Kernel 仅在 Debian apt 环境下自动安装，当前系统跳过。"
        return
    fi

    display_status_info "正在安装 Debian Cloud Kernel..."
    install_packages linux-image-cloud-amd64
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null
    fi
    display_status_success "Debian Cloud Kernel 安装流程完成，请在维护窗口重启后确认内核。"
}

validate_port_number() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

configure_ssh_port() {
    if [ -z "$GLOBAL_SSH_PORT" ]; then
        return
    fi

    if [[ "$GLOBAL_PROFILE" != "public" ]]; then
        display_status_warning "--ssh-port 仅适用于 public profile，当前跳过。"
        return
    fi

    if ! validate_port_number "$GLOBAL_SSH_PORT"; then
        display_status_error "SSH 端口不合法: ${GLOBAL_SSH_PORT}"
        exit 1
    fi

    local ssh_config_file="/etc/ssh/sshd_config"
    if [ ! -f "$ssh_config_file" ]; then
        display_status_warning "未找到 ${ssh_config_file}，跳过 SSH 端口修改。"
        return
    fi

    display_status_info "正在修改 SSH 端口为 ${GLOBAL_SSH_PORT}..."
    local backup_file="${ssh_config_file}.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$ssh_config_file" "$backup_file"

    if grep -qE '^[#[:space:]]*Port[[:space:]]+' "$ssh_config_file"; then
        sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${GLOBAL_SSH_PORT}/" "$ssh_config_file"
    else
        echo "Port ${GLOBAL_SSH_PORT}" >> "$ssh_config_file"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        ufw allow "${GLOBAL_SSH_PORT}"/tcp >/dev/null || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${GLOBAL_SSH_PORT}"/tcp >/dev/null || true
        firewall-cmd --reload >/dev/null || true
    else
        display_status_warning "未检测到活跃防火墙，未自动写入防火墙规则。请手动确认新 SSH 端口可达。"
    fi

    if ! sshd -t; then
        cp "$backup_file" "$ssh_config_file"
        display_status_error "SSH 配置语法检查失败，已恢复备份。"
        exit 1
    fi

    local ssh_service_name="sshd"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^ssh.service'; then
        ssh_service_name="ssh"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl restart "$ssh_service_name"; then
            cp "$backup_file" "$ssh_config_file"
            systemctl restart "$ssh_service_name" || true
            display_status_error "SSH 服务重启失败，已尝试恢复备份。"
            exit 1
        fi
    else
        service "$ssh_service_name" restart
    fi

    display_status_success "SSH 端口已更新为 ${GLOBAL_SSH_PORT}。请保持当前会话，确认新端口可登录后再断开。"
}

remove_orphaned_packages() {
    display_status_info "正在清理孤立依赖以释放磁盘空间..."
    if [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get autoremove -y >/dev/null
        apt-get clean >/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        dnf autoremove -y >/dev/null || true
    fi
    display_status_success "系统垃圾清理完成。"
}

confirm_reboot() {
    echo ""
    if prompt_yes_no "是否立即重启系统以全面应用内核变更？[y/N] " "n"; then
        display_status_info "系统将在 5 秒后执行重启指令..."
        sleep 5
        reboot
    else
        display_status_warning "请在合适的维护窗口手动重启系统。"
    fi
}

execute_main_lifecycle() {
    clear || true
    display_status_info "=== VPS 初始化与优化总线启动 ==="

    validate_root_privilege
    select_vps_profile
    detect_operating_system_environment
    configure_public_optional_features
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

parse_arguments "$@"
execute_main_lifecycle
