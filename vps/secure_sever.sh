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
CURRENT_IP=""         # 全局变量存储当前外部IP

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
        read -p "$(echo -e ${YELLOW}${BOLD}"[?] 请手动输入您当前的外部 IP 地址 (留空则不添加白名单): "${RESET})" CURRENT_IP_INPUT
        CURRENT_IP=$CURRENT_IP_INPUT # 赋值给全局变量
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
        # 检查常见的 SSH 服务单元名称
        for service_unit in sshd ssh; do
            if journalctl -u "$service_unit" --no-pager --quiet &> /dev/null; then
                echo -e "${GREEN}${BOLD}[✓] 检测到 systemd journal 管理 SSH 日志 ($service_unit)。将使用 '${MAGENTA}systemd${GREEN}' 后端。${RESET}"
                FAIL2BAN_BACKEND="systemd"
                SSH_LOG_PATH="using systemd backend" # 特殊标记，表示使用systemd
                found=true
                break # 找到一个即可
            fi
        done
    fi

    # 如果未使用 systemd 或 journalctl 无法查询，则检查传统日志文件
    if ! $found; then
        local potential_logs=("/var/log/auth.log" "/var/log/secure")
        for log_file in "${potential_logs[@]}"; do
            if [ -f "$log_file" ]; then
                 # 使用 head 限制读取量，提高效率，并确保文件包含 sshd 相关日志
                if head -n 100 "$log_file" | grep -q "sshd" &> /dev/null || tail -n 100 "$log_file" | grep -q "sshd" &> /dev/null ; then
                     echo -e "${GREEN}${BOLD}[✓] 检测到可能的 SSH 日志文件: ${CYAN}$log_file${RESET}"
                     SSH_LOG_PATH="$log_file"
                     FAIL2BAN_BACKEND="auto" # 允许 fail2ban 自动选择 (polling, pyinotify, gamin)
                     found=true
                     break
                fi
            fi
        done
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
        local port_found=""
        # 尝试使用 ss (推荐)
        if command -v ss &> /dev/null; then
            # 优化 ss 命令，直接查找 sshd 进程并提取端口
            port_found=$(ss -tlpn 2>/dev/null | grep 'sshd' | awk '{print $4}' | grep -oP ':\K[0-9]+' | head -n 1)
        # 备选 netstat
        elif command -v netstat &> /dev/null; then
             port_found=$(netstat -tlpn 2>/dev/null | grep 'sshd' | awk '{print $4}' | grep -oP ':\K[0-9]+' | head -n 1)
        fi
        DETECTED_SSH_PORT=$port_found
    fi

    # 最后确认
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 无法自动检测到 SSH 端口。将假定为标准端口 ${CYAN}22${YELLOW}。${RESET}"
        DETECTED_SSH_PORT="22"
    else
        echo -e "${GREEN}${BOLD}[✓] 检测到 SSH 端口: ${CYAN}${BOLD}$DETECTED_SSH_PORT${RESET}"
    fi
    # 将检测到的SSH端口也加入到TCP端口列表，以便后续UFW统一处理（如果它不是标准端口且未被代理检测覆盖）
    if [[ -n "$DETECTED_SSH_PORT" && ! " ${DETECTED_TCP_PORTS[*]} " =~ " ${DETECTED_SSH_PORT} " ]]; then
        DETECTED_TCP_PORTS+="$DETECTED_SSH_PORT "
    fi
    echo "----------------------------------------"
}


