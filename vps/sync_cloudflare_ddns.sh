#!/bin/bash
# ==========================================
# 描述：NAT VPS Cloudflare DDNS 自动更新核心脚本 (含自更新机制)
# 规则：遵循意图导向命名法
# ==========================================

# --- 版本与路径定义 ---
Define_ScriptVersion="1.0.0"
# [重要] 替换为 sync_cloudflare_ddns.sh 的真实 Raw 链接
Define_UpdateUrl="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/sync_cloudflare_ddns.sh"
Define_ConfigFile="/usr/local/etc/config_cloudflare_ddns.conf"
Define_SelfPath="/usr/local/bin/sync_cloudflare_ddns.sh"

# 验证配置文件是否存在并读取
Verify_Configuration() {
    if [ -f "$Define_ConfigFile" ]; then
        source "$Define_ConfigFile"
    else
        echo "[错误] 找不到配置文件 ${Define_ConfigFile}。请先运行安装脚本。"
        exit 1
    fi
}

# 检查并执行自身更新
Perform_SelfUpdate() {
    local Path_TempFile="/tmp/sync_cloudflare_ddns_new.sh"
    
    # 静默下载远程最新脚本
    curl -sL "$Define_UpdateUrl" -o "$Path_TempFile"
    
    # 若下载失败则跳过更新
    if [ ! -f "$Path_TempFile" ]; then
        return 0
    fi

    # 提取远程脚本的版本号
    local String_RemoteVersion=$(grep "^Define_ScriptVersion=" "$Path_TempFile" | cut -d'"' -f2 | head -n 1)

    # 简单的版本号比对（若远程存在且不等于当前版本，则执行更新）
    if [ -n "$String_RemoteVersion" ] && [ "$String_RemoteVersion" != "$Define_ScriptVersion" ]; then
        echo "[更新] 发现新版本 ${String_RemoteVersion} (当前版本: ${Define_ScriptVersion})。"
        echo "[更新] 正在应用更新..."
        
        # 覆盖本地脚本并赋予权限
        mv -f "$Path_TempFile" "$Define_SelfPath"
        chmod +x "$Define_SelfPath"
        
        echo "[更新] 正在重启更新后的脚本..."
        # 重新执行最新的脚本替换当前进程，并传递原始参数
        exec "$Define_SelfPath" "$@"
        exit 0
    else
        # 清理临时文件
        rm -f "$Path_TempFile"
    fi
}

# 获取当前 NAT VPS 的公网 IPv4
Fetch_PublicIp() {
    curl -s -4 https://api.ipify.org
}

# 访问 Cloudflare API 获取目标域名的唯一 Record ID
Query_RecordId() {
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${Config_ZoneId}/dns_records?type=A&name=${Config_DomainName}" \
         -H "Authorization: Bearer ${Config_ApiToken}" \
         -H "Content-Type: application/json" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
}

# 提交新的 IP 地址到 Cloudflare 进行更新
Commit_DnsUpdate() {
    local Inject_PublicIp=$1
    local Inject_RecordId=$2

    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${Config_ZoneId}/dns_records/${Inject_RecordId}" \
         -H "Authorization: Bearer ${Config_ApiToken}" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"${Config_DomainName}\",\"content\":\"${Inject_PublicIp}\",\"ttl\":120,\"proxied\":false}"
}

# ==========================================
# 主执行流 (Main Execution Flow)
# ==========================================
Perform_SelfUpdate
Verify_Configuration

# 1. 获取公网 IP
Fetched_PublicIp=$(Fetch_PublicIp)
if [ -z "$Fetched_PublicIp" ]; then
    echo "[错误] 获取公网 IP 失败。请检查网络连通性。"
    exit 1
fi

# 2. 查询目标域名的 Record ID
Queried_RecordId=$(Query_RecordId)
if [ -z "$Queried_RecordId" ]; then
    echo "[错误] 获取 Record ID 失败。请检查 API Token 和 Zone ID 是否正确，并确认 A 记录已存在。"
    exit 1
fi

# 3. 提交更新请求并获取结果
Committed_Result=$(Commit_DnsUpdate "$Fetched_PublicIp" "$Queried_RecordId")

# 4. 验证 API 响应
if echo "$Committed_Result" | grep -q '"success":true'; then
    echo "[成功] DDNS 已成功更新至 IP: ${Fetched_PublicIp}"
else
    echo "[错误] DDNS 更新失败。Cloudflare API 返回信息："
    echo "$Committed_Result"
fi
