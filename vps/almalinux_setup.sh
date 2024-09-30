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
        dnf install -y $1
        if [ $? -ne 0 ];then
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
dd if=/dev/zero of=/mnt/swap bs=1M count=$SWAP_SIZE_MB
chmod 600 /mnt/swap
mkswap /mnt/swap
swapon /mnt/swap
if ! grep -q '/mnt/swap' /etc/fstab; then
    echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
    print_success "交换文件已添加到 /etc/fstab。"
else
    print_success "交换文件已存在于 /etc/fstab。"
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

# 修改时区为新加坡
current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [ "$current_timezone" == "Asia/Singapore" ]; then
    print_success "当前系统时区已经是 Asia/Singapore，跳过时区设置。"
else
    print_info "设置系统时区为 Asia/Singapore..."
    sudo timedatectl set-timezone Asia/Singapore
    new_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    print_success "当前系统时区已设置为: $new_timezone"
fi

# 检查系统负载
while [ $(uptime | awk '{print $10}' | cut -d',' -f1) -gt 1 ]; do
    print_warning "系统负载过高，等待中..."
    sleep 5
done

# 更新系统
print_info "终止可能阻塞的进程..."
dnf ps -q | awk '{print $1}' | xargs -r kill -9

print_info "更新系统..."
dnf update --refresh -y
if [ $? -ne 0 ]; then
    print_error "系统更新失败。"
    exit 1
else
    print_success "系统更新成功。"
fi

# 检查 EPEL 仓库是否已启用
if dnf repolist enabled | grep -q "epel"; then
    print_success "EPEL 仓库已经启用。"
else
    print_info "EPEL 仓库未启用，正在安装并启用..."
    sudo dnf install -y epel-release
    if [ $? -eq 0 ]; then
        print_success "EPEL 仓库已成功启用。"
    else
        print_error "EPEL 仓库启用失败，请手动检查问题。"
        exit 1
    fi
fi

# 检查是否安装成功并启用
if dnf repolist enabled | grep -q "epel"; then
    print_success "EPEL 仓库确认已启用。"
else
    print_error "EPEL 仓库仍未启用，请检查网络或仓库配置。"
    exit 1
fi

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install unzip
check_and_install bind-utils
check_and_install dkms

# 开启 TCP Fast Open (TFO)
print_info "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 设置 BBR+FQ

# 检查当前的 TCP 拥塞控制算法
current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

if [ "$current_algo" == "bbr" ]; then
    print_success "当前系统已使用 BBR 算法。"
else
    print_info "当前系统未使用 BBR 算法，正在设置 BBR..."

    # 检查是否加载了 BBR 模块
    if lsmod | grep -q "tcp_bbr"; then
        print_success "BBR 模块已加载。"
    else
        print_info "BBR 模块未加载，正在加载..."
        modprobe tcp_bbr
        if [ $? -ne 0 ]; then
            print_error "加载 BBR 模块失败。"
            exit 1
        fi
        print_success "BBR 模块加载成功。"
    fi

    # 将 BBR 添加到 TCP 拥塞控制列表
    print_info "设置 TCP 拥塞控制为 BBR..."
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr

    # 确保设置在重启后仍然有效
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    print_success "BBR 设置完成。"
fi

# 再次确认 BBR 是否已启用
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

# 安装 Docker
print_info "安装 Docker..."
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo systemctl enable docker
docker --version

# 安装 Node.js 19.x
print_info "安装 Node.js 19.x..."
sudo dnf install -y epel-release
curl -fsSL https://rpm.nodesource.com/setup_19.x | sudo bash -
sudo dnf install -y nodejs
node -v
npm -v

# 安装路由测试工具
print_info "安装路由测试工具 nexttrace..."
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 修改 SSH 端口为 9399
print_info "修改 SSH 端口为 9399..."
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd
if [ $? -ne 0 ]; then
    print_error "SSH 服务重启失败，请检查配置。"
    exit 1
fi

# 清理不需要的包
sudo dnf autoremove -y
if [ $? -eq 0 ]; then
    print_success "系统清理完成，不需要的包已移除。"
else
    print_error "系统清理失败，请检查错误信息。"
    exit 1
fi

print_success "所有任务完成！"

print_info "重启..."
reboot
