#!/bin/bash

# --- Configuration ---
SS_VERSION="1.23.0" # Shadowsocks Rust Version
SHADOW_TLS_VERSION="v0.2.25" # Shadow-TLS Version
SHADOW_TLS_FIXED_PASSWORD="dEyss6rg38psKamNstVSpQ==" # Predefined fixed password
SHADOW_TLS_SNI="gateway.icloud.com" # Shadow-TLS SNI Host

# --- Helper Functions ---
get_service_manager() {
    if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

is_alpine() {
    [ -f /etc/alpine-release ]
}

check_package() {
    case "$PKG_MANAGER" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        apt) dpkg -l "$1" 2>/dev/null | grep -q "^ii" ;;
        dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

install_packages() {
    echo "Installing required packages: $*"
    case "$PKG_MANAGER" in
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
        apt) apt update >/dev/null 2>&1 && apt install -y "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
        yum) yum install -y "$@" >/dev/null 2>&1 ;;
        *) echo "Error: Package manager $PKG_MANAGER not supported for installation." ; return 1 ;;
    esac
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install required packages"
        return 1
    fi
    return 0
}

show_usage() {
  echo "Usage: $0 <command> [options]"
  echo ""
  echo "Commands:"
  echo "  install    Install Shadowsocks-Rust and optionally Shadow-TLS."
  echo "             Options for install:"
  echo "               -p <port>       Specify the Shadowsocks server port (default: random)."
  echo "               -passwd <password> Specify the Shadowsocks password (default: random)."
  echo "  update     Update existing Shadowsocks-Rust and Shadow-TLS installations."
  echo "  uninstall  Uninstall Shadowsocks-Rust and Shadow-TLS."
  echo ""
  echo "Examples:"
  echo "  $0 install"
  echo "  $0 install -p 20000 -passwd mysecretpassword"
  echo "  $0 update"
  echo "  $0 uninstall"
}

# --- Uninstall Function ---
uninstall() {
    echo "Uninstalling Shadowsocks Rust and potentially Shadow-TLS..."

    # Stop and disable Shadow-TLS (systemd only)
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        echo "Stopping and disabling Shadow-TLS service..."
        systemctl stop shadow-tls 2>/dev/null
        systemctl disable shadow-tls 2>/dev/null
        rm -f /etc/systemd/system/shadow-tls.service
    fi

    # Stop and disable Shadowsocks Rust
    echo "Stopping and disabling Shadowsocks Rust service..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop ss-rust 2>/dev/null
        systemctl disable ss-rust 2>/dev/null
        rm -f /etc/systemd/system/ss-rust.service
        systemctl daemon-reload # Reload after removing service files
    else # openrc
        rc-service ss-rust stop 2>/dev/null
        rc-update del ss-rust default 2>/dev/null
        rm -f /etc/init.d/ss-rust
    fi

    # Remove files
    echo "Removing files..."
    rm -rf /opt/ss-rust
    rm -f /usr/local/bin/shadow-tls # Remove shadow-tls binary if it exists

    echo "Uninstallation complete."
}

