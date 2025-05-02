#!/bin/bash
# 安全加固脚本 - 自动配置防火墙、fail2ban 及 SSH 强化
# --- 配置变量 ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
DETECTED_TCP_PORTS="" # 全局变量存储检测到的TCP端口
DETECTED_UDP_PORTS="" # 全局变量存储检测到的UDP端口
DETECTED_SSH_PORT=""  # 全局变量存储检测到的SSH端口
SSH_LOG_PATH=""       # 全局变量存储检测到的SSH日志路径
FAIL2BAN_BACKEND="auto" # 全局变量存储检测到的Fail2ban后端
# --- 辅助函数 ---
# 检查上一条命令是否成功执行
# 参数: $1 - 命令描述
check_command_status() {
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：执行 '$1' 失败。请检查错误信息并重试。" >&2
        # 在交互式菜单中，不直接退出，允许用户重试或选择其他选项
        return 1 # 返回失败状态
    else
        echo "[✓] '$1' 执行成功。"
        return 0 # 返回成功状态
    fi
}
# 获取当前外部 IP 地址
get_current_ip() {
    echo "[+] 正在获取当前外部 IP 地址..."
    CURRENT_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
    if [ -z "$CURRENT_IP" ]; then
        echo "[!] 警告：无法自动获取当前 IP 地址。"
        read -p "请手动输入您当前的外部 IP 地址 (留空则不添加白名单): " CURRENT_IP
    else
        echo "[✓] 当前外部 IP 地址: $CURRENT_IP"
    fi
}
# 尝试自动查找 SSH 日志文件或确定合适的 Fail2ban 后端
# 设置全局变量: SSH_LOG_PATH 和 FAIL2BAN_BACKEND
find_ssh_log_or_backend() {
    echo "[+] 正在尝试自动检测 SSH 日志位置或 Fail2ban 后端..."
    SSH_LOG_PATH="" # 重置
    FAIL2BAN_BACKEND="auto" # 默认值
    # 优先检查 systemd journal
    if command -v journalctl &> /dev/null && journalctl -u sshd --no-pager --quiet &> /dev/null; then
        echo "[✓] 检测到 systemd journal 管理 SSH 日志。将使用 'systemd' 后端。"
        FAIL2BAN_BACKEND="systemd"
        # 对于 systemd 后端，logpath 通常不需要显式设置，但可以保留默认或注释掉
        SSH_LOG_PATH="using systemd backend" # 标记为使用 systemd
        return 0
    elif command -v journalctl &> /dev/null && journalctl -u ssh --no-pager --quiet &> /dev/null; then
         echo "[✓] 检测到 systemd journal 管理 SSH 日志 (服务名 ssh)。将使用 'systemd' 后端。"
        FAIL2BAN_BACKEND="systemd"
        SSH_LOG_PATH="using systemd backend" # 标记为使用 systemd
        return 0
    fi
    # 如果未使用 systemd 或 journalctl 无法查询 sshd 日志，则检查传统日志文件
    if [ -f "/var/log/auth.log" ]; then
        if grep -q "sshd" /var/log/auth.log &> /dev/null; then # 简单检查文件是否包含 sshd 条目
             echo "[✓] 检测到 SSH 日志文件: /var/log/auth.log"
             SSH_LOG_PATH="/var/log/auth.log"
             FAIL2BAN_BACKEND="auto" # 或者 pyinotify, gamin
             return 0
        fi
    fi
    if [ -f "/var/log/secure" ]; then
         if grep -q "sshd" /var/log/secure &> /dev/null; then
            echo "[✓] 检测到 SSH 日志文件: /var/log/secure"
            SSH_LOG_PATH="/var/log/secure"
            FAIL2BAN_BACKEND="auto" # 或者 pyinotify, gamin
            return 0
         fi
    fi
    echo "[!] 警告：无法自动确定 SSH 日志文件路径或 systemd 后端。"
    echo "    Fail2ban 配置将使用默认设置，可能需要您手动调整 '$FAIL2BAN_JAIL_LOCAL' 中的 'backend' 和 'logpath'。"
    # 保留 FAIL2BAN_BACKEND="auto"，让 fail2ban 自行尝试
    # SSH_LOG_PATH 保持为空，让 jail.local 中的默认值生效或提示用户
    return 1 # 表示未成功检测到特定路径
}
# 检测 SSH 端口
detect_ssh_port() {
    echo "[+] 正在检测当前 SSH 端口..."
    # 尝试从 sshd_config 获取
    DETECTED_SSH_PORT=$(grep -iE '^\s*Port\s+' "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    # 如果 sshd_config 中未明确指定或找不到文件，尝试从当前监听端口获取
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo "[!] 未在 $SSH_CONFIG_FILE 中找到明确的端口设置，尝试检测监听端口..."
        # 尝试使用 ss (推荐)
        if command -v ss &> /dev/null; then
            DETECTED_SSH_PORT=$(ss -tlpn 'sport = :*' | grep 'sshd' | awk '{print $4}' | cut -d ':' -f 2 | head -n 1)
        # 备选 netstat
        elif command -v netstat &> /dev/null; then
             DETECTED_SSH_PORT=$(netstat -tlpn | grep 'sshd' | awk '{print $4}' | cut -d ':' -f 2 | head -n 1)
        fi
    fi
    # 最后确认
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo "[!] 警告：无法自动检测到 SSH 端口。将假定为标准端口 22。"
        DETECTED_SSH_PORT="22"
    else
        echo "[✓] 检测到 SSH 端口: $DETECTED_SSH_PORT"
    fi
}
# 检测常用代理工具监听的端口 (示例)
detect_proxy_ports() {
    echo "[+] 正在检测常用代理工具端口 (TCP)..."
    local proxy_ports_tcp=""
    local proxy_ports_udp=""
    # 使用 ss 命令查找监听 TCP 端口的进程
    if command -v ss &> /dev/null; then
        # 添加你需要检测的代理进程名到这个 grep 模式中
        proxy_ports_tcp=$(ss -tlpn | grep -E 'snell|ss-|ssserver|shadow|tls' | awk '{print $4}' | cut -d ':' -f 2 | sort -un | tr '\n' ' ')
        proxy_ports_udp=$(ss -ulpn | grep -E 'snell|ss-|ssserver|shadow|tls' | awk '{print $4}' | cut -d ':' -f 2 | sort -un | tr '\n' ' ')
    elif command -v netstat &> /dev/null; then
         # 使用 netstat 作为备选
         proxy_ports_tcp=$(netstat -tlpn | grep -E 'snell|ss-|ssserver|shadow|tls' | awk '{print $4}' | cut -d ':' -f 2 | sort -un | tr '\n' ' ')
         proxy_ports_udp=$(netstat -ulpn | grep -E 'snell|ss-|ssserver|shadow|tls' | awk '{print $4}' | cut -d ':' -f 2 | sort -un | tr '\n' ' ')
    else
        echo "[!] 警告: 'ss' 和 'netstat' 命令都不可用，无法自动检测代理端口。"
    fi
    if [ -n "$proxy_ports_tcp" ]; then
        echo "[✓] 检测到潜在的代理 TCP 端口: $proxy_ports_tcp"
        DETECTED_TCP_PORTS+="$proxy_ports_tcp " # 追加到全局变量
    else
        echo "[-] 未检测到常用代理工具监听的 TCP 端口。"
    fi
     if [ -n "$proxy_ports_udp" ]; then
        echo "[✓] 检测到潜在的代理 UDP 端口: $proxy_ports_udp"
        DETECTED_UDP_PORTS+="$proxy_ports_udp " # 追加到全局变量
    else
        echo "[-] 未检测到常用代理工具监听的 UDP 端口。"
    fi
}
# --- 主要功能函数 ---
# 1. 安装必要的软件包
install_packages() {
    echo "[+] 正在更新软件包列表并安装 UFW 和 Fail2ban..."
    apt update -y
    check_command_status "软件包列表更新 (apt update)" || return 1
    apt install -y ufw fail2ban curl wget net-tools # 添加 net-tools 以防 ss 不可用
    check_command_status "安装 ufw, fail2ban, curl, wget, net-tools" || return 1
    echo "[✓] UFW 和 Fail2ban 安装完成。"
}
# 2. 配置 UFW 防火墙
configure_ufw() {
    echo "[+] 正在配置 UFW 防火墙..."
    # 检测 SSH 和代理端口
    detect_ssh_port
    detect_proxy_ports
    # 重置 UFW 到默认状态
    echo "y" | ufw reset
    check_command_status "重置 UFW" || return 1
    # 设置默认策略：拒绝所有入站，允许所有出站
    ufw default deny incoming
    check_command_status "设置默认入站策略为 deny" || return 1
    ufw default allow outgoing
    check_command_status "设置默认出站策略为 allow" || return 1
    # 允许 SSH 端口
    if [ -n "$DETECTED_SSH_PORT" ]; then
        ufw allow "$DETECTED_SSH_PORT"/tcp
        check_command_status "允许 SSH 端口 $DETECTED_SSH_PORT/tcp" || return 1
    else
        echo "[!] 错误：无法获取 SSH 端口，跳过 UFW SSH 规则添加。" >&2
        return 1 # SSH 是关键，获取不到端口则认为配置失败
    fi
    # 允许检测到的代理 TCP 端口
    if [ -n "$DETECTED_TCP_PORTS" ]; then
        for port in $DETECTED_TCP_PORTS; do
            ufw allow "$port"/tcp
            check_command_status "允许 TCP 端口 $port/tcp" || return 1 # 检查每个端口添加状态
        done
    fi
    # 允许检测到的代理 UDP 端口
    if [ -n "$DETECTED_UDP_PORTS" ]; then
        for port in $DETECTED_UDP_PORTS; do
            ufw allow "$port"/udp
            check_command_status "允许 UDP 端口 $port/udp" || return 1 # 检查每个端口添加状态
        done
    fi
    # 允许本地回环接口
    ufw allow in on lo
    check_command_status "允许本地回环入站" || return 1
    ufw allow out on lo
    check_command_status "允许本地回环出站" || return 1
    # (已移除) 不再尝试添加 ufw allow icmp
    # 添加当前 IP 到白名单 (如果获取到)
    if [ -n "$CURRENT_IP" ]; then
        ufw allow from "$CURRENT_IP" to any port "$DETECTED_SSH_PORT" proto tcp comment '当前 IP 白名单 (SSH)'
        check_command_status "添加当前 IP $CURRENT_IP 到 SSH 白名单" || return 1
    fi
    # 启用 UFW
    echo "y" | ufw enable
    check_command_status "启用 UFW" || return 1
    echo "[✓] UFW 配置完成并已启用。"
    ufw status verbose # 显示详细状态
}
# 3. 配置 Fail2ban
configure_fail2ban() {
    echo "[+] 正在配置 Fail2ban..."
    # 自动检测 SSH 日志或后端
    find_ssh_log_or_backend
    # 创建 jail.local 配置文件
    echo "[+] 正在创建 $FAIL2BAN_JAIL_LOCAL..."
    cat > "$FAIL2BAN_JAIL_LOCAL" << EOF
[DEFAULT]
# 默认禁止时间（秒）
bantime = 1h
# 在多少时间内达到最大重试次数则封禁
findtime = 10m
# 最大重试次数
maxretry = 5
# 忽略的 IP 地址，可以是单个 IP、CIDR 或 DNS 主机名
# 将当前 IP 加入白名单 (如果获取到)
ignoreip = 127.0.0.1/8 ::1 ${CURRENT_IP:-}
# 后端设置 (根据检测结果设置)
backend = ${FAIL2BAN_BACKEND}
[sshd]
enabled = true
port = ${DETECTED_SSH_PORT:-ssh} # 使用检测到的端口，若未检测到则使用默认 'ssh'
filter = sshd
# 日志路径 (如果检测到特定文件路径则使用，否则留空让 fail2ban 使用默认或 systemd 后端)
EOF
    # 只有在检测到具体日志文件路径时才添加 logpath
    if [ -n "$SSH_LOG_PATH" ] && [ "$SSH_LOG_PATH" != "using systemd backend" ]; then
        echo "logpath = $SSH_LOG_PATH" >> "$FAIL2BAN_JAIL_LOCAL"
    elif [ "$FAIL2BAN_BACKEND" != "systemd" ]; then
         # 如果没有检测到特定路径且不是 systemd 后端，添加注释提示用户检查
         echo "# logpath = %(sshd_log)s  # 自动检测失败，请根据系统检查并取消注释或修改" >> "$FAIL2BAN_JAIL_LOCAL"
    fi
    # 添加 action (默认即可，通常无需修改)
    # echo "action = %(action_)s" >> "$FAIL2BAN_JAIL_LOCAL"
    check_command_status "创建 $FAIL2BAN_JAIL_LOCAL" || return 1
    # 重启 Fail2ban 服务使配置生效
    systemctl restart fail2ban
    check_command_status "重启 Fail2ban 服务" || return 1
    systemctl enable fail2ban
    check_command_status "设置 Fail2ban 开机自启" || return 1
    echo "[✓] Fail2ban 配置完成并已重启。"
    # 短暂等待后检查状态
    sleep 2
    fail2ban-client status sshd
}
# 4. 强化 SSH 配置
secure_ssh() {
    echo "[+] 正在强化 SSH 配置 ($SSH_CONFIG_FILE)..."
    local backup_file="${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    # 备份原始配置文件
    cp "$SSH_CONFIG_FILE" "$backup_file"
    check_command_status "备份 SSH 配置文件到 $backup_file" || return 1
    echo "[✓] SSH 配置文件已备份到: $backup_file"
    # 应用安全设置 (如果存在则修改，不存在则添加)
    # 禁用 root 登录
    if grep -qE '^\s*#?\s*PermitRootLogin' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^\s*#?\s*PermitRootLogin\s+.*/PermitRootLogin no/' "$SSH_CONFIG_FILE"
    else
        echo "PermitRootLogin no" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "禁用 Root 登录" || return 1
    # 禁用密码认证 (推荐使用密钥登录)
    read -p "[?] 是否禁用 SSH 密码认证，强制使用密钥登录? (y/N): " disable_password_auth
    if [[ "$disable_password_auth" =~ ^[Yy]$ ]]; then
        if grep -qE '^\s*#?\s*PasswordAuthentication' "$SSH_CONFIG_FILE"; then
            sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' "$SSH_CONFIG_FILE"
        else
            echo "PasswordAuthentication no" >> "$SSH_CONFIG_FILE"
        fi
        check_command_status "禁用密码认证" || return 1
        echo "[✓] 已禁用密码认证。请确保您已配置 SSH 密钥！"
        # 顺便禁用 ChallengeResponseAuthentication
         if grep -qE '^\s*#?\s*ChallengeResponseAuthentication' "$SSH_CONFIG_FILE"; then
            sed -i -E 's/^\s*#?\s*ChallengeResponseAuthentication\s+.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG_FILE"
        else
            echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG_FILE"
        fi
        check_command_status "禁用 ChallengeResponseAuthentication" || return 1
    else
        echo "[-] 跳过禁用密码认证。"
    fi
    # 限制最大认证尝试次数
    if grep -qE '^\s*#?\s*MaxAuthTries' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^\s*#?\s*MaxAuthTries\s+.*/MaxAuthTries 3/' "$SSH_CONFIG_FILE"
    else
        echo "MaxAuthTries 3" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 MaxAuthTries 为 3" || return 1
    # 启用 TCPKeepAlive
     if grep -qE '^\s*#?\s*TCPKeepAlive' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^\s*#?\s*TCPKeepAlive\s+.*/TCPKeepAlive yes/' "$SSH_CONFIG_FILE"
    else
        echo "TCPKeepAlive yes" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "启用 TCPKeepAlive" || return 1
    # 设置 ClientAliveInterval
     if grep -qE '^\s*#?\s*ClientAliveInterval' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^\s*#?\s*ClientAliveInterval\s+.*/ClientAliveInterval 300/' "$SSH_CONFIG_FILE"
    else
        echo "ClientAliveInterval 300" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 ClientAliveInterval 为 300" || return 1
     if grep -qE '^\s*#?\s*ClientAliveCountMax' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^\s*#?\s*ClientAliveCountMax\s+.*/ClientAliveCountMax 2/' "$SSH_CONFIG_FILE"
    else
        echo "ClientAliveCountMax 2" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 ClientAliveCountMax 为 2" || return 1
    # 检查 SSH 配置语法
    sshd -t
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：修改后的 SSH 配置 ($SSH_CONFIG_FILE) 语法检查失败！" >&2
        echo "[!] 正在尝试恢复备份文件..."
        cp "$backup_file" "$SSH_CONFIG_FILE"
        if [ $? -eq 0 ]; then
            echo "[✓] 备份文件已恢复。"
        else
            echo "[✗] 错误：恢复备份文件失败！请手动检查 $SSH_CONFIG_FILE 和 $backup_file" >&2
        fi
        return 1
    fi
    check_command_status "SSH 配置语法检查" || return 1
    # 重启 SSH 服务使配置生效
    systemctl restart sshd
    check_command_status "重启 SSH 服务 (sshd)" || return 1
    echo "[✓] SSH 配置强化完成并已重启服务。"
}
# --- 脚本主逻辑 ---
# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[✗] 错误：此脚本需要以 root 权限运行。" >&2
    echo "请尝试使用 'sudo bash $0' 来运行。"
    exit 1
fi
# 获取当前 IP (脚本开始时获取一次)
get_current_ip
# 显示菜单
while true; do
    echo ""
    echo "--- Linux 安全加固脚本 ---"
    echo "1. 安装 UFW 和 Fail2ban"
    echo "2. 配置 UFW 防火墙 (将重置现有规则)"
    echo "3. 配置 Fail2ban"
    echo "4. 强化 SSH 配置"
    echo "5. 执行所有步骤 (1-4)"
    echo "6. 查看 UFW 状态"
    echo "7. 查看 Fail2ban SSH jail 状态"
    echo "8. 退出"
    echo "---------------------------"
    read -p "请输入选项 [1-8]: " choice
    case $choice in
        1)
            install_packages
            ;;
        2)
            # 配置 UFW 前最好先安装
            if ! command -v ufw &> /dev/null; then
                echo "[!] UFW 未安装，请先执行选项 1。"
            else
                configure_ufw
            fi
            ;;
        3)
            # 配置 Fail2ban 前最好先安装并配置好 UFW (特别是 SSH 端口)
            if ! command -v fail2ban-client &> /dev/null; then
                echo "[!] Fail2ban 未安装，请先执行选项 1。"
            elif [ -z "$DETECTED_SSH_PORT" ]; then
                 # 尝试再次检测 SSH 端口，因为可能只运行了此选项
                 detect_ssh_port
                 if [ -z "$DETECTED_SSH_PORT" ]; then
                     echo "[!] 无法检测 SSH 端口，Fail2ban 配置可能不完整。建议先运行选项 2 或 5。"
                 else
                    configure_fail2ban
                 fi
            else
                configure_fail2ban
            fi
            ;;
        4)
             if [ ! -f "$SSH_CONFIG_FILE" ]; then
                 echo "[!] SSH 配置文件 $SSH_CONFIG_FILE 不存在。"
             else
                secure_ssh
             fi
            ;;
        5)
            echo "[+] 开始执行所有步骤..."
            install_packages && \
            configure_ufw && \
            configure_fail2ban && \
            secure_ssh
            if [ $? -eq 0 ]; then
                echo "[✓] 所有步骤执行成功！"
            else
                echo "[✗] 执行过程中出现错误，请检查上面的输出。"
            fi
            ;;
        6)
            if command -v ufw &> /dev/null; then
                echo "[+] 当前 UFW 状态:"
                ufw status verbose
            else
                echo "[!] UFW 未安装或不可用。"
            fi
            ;;
        7)
            if command -v fail2ban-client &> /dev/null; then
                echo "[+] 当前 Fail2ban SSH jail 状态:"
                fail2ban-client status sshd
            else
                echo "[!] Fail2ban 未安装或不可用。"
            fi
            ;;
        8)
            echo "[-] 退出脚本。"
            exit 0
            ;;
        *)
            echo "[!] 无效选项，请输入 1 到 8 之间的数字。"
            ;;
    esac
    read -p "按 Enter键 继续..." # 暂停以便用户阅读输出
done