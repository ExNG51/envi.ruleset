#!/bin/bash
# 安全加固脚本 - 自动配置防火墙、fail2ban 及 SSH 强化
# --- 配置变量 ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
DETECTED_TCP_PORTS="" # 全局变量存储检测到的TCP端口
DETECTED_UDP_PORTS="" # 全局变量存储检测到的UDP端口
DETECTED_SSH_PORT=""  # 全局变量存储检测到的SSH端口
# --- 辅助函数 ---
# 检查上一条命令是否成功执行
# 参数: $1 - 命令描述
check_command_status() {
    if [ $? -ne 0 ]; then
        echo "[✗] 错误：执行 '$1' 失败。请检查错误信息并重试。" >&2
        # 在交互式菜单中，不直接退出，允许用户重试或选择其他选项
        # exit 1
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
        read -p "请输入您的公网 IP 地址（用于添加到白名单，留空则跳过）: " MANUAL_IP
        CURRENT_IP=$MANUAL_IP
    fi
    if [ -n "$CURRENT_IP" ]; then
        echo "[✓] 获取到 IP 地址: $CURRENT_IP (将尝试添加到白名单)"
    else
        echo "[!] 未提供 IP 地址，将不会自动添加到白名单。"
    fi
    # 不需要显式返回，CURRENT_IP 是全局可访问的（虽然不是最佳实践，但在此脚本中可行）
}
# 函数：安装必要的软件包
install_packages() {
    echo "[+] 正在更新系统并安装必要的软件包 (ufw, fail2ban, net-tools, lsof, curl, wget)..."
    apt update
    if ! apt install -y ufw fail2ban net-tools lsof curl wget; then
         echo "[✗] 软件包安装失败。请检查您的网络连接和包管理器配置。" >&2
         return 1
    fi
    echo "[✓] 软件包安装完成。"
    return 0
}
# 函数：检测当前 SSH 端口
detect_ssh_port() {
    echo "[+] 正在检测当前 SSH 端口..."
    # 从 sshd_config 文件中查找 Port 指令
    DETECTED_SSH_PORT=$(grep -i '^Port' "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    # 如果文件中没有明确指定，则默认为 22
    if [ -z "$DETECTED_SSH_PORT" ]; then
        DETECTED_SSH_PORT=22
        echo "[!] 未在 $SSH_CONFIG_FILE 中找到明确的端口设置，假定为默认端口 22。"
    fi
     # 进一步验证端口是否真的在监听 (可选但更健壮)
     if ! ss -tlnp | grep -q ":$DETECTED_SSH_PORT\s"; then
         echo "[!] 警告：检测到的 SSH 端口 $DETECTED_SSH_PORT 当前似乎没有被监听。"
         # 尝试从实际监听端口查找 sshd
         local listening_ssh_port=$(ss -tlpn | grep 'sshd' | grep -oP '(?<=:)\d+' | head -n 1)
         if [[ -n "$listening_ssh_port" && "$listening_ssh_port" != "$DETECTED_SSH_PORT" ]]; then
             echo "[!] 发现实际监听的 SSH 端口为 $listening_ssh_port。将使用此端口。"
             DETECTED_SSH_PORT=$listening_ssh_port
         elif [[ -z "$listening_ssh_port" ]]; then
              echo "[!] 无法确认实际监听的 SSH 端口。将继续使用配置中的端口 $DETECTED_SSH_PORT，但请注意防火墙规则可能不正确。"
         fi
     fi
    if [[ "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]]; then
        echo "[✓] 检测到 SSH 端口为: $DETECTED_SSH_PORT"
        return 0
    else
        echo "[✗] 错误：无法检测到有效的 SSH 端口。" >&2
        DETECTED_SSH_PORT="" # 清空无效值
        return 1
    fi
}
# 函数：检测代理端口 (Snell, Shadowsocks, Shadow TLS) - 使用关联数组优化版
detect_proxy_ports() {
    echo "[+] 正在检测代理服务使用的端口 (Snell, Shadowsocks, Shadow TLS)..."
    # 初始化关联数组
    declare -A TCP_PORTS # 存储 port -> process
    declare -A UDP_PORTS # 存储 port -> process
    local found_ports=false
    # 解析 ss 命令输出
    while IFS= read -r line; do
        # 提取协议 (tcp/udp)
        local protocol=$(echo "$line" | awk '{print $1}')
        # 提取监听地址和端口 (e.g., 0.0.0.0:8388 or [::]:8388)
        local listen_addr_port=$(echo "$line" | awk '{print $5}')
        # 使用 sed 提取端口号，兼容 IPv4/IPv6
        local port=$(echo "$listen_addr_port" | sed -n 's/.*:\([0-9]*\)/\1/p')
        # 提取进程信息 (e.g., users:(("ssserver",pid=1234,fd=5)))
        # 尝试从第7列获取进程信息，如果失败则尝试第6列
        local process_info=$(echo "$line" | awk '{print $7}')
        local process=$(echo "$process_info" | grep -oP '(?<=\(")[^"]+(?=",)')
        if [ -z "$process" ]; then
             process_info=$(echo "$line" | awk '{print $6}')
             process=$(echo "$process_info" | grep -oP '(?<=\(")[^"]+(?=",)')
        fi
        # 如果没有提取到进程名，给个默认值
        if [ -z "$process" ]; then
            process="未知进程"
        fi
        # 检查端口是否为有效数字
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            continue # 跳过无效端口
        fi
        if [ "$protocol" = "tcp" ]; then
            # 检查端口是否已在关联数组中
            if [[ -z "${TCP_PORTS[$port]}" ]]; then
               echo "  发现 TCP 端口 $port (进程: $process)"
               TCP_PORTS["$port"]="$process" # 存储端口和进程名
               found_ports=true
            fi
        elif [ "$protocol" = "udp" ]; then
             # 检查端口是否已在关联数组中
            if [[ -z "${UDP_PORTS[$port]}" ]]; then
                echo "  发现 UDP 端口 $port (进程: $process)"
                UDP_PORTS["$port"]="$process" # 存储端口和进程名
                found_ports=true
            fi
        fi
    done < <(ss -tulpn | grep -E 'snell|ss-|ssserver|shadow|tls') # 使用进程替换避免子shell问题
    # 将关联数组的键（端口号）转换为空格分隔的字符串
    DETECTED_TCP_PORTS="${!TCP_PORTS[*]}"
    DETECTED_UDP_PORTS="${!UDP_PORTS[*]}"
    if [ "$found_ports" = true ]; then
        echo "[✓] 代理端口检测完成。"
        if [ -n "$DETECTED_TCP_PORTS" ]; then
            echo "    将开放 TCP 端口: $DETECTED_TCP_PORTS"
        fi
        if [ -n "$DETECTED_UDP_PORTS" ]; then
            echo "    将开放 UDP 端口: $DETECTED_UDP_PORTS"
        fi
        return 0
    else
        echo "[!] 未检测到明确的代理服务监听端口。"
        # 这不一定是错误，可能用户没有运行这些服务
        return 0 # 仍然返回成功，因为函数本身执行没问题
    fi
    # 清理关联数组 (可选, 函数退出时会自动清理局部变量)
    # unset TCP_PORTS
    # unset UDP_PORTS
}
# 函数：配置 UFW 防火墙
# 参数: $1 - SSH 端口
#       $2 - TCP 代理端口列表 (空格分隔)
#       $3 - UDP 代理端口列表 (空格分隔)
configure_ufw() {
    local ssh_port="$1"
    local tcp_ports="$2"
    local udp_ports="$3"
    if [ -z "$ssh_port" ]; then
        echo "[✗] 错误：未提供有效的 SSH 端口，无法配置防火墙。" >&2
        return 1
    fi
    echo "[+] 正在配置 UFW 防火墙..."
    ufw --force reset # 强制重置规则
    check_command_status "UFW 重置" || return 1
    ufw default deny incoming
    check_command_status "设置默认入站策略为拒绝" || return 1
    ufw default allow outgoing
    check_command_status "设置默认出站策略为允许" || return 1
    echo "[+] 允许 SSH 端口 $ssh_port/tcp..."
    ufw allow "$ssh_port/tcp"
    check_command_status "允许 SSH 端口 $ssh_port/tcp" || return 1
    # 允许检测到的 TCP 代理端口
    if [ -n "$tcp_ports" ]; then
        echo "[+] 允许 TCP 代理端口: $tcp_ports..."
        for port in $tcp_ports; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow "$port/tcp"
                check_command_status "允许 TCP 端口 $port" # 逐个检查可能过于冗余，但更安全
            else
                 echo "[!] 警告：跳过无效的 TCP 端口 '$port'"
            fi
        done
    else
        echo "[i] 没有检测到需要开放的 TCP 代理端口。"
    fi
    # 允许检测到的 UDP 代理端口
    if [ -n "$udp_ports" ]; then
        echo "[+] 允许 UDP 代理端口: $udp_ports..."
        for port in $udp_ports; do
             if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow "$port/udp"
                check_command_status "允许 UDP 端口 $port"
             else
                 echo "[!] 警告：跳过无效的 UDP 端口 '$port'"
             fi
        done
    else
        echo "[i] 没有检测到需要开放的 UDP 代理端口。"
    fi
    # 允许 ICMP (Ping) - 可选，但通常有用
    echo "[+] 允许 ICMP (Ping)..."
    ufw allow icmp
    check_command_status "允许 ICMP"
    echo "[+] 正在启用 UFW 防火墙..."
    ufw enable
    # ufw enable 命令本身会进行交互确认，这里假设用户会输入 'y'
    # 检查状态可能需要解析 ufw status 的输出，暂时简化
    echo "[✓] UFW 配置完成。请使用 'sudo ufw status verbose' 查看状态。"
    return 0
}
# 函数：配置 Fail2ban
# 参数: $1 - 当前 IP (白名单)
#       $2 - SSH 端口
configure_fail2ban() {
    local current_ip="$1"
    local ssh_port="$2"
    if [ -z "$ssh_port" ]; then
        echo "[✗] 错误：未提供有效的 SSH 端口，无法配置 Fail2ban SSH jail。" >&2
        return 1
    fi
    echo "[+] 正在配置 Fail2ban..."
    # 确定 Fail2ban 日志路径 (常见路径)
    local ssh_logpath="/var/log/auth.log" # Debian/Ubuntu 默认
    if [ ! -f "$ssh_logpath" ]; then
        ssh_logpath="/var/log/secure" # CentOS/RHEL 默认
        if [ ! -f "$ssh_logpath" ]; then
             echo "[!] 警告：无法找到 SSH 日志文件 (尝试了 /var/log/auth.log 和 /var/log/secure)。请手动检查并配置 jail.local 中的 logpath。"
             ssh_logpath="请手动配置正确的 SSH 日志路径"
        fi
    fi
    # 构建 jail.local 内容
    local jail_content="[DEFAULT]
# 忽略的 IP 地址列表，包括本地回环和当前 IP
ignoreip = 127.0.0.1/8 ::1"
    # 只有当 current_ip 非空时才添加到 ignoreip
    if [ -n "$current_ip" ]; then
        jail_content="$jail_content $current_ip"
    fi
    jail_content="$jail_content
# 封禁时间（秒），1 小时
bantime = 3600
# 检测时间窗口（秒），10 分钟
findtime = 600
# 最大重试次数
maxretry = 5
# 后端，尝试自动检测 systemd
backend = auto"
    # 检查 systemd 是否在运行
    if systemctl is-active --quiet systemd-journald; then
         jail_content=$(echo "$jail_content" | sed 's/backend = auto/backend = systemd/')
    fi
    jail_content="$jail_content
# 封禁动作，使用 UFW
banaction = ufw
[sshd]
enabled = true
# 使用检测到的 SSH 端口
port = $ssh_port
# 使用检测到的日志路径
logpath = $ssh_logpath
# 更严格的 SSH 重试次数
maxretry = 3
# SSH 的封禁时间可以更长，例如 24 小时
# bantime = 86400
"
    echo "[+] 正在创建/覆盖 $FAIL2BAN_JAIL_LOCAL..."
    echo "$jail_content" > "$FAIL2BAN_JAIL_LOCAL"
    check_command_status "写入 Fail2ban 配置文件 $FAIL2BAN_JAIL_LOCAL" || return 1
    echo "[+] 正在重启 Fail2ban 服务..."
    systemctl restart fail2ban
    check_command_status "重启 Fail2ban 服务" || return 1
    echo "[✓] Fail2ban 配置完成。请使用 'sudo fail2ban-client status sshd' 查看状态。"
    return 0
}
# 函数：禁用 SSH 密码认证
disable_password_auth() {
    echo "[!] 警告：禁用密码认证将要求您使用 SSH 密钥进行登录。"
    echo "    请确保您已经配置好 SSH 密钥，并且可以通过密钥成功登录。"
    read -p "    您确定要继续禁用密码认证吗？ (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "[i] 操作已取消。"
        return 1
    fi
    echo "[+] 正在禁用 SSH 密码认证..."
    # 备份原始配置文件
    cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    check_command_status "备份 SSH 配置文件" || return 1
    # 禁用 PasswordAuthentication
    if grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' "$SSH_CONFIG_FILE"; then
        # 如果存在则修改
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG_FILE"
    else
        # 如果不存在则添加
        echo "PasswordAuthentication no" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 PasswordAuthentication no" || return 1
    # 确保 ChallengeResponseAuthentication 也被禁用（通常与密码认证相关）
     if grep -qE '^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication' "$SSH_CONFIG_FILE"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG_FILE"
    else
        echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG_FILE"
    fi
    check_command_status "设置 ChallengeResponseAuthentication no" || return 1
    # 确保 UsePAM 设置允许密钥登录（如果 UsePAM yes，需要 pam 配置支持）
    # 通常保持 UsePAM yes 是可以的，但如果遇到问题可以尝试设置为 no
    # 这里我们不主动修改 UsePAM，除非用户明确要求或遇到问题
    # if grep -qE '^[[:space:]]*#?[[:space:]]*UsePAM' "$SSH_CONFIG_FILE"; then
    #     sed -i -E 's/^[[:space:]]*#?[[:space:]]*UsePAM.*/UsePAM yes/' "$SSH_CONFIG_FILE" # 或者 no
    # else
    #     echo "UsePAM yes" >> "$SSH_CONFIG_FILE" # 或者 no
    # fi
    # check_command_status "确保 UsePAM 设置" || return 1
    echo "[+] 正在重新加载 SSH 服务配置..."
    systemctl reload sshd
    check_command_status "重新加载 SSH 服务 (sshd)" || {
        echo "[!] SSH 服务重载失败。配置可能存在语法错误。" >&2
        echo "    请手动检查 $SSH_CONFIG_FILE 文件。" >&2
        echo "    您可以尝试使用 'sshd -t' 命令测试配置文件。" >&2
        echo "    之前的备份文件是 ${SSH_CONFIG_FILE}.bak_*" >&2
        return 1
    }
    echo "[✓] SSH 密码认证已禁用。请务必测试 SSH 密钥登录！"
    return 0
}
# --- 主逻辑 ---
# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份运行。"
    exit 1
fi
# 显示欢迎信息
echo "=========================================================="
echo "              系统安全加固脚本 (调整版 v3)              "
echo "=========================================================="
echo
# --- 预检查和信息获取 ---
get_current_ip # 获取当前 IP
echo # 空行
if ! install_packages; then # 安装依赖
    echo "[✗] 关键软件包安装失败，无法继续。请解决安装问题后重试。" >&2
    exit 1
fi
echo # 空行
if ! detect_ssh_port; then # 检测 SSH 端口
    echo "[✗] 无法确定 SSH 端口，某些功能将无法正常工作。" >&2
    # 可以选择退出或继续，这里选择继续但后续功能会受影响
fi
echo # 空行
detect_proxy_ports # 检测代理端口
echo # 空行
# --- 交互式菜单 ---
while true; do
    echo "请选择要执行的操作:"
    echo "  1) 配置 UFW 防火墙"
    echo "  2) 配置 Fail2ban"
    echo "  3) 禁用 SSH 密码认证 (请确保已设置 SSH 密钥!)"
    echo "  4) 执行以上所有加固操作 (1, 2, 3)"
    echo "  5) 重新检测端口 (SSH 和代理)"
    echo "  q) 退出脚本"
    read -p "请输入选项 [1-5, q]: " choice
    case $choice in
        1)
            if [ -z "$DETECTED_SSH_PORT" ]; then
                 echo "[!] 需要先成功检测到 SSH 端口才能配置 UFW。"
                 detect_ssh_port # 尝试再次检测
            fi
            if [ -n "$DETECTED_SSH_PORT" ]; then
                 # 传递检测到的端口给 UFW 配置函数
                 configure_ufw "$DETECTED_SSH_PORT" "$DETECTED_TCP_PORTS" "$DETECTED_UDP_PORTS"
            else
                 echo "[✗] 无法配置 UFW，因为 SSH 端口未知。"
            fi
            ;;
        2)
             if [ -z "$DETECTED_SSH_PORT" ]; then
                 echo "[!] 需要先成功检测到 SSH 端口才能配置 Fail2ban。"
                 detect_ssh_port # 尝试再次检测
            fi
             if [ -n "$DETECTED_SSH_PORT" ]; then
                # 传递当前 IP 和 SSH 端口给 Fail2ban 配置函数
                configure_fail2ban "$CURRENT_IP" "$DETECTED_SSH_PORT"
             else
                 echo "[✗] 无法配置 Fail2ban，因为 SSH 端口未知。"
             fi
            ;;
        3)
            disable_password_auth
            ;;
        4)
            echo "[+] 执行所有加固操作..."
            all_success=true
            echo "--- 步骤 1: 配置 UFW ---"
            if [ -z "$DETECTED_SSH_PORT" ]; then detect_ssh_port; fi
            if [ -n "$DETECTED_SSH_PORT" ]; then
                 configure_ufw "$DETECTED_SSH_PORT" "$DETECTED_TCP_PORTS" "$DETECTED_UDP_PORTS" || all_success=false
            else
                 echo "[✗] 跳过 UFW 配置，因为 SSH 端口未知。"
                 all_success=false
            fi
            echo # 空行
            echo "--- 步骤 2: 配置 Fail2ban ---"
            if [ -z "$DETECTED_SSH_PORT" ]; then detect_ssh_port; fi
             if [ -n "$DETECTED_SSH_PORT" ]; then
                configure_fail2ban "$CURRENT_IP" "$DETECTED_SSH_PORT" || all_success=false
             else
                 echo "[✗] 跳过 Fail2ban 配置，因为 SSH 端口未知。"
                 all_success=false
             fi
            echo # 空行
            echo "--- 步骤 3: 禁用 SSH 密码认证 ---"
            disable_password_auth || all_success=false
            echo # 空行
            if [ "$all_success" = true ]; then
                echo "[✓] 所有加固操作已成功完成（或已取消）。"
            else
                echo "[!] 部分加固操作失败或被跳过。请检查上面的输出。"
            fi
            ;;
        5)
            echo "[+] 重新检测端口..."
            detect_ssh_port
            echo # 空行
            detect_proxy_ports
            echo # 空行
            ;;
        q|Q)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请输入 1-5 或 q。"
            ;;
    esac
    echo # 每个选项执行后加空行
    read -p "按 Enter键 继续..." # 暂停，让用户看清输出
    echo # 清屏或换行，准备下一次菜单显示
    # clear # 取消注释此行可以在每次循环后清屏
done
exit 0