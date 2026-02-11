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

# ==========================================
# 2. 全局状态与路径定义
# ==========================================
State_ServiceManager="unknown"
State_PackageManager="unknown"
Config_InstallPath="/opt/ss-rust"
Config_SystemdPath="/etc/systemd/system/ss-rust.service"
Config_OpenrcPath="/etc/init.d/ss-rust"
Config_FallbackVersion="1.23.0" # 当 GitHub API 受限时的回退版本

# ==========================================
# 3. 基础环境校验模块
# ==========================================
Verify_RootAccess() {
    if [ "$EUID" -ne 0 ]; then
        Print_Error "权限不足！请使用 root 身份运行此安全脚本。"
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
    if command -v apk >/dev/null 2>&1; then
        State_PackageManager="apk"
    elif command -v apt >/dev/null 2>&1; then
        State_PackageManager="apt"
    elif command -v dnf >/dev/null 2>&1; then
        State_PackageManager="dnf"
    elif command -v yum >/dev/null 2>&1; then
        State_PackageManager="yum"
    else
        Print_Error "未找到受支持的包管理器 (apk/apt/dnf/yum)。"
        exit 1
    fi
}

Install_SystemDependencies() {
    Print_Info "正在检查并安装必要的系统依赖 (包含 CA 根证书)..."
    # 新增 ca-certificates 确保 TLS 校验的合法性
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
# 4. 核心功能：获取、安全更新与卸载模块
# ==========================================
Fetch_LatestVersion() {
    Print_Info "正在向 GitHub 请求最新版本号..."
    local Fetched_Version=$(curl -s -m 5 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$Fetched_Version" ]; then
        Print_Warning "获取最新版本失败 (API 速率限制)，安全回退至稳定版 v${Config_FallbackVersion}"
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
            *) Print_Error "不支持的系统架构: $System_Arch"; exit 1 ;;
        esac
    else
        case $System_Arch in
            x86_64) Package_Name="shadowsocks-v${Inject_Version}.x86_64-unknown-linux-gnu.tar.xz" ;;
            aarch64) Package_Name="shadowsocks-v${Inject_Version}.aarch64-unknown-linux-gnu.tar.xz" ;;
            *) Print_Error "不支持的系统架构: $System_Arch"; exit 1 ;;
        esac
    fi
    echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${Inject_Version}/${Package_Name}"
}

Execute_CoreUpdate() {
    if [ ! -d "$Config_InstallPath" ]; then
        Print_Error "未检测到安装记录，无法执行更新。"
        exit 1
    fi

    local Target_Version=$(Fetch_LatestVersion)
    local Download_Url=$(Generate_DownloadUrl "$Target_Version")
    local Temp_Dir="/tmp/ss_rust_update_$$"
    
    Print_Info "开始安全升级至版本 v${Target_Version}..."
    mkdir -p "$Temp_Dir" && cd "$Temp_Dir" || exit 1

    Print_Info "正在通过强制 TLS 下载核心组件..."
    # 安全加固：强制 HTTPS 与 TLSv1.2 以上协议，防中间人劫持
    if ! wget --secure-protocol=TLSv1_2 --https-only -q --show-progress "$Download_Url"; then
        Print_Error "核心包下载失败或证书校验不通过，更新已中止以保护现有服务。"
        rm -rf "$Temp_Dir"
        exit 1
    fi

    tar -xf *.tar.xz
    if [ ! -f "ssserver" ]; then
        Print_Error "解压产物缺失核心程序，更新中止。"
        rm -rf "$Temp_Dir"
        exit 1
    fi

    Print_Info "校验通过，正在替换核心并重启服务..."
    if [ "$State_ServiceManager" = "systemd" ]; then systemctl stop ss-rust; else rc-service ss-rust stop; fi
    
    mv -f ssserver "$Config_InstallPath/ssserver"
    chmod 755 "$Config_InstallPath/ssserver"
    rm -rf "$Temp_Dir"

    if [ "$State_ServiceManager" = "systemd" ]; then systemctl restart ss-rust; else rc-service ss-rust restart; fi
    Print_Success "更新完成！Shadowsocks-Rust 服务已恢复运行。"
    exit 0
}

Execute_ServiceRemoval() {
    if [ -d "$Config_InstallPath" ] || [ -f "$Config_SystemdPath" ] || [ -f "$Config_OpenrcPath" ]; then
        Print_Info "正在深度清理 Shadowsocks-Rust 安装残留..."
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
        Print_Success "卸载完毕。系统已恢复纯净状态。"
    else
        Print_Warning "当前系统未检测到安装记录。"
    fi
    exit 0
}

