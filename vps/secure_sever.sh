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

# --- 颜色定义 ---
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'

# --- 辅助函数 ---
# 检查上一条命令是否成功执行
# 参数: $1 - 命令描述
check_command_status() {
    local description=$1
    if [ $? -ne 0 ]; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 执行 '${description}' 失败。请检查错误信息并重试。${RESET}" >&2
        return 1 # 返回失败状态
    else
        echo -e "${GREEN}${BOLD}[✓] 成功:${RESET}${GREEN} '${description}' 执行完毕。${RESET}"
        return 0 # 返回成功状态
    fi
}

# 获取当前外部 IP 地址
get_current_ip() {
    echo -e "${BLUE}${BOLD}[+] 正在获取当前外部 IP 地址...${RESET}"
    CURRENT_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
    if [ -z "$CURRENT_IP" ]; then
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 无法自动获取当前 IP 地址。${RESET}"
        read -p "$(echo -e ${YELLOW}${BOLD}"[?] 请手动输入您当前的外部 IP 地址 (留空则不添加白名单): "${RESET})" CURRENT_IP
        if [ -n "$CURRENT_IP" ]; then
             echo -e "${GREEN}[✓] 您输入的 IP 地址: ${CYAN}${BOLD}$CURRENT_IP${RESET}"
        fi
    else
        echo -e "${GREEN}${BOLD}[✓] 检测到当前外部 IP 地址: ${CYAN}${BOLD}$CURRENT_IP${RESET}"
    fi
    echo "----------------------------------------"
}

# 尝试自动查找 SSH 日志文件或确定合适的 Fail2ban 后端
# 设置全局变量: SSH_LOG_PATH 和 FAIL2BAN_BACKEND
find_ssh_log_or_backend() {
    echo -e "${BLUE}${BOLD}[+] 正在尝试自动检测 SSH 日志位置或 Fail2ban 后端...${RESET}"
    SSH_LOG_PATH="" # 重置
    FAIL2BAN_BACKEND="auto" # 默认值
    local found=false
    # 优先检查 systemd journal
    if command -v journalctl &> /dev/null; then
        if journalctl -u sshd --no-pager --quiet &> /dev/null; then
            echo -e "${GREEN}${BOLD}[✓] 检测到 systemd journal 管理 SSH 日志 (sshd)。将使用 '${MAGENTA}systemd${GREEN}' 后端。${RESET}"
            FAIL2BAN_BACKEND="systemd"
            SSH_LOG_PATH="using systemd backend"
            found=true
        elif journalctl -u ssh --no-pager --quiet &> /dev/null; then
            echo -e "${GREEN}${BOLD}[✓] 检测到 systemd journal 管理 SSH 日志 (ssh)。将使用 '${MAGENTA}systemd${GREEN}' 后端。${RESET}"
            FAIL2BAN_BACKEND="systemd"
            SSH_LOG_PATH="using systemd backend"
            found=true
        fi
    fi

    # 如果未使用 systemd 或 journalctl 无法查询，则检查传统日志文件
    if ! $found; then
        if [ -f "/var/log/auth.log" ]; then
            if grep -q "sshd" /var/log/auth.log &> /dev/null; then
                 echo -e "${GREEN}${BOLD}[✓] 检测到 SSH 日志文件: ${CYAN}/var/log/auth.log${RESET}"
                 SSH_LOG_PATH="/var/log/auth.log"
                 FAIL2BAN_BACKEND="auto" # 或者 pyinotify, gamin
                 found=true
            fi
        fi
    fi
    if ! $found; then
        if [ -f "/var/log/secure" ]; then
             if grep -q "sshd" /var/log/secure &> /dev/null; then
                echo -e "${GREEN}${BOLD}[✓] 检测到 SSH 日志文件: ${CYAN}/var/log/secure${RESET}"
                SSH_LOG_PATH="/var/log/secure"
                FAIL2BAN_BACKEND="auto" # 或者 pyinotify, gamin
                found=true
             fi
        fi
    fi

    if ! $found; then
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 无法自动确定 SSH 日志文件路径或 systemd 后端。${RESET}"
        echo -e "${YELLOW}    Fail2ban 配置将使用默认设置，可能需要您手动调整 '${CYAN}${FAIL2BAN_JAIL_LOCAL}${YELLOW}' 中的 'backend' 和 'logpath'。${RESET}"
        return 1 # 表示未成功检测到特定路径
    fi
    echo "----------------------------------------"
    return 0
}

