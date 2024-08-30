#!/bin/bash

# 检查是否具有sudo权限
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 身份或使用 sudo 执行此脚本。" 
   exit 1
fi

# 检测并安装所需的指令
check_and_install() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 未安装，正在安装..."
        dnf install -y $1
        if [ $? -ne 0 ]; then
            echo "$1 安装失败。"
            exit 1
        fi
    else
        echo "$1 已安装，跳过安装。"
    fi
}

# 更新系统
echo "更新系统..."
dnf update -y
if [ $? -ne 0 ]; then
    echo "系统更新失败。"
    exit 1
fi

# 修改时区为新加坡
sudo timedatectl set-timezone Asia/Singapore

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install unzip
check_and_install bind-utils
check_and_install dkms

# 创建并启用交换空间
MEM_SIZE_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_SIZE_MB" -le 1024 ]; then
    SWAP_SIZE_MB=1024  # 设置为1GB
else
    SWAP_SIZE_MB=$((MEM_SIZE_MB * 2))  # 否则设置为物理内存的两倍
fi
dd if=/dev/zero of=/mnt/swap bs=1M count=$SWAP_SIZE_MB
chmod 600 /mnt/swap
mkswap /mnt/swap
echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
sed -i '/vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 25" >> /etc/sysctl.conf
sysctl -w vm.swappiness=25
swapon -a

# 开启 TCP Fast Open (TFO)
echo "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 设置 BBR+FQ

# 检查当前的 TCP 拥塞控制算法
current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

if [ "$current_algo" == "bbr" ]; then
    echo "当前系统已使用 BBR 算法。"
else
    echo "当前系统未使用 BBR 算法，正在设置 BBR..."

    # 检查是否加载了 BBR 模块
    if lsmod | grep -q "tcp_bbr"; then
        echo "BBR 模块已加载。"
    else
        echo "BBR 模块未加载，正在加载..."
        modprobe tcp_bbr
        if [ $? -ne 0 ]; then
            echo "加载 BBR 模块失败。"
            exit 1
        fi
        echo "BBR 模块加载成功。"
    fi

    # 将 BBR 添加到 TCP 拥塞控制列表
    echo "设置 TCP 拥塞控制为 BBR..."
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr

    # 确保设置在重启后仍然有效
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    echo "BBR 设置完成。"
fi

# 再次确认 BBR 是否已启用
final_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

if [ "$final_algo" == "bbr" ]; then
    echo "BBR 已成功启用。"
else
    echo "BBR 启用失败，请检查配置。"
    exit 1
fi

# 开启 tuned 并设置网络性能优化配置
echo "开启 tuned 并设置网络性能优化配置..."
check_and_install tuned
systemctl enable tuned.service
systemctl start tuned.service
tuned-adm profile network-throughput

# 安装 Docker
echo "安装 Docker..."
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo systemctl enable docker
docker --version

# 安装 Node.js 19.x
echo "安装 Node.js 19.x..."
sudo dnf install -y epel-release
curl -fsSL https://rpm.nodesource.com/setup_19.x | sudo bash -
sudo dnf install -y nodejs
node -v
npm -v

# 安装路由测试工具
echo "安装路由测试工具 nexttrace..."
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 修改 SSH 端口为 9399
echo "修改 SSH 端口为 9399..."
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd
if [ $? -ne 0 ]; then
    echo "SSH 服务重启失败，请检查配置。"
    exit 1
fi

# 清理不需要的包
sudo dnf autoremove -y

echo "所有任务完成！"
