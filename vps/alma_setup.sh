#!/bin/bash

# 更新软件包
dnf update -y

# 开启swap增加交换空间
dd if=/dev/zero of=/mnt/swap bs=1M count=`awk '($1 == "MemTotal:"){print int($2/1024*2)}' /proc/meminfo`
chmod 600 /mnt/swap
mkswap /mnt/swap
echo "/mnt/swap swap swap defaults 0 0" >> /etc/fstab
sed -i '/vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 25" >> /etc/sysctl.conf
sysctl -w vm.swappiness=25
swapon -a

# 安装tuned
dnf install tuned -y && systemctl enable --now tuned

# 安装Docker和Docker Compose
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 安装Node.js和npm
curl -fsSL https://rpm.nodesource.com/setup_19.x | sudo bash -
sudo dnf install -y nodejs

# 安装python
curl https://mise.run | sh
mise use -g python@3.10

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai

# 修改SSH端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd

# 运行NextTrace安装脚本
bash -c "$(curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh)"

# 设置BBR+FQ
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 安装dnsutils
dnf install -y bind-utils

echo "所有任务完成！"
