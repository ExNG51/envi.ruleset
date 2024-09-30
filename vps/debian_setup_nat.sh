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

# 修改时区为新加坡
sudo timedatectl set-timezone Asia/Singapore
current_timezone=$(timedatectl | grep "Time zone")
echo "当前系统时区已设置为: $current_timezone"

# 检查系统负载
while [ $(uptime | awk -F 'load average: ' '{print $2}' | cut -d',' -f1 | xargs) -gt 1 ]; do
    echo "系统负载过高，等待中..."
    sleep 5
done

# 更新核心包
echo "更新系统核心包..."
sudo apt update && sudo apt upgrade -y linux-image-$(uname -r)
if [ $? -ne 0 ]; then
    echo "系统核心包更新失败。"
    exit 1
else
    echo "系统核心包更新成功。"
fi

# 更新系统
echo "更新系统..."
apt-get update -o Acquire::ForceIPv4=true && apt-get full-upgrade -y
if [ $? -ne 0 ]; then
    echo "系统更新失败。"
    exit 1
else
    echo "系统更新成功。"
fi

# 安装必要的工具
check_and_install jq
check_and_install wget
check_and_install unzip
check_and_install dnsutils
check_and_install dkms

# 安装 Cloud 内核
echo "安装 Cloud 内核..."
apt-cache search linux-image-cloud
sudo apt-get install linux-image-cloud-amd64 -y
sudo update-grub

# 开启 TCP Fast Open (TFO)
echo "开启 TCP Fast Open (TFO)..."
echo "3" > /proc/sys/net/ipv4/tcp_fastopen
echo "net.ipv4.tcp_fastopen=3" > /etc/sysctl.d/30-tcp_fastopen.conf
sysctl --system

# 设置 BBRv3
echo "设置 BBRv3..."
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 查看当前的TCP流控算法
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
# 验证 tuned 服务状态
echo "检查 tuned 服务状态..."
if systemctl status tuned.service | grep -q "active (running)"; then
    echo "tuned 服务已成功启动。"
else
    echo "tuned 服务未启动，请检查日志进行排查。"
    exit 1
fi
# 验证配置是否应用
echo "验证 tuned 配置..."
active_profile=$(tuned-adm active)
if [[ "$active_profile" == *"network-throughput"* ]]; then
    echo "网络吞吐量优化配置已成功应用。"
else
    echo "未能应用网络吞吐量优化配置。"
    exit 1
fi

# 卸载 tcp-brutal 模块
if dkms status | grep -q "tcp-brutal"; then
    echo "卸载 tcp-brutal 模块..."
    dkms uninstall tcp-brutal/1.0.1 --all && dkms remove tcp-brutal/1.0.1 --all
else
    echo "tcp-brutal 模块未安装，跳过卸载。"
fi

# 检查 dkms 状态
dkms status

# 清理不需要的包
sudo apt-get autoremove -y
if [ $? -eq 0 ]; then
    echo "系统清理完成，不需要的包已移除。"
else
    echo "系统清理失败，请检查错误信息。"
    exit 1
fi

echo "所有步骤完成！"

echo "重启..."
reboot