# --- Update Function ---
update() {
    if [ ! -d "/opt/ss-rust" ]; then
        echo "Error: Shadowsocks Rust is not installed at /opt/ss-rust. Cannot update."
        exit 1
    fi
    if [ "$SERVICE_MANAGER" = "unknown" ]; then # Need service manager info for update
        echo "Error: Could not determine service manager (systemd or openrc)."
        exit 1
    fi

    echo "Updating Shadowsocks Rust to version $SS_VERSION..."
    cd /opt/ss-rust || exit 1

    arch=$(uname -m)
    ss_package=""
    if is_alpine; then
        case $arch in
        x86_64) ss_package="shadowsocks-v$SS_VERSION.x86_64-unknown-linux-musl.tar.xz" ;;
        aarch64) ss_package="shadowsocks-v$SS_VERSION.aarch64-unknown-linux-musl.tar.xz" ;;
        *) echo "Unsupported system architecture for Alpine: $arch"; exit 1 ;;
        esac
    else
        case $arch in
        x86_64) ss_package="shadowsocks-v$SS_VERSION.x86_64-unknown-linux-gnu.tar.xz" ;;
        aarch64) ss_package="shadowsocks-v$SS_VERSION.aarch64-unknown-linux-gnu.tar.xz" ;;
        *) echo "Unsupported system architecture: $arch"; exit 1 ;;
        esac
    fi

    echo "Downloading $ss_package..."
    rm -f ssserver sslocal ssmanager ssservice ssurl "$ss_package" # Clean previous binaries and archive
    if ! wget -q "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$SS_VERSION/$ss_package"; then
        echo "Error: Failed to download Shadowsocks package."
        # Attempt to restore old binary if possible? Maybe too complex. Just exit.
        exit 1
    fi

    echo "Extracting..."
    if ! tar -xf "$ss_package"; then
        echo "Error: Failed to extract Shadowsocks package."
        rm -f "$ss_package" # Clean up downloaded archive on failure
        exit 1
    fi
    rm -f "$ss_package" sslocal ssmanager ssservice ssurl # Clean up archive and unused binaries

    echo "Restarting Shadowsocks service..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl restart ss-rust
    else
        rc-service ss-rust restart
    fi

    # Also update Shadow-TLS if it exists (systemd only)
    if [ "$SERVICE_MANAGER" = "systemd" ] && [ -f "/usr/local/bin/shadow-tls" ]; then
        echo "Updating Shadow-TLS to version $SHADOW_TLS_VERSION..."
        shadow_tls_binary=""
        case $arch in
            x86_64) shadow_tls_binary="shadow-tls-x86_64-unknown-linux-musl" ;;
            aarch64|arm*) shadow_tls_binary="shadow-tls-arm-unknown-linux-musleabi" ;; # Use arm* glob
            *) echo "Warning: Unsupported architecture for Shadow-TLS update: $arch. Skipping Shadow-TLS update." ;;
        esac

        if [ -n "$shadow_tls_binary" ]; then
            # Use curl for better error handling during download
            echo "Downloading Shadow-TLS binary ($shadow_tls_binary)..."
            if curl -fSL "https://github.com/ihciah/shadow-tls/releases/download/$SHADOW_TLS_VERSION/$shadow_tls_binary" -o /usr/local/bin/shadow-tls.new; then
                chmod a+x /usr/local/bin/shadow-tls.new
                mv /usr/local/bin/shadow-tls.new /usr/local/bin/shadow-tls
                echo "Restarting Shadow-TLS service..."
                # Note: Restarting shadow-tls doesn't re-read the password from the file,
                # it uses the password it was initially started with. This is correct for updates.
                systemctl restart shadow-tls
            else
                echo "Error: Failed to download Shadow-TLS binary. Keeping existing version."
                rm -f /usr/local/bin/shadow-tls.new
            fi
        fi
    fi

    echo "Update completed. Services restarted."
}


