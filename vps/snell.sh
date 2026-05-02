#!/usr/bin/env bash
set -Eeuo pipefail

# Snell 官方二进制安装脚本。可通过环境变量覆盖默认配置：
#   SNELL_VERSION=5.0.1 SNELL_PORT=16386 SNELL_IPV6=false bash snell.sh

SNELL_VERSION="${SNELL_VERSION:-5.0.1}"
SNELL_PORT="${SNELL_PORT:-16386}"
SNELL_IPV6="${SNELL_IPV6:-false}"
SNELL_DNS="${SNELL_DNS:-1.1.1.1, 9.9.9.9, 2606:4700:4700::1111}"
SNELL_CONFIG_DIR="/etc/snell"
SNELL_CONFIG_FILE="${SNELL_CONFIG_DIR}/snell-server.conf"
SNELL_BINARY_PATH="/usr/local/bin/snell-server"
SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"

info() { echo "[信息] $1"; }
success() { echo "[成功] $1"; }
error() { echo "[错误] $1" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 身份或使用 sudo 运行此脚本。"
        exit 1
    fi
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7l" ;;
        *)
            error "不支持的系统架构: $(uname -m)"
            exit 1
            ;;
    esac
}

install_dependencies() {
    info "正在安装基础依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >/dev/null
        apt-get install -y curl openssl unzip ca-certificates >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl unzip ca-certificates >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl openssl unzip ca-certificates >/dev/null
    else
        error "未找到受支持的包管理器 (apt-get/dnf/apk)。"
        exit 1
    fi
}

install_snell_binary() {
    local architecture
    local download_url
    local temp_dir
    local archive_path

    architecture="$(detect_architecture)"
    download_url="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${architecture}.zip"
    temp_dir="$(mktemp -d)"
    archive_path="${temp_dir}/snell-server.zip"

    info "正在下载 Snell Server v${SNELL_VERSION} (${architecture})..."
    if ! curl -fsSL "$download_url" -o "$archive_path"; then
        error "下载失败: ${download_url}"
        exit 1
    fi

    unzip -q "$archive_path" -d "$temp_dir"
    if [ ! -f "${temp_dir}/snell-server" ]; then
        error "压缩包中未找到 snell-server 二进制。"
        exit 1
    fi

    install -m 0755 "${temp_dir}/snell-server" "$SNELL_BINARY_PATH"
    rm -rf "$temp_dir"
    success "Snell Server 已安装到 ${SNELL_BINARY_PATH}。"
}

write_snell_config() {
    local psk
    mkdir -p "$SNELL_CONFIG_DIR"
    psk="$(openssl rand -base64 18)"

    cat > "$SNELL_CONFIG_FILE" <<EOF
[snell-server]
dns = ${SNELL_DNS}
listen = 0.0.0.0:${SNELL_PORT}
psk = ${psk}
ipv6 = ${SNELL_IPV6}
EOF

    chmod 600 "$SNELL_CONFIG_FILE"
    success "Snell 配置已写入 ${SNELL_CONFIG_FILE}。"
    echo "Snell PSK: ${psk}"
}

write_systemd_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        error "当前系统未检测到 systemd，无法自动创建 Snell 服务。"
        exit 1
    fi

    cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
LimitNOFILE=32768
ExecStart=${SNELL_BINARY_PATH} -c ${SNELL_CONFIG_FILE}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now snell
    success "Snell 服务已启用并启动。"
}

apply_network_tuning() {
    info "正在写入 Snell 网络调优参数..."
    cat > /etc/sysctl.d/99-snell-network.conf <<'EOF'
net.core.rmem_default = 262144
net.core.rmem_max = 6291456
net.core.wmem_default = 262144
net.core.wmem_max = 4194304
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
EOF
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
}

require_root
install_dependencies
install_snell_binary
write_snell_config
write_systemd_service
apply_network_tuning
success "Snell v${SNELL_VERSION} 部署完成，监听端口: ${SNELL_PORT}。"