# 检测 SSH 端口
detect_ssh_port() {
    echo -e "${BLUE}${BOLD}[+] 正在检测当前 SSH 端口...${RESET}"
    DETECTED_SSH_PORT="" # 重置以防万一
    # 尝试从 sshd_config 获取
    if [ -f "$SSH_CONFIG_FILE" ]; then
        DETECTED_SSH_PORT=$(grep -iE '^\s*Port\s+' "$SSH_CONFIG_FILE" | awk '{print $2}' | head -n 1)
    fi

    # 如果 sshd_config 中未明确指定或找不到文件，尝试从当前监听端口获取
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${YELLOW}[!] 未在 ${CYAN}$SSH_CONFIG_FILE${YELLOW} 中找到明确端口，尝试检测监听端口...${RESET}"
        # 尝试使用 ss (推荐)
        if command -v ss &> /dev/null; then
            DETECTED_SSH_PORT=$(ss -tlpn 'sport = :*' 2>/dev/null | grep 'sshd' | awk '{print $4}' | cut -d ':' -f 2 | head -n 1)
        # 备选 netstat
        elif command -v netstat &> /dev/null; then
             DETECTED_SSH_PORT=$(netstat -tlpn 2>/dev/null | grep 'sshd' | awk '{print $4}' | cut -d ':' -f 2 | head -n 1)
        fi
    fi

    # 最后确认
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 无法自动检测到 SSH 端口。将假定为标准端口 ${CYAN}22${YELLOW}。${RESET}"
        DETECTED_SSH_PORT="22"
    else
        echo -e "${GREEN}${BOLD}[✓] 检测到 SSH 端口: ${CYAN}${BOLD}$DETECTED_SSH_PORT${RESET}"
    fi
    echo "----------------------------------------"
}

