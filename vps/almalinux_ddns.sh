#!/bin/bash

# 输出字体颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
GREEN_ground="\033[42;37m" # 全局绿色
RED_ground="\033[41;37m"   # 全局红色
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# 检查系统是否为 AlmaLinux
if ! grep -qiE "almalinux" /etc/os-release; then
    echo -e "${RED}本脚本仅支持 AlmaLinux 系统，请在 AlmaLinux 系统上运行。${NC}"
    exit 1
fi

# 检查是否为root用户
check_root(){
    if [[ $(whoami) != "root" ]]; then
        echo -e "${Error}请以root身份执行该脚本！"
        exit 1
    fi
}

# 检查是否安装 curl，如果没有安装，则安装 curl
check_curl() {
    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装 curl...${NC}"
        dnf install -y curl
        if [ $? -ne 0 ]; then
            echo -e "${RED}安装 curl 失败，请手动安装后重新运行脚本。${NC}"
            exit 1
        fi
    fi
}

# 开始安装DDNS
install_ddns(){
    if [ ! -f "/usr/bin/ddns" ]; then
        curl -o /usr/bin/ddns https://raw.githubusercontent.com/ExNG51/envi.ruleset/refs/heads/main/vps/almalinux_ddns.sh && chmod +x /usr/bin/ddns
    fi
    mkdir -p /etc/DDNS
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash

# 引入环境变量文件
source /etc/DDNS/.config

# 保存旧的 IP 地址
Old_Public_IPv4="$Old_Public_IPv4"
Old_Public_IPv6="$Old_Public_IPv6"

# 更新IPv4 DNS记录
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv4" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$Domain\",\"content\":\"$Public_IPv4\"}" >/dev/null 2>&1

# 更新IPv6 DNS记录
if [ "$ipv6_set" = true ] && [ -n "$Domainv6" ] && [ "$Domainv6" != "your_domainv6.com" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records/$DNS_IDv6" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"AAAA\",\"name\":\"$Domainv6\",\"content\":\"$Public_IPv6\"}" >/dev/null 2>&1
fi

# 发送Telegram通知
if [[ -n "$Telegram_Bot_Token" && -n "$Telegram_Chat_ID" && (("$Public_IPv4" != "$Old_Public_IPv4" && -n "$Public_IPv4") || ("$Public_IPv6" != "$Old_Public_IPv6" && -n "$Public_IPv6")) ]]; then
    send_telegram_notification
fi

# 延迟3秒
sleep 3

# 保存当前的 IP 地址到配置文件，但只有当 IP 地址有变化时才进行更新
if [[ -n "$Public_IPv4" && "$Public_IPv4" != "$Old_Public_IPv4" ]]; then
    sed -i "s/^Old_Public_IPv4=.*/Old_Public_IPv4=\"$Public_IPv4\"/" /etc/DDNS/.config
fi

# 检查 IPv6 地址是否有效且发生变化
if [[ -n "$Public_IPv6" && "$Public_IPv6" != "$Old_Public_IPv6" ]]; then
    sed -i "s/^Old_Public_IPv6=.*/Old_Public_IPv6=\"$Public_IPv6\"/" /etc/DDNS/.config
fi
EOF
    cat <<'EOF' > /etc/DDNS/.config
Domain="your_domain.com"		# 你要解析的域名
ipv6_set="set"                 #开启ipv6
Domainv6="your_domainv6.com" 
Email="your_email@gmail.com"     # 你在Cloudflare注册的邮箱
Api_key="your_api_key"  # 你的Cloudflare API密钥

# Telegram Bot Token 和 Chat ID
Telegram_Bot_Token=""
Telegram_Chat_ID=""

# 获取根域名
Root_domain=$(echo "$Domain" | cut -d'.' -f2-)

# 获取公网IP地址
regex_pattern='^(eth|ens|eno|esp|enp)[0-9]+'

InterFace=($(ip link show | awk -F': ' '{print $2}' | grep -E "$regex_pattern" | sed "s/@.*//g"))

Public_IPv4=""
Public_IPv6=""
Old_Public_IPv4=""
Old_Public_IPv6=""
ipv4Regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
ipv6Regex="^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$"

for i in "${InterFace[@]}"; do
    # 尝试通过第一个接口获取 IPv4 地址
    ipv4=$(curl -s4 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)

    # 如果第一个接口的 IPv4 地址获取失败，尝试备用接口
    if [[ -z "$ipv4" ]]; then
        ipv4=$(curl -s4 --max-time 3 --interface "$i" https://api.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
    fi

    # 验证获取到的 IPv4 地址是否是有效的 IP 地址
    if [[ -n "$ipv4" && "$ipv4" =~ $ipv4Regex ]]; then
        Public_IPv4="$ipv4"
    else
        ipv4=""
    fi

    # 检查是否启用了 IPv6 解析
    if [[ "$ipv6_set" == "true" ]]; then
        # 尝试通过第一个接口获取 IPv6 地址
        ipv6=$(curl -s6 --max-time 3 --interface "$i" ip.sb -k | grep -E -v '^(2a09|104\.28)' || true)

        # 如果第一个接口的 IPv6 地址获取失败，尝试备用接口
        if [[ -z "$ipv6" ]]; then
            ipv6=$(curl -s6 --max-time 3 --interface "$i" https://api6.ipify.org -k | grep -E -v '^(2a09|104\.28)' || true)
        fi

        # 验证获取到的 IPv6 地址是否是有效的 IP 地址
        if [[ -n "$ipv6" && "$ipv6" =~ $ipv6Regex ]]; then
            Public_IPv6="$ipv6"
        else
            ipv6=""
        fi
    fi
done

# 使用Cloudflare API获取根域名的区域ID
Zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$Root_domain" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     | grep -Po '(?<="id":")[^"]*' | head -1)

# 获取IPv4 DNS记录ID
DNS_IDv4=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=A&name=$Domain" \
     -H "X-Auth-Email: $Email" \
     -H "X-Auth-Key: $Api_key" \
     -H "Content-Type: application/json" \
     | grep -Po '(?<="id":")[^"]*' | head -1)

# 获取IPv6 DNS记录ID
if [ "$ipv6_set" = true ] && [ -n "$Domainv6" ] && [ "$Domainv6" != "your_domainv6.com" ]; then
    DNS_IDv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$Zone_id/dns_records?type=AAAA&name=$Domainv6" \
         -H "X-Auth-Email: $Email" \
         -H "X-Auth-Key: $Api_key" \
         -H "Content-Type: application/json" \
         | grep -Po '(?<="id":")[^"]*' | head -1)
fi

# 发送 Telegram 通知函数
send_telegram_notification(){
    # 构建基础的通知消息（仅包含IPv4）
    local message="$Domain IPv4更新 $Old_Public_IPv4  🔜  $Public_IPv4 。 "

    # 如果 Domainv6 存在，添加 IPv6 更新信息
    if [ -n "$Domainv6" ] && [ "$Domainv6" != "your_domainv6.com" ]; then
        message+="$Domainv6 IPv6更新 $Old_Public_IPv6  🔜  $Public_IPv6 。"
    fi

    # 发送通知
    curl -s -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
        -d "chat_id=$Telegram_Chat_ID" \
        -d "text=$message"
}

EOF
    echo -e "${Info}DDNS 安装完成！"
    echo
}

# 检查 DDNS 状态
check_ddns_status(){
    if [[ -f "/etc/systemd/system/ddns.timer" ]]; then
        STatus=$(systemctl status ddns.timer | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ $STatus =~ "waiting"|"running" ]]; then
            ddns_status=running
        else
            ddns_status=dead
        fi
    fi
}

# 后续操作
go_ahead(){
    echo -e "${Tip}选择一个选项：
  ${GREEN}0${NC}：退出
  ${GREEN}1${NC}：重启 DDNS
  ${GREEN}2${NC}：停止 DDNS
  ${GREEN}3${NC}：${RED}卸载 DDNS${NC}
  ${GREEN}4${NC}：修改要解析的域名
  ${GREEN}5${NC}：修改 Cloudflare Api
  ${GREEN}6${NC}：配置 Telegram 通知"
    echo
    read -p "选项: " option
    until [[ "$option" =~ ^[0-6]$ ]]; do
        echo -e "${Error}请输入正确的数字 [0-6]"
        echo
        exit 1
    done
    case "$option" in
        0)
            exit 1
        ;;
        1)
            restart_ddns
            check_ddns_install
        ;;
        2)
            stop_ddns
        ;;
        3)
            systemctl disable ddns.service ddns.timer >/dev/null 2>&1
            systemctl stop ddns.service ddns.timer >/dev/null 2>&1
            rm -rf /etc/systemd/system/ddns.service /etc/systemd/system/ddns.timer /etc/DDNS /usr/bin/ddns
            echo -e "${Info}DDNS 已卸载！"
            echo
        ;;
        4)
            set_domain
            restart_ddns
            sleep 2
            check_ddns_install
        ;;
        5)
            set_cloudflare_api
            set_domain
            if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
                run_ddns
                sleep 2
            else
               restart_ddns
               sleep 2
            fi
            check_ddns_install
        ;;
        6)
            set_telegram_settings
            check_ddns_install
        ;;
    esac
}

