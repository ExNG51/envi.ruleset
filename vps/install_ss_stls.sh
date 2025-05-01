#!/bin/bash
set -x

# --- Configuration (Defaults, can be overridden by --latest) ---
SS_VERSION="1.23.0" # Shadowsocks Rust Version
SHADOW_TLS_VERSION="v0.2.25" # Shadow-TLS Version
SHADOW_TLS_FIXED_PASSWORD="dEyss6rg38psKamNstVSpQ==" # Predefined fixed password
SHADOW_TLS_SNI="gateway.icloud.com" # Shadow-TLS SNI Host

# --- Global Variables (Detected early) ---
SERVICE_MANAGER=""
PKG_MANAGER=""
ARCH=""
IS_ALPINE=false
ENABLE_TFO=false # TCP Fast Open Flag
FETCH_LATEST=false # Fetch Latest Version Flag

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

detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v apt >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    else echo "unknown"; fi
}

is_alpine() {
    [ -f /etc/alpine-release ]
}

# Req 9: Function to get latest GitHub release tag
# Needs curl and jq
get_latest_github_release() {
    local repo_url="$1" # e.g., "shadowsocks/shadowsocks-rust"
    local latest_url="https://api.github.com/repos/${repo_url}/releases/latest"
    # Use -L to follow redirects, ensure jq handles potential errors gracefully
    local latest_tag=$(curl -sL "$latest_url" | jq -r '.tag_name // empty' 2>/dev/null)

    if [[ -z "$latest_tag" ]]; then
        echo "Error: Could not fetch latest release tag from $repo_url. Using default." >&2
        return 1 # Indicate failure
    fi
    # Remove potential leading 'v' for SS-Rust comparison if needed later
    # Keep 'v' for shadow-tls as it uses it consistently
    if [[ "$repo_url" == "shadowsocks/shadowsocks-rust" ]]; then
       echo "${latest_tag#v}" # Remove leading 'v'
    else
       echo "$latest_tag" # Keep leading 'v' for shadow-tls
    fi
    return 0
}


# Req 2: Use global PKG_MANAGER
check_package() {
    if [[ "$PKG_MANAGER" == "unknown" ]]; then return 1; fi
    case "$PKG_MANAGER" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        apt) dpkg -l "$1" 2>/dev/null | grep -q "^ii" ;;
        dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# Req 2: Use global PKG_MANAGER
install_packages() {
    if [[ "$PKG_MANAGER" == "unknown" ]]; then
        echo "Error: No supported package manager found for installation."
        return 1
    fi

    echo "Installing required packages using $PKG_MANAGER: $*"
    # Redirect stdout only, keep stderr visible for errors during install
    local install_cmd_output
    local install_cmd_status
    case "$PKG_MANAGER" in
        apk) install_cmd_output=$(apk add --no-cache "$@" 2>&1) ; install_cmd_status=$? ;;
        apt) install_cmd_output=$(apt update >/dev/null 2>&1 && apt install -y "$@" 2>&1) ; install_cmd_status=$? ;;
        dnf) install_cmd_output=$(dnf install -y "$@" 2>&1) ; install_cmd_status=$? ;;
        yum) install_cmd_output=$(yum install -y "$@" 2>&1) ; install_cmd_status=$? ;;
    esac

    if [ $install_cmd_status -ne 0 ]; then
        echo "Error: Failed to install required packages ($*)"
        echo "Package manager output:"
        echo "$install_cmd_output" # Show output on failure
        return 1
    fi

    # Verify installation for coreutils/shuf specifically after attempt
    if [[ " $@ " =~ " coreutils " ]]; then
        if ! command -v shuf >/dev/null 2>&1; then
             echo "Warning: coreutils installed but 'shuf' command still not found or not in PATH."
        fi
    fi
    # Verify jq if it was installed
    if [[ " $@ " =~ " jq " ]]; then
        if ! command -v jq >/dev/null 2>&1; then
             echo "Warning: jq installation attempted but command not found."
        fi
    fi

    return 0
}

