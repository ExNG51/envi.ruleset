#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail

SCRIPT_PATH="${SCRIPT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shadowsocks-manager.sh}"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

test_source_does_not_run_main() {
    local output
    if ! output="$(bash -c 'source "$1"; type read_prompt >/dev/null; printf sourced' _ "${SCRIPT_PATH}" 2>&1)"; then
        printf '%s\n' "${output}" >&2
        fail "sourcing script should define functions without executing main"
    fi
    [[ "${output}" == *"sourced"* ]] || fail "sourcing script did not complete"
    pass "sourcing script does not execute main"
}

test_prompt_port_keeps_manual_port() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"
    is_port_in_use() { return 1; }

    local port=""
    exec 9<<<"12345"
    PROMPT_FD=9
    prompt_port port "Port: " false >/tmp/shadowsocks-manager-test-output
    exec 9<&-

    [[ "${port}" == "12345" ]] || fail "prompt_port should preserve manual port input, got '${port}'"
    pass "prompt_port preserves manual port input"
}

test_prompt_port_cancel_returns_to_caller() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"
    is_port_in_use() { return 1; }

    local port="unchanged" status=0
    exec 9<<<"q"
    PROMPT_FD=9
    prompt_port port "Port: " false >/tmp/shadowsocks-manager-test-output || status=$?
    exec 9<&-

    [[ "${status}" -eq 130 ]] || fail "prompt_port cancel should return 130, got ${status}"
    [[ "${port}" == "unchanged" ]] || fail "prompt_port cancel should not modify output variable"
    pass "prompt_port cancel returns to caller"
}

test_shadow_tls_env_parser_does_not_execute_content() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local tmpdir marker
    tmpdir="$(mktemp -d)"
    marker="${tmpdir}/executed"
    SHADOW_TLS_ENV_FILE="${tmpdir}/shadow-tls.env"
    cat >"${SHADOW_TLS_ENV_FILE}" <<EOF
SS_PORT="8388"
STLS_PORT="\$(touch "${marker}")443"
STLS_SNI="gateway.icloud.com"
STLS_PASSWORD="secret"
STLS_TFO_FLAG=""
EOF

    if load_shadow_tls_env >/tmp/shadowsocks-manager-test-output 2>&1; then
        rm -rf "${tmpdir}"
        fail "load_shadow_tls_env should reject unsafe env content"
    fi
    [[ ! -e "${marker}" ]] || {
        rm -rf "${tmpdir}"
        fail "load_shadow_tls_env executed env content"
    }
    rm -rf "${tmpdir}"
    pass "shadow-tls env parser rejects unsafe content without executing it"
}

test_ss_systemd_service_uses_root_execution_model() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    SERVICE_MANAGER="systemd"
    SYSTEMD_SS_SERVICE="${tmpdir}/ss-rust.service"
    SS_BINARY="/opt/ss-rust/ssserver"
    SS_CONFIG_FILE="/opt/ss-rust/config.json"

    systemctl() { return 0; }
    write_ss_service

    if grep -q '^User=nobody$' "${SYSTEMD_SS_SERVICE}"; then
        rm -rf "${tmpdir}"
        fail "systemd service should not force nobody user in root execution model"
    fi
    grep -q '^NoNewPrivileges=true$' "${SYSTEMD_SS_SERVICE}" || {
        rm -rf "${tmpdir}"
        fail "systemd service should enable NoNewPrivileges"
    }
    rm -rf "${tmpdir}"
    pass "systemd service uses root execution model with hardening"
}

test_confirm_yes_no_cancel_returns_status() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local status=0
    exec 9<<<"q"
    PROMPT_FD=9
    confirm_yes_no "Continue?" "n" >/tmp/shadowsocks-manager-test-output || status=$?
    exec 9<&-

    [[ "${status}" -eq 130 ]] || fail "confirm_yes_no cancel should return 130, got ${status}"
    pass "confirm_yes_no cancel returns status"
}

test_choose_method_cancel_returns_status() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local method="unchanged" status=0
    exec 9<<<"q"
    PROMPT_FD=9
    choose_method method >/tmp/shadowsocks-manager-test-output || status=$?
    exec 9<&-

    [[ "${status}" -eq 130 ]] || fail "choose_method cancel should return 130, got ${status}"
    [[ "${method}" == "unchanged" ]] || fail "choose_method cancel should not modify method"
    pass "choose_method cancel returns status"
}

test_write_ss_config_outputs_valid_json() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local tmpdir password method
    tmpdir="$(mktemp -d)"
    INSTALL_DIR="${tmpdir}"
    SS_CONFIG_FILE="${tmpdir}/config.json"
    password='abc"def\ghi'
    method="2022-blake3-aes-128-gcm"

    write_ss_config 12345 "${password}" "${method}"
    jq -e '.server == "::" and .server_port == 12345 and .password == "abc\"def\\ghi" and .method == "2022-blake3-aes-128-gcm" and .mode == "tcp_and_udp"' "${SS_CONFIG_FILE}" >/dev/null || {
        rm -rf "${tmpdir}"
        fail "write_ss_config should output valid escaped JSON"
    }
    [[ "$(get_ss_port)" == "12345" ]] || fail "get_ss_port should read JSON port"
    [[ "$(get_ss_password)" == "${password}" ]] || fail "get_ss_password should read JSON password"
    [[ "$(get_ss_method)" == "${method}" ]] || fail "get_ss_method should read JSON method"
    rm -rf "${tmpdir}"
    pass "write_ss_config outputs valid JSON"
}

test_main_menu_q_does_not_exit_until_zero() {
    local output
    output="$(
        bash -c '
            source "$1"
            print_title() { :; }
            pause_screen() { :; }
            ss_service_state() { echo inactive; }
            shadow_tls_service_state() { echo inactive; }
            exec 9<<<$'"'"'q\n0\n'"'"'
            PROMPT_FD=9
            show_main_menu
        ' _ "${SCRIPT_PATH}" 2>&1
    )"
    [[ "${output}" == *"主菜单请使用 0 退出脚本"* ]] || fail "main menu should require 0 for exit"
    [[ "${output}" == *"已退出"* ]] || fail "main menu should exit after explicit 0"
    pass "main menu q does not exit until zero"
}

test_service_menu_stays_after_action_until_zero() {
    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"

    local leftover="none"
    SERVICE_MANAGER="systemd"
    print_title() { :; }
    pause_screen() { :; }
    ss_service_state() { echo inactive; }
    shadow_tls_service_state() { echo inactive; }
    start_ss_service() { return 0; }

    exec 9<<<$'1\n0'
    PROMPT_FD=9
    manage_services >/tmp/shadowsocks-manager-test-output
    if IFS= read -r -u 9 leftover; then
        exec 9<&-
        fail "service menu should consume explicit 0 before returning, leftover '${leftover}'"
    fi
    exec 9<&-
    pass "service menu stays after action until zero"
}

test_source_does_not_run_main
test_prompt_port_keeps_manual_port
test_prompt_port_cancel_returns_to_caller
test_shadow_tls_env_parser_does_not_execute_content
test_ss_systemd_service_uses_root_execution_model
test_confirm_yes_no_cancel_returns_status
test_choose_method_cancel_returns_status
test_write_ss_config_outputs_valid_json
test_main_menu_q_does_not_exit_until_zero
test_service_menu_stays_after_action_until_zero