# 设置Cloudflare Api
set_cloudflare_api(){
    echo -e "${Tip}开始配置CloudFlare API..."
    echo

    echo -e "${Tip}请输入您的Cloudflare邮箱"
    read -rp "邮箱: " EMail
    if [ -z "$EMail" ]; then
        echo -e "${Error}未输入邮箱，无法执行操作！"
        exit 1
    else
        EMAIL="$EMail"
    fi
    echo -e "${Info}你的邮箱：${RED_ground}${EMAIL}${NC}"
    echo

    echo -e "${Tip}请输入您的Cloudflare API密钥"
    read -rp "密钥: " Api_Key
    if [ -z "Api_Key" ]; then
        echo -e "${Error}未输入密钥，无法执行操作！"
        exit 1
    else
        API_KEY="$Api_Key"
    fi
    echo -e "${Info}你的密钥：${RED_ground}${API_KEY}${NC}"
    echo

    sed -i 's/^#\?Email=".*"/Email="'"${EMAIL}"'"/g' /etc/DDNS/.config
    sed -i 's/^#\?Api_key=".*"/Api_key="'"${API_KEY}"'"/g' /etc/DDNS/.config
}

# 设置解析的域名
set_domain(){
    # 检查是否有IPv4
    ipv4_check=$(curl -s ip.sb -4)
    if [ -n "$ipv4_check" ]; then
        echo -e "${Info}检测到IPv4地址: ${ipv4_check}"
        echo -e "${Tip}请输入您解析的IPv4域名 (或按回车跳过)"
        read -rp "IPv4域名: " DOmain
        if [ -z "$DOmain" ]; then
            echo -e "${Info}跳过IPv4域名设置。"
        else
            DOMAIN="$DOmain"
            echo -e "${Info}你的IPv4域名：${RED_ground}${DOMAIN}${NC}"
            echo
            # 更新 .config 文件中的IPv4域名
            sed -i 's/^#\?Domain=".*"/Domain="'"${DOMAIN}"'"/g' /etc/DDNS/.config
        fi
    else
        echo -e "${Info}未检测到IPv4地址，跳过IPv4域名设置。"
        echo
    fi

    # 检查是否有IPv6
    ipv6_check=$(curl -s ip.sb -6)
    if [ -n "$ipv6_check" ]; then
        echo -e "${Info}检测到IPv6地址: ${ipv6_check}"

        # 检查是否开启 IPv6 解析
        while true; do
            echo -e "${Tip}是否开启 IPv6 解析？(y/n)"
            read -rp "选择: " enable_ipv6

            if [[ "$enable_ipv6" =~ ^[Yy]$ ]]; then
                ipv6_set="true"
                # 更新 .config 文件中的 ipv6_set 为 true
                sed -i 's/^#\?ipv6_set=".*"/ipv6_set="true"/g' /etc/DDNS/.config

                echo -e "${Tip}请输入您解析的IPv6域名 (或按回车跳过)"
                read -rp "IPv6域名: " DOmainv6

                if [ -z "$DOmainv6" ]; then
                    echo -e "${Info}跳过IPv6域名设置。"
                    echo
                else
                    DOMAINV6="$DOmainv6"
                    echo -e "${Info}你的IPv6域名：${RED_ground}${DOMAINV6}${NC}"
                    echo
                    # 更新 .config 文件中的IPv6域名
                    sed -i 's/^#\?Domainv6=".*"/Domainv6="'"${DOMAINV6}"'"/g' /etc/DDNS/.config
                fi
                break
            elif [[ "$enable_ipv6" =~ ^[Nn]$ ]]; then
                ipv6_set="false"
                # 更新 .config 文件中的 ipv6_set 为 false
                sed -i 's/^#\?ipv6_set=".*"/ipv6_set="false"/g' /etc/DDNS/.config
                echo -e "${Info}IPv6 解析未开启，跳过 IPv6 域名设置。"
                echo
                break
            else
                echo -e "${Error}无效输入，请输入 'y' 或 'n'。"
            fi
        done
    else
        echo -e "${Info}未检测到IPv6地址，跳过IPv6域名设置。"
        echo
        ipv6_set="false"
        # 更新 .config 文件中的 ipv6_set 为 false
        sed -i 's/^#\?ipv6_set=".*"/ipv6_set="false"/g' /etc/DDNS/.config
    fi
}

