#!/bin/bash
# ==========================================
# 描述：NAT VPS Cloudflare DDNS 自动更新核心脚本 (v1.2.3)
# 规则：遵循意图导向命名法
# 特性：支持双栈、自更新、IP防刷、防脏数据注入拦截、原生错误追踪
# ==========================================

# --- 版本与路径定义 ---
Define_ScriptVersion="1.2.3" 
Define_UpdateUrl="https://raw.githubusercontent.com/ExNG51/envi.ruleset/refs/heads/main/vps/sync_cloudflare_ddns.sh"
Define_ConfigFile="/usr/local/etc/config_cloudflare_ddns.conf"
Define_SelfPath="/usr/local/bin/sync_cloudflare_ddns.sh"

# 本地缓存文件路径 (用于比对 IP 是否发生变化，避免频繁调用 API)
Define_CacheIpv4="/tmp/cf_ddns_ipv4.cache"
Define_CacheIpv6="/tmp/cf_ddns_ipv6.cache"

# ==========================================
# 基础配置与更新模块
# ==========================================

Verify_Configuration() {
    if [ -f "$Define_ConfigFile" ]; then
        source "$Define_ConfigFile"
    else
        echo "[错误] 找不到配置文件 ${Define_ConfigFile}。"
        exit 1
    fi
}

Perform_SelfUpdate() {
    local Path_TempFile="/tmp/sync_cloudflare_ddns_new.sh"
    curl -sL "$Define_UpdateUrl" -o "$Path_TempFile"
    if [ ! -f "$Path_TempFile" ]; then return 0; fi

    local String_RemoteVersion=$(grep "^Define_ScriptVersion=" "$Path_TempFile" | cut -d'"' -f2 | head -n 1)

    if [ -n "$String_RemoteVersion" ] && [ "$String_RemoteVersion" != "$Define_ScriptVersion" ]; then
        echo "[更新] 发现新版本 ${String_RemoteVersion} (当前: ${Define_ScriptVersion})，正在更新..."
        mv -f "$Path_TempFile" "$Define_SelfPath"
        chmod +x "$Define_SelfPath"
        Notify_Telegram "🔄 [DDNS 自动更新]%0A已成功升级至版本: v${String_RemoteVersion}"
        exec "$Define_SelfPath" "$@"
        exit 0
    else
        rm -f "$Path_TempFile"
    fi
}

# ==========================================
# 消息推送模块 (Telegram)
# ==========================================

Notify_Telegram() {
    local Inject_Message=$1
    if [ -n "$Config_TgToken" ] && [ -n "$Config_TgChatId" ]; then
        local Format_Message="🌐 [${Config_DomainName}]%0A${Inject_Message}"
        curl -s -X POST "https://api.telegram.org/bot${Config_TgToken}/sendMessage" \
             -d "chat_id=${Config_TgChatId}" \
             -d "text=${Format_Message}" >/dev/null 2>&1
    fi
}

# ==========================================
# 网络请求与解析模块
# ==========================================