# ==========================================
# 5. 安全配置与部署模块
# ==========================================
Configure_SecurityRules() {
    local Inject_Port=$1
    local Inject_Psk=$2

    if [ -z "$Inject_Port" ]; then
        while true; do
            Inject_Port=$(shuf -i 10000-60000 -n 1)
            if ! netstat -tuln | grep -q ":$Inject_Port "; then break; fi
        done
        Print_Info "未指定端口，已分配随机安全端口: ${Define_ColorYellow}${Inject_Port}${Define_ColorReset}"
    fi

    if [ -z "$Inject_Psk" ]; then
        Inject_Psk=$(openssl rand -base64 16)
        Print_Info "未指定密码，已生成强加密密钥。"
    fi

    # 写入配置文件
    cat >|"$Config_InstallPath/config.json" <<EOF
{
    "server": "::",
    "server_port": $Inject_Port,
    "password": "$Inject_Psk",
    "method": "2022-blake3-aes-128-gcm",
    "mode": "tcp_and_udp"
}
EOF

    # 安全加固：锁定文件权限，防越权读取
    # 将所有权交接给 nobody（跨平台低权限标准账户），并设置为仅 owner 可读 (400)
    chown nobody "$Config_InstallPath/config.json" 2>/dev/null || true
    chmod 400 "$Config_InstallPath/config.json"
    Print_Success "配置文件权限已被锁定 (chmod 400)。"

    Node_Port="$Inject_Port"
    Node_Psk="$Inject_Psk"
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
# 安全加固：剥夺 Root 权限，使用系统默认的低权限账户 nobody 运行
User=nobody
# 赋予 nobody 绑定 1024 以下低位端口的特权（如果配置了低端口的话）
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
# 安全加固：在 Alpine 体系下同样降权为 nobody 运行
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
    Print_Success "服务进程已安全启动。"
}

Deploy_ShadowsocksServer() {
    local Input_Port=$1
    local Input_Psk=$2

    # 拦截误触
    if [ -d "$Config_InstallPath" ]; then
        Print_Warning "检测到系统已安装 Shadowsocks-Rust。"
        read -p "是否要覆盖重装并清除原有配置？(y/N): " Confirm_Overwrite
        if [[ ! "$Confirm_Overwrite" =~ ^[Yy]$ ]]; then
            Print_Info "操作已取消。如需更新版本，请运行: $0 update"
            exit 0
        fi
        Execute_ServiceRemoval >/dev/null
    fi

    Install_SystemDependencies
    local Target_Version=$(Fetch_LatestVersion)
    local Download_Url=$(Generate_DownloadUrl "$Target_Version")
    
    mkdir -p "$Config_InstallPath" && cd "$Config_InstallPath" || exit 1
    Print_Info "正在通过强制 TLS 下载 v${Target_Version} 核心包..."
    
    # 安全加固下载
    if ! wget --secure-protocol=TLSv1_2 --https-only -q --show-progress "$Download_Url"; then
        Print_Error "核心包下载失败或证书不安全，部署中止。"
        rm -rf "$Config_InstallPath"
        exit 1
    fi

    tar -xf *.tar.xz
    rm -f *.tar.xz sslocal ssmanager ssservice ssurl
    chmod 755 ssserver

    Configure_SecurityRules "$Input_Port" "$Input_Psk"
    Generate_ServiceDaemon

    local Server_Ip=$(curl -s -m 5 -4 http://api.ipify.org || curl -s -m 5 -6 https://api64.ipify.org)
    
    echo "=========================================================="
    Print_Success "企业级高可用 Shadowsocks-Rust 部署完毕！"
    echo -e "${Define_ColorCyan}节点连接信息 (Surge 格式):${Define_ColorReset}"
    echo -e "${Define_ColorYellow}$(hostname) = ss, ${Server_Ip}, ${Node_Port}, encrypt-method=2022-blake3-aes-128-gcm, password=${Node_Psk}, udp-relay=true${Define_ColorReset}"
    echo "=========================================================="
}

# ==========================================
# 6. 主程序入口与参数解析
# ==========================================
Verify_RootAccess
Detect_ServiceManager
Detect_PackageManager

User_Port=""
User_Psk=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        "uninstall") Execute_ServiceRemoval ;;
        "update") Execute_CoreUpdate ;;
        "-p")
            shift
            if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
                if ! netstat -tuln | grep -q ":$1 "; then
                    User_Port="$1"
                else
                    Print_Error "端口 $1 已被占用！"
                    exit 1
                fi
            else
                Print_Error "无效的端口号格式。"
                exit 1
            fi
            ;;
        "-psk")
            shift
            User_Psk="$1"
            ;;
        *)
            Print_Info "使用帮助: $0 [-p 指定端口] [-psk 指定密码] [update|uninstall]"
            exit 1
            ;;
    esac
    shift
done
Deploy_ShadowsocksServer "$User_Port" "$User_Psk"