# 检测常用代理工具监听的端口 (示例)
detect_proxy_ports() {
    echo -e "${BLUE}${BOLD}[+] 正在检测常用代理工具端口 (TCP/UDP)...${RESET}"
    local proxy_ports_tcp=""
    local proxy_ports_udp=""
    local grep_pattern='snell|ss-|ssserver|shadow|tls|v2ray|trojan' # 定义检测模式

    # 使用 ss 命令查找监听 TCP/UDP 端口的进程
    if command -v ss &> /dev/null; then
        proxy_ports_tcp=$(ss -tlpn 2>/dev/null | awk 'NR>1{print $4}' | sed -n 's/.*:\([0-9]*\)/\1/p' | xargs -r -I{} sh -c "ss -tlpn 2>/dev/null | grep ':{} ' | grep -E '$grep_pattern' > /dev/null && echo {}" | sort -un | tr '\n' ' ')
        proxy_ports_udp=$(ss -ulpn 2>/dev/null | awk 'NR>1{print $4}' | sed -n 's/.*:\([0-9]*\)/\1/p' | xargs -r -I{} sh -c "ss -ulpn 2>/dev/null | grep ':{} ' | grep -E '$grep_pattern' > /dev/null && echo {}" | sort -un | tr '\n' ' ')
    elif command -v netstat &> /dev/null; then
         # 使用 netstat 作为备选
         proxy_ports_tcp=$(netstat -tlpn 2>/dev/null | grep -E "$grep_pattern" | awk '{print $4}' | sed -n 's/.*:\([0-9]*\)/\1/p' | sort -un | tr '\n' ' ')
         proxy_ports_udp=$(netstat -ulpn 2>/dev/null | grep -E "$grep_pattern" | awk '{print $4}' | sed -n 's/.*:\([0-9]*\)/\1/p' | sort -un | tr '\n' ' ')
    else
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 'ss' 和 'netstat' 命令都不可用，无法自动检测代理端口。${RESET}"
    fi

    if [ -n "$proxy_ports_tcp" ]; then
        echo -e "${GREEN}${BOLD}[✓] 检测到潜在的代理 TCP 端口: ${CYAN}${proxy_ports_tcp}${RESET}"
        DETECTED_TCP_PORTS+="$proxy_ports_tcp " # 追加到全局变量
    else
        echo -e "${BLUE}[-] 未检测到与模式 (${MAGENTA}$grep_pattern${BLUE}) 匹配的常用代理 TCP 端口。${RESET}"
    fi
     if [ -n "$proxy_ports_udp" ]; then
        echo -e "${GREEN}${BOLD}[✓] 检测到潜在的代理 UDP 端口: ${CYAN}${proxy_ports_udp}${RESET}"
        DETECTED_UDP_PORTS+="$proxy_ports_udp " # 追加到全局变量
    else
        echo -e "${BLUE}[-] 未检测到与模式 (${MAGENTA}$grep_pattern${BLUE}) 匹配的常用代理 UDP 端口。${RESET}"
    fi
    # 去重
    DETECTED_TCP_PORTS=$(echo "$DETECTED_TCP_PORTS" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    DETECTED_UDP_PORTS=$(echo "$DETECTED_UDP_PORTS" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    echo "----------------------------------------"
}

# --- 主要功能函数 ---
# 1. 安装必要的软件包
install_packages() {
    echo -e "\n${MAGENTA}==================== 步骤 1: 安装软件包 ====================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 正在更新软件包列表并安装 UFW, Fail2ban 及依赖...${RESET}"
    apt update -y > /dev/null 2>&1 # 静默更新
    check_command_status "软件包列表更新 (apt update)" || return 1
    # 添加 net-tools 以防 ss 不可用, iproute2 包含 ss 命令
    apt install -y ufw fail2ban curl wget net-tools iproute2 > /dev/null 2>&1 # 静默安装
    check_command_status "安装 ${CYAN}ufw, fail2ban, curl, wget, net-tools, iproute2${RESET}" || return 1
    echo -e "${GREEN}${BOLD}[✓] 软件包安装完成。${RESET}"
    echo -e "${MAGENTA}===========================================================${RESET}"
}

# 2. 配置 UFW 防火墙
configure_ufw() {
    echo -e "\n${MAGENTA}==================== 步骤 2: 配置 UFW 防火墙 ================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 开始配置 UFW 防火墙...${RESET}"
    # 检测 SSH 和代理端口
    detect_ssh_port
    detect_proxy_ports

    # 确保 ufw 已安装
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} UFW 命令不可用。请先运行安装步骤 (选项 1)。${RESET}"
        return 1
    fi

    # 重置 UFW 到默认状态
    echo -e "${YELLOW}${BOLD}[!] 注意:${RESET}${YELLOW} 即将重置 UFW 规则为默认状态...${RESET}"
    echo "y" | ufw reset > /dev/null
    check_command_status "重置 UFW 规则" || return 1

    # 设置默认策略
    echo -e "${BLUE}[+] 设置默认策略: ${BOLD}拒绝入站${RESET}${BLUE}, ${BOLD}允许出站${RESET}${BLUE}...${RESET}"
    ufw default deny incoming > /dev/null
    check_command_status "设置默认入站策略 (deny incoming)" || return 1
    ufw default allow outgoing > /dev/null
    check_command_status "设置默认出站策略 (allow outgoing)" || return 1

    # 允许 SSH 端口
    if [ -n "$DETECTED_SSH_PORT" ]; then
        echo -e "${BLUE}[+] 允许 SSH 端口 ${CYAN}${BOLD}$DETECTED_SSH_PORT${BLUE}/tcp...${RESET}"
        ufw allow "$DETECTED_SSH_PORT"/tcp comment 'Allow SSH access' > /dev/null
        check_command_status "允许 SSH 端口 $DETECTED_SSH_PORT/tcp" || return 1
    else
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 无法获取 SSH 端口，无法添加 UFW 规则。${RESET}" >&2
        return 1 # SSH 是关键
    fi

    # 允许检测到的代理 TCP 端口
    if [ -n "$DETECTED_TCP_PORTS" ]; then
        echo -e "${BLUE}[+] 允许检测到的 TCP 端口: ${CYAN}${DETECTED_TCP_PORTS}${RESET}"
        for port in $DETECTED_TCP_PORTS; do
            ufw allow "$port"/tcp comment 'Allow detected TCP service' > /dev/null
            check_command_status "允许 TCP 端口 $port/tcp" || return 1
        done
    fi

    # 允许检测到的代理 UDP 端口
    if [ -n "$DETECTED_UDP_PORTS" ]; then
         echo -e "${BLUE}[+] 允许检测到的 UDP 端口: ${CYAN}${DETECTED_UDP_PORTS}${RESET}"
        for port in $DETECTED_UDP_PORTS; do
            ufw allow "$port"/udp comment 'Allow detected UDP service' > /dev/null
            check_command_status "允许 UDP 端口 $port/udp" || return 1
        done
    fi

    # 允许本地回环接口
    echo -e "${BLUE}[+] 允许本地回环 (lo) 接口流量...${RESET}"
    ufw allow in on lo > /dev/null
    check_command_status "允许本地回环入站 (lo in)" || return 1
    ufw allow out on lo > /dev/null
    check_command_status "允许本地回环出站 (lo out)" || return 1

    # 添加当前 IP 到白名单
    if [ -n "$CURRENT_IP" ]; then
        echo -e "${BLUE}[+] 将当前 IP ${CYAN}${BOLD}$CURRENT_IP${BLUE} 添加到 SSH 端口白名单...${RESET}"
        ufw allow from "$CURRENT_IP" to any port "$DETECTED_SSH_PORT" proto tcp comment 'Current IP Whitelist (SSH)' > /dev/null
        check_command_status "添加当前 IP $CURRENT_IP 到 SSH 白名单" || return 1
    fi

    # 启用 UFW
    echo -e "${BLUE}${BOLD}[+] 正在启用 UFW 防火墙...${RESET}"
    echo "y" | ufw enable > /dev/null
    check_command_status "启用 UFW" || return 1

    echo -e "${GREEN}${BOLD}[✓] UFW 配置完成并已启用。${RESET}"
    echo -e "${BLUE}${BOLD}[+] 当前 UFW 状态:${RESET}"
    ufw status verbose # 显示详细状态
    echo -e "${MAGENTA}===========================================================${RESET}"
}

# 3. 配置 Fail2ban
configure_fail2ban() {
    echo -e "\n${MAGENTA}==================== 步骤 3: 配置 Fail2ban ==================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 开始配置 Fail2ban...${RESET}"
    # 确保 fail2ban 已安装
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} Fail2ban 命令不可用。请先运行安装步骤 (选项 1)。${RESET}"
        return 1
    fi
     # 确保 SSH 端口已检测
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] 未检测到 SSH 端口，尝试现在检测...${RESET}"
        detect_ssh_port
        if [ -z "$DETECTED_SSH_PORT" ]; then
             echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 无法检测 SSH 端口，无法继续配置 Fail2ban。${RESET}" >&2
             return 1
        fi
    fi

    # 自动检测 SSH 日志或后端
    find_ssh_log_or_backend || echo -e "${YELLOW}[!] 继续使用 Fail2ban 默认日志检测机制。${RESET}" # 如果检测失败，提示一下

    # 创建 jail.local 配置文件
    echo -e "${BLUE}[+] 正在创建 Fail2ban 配置文件 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${BLUE}...${RESET}"
    cat > "$FAIL2BAN_JAIL_LOCAL" << EOF
