#!/bin/bash
# ==========================================
# 描述：Shadowsocks-Rust 自动化部署脚本
# 规则：遵循意图导向命名法 (动词+核心名词)
# ==========================================

# ==========================================
# 1. 颜色与 UI 格式化定义
# ==========================================
Define_ColorRed='\033[0;31m'
Define_ColorGreen='\033[0;32m'
Define_ColorYellow='\033[0;33m'
Define_ColorCyan='\033[0;36m'
Define_ColorReset='\033[0m'

Print_Info() { echo -e "${Define_ColorCyan}[信息]${Define_ColorReset} $1"; }
Print_Success() { echo -e "${Define_ColorGreen}[成功]${Define_ColorReset} $1"; }
Print_Warning() { echo -e "${Define_ColorYellow}[警告]${Define_ColorReset} $1"; }
Print_Error() { echo -e "${Define_ColorRed}[错误]${Define_ColorReset} $1"; }
Print_Prompt() { echo -e "${Define_ColorYellow}[交互]${Define_ColorReset} $1 \c"; }

# ==========================================
# 2. 全局状态与路径定义
# ==========================================
State_ServiceManager="unknown"
State_PackageManager="unknown"
Config_InstallPath="/opt/ss-rust"
Config_SystemdPath="/etc/systemd/system/ss-rust.service"
Config_OpenrcPath="/etc/init.d/ss-rust"
Config_FallbackVersion="1.24.0"

Node_Port=""
Node_Psk=""

# ==========================================
# 3. 基础环境校验模块
# ==========================================
Verify_RootAccess() {
    if [ "$EUID" -ne 0 ]; then
        Print_Error "权限不足！请使用 root 身份运行此脚本。"
        exit 1
    fi
}

Detect_ServiceManager() {
    if command -v systemctl >/dev/null 2>&1; then
        State_ServiceManager="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        State_ServiceManager="openrc"
    else
        Print_Error "未找到受支持的服务管理器 (systemd/openrc)。"
        exit 1
    fi
}

Verify_AlpineSystem() {
    if [ -f /etc/alpine-release ]; then return 0; else return 1; fi
}

Detect_PackageManager() {
    if command -v apk >/dev/null 2>&1; then State_PackageManager="apk"
    elif command -v apt >/dev/null 2>&1; then State_PackageManager="apt"
    elif command -v dnf >/dev/null 2>&1; then State_PackageManager="dnf"
    elif command -v yum >/dev/null 2>&1; then State_PackageManager="yum"
    else Print_Error "未找到受支持的包管理器。"; exit 1; fi
}

Install_SystemDependencies() {
    Print_Info "正在检查并安装必要的系统依赖 (包含 CA 根证书)..."
    local Required_Packages=(wget tar openssl curl net-tools ca-certificates)
    if [ "$State_PackageManager" = "apk" ] || [ "$State_PackageManager" = "yum" ] || [ "$State_PackageManager" = "dnf" ]; then
        Required_Packages+=(xz)
    else
        Required_Packages+=(xz-utils)
    fi
    for Inject_Package in "${Required_Packages[@]}"; do
        if [ "$State_PackageManager" = "apk" ]; then apk add --quiet --no-cache "$Inject_Package"
        elif [ "$State_PackageManager" = "apt" ]; then apt-get install -y -qq "$Inject_Package" >/dev/null
        elif [ "$State_PackageManager" = "dnf" ]; then dnf install -y -q "$Inject_Package" >/dev/null
        elif [ "$State_PackageManager" = "yum" ]; then yum install -y -q "$Inject_Package" >/dev/null
        fi
    done
    Print_Success "系统依赖就绪。"
}

# ==========================================
# 4. 核心功能：获取、更新与清理模块
# ==========================================
Fetch_LatestVersion() {
    Print_Info "正在向 GitHub 请求最新版本号..." >&2
    local Fetched_Version=$(curl -s -m 5 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$Fetched_Version" ]; then
        Print_Warning "API 速率限制触发，回退至版本 v${Config_FallbackVersion}" >&2
        echo "$Config_FallbackVersion"
    else
        echo "$Fetched_Version"
    fi
}

Generate_DownloadUrl() {
    local Inject_Version=$1
    local System_Arch=$(uname -m)
    local Package_Name=""

    if Verify_AlpineSystem; then
        case $System_Arch in
            x86_64) Package_Name="shadowsocks-v${Inject_Version}.x86_64-unknown-linux-musl.tar.xz" ;;
            aarch64) Package_Name="shadowsocks-v${Inject_Version}.aarch64-unknown-linux-musl.tar.xz" ;;
            *) Print_Error "不支持的系统架构: $System_Arch" >&2; exit 1 ;;
        esac
    else
        case $System_Arch in
            x86_64) Package_Name="shadowsocks-v${Inject_Version}.x86_64-unknown-linux-gnu.tar.xz" ;;
            aarch64) Package_Name="shadowsocks-v${Inject_Version}.aarch64-unknown-linux-gnu.tar.xz" ;;
            *) Print_Error "不支持的系统架构: $System_Arch" >&2; exit 1 ;;
        esac
    fi
    echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${Inject_Version}/${Package_Name}"
}