# 设置Telegram参数
set_telegram_settings(){
    echo -e "${Info}开始配置Telegram通知设置..."
    echo

    echo -e "${Tip}请输入您的Telegram Bot Token，如果不使用Telegram通知请直接按 Enter 跳过"
    read -rp "Token: " Token
    if [ -n "$Token" ]; then
        TELEGRAM_BOT_TOKEN="$Token"
        echo -e "${Info}你的TOKEN：${RED_ground}$TELEGRAM_BOT_TOKEN${NC}"
        echo

        echo -e "${Tip}请输入您的Telegram Chat ID，如果不使用Telegram通知请直接按 Enter 跳过"
        read -rp "Chat ID: " Chat_ID
        if [ -n "$Chat_ID" ]; then
            TELEGRAM_CHAT_ID="$Chat_ID"
            echo -e "${Info}你的Chat ID：${RED_ground}$TELEGRAM_CHAT_ID${NC}"
            echo

            sed -i 's/^#\?Telegram_Bot_Token=".*"/Telegram_Bot_Token="'"${TELEGRAM_BOT_TOKEN}"'"/g' /etc/DDNS/.config
            sed -i 's/^#\?Telegram_Chat_ID=".*"/Telegram_Chat_ID="'"${TELEGRAM_CHAT_ID}"'"/g' /etc/DDNS/.config
        else
            echo -e "${Info}已跳过设置Telegram Chat ID"
        fi
    else
        echo -e "${Info}已跳过设置Telegram Bot Token和Chat ID"
        echo
        return  # 如果没有输入 Token，则直接返回，跳过设置 Chat ID 的步骤
    fi
}