# Req 4: Function to get SS package name
get_ss_package_name() {
    local version="$1"
    local arch="$2"
    local is_alpine_os="$3"
    local package_suffix=""

    if [[ "$is_alpine_os" == true ]]; then
        case $arch in
        x86_64) package_suffix="x86_64-unknown-linux-musl.tar.xz" ;;
        aarch64) package_suffix="aarch64-unknown-linux-musl.tar.xz" ;;
        *) echo ""; return 1 ;; # Indicate unsupported arch
        esac
    else
        case $arch in
        x86_64) package_suffix="x86_64-unknown-linux-gnu.tar.xz" ;;
        aarch64) package_suffix="aarch64-unknown-linux-gnu.tar.xz" ;;
        *) echo ""; return 1 ;; # Indicate unsupported arch
        esac
    fi
    echo "shadowsocks-v${version}.${package_suffix}"
    return 0
}

# Req 4: Function to get Shadow-TLS binary name
get_stls_binary_name() {
    local arch="$1"
    case $arch in
        x86_64) echo "shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64|arm*) echo "shadow-tls-arm-unknown-linux-musleabi" ;; # Use arm* glob
        *) echo ""; return 1 ;; # Indicate unsupported arch
    esac
    return 0
}


# --- Uninstall Function ---
uninstall() {
    echo "Uninstalling Shadowsocks Rust and potentially Shadow-TLS..."
    # Use global SERVICE_MANAGER
    if [[ "$SERVICE_MANAGER" == "unknown" ]]; then
       echo "Warning: Could not determine service manager for service removal."
       # Proceed with file removal anyway
    fi

    # Stop and disable Shadow-TLS (systemd only)
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        echo "Stopping and disabling Shadow-TLS service..."
        systemctl stop shadow-tls 2>/dev/null
        systemctl disable shadow-tls 2>/dev/null
        rm -f /etc/systemd/system/shadow-tls.service
    fi

    # Stop and disable Shadowsocks Rust
    echo "Stopping and disabling Shadowsocks Rust service..."
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl stop ss-rust 2>/dev/null
        systemctl disable ss-rust 2>/dev/null
        rm -f /etc/systemd/system/ss-rust.service
        systemctl daemon-reload # Reload after removing service files
    elif [[ "$SERVICE_MANAGER" == "openrc" ]]; then # Check explicitly for openrc
        rc-service ss-rust stop 2>/dev/null
        rc-update del ss-rust default 2>/dev/null
        rm -f /etc/init.d/ss-rust
    fi # No else needed due to initial warning

    # Remove files
    echo "Removing files..."
    rm -rf /opt/ss-rust
    rm -f /usr/local/bin/shadow-tls # Remove shadow-tls binary if it exists

    echo "Uninstallation complete."
}

