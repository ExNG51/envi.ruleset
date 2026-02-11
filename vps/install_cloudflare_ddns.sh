#!/bin/bash
# ==========================================
# 描述：Cloudflare DDNS 自动化安装与配置分离脚本 (支持双栈 IPv4/IPv6)
# 规则：遵循意图导向命名法
# ==========================================

# --- 路径与 URL 定义 ---
Define_ConfigFile="/usr/local/etc/config_cloudflare_ddns.conf"
Define_CoreScriptPath="/usr/local/bin/sync_cloudflare_ddns.sh"
Define_CoreScriptUrl="https://raw.githubusercontent.com/ExNG51/envi.ruleset/refs/heads/main/vps/sync_cloudflare_ddns.sh"

# 验证当前执行环境是否具备管理员权限
Verify_RootAccess() {
    if [ "$EUID" -ne 0 ]; then
        echo "[错误] 请使用 root 权限运行此安装脚本。"
        exit 1
    fi
}

# 收集用户输入的 Cloudflare 配置信息
Prompt_UserInput() {
    echo "=========================================="
    echo " Cloudflare DDNS 安装向导 (支持 IPv4 & IPv6 双栈) "
    echo "=========================================="
    echo "[提示] 脚本将自动检测 VPS 的公网 IPv4 和 IPv6 地址。"
    echo "[提示] 请确保在 Cloudflare 中已为您需要的 IP 类型创建了 A 或 AAAA 记录。"
    echo "------------------------------------------"
    read -p "请输入 Cloudflare API Token: " Input_ApiToken
    read -p "请输入 Cloudflare Zone ID: " Input_ZoneId
    read -p "请输入目标域名 (例如: ddns.example.com): " Input_DomainName
    read -p "请输入定时任务间隔分钟数 (默认: 5): " Input_CronInterval
    
    # 设定定时任务默认值为 5 分钟
    if [ -z "$Input_CronInterval" ]; then
        Input_CronInterval="5"
    fi
}

# 动态生成配置文件并写入目标路径
Generate_Configuration() {
    echo "[信息] 正在生成配置文件至 ${Define_ConfigFile}..."
    
    # 写入独立的配置文件，隔离运行时变量
    cat << EOF > "$Define_ConfigFile"
Config_ApiToken="${Input_ApiToken}"
Config_ZoneId="${Input_ZoneId}"
Config_DomainName="${Input_DomainName}"
EOF
    # 保护敏感配置，仅限 root 读写
    chmod 600 "$Define_ConfigFile" 
}

# 从 GitHub 拉取并部署核心同步脚本
Deploy_CoreScript() {
    echo "[信息] 正在从 GitHub 下载核心同步脚本..."
    curl -sL "$Define_CoreScriptUrl" -o "$Define_CoreScriptPath"
    
    if [ ! -f "$Define_CoreScriptPath" ]; then
         echo "[错误] 核心脚本下载失败，请检查 URL 是否正确。"
         exit 1
    fi
    # 赋予执行权限
    chmod +x "$Define_CoreScriptPath"
}

# 配置系统级定时任务以实现自动化
Configure_CronJob() {
    local Cron_Expression="*/${Input_CronInterval} * * * * ${Define_CoreScriptPath} >/dev/null 2>&1"
    
    echo "[信息] 正在配置系统定时任务..."
    # 移除旧的同名任务以防重复，并添加新任务
    (crontab -l 2>/dev/null | grep -v "$Define_CoreScriptPath"; echo "$Cron_Expression") | crontab -
    
    echo "=========================================="
    echo " 安装完成！                               "
    echo " 脚本将定期在后台运行，并支持从 GitHub 更新。"
    echo "=========================================="
}

# ==========================================
# 安装向导主执行流
# ==========================================
Verify_RootAccess
Prompt_UserInput
Generate_Configuration
Deploy_CoreScript
Configure_CronJob

# 立即触发一次初次运行以验证配置
echo "[信息] 正在首次运行 DDNS 同步脚本..."
$Define_CoreScriptPath