# 运行DDNS服务
run_ddns(){
    service='[Unit]
Description=ddns
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/DDNS
ExecStart=bash DDNS

[Install]
WantedBy=multi-user.target'

    timer='[Unit]
Description=ddns timer

[Timer]
OnUnitActiveSec=60s
Unit=ddns.service

[Install]
WantedBy=multi-user.target'

    if [ ! -f "/etc/systemd/system/ddns.service" ] || [ ! -f "/etc/systemd/system/ddns.timer" ]; then
        echo -e "${Info}创建ddns定时任务..."
        echo "$service" >/etc/systemd/system/ddns.service
        echo "$timer" >/etc/systemd/system/ddns.timer
        echo -e "${Info}ddns定时任务已创建，每1分钟执行一次！"
        systemctl enable --now ddns.service >/dev/null 2>&1
        systemctl enable --now ddns.timer >/dev/null 2>&1
    else
        echo -e "${Tip}服务和定时器单元文件已存在，无需再次创建！"
    fi
}

# 重启DDNS服务
restart_ddns(){
    systemctl restart ddns.service >/dev/null 2>&1
    systemctl restart ddns.timer >/dev/null 2>&1
    echo -e "${Info}DDNS 已重启！"
}

# 停止DDNS服务
stop_ddns(){
    systemctl stop ddns.service >/dev/null 2>&1
    systemctl stop ddns.timer >/dev/null 2>&1
    echo -e "${Info}DDNS 已停止！"
}

# 检查是否安装DDNS
check_ddns_install(){
    if [ ! -f "/etc/DDNS/.config" ]; then
        echo -e "${Tip}DDNS 未安装，现在开始安装..."
        echo
        install_ddns
        set_cloudflare_api
        set_domain
        set_telegram_settings
        run_ddns
        echo -e "${Info}执行 ${GREEN}ddns${NC} 可呼出菜单！"
    else
        cop_info
        check_ddns_status
        if [[ "$ddns_status" == "running" ]]; then
            echo -e "${Info}DDNS：${GREEN}已安装${NC} 并 ${GREEN}已启动${NC}"
        else
            echo -e "${Tip}DDNS：${GREEN}已安装${NC} 但 ${RED}未启动${NC}"
            echo -e "${Tip}请选择 ${GREEN}4${NC} 重新配置 Cloudflare Api 或 ${GREEN}5${NC} 配置 Telegram 通知"
        fi
    echo
    go_ahead
    fi
}

check_root
check_curl
check_ddns_install
