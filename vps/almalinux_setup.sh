#!/bin/bash

# 定义颜色和样式
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 打印显著的提示信息函数
print_info() {
    echo -e "${BLUE}${BOLD}$1${NC}"
}

print_success() {
    echo -e "${GREEN}${BOLD}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}$1${NC}"
}

print_error() {
    echo -e "${RED}${BOLD}$1${NC}"
}

# 检查是否具有sudo权限
if [[ $EUID -ne 0 ]]; then
   print_error "请以 root 身份或使用 sudo 执行此脚本。"
   exit 1
fi

# 检测系统类型和包管理器
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
else
    print_error "无法检测操作系统类型。"
    exit 1
fi

case $OS in
    "CentOS Linux"|"AlmaLinux")
        PKG_MANAGER="dnf"
        ;;
    "Ubuntu"|"Debian GNU/Linux")
        PKG_MANAGER="apt"
        ;;
    *)
        print_error "不支持的操作系统: $OS"
        exit 1
        ;;
esac

# 检测并安装所需的指令
check_and_install() {
    if ! command -v $1 &> /dev/null; then
        print_info "$1 未安装，正在安装..."
        $PKG_MANAGER install -y $1
        if [ $? -ne 0 ]; then
            print_error "$1 安装失败。"
            exit 1
        fi
    else
        print_success "$1 已安装，跳过安装。"
    fi
}

# 创建并启用交换空间
setup_swap() {
    if [ -f /mnt/swap ]; then
        print_warning "交换文件已存在，跳过创建。"
        return
    fi

    MEM_SIZE_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    SWAP_SIZE_MB=$((MEM_SIZE_MB < 1024 ? 1024 : MEM_SIZE_MB))

    if [ ! -d /mnt ]; then
        print_error "/mnt 目录不存在，请检查挂载点。"
        exit 1
    fi

    if [ $(df -m /mnt | tail -1 | awk '{print $4}') -lt $SWAP_SIZE_MB ]; then
        print_error "/mnt 没有足够的空间创建交换文件。"
        exit 1
    fi

    dd if=/dev/zero of=/mnt/swap bs=1M count=$SWAP_SIZE_MB
    chmod 600 /mnt/swap
    mkswap /mnt/swap
    swapon /mnt/swap

    if ! grep -q '/mnt/swap' /etc/fstab; then
        echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
        print_success "交换文件已添加到 /etc/fstab。"
    fi

    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    echo "vm.swappiness = 25" >> /etc/sysctl.conf
    sysctl -w vm.swappiness=25
    swapon -a
    swapon --show

    if [ $? -eq 0 ]; then
        print_success "交换空间已成功启用。"
    else
        print_error "交换空间启用失败。"
        exit 1
    fi
}

# 修改时区为新加坡
set_timezone() {
    current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$current_timezone" == "Asia/Singapore" ]; then
        print_success "当前系统时区已经是 Asia/Singapore，跳过时区设置。"
    else
        print_info "设置系统时区为 Asia/Singapore..."
        timedatectl set-timezone Asia/Singapore
        new_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
        print_success "当前系统时区已设置为: $new_timezone"
    fi
}

# 检查系统负载
check_system_load() {
    while [ $(awk '{print $1}' /proc/loadavg) > 1 ]; do
        print_warning "系统负载过高，等待中..."
        sleep 5
    done
}

# 更新系统
update_system() {
    print_info "更新系统中..."
    if [ "$PKG_MANAGER" == "dnf" ]; then
        dnf update -y
    elif [ "$PKG_MANAGER" == "apt" ]; then
        apt update && apt upgrade -y
    fi
    if [ $? -eq 0 ]; then
        print_success "系统更新完成。"
    else
        print_error "系统更新失败。"
        exit 1
    fi
}

# 安装 EPEL 仓库（仅适用于 CentOS/RHEL/AlmaLinux）
install_epel() {
    if [ "$PKG_MANAGER" == "dnf" ]; then
        if ! dnf repolist enabled | grep -q "epel"; then
            print_info "安装 EPEL 仓库..."
            dnf install -y epel-release
            if [ $? -eq 0 ]; then
                print_success "EPEL 仓库安装成功。"
            else
                print_error "EPEL 仓库安装失败。"
                exit 1
            fi
        else
            print_success "EPEL 仓库已经安装。"
        fi
    fi
}

# 安装必要的工具
install_tools() {
    tools=("jq" "wget" "unzip" "bind-utils" "dkms")
    for tool in "${tools[@]}"; do
        check_and_install $tool
    done
}

# 开启 TCP Fast Open (TFO)
enable_tfo() {
    print_info "开启 TCP Fast Open (TFO)..."
    echo "3" > /proc/sys/net/ipv4/tcp_fastopen
    echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
    sysctl --system
}

# 设置 BBR+FQ
setup_bbr() {
    current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

    if [ "$current_algo" == "bbr" ]; then
        print_success "当前系统已使用 BBR 算法。"
    else
        print_info "当前系统未使用 BBR 算法，正在设置 BBR..."

        # 检查内核版本是否支持 BBR
        if ! modprobe tcp_bbr &> /dev/null; then
            print_error "当前内核不支持 BBR，请升级内核后再试。"
            exit 1
        fi

        sysctl -w net.core.default_qdisc=fq
        sysctl -w net.ipv4.tcp_congestion_control=bbr

        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        fi
        if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        fi

        print_success "BBR 设置完成。"
    fi

    final_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$final_algo" == "bbr" ]; then
        print_success "BBR 已成功启用。"
    else
        print_error "BBR 启用失败，请检查配置。"
        exit 1
    fi
}

# 设置网络性能优化
setup_network_performance() {
    print_info "设置网络性能优化配置..."
    check_and_install tuned
    systemctl enable tuned.service
    systemctl start tuned.service
    tuned-adm profile network-throughput

    if systemctl is-active --quiet tuned.service; then
        print_success "tuned 服务已成功启动。"
    else
        print_error "tuned 服务未启动，请检查日志进行排查。"
        exit 1
    fi

    active_profile=$(tuned-adm active)
    if [[ "$active_profile" == *"network-throughput"* ]]; then
        print_success "网络吞吐量优化配置已成功应用。"
    else
        print_error "未能应用网络吞吐量优化配置。"
        exit 1
    fi
}

# 安装 Docker
install_docker() {
    print_info "安装 Docker..."
    if [ "$PKG_MANAGER" == "dnf" ]; then
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif [ "$PKG_MANAGER" == "apt" ]; then
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    systemctl start docker
    systemctl enable docker
    docker --version
}

# 安装 Node.js LTS 版本
install_nodejs() {
    print_info "安装 Node.js LTS 版本..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    $PKG_MANAGER install -y nodejs
    node -v
    npm -v
}

# 安装路由测试工具
install_nexttrace() {
    print_info "安装路由测试工具 nexttrace..."
    bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"
}

# 修改 SSH 端口
change_ssh_port() {
    print_info "修改 SSH 端口为 9399..."
    sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
    
    # 配置防火墙（假设使用 firewalld）
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=9399/tcp
        firewall-cmd --reload
    fi

    systemctl restart sshd
    if [ $? -ne 0 ]; then
        print_error "SSH 服务重启失败，请检查配置。"
        exit 1
    fi
    print_success "SSH 端口已更改为 9399。请确保使用新端口进行连接。"
}

# 清理不需要的包
clean_system() {
    print_info "清理系统..."
    if [ "$PKG_MANAGER" == "dnf" ]; then
        dnf autoremove -y
    elif [ "$PKG_MANAGER" == "apt" ]; then
        apt autoremove -y
    fi

    if [ $? -eq 0 ]; then
        print_success "系统清理完成，不需要的包已移除。"
    else
        print_error "系统清理失败，请检查错误信息。"
        exit 1
    fi
}

# 主函数
main() {
    print_info "开始系统优化和配置..."

    setup_swap
    set_timezone
    check_system_load
    update_system
    install_epel
    install_tools
    enable_tfo
    setup_bbr
    setup_network_performance
    install_docker
    install_nodejs
    install_nexttrace
    change_ssh_port
    clean_system

    print_success "所有任务完成！"

    read -p "是否现在重启系统？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "系统将在 10 秒后重启..."
        sleep 10
        reboot
    else
        print_info "请记得稍后手动重启系统以应用所有更改。"
    fi
}

# 执行主函数
main