[DEFAULT]
# 默认禁止时间 (30 天)
bantime = 30d
# 在多少时间内达到最大重试次数则封禁 (5 分钟)
findtime = 5m
# 最大重试次数
maxretry = 3
# 忽略的 IP 地址，可以是单个 IP、CIDR 或 DNS 主机名
# 将当前 IP 加入白名单 (如果获取到)
ignoreip = 127.0.0.1/8 ::1 ${CURRENT_IP:-}
# 后端设置 (根据检测结果设置)
backend = ${FAIL2BAN_BACKEND}
# 使用 ufw 作防火墙操作
banaction = ufw

[sshd]
enabled = true
port = ${DETECTED_SSH_PORT:-ssh} # 使用检测到的端口，若未检测到则使用默认 'ssh'
filter = sshd
# 日志路径 (如果检测到特定文件路径则使用，否则留空让 fail2ban 使用默认或 systemd 后端)
EOF
    # 添加 logpath (如果需要)
    local logpath_display="" # 用于后续输出显示
    if [ -n "$SSH_LOG_PATH" ] && [ "$SSH_LOG_PATH" != "using systemd backend" ]; then
        echo "logpath = $SSH_LOG_PATH" >> "$FAIL2BAN_JAIL_LOCAL"
        echo -e "${BLUE}[i] 使用检测到的日志路径: ${CYAN}$SSH_LOG_PATH${RESET}"
        logpath_display="${CYAN}$SSH_LOG_PATH${RESET}"
    elif [ "$FAIL2BAN_BACKEND" != "systemd" ] && [ -z "$SSH_LOG_PATH" ]; then # 明确检测失败的情况
         echo "# logpath = %(sshd_log)s  # 自动检测失败，请根据系统检查并取消注释或修改" >> "$FAIL2BAN_JAIL_LOCAL"
         echo -e "${YELLOW}[i] 未能自动检测日志路径，请在 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${YELLOW} 中检查 'logpath'。${RESET}"
         logpath_display="${YELLOW}(自动检测失败，使用 Fail2ban 默认或需手动设置)${RESET}"
    elif [ "$FAIL2BAN_BACKEND" == "systemd" ]; then
        echo -e "${BLUE}[i] 使用 systemd 后端，无需设置 logpath。${RESET}"
        logpath_display="${MAGENTA}(使用 systemd journal，无需显式设置)${RESET}"
    fi

    check_command_status "创建/更新 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${RESET}" || return 1

    # --- 显示配置参数 ---
    echo -e "${BLUE}${BOLD}\n[+] Fail2ban (${CYAN}${FAIL2BAN_JAIL_LOCAL}${BLUE}) 配置摘要:${RESET}"
    echo -e "  ${MAGENTA}[DEFAULT]${RESET}"
    echo -e "    ${CYAN}bantime${RESET}  = 30d"
    echo -e "    ${CYAN}findtime${RESET} = 5m"
    echo -e "    ${CYAN}maxretry${RESET} = 3"
    # 处理 CURRENT_IP 为空的情况
    local current_ip_display="${CURRENT_IP}"
    if [ -z "$current_ip_display" ]; then
        current_ip_display="${YELLOW}(未自动获取或手动输入)${RESET}"
    else
        current_ip_display="${CYAN}${BOLD}${current_ip_display}${RESET}"
    fi
    echo -e "    ${CYAN}ignoreip${RESET} = 127.0.0.1/8 ::1 ${current_ip_display}"
    echo -e "    ${CYAN}backend${RESET}  = ${MAGENTA}${FAIL2BAN_BACKEND}${RESET}"
    echo -e "    ${CYAN}banaction${RESET}= ufw"
    echo -e "  ${MAGENTA}[sshd]${RESET}"
    echo -e "    ${CYAN}enabled${RESET}  = true"
    echo -e "    ${CYAN}port${RESET}     = ${CYAN}${DETECTED_SSH_PORT:-ssh}${RESET}"
    echo -e "    ${CYAN}filter${RESET}   = sshd"
    echo -e "    ${CYAN}logpath${RESET}  = ${logpath_display}" # 使用前面处理好的 logpath 显示内容
    echo "----------------------------------------"
    # --- 显示结束 ---

    # 重启 Fail2ban 服务
    echo -e "${BLUE}${BOLD}[+] 正在重启 Fail2ban 服务...${RESET}"
    systemctl restart fail2ban
    if ! check_command_status "重启 Fail2ban 服务"; then
        echo -e "${RED}${BOLD}[!] Fail2ban 服务重启命令失败。请检查服务日志 (${CYAN}journalctl -u fail2ban${RED} 或 ${CYAN}/var/log/fail2ban.log${RED})。${RESET}"
        return 1
    fi

    # --- 验证 Fail2ban 服务状态 ---
    echo -e "${BLUE}[+] 正在验证 Fail2ban 服务状态...${RESET}"
    sleep 2 # 等待服务启动
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}${BOLD}[✓] Fail2ban 服务处于活动状态。${RESET}"
        echo -e "${BLUE}[+] 设置 Fail2ban 开机自启...${RESET}"
        systemctl enable fail2ban > /dev/null 2>&1
        check_command_status "设置 Fail2ban 开机自启" # 这里如果失败只是警告，不中断
        echo -e "${GREEN}${BOLD}[✓] Fail2ban 配置完成并已启动。${RESET}"
        # 显示状态
        echo -e "${BLUE}${BOLD}[+] 当前 Fail2ban SSH jail 状态:${RESET}"
        fail2ban-client status sshd
    else
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} Fail2ban 服务未能成功启动！${RESET}" >&2
        echo -e "${RED}[!] 请检查 Fail2ban 的配置 (${CYAN}${FAIL2BAN_JAIL_LOCAL}${RED}) 和系统日志 (${CYAN}journalctl -u fail2ban${RED} 或 ${CYAN}/var/log/fail2ban.log${RED}) 以获取详细错误信息。${RESET}" >&2
        return 1 # 返回失败状态
    fi
    # --- 验证结束 ---
    echo -e "${MAGENTA}===========================================================${RESET}"
}