# --- Update Function ---
update() {
    # Use global SERVICE_MANAGER, ARCH, IS_ALPINE
    if [[ "$SERVICE_MANAGER" == "unknown" ]]; then
        echo "Error: Could not determine service manager (systemd or openrc)."
        exit 1
    fi
    if [ ! -d "/opt/ss-rust" ]; then
        echo "Error: Shadowsocks Rust is not installed at /opt/ss-rust. Cannot update."
        exit 1
    fi

    # Req 9: Check if latest versions need fetching for update
    if [[ "$FETCH_LATEST" == true ]]; then
        echo "Fetching latest version information for update..."
        local latest_ss=$(get_latest_github_release "shadowsocks/shadowsocks-rust")
        local latest_stls=$(get_latest_github_release "ihciah/shadow-tls")
        if [ -n "$latest_ss" ]; then SS_VERSION="$latest_ss"; fi
        if [ -n "$latest_stls" ]; then SHADOW_TLS_VERSION="$latest_stls"; fi
        echo "Attempting update to SS: $SS_VERSION, Shadow-TLS: $SHADOW_TLS_VERSION"
    fi


    echo "Updating Shadowsocks Rust to version $SS_VERSION..."
    cd /opt/ss-rust || exit 1

    # Req 4: Use function to get package name
    local ss_package=$(get_ss_package_name "$SS_VERSION" "$ARCH" "$IS_ALPINE")
    if [ -z "$ss_package" ]; then
         echo "Unsupported system architecture: $ARCH. Cannot determine package name."
         exit 1
    fi

    echo "Downloading $ss_package..."
    rm -f ssserver sslocal ssmanager ssservice ssurl "$ss_package" # Clean previous binaries and archive
    # Add -O flag to wget to ensure output filename is correct
    if ! wget -q -O "$ss_package" "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$SS_VERSION/$ss_package"; then
        echo "Error: Failed to download Shadowsocks package."
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
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        systemctl restart ss-rust
    else # openrc
        rc-service ss-rust restart
    fi

    # Also update Shadow-TLS if it exists (systemd only)
    if [[ "$SERVICE_MANAGER" == "systemd" && -f "/usr/local/bin/shadow-tls" ]]; then
        echo "Updating Shadow-TLS to version $SHADOW_TLS_VERSION..."
        # Req 4: Use function to get binary name
        local shadow_tls_binary=$(get_stls_binary_name "$ARCH")

        if [ -z "$shadow_tls_binary" ]; then
             echo "Warning: Unsupported architecture for Shadow-TLS update: $ARCH. Skipping Shadow-TLS update."
        else
            echo "Downloading Shadow-TLS binary ($shadow_tls_binary)..."
            local temp_stls_bin="/tmp/shadow-tls.$$" # Use temp file for download
            if curl -fSL "https://github.com/ihciah/shadow-tls/releases/download/$SHADOW_TLS_VERSION/$shadow_tls_binary" -o "$temp_stls_bin"; then
                chmod a+x "$temp_stls_bin"
                if mv "$temp_stls_bin" /usr/local/bin/shadow-tls; then # Move after successful download and chmod
                   echo "Restarting Shadow-TLS service..."
                   systemctl restart shadow-tls
                else
                    echo "Error: Failed to move downloaded Shadow-TLS binary to /usr/local/bin/. Keeping existing version."
                    rm -f "$temp_stls_bin" # Clean up temp file
                fi
            else
                echo "Error: Failed to download Shadow-TLS binary. Keeping existing version."
                rm -f "$temp_stls_bin" # Clean up temp file if exists
            fi
        fi
    fi

    echo "Update completed. Services restarted."
}