Execute_CoreUpdate() {
    if [ ! -d "$Config_InstallPath" ]; then Print_Error "未安装服务端，无法执行更新。"; exit 1; fi
    local Target_Version=$(Fetch_LatestVersion)
    local Download_Url=$(Generate_DownloadUrl "$Target_Version")
    local Temp_Dir="/tmp/ss_rust_update_$$"
    
    Print_Info "开始安全升级至版本 v${Target_Version}..."
    mkdir -p "$Temp_Dir" && cd "$Temp_Dir" || exit 1
    if ! wget --secure-protocol=TLSv1_2 --https-only -q --show-progress "$Download_Url"; then
        Print_Error "下载失败，更新已中止以保护现有服务。"; rm -rf "$Temp_Dir"; exit 1
    fi
    tar -xf *.tar.xz
    if [ ! -f "ssserver" ]; then Print_Error "解压失败，更新中止。"; rm -rf "$Temp_Dir"; exit 1; fi

    if [ "$State_ServiceManager" = "systemd" ]; then systemctl stop ss-rust; else rc-service ss-rust stop; fi
    mv -f ssserver "$Config_InstallPath/ssserver"
    chmod 755 "$Config_InstallPath/ssserver"
    rm -rf "$Temp_Dir"
    if [ "$State_ServiceManager" = "systemd" ]; then systemctl restart ss-rust; else rc-service ss-rust restart; fi
    Print_Success "更新完成！服务已恢复运行。"
}

# [修复] 将纯粹的清理逻辑与 exit 分离，解决覆盖安装时的退坑问题
Purge_ServiceResidue() {
    if [ "$State_ServiceManager" = "systemd" ]; then
        systemctl stop ss-rust >/dev/null 2>&1
        systemctl disable ss-rust >/dev/null 2>&1
        rm -f "$Config_SystemdPath"
        systemctl daemon-reload
    else
        rc-service ss-rust stop >/dev/null 2>&1
        rc-update del ss-rust default >/dev/null 2>&1
        rm -f "$Config_OpenrcPath"
    fi
    rm -rf "$Config_InstallPath"
}

Execute_ServiceRemoval() {
    if [ -d "$Config_InstallPath" ] || [ -f "$Config_SystemdPath" ]; then
        Print_Info "正在深度清理 Shadowsocks-Rust 安装残留..."
        Purge_ServiceResidue
        Print_Success "彻底卸载完毕，系统已恢复纯净状态。"
    else
        Print_Warning "当前系统未检测到安装记录。"
    fi
    exit 0
}

