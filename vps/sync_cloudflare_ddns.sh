#!/bin/bash
# ==========================================
# 描述：NAT VPS Cloudflare DDNS 自动更新核心脚本 (支持双栈与自更新)
# 规则：遵循意图导向命名法
# ==========================================

# --- 版本与路径定义 ---
Define_ScriptVersion="1.1.0" 
Define_UpdateUrl="https://raw.githubusercontent.com/ExNG51/envi.ruleset/refs/heads/main/vps/install_cloudflare_ddns.sh"
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
    if [ ! -f "$Path_TempFile" ]; then
        return 0
    fi

    local String_RemoteVersion=$(grep "^Define_ScriptVersion=" "$Path_TempFile" | cut -d'"' -f2 | head -n 1)

    if [ -n "$String_RemoteVersion" ] && [ "$String_RemoteVersion" != "$Define_ScriptVersion" ]; then
        echo "[更新] 发现新版本 ${String_RemoteVersion} (当前版本: ${Define_ScriptVersion})。"
        mv -f "$Path_TempFile" "$Define_SelfPath"
        chmod +x "$Define_SelfPath"
        echo "[更新] 正在重启更新后的脚本..."
        exec "$Define_SelfPath" "$@"
        exit 0
    else
        rm -f "$Path_TempFile"
    fi
}

# 获取当前 NAT VPS 的公网 IPv4 (-m 5 设置超时防止阻塞)
Fetch_PublicIpv4() {
    curl -s -4 -m 5 https://api.ipify.org
}

# 获取当前 NAT VPS 的公网 IPv6 (使用 api64 或 icanhazip 保证 v6 穿透)
Fetch_PublicIpv6() {
    curl -s -6 -m 5 https://api64.ipify.org || curl -s -6 -m 5 https://ipv6.icanhazip.com
}

# 访问 Cloudflare API 获取目标域名的唯一 Record ID (参数化类型: A 或 AAAA)
Query_DnsRecordId() {
    local Inject_RecordType=$1
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${Config_ZoneId}/dns_records?type=${Inject_RecordType}&name=${Config_DomainName}" \
         -H "Authorization: Bearer ${Config_ApiToken}" \
         -H "Content-Type: application/json" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
}

# 提交新的 IP 地址到 Cloudflare 进行更新 (参数化 IP、ID 和类型)
Commit_DnsRecordUpdate() {
    local Inject_IpAddress=$1
    local Inject_RecordId=$2
    local Inject_RecordType=$3

    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${Config_ZoneId}/dns_records/${Inject_RecordId}" \
         -H "Authorization: Bearer ${Config_ApiToken}" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"${Inject_RecordType}\",\"name\":\"${Config_DomainName}\",\"content\":\"${Inject_IpAddress}\",\"ttl\":120,\"proxied\":false}"
}

# ==========================================
# 主执行流 (Main Execution Flow)
# ==========================================
Perform_SelfUpdate
Verify_Configuration

echo "[信息] 开始执行 DDNS 同步 (${Config_DomainName})..."

# ------------------------------------------
# 流程 1：处理 IPv4 (A 记录)
# ------------------------------------------
Fetched_Ipv4=$(Fetch_PublicIpv4)
if [ -n "$Fetched_Ipv4" ]; then
    Queried_RecordId_A=$(Query_DnsRecordId "A")
    if [ -n "$Queried_RecordId_A" ]; then
        Committed_Result_A=$(Commit_DnsRecordUpdate "$Fetched_Ipv4" "$Queried_RecordId_A" "A")
        if echo "$Committed_Result_A" | grep -q '"success":true'; then
            echo "[成功] IPv4 (A) 已更新至: ${Fetched_Ipv4}"
        else
            echo "[错误] IPv4 (A) 更新失败: ${Committed_Result_A}"
        fi
    else
        echo "[警告] 未在 Cloudflare 找到 A 记录，跳过 IPv4 更新。"
    fi
else
    echo "[提示] 当前环境未检测到公网 IPv4 地址。"
fi

# ------------------------------------------
# 流程 2：处理 IPv6 (AAAA 记录)
# ------------------------------------------
Fetched_Ipv6=$(Fetch_PublicIpv6)
if [ -n "$Fetched_Ipv6" ]; then
    Queried_RecordId_AAAA=$(Query_DnsRecordId "AAAA")
    if [ -n "$Queried_RecordId_AAAA" ]; then
        Committed_Result_AAAA=$(Commit_DnsRecordUpdate "$Fetched_Ipv6" "$Queried_RecordId_AAAA" "AAAA")
        if echo "$Committed_Result_AAAA" | grep -q '"success":true'; then
            echo "[成功] IPv6 (AAAA) 已更新至: ${Fetched_Ipv6}"
        else
            echo "[错误] IPv6 (AAAA) 更新失败: ${Committed_Result_AAAA}"
        fi
    else
        echo "[警告] 未在 Cloudflare 找到 AAAA 记录，跳过 IPv6 更新。"
    fi
else
    echo "[提示] 当前环境未检测到公网 IPv6 地址。"
fi