# --- Install Function ---
install() {
    # Use global SERVICE_MANAGER, PKG_MANAGER, ARCH, IS_ALPINE, ENABLE_TFO
    if [[ "$SERVICE_MANAGER" == "unknown" ]]; then
        echo "Error: No supported service manager found (systemd or openrc)"
        exit 1
    fi

    echo "Starting new installation..."
    # Ensure clean state by running uninstall first
    uninstall

    # --- Dependency Check and Installation ---
    # Dependencies checked/installed in main script logic before calling install
    echo "Using package manager: $PKG_MANAGER"

    # --- Shadowsocks Installation ---
    echo "Installing Shadowsocks Rust version $SS_VERSION ..."
    mkdir -p /opt/ss-rust
    cd /opt/ss-rust || exit 1

    # Req 4: Use function to get package name
    local ss_package=$(get_ss_package_name "$SS_VERSION" "$ARCH" "$IS_ALPINE")
     if [ -z "$ss_package" ]; then
         echo "Unsupported system architecture: $ARCH. Cannot determine package name."
         exit 1
    fi

    echo "Downloading $ss_package..."
    # Add -O flag to wget
    if ! wget -q -O "$ss_package" "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$SS_VERSION/$ss_package"; then
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

    # --- Shadowsocks Configuration (Interactive) ---
    local ss_port=""
    local ss_password=""
    local user_port_input=""
    local user_pw_input=""
    local use_shuf_for_port=true # Flag to indicate if we should try using shuf

    # Ask for Port
    echo ""
    read -p "Enter Shadowsocks port (leave empty for random port between 10000-65535): " user_port_input
    if [[ -n "$user_port_input" ]]; then
        if [[ "$user_port_input" =~ ^[0-9]+$ && "$user_port_input" -ge 1 && "$user_port_input" -le 65535 ]]; then
            # Check port availability using net-tools (ss or netstat)
             local port_in_use=false
             if command -v ss > /dev/null; then
                 if ss -tuln | awk '{print $5}' | grep -q ":${user_port_input}$"; then
                     port_in_use=true
                 fi
             elif command -v netstat > /dev/null; then
                  if netstat -tuln | awk '{print $4}' | grep -q ":${user_port_input}$"; then
                      port_in_use=true
                  fi
             else
                  echo "Warning: Cannot check port availability (ss or netstat not found)."
             fi

            if [[ "$port_in_use" == true ]]; then
                echo "Error: Port $user_port_input is already in use. Exiting."
                exit 1
            else
                ss_port="$user_port_input"
                echo "Using user-provided Shadowsocks port: $ss_port"
            fi
        else
            echo "Error: Invalid port number '$user_port_input'. Exiting."
            exit 1
        fi
    fi

    # Generate random port if not provided
    if [ -z "$ss_port" ]; then
        echo "Attempting to generate random port..."
        # Req 3: Simplified shuf check (coreutils install attempted earlier)
        if ! command -v shuf >/dev/null 2>&1; then
             echo "Warning: 'shuf' command not found or not in PATH."
             echo "Falling back to using \$RANDOM for port generation."
             echo "Note: \$RANDOM method can only generate ports up to 42767."
             use_shuf_for_port=false # Set flag to use fallback method
        fi

        # Loop to find an available port using the chosen method
        while true; do
            if [[ "$use_shuf_for_port" == true ]]; then
                # Use shuf (preferred method)
                ss_port=$(shuf -i 10000-65535 -n 1)
            else
                # Use $RANDOM (fallback method)
                ss_port=$(( ( RANDOM % 32768 ) + 10000 )) # Range 10000-42767
            fi

            # Check port availability using ss or netstat
            local port_available=false
            if command -v ss > /dev/null; then
                if ! ss -tuln | awk '{print $5}' | grep -q ":$ss_port$"; then
                    port_available=true
                fi
            elif command -v netstat > /dev/null; then
                 if ! netstat -tuln | awk '{print $4}' | grep -q ":$ss_port$"; then
                    port_available=true
                 fi
            else
                 port_available=true # Assume available if we can't check
            fi

            if [[ "$port_available" == true ]]; then
                 echo "Using randomly generated Shadowsocks port: $ss_port"
                 break
            else
                 sleep 0.1 # Prevent tight loop
            fi
        done
    fi

    # --- Ask for Password & Create Config ---
    echo ""
    # Req 1: Use read -s for password
    read -sp "Enter Shadowsocks password (leave empty for random password): " user_pw_input
    echo "" # Add newline after hidden input
    if [[ -n "$user_pw_input" ]]; then
        ss_password="$user_pw_input"
        echo "Using user-provided Shadowsocks password."
    else
        echo "Generating random password for Shadowsocks..."
        ss_password=$(openssl rand -base64 32)
        echo "Using randomly generated Shadowsocks password."
    fi
    echo ""

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

    # Req 8: Prepare TFO flag if enabled
    local ssserver_tfo_flag=""
    if [[ "$ENABLE_TFO" == true ]]; then
        echo "TCP Fast Open (TFO) requested."
        # Check kernel support (optional, but informative)
        if [[ -r "/proc/sys/net/ipv4/tcp_fastopen" ]]; then
            local tfo_val=$(cat /proc/sys/net/ipv4/tcp_fastopen)
            # TFO needs client support (value 1 or 3)
            if [[ "$tfo_val" -eq 1 || "$tfo_val" -eq 3 ]]; then
                echo "Kernel TFO client support seems enabled (value: $tfo_val)."
                ssserver_tfo_flag="--fast-open" # Use the actual flag for ssserver
            else
                echo "Warning: Kernel TFO support might not be fully enabled for clients (value: $tfo_val). Flag will be added anyway."
                 ssserver_tfo_flag="--fast-open"
            fi
        else
             echo "Warning: Cannot check kernel TFO support (/proc/sys/net/ipv4/tcp_fastopen). Flag will be added anyway."
             ssserver_tfo_flag="--fast-open"
        fi
    fi

    # --- Shadowsocks Service Setup ---
    echo "Setting up Shadowsocks service ($SERVICE_MANAGER)..."
    local ssserver_exec="/opt/ss-rust/ssserver -c /opt/ss-rust/config.json ${ssserver_tfo_flag}"

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        cat >| /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks Rust Server (ssserver)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=51200
ExecStart=${ssserver_exec}
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
# Inject TFO flag if needed into command_args
command_args="-c /opt/ss-rust/config.json ${ssserver_tfo_flag}"
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
    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        if ! systemctl is-active --quiet ss-rust; then
            echo "Error: Shadowsocks service (ss-rust) failed to start. Check logs with 'journalctl -u ss-rust'."
            uninstall > /dev/null 2>&1 # Suppress uninstall output here
            exit 1
        fi
    else # openrc
         # Check if service command exists before trying to use it
         if command -v rc-service >/dev/null 2>&1; then
             if ! rc-service ss-rust status | grep -q "status: started"; then
                 echo "Error: Shadowsocks service (ss-rust) failed to start. Check logs in /var/log/."
                 uninstall > /dev/null 2>&1
                 exit 1
             fi
         else
              echo "Warning: Cannot verify OpenRC service status (rc-service not found)."
         fi
    fi
    echo "Shadowsocks service started successfully on port $ss_port (TCP/UDP)."

    # --- Shadow-TLS Installation and Setup (Systemd Only) ---
    local stls_password="" # Declare variable
    local install_stls_choice="n" # Default to no

    if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
        echo ""
        echo "--- Shadow-TLS Setup (Optional) ---"
        # Ask if user wants to install Shadow-TLS first
        read -p "Do you want to install Shadow-TLS (requires port 443)? (y/N): " install_stls_choice
        if [[ "$install_stls_choice" =~ ^[Yy]$ ]]; then
            echo "Proceeding with Shadow-TLS setup (version $SHADOW_TLS_VERSION)..."

            # <<< START: Password Choice Logic >>>
            echo ""
            echo "Choose Shadow-TLS password generation method:"
            echo "  1) Generate a random password (Recommended)"
            echo "  2) Use the predefined fixed password (Less Secure: $SHADOW_TLS_FIXED_PASSWORD)"
            echo ""

            local stls_choice=""
            while true; do
                # Req 1: Use read -s if choosing password later? (Currently only choice 1/2)
                read -p "Enter your choice (1 or 2): " stls_choice
                case $stls_choice in
                    1)
                        echo "Generating random password for Shadow-TLS..."
                        stls_password=$(openssl rand -base64 16)
                        if [ -z "$stls_password" ]; then
                            echo "Error: Failed to generate random Shadow-TLS password."
                            echo "Warning: Skipping Shadow-TLS setup due to password generation failure."
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
                # Check if port 443 is available
                local port_443_in_use=false
                 if command -v ss > /dev/null; then
                     if ss -tuln | awk '{print $5}' | grep -q ":443$"; then
                         port_443_in_use=true
                     fi
                 elif command -v netstat > /dev/null; then
                     if netstat -tuln | awk '{print $4}' | grep -q ":443$"; then
                         port_443_in_use=true
                     fi
                 else
                     echo "Warning: Cannot check if port 443 is in use (ss or netstat not found). Proceeding anyway."
                 fi

                if [[ "$port_443_in_use" == true ]]; then
                     echo "Error: Port 443 is already in use. Cannot install Shadow-TLS. Skipping Shadow-TLS setup."
                     stls_password="" # Clear password as we are skipping
                else
                    # Install Shadow-TLS binary
                    # Req 4: Use function to get binary name
                    local shadow_tls_binary=$(get_stls_binary_name "$ARCH")

                    if [ -z "$shadow_tls_binary" ]; then
                         echo "Warning: Unsupported architecture for Shadow-TLS: $arch. Skipping Shadow-TLS setup."
                         stls_password="" # Clear password if arch unsupported
                    else
                        echo "Downloading Shadow-TLS binary ($shadow_tls_binary)..."
                        local shadow_tls_url_base="https://github.com/ihciah/shadow-tls/releases/download/$SHADOW_TLS_VERSION"
                        local temp_stls_bin="/tmp/shadow-tls.$$"
                        if curl -fSL "$shadow_tls_url_base/$shadow_tls_binary" -o "$temp_stls_bin"; then
                            chmod a+x "$temp_stls_bin"
                            # Move to final destination
                            if mv "$temp_stls_bin" /usr/local/bin/shadow-tls; then
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
# Add --fastopen to shadow-tls as well if TFO is enabled
ExecStart=/usr/local/bin/shadow-tls ${ssserver_tfo_flag} --v3 --strict server --wildcard-sni=authed --listen [::]:443 --server 127.0.0.1:$ss_port --tls $SHADOW_TLS_SNI:443 --password $stls_password

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
                                     systemctl disable shadow-tls 2>/dev/null
                                     rm -f /etc/systemd/system/shadow-tls.service 2>/dev/null
                                     rm -f /usr/local/bin/shadow-tls 2>/dev/null # Also remove binary
                                     stls_password="" # Clear the password variable if service failed
                                else
                                     echo "Shadow-TLS service started successfully on port 443."
                                fi
                            else
                                echo "Error: Failed to move Shadow-TLS binary to /usr/local/bin/. Skipping Shadow-TLS setup."
                                rm -f "$temp_stls_bin" # Clean up temp file
                                stls_password=""
                            fi
                        else
                            echo "Error: Failed to download Shadow-TLS binary. Skipping Shadow-TLS setup."
                            rm -f "$temp_stls_bin" # Clean up temp file if it exists
                            stls_password="" # Clear password if download failed
                        fi
                    fi # end if shadow_tls_binary not empty
                fi # end if port 443 not in use
            else
                 echo "Skipping Shadow-TLS setup as no valid password was set."
            fi # end if password was set successfully
        else # User chose not to install Shadow-TLS
             echo "Skipping Shadow-TLS installation."
        fi # end if install_stls_choice
    else # Not systemd
        echo "Skipping Shadow-TLS setup (Systemd not detected)."
    fi # end systemd check

    # --- Final Output ---
    echo ""
    echo "--------------------------------------------------"
    echo "Installation Summary"
    echo "--------------------------------------------------"
    echo "Shadowsocks Version: $SS_VERSION"
    echo "Shadowsocks Port (TCP/UDP): $ss_port"
    echo "Shadowsocks Password: $ss_password"
    echo "Shadowsocks Method: 2022-blake3-aes-256-gcm"
    if [[ "$ENABLE_TFO" == true ]]; then
        echo "TCP Fast Open (TFO): Enabled (requires client and kernel support)"
    fi

    # Display Shadow-TLS info only if the password variable is non-empty AND the service is active
    local stls_active=false
    # Ensure stls_active remains false if not systemd
    if [[ "$SERVICE_MANAGER" == "systemd" ]] && systemctl is-active --quiet shadow-tls 2>/dev/null ; then
        stls_active=true
    fi

    local server_ip=$(curl -s4 http://ipv4.icanhazip.com || curl -s4 http://ifconfig.me || echo "YOUR_SERVER_IP")
    # Use command -v to check for hostname command before calling it
    local server_hostname="UNKNOWN_HOST"
    if command -v hostname >/dev/null 2>&1; then
        server_hostname=$(hostname)
    fi


    if [[ -n "$stls_password" && "$stls_active" == true ]]; then
        echo ""
        echo "Shadow-TLS Version: $SHADOW_TLS_VERSION"
        echo "Shadow-TLS Port (TCP Only): 443"
        echo "Shadow-TLS Password: $stls_password"
        echo "Shadow-TLS SNI: $SHADOW_TLS_SNI (Wildcard enabled, client can use others)"
        echo "Shadow-TLS v3 Mode: Enabled"
        echo ""
        echo "Client Configuration Example (e.g., Surge/Loon):"
        echo "$server_hostname-stls = ss, $server_ip, 443, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, shadow-tls-password=$stls_password, shadow-tls-sni=$SHADOW_TLS_SNI, shadow-tls-version=3, udp-relay=true, udp-port=$ss_port"
        echo ""
        echo "Note: UDP traffic goes directly to port $ss_port."
    # **** CORRECTED ELIF CONDITION ****
    elif [[ "$install_stls_choice" =~ ^[Yy]$ && ( -z "$stls_password" || "$stls_active" == false ) ]]; then
         echo ""
         echo "Shadow-TLS Status: Installation attempted but FAILED TO START or configure correctly."
         if [[ "$SERVICE_MANAGER" == "systemd" ]]; then
             echo "Please check logs: journalctl -u shadow-tls"
         else
             echo "(Shadow-TLS setup is only supported on systemd systems.)"
         fi
         echo "Shadowsocks should be available directly on port $ss_port (TCP/UDP)."
         echo ""
         echo "Direct Client Configuration Example (Shadowsocks Only):"
         echo "$server_hostname = ss, $server_ip, $ss_port, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, udp-relay=true"
    else
        echo ""
        echo "Shadow-TLS Status: Not installed or setup skipped."
        echo ""
        echo "Direct Client Configuration Example (Shadowsocks Only):"
        echo "$server_hostname = ss, $server_ip, $ss_port, encrypt-method=2022-blake3-aes-256-gcm, password=$ss_password, udp-relay=true"
    fi
    echo "--------------------------------------------------"
    echo "Installation finished!"
    echo "Note: Ensure your firewall allows traffic on TCP/UDP port $ss_port"
    # **** CORRECTED IF CONDITION ****
    if [[ "$stls_active" == true ]]; then
       echo "      and TCP port 443."
    else
       echo "."
    fi

}