# ==========================================
# 5. 配置解析与修改面板 (新增功能模块)
# ==========================================
Extract_NodeConfig() {
    if [ ! -f "$Config_InstallPath/config.json" ]; then return 1; fi
    Node_Port=$(grep '"server_port"' "$Config_InstallPath/config.json" | sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/')
    Node_Psk=$(grep '"password"' "$Config_InstallPath/config.json" | sed -E 's/.*"password":[[:space:]]*"([^"]+)".*/\1/')
}

Display_NodeInfo() {
    Extract_NodeConfig
    local Server_Ip=$(curl -s -m 5 -4 http://api.ipify.org || curl -s -m 5 -6 https://api64.ipify.org)
    echo "=========================================================="
    Print_Success "当前节点连接信息:"
    echo -e "${Define_ColorYellow}$(hostname) = ss, ${Server_Ip}, ${Node_Port}, encrypt-method=2022-blake3-aes-128-gcm, password=${Node_Psk}, udp-relay=true${Define_ColorReset}"
    echo "=========================================================="
}

Update_LocalConfig() {
    Extract_NodeConfig
    echo "------------------------------------------"
    Print_Info "当前监听端口: ${Define_ColorYellow}${Node_Port}${Define_ColorReset}"
    Print_Info "当前连接密码: ${Define_ColorYellow}${Node_Psk}${Define_ColorReset}"
    echo "------------------------------------------"
    
    local New_Port="$Node_Port"
    local New_Psk="$Node_Psk"

    Print_Prompt "请输入新端口 (直接回车则不修改): "
    read Input_Port
    if [ -n "$Input_Port" ]; then
        if [[ "$Input_Port" =~ ^[0-9]+$ ]] && [ "$Input_Port" -ge 1 ] && [ "$Input_Port" -le 65535 ]; then
            if ! netstat -tuln | grep -q ":$Input_Port "; then New_Port="$Input_Port"
            else Print_Error "端口 $Input_Port 已被占用！修改已取消。"; return 1; fi
        else
            Print_Error "无效的端口号！修改已取消。"; return 1
        fi
    fi

    Print_Prompt "请输入新密码 (直接回车则不修改): "
    read Input_Psk
    if [ -n "$Input_Psk" ]; then New_Psk="$Input_Psk"; fi

    # 重新写入配置
    cat >|"$Config_InstallPath/config.json" <<EOF
{
    "server": "::",
    "server_port": $New_Port,
    "password": "$New_Psk",
    "method": "2022-blake3-aes-128-gcm",
    "mode": "tcp_and_udp"
}
EOF
    chown nobody "$Config_InstallPath/config.json" 2>/dev/null || true
    chmod 400 "$Config_InstallPath/config.json"
    
    Print_Info "配置已更新，正在重启服务应用更改..."
    if [ "$State_ServiceManager" = "systemd" ]; then systemctl restart ss-rust; else rc-service ss-rust restart; fi
    
    Display_NodeInfo
}

Render_InteractiveMenu() {
    clear
    echo "=========================================================="
    echo -e "      ${Define_ColorCyan}Shadowsocks-Rust 管理面板${Define_ColorReset}"
    echo "=========================================================="
    echo -e " ${Define_ColorGreen}1.${Define_ColorReset} 查看当前节点配置"
    echo -e " ${Define_ColorGreen}2.${Define_ColorReset} 修改端口与密码"
    echo -e " ${Define_ColorGreen}3.${Define_ColorReset} 更新核心服务端"
    echo -e " ${Define_ColorGreen}4.${Define_ColorReset} 彻底卸载服务"
    echo -e " ${Define_ColorYellow}0.${Define_ColorReset} 退出脚本"
    echo "=========================================================="
    Print_Prompt "请输入对应的数字选项: "
    read Menu_Choice
    case "$Menu_Choice" in
        1) Display_NodeInfo ;;
        2) Update_LocalConfig ;;
        3) Execute_CoreUpdate ;;
        4) 
           Print_Prompt "确定要彻底卸载 Shadowsocks-Rust 吗？[y/N]: "
           read Confirm_Uninstall
           if [[ "$Confirm_Uninstall" =~ ^[Yy]$ ]]; then Execute_ServiceRemoval; fi
           ;;
        0) Print_Info "已退出。"; exit 0 ;;
        *) Print_Error "无效的选项。" ;;
    esac
}

# ==========================================
# 6. 安全配置与全新部署模块
# ==========================================
Configure_SecurityRules() {
    local Inject_Port=$1
    local Inject_Psk=$2

    if [ -z "$Inject_Port" ]; then
        Print_Prompt "是否需要手动指定监听端口？ [y/N]: "
        read Confirm_Port
        if [[ "$Confirm_Port" =~ ^[Yy]$ ]]; then
            while true; do
                Print_Prompt "请输入指定端口 (1-65535): "
                read Input_ManualPort
                if [[ "$Input_ManualPort" =~ ^[0-9]+$ ]] && [ "$Input_ManualPort" -ge 1 ] && [ "$Input_ManualPort" -le 65535 ]; then
                    if ! netstat -tuln | grep -q ":$Input_ManualPort "; then Inject_Port="$Input_ManualPort"; break
                    else Print_Error "端口 $Input_ManualPort 已被占用，请更换。"; fi
                else
                    Print_Error "无效的端口号，请输入 1-65535 之间的数字。"; fi
            done
        else
            while true; do
                Inject_Port=$(shuf -i 10000-60000 -n 1)
                if ! netstat -tuln | grep -q ":$Inject_Port "; then break; fi
            done
            Print_Info "已分配随机安全端口: ${Define_ColorYellow}${Inject_Port}${Define_ColorReset}"
        fi
    fi

    if [ -z "$Inject_Psk" ]; then
        Print_Prompt "是否需要手动指定连接密码？ [y/N]: "
        read Confirm_Psk
        if [[ "$Confirm_Psk" =~ ^[Yy]$ ]]; then
            while true; do
                Print_Prompt "请输入自定义密码: "
                read Input_ManualPsk
                if [ -n "$Input_ManualPsk" ]; then Inject_Psk="$Input_ManualPsk"; break
                else Print_Error "密码不能为空。"; fi
            done
        else
            Inject_Psk=$(openssl rand -base64 16)
            Print_Info "已自动生成强加密密钥。"
        fi
    fi

    cat >|"$Config_InstallPath/config.json" <<EOF
{
    "server": "::",
    "server_port": $Inject_Port,
    "password": "$Inject_Psk",
    "method": "2022-blake3-aes-128-gcm",
    "mode": "tcp_and_udp"
}
EOF
    chown nobody "$Config_InstallPath/config.json" 2>/dev/null || true
    chmod 400 "$Config_InstallPath/config.json"
}

