#!/usr/bin/env bash

# ==============================================================================
# 脚本意图: NAT VPS 专属系统初始化与轻量级网络协议栈调优
# 命名规范: 意图导向命名法 (动词+核心名词)
# ==============================================================================

# 定义全局界面输出样式
readonly COLOR_TEXT_RED='\033[0;31m'
readonly COLOR_TEXT_GREEN='\033[0;32m'
readonly COLOR_TEXT_YELLOW='\033[1;33m'
readonly COLOR_TEXT_BLUE='\033[1;34m'
readonly FORMAT_TEXT_BOLD='\033[1m'
readonly STYLE_RESET='\033[0m'

# 核心状态输出函数 (UI保持中文)
display_status_info() { echo -e "${COLOR_TEXT_BLUE}${FORMAT_TEXT_BOLD}[信息] $1${STYLE_RESET}"; }
display_status_success() { echo -e "${COLOR_TEXT_GREEN}${FORMAT_TEXT_BOLD}[成功] $1${STYLE_RESET}"; }
display_status_warning() { echo -e "${COLOR_TEXT_YELLOW}${FORMAT_TEXT_BOLD}[警告] $1${STYLE_RESET}"; }
display_status_error() { echo -e "${COLOR_TEXT_RED}${FORMAT_TEXT_BOLD}[错误] $1${STYLE_RESET}"; }

# ------------------------------------------------------------------------------
# 模块: 基础环境校验
# ------------------------------------------------------------------------------
validate_root_privilege() {
    display_status_info "正在校验 root 权限..."
    if [[ $EUID -ne 0 ]]; then
       display_status_error "权限不足：请以 root 身份或使用 sudo 执行此脚本。"
       exit 1
    fi
    display_status_success "root 权限校验通过。"
}

detect_operating_system_environment() {
    display_status_info "正在探测操作系统架构与包管理器..."
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        local_os_name=$NAME
        local_os_version=$VERSION_ID
        display_status_success "识别到系统: $local_os_name (版本: $local_os_version)"
    else
        display_status_error "无法探测操作系统类型，文件 /etc/os-release 缺失。"
        exit 1
    fi

    # 确定包管理器并赋值给全局变量
    if command -v apt-get &> /dev/null; then
        GLOBAL_PKG_MANAGER="apt-get"
        GLOBAL_BIND_UTILS="dnsutils"
    elif command -v dnf &> /dev/null; then
        GLOBAL_PKG_MANAGER="dnf"
        GLOBAL_BIND_UTILS="bind-utils"
    else
        display_status_error "不支持当前系统的包管理器，仅支持 apt 或 dnf。"
        exit 1
    fi
    display_status_success "已绑定主包管理器: $GLOBAL_PKG_MANAGER"
}

# ------------------------------------------------------------------------------
# 模块: 核心资源与系统配置
# ------------------------------------------------------------------------------
configure_virtual_memory_swap() {
    display_status_info "正在配置虚拟内存 (Swap)..."
    if [[ -f /mnt/swap ]]; then
        display_status_warning "交换文件 /mnt/swap 已存在，跳过创建以保护磁盘寿命。"
        return
    fi

    local memory_total_mb
    memory_total_mb=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    
    # NAT VPS 策略：若物理内存小于 1024MB，则分配 2 倍物理内存；否则分配 1024MB
    local swap_target_size_mb
    if (( memory_total_mb < 1024 )); then
        swap_target_size_mb=$((memory_total_mb * 2))
    else
        swap_target_size_mb=1024
    fi

    # LXC 虚拟化环境通常不支持创建 Loop 设备或 Swap，增加容错拦截
    dd if=/dev/zero of=/mnt/swap bs=1M count="$swap_target_size_mb" status=none
    chmod 600 /mnt/swap
    
    if mkswap /mnt/swap &>/dev/null && swapon /mnt/swap &>/dev/null; then
        if ! grep -q '/mnt/swap' /etc/fstab; then
            echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
        fi
        # 降低对 Swap 的依赖倾向，保护廉价 IO 性能
        sed -i '/vm.swappiness/d' /etc/sysctl.conf
        echo "vm.swappiness = 10" >> /etc/sysctl.conf
        sysctl -w vm.swappiness=10 &>/dev/null
        display_status_success "虚拟内存 (大小: ${swap_target_size_mb}MB) 挂载并激活成功。"
    else
        display_status_warning "当前虚拟化架构（如 LXC）不支持自行挂载 Swap，已自动清理并跳过该步骤。"
        rm -f /mnt/swap
    fi
}

calibrate_system_timezone() {
    display_status_info "正在校准系统时区为 Asia/Singapore..."
    local current_timezone
    current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    
    if [[ "$current_timezone" == "Asia/Singapore" ]]; then
        display_status_success "时区校验一致，当前已是 Asia/Singapore。"
    else
        timedatectl set-timezone Asia/Singapore
        display_status_success "系统时区已成功校准为: Asia/Singapore"
    fi
}