# --- Main Script Logic ---

# --- Argument Parsing ---
COMMAND="" # Initialize command variable
while [ $# -gt 0 ]; do
    case "$1" in
        --latest)
            FETCH_LATEST=true
            shift
            ;;
        --enable-tfo)
            ENABLE_TFO=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  install    Install Shadowsocks-Rust and optionally Shadow-TLS (interactive)."
            echo "  update     Update existing Shadowsocks-Rust and Shadow-TLS installations."
            echo "  uninstall  Uninstall Shadowsocks-Rust and Shadow-TLS."
            echo "  (no command) Show interactive menu."
            echo ""
            echo "Options:"
            echo "  --latest       Fetch and use the latest stable versions from GitHub for install/update."
            echo "  --enable-tfo   Enable TCP Fast Open (TFO) for both ssserver and shadow-tls (requires kernel support)."
            echo "  -h, --help     Show this help message."
            echo ""
            echo "Note: Non-interactive install options (-p, -passwd) are not yet supported."
            exit 0
            ;;
        install|update|uninstall)
            # Capture command if provided positionally (and no command already captured)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            else
                # Allow options after command, but prevent two commands
                echo "Error: Multiple commands specified ('$COMMAND', '$1'). Use options like --latest before the command." >&2; exit 1;
            fi
            shift
            ;;
        *)
            echo "Error: Unknown option or misplaced argument '$1'" >&2
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# --- Initial Setup and Checks ---
# Check root privileges first
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Please run with root privileges"
    exit 1