# --- Install Function ---
# Accepts optional arguments like -p <port> -passwd <password>
install() {
    echo "Starting new installation..."
    # Ensure clean state by running uninstall first
    uninstall

    # --- Dependency Check and Installation ---
    echo "Checking package manager and dependencies..."
    if command -v apk >/dev/null 2>&1; then PKG_MANAGER="apk"
    elif command -v apt >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"
    else echo "Error: No supported package manager found (apk/apt/dnf/yum)"; exit 1
    fi
    echo "Using package manager: $PKG_MANAGER"

    if [ "$PKG_MANAGER" = "apk" ] || [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        required_packages=(wget tar openssl curl net-tools xz)
    else # apt
        required_packages=(wget tar openssl curl net-tools xz-utils)
    fi

    missing_packages=()
    for package in "${required_packages[@]}"; do
        if ! check_package "$package"; then
            missing_packages+=("$package")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        if ! install_packages "${missing_packages[@]}"; then
            exit 1
        fi
    else
        echo "All dependencies seem to be installed."
    fi

    # --- Shadowsocks Installation ---
    echo "Installing Shadowsocks Rust..."
    mkdir -p /opt/ss-rust
    cd /opt/ss-rust || exit 1

    arch=$(uname -m)
    ss_package=""
    if is_alpine; then
        case $arch in
        x86_64) ss_package="shadowsocks-v$SS_VERSION.x86_64-unknown-linux-musl.tar.xz" ;;
        aarch64) ss_package="shadowsocks-v$SS_VERSION.aarch64-unknown-linux-musl.tar.xz" ;;
        *) echo "Unsupported system architecture for Alpine: $arch"; exit 1 ;;
        esac
    else
        case $arch in
        x86_64) ss_package="shadowsocks-v$SS_VERSION.x86_64-unknown-linux-gnu.tar.xz" ;;
        aarch64) ss_package="shadowsocks-v$SS_VERSION.aarch64-unknown-linux-gnu.tar.xz" ;;
        *) echo "Unsupported system architecture: $arch"; exit 1 ;;
        esac
    fi

    echo "Downloading $ss_package..."
    if ! wget -q "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$SS_VERSION/$ss_package"; then
        echo "Error: Failed to download Shadowsocks package."
        rm -rf /opt/ss-rust
        exit 1
    fi

    echo "Extracting..."
    if ! tar -xf "$ss_package"; then
        echo "Error: Failed to extract Shadowsocks package."
        rm -f "$ss_package"
        rm -rf /opt/ss-rust
        exit 1
    fi
    rm -f "$ss_package" sslocal ssmanager ssservice ssurl
    echo "Shadowsocks Rust binaries installed in /opt/ss-rust"

    # --- Shadowsocks Configuration (Parsing args passed to install function) ---
    ss_port=""
    ss_password=""

    # Process arguments passed specifically to the install function
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -p)
            shift
            if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
                # Check port availability using ss (requires net-tools)
                if ! ss -tuln | awk '{print $5}' | grep -q ":$1$"; then
                    ss_port="$1"
                    echo "Using user-provided Shadowsocks port: $ss_port"
                else
                    echo "Error: Port $1 is already in use by TCP or UDP"
                    exit 1
                fi
            else
                echo "Error: Invalid port number '$1' provided after -p"
                exit 1
            fi
            ;;
        -passwd)
            shift
            # Check if next argument exists before assigning
            if [ -n "$1" ]; then
                ss_password="$1"
                echo "Using user-provided Shadowsocks password."
            else
                 echo "Error: -passwd option requires a password argument."
                 exit 1
            fi
            ;;
        *)
            echo "Error: Invalid argument '$1' for install command."
            show_usage
            exit 1
            ;;
        esac
        shift # Move to next argument pair or next argument
    done


    if [ -z "$ss_port" ]; then
        echo "Generating random port for Shadowsocks..."
        while true; do
            ss_port=$(( ( RANDOM % 55536 ) + 10000 ))
            if ! ss -tuln | awk '{print $5}' | grep -q ":$ss_port$"; then
                echo "Using randomly generated Shadowsocks port: $ss_port"
                break
            fi
            sleep 0.1 # Prevent tight loop if finding port fails repeatedly
        done
    fi

    if [ -z "$ss_password" ]; then
        echo "Generating random password for Shadowsocks..."
        ss_password=$(openssl rand -base64 32)
    fi

    echo "Creating Shadowsocks config.json..."
    cat >| /opt/ss-rust/config.json <<EOF
{
    "server": "::",
    "server_port": $ss_port,
    "password": "$ss_password",
    "method": "2022-blake3-aes-256-gcm",
    "mode": "tcp_and_udp"
}
EOF

    # --- Shadowsocks Service Setup ---
    echo "Setting up Shadowsocks service ($SERVICE_MANAGER)..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        cat >| /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks Rust Server (ssserver)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=51200
ExecStart=/opt/ss-rust/ssserver -c /opt/ss-rust/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-rust
        echo "Starting Shadowsocks service..."
        systemctl restart ss-rust
    else # openrc
        cat >| /etc/init.d/ss-rust <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust Server"
description="Shadowsocks Rust Server (ssserver)"
command="/opt/ss-rust/ssserver"
command_args="-c /opt/ss-rust/config.json"
command_background="yes"
pidfile="/run/ss-rust.pid"
output_log="/var/log/ss-rust.log"
error_log="/var/log/ss-rust-error.log"