Fetch_PublicIpv4() { curl -s -4 -m 5 https://api.ipify.org; }
Fetch_PublicIpv6() { curl -s -6 -m 5 https://api64.ipify.org || curl -s -6 -m 5 https://ipv6.icanhazip.com; }

Query_DnsRecordId() {
    local Inject_RecordType=$1
    local Raw_Response=$(curl -s -m 10 -X GET "https://api.cloudflare.com/client/v4/zones/${Config_ZoneId}/dns_records?type=${Inject_RecordType}&name=${Config_DomainName}" \
         -H "Authorization: Bearer ${Config_ApiToken}" \
         -H "Content-Type: application/json")
    
    local Extracted_Id=$(echo "$Raw_Response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    
    if [ -z "$Extracted_Id" ]; then
        echo "[诊断日志] CF API 返回空或异常: $Raw_Response" >&2
    fi
    echo "$Extracted_Id"
}

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
# 核心执行流：双栈解析、严格校验与缓存控制
# ==========================================

Execute_DdnsProcess() {
    local Inject_Type=$1       
    local Inject_RecordType=$2 
    local Inject_CacheFile=$3  
    local Fetched_Ip=""

    # 1. 获取并严格校验公网 IP (防脏数据注入)
    if [ "$Inject_Type" == "IPv4" ]; then
        Fetched_Ip=$(Fetch_PublicIpv4)
        if [[ ! "$Fetched_Ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "[警告] 获取到的 IPv4 地址格式不合法 (可能遭遇网关阻断): ${Fetched_Ip}，跳过本次同步。"
            return 0
        fi
    else
        Fetched_Ip=$(Fetch_PublicIpv6)
        if [[ ! "$Fetched_Ip" =~ : ]] || [[ "$Fetched_Ip" =~ " " ]]; then
            echo "[警告] 获取到的 IPv6 地址格式不合法: ${Fetched_Ip}，跳过本次同步。"
            return 0
        fi
    fi

    if [ -z "$Fetched_Ip" ]; then
        echo "[提示] 未检测到公网 ${Inject_Type} 地址。"
        return 0
    fi

    # 2. 读取本地缓存，判断 IP 是否发生变化
    local Cached_Ip=""
    if [ -f "$Inject_CacheFile" ]; then
        Cached_Ip=$(cat "$Inject_CacheFile")
    fi

    if [ "$Fetched_Ip" == "$Cached_Ip" ]; then
        echo "[跳过] ${Inject_Type} 地址未改变 (${Fetched_Ip})，无需更新。"
        return 0
    fi

    echo "[信息] 检测到 ${Inject_Type} 发生变化：${Cached_Ip:-无} -> ${Fetched_Ip}"
    
    # 3. 拦截空 Record ID 报错
    local Queried_RecordId=$(Query_DnsRecordId "$Inject_RecordType")
    if [ -z "$Queried_RecordId" ]; then
        echo "[错误] 未找到 Cloudflare ${Inject_RecordType} 记录。"
        Notify_Telegram "❌ [前置错误]%0A获取 ${Inject_RecordType} 记录失败！%0A请检查：%0A1. 控制台是否预先创建了该记录%0A2. 域名的拼写是否有误%0A3. API Token 权限"
        return 1
    fi

    # 4. 提交更新并处理反馈
    local Committed_Result=$(Commit_DnsRecordUpdate "$Fetched_Ip" "$Queried_RecordId" "$Inject_RecordType")
    
    if echo "$Committed_Result" | grep -q '"success":true'; then
        echo "$Fetched_Ip" > "$Inject_CacheFile"
        echo "[成功] ${Inject_Type} (${Inject_RecordType}) 已更新至: ${Fetched_Ip}"
        Notify_Telegram "✅ [状态报告]%0A${Inject_Type} 解析已成功更新！%0A旧 IP: ${Cached_Ip:-无}%0A新 IP: ${Fetched_Ip}"
    else
        # [硬核排障] 截取真实报错并暴露给用户
        local Truncated_Result=$(echo "$Committed_Result" | cut -c 1-200)
        echo "[错误] ${Inject_Type} 更新失败: ${Committed_Result}"
        Notify_Telegram "❌ [严重错误]%0A${Inject_Type} 更新至 Cloudflare 失败！%0A异常截获IP: ${Fetched_Ip}%0A原生反馈:%0A${Truncated_Result}"
    fi
}

# ==========================================
# 主程序入口 (Main)
# ==========================================
Perform_SelfUpdate
Verify_Configuration

echo "=== 开始执行 DDNS 同步 (${Config_DomainName}) ==="
Execute_DdnsProcess "IPv4" "A" "$Define_CacheIpv4"
Execute_DdnsProcess "IPv6" "AAAA" "$Define_CacheIpv6"
echo "=== 同步任务执行完毕 ==="
