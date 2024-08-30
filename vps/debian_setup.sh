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
        apt-get install -y $1
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
apt-get update -o Acquire::ForceIPv4=true && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    echo "系统更新失败。"
    exit 1
else
    echo "系统更新成功。"
fi

# 修改时区为新加坡
sudo timedatectl set-timezone Asia/Singapore
current_timezone=$(timedatectl | grep "Time zone")
echo "当前系统时区已设置为: $current_timezone"

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install unzip
check_and_install dnsutils
check_and_install dkms

# 创建 /root/kernel 目录并进入
echo "创建 /root/kernel 目录并进入..."
mkdir -p /root/kernel && cd /root/kernel

# 下载和安装内核包
echo "下载内核包..."
KERNEL_URLS=$(wget -q -O - https://api.github.com/repos/love4taylor/linux-self-use-deb/releases/latest | \
    jq -r '.assets[] | select(.name | contains ("deb")) | select(.name | contains ("cloud")) | .browser_download_url')
if [ -z "$KERNEL_URLS" ]; then
    echo "未找到内核包下载链接，退出。"
    exit 1
fi

for url in $KERNEL_URLS; do
    wget -q --show-progress $url
done

# 安装内核包
echo "安装内核包..."
dpkg -i linux-headers-*-egoist-cloud_*.deb
dpkg -i linux-image-*-egoist-cloud_*.deb

# 清理下载的deb包
rm -f *.deb

# 创建并启用交换空间
MEM_SIZE_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_SIZE_MB" -le 1024 ]; then
    SWAP_SIZE_MB=1024  # 设置为1GB
else
    SWAP_SIZE_MB=$((MEM_SIZE_MB * 2))  # 否则设置为物理内存的两倍
fi
sudo dd if=/dev/zero of=/mnt/swap bs=1M count=$SWAP_SIZE_MB
sudo chmod 600 /mnt/swap
sudo mkswap /mnt/swap
sudo swapon /mnt/swap
if ! grep -q '/mnt/swap' /etc/fstab; then
    echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
    echo "交换文件已添加到 /etc/fstab。"
else
    echo "交换文件已存在于 /etc/fstab。"
fi
sudo sed -i '/vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 25" | sudo tee -a /etc/sysctl.conf
sudo sysctl -w vm.swappiness=25
swapon -a
swapon --show
if [ $? -eq 0 ]; then
    echo "交换空间已成功启用。"
else
    echo "交换空间启用失败。"
    exit 1
fi

# 开启 TCP Fast Open (TFO)
echo "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 设置 bbrv3
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 查看当前的TCP流控算法
sysctl net.ipv4.tcp_congestion_control

# 开启 tuned 并设置网络性能优化配置
echo "开启 tuned 并设置网络性能优化配置..."
check_and_install tuned
systemctl enable tuned.service
systemctl start tuned.service
tuned-adm profile network-throughput

# 卸载 tcp-brutal 模块
dkms uninstall tcp-brutal/1.0.1 --all && dkms remove tcp-brutal/1.0.1 --all

# 检查 dkms 状态
dkms status

# 安装 Docker
echo "安装 Docker..."
curl -fSL https://get.docker.com | bash -s docker

# 安装 Node.js 19.x
echo "安装 Node.js 19.x..."
curl -fsSL https://deb.nodesource.com/setup_19.x | bash -
apt-get install -y nodejs
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
apt-get autoremove -y

echo "所有步骤完成！"