Generate_ServiceDaemon() {
    Print_Info "正在创建降权沙盒守护进程..."
    if [ "$State_ServiceManager" = "systemd" ]; then
        cat >|"$Config_SystemdPath" <<EOF
[Unit]
Description=Shadowsocks Rust Secure Daemon
After=network.target

[Service]
Type=simple
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=$Config_InstallPath/ssserver -c $Config_InstallPath/config.json
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-rust >/dev/null 2>&1
        systemctl restart ss-rust
    else
        cat >|"$Config_OpenrcPath" <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust Secure Server"
command_user="nobody"
command="$Config_InstallPath/ssserver"
command_args="-c $Config_InstallPath/config.json"
command_background="yes"
pidfile="/run/ss-rust.pid"
output_log="/var/log/ss-rust.log"
error_log="/var/log/ss-rust-error.log"

depend() {
    need net
    after network
}
EOF
        chmod +x "$Config_OpenrcPath"
        rc-update add ss-rust default >/dev/null 2>&1
        rc-service ss-rust restart >/dev/null 2>&1
    fi
}

Deploy_ShadowsocksServer() {
    local Input_Port=$1
    local Input_Psk=$2

    # [修复] 调用 Purge_ServiceResidue 解决卸载中断装机流程的 Bug
    if [ -d "$Config_InstallPath" ]; then
        Print_Warning "检测到系统已安装 Shadowsocks-Rust。"
        Print_Prompt "是否要覆盖重装并清除原有配置？[y/N]: "
        read Confirm_Overwrite
        if [[ ! "$Confirm_Overwrite" =~ ^[Yy]$ ]]; then
            Print_Info "操作已取消。"
            exit 0
        fi
        Purge_ServiceResidue
    fi

    Install_SystemDependencies
    local Target_Version=$(Fetch_LatestVersion)
    local Download_Url=$(Generate_DownloadUrl "$Target_Version")
    
    mkdir -p "$Config_InstallPath" && cd "$Config_InstallPath" || exit 1
    Print_Info "正在通过强制 TLS 下载 v${Target_Version} 核心包..."
    
    if ! wget --secure-protocol=TLSv1_2 --https-only -q --show-progress "$Download_Url"; then
        Print_Error "核心包下载失败或证书不安全，部署中止。"; rm -rf "$Config_InstallPath"; exit 1
    fi

    tar -xf *.tar.xz
    rm -f *.tar.xz sslocal ssmanager ssservice ssurl
    chmod 755 ssserver

    Configure_SecurityRules "$Input_Port" "$Input_Psk"
    Generate_ServiceDaemon
    Display_NodeInfo
}

# ==========================================
# 7. 主程序入口与路由分发
# ==========================================
Verify_RootAccess
Detect_ServiceManager
Detect_PackageManager

# 若未带任何参数运行，且检测到已安装，则触发可视化主菜单
if [ "$#" -eq 0 ]; then
    if [ -d "$Config_InstallPath" ]; then
        Render_InteractiveMenu
        exit 0
    else
        Deploy_ShadowsocksServer "" ""
        exit 0
    fi
fi

# 带参数运行的 CLI 解析逻辑
User_Port=""
User_Psk=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        "uninstall") Execute_ServiceRemoval ;;
        "update") Execute_CoreUpdate ;;
        "-p")
            shift
            if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
                if ! netstat -tuln | grep -q ":$1 "; then User_Port="$1"
                else Print_Error "端口 $1 已被占用！"; exit 1; fi
            else Print_Error "无效的端口号格式。"; exit 1; fi
            ;;
        "-psk")
            shift; User_Psk="$1"
            ;;
        *)
            Print_Info "使用帮助: $0 [-p 端口] [-psk 密码] [update|uninstall]"
            exit 1
            ;;
    esac
    shift
done

Deploy_ShadowsocksServer "$User_Port" "$User_Psk"
