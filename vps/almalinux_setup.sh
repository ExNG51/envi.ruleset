#!/bin/bash

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

# 更新软件包
dnf update -y || { echo "dnf update failed"; exit 1; }

# 安装 wget 及 unzip
sudo dnf install wget unzip -y

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai || { echo "Failed to set timezone"; exit 1; }

# 修改 SSH 端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config || { echo "Failed to modify SSH port"; exit 1; }
systemctl restart sshd || { echo "Failed to restart SSHD"; exit 1; }

# 运行 NextTrace 安装脚本
curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh -o /tmp/nt_install.sh || { echo "Failed to download NextTrace script"; exit 1; }
bash /tmp/nt_install.sh || { echo "NextTrace installation failed"; exit 1; }
rm /tmp/nt_install.sh

# 设置 BBR+FQ
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p || { echo "Failed to apply sysctl changes"; exit 1; }

# 安装 dnsutils
dnf install -y bind-utils || { echo "Failed to install bind-utils"; exit 1; }

echo "所有任务完成！"
