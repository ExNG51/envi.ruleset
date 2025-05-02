#!/bin/bash

# --- 配置变量 ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"

--- 辅助函数 ---
# 检查上一条命令是否成功执行
# 参数: $1 - 命令描述
check_command_status() {
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：执行 '$1' 失败。请检查错误信息并重试。" >&2
        exit 1
    else
        echo "[✓] '$1' 执行成功。"
    fi
}
# 获取当前外部 IP 地址
get_current_ip() {
    echo "[+] 正在获取当前外部 IP 地址..."
    CURRENT_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
    if [ -z "$CURRENT_IP" ]; then
        echo "[!] 警告：无法自动获取当前 IP 地址。"
        read -p "请输入您的公网 IP 地址（用于添加到白名单，留空则跳过）: " MANUAL_IP
        CURRENT_IP=$MANUAL_IP
    fi
    if [ -n "$CURRENT_IP" ]; then
        echo "[✓] 当前 IP: $CURRENT_IP (将尝试添加到白名单)"
    else
        echo "[!] 未能获取或指定 IP 地址，Fail2ban 白名单将不包含当前 IP。"
    fi
}
# 检测当前 SSH 端口
detect_ssh_port() {
    echo "[+] 正在检测当前 SSH 端口..."
    SSH_PORT=$(ss -tlpn | grep sshd | grep -oP '(?<=:)\d+' | head -n 1)
    if [ -z "$SSH_PORT" ]; then
        echo "[!] 警告：无法自动检测 SSH 端口。将使用默认端口 22。"
        SSH_PORT="22"
    else
        echo "[✓] 检测到 SSH 端口为: $SSH_PORT"
    fi
}
# 函数：检测代理端口 (Snell, Shadowsocks, Shadow TLS)
detect_proxy_ports() {
    echo "[+] 正在检测常见的代理服务端口 (Snell, Shadowsocks, Shadow TLS)..."
    # 使用 ss 和 grep -E 来查找相关进程监听的 TCP 和 UDP 端口
    # -t: tcp, -u: udp, -l: listening, -p: process, -n: numeric ports, -e: extended info
    # grep -E: 使用扩展正则表达式匹配进程名或相关关键字
    # grep -oP '(?<=:)\d+(?=\s+)' : 提取冒号后面、空格前面的数字（端口号）
    # sort -u: 去重并排序
    PROXY_PORTS=$(ss -tulpne | grep -E 'snell|ss-|ssserver|shadow|tls' | grep -oP '(?<=:)\d+(?=\s+)' | sort -u)
    if [ -n "$PROXY_PORTS" ]; then
        echo "[✓] 检测到以下可能的代理端口:"
        # 将换行符转换为空格，以便打印
        echo "    $(echo $PROXY_PORTS | tr '\n' ' ')"
    else
        echo "[!] 未检测到常见的代理服务端口。"
        PROXY_PORTS="" # 确保变量为空
    fi
}
# --- 主要功能函数 ---
# 函数：安装必要的软件包
install_packages() {
    echo "[+] 正在更新系统并安装必要的软件包 (ufw, fail2ban, net-tools, lsof, curl)..."
    apt update
    check_command_status "apt update"
    apt install -y ufw fail2ban net-tools lsof curl
    check_command_status "apt install -y ufw fail2ban net-tools lsof curl"
    echo "[✓] 软件包安装完成。"
}
# 函数：配置 UFW 防火墙
configure_ufw() {
    echo "[+] 正在配置 UFW 防火墙..."
    ufw --force reset # 强制重置规则
    check_command_status "ufw --force reset"
    ufw default deny incoming
    check_command_status "ufw default deny incoming"
    ufw default allow outgoing
    check_command_status "ufw default allow outgoing"
    echo "[+] 允许 SSH 端口: $SSH_PORT"
    ufw allow $SSH_PORT/tcp
    check_command_status "ufw allow $SSH_PORT/tcp"
    if [ -n "$PROXY_PORTS" ]; then
        echo "[+] 允许检测到的代理端口..."
        for port in $PROXY_PORTS; do
            echo "    允许端口: $port (TCP/UDP)"
            ufw allow $port/tcp
            check_command_status "ufw allow $port/tcp"
            ufw allow $port/udp
            check_command_status "ufw allow $port/udp"
        done
    fi
    ufw enable
    # UFW enable 需要交互确认，这里假设用户会输入 'y'
    # 在完全自动化的脚本中可能需要 `yes | ufw enable`，但这里保留交互性
    check_command_status "ufw enable"
    echo "[✓] UFW 防火墙配置完成并已启用。"
    ufw status verbose
}
# 函数：配置 Fail2ban
configure_fail2ban() {
    echo "[+] 正在配置 Fail2ban..."
    # 创建或覆盖 jail.local 文件
    echo "[+] 创建 $FAIL2BAN_JAIL_LOCAL ..."
    cat > $FAIL2BAN_JAIL_LOCAL << EOF
[DEFAULT]
# 默认封禁时间（秒）
bantime = 3600
# 检测时间窗口（秒）
findtime = 600
# 最大重试次数
maxretry = 5
# 白名单 IP，包括本地回环和当前 IP (如果获取到)
ignoreip = 127.0.0.1/8 ::1 $( [ -n "$CURRENT_IP" ] && echo "$CURRENT_IP" )
# 使用 UFW 进行封禁操作
banaction = ufw
# 后端（对于 systemd 系统）
backend = systemd
[sshd]
enabled = true
# 使用检测到的 SSH 端口
port = $SSH_PORT
# 更严格的 SSH 重试次数
maxretry = 3
# SSH 日志路径 (根据系统调整，常见的路径)
logpath = %(sshd_log)s
EOF
    check_command_status "创建 $FAIL2BAN_JAIL_LOCAL"
    echo "[+] 重启 Fail2ban 服务..."
    systemctl restart fail2ban
    check_command_status "systemctl restart fail2ban"
    systemctl enable fail2ban
    check_command_status "systemctl enable fail2ban"
    echo "[✓] Fail2ban 配置完成并已启动。"
    sleep 2 # 等待服务启动
    fail2ban-client status
    echo "---"
    fail2ban-client status sshd
}
# 函数：禁用 SSH 密码认证
disable_password_auth() {
    echo "[!] 警告：禁用 SSH 密码认证！"
    echo "[!] 在继续之前，请务必确认您已经设置并测试了 SSH 密钥对登录。"
    echo "[!] 如果您没有配置密钥登录，禁用密码认证将导致您无法通过 SSH 登录服务器！"
    read -p "您确定要禁用 SSH 密码认证吗？ (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "[!] 操作已取消。"
        return 1
    fi
    echo "[+] 正在禁用 SSH 密码认证..."
    # 备份原始配置文件
    cp $SSH_CONFIG_FILE "${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    check_command_status "备份 $SSH_CONFIG_FILE"
    # 禁用密码认证
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG_FILE
    check_command_status "修改 PasswordAuthentication"
    # 确保 ChallengeResponseAuthentication 也被禁用（如果存在）
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' $SSH_CONFIG_FILE
    check_command_status "修改 ChallengeResponseAuthentication"
    # 确保 UsePAM 设置允许密钥登录（通常默认是 yes，但检查一下）
    if grep -q "^#\?UsePAM" $SSH_CONFIG_FILE; then
        sed -i 's/^#\?UsePAM.*/UsePAM yes/' $SSH_CONFIG_FILE
    else
        echo "UsePAM yes" >> $SSH_CONFIG_FILE
    fi
    check_command_status "确保 UsePAM yes"
    echo "[+] 正在重新加载 SSH 服务配置..."
    systemctl reload sshd
    check_command_status "systemctl reload sshd"
    echo "[✓] SSH 密码认证已禁用。请确保您的密钥登录正常工作！"
}
# --- 主逻辑 ---
# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份运行。" >&2
    exit 1
