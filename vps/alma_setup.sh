#!/bin/bash

# 更新软件包
dnf update -y

# 安装并启动 tuned
dnf install -y tuned
systemctl enable --now tuned

# 修改时区为上海
timedatectl set-timezone Asia/Shanghai

# 修改 SSH 端口
sed -i 's/#Port 22/Port 9399/' /etc/ssh/sshd_config
systemctl restart sshd

# 运行 NextTrace 安装脚本
curl -Ls https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh -o /tmp/nt_install.sh
bash /tmp/nt_install.sh
rm /tmp/nt_install.sh

# 设置 BBR+FQ
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 安装 dnsutils
dnf install -y bind-utils

echo "所有任务完成！"