fi

# Detect system info
SERVICE_MANAGER=$(get_service_manager)
PKG_MANAGER=$(detect_package_manager)
ARCH=$(uname -m)
IS_ALPINE=$(is_alpine && echo true || echo false)

if [[ "$PKG_MANAGER" == "unknown" ]]; then
   echo "Error: Could not detect a supported package manager (apk/apt/dnf/yum)."
   exit 1
fi

# Check and install base dependencies (including jq if --latest is used)
base_required_packages=()
if [[ "$PKG_MANAGER" == "apk" || "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
    base_required_packages=(wget tar openssl curl net-tools xz coreutils)
else # apt
    base_required_packages=(wget tar openssl curl net-tools xz-utils coreutils)
fi
if [[ "$FETCH_LATEST" == true ]]; then
    # Add jq if fetching latest versions
     if ! command -v jq > /dev/null 2>&1; then
        base_required_packages+=("jq")
     fi
fi
# Add curl check here as it's crucial for fetching latest
if ! command -v curl > /dev/null 2>&1; then
    # Avoid adding if already present
    if ! [[ " ${base_required_packages[*]} " =~ " curl " ]]; then
      base_required_packages+=("curl")
    fi
fi


missing_base_packages=()
for package in "${base_required_packages[@]}"; do
    if ! check_package "$package"; then
        missing_base_packages+=("$package")
    fi
done

if [ ${#missing_base_packages[@]} -ne 0 ]; then
    echo "Attempting to install base dependencies: ${missing_base_packages[*]}"
    if ! install_packages "${missing_base_packages[@]}"; then
        echo "Error: Failed to install base dependencies. Aborting."
        # Check if jq/curl was the one that failed if needed for --latest
        if [[ "$FETCH_LATEST" == true && (" ${missing_base_packages[*]} " =~ " jq " || " ${missing_base_packages[*]} " =~ " curl ") ]]; then
             # Check specifically which one is missing *after* the failed install attempt
             jq_missing=$(! command -v jq > /dev/null 2>&1 && echo true || echo false)
             curl_missing=$(! command -v curl > /dev/null 2>&1 && echo true || echo false)
             if [[ "$jq_missing" == true || "$curl_missing" == true ]]; then
                 echo "Error: 'jq' and/or 'curl' could not be installed, which is required for '--latest'."
                 exit 1
             fi
        fi
        # Exit if any base dependency failed critical install
        exit 1
    fi
fi

# Req 9: Fetch latest versions if requested
if [[ "$FETCH_LATEST" == true ]]; then
    echo "Fetching latest version information..."
     # Ensure jq and curl are available now
    if ! command -v jq > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
        echo "Error: 'jq' and 'curl' are required for '--latest' but are not available. Please install them."
        exit 1
    fi
    latest_ss=$(get_latest_github_release "shadowsocks/shadowsocks-rust")
    latest_stls=$(get_latest_github_release "ihciah/shadow-tls")
    if [ -n "$latest_ss" ]; then
        echo "Found latest Shadowsocks-Rust version: $latest_ss"
        SS_VERSION="$latest_ss"
    fi
    if [ -n "$latest_stls" ]; then
         echo "Found latest Shadow-TLS version: $latest_stls"
        SHADOW_TLS_VERSION="$latest_stls"
    fi
fi


# --- Execute Command or Show Menu ---
if [ -n "$COMMAND" ]; then
    # Execute the command provided via argument
    case "$COMMAND" in
        install)
            install
            ;;
        update)
            update
            ;;
        uninstall)
            uninstall
            ;;
        *)
            # Should not happen due to earlier parsing, but as a safeguard
            echo "Error: Invalid command '$COMMAND'" >&2; exit 1;
            ;;
    esac