# ------------------------------------------------------------------------------
# 模块: 依赖包管理与更新
# ------------------------------------------------------------------------------
upgrade_system_packages() {
    display_status_info "正在同步软件源并升级系统组件..."
    if [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        # CentOS/AlmaLinux 预置 EPEL
        if ! dnf repolist enabled | grep -q "epel"; then
            dnf install -y epel-release &>/dev/null
        fi
        dnf update -y &>/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update &>/dev/null && apt-get upgrade -y &>/dev/null
    fi
    display_status_success "系统组件升级完毕。"
}

install_essential_utilities() {
    display_status_info "正在验证并安装必备运维工具箱..."
    
    # 修复此前关联数组带来的兼容性隐患，改用基础数组进行遍历
    local array_system_dependencies=(
        "sudo" "curl" "jq" "wget" "unzip" "dkms" "$GLOBAL_BIND_UTILS"
    )

    for package_name in "${array_system_dependencies[@]}"; do
        # 针对 dnsutils/bind-utils 统一检测 nslookup 二进制文件
        if [[ "$package_name" == "$GLOBAL_BIND_UTILS" ]]; then
            if ! command -v nslookup &> /dev/null; then
                $GLOBAL_PKG_MANAGER install -y "$package_name" &>/dev/null
            fi
        else
            if ! command -v "$package_name" &> /dev/null; then
                $GLOBAL_PKG_MANAGER install -y "$package_name" &>/dev/null
            fi
        fi
    done
    display_status_success "运维工具箱安装校验完成。"
}

# ------------------------------------------------------------------------------
# 模块: 纯静态网络协议栈调优 (替代 Tuned 以节省内存)
# ------------------------------------------------------------------------------
optimize_kernel_sysctl_network() {
    display_status_info "正在注入 NAT VPS 专属底层网络调优参数..."
    local sysctl_config_file="/etc/sysctl.d/99-nat-vps-network.conf"

    # 构建并写入针对高并发、短连接优化的内核参数
    cat > "$sysctl_config_file" <<EOF
# 提升网络吞吐量，使用 BBR 拥塞控制与 FQ 队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# NAT 穿透保护：仅作为客户端开启 TCP Fast Open，避免严格 NAT 下丢包
net.ipv4.tcp_fastopen = 1

# 释放并扩大本地临时端口范围 (应对大量并发外部请求)
net.ipv4.ip_local_port_range = 10240 65535

# 开启 TCP 连接复用，快速回收 TIME_WAIT 状态套接字
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 提升连接追踪表容量 (防止 NAT 下 Conntrack Table Full)
net.netfilter.nf_conntrack_max = 262144
EOF

    # 尝试加载 BBR 模块 (针对 KVM/XEN)，并重载配置
    modprobe tcp_bbr &>/dev/null || true
    sysctl --system &>/dev/null

    # 验证 BBR 是否成功生效 (兼容 LXC 等无法修改拥塞算法的环境)
    local active_congestion_algo
    active_congestion_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$active_congestion_algo" == "bbr" ]]; then
        display_status_success "静态网络调优注入成功，BBR 引擎已挂载。"
    else
        display_status_warning "静态网络调优已注入。但当前内核/虚拟化限制了 BBR 引擎的挂载 (常见于 LXC 环境)。"
    fi
}

remove_orphaned_packages() {
    display_status_info "正在清理孤立依赖以释放磁盘空间..."
    if [[ "$GLOBAL_PKG_MANAGER" == "dnf" ]]; then
        dnf autoremove -y &>/dev/null
    elif [[ "$GLOBAL_PKG_MANAGER" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get autoremove -y &>/dev/null
        apt-get clean &>/dev/null
    fi
    display_status_success "系统垃圾清理完成。"
}

# ------------------------------------------------------------------------------
# 模块: 主生命周期总线
# ------------------------------------------------------------------------------
execute_main_lifecycle() {
    clear
    display_status_info "=== NAT VPS 初始化与优化总线启动 ==="
    
    validate_root_privilege
    detect_operating_system_environment
    configure_virtual_memory_swap
    calibrate_system_timezone
    upgrade_system_packages
    install_essential_utilities
    optimize_kernel_sysctl_network
    remove_orphaned_packages

    display_status_success "所有系统初始化与网络优化任务编排执行完毕！"
    echo ""
    
    # 交互式重启确认 (UI保持中文)
    read -p "是否立即重启系统以全面应用内核更改？[Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        display_status_info "系统将在 5 秒后执行重启指令..."
        sleep 5
        reboot
    else
        display_status_warning "请务必在合适的窗口期手动重启系统，以确保网络堆栈变更生效。"
    fi
}

# 挂载入口执行
execute_main_lifecycle