depend() {
    need net
    after network
}
EOF
        chmod +x /etc/init.d/ss-rust
        rc-update add ss-rust default
        echo "Starting Shadowsocks service..."
        rc-service ss-rust restart
    fi

    sleep 2 # Give service time to start
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        if ! systemctl is-active --quiet ss-rust; then
            echo "Error: Shadowsocks service (ss-rust) failed to start. Check logs with 'journalctl -u ss-rust'."
            exit 1
        fi
    else
         if ! rc-service ss-rust status | grep -q "status: started"; then
            echo "Error: Shadowsocks service (ss-rust) failed to start. Check logs in /var/log/."
            exit 1
         fi
    fi
    echo "Shadowsocks service started successfully on port $ss_port (TCP/UDP)."

    # --- Shadow-TLS Installation and Setup (Systemd Only) ---
    stls_password="" # Declare variable

    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        echo "Proceeding with Shadow-TLS setup (systemd detected)..."

        # <<< START: Password Choice Logic >>>
        echo ""
        echo "Choose Shadow-TLS password generation method:"
        echo "  1) Generate a random password (Recommended)"
        echo "  2) Use the predefined fixed password ($SHADOW_TLS_FIXED_PASSWORD)"
        echo ""

        stls_choice=""
        while true; do
            read -p "Enter your choice (1 or 2): " stls_choice
            case $stls_choice in
                1)
                    echo "Generating random password for Shadow-TLS..."
                    stls_password=$(openssl rand -base64 16)
                    if [ -z "$stls_password" ]; then
                        echo "Error: Failed to generate random Shadow-TLS password."
                        echo "Warning: Continuing without Shadow-TLS setup due to password generation failure."
                        stls_password="" # Ensure it's empty if generation failed
                    else
                        echo "Random Shadow-TLS password generated."
                    fi
                    break # Exit loop
                    ;;
                2)
                    echo "Using predefined fixed password for Shadow-TLS."
                    stls_password="$SHADOW_TLS_FIXED_PASSWORD"
                    break # Exit loop
                    ;;
                *)
                    echo "Invalid choice. Please enter 1 or 2."
                    ;;
            esac
        done
        echo "" # Add a newline for better formatting
        # <<< END: Password Choice Logic >>>

        # Proceed only if a password was successfully set (either random or fixed)
        if [ -n "$stls_password" ]; then

            # Install Shadow-TLS binary
            shadow_tls_binary=""
            shadow_tls_url_base="https://github.com/ihciah/shadow-tls/releases/download/$SHADOW_TLS_VERSION"
            arch=$(uname -m)
            case $arch in
                x86_64) shadow_tls_binary="shadow-tls-x86_64-unknown-linux-musl" ;;
                aarch64|arm*) shadow_tls_binary="shadow-tls-arm-unknown-linux-musleabi" ;; # Use arm* glob
                *) echo "Warning: Unsupported architecture for Shadow-TLS: $arch. Skipping Shadow-TLS setup.";;
            esac

            if [ -n "$shadow_tls_binary" ]; then
                echo "Downloading Shadow-TLS binary ($shadow_tls_binary)..."
                if curl -fSL "$shadow_tls_url_base/$shadow_tls_binary" -o /usr/local/bin/shadow-tls && chmod a+x /usr/local/bin/shadow-tls; then
                    echo "Shadow-TLS binary installed to /usr/local/bin/shadow-tls"

                    # Create Shadow-TLS systemd service file using the chosen password
                    echo "Creating Shadow-TLS systemd service file..."
                    cat >| /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service (v3)
After=network-online.target ss-rust.service
Wants=network-online.target
Requires=ss-rust.service

