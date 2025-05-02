#!/bin/bash
# 安全加固 - 自动配置防火墙、fail2ban 及 SSH 强化
# --- 配置变量 ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
# --- 全局变量 ---
# 这些变量将在函数中被设置
CURRENT_IP=""
DETECTED_SSH_PORT=""
DETECTED_TCP_PORTS=""
DETECTED_UDP_PORTS=""
# --- 辅助函数 ---
# 检查上一条命令是否成功执行
# 参数: $1 - 命令描述
check_command_status() {
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：执行 '$1' 失败。请检查错误信息并重试。" >&2
        # 在关键操作失败时可以选择退出，或者只是报告错误并继续
        # exit 1 # 如果希望在任何错误时停止脚本，取消此行注释
        return 1 # 返回失败状态码
    else
        echo "[✓] '$1' 执行成功。"
        return 0 # 返回成功状态码
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
        echo "[✓] 当前 IP 地址: $CURRENT_IP (将尝试添加到白名单)"
    else
        echo "[!] 未能获取或指定 IP 地址，Fail2ban 白名单将不包含当前 IP。"
    fi
}
# 函数：安装必要的软件包
install_packages() {
    echo "[+] 正在更新系统并安装必要的软件包 (ufw, fail2ban, net-tools, lsof, curl, wget)..."
    apt update
    check_command_status "apt update" || return 1 # 如果更新失败则停止安装
    apt install -y ufw fail2ban net-tools lsof curl wget
    check_command_status "安装软件包" || return 1
    echo "[✓] 软件包安装完成。"
}
# 函数：检测当前 SSH 端口
detect_ssh_port() {
    echo "[+] 正在检测当前 SSH 端口..."
    # 从 sshd_config 文件中查找 Port 指令
    DETECTED_SSH_PORT=$(grep -i '^Port ' "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    # 如果文件中没有明确指定 Port，则默认为 22
    if [ -z "$DETECTED_SSH_PORT" ]; then
        DETECTED_SSH_PORT="22"
        echo "[!] 在 $SSH_CONFIG_FILE 中未找到明确的 Port 设置，假定为默认端口 22。"
    else
        echo "[✓] 检测到 SSH 端口为: $DETECTED_SSH_PORT"
    fi
}
# 函数：检测代理端口 (Snell, Shadowsocks, Shadow TLS)
detect_proxy_ports() {
    echo "[+] 正在检测代理服务使用的端口 (Snell, Shadowsocks, Shadow TLS)..."
    # 初始化端口变量
    DETECTED_TCP_PORTS=""
    DETECTED_UDP_PORTS=""
    # 使用 ss 命令检测端口并解析
    # -t: tcp, -u: udp, -l: listening, -p: process, -n: numeric ports
    # grep -E: 匹配关键字
    # awk: 提取协议和端口
    # sed: 清理端口字符串
    # sort -u: 去重
    local process_output
    process_output=$(ss -tulpn 2>/dev/null | grep -E 'snell|ss-|ssserver|shadow|tls')
    if [ -z "$process_output" ]; then
         echo "[!] 未检测到与关键字 'snell', 'ss-', 'ssserver', 'shadow', 'tls' 相关的监听进程。"
         return # 没有检测到，直接返回
    fi
    echo "$process_output" | while IFS= read -r line; do
        protocol=$(echo "$line" | awk '{print $1}')
        # 提取监听地址和端口部分，例如 *:443 或 127.0.0.1:8080
        listen_addr_port=$(echo "$line" | awk '{print $5}')
        # 从地址端口字符串中提取端口号 (处理 IPv4 和 IPv6 的情况)
        port=$(echo "$listen_addr_port" | sed 's/.*://')
        # 提取进程信息 (尝试从 users:(("name",...)) 中获取名字)
        process_name=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "未知")
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then # 确保提取到的是数字端口
            if [ "$protocol" = "tcp" ]; then
                # 避免重复添加
                if [[ ! " $DETECTED_TCP_PORTS " =~ " $port " ]]; then
                     echo "  发现 TCP 端口 $port (进程: ${process_name})"
                     DETECTED_TCP_PORTS="$DETECTED_TCP_PORTS $port"
                fi
            elif [ "$protocol" = "udp" ]; then
                # 避免重复添加
                if [[ ! " $DETECTED_UDP_PORTS " =~ " $port " ]]; then
                    echo "  发现 UDP 端口 $port (进程: ${process_name})"
                    DETECTED_UDP_PORTS="$DETECTED_UDP_PORTS $port"
                fi
            fi
        fi
    done
    # 去除首尾空格
    DETECTED_TCP_PORTS=$(echo "$DETECTED_TCP_PORTS" | xargs)
    DETECTED_UDP_PORTS=$(echo "$DETECTED_UDP_PORTS" | xargs)
    if [ -z "$DETECTED_TCP_PORTS" ] && [ -z "$DETECTED_UDP_PORTS" ]; then
        echo "[!] 未能从监听进程中解析出有效的代理服务端口。"
    else
        echo "[✓] 代理端口检测完成。"
        [ -n "$DETECTED_TCP_PORTS" ] && echo "  将配置 UFW 允许 TCP 端口: $DETECTED_TCP_PORTS"
        [ -n "$DETECTED_UDP_PORTS" ] && echo "  将配置 UFW 允许 UDP 端口: $DETECTED_UDP_PORTS"
    fi
}
# 函数：配置 UFW 防火墙
# 参数: $1 - SSH 端口
#       $2 - 要允许的 TCP 端口列表 (空格分隔)
#       $3 - 要允许的 UDP 端口列表 (空格分隔)
configure_ufw() {
    local ssh_port=$1
    local tcp_ports=$2
    local udp_ports=$3
    local port # 循环变量
    echo "[+] 正在配置 UFW 防火墙..."
    # 检查 ufw 是否已安装
    if ! command -v ufw &> /dev/null; then
        echo "[!] UFW 未安装。请先运行安装选项。"
        return 1 # 返回错误码
    fi
    # 询问用户是否重置 UFW 规则
    read -p "是否要重置所有 UFW 规则？这将清除现有规则。[y/N]: " confirm_reset
    if [[ "$confirm_reset" =~ ^[Yy]$ ]]; then
        echo "[+] 正在重置 UFW 规则..."
        ufw --force reset
        check_command_status "UFW 重置" || return 1
    else
        echo "[+] 跳过 UFW 重置。"
    fi
    echo "[+] 设置 UFW 默认策略：拒绝入站，允许出站..."
    ufw default deny incoming
    check_command_status "设置 UFW 默认入站策略为 deny" || return 1
    ufw default allow outgoing
    check_command_status "设置 UFW 默认出站策略为 allow" || return 1
    # 允许 SSH 端口
    if [ -n "$ssh_port" ]; then
        echo "[+] 允许 SSH 端口 $ssh_port/tcp..."
        ufw allow "$ssh_port/tcp"
        check_command_status "允许 SSH 端口 $ssh_port/tcp"
    else
        echo "[!] 警告：未指定或检测到 SSH 端口，未添加 SSH 允许规则。"
    fi
    # 允许检测到的 TCP 代理端口
    if [ -n "$tcp_ports" ]; then
        echo "[+] 允许检测到的 TCP 代理端口: $tcp_ports"
        for port in $tcp_ports; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then # 再次验证是数字
                ufw allow "$port/tcp"
                check_command_status "允许 TCP 端口 $port"
            fi
        done
    else
        echo "[+] 未指定或检测到需要额外允许的 TCP 端口。"
    fi
     # 允许检测到的 UDP 代理端口
    if [ -n "$udp_ports" ]; then
        echo "[+] 允许检测到的 UDP 代理端口: $udp_ports"
        for port in $udp_ports; do
             if [[ "$port" =~ ^[0-9]+$ ]]; then # 再次验证是数字
                ufw allow "$port/udp"
                check_command_status "允许 UDP 端口 $port"
             fi
        done
    else
        echo "[+] 未指定或检测到需要额外允许的 UDP 端口。"
    fi
    # 启用 UFW (如果尚未启用)
    if ! ufw status | grep -qw active; then
        echo "[+] 正在启用 UFW..."
        # 使用 yes 管道自动确认
        yes | ufw enable
        check_command_status "启用 UFW" || return 1
    else
        echo "[+] UFW 已经启用。"
        # 如果规则有变动，重新加载规则可能是个好主意
        echo "[+] 重新加载 UFW 规则..."
        ufw reload
        check_command_status "重新加载 UFW 规则"
    fi
    echo "[✓] UFW 防火墙配置完成。"
    echo "[+] 当前 UFW 状态和规则:"
    ufw status verbose
}
# 函数：配置 Fail2ban
# 参数: $1 - 要添加到白名单的 IP 地址
configure_fail2ban() {
    local whitelist_ip=$1
    echo "[+] 正在配置 Fail2ban..."
    if ! command -v fail2ban-client &> /dev/null; then
        echo "[!] Fail2ban 未安装。请先运行安装选项。"
        return 1
    fi
    # 确定 Fail2ban 后端 (对于现代系统通常是 systemd)
    local backend="auto"
    if [ -d /run/systemd/system ]; then
        backend="systemd"
        echo "[+] 检测到 systemd，将 Fail2ban 后端设置为 systemd。"
    fi
    # 确定 sshd 日志路径
    local sshd_logpath="/var/log/auth.log" # Debian/Ubuntu 默认
    if [ -f /var/log/secure ]; then # CentOS/RHEL 默认
        sshd_logpath="/var/log/secure"
    fi
    echo "[+] 使用 SSHD 日志路径: $sshd_logpath"
    echo "[+] 创建或更新 Fail2ban 本地配置文件: $FAIL2BAN_JAIL_LOCAL"
    # 基础配置
    cat > "$FAIL2BAN_JAIL_LOCAL" << EOF
[DEFAULT]
# 1 小时封禁时间
bantime = 1h
# 10 分钟内达到最大重试次数则触发封禁
findtime = 10m
# 最多允许 5 次失败尝试
maxretry = 5
# 使用 UFW 进行封禁操作
banaction = ufw
# 后端监控方式
backend = $backend
# 白名单 IP 地址，包括本地回环和当前 IP (如果获取到)
ignoreip = 127.0.0.1/8 ::1 $whitelist_ip
[sshd]
enabled = true
# 覆盖默认的 maxretry，设置为 3 次
maxretry = 3
# 指定 SSH 端口 (如果检测到非标准端口)
port = $DETECTED_SSH_PORT
# 指定日志路径
logpath = $sshd_logpath
# 使用更具体的 banaction (如果需要)
# banaction = ufw[application=sshd]
# 可以添加其他服务的 jail 配置，例如：
# [nginx-http-auth]
# enabled = true
# ...
# [postfix]
# enabled = true
# ...
EOF
    check_command_status "写入 Fail2ban 配置文件 $FAIL2BAN_JAIL_LOCAL" || return 1
    echo "[+] 重启 Fail2ban 服务以应用配置..."
    systemctl restart fail2ban
    check_command_status "重启 Fail2ban 服务" || return 1
    echo "[+] 检查 Fail2ban 服务状态..."
    systemctl status fail2ban --no-pager -l
    echo "[+] 检查 sshd jail 状态..."
    fail2ban-client status sshd
    echo "[✓] Fail2ban 配置完成。"
}
# 函数：禁用 SSH 密码认证
disable_password_auth() {
    echo "[!] 警告：禁用密码认证前，请确保您已配置好 SSH 密钥对登录！"
    echo "[!] 如果没有密钥，您将无法通过 SSH 登录服务器！"
    read -p "您确定要禁用 SSH 密码认证吗？(请输入 'yes' 确认): " confirm_disable
    if [[ "$confirm_disable" != "yes" ]]; then
        echo "[+] 操作取消。未禁用 SSH 密码认证。"
        return
    fi
    echo "[+] 正在禁用 SSH 密码认证..."
    # 备份原始配置文件
    cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    check_command_status "备份 SSH 配置文件" || return 1
    # 禁用密码认证
    if grep -q "^PasswordAuthentication" "$SSH_CONFIG_FILE"; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG_FILE"
    else
        echo "PasswordAuthentication no" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 PasswordAuthentication no" || return 1
    # 确保 ChallengeResponseAuthentication 也被禁用 (通常与密码认证相关)
    if grep -q "^ChallengeResponseAuthentication" "$SSH_CONFIG_FILE"; then
        sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG_FILE"
    else
        echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 ChallengeResponseAuthentication no" || return 1
    # 确保 UsePAM 设置允许密钥登录 (通常默认为 yes，但检查一下)
    if grep -q "^UsePAM" "$SSH_CONFIG_FILE"; then
         # 如果 UsePAM 设置为 no，可能会阻止某些密钥登录方式，提醒用户检查
         if grep -q "^UsePAM no" "$SSH_CONFIG_FILE"; then
              echo "[!] 警告: UsePAM 在 $SSH_CONFIG_FILE 中设置为 no。这可能影响某些认证方式。如果遇到问题，请考虑将其设置为 yes。"
         fi
         # 确保 UsePAM yes 没有被注释掉 (如果存在的话)
         sed -i 's/^#UsePAM yes/UsePAM yes/' "$SSH_CONFIG_FILE"
    else
        # 如果没有 UsePAM 指令，添加一个推荐的设置
        echo "UsePAM yes" >> "$SSH_CONFIG_FILE"
        echo "[+] 添加了 UsePAM yes 到 SSH 配置。"
    fi
    echo "[+] 正在测试 SSH 配置语法..."
    sshd -t
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：SSH 配置测试失败！请检查 $SSH_CONFIG_FILE 文件。"
        echo "[!] 正在尝试恢复备份..."
        cp "${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)" "$SSH_CONFIG_FILE"
        echo "[!] 备份已恢复。SSH 服务未重启。"
        return 1
    fi
    echo "[+] SSH 配置测试通过。正在重启 SSH 服务..."
    systemctl restart sshd
    check_command_status "重启 SSH 服务" || {
        echo "[✗] 错误：重启 SSH 服务失败！请手动检查服务状态和日志。";
        return 1;
    }
    echo "[✓] SSH 密码认证已禁用，并已重启 SSH 服务。"
    echo "[!] 请务必从新的终端窗口测试您的 SSH 密钥登录是否正常！"
}
# 主菜单和执行逻辑
main_menu() {
    while true; do
        echo
        echo "=========================================================="
        echo "              系统安全加固脚本 (优化版 v2)               "
        echo "=========================================================="
        echo "请选择要执行的操作:"
        echo "  1. 安装必要的软件包 (ufw, fail2ban, etc.)"
        echo "  2. 配置 UFW 防火墙 (自动检测 SSH 和代理端口)"
        echo "  3. 配置 Fail2ban (自动检测 SSH 端口, 添加当前 IP 到白名单)"
        echo "  4. 禁用 SSH 密码认证 (需要 SSH 密钥!)"
        echo "  5. 执行所有加固操作 (1 -> 2 -> 3 -> 4)"
        echo "  q. 退出脚本"
        echo "----------------------------------------------------------"
        read -p "请输入选项 [1-5, q]: " choice
        case $choice in
            1)
                install_packages
                ;;
            2)
                detect_ssh_port    # 检测 SSH 端口
                detect_proxy_ports # 检测代理端口 (设置全局变量)
                # 将检测到的端口传递给 configure_ufw
                configure_ufw "$DETECTED_SSH_PORT" "$DETECTED_TCP_PORTS" "$DETECTED_UDP_PORTS"
                ;;
            3)
                detect_ssh_port # Fail2ban 配置也需要 SSH 端口
                get_current_ip  # 获取 IP
                configure_fail2ban "$CURRENT_IP"
                ;;
            4)
                disable_password_auth
                ;;
            5)
                echo "[+] 执行所有加固操作..."
                install_packages && \
                detect_ssh_port && \
                detect_proxy_ports && \
                get_current_ip && \
                configure_ufw "$DETECTED_SSH_PORT" "$DETECTED_TCP_PORTS" "$DETECTED_UDP_PORTS" && \
                configure_fail2ban "$CURRENT_IP" && \
                disable_password_auth
                if [ $? -eq 0 ]; then
                    echo "[✓] 所有加固操作执行完毕。"
                else
                    echo "[!] 部分加固操作失败，请检查上面的错误信息。"
                fi
                ;;
            q|Q)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                echo "[!] 无效选项，请输入 1-5 或 q。"
                ;;
        esac
        echo
        read -p "按 Enter键 返回主菜单..."
        clear # 清屏使菜单更清晰
    done
}
# --- 脚本入口 ---
# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份运行。"
    exit 1
fi
# 显示主菜单
main_menu