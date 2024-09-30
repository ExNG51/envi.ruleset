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

# 检测并安装所需的指令
check_and_install() {
    if ! command -v $1 &> /dev/null; then
        print_info "$1 未安装，正在安装..."
        apt-get install -y $1
        if [ $? -ne 0 ]; then
            print_error "$1 安装失败。"
            exit 1
        fi
    else
        print_success "$1 已安装，跳过安装。"
    fi
}

# 创建并启用交换空间
MEM_SIZE_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_SIZE_MB" -le 1024 ]; then
    SWAP_SIZE_MB=1024  # 设置为1GB
else
    SWAP_SIZE_MB=$((MEM_SIZE_MB))  # 否则设置为物理内存的数值
fi
sudo dd if=/dev/zero of=/mnt/swap bs=1M count=$SWAP_SIZE_MB
sudo chmod 600 /mnt/swap
sudo mkswap /mnt/swap
sudo swapon /mnt/swap
if ! grep -q '/mnt/swap' /etc/fstab; then
    echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
    print_success "交换文件已添加到 /etc/fstab。"
else
    print_success "交换文件已存在于 /etc/fstab。"
fi
sudo sed -i '/vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 25" | sudo tee -a /etc/sysctl.conf
sudo sysctl -w vm.swappiness=25
swapon -a
swapon --show
if [ $? -eq 0 ]; then
    print_success "交换空间已成功启用。"
else
    print_error "交换空间启用失败。"
    exit 1
fi

# 修改时区为新加坡
sudo timedatectl set-timezone Asia/Singapore
current_timezone=$(timedatectl | grep "Time zone")
print_success "当前系统时区已设置为: $current_timezone"

# 检查系统负载
while [ $(uptime | awk -F 'load average: ' '{print $2}' | cut -d',' -f1 | xargs) -gt 1 ]; do
    print_warning "系统负载过高，等待中..."
    sleep 5
done

# 更新核心包
print_info "更新系统核心包..."
sudo apt update && sudo apt upgrade -y linux-image-$(uname -r)
if [ $? -ne 0 ]; then
    print_error "系统核心包更新失败。"
    exit 1
else
    print_success "系统核心包更新成功。"
fi

# 更新系统
print_info "更新系统..."
apt-get update -o Acquire::ForceIPv4=true && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    print_error "系统更新失败。"
    exit 1
else
    print_success "系统更新成功。"
fi

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install unzip
check_and_install dnsutils
check_and_install dkms

# 安装 Cloud 内核
print_info "安装 Cloud 内核..."
apt-cache search linux-image-cloud
sudo apt-get install linux-image-cloud-amd64 -y
sudo update-grub

# 开启 TCP Fast Open (TFO)
print_info "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 设置 BBRv3
print_info "设置 BBRv3..."
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 查看当前的TCP流控算法
final_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$final_algo" == "bbr" ]; then
    print_success "BBR 已成功启用。"
else
    print_error "BBR 启用失败，请检查配置。"
    exit 1
fi

# 开启 tuned 并设置网络性能优化配置
print_info "开启 tuned 并设置网络性能优化配置..."
check_and_install tuned
systemctl enable tuned.service
systemctl start tuned.service
tuned-adm profile network-throughput
# 验证 tuned 服务状态
print_info "检查 tuned 服务状态..."
if systemctl status tuned.service | grep -q "active (running)"; then
    print_success "tuned 服务已成功启动。"
else
    print_error "tuned 服务未启动，请检查日志进行排查。"
    exit 1
fi
# 验证配置是否应用
print_info "验证 tuned 配置..."
active_profile=$(tuned-adm active)
if [[ "$active_profile" == *"network-throughput"* ]]; then
    print_success "网络吞吐量优化配置已成功应用。"
else
    print_error "未能应用网络吞吐量优化配置。"
    exit 1
fi

# 卸载 tcp-brutal 模块
if dkms status | grep -q "tcp-brutal"; then
    print_info "卸载 tcp-brutal 模块..."
    dkms uninstall tcp-brutal/1.0.1 --all && dkms remove tcp-brutal/1.0.1 --all
else
    print_success "tcp-brutal 模块未安装，跳过卸载。"
fi

# 检查 dkms 状态
dkms status

# 清理不需要的包
sudo apt-get autoremove -y
if [ $? -eq 0 ]; then
    print_success "系统清理完成，不需要的包已移除。"
else
    print_error "系统清理失败，请检查错误信息。"
    exit 1
fi

print_success "所有步骤完成！"

print_info "重启..."
reboot