else
    # --- Interactive Menu Logic (No command provided) ---
    echo "========================================="
    echo " Shadowsocks-Rust & Shadow-TLS Manager"
    echo "========================================="
    echo "Detected Service Manager: $SERVICE_MANAGER"
    echo "Detected Package Manager: $PKG_MANAGER"
    echo "Architecture: $ARCH"
    if [[ "$IS_ALPINE" == true ]]; then echo "OS Type: Alpine Linux"; fi
    echo "-----------------------------------------"
    echo "Using Versions:"
    echo "  Shadowsocks-Rust: $SS_VERSION"
    echo "  Shadow-TLS: $SHADOW_TLS_VERSION"
    if [[ "$FETCH_LATEST" == true ]]; then echo "  (Fetched Latest)"; fi
    if [[ "$ENABLE_TFO" == true ]]; then echo "TCP Fast Open: Enabled"; fi
    echo "-----------------------------------------"
    echo "Please choose an option:"
    echo "  1) Install Shadowsocks-Rust (and optionally Shadow-TLS)"
    echo "  2) Update existing installation"
    echo "  3) Uninstall Shadowsocks-Rust and Shadow-TLS"
    echo "  *) Exit"
    echo "-----------------------------------------"

    main_choice=""
    read -p "Enter your choice: " main_choice

    echo "" # Add a newline

    # Process Choice
    case $main_choice in
        1)
            install
            ;;
        2)
            update
            ;;
        3)
            uninstall
            ;;
        *)
            echo "Exiting."
            exit 0
            ;;
    esac
fi

exit 0