[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c "ulimit -n 51200"
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 --strict server --wildcard-sni=authed --listen [::]:443 --server 127.0.0.1:$ss_port --tls $SHADOW_TLS_SNI:443 --password $stls_password

[Install]
WantedBy=multi-user.target
EOF
                    # Start Shadow-TLS service
                    echo "Reloading systemd daemon and starting Shadow-TLS service..."
                    systemctl daemon-reload
                    systemctl enable shadow-tls
                    systemctl restart shadow-tls

                    sleep 2 # Give service time to start
                    if ! systemctl is-active --quiet shadow-tls; then
                         echo "Warning: Shadow-TLS service failed to start. Check logs with 'journalctl -u shadow-tls'. The Shadowsocks service on port $ss_port should still work directly."
                         # Clear the password variable if service failed, so it's not shown misleadingly
                         stls_password=""
                    else
                         echo "Shadow-TLS service started successfully on port 443."
                    fi
                else
                    echo "Error: Failed to download or set permissions for Shadow-TLS binary. Skipping Shadow-TLS setup."
                    stls_password="" # Clear password if download failed
                fi
            else
                 stls_password="" # Clear password if arch unsupported
            fi # end if shadow_tls_binary not empty
        else
             echo "Skipping Shadow-TLS setup as no valid password was set (e.g., random generation failed)."
        fi # end if password was set successfully

    else
        echo "Skipping Shadow-TLS setup (Systemd not detected)."
    fi # end systemd check

    # --- Final Output ---
    echo "--------------------------------------------------"
    echo "Installation Summary"
    echo "--------------------------------------------------"
    echo "Shadowsocks Port (TCP/UDP): $ss_port"
    echo "Shadowsocks Password: $ss_password"
    echo "Shadowsocks Method: 2022-blake3-aes-256-gcm"

    # Display Shadow-TLS info only if the password variable is non-empty AND the service is active
    if [ -n "$stls_password" ] && [ "$SERVICE_MANAGER" = "systemd" ] && systemctl is-active --quiet shadow-tls 2>/dev/null ; then
        echo ""
        echo "Shadow-TLS Port (TCP Only): 443"
        echo "Shadow-TLS Password: $stls_password" # Display the generated or fixed password
        echo "Shadow-TLS SNI: $SHADOW_TLS_SNI (Wildcard enabled, client can use others)"
        echo "Shadow-TLS Version: 3"
        echo ""
        echo "Client Configuration Example (e.g., Surge/Loon):"
        server_ip=$(curl -s4 http://ipv4.icanhazip.com || curl -s4 http://ifconfig.me || echo "YOUR_SERVER_IP")
        echo "vps-stls = ss, $server_ip, 443, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, shadow-tls-password=$stls_password, shadow-tls-sni=$SHADOW_TLS_SNI, shadow-tls-version=3, udp-relay=true, udp-port=$ss_port"
        echo ""
        echo "Note: UDP traffic goes directly to port $ss_port."
    # Add case where setup was attempted (systemd exists, binary potentially downloaded) but service isn't active
    elif [ "$SERVICE_MANAGER" = "systemd" ] && [ -f "/usr/local/bin/shadow-tls" ]; then
         echo ""
         echo "Shadow-TLS Status: Installation or service start FAILED."
         echo "Please check logs: journalctl -u shadow-tls"
         echo "Shadowsocks should be available directly on port $ss_port (TCP/UDP)."
         echo ""
         echo "Direct Client Configuration Example (Shadowsocks Only):"
         server_ip=$(curl -s4 http://ipv4.icanhazip.com || curl -s4 http://ifconfig.me || echo "YOUR_SERVER_IP")
         echo "vps-ss = ss, $server_ip, $ss_port, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, udp-relay=true"
    # Default case: Shadow-TLS was not installed (non-systemd, unsupported arch, etc.)
    else
        echo ""
        echo "Shadow-TLS Status: Not installed or setup skipped."
        echo ""
        echo "Direct Client Configuration Example (Shadowsocks Only):"
        server_ip=$(curl -s4 http://ipv4.icanhazip.com || curl -s4 http://ifconfig.me || echo "YOUR_SERVER_IP")
        echo "vps-ss = ss, $server_ip, $ss_port, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, udp-relay=true"
    fi
    echo "--------------------------------------------------"
    echo "Installation finished!"
}


# --- Main Script Logic ---

# Pre-checks required for all actions
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with root privileges"
    exit 1
fi

SERVICE_MANAGER=$(get_service_manager)
# Note: Update and Install functions will check SERVICE_MANAGER again if they need it.
# Uninstall also checks it implicitly.

# Check if any command is provided
if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

# Store the command (first argument)
COMMAND="$1"
shift # Remove the command from the arguments list, so $@ contains only options for the command

# Execute command
case "$COMMAND" in
    install)
        # Pass the remaining arguments (options like -p, -passwd) to the install function
        install "$@"
        ;;
    update)
        # Update should not take extra arguments
        if [ "$#" -ne 0 ]; then
            echo "Error: 'update' command does not take any arguments."
            show_usage
            exit 1
        fi
        update
        ;;
    uninstall)
        # Uninstall should not take extra arguments
        if [ "$#" -ne 0 ]; then
            echo "Error: 'uninstall' command does not take any arguments."
            show_usage
            exit 1
        fi
        uninstall
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_usage
        exit 1
        ;;
esac

exit 0
