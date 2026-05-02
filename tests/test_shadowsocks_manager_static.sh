#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER_SCRIPT="${REPO_ROOT}/vps/shadowsocks-manager.sh"

fail() {
    echo "[FAIL] $1" >&2
    exit 1
}

[ -f "${MANAGER_SCRIPT}" ] || fail "vps/shadowsocks-manager.sh should exist"
[ ! -f "${REPO_ROOT}/vps/install_ss.sh" ] || fail "legacy vps/install_ss.sh should be removed"
[ ! -f "${REPO_ROOT}/vps/install_ss_stls.sh" ] || fail "legacy vps/install_ss_stls.sh should be removed"

bash -n "${MANAGER_SCRIPT}"

help_output="$(bash "${MANAGER_SCRIPT}" --help)"
grep -q "Shadowsocks-Rust 统一管理脚本" <<< "${help_output}" || fail "help should show Chinese manager title"
grep -q "安装 / 覆盖安装" <<< "${help_output}" || fail "help should list install action"
grep -q "Shadow-TLS" <<< "${help_output}" || fail "help should mention Shadow-TLS management"

! grep -q "SHADOW_TLS_FIXED_PASSWORD" "${MANAGER_SCRIPT}" || fail "fixed Shadow-TLS password must not exist"
! grep -q 'SS_VERSION="1.23.0"' "${MANAGER_SCRIPT}" || fail "old default Shadowsocks-Rust version must not remain"
grep -q 'SS_VERSION_DEFAULT="1.24.0"' "${MANAGER_SCRIPT}" || fail "manager should default to Shadowsocks-Rust 1.24.0"

echo "[PASS] shadowsocks manager static checks"