# --- Merged & Optimized detect_proxy_ports ---
detect_proxy_ports() {
    echo -e "${BLUE}${BOLD}[+] 正在检测常用代理工具端口 (TCP/UDP)...${RESET}"
    local proxy_ports_tcp=""
    local proxy_ports_udp=""
    local grep_pattern='snell|snell-server|ssserver|shadow-tls|trojan|hysteria|tuic'

    # --- 使用 ss 命令 (优先) ---
    if command -v ss &> /dev/null; then
        # TCP 端口检测 (ss)
        local raw_tcp
        raw_tcp=$(ss -lntp 2>/dev/null | awk -v pattern="$grep_pattern" '
            NR > 1 {
                process_info = ""; proc_name = "";
                # 提取进程信息 users:(("procname",pid=...,...))
                if (match($0, /users:\(\("([^"]+)"/)) {
                    proc_name = substr($0, RSTART + 8, RLENGTH - 9); # 提取引号内的进程名
                    process_info = proc_name; # 主要用于匹配
                } else if ($NF ~ /\(.*\)/ && $NF !~ /users:/) { # 尝试从最后一列提取进程名(如果格式不同)
                     process_info = $NF;
                } else if (match($0, /users:\(.*\)/)) { # 备用匹配整个 users:() 部分
                     process_info = substr($0, RSTART);
                }

                # 如果找到进程信息且匹配模式
                if (process_info != "" && (process_info ~ pattern || proc_name ~ pattern)) {
                     addr_port = $4 # 获取本地地址:端口
                     sub(/.*:/, "", addr_port); # 提取端口号
                     # 确保是纯数字端口号
                     if (addr_port ~ /^[0-9]+$/) {
                        # 排除常见的非代理端口减少误报 (可选，可注释掉)
                        # if (addr_port != 80 && addr_port != 443 && addr_port != 22) {
                            ports[addr_port]++; # 存储数字端口并去重
                        # }
                     }
                 }
            }
            END {
                # 按数字排序输出端口
                PROCINFO["sorted_in"] = "@ind_num_asc";
                for (port in ports) print port;
            }' | tr '\n' ' ')
        proxy_ports_tcp="${raw_tcp% }" # 移除可能的尾随空格

        # UDP 端口检测 (ss)
        local raw_udp
        raw_udp=$(ss -lnup 2>/dev/null | awk -v pattern="$grep_pattern" '
             NR > 1 {
                process_info = ""; proc_name = "";
                if (match($0, /users:\(\("([^"]+)"/)) {
                    proc_name = substr($0, RSTART + 8, RLENGTH - 9);
                    process_info = proc_name;
                } else if ($NF ~ /\(.*\)/ && $NF !~ /users:/) {
                     process_info = $NF;
                } else if (match($0, /users:\(.*\)/)) {
                     process_info = substr($0, RSTART);
                }

                if (process_info != "" && (process_info ~ pattern || proc_name ~ pattern)) {
                     addr_port = $4;
                     sub(/.*:/, "", addr_port);
                     if (addr_port ~ /^[0-9]+$/) {
                         ports[addr_port]++;
                     }
                 }
            }
            END {
                PROCINFO["sorted_in"] = "@ind_num_asc";
                for (port in ports) print port;
            }' | tr '\n' ' ')
        proxy_ports_udp="${raw_udp% }" # 移除可能的尾随空格

    # --- 使用 netstat 命令 (备选) ---
    elif command -v netstat &> /dev/null; then
        # TCP 端口检测 (netstat)
        local raw_tcp
        raw_tcp=$(netstat -lntp 2>/dev/null | awk -v pattern="$grep_pattern" '
            # $NF 通常是 PID/Program name 列
            NR > 2 && $NF ~ /^[0-9]+\// { # 跳过头部，检查最后一列是否包含 PID/
                prog_field = $NF;
                sub(/^[0-9]+\//, "", prog_field); # 提取程序名
                # 检查程序名是否匹配模式
                if (prog_field ~ pattern) {
                    addr_port = $4; # 获取本地地址:端口
                    sub(/.*:/, "", addr_port); # 提取端口号
                    if (addr_port ~ /^[0-9]+$/) {
                       ports[addr_port]++;
                    }
                 }
            }
            END {
                PROCINFO["sorted_in"] = "@ind_num_asc";
                for (port in ports) print port;
            }' | tr '\n' ' ')
        proxy_ports_tcp="${raw_tcp% }" # 移除可能的尾随空格

        # UDP 端口检测 (netstat)
        local raw_udp
        raw_udp=$(netstat -lnup 2>/dev/null | awk -v pattern="$grep_pattern" '
            NR > 2 && $NF ~ /^[0-9]+\// {
                prog_field = $NF;
                sub(/^[0-9]+\//, "", prog_field);
                if (prog_field ~ pattern) {
                    addr_port = $4;
                    sub(/.*:/, "", addr_port);
                    if (addr_port ~ /^[0-9]+$/) {
                         ports[addr_port]++;
                    }
                 }
            }
            END {
                PROCINFO["sorted_in"] = "@ind_num_asc";
                for (port in ports) print port;
            }' | tr '\n' ' ')
        proxy_ports_udp="${raw_udp% }" # 移除可能的尾随空格
    else
        echo -e "${YELLOW}${BOLD}[!] 警告:${RESET}${YELLOW} 'ss' 和 'netstat' 命令都不可用，无法自动检测代理端口。${RESET}"
    fi

    # --- 报告结果并将结果存入全局变量 ---
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
    # 去重全局变量 (以防万一重复追加)
    DETECTED_TCP_PORTS=$(echo "$DETECTED_TCP_PORTS" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    DETECTED_UDP_PORTS=$(echo "$DETECTED_UDP_PORTS" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    echo "----------------------------------------"
}
# --- End of merged detect_proxy_ports ---


# --- 主要功能函数 ---
# 1. 安装必要的软件包
install_packages() {
    echo -e "\n${MAGENTA}==================== 步骤 1: 安装软件包 ====================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 正在更新软件包列表并安装 UFW, Fail2ban 及依赖...${RESET}"
    # 尝试识别包管理器
    local pkg_manager=""
    if command -v apt-get &> /dev/null; then
        pkg_manager="apt"
    elif command -v yum &> /dev/null; then
        pkg_manager="yum"
    elif command -v dnf &> /dev/null; then
        pkg_manager="dnf"
    else
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 无法识别的包管理器 (apt/yum/dnf)。${RESET}" >&2
        return 1
    fi
    echo -e "${BLUE}[i] 使用包管理器: ${CYAN}$pkg_manager${RESET}"

    # 更新软件包列表
    case "$pkg_manager" in
        apt) sudo $pkg_manager update -y > /dev/null 2>&1 ;;
        yum|dnf) sudo $pkg_manager check-update > /dev/null 2>&1 ;; # yum/dnf 没有静默更新列表的直接命令
    esac
    check_command_status "软件包列表更新" || return 1

    # 定义不同发行版的包名
    local ufw_pkg="ufw"
    local fail2ban_pkg="fail2ban"
    local curl_pkg="curl"
    local wget_pkg="wget"
    local net_tools_pkg="net-tools"
    local iproute_pkg="iproute" # 通常是 iproute2 在 apt, iproute 在 yum/dnf
    local fail2ban_ufw_action="" # fail2ban-action for ufw if needed

    if [[ "$pkg_manager" == "yum" || "$pkg_manager" == "dnf" ]]; then
        # CentOS/RHEL/Fedora 通常需要 EPEL release 来安装 fail2ban
        echo -e "${BLUE}[+] 正在检查并安装 EPEL release (如果需要)...${RESET}"
        if ! rpm -q epel-release &>/dev/null; then
            sudo $pkg_manager install -y epel-release > /dev/null 2>&1
            check_command_status "安装 epel-release" || return 1 # Fail2ban 依赖它
        else
            echo -e "${BLUE}[-] EPEL release 已安装。${RESET}"
        fi
        # CentOS 7/RHEL 7 可能默认没有 ufw, CentOS 8+ firewalld 是默认
        # 脚本目前强制使用 UFW，如果需要支持 firewalld 需要大改动
        echo -e "${YELLOW}[!] 注意: 在 RHEL/CentOS 系统上，firewalld 是默认防火墙。此脚本将安装并使用 UFW。${RESET}"
        iproute_pkg="iproute"
        # yum/dnf 通常不需要单独的 fail2ban-action 包
    elif [ "$pkg_manager" == "apt" ]; then
        iproute_pkg="iproute2"
        # Debian/Ubuntu 可能需要 fail2ban 的 ufw action (虽然通常默认包含)
    fi

    # 安装软件包
    echo -e "${BLUE}[+] 正在安装软件包: ${CYAN}${ufw_pkg}, ${fail2ban_pkg}, ${curl_pkg}, ${wget_pkg}, ${net_tools_pkg}, ${iproute_pkg}${RESET}"
    sudo $pkg_manager install -y "$ufw_pkg" "$fail2ban_pkg" "$curl_pkg" "$wget_pkg" "$net_tools_pkg" "$iproute_pkg" > /dev/null 2>&1
    check_command_status "安装核心软件包" || return 1

    echo -e "${GREEN}${BOLD}[✓] 软件包安装完成。${RESET}"
    echo -e "${MAGENTA}===========================================================${RESET}"
}

# 2. 配置 UFW 防火墙
configure_ufw() {
    echo -e "\n${MAGENTA}==================== 步骤 2: 配置 UFW 防火墙 ================${RESET}"
    echo -e "${BLUE}${BOLD}[+] 开始配置 UFW 防火墙...${RESET}"

    # 确保 ufw 命令可用
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} UFW 命令不可用。请先运行安装步骤 (选项 1)。${RESET}"
        return 1
    fi

    # 重置 UFW 到默认状态 (先禁用再重置更可靠)
    echo -e "${YELLOW}${BOLD}[!] 注意:${RESET}${YELLOW} 即将重置 UFW 规则为默认状态...${RESET}"
    ufw --force disable > /dev/null 2>&1 # 先禁用
    echo "y" | ufw reset > /dev/null
    check_command_status "重置 UFW 规则" || return 1

    # 设置默认策略
    echo -e "${BLUE}[+] 设置默认策略: ${BOLD}拒绝入站${RESET}${BLUE}, ${BOLD}允许出站${RESET}${BLUE}...${RESET}"
    ufw default deny incoming > /dev/null
    check_command_status "设置默认入站策略 (deny incoming)" || return 1
    ufw default allow outgoing > /dev/null
    check_command_status "设置默认出站策略 (allow outgoing)" || return 1

    # 清空上次检测的端口，重新检测
    DETECTED_TCP_PORTS=""
    DETECTED_UDP_PORTS=""
    DETECTED_SSH_PORT=""

    # 检测 SSH 和代理端口
    detect_ssh_port # 这会填充 DETECTED_SSH_PORT 并可能添加到 DETECTED_TCP_PORTS
    detect_proxy_ports # 这会填充 DETECTED_TCP_PORTS 和 DETECTED_UDP_PORTS

    # 确保 SSH 端口已确定
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 无法确定 SSH 端口，无法继续配置 UFW。${RESET}" >&2
        return 1 # SSH 是关键
    fi

    # 允许 SSH 端口 (应该已包含在 DETECTED_TCP_PORTS 中，但为保险起见单独加一次)
    echo -e "${BLUE}[+] 允许 SSH 端口 ${CYAN}${BOLD}$DETECTED_SSH_PORT${BLUE}/tcp...${RESET}"
    ufw allow "$DETECTED_SSH_PORT"/tcp comment 'Allow SSH access' > /dev/null
    check_command_status "允许 SSH 端口 $DETECTED_SSH_PORT/tcp" || return 1

    # 允许检测到的 TCP 端口 (去重并排除已添加的 SSH 端口)
    local unique_tcp_ports=$(echo "$DETECTED_TCP_PORTS" | tr ' ' '\n' | grep -v "^${DETECTED_SSH_PORT}$" | sort -un | tr '\n' ' ')
    unique_tcp_ports=${unique_tcp_ports% } # Remove trailing space
    if [ -n "$unique_tcp_ports" ]; then
        echo -e "${BLUE}[+] 允许其他检测到的 TCP 端口: ${CYAN}${unique_tcp_ports}${RESET}"
        for port in $unique_tcp_ports; do
            ufw allow "$port"/tcp comment 'Allow detected TCP service' > /dev/null
            check_command_status "允许 TCP 端口 $port/tcp" || return 1
        done
    fi

    # 允许检测到的 UDP 端口 (去重)
    local unique_udp_ports=$(echo "$DETECTED_UDP_PORTS" | tr ' ' '\n' | sort -un | tr '\n' ' ')
    unique_udp_ports=${unique_udp_ports% } # Remove trailing space
    if [ -n "$unique_udp_ports" ]; then
         echo -e "${BLUE}[+] 允许检测到的 UDP 端口: ${CYAN}${unique_udp_ports}${RESET}"
        for port in $unique_udp_ports; do
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

    # 添加当前 IP 到白名单 (如果获取到)
    if [ -n "$CURRENT_IP" ]; then
        echo -e "${BLUE}[+] 将当前 IP ${CYAN}${BOLD}$CURRENT_IP${BLUE} 添加到 SSH 端口 (${CYAN}$DETECTED_SSH_PORT${BLUE}) 白名单...${RESET}"
        ufw allow from "$CURRENT_IP" to any port "$DETECTED_SSH_PORT" proto tcp comment 'Current IP Whitelist (SSH)' > /dev/null
        check_command_status "添加当前 IP $CURRENT_IP 到 SSH 白名单" || return 1
    else
        echo -e "${YELLOW}[i] 未获取到当前 IP 地址，跳过添加 SSH 白名单。${RESET}"
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
    # 确保 fail2ban 命令可用
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} Fail2ban 命令不可用。请先运行安装步骤 (选项 1)。${RESET}"
        return 1
    fi
     # 确保 SSH 端口已检测 (如果 configure_ufw 没运行过)
    if [ -z "$DETECTED_SSH_PORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] 未检测到 SSH 端口，尝试现在检测...${RESET}"
        detect_ssh_port
        if [ -z "$DETECTED_SSH_PORT" ]; then
             echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 无法检测 SSH 端口，无法继续配置 Fail2ban。${RESET}" >&2
             return 1
        fi
    fi

    # 自动检测 SSH 日志或后端
    find_ssh_log_or_backend || echo -e "${YELLOW}[i] 继续使用 Fail2ban 默认日志检测机制。${RESET}" # 如果检测失败，提示一下

    # 创建 jail.local 配置文件
    echo -e "${BLUE}[+] 正在创建/更新 Fail2ban 配置文件 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${BLUE}...${RESET}"
    # 使用 cat 和 EOF 创建或覆盖文件，确保权限正确
    cat > "$FAIL2BAN_JAIL_LOCAL" << EOF
[DEFAULT]
# 默认禁止时间 (设置为更长的时间，例如 30 天)
bantime = 30d
# 在多少时间内达到最大重试次数则封禁 (例如 10 分钟)
findtime = 10m
# 最大重试次数 (可以设置得更严格，例如 3 次)
maxretry = 3
# 忽略的 IP 地址，可以是单个 IP、CIDR 或 DNS 主机名
# 127.0.0.1/8 和 ::1 是本地回环，必须忽略
# 将当前 IP 加入白名单 (如果获取到)
ignoreip = 127.0.0.1/8 ::1 ${CURRENT_IP:-}
# 后端设置 (根据检测结果设置)
backend = ${FAIL2BAN_BACKEND:-auto}
# 使用 ufw 作防火墙操作 (确保与 UFW 集成)
# 如果有多个 action，可以这样写: banaction = ufw[application=...]
# 但对于 SSH，通常直接用 ufw 即可
banaction = ufw

[sshd]
# 启用 SSH 防护
enabled = true
# 监听的端口，使用检测到的端口，若未检测到则使用默认 'ssh'
# 可以指定多个端口，用逗号分隔，例如 port = ssh,2222
port = ${DETECTED_SSH_PORT:-ssh}
# 使用内置的 sshd 过滤器
filter = sshd
# 日志路径 (如果检测到特定文件路径则使用，否则留空让 fail2ban 使用默认或 systemd 后端)
EOF
    # --- 添加 logpath (如果需要) ---
    local logpath_line="" # 存储要写入文件的 logpath 行
    local logpath_display="" # 用于后续摘要输出显示
    if [ -n "$SSH_LOG_PATH" ] && [ "$SSH_LOG_PATH" != "using systemd backend" ]; then
        # 检测到特定日志文件路径
        logpath_line="logpath = $SSH_LOG_PATH"
        logpath_display="${CYAN}$SSH_LOG_PATH${RESET}"
        echo "$logpath_line" >> "$FAIL2BAN_JAIL_LOCAL"
        echo -e "${BLUE}[i] 使用检测到的日志路径: $logpath_display"
    elif [ "$FAIL2BAN_BACKEND" == "systemd" ]; then
        # 使用 systemd 后端，不需要 logpath
        echo -e "${BLUE}[i] 使用 systemd 后端，无需在 jail.local 中显式设置 logpath。${RESET}"
        logpath_display="${MAGENTA}(使用 systemd journal，无需显式设置)${RESET}"
        # 不需要向 jail.local 添加 logpath 行
    else # FAIL2BAN_BACKEND != "systemd" 且未检测到 SSH_LOG_PATH
         # 自动检测失败，添加注释提示用户
         logpath_line="# logpath = %(sshd_log)s  # 自动检测失败，请根据系统检查并取消注释或修改"
         logpath_display="${YELLOW}(自动检测失败，使用 Fail2ban 默认或需手动设置)${RESET}"
         echo "$logpath_line" >> "$FAIL2BAN_JAIL_LOCAL"
         echo -e "${YELLOW}[i] 未能自动检测日志路径，请在 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${YELLOW} 中检查 'logpath'。${RESET}"
    fi

    check_command_status "创建/更新 ${CYAN}${FAIL2BAN_JAIL_LOCAL}${RESET}" || return 1

    # --- 显示配置参数 ---
    echo -e "${BLUE}${BOLD}\n[+] Fail2ban (${CYAN}${FAIL2BAN_JAIL_LOCAL}${BLUE}) 配置摘要:${RESET}"
    echo -e "  ${MAGENTA}[DEFAULT]${RESET}"
    echo -e "    ${CYAN}bantime${RESET}  = $(grep -E '^\s*bantime\s*=' "$FAIL2BAN_JAIL_LOCAL" | awk -F= '{print $2}' | xargs)"
    echo -e "    ${CYAN}findtime${RESET} = $(grep -E '^\s*findtime\s*=' "$FAIL2BAN_JAIL_LOCAL" | awk -F= '{print $2}' | xargs)"
    echo -e "    ${CYAN}maxretry${RESET} = $(grep -E '^\s*maxretry\s*=' "$FAIL2BAN_JAIL_LOCAL" | awk -F= '{print $2}' | xargs)"
    local current_ip_display="${CURRENT_IP}"
    if [ -z "$current_ip_display" ]; then
        current_ip_display="${YELLOW}(未自动获取或手动输入)${RESET}"
    else
        current_ip_display="${CYAN}${BOLD}${current_ip_display}${RESET}"
    fi
    echo -e "    ${CYAN}ignoreip${RESET} = 127.0.0.1/8 ::1 ${current_ip_display}"
    echo -e "    ${CYAN}backend${RESET}  = ${MAGENTA}${FAIL2BAN_BACKEND:-auto}${RESET}"
    echo -e "    ${CYAN}banaction${RESET}= $(grep -E '^\s*banaction\s*=' "$FAIL2BAN_JAIL_LOCAL" | awk -F= '{print $2}' | xargs)"
    echo -e "  ${MAGENTA}[sshd]${RESET}"
    echo -e "    ${CYAN}enabled${RESET}  = $(grep -A 5 '\[sshd\]' "$FAIL2BAN_JAIL_LOCAL" | grep -E '^\s*enabled\s*=' | awk -F= '{print $2}' | xargs)"
    echo -e "    ${CYAN}port${RESET}     = ${CYAN}$(grep -A 5 '\[sshd\]' "$FAIL2BAN_JAIL_LOCAL" | grep -E '^\s*port\s*=' | awk -F= '{print $2}' | xargs)${RESET}"
    echo -e "    ${CYAN}filter${RESET}   = $(grep -A 5 '\[sshd\]' "$FAIL2BAN_JAIL_LOCAL" | grep -E '^\s*filter\s*=' | awk -F= '{print $2}' | xargs)"
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
        # 尝试查看最近的日志帮助调试
        echo -e "${YELLOW}[i] 显示最近的 Fail2ban 日志: ${RESET}"
        journalctl -u fail2ban -n 10 --no-pager || tail -n 20 /var/log/fail2ban.log
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
    if ! check_command_status "备份 SSH 配置文件"; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 备份 SSH 配置文件失败，中止操作。${RESET}" >&2
        return 1
    fi

    # --- 辅助函数：修改或添加 SSH 配置项 ---
    # 参数: $1=配置项名称, $2=期望值, $3=配置文件路径
    configure_ssh_option() {
        local key="$1"
        local value="$2"
        local config_file="$3"
        local change_made_flag=false # 局部变量跟踪此项修改
        # 检查是否已存在且值正确 (忽略行首空格和注释)
        if grep -qE "^\s*${key}\s+${value}" "$config_file"; then
            echo -e "${BLUE}[-] ${key} 已设置为 ${value}，无需修改。${RESET}"
            return 0 # 0 表示无需修改或修改成功
        else
             # 尝试修改现有行 (包括注释掉的行)
             if grep -qE "^\s*#?\s*${key}\s+" "$config_file"; then
                 sed -i -E "s/^\s*#?\s*${key}\s+.*/${key} ${value}/" "$config_file"
             else
                 # 如果不存在，则追加到文件末尾
                 echo "${key} ${value}" >> "$config_file"
             fi
             # 验证修改是否成功
             if grep -qE "^\s*${key}\s+${value}" "$config_file"; then
                check_command_status "设置 ${key} ${value}" || return 1
                return 2 # 2 表示成功修改
             else
                 echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 尝试设置 ${key} ${value} 失败。${RESET}" >&2
                 return 1 # 1 表示修改失败
             fi
        fi
    }

    local overall_success=true # 跟踪整个函数是否成功
    local any_change_made=false # 跟踪是否有任何实际修改

    # 禁用 Root 登录 (交互式)
    read -p "$(echo -e ${YELLOW}${BOLD}"[?] 是否要尝试禁用 Root 账户通过 SSH 登录? (y/N): "${RESET})" disable_root_login
    if [[ "$disable_root_login" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}[+] 正在检查禁用 Root 登录的安全性...${RESET}"
        # 查找 sudo 组或 wheel 组中的非 root 用户
        local sudo_users=""
        if getent group sudo >/dev/null 2>&1; then
            sudo_users=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' || true)
        elif getent group wheel >/dev/null 2>&1; then
             sudo_users=$(getent group wheel | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' || true)
        fi
        # 也可以检查 /etc/sudoers.d/ 文件中的用户，但 getent group 更简单通用

        if [ -z "$sudo_users" ]; then
            # 如果没有找到其他 sudo 用户
            echo -e "${RED}${BOLD}[✗] 安全检查失败!${RESET}${RED} 未找到其他具有 sudo/wheel 权限的用户。${RESET}"
            echo -e "${RED}    为了防止您被锁定在服务器之外，脚本无法自动禁用 Root 登录。${RESET}"
            echo -e "${YELLOW}    请先手动创建一个具有 sudo/wheel 权限的新用户，并确保可以使用该用户登录，然后再尝试禁用 Root 登录。${RESET}"
            # 不设置 overall_success=false，允许用户继续其他配置
        else
            # 找到其他 sudo 用户，进行二次确认
            echo -e "${YELLOW}${BOLD}[!] 安全警告!${RESET}${YELLOW} 检测到以下可能具有 sudo/wheel 权限的用户:${RESET}"
            echo -e "${CYAN}${sudo_users}${RESET}" # 列出找到的用户
            echo -e "${YELLOW}    在禁用 Root 登录之前，${BOLD}请务必确认您可以使用上述至少一个用户通过 SSH 成功登录，并且该用户拥有 sudo/wheel 权限${RESET}${YELLOW}，否则您将无法管理服务器！${RESET}"
            read -p "$(echo -e ${YELLOW}${BOLD}"[?] 您是否已确认并理解风险，确实要继续禁用 Root 登录? (y/N): "${RESET})" confirm_disable_root
            if [[ "$confirm_disable_root" =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}[+] 设置 Root 禁止登录 (PermitRootLogin no)...${RESET}"
                configure_ssh_option "PermitRootLogin" "no" "$SSH_CONFIG_FILE"
                local config_status=$?
                if [ $config_status -eq 1 ]; then overall_success=false; fi
                if [ $config_status -eq 2 ]; then any_change_made=true; fi
            else
                echo -e "${YELLOW}[-] 取消禁用 Root 登录。${RESET}"
            fi
        fi
    else
         echo -e "${BLUE}[i] 跳过禁用 Root 登录的设置。${RESET}"
    fi
    echo "---"


    # 禁用密码认证 (交互式)
    if $overall_success; then # 只有在前面的步骤没有明确失败时才继续
        read -p "$(echo -e ${YELLOW}${BOLD}"[?] 是否禁用 SSH 密码认证，强制使用密钥登录? (强烈推荐 'y') (y/N): "${RESET})" disable_password_auth
        if [[ "$disable_password_auth" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}${BOLD}[!] 重要提示:${RESET}${YELLOW} 禁用密码认证前，请确保您已成功设置并测试过 SSH 密钥登录！${RESET}"
            read -p "$(echo -e ${YELLOW}${BOLD}"[?] 您是否已准备好 SSH 密钥并确认可以无密码登录? (y/N): "${RESET})" confirm_key_ready
            if [[ "$confirm_key_ready" =~ ^[Yy]$ ]]; then
                local pw_auth_changed=false
                local chal_resp_changed=false

                echo -e "${BLUE}[+] 禁用密码认证 (PasswordAuthentication no)...${RESET}"
                configure_ssh_option "PasswordAuthentication" "no" "$SSH_CONFIG_FILE"
                local config_status=$?
                if [ $config_status -eq 1 ]; then overall_success=false; fi
                if [ $config_status -eq 2 ]; then any_change_made=true; pw_auth_changed=true; fi

                if $overall_success; then
                     echo -e "${BLUE}[+] 禁用 ChallengeResponseAuthentication (no)...${RESET}"
                     configure_ssh_option "ChallengeResponseAuthentication" "no" "$SSH_CONFIG_FILE"
                     config_status=$?
                     if [ $config_status -eq 1 ]; then overall_success=false; fi
                     if [ $config_status -eq 2 ]; then any_change_made=true; chal_resp_changed=true; fi
                fi
                # KbdInteractiveAuthentication is often linked or replaces ChallengeResponseAuthentication
                if $overall_success; then
                     echo -e "${BLUE}[+] 禁用 KbdInteractiveAuthentication (no)...${RESET}"
                     configure_ssh_option "KbdInteractiveAuthentication" "no" "$SSH_CONFIG_FILE"
                     config_status=$?
                     if [ $config_status -eq 1 ]; then overall_success=false; fi
                     if [ $config_status -eq 2 ]; then any_change_made=true; fi # Don't need a separate flag for this one for the message
                fi

                if $overall_success && ($pw_auth_changed || $chal_resp_changed); then # 只有当真正修改了才提示
                    echo -e "${GREEN}${BOLD}[✓] 已配置禁用密码/质询认证。${RESET}"
                elif ! $overall_success; then
                    echo -e "${RED}[!] 设置密码/质询认证时出错。${RESET}"
                fi
            else
                echo -e "${YELLOW}[-] 取消禁用密码认证，因为 SSH 密钥未确认。${RESET}"
            fi
        else
            echo -e "${YELLOW}[-] 跳过禁用密码认证。${BOLD}(为了安全，强烈建议使用密钥登录)${RESET}"
        fi
    fi
    echo "---"

    # 限制最大认证尝试次数
    if $overall_success; then
        echo -e "${BLUE}[+] 设置最大认证尝试次数 (MaxAuthTries 3)...${RESET}"
        configure_ssh_option "MaxAuthTries" "3" "$SSH_CONFIG_FILE"
        local config_status=$?
        if [ $config_status -eq 1 ]; then overall_success=false; fi
        if [ $config_status -eq 2 ]; then any_change_made=true; fi
    fi
    echo "---"

    # 启用 TCPKeepAlive
    if $overall_success; then
         echo -e "${BLUE}[+] 启用 TCPKeepAlive (TCPKeepAlive yes)...${RESET}"
         configure_ssh_option "TCPKeepAlive" "yes" "$SSH_CONFIG_FILE"
         local config_status=$?
         if [ $config_status -eq 1 ]; then overall_success=false; fi
         if [ $config_status -eq 2 ]; then any_change_made=true; fi
    fi
    echo "---"

    # 设置 ClientAliveInterval
    if $overall_success; then
        echo -e "${BLUE}[+] 设置客户端存活探测间隔 (ClientAliveInterval 300)...${RESET}"
        configure_ssh_option "ClientAliveInterval" "300" "$SSH_CONFIG_FILE"
        local config_status=$?
        if [ $config_status -eq 1 ]; then overall_success=false; fi
        if [ $config_status -eq 2 ]; then any_change_made=true; fi
    fi
    echo "---"

    # 设置 ClientAliveCountMax
    if $overall_success; then
        echo -e "${BLUE}[+] 设置客户端存活探测次数 (ClientAliveCountMax 2)...${RESET}"
        configure_ssh_option "ClientAliveCountMax" "2" "$SSH_CONFIG_FILE"
        local config_status=$?
        if [ $config_status -eq 1 ]; then overall_success=false; fi
        if [ $config_status -eq 2 ]; then any_change_made=true; fi
    fi
    echo "---"

    # 如果任何修改步骤失败，恢复备份并退出
    if ! $overall_success; then
        echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 在修改 SSH 配置时发生错误。${RESET}" >&2
        echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
        cp "$backup_file" "$SSH_CONFIG_FILE"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。 SSH 配置未更改。${RESET}"
        else
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 恢复备份文件失败！请手动检查 ${CYAN}$SSH_CONFIG_FILE${RED} 和 ${CYAN}$backup_file${RESET}" >&2
        fi
        return 1
    fi

    # 只有在实际做出更改后才进行测试和重启
    if $any_change_made; then
        # 检查 SSH 配置语法
        echo -e "${BLUE}${BOLD}[+] 正在检查 SSH 配置语法...${RESET}"
        sshd -t
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 修改后的 SSH 配置 (${CYAN}$SSH_CONFIG_FILE${RED}) 语法检查失败！${RESET}" >&2
            echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
            cp "$backup_file" "$SSH_CONFIG_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。 SSH 配置未更改。${RESET}"
            else
                echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 恢复备份文件失败！请手动检查 ${CYAN}$SSH_CONFIG_FILE${RED} 和 ${CYAN}$backup_file${RESET}" >&2
            fi
            return 1
        fi
        echo -e "${GREEN}${BOLD}[✓] SSH 配置语法检查通过。${RESET}"

        # 重启 SSH 服务
        echo -e "${BLUE}${BOLD}[+] 正在重启 SSH 服务 (sshd/ssh)...${RESET}"
        # 确定服务名称
        local ssh_service_name="sshd"
        if systemctl list-unit-files | grep -q '^ssh.service'; then
            ssh_service_name="ssh"
        fi
        echo -e "${BLUE}[i] 使用 SSH 服务名: ${CYAN}${ssh_service_name}${RESET}"
        systemctl restart "$ssh_service_name"
        if ! check_command_status "重启 SSH 服务 (${ssh_service_name})"; then
             echo -e "${RED}${BOLD}[!] SSH 服务重启命令失败，尝试恢复备份并再次重启...${RESET}"
             cp "$backup_file" "$SSH_CONFIG_FILE" && systemctl restart "$ssh_service_name"
             echo -e "${YELLOW}[!] 已尝试恢复备份配置。请检查 SSH 服务状态 (${CYAN}systemctl status ${ssh_service_name}${YELLOW}) 和日志 (${CYAN}journalctl -u ${ssh_service_name}${YELLOW})。${RESET}" >&2
             return 1
        fi

        # --- 验证 SSH 服务状态 ---
        echo -e "${BLUE}[+] 正在验证 SSH 服务状态...${RESET}"
        sleep 2 # 等待服务启动
        if systemctl is-active --quiet "$ssh_service_name"; then
            echo -e "${GREEN}${BOLD}[✓] SSH 服务 (${ssh_service_name}) 处于活动状态。${RESET}"
            echo -e "${GREEN}${BOLD}[✓] SSH 配置强化完成并已成功重启服务。${RESET}"
        else
            echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} SSH 服务 (${ssh_service_name}) 未能成功启动！即使语法检查通过。${RESET}" >&2
            echo -e "${RED}[!] 这可能由配置中的逻辑错误或权限问题引起。${RESET}"
            echo -e "${YELLOW}${BOLD}[!] 正在尝试恢复备份文件 ${CYAN}${backup_file}${YELLOW}...${RESET}"
            cp "$backup_file" "$SSH_CONFIG_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${BOLD}[✓] 备份文件已恢复。正在尝试再次重启 SSH 服务...${RESET}"
                systemctl restart "$ssh_service_name"
                sleep 2
                if systemctl is-active --quiet "$ssh_service_name"; then
                     echo -e "${GREEN}${BOLD}[✓] 使用备份配置成功重启 SSH 服务。${RESET}"
                else
                     echo -e "${RED}${BOLD}[✗] 错误:${RESET}${RED} 使用备份配置也无法启动 SSH 服务！请立即手动检查 SSH 配置 (${CYAN}$SSH_CONFIG_FILE${RED}) 和系统日志 (${CYAN}journalctl -u ${ssh_service_name}${RED})。${RESET}" >&2
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
    # 清除上次菜单循环可能残留的检测结果（如果适用）
    # 注意：全局变量 DETECTED_*_PORTS 和 DETECTED_SSH_PORT 主要在步骤 2/3 中动态获取和使用
    # 这里不需要每次循环都清空，因为步骤 2 (configure_ufw) 会在开始时清空它们

    echo -e "\n${BLUE}${BOLD}================= Linux 安全加固脚本 (v2.6 - Optimized Port Detection) =================${RESET}"
    echo -e "${CYAN}请选择要执行的操作:${RESET}"
    echo -e " ${YELLOW}1.${RESET} 安装 UFW 和 Fail2ban (及依赖)"
    echo -e " ${YELLOW}2.${RESET} 配置 UFW 防火墙 (${RED}将重置现有规则${RESET})"
    echo -e " ${YELLOW}3.${RESET} 配置 Fail2ban (需先配置UFW或已知SSH端口)"
    echo -e " ${YELLOW}4.${RESET} 强化 SSH 配置 (sshd)"
    echo -e " ${YELLOW}5.${RESET} ${BOLD}执行所有步骤 (1-4)${RESET}"
    echo -e " ${YELLOW}6.${RESET} 查看 UFW 状态"
    echo -e " ${YELLOW}7.${RESET} 查看 Fail2ban SSH jail 状态"
    echo -e " ${YELLOW}8.${RESET} 退出脚本"
    echo -e "${BLUE}${BOLD}====================================================================================${RESET}"
    read -p "$(echo -e ${YELLOW}${BOLD}"请输入选项 [1-8]: "${RESET})" choice

    case $choice in
        1)
            install_packages
            ;;
        2)
            configure_ufw
            ;;
        3)
            # 确保 configure_ufw 运行过或 SSH 端口已知
            if [ -z "$DETECTED_SSH_PORT" ]; then
                 echo -e "${YELLOW}[!] 尚未配置 UFW 或检测 SSH 端口。建议先运行步骤 2。${RESET}"
                 read -p "$(echo -e ${YELLOW}${BOLD}"[?] 是否仍要继续配置 Fail2ban? (y/N): "${RESET})" continue_f2b
                 if [[ ! "$continue_f2b" =~ ^[Yy]$ ]]; then
                    echo -e "${BLUE}[i] 取消配置 Fail2ban。${RESET}"
                    continue # 跳回主菜单
                 fi
                 # 如果用户坚持，尝试检测 SSH 端口
                 detect_ssh_port
                 if [ -z "$DETECTED_SSH_PORT" ]; then
                     echo -e "${RED}[!] 无法检测 SSH 端口，无法配置 Fail2ban。${RESET}"
                     continue # 跳回主菜单
                 fi
            fi
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
                echo -e "\n${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
                echo -e "${RED}${BOLD}!!! 执行过程中至少有一个步骤失败，请检查上面的输出。 !!!${RESET}"
                echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RESET}"
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
                 if systemctl is-active --quiet fail2ban; then
                    fail2ban-client status sshd
                 else
                     echo -e "${YELLOW}[!] Fail2ban 服务当前未运行。${RESET}"
                 fi
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
        # 检查脚本是否仍在运行（避免在步骤5失败后还提示按键）
        # (这里简单处理，只要不是选项8就暂停)
        read -p "$(echo -e ${CYAN}"\n按 Enter 键返回主菜单..."${RESET})" # 暂停以便用户阅读输出
    fi
done