# 4. 强化 SSH 配置
secure_ssh() {
    echo -e "\n${MAGENTA}==================== 步骤 4: 强化 SSH 配置 ==================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 开始强化 SSH 配置 (${CYAN}${SSH_CONFIG_FILE}${BLUE})...${RESET}"
    # 确保 SSH 配置文件存在
    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} SSH 配置文件 ${CYAN}$SSH_CONFIG_FILE${RED} 未找到。${RESET}" >&2
        return 1
    fi

    local backup_file="${SSH_CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    # 备份原始配置文件
    echo -e "${BLUE}[+] 备份当前 SSH 配置文件到 ${CYAN}${backup_file}${BLUE}...${RESET}"
    cp "$SSH_CONFIG_FILE" "$backup_file"
    check_command_status "备份 SSH 配置文件" || return 1

    # 应用安全设置
    local success=true
    local changes_made=false # 标记是否有实际修改

    # 禁用 Root 登录
    read -p "$(echo -e ${YELLOW}${BOLD}"[?] 是否要尝试禁用 Root 账户通过 SSH 登录? (y/N): "${RESET})" disable_root_login
    if [[ "$disable_root_login" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}[+] 正在检查禁用 Root 登录的安全性...${RESET}"
        # 查找 sudo 组中的非 root 用户
        local sudo_users=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' || true)
        # 也可以检查 /etc/sudoers.d/ 文件中的用户，但 getent group 更简单通用
        if [ -z "$sudo_users" ]; then
            # 如果没有找到其他 sudo 用户
            echo -e "${RED}${BOLD}[✗] 安全检查失败!${RESET}${RED} 未找到其他具有 sudo 权限的用户。${RESET}"
            echo -e "${RED}    为了防止您被锁定在服务器之外，脚本无法自动禁用 Root 登录。${RESET}"
            echo -e "${YELLOW}    请先手动创建一个具有 sudo 权限的新用户，并确保可以使用该用户登录，然后再尝试禁用 Root 登录。${RESET}"
            success=false # 阻止后续执行
        else
            # 找到其他 sudo 用户，进行二次确认
            echo -e "${YELLOW}${BOLD}[!] 安全警告!${RESET}${YELLOW} 检测到以下可能具有 sudo 权限的用户:${RESET}"
            echo -e "${CYAN}${sudo_users}${RESET}" # 列出找到的用户
            echo -e "${YELLOW}    在禁用 Root 登录之前，${BOLD}请务必确认您可以使用上述至少一个用户通过 SSH 成功登录，并且该用户拥有 sudo 权限${RESET}${YELLOW}，否则您将无法管理服务器！${RESET}"
            read -p "$(echo -e ${YELLOW}${BOLD}"[?] 您是否已确认并理解风险，确实要继续禁用 Root 登录? (y/N): "${RESET})" confirm_disable_root
            if [[ "$confirm_disable_root" =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}[+] 设置 Root 禁止登录 (PermitRootLogin no)...${RESET}"
                if ! grep -qE "^\s*PermitRootLogin\s+no" "$SSH_CONFIG_FILE"; then
                    sed -i -E 's/^\s*#?\s*PermitRootLogin\s+.*/PermitRootLogin no/' "$SSH_CONFIG_FILE"
                    if ! grep -qE "^\s*PermitRootLogin\s+no" "$SSH_CONFIG_FILE"; then
                        echo "PermitRootLogin no" >> "$SSH_CONFIG_FILE"
                    fi
                    check_command_status "设置 PermitRootLogin no" || success=false
                    changes_made=true
                else
                    echo -e "${BLUE}[-] PermitRootLogin 已设置为 no，无需修改。${RESET}"
                fi
            else
                echo -e "${YELLOW}[-] 取消禁用 Root 登录。${RESET}"
                # success 保持 true，允许继续执行后续 SSH 配置
            fi
        fi
    else
         echo -e "${BLUE}[i] 跳过禁用 Root 登录的设置。${RESET}"
    fi
    echo "---"


    # 禁用密码认证
    if $success; then # 只有在前面的步骤没有明确失败时才继续
        read -p "$(echo -e ${YELLOW}${BOLD}"[?] 是否禁用 SSH 密码认证，强制使用密钥登录? (强烈推荐 'y') (y/N): "${RESET})" disable_password_auth
        if [[ "$disable_password_auth" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}[+] 禁用密码认证 (PasswordAuthentication no)...${RESET}"
            local pw_auth_changed=false
            if ! grep -qE "^\s*PasswordAuthentication\s+no" "$SSH_CONFIG_FILE"; then
                sed -i -E 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' "$SSH_CONFIG_FILE"
                if ! grep -qE "^\s*PasswordAuthentication\s+no" "$SSH_CONFIG_FILE"; then
                   echo "PasswordAuthentication no" >> "$SSH_CONFIG_FILE"
                fi
                check_command_status "设置 PasswordAuthentication no" || success=false
                changes_made=true
                pw_auth_changed=true
            else
                echo -e "${BLUE}[-] PasswordAuthentication 已设置为 no，无需修改。${RESET}"
            fi

            if $success; then
                 echo -e "${BLUE}[+] 禁用 ChallengeResponseAuthentication (no)...${RESET}"
                 local chal_resp_changed=false
                 if ! grep -qE "^\s*#?\s*ChallengeResponseAuthentication\s+no" "$SSH_CONFIG_FILE"; then
                    sed -i -E 's/^\s*#?\s*ChallengeResponseAuthentication\s+.*/ChallengeResponseAuthentication no/' "$SSH_CONFIG_FILE"
                     if ! grep -qE "^\s*ChallengeResponseAuthentication\s+no" "$SSH_CONFIG_FILE"; then
                         echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG_FILE"
                     fi
                    check_command_status "设置 ChallengeResponseAuthentication no" || success=false
                    changes_made=true
                    chal_resp_changed=true
                 else
                    echo -e "${BLUE}[-] ChallengeResponseAuthentication 已设置为 no，无需修改。${RESET}"
                 fi
            fi
            if $success && ($pw_auth_changed || $chal_resp_changed); then # 只有当真正修改了才提示
                echo -e "${GREEN}${BOLD}[✓] 已禁用密码认证。${YELLOW}请确保您已配置 SSH 密钥！${RESET}"
            fi
        else
            echo -e "${YELLOW}[-] 跳过禁用密码认证。${BOLD}(为了安全，强烈建议使用密钥登录)${RESET}"
        fi
    fi
    echo "---"

    # 限制最大认证尝试次数
    if $success; then
        echo -e "${BLUE}[+] 设置最大认证尝试次数 (MaxAuthTries 3)...${RESET}"
        if ! grep -qE "^\s*MaxAuthTries\s+3" "$SSH_CONFIG_FILE"; then
            if grep -qE '^\s*#?\s*MaxAuthTries' "$SSH_CONFIG_FILE"; then
                sed -i -E 's/^\s*#?\s*MaxAuthTries\s+.*/MaxAuthTries 3/' "$SSH_CONFIG_FILE"
            else
                echo "MaxAuthTries 3" >> "$SSH_CONFIG_FILE"
            fi
            check_command_status "设置 MaxAuthTries 3" || success=false
            changes_made=true
        else
            echo -e "${BLUE}[-] MaxAuthTries 已设置为 3，无需修改。${RESET}"
        fi
    fi
    echo "---"

    # 启用 TCPKeepAlive
    if $success; then
         echo -e "${BLUE}[+] 启用 TCPKeepAlive (TCPKeepAlive yes)...${RESET}"
         if ! grep -qE "^\s*TCPKeepAlive\s+yes" "$SSH_CONFIG_FILE"; then
             if grep -qE '^\s*#?\s*TCPKeepAlive' "$SSH_CONFIG_FILE"; then
                sed -i -E 's/^\s*#?\s*TCPKeepAlive\s+.*/TCPKeepAlive yes/' "$SSH_CONFIG_FILE"
            else
                echo "TCPKeepAlive yes" >> "$SSH_CONFIG_FILE"
            fi
            check_command_status "设置 TCPKeepAlive yes" || success=false
            changes_made=true
         else
            echo -e "${BLUE}[-] TCPKeepAlive 已设置为 yes，无需修改。${RESET}"
         fi
    fi
    echo "---"

    # 设置 ClientAliveInterval
    if $success; then
        echo -e "${BLUE}[+] 设置客户端存活探测间隔 (ClientAliveInterval 300)...${RESET}"
        if ! grep -qE "^\s*ClientAliveInterval\s+300" "$SSH_CONFIG_FILE"; then
             if grep -qE '^\s*#?\s*ClientAliveInterval' "$SSH_CONFIG_FILE"; then
                sed -i -E 's/^\s*#?\s*ClientAliveInterval\s+.*/ClientAliveInterval 300/' "$SSH_CONFIG_FILE"
            else
                echo "ClientAliveInterval 300" >> "$SSH_CONFIG_FILE"
            fi
            check_command_status "设置 ClientAliveInterval 300" || success=false
            changes_made=true
        else
             echo -e "${BLUE}[-] ClientAliveInterval 已设置为 300，无需修改。${RESET}"
        fi
    fi
    echo "---"

    # 设置 ClientAliveCountMax
    if $success; then
        echo -e "${BLUE}[+] 设置客户端存活探测次数 (ClientAliveCountMax 2)...${RESET}"
        if ! grep -qE "^\s*ClientAliveCountMax\s+2" "$SSH_CONFIG_FILE"; then
             if grep -qE '^\s*#?\s*ClientAliveCountMax' "$SSH_CONFIG_FILE"; then
                sed -i -E 's/^\s*#?\s*ClientAliveCountMax\s+.*/ClientAliveCountMax 2/' "$SSH_CONFIG_FILE"
            else
                echo "ClientAliveCountMax 2" >> "$SSH_CONFIG_FILE"
            fi
            check_command_status "设置 ClientAliveCountMax 2" || success=false
            changes_made=true
        else
            echo -e "${BLUE}[-] ClientAliveCountMax 已设置为 2，无需修改。${RESET}"
        fi
    fi
    echo "---"

    # 如果任何修改步骤失败，恢复备份并退出
    if ! $success; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 在修改 SSH 配置时发生错误。${RESET}" >&2
        echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
        cp "$backup_file" "$SSH_CONFIG_FILE"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。${RESET}"
        else
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 恢复备份文件失败！请手动检查 ${CYAN}$SSH_CONFIG_FILE${RED} 和 ${CYAN}$backup_file${RESET}" >&2
        fi
        return 1
    fi

    # 只有在实际做出更改后才进行测试和重启
    if $changes_made; then
        # 检查 SSH 配置语法
        echo -e "${BLUE}${BOLD}[+] 正在检查 SSH 配置语法...${RESET}"
        sshd -t
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 修改后的 SSH 配置 (${CYAN}$SSH_CONFIG_FILE${RED}) 语法检查失败！${RESET}" >&2
            echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
            cp "$backup_file" "$SSH_CONFIG_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。${RESET}"
            else
                echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 恢复备份文件失败！请手动检查 ${CYAN}$SSH_CONFIG_FILE${RED} 和 ${CYAN}$backup_file${RESET}" >&2
            fi
            return 1
        fi
        echo -e "${GREEN}${BOLD}[✓] SSH 配置语法检查通过。${RESET}"

        # 重启 SSH 服务
        echo -e "${BLUE}${BOLD}[+] 正在重启 SSH 服务 (sshd/ssh)...${RESET}"
        systemctl restart sshd || systemctl restart ssh # 尝试重启 sshd 或 ssh
        if ! check_command_status "重启 SSH 服务"; then
             echo -e "${RED}${BOLD}[!] SSH 服务重启命令失败，尝试恢复备份并再次重启...${RESET}"
             cp "$backup_file" "$SSH_CONFIG_FILE" && (systemctl restart sshd || systemctl restart ssh)
             echo -e "${YELLOW}[!] 已尝试恢复备份配置。请检查 SSH 服务状态 (${CYAN}systemctl status sshd/ssh${YELLOW}) 和日志 (${CYAN}journalctl -u sshd/ssh${YELLOW})。${RESET}" >&2
             return 1
        fi

        # --- 验证 SSH 服务状态 ---
        echo -e "${BLUE}[+] 正在验证 SSH 服务状态...${RESET}"
        sleep 2 # 等待服务启动
        if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
            echo -e "${GREEN}${BOLD}[✓] SSH 服务处于活动状态。${RESET}"
            echo -e "${GREEN}${BOLD}[✓] SSH 配置强化完成并已成功重启服务。${RESET}"
        else
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} SSH 服务未能成功启动！即使语法检查通过。${RESET}" >&2
            echo -e "${RED}[!] 这可能由配置中的逻辑错误或权限问题引起。${RESET}"
            echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
            cp "$backup_file" "$SSH_CONFIG_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。正在尝试再次重启 SSH 服务...${RESET}"
                systemctl restart sshd || systemctl restart ssh
                sleep 2
                if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
                     echo -e "${GREEN}${BOLD}[✓] 使用备份配置成功重启 SSH 服务。${RESET}"
                else
                     echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 使用备份配置也无法启动 SSH 服务！请立即手动检查 SSH 配置 (${CYAN}$SSH_CONFIG_FILE${RED}) 和系统日志 (${CYAN}journalctl -u sshd/ssh${RED})。${RESET}" >&2
                fi
            else
                echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 恢复备份文件失败！请手动检查 ${CYAN}$SSH_CONFIG_FILE${RED} 和 ${CYAN}$backup_file${RED} 并尝试启动 SSH 服务。${RESET}" >&2
            fi
            return 1 # 返回失败状态
        fi
        # --- 验证结束 ---
    else
        echo -e "${BLUE}${BOLD}[i] SSH 配置未做任何更改，无需测试或重启服务。${RESET}"
    fi
    echo -e "${MAGENTA}===========================================================${RESET}"
}

# --- 脚本主逻辑 ---
# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 此脚本需要以 root 权限运行。${RESET}" >&2
    echo -e "${YELLOW}请尝试使用 'sudo bash $0' 来运行。${RESET}"
    exit 1
fi

# 获取当前 IP (脚本开始时获取一次)
get_current_ip

# 主菜单循环
while true; do
    # 清除动态检测的端口
    DETECTED_TCP_PORTS=""
    DETECTED_UDP_PORTS=""

    echo -e "\n${BLUE}${BOLD}================= Linux 安全加固脚本 (v2.5) =================${RESET}"
    echo -e "${CYAN}请选择要执行的操作:${RESET}"
    echo -e " ${YELLOW}1.${RESET} 安装 UFW 和 Fail2ban (及依赖)"
    echo -e " ${YELLOW}2.${RESET} 配置 UFW 防火墙 (${RED}将重置现有规则${RESET})"
    echo -e " ${YELLOW}3.${RESET} 配置 Fail2ban (需先配置UFW或已知SSH端口)"
    echo -e " ${YELLOW}4.${RESET} 强化 SSH 配置 (sshd)"
    echo -e " ${YELLOW}5.${RESET} ${BOLD}执行所有步骤 (1-4)${RESET}"
    echo -e " ${YELLOW}6.${RESET} 查看 UFW 状态"
    echo -e " ${YELLOW}7.${RESET} 查看 Fail2ban SSH jail 状态"
    echo -e " ${YELLOW}8.${RESET} 退出脚本"
    echo -e "${BLUE}${BOLD}=============================================================${RESET}"
    read -p "$(echo -e ${YELLOW}${BOLD}"请输入选项 [1-8]: "${RESET})" choice

    case $choice in
        1)
            install_packages
            ;;
        2)
            configure_ufw
            ;;
        3)
            configure_fail2ban
            ;;
        4)
            secure_ssh
            ;;
        5)
            echo -e "\n${MAGENTA}${BOLD}===== 开始执行所有步骤 (1 -> 2 -> 3 -> 4) =====${RESET}"
            install_packages && \
            configure_ufw && \
            configure_fail2ban && \
            secure_ssh
            if [ $? -eq 0 ]; then
                echo -e "\n${GREEN}${BOLD}*********************************************${RESET}"
                echo -e "${GREEN}${BOLD}*** 所有步骤已成功执行！ 服务器加固完成。 ***${RESET}"
                echo -e "${GREEN}${BOLD}*********************************************${RESET}"
            else
                echo -e "\n${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
                echo -e "${RED}${BOLD}!!! 执行过程中出现错误，请检查上面的输出。 !!!${RESET}"
                echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
            fi
            ;;
        6)
            echo -e "\n${BLUE}${BOLD}--- UFW 状态 ---${RESET}"
            if command -v ufw &> /dev/null; then
                ufw status verbose
            else
                echo -e "${YELLOW}[!] UFW 未安装或不可用。${RESET}"
            fi
            echo -e "${BLUE}${BOLD}----------------${RESET}"
            ;;
        7)
             echo -e "\n${BLUE}${BOLD}--- Fail2ban SSH Jail 状态 ---${RESET}"
            if command -v fail2ban-client &> /dev/null; then
                fail2ban-client status sshd
            else
                echo -e "${YELLOW}[!] Fail2ban 未安装或不可用。${RESET}"
            fi
             echo -e "${BLUE}${BOLD}-----------------------------${RESET}"
            ;;
        8)
            echo -e "\n${BLUE}[-] 退出脚本。祝您服务器安全！${RESET}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}${BOLD}[!] 无效选项，请输入 1 到 8 之间的数字。${RESET}"
            ;;
    esac
    # 只有在执行了实际操作或查看状态后才暂停
    if [[ "$choice" =~ ^[1-7]$ ]]; then
        read -p "$(echo -e ${CYAN}"\n按 Enter 键继续..."${RESET})" # 暂停以便用户阅读输出
    fi
done