fi
# 显示欢迎信息
echo "=========================================================="
echo "              系统安全加固脚本 (优化版)                  "
echo "=========================================================="
echo
# 执行初始检测
get_current_ip
detect_ssh_port
detect_proxy_ports
echo # 添加空行
# 显示菜单
echo "请选择要执行的操作:"
echo "  1) 安装必要的软件包"
echo "  2) 配置 UFW 防火墙"
echo "  3) 配置 Fail2ban"
echo "  4) 禁用 SSH 密码认证 (请确保已设置密钥登录!)"
echo "  5) 执行所有加固操作 (1-4)"
echo "  6) 退出"
echo
read -p "请输入选项编号: " choice
case $choice in
    1)
        install_packages
        ;;
    2)
        # 配置 UFW 前需要知道 SSH 端口和代理端口
        # 确保这些检测已运行 (虽然在菜单前已运行，但明确依赖关系)
        if [ -z "$SSH_PORT" ]; then detect_ssh_port; fi
        if [ -z "$PROXY_PORTS" ] && [[ $(type -t detect_proxy_ports) == 'function' ]]; then detect_proxy_ports; fi
        configure_ufw
        ;;
    3)
        # 配置 Fail2ban 前需要知道 SSH 端口和当前 IP
        if [ -z "$SSH_PORT" ]; then detect_ssh_port; fi
        if [ -z "$CURRENT_IP" ] && [[ $(type -t get_current_ip) == 'function' ]]; then get_current_ip; fi
        configure_fail2ban
        ;;
    4)
        disable_password_auth
        ;;
    5)
        echo "[+] 执行所有加固操作..."
        install_packages
        # 确保检测函数已运行
        if [ -z "$SSH_PORT" ]; then detect_ssh_port; fi
        if [ -z "$PROXY_PORTS" ] && [[ $(type -t detect_proxy_ports) == 'function' ]]; then detect_proxy_ports; fi
        if [ -z "$CURRENT_IP" ] && [[ $(type -t get_current_ip) == 'function' ]]; then get_current_ip; fi
        configure_ufw
        configure_fail2ban
        disable_password_auth # 注意：这里会再次请求确认
        echo "[✓] 所有加固操作已尝试执行。"
        ;;
    6)
        echo "退出脚本。"
        exit 0
        ;;
    *)
        echo "无效选项，退出脚本。" >&2
        exit 1
        ;;
esac
echo
echo "=========================================================="
echo "              脚本执行完毕                             "
echo "=========================================================="
exit 0