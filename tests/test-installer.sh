#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
INSTALLER="${REPO_ROOT}/install.sh"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'not ok - %s: %s\n' "$1" "$2" >&2
}

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    pass "${test_name}"
  else
    fail "${test_name}" "expected '${expected}', got '${actual}'"
  fi
}

run_isolated_test() {
  local function_name="$1"
  local test_name="$2"
  local output

  if output="$("${function_name}" 2>&1)"; then
    pass "${test_name}"
  else
    fail "${test_name}" "${output}"
  fi
}

load_installer() {
  if [[ ! -f "${INSTALLER}" ]]; then
    fail "installer exists" "missing ${INSTALLER}"
    return 1
  fi
  # shellcheck source=../install.sh
  source "${INSTALLER}"
}

if [[ -f "${INSTALLER}" ]]; then
  load_installer
fi

test_constants_are_fixed() {
  assert_eq "port is fixed" "443" "${XRAY_PORT:-}"
  assert_eq "reality host is fixed" "www.bing.com" "${REALITY_HOST:-}"
  assert_eq "reality destination is fixed" "www.bing.com:443" "${REALITY_DEST:-}"
  assert_eq "client output is fixed" "/root/VLESS-REALITY-Vision.txt" "${CLIENT_OUTPUT:-}"
}

test_non_root_stops_before_mutation() (
  local mutations=""
  declare -F preflight_platform >/dev/null || {
    printf 'preflight_platform is not defined'
    return 1
  }
  get_effective_uid() { printf '501\n'; }
  install_dependencies() { mutations="packages"; }
  if preflight_platform >/dev/null 2>&1; then
    printf 'preflight unexpectedly succeeded'
    return 1
  elif [[ -n "${mutations}" ]]; then
    printf 'mutation occurred before rejection'
    return 1
  fi
)

test_rejects_non_systemd() (
  local mutations=""
  declare -F preflight_platform >/dev/null || {
    printf 'preflight_platform is not defined'
    return 1
  }
  get_effective_uid() { printf '0\n'; }
  systemd_is_running() { return 1; }
  install_dependencies() { mutations="packages"; }
  if preflight_platform >/dev/null 2>&1; then
    printf 'preflight unexpectedly succeeded'
    return 1
  elif [[ -n "${mutations}" ]]; then
    printf 'mutation occurred before rejection'
    return 1
  fi
)

test_rejects_unsupported_os() (
  local temp_dir mutations=""
  declare -F preflight_platform >/dev/null || {
    printf 'preflight_platform is not defined'
    return 1
  }
  temp_dir="$(mktemp -d)"
  printf 'ID=arch\n' >"${temp_dir}/os-release"
  OS_RELEASE_FILE="${temp_dir}/os-release"
  get_effective_uid() { printf '0\n'; }
  systemd_is_running() { return 0; }
  install_dependencies() { mutations="packages"; }
  if preflight_platform >/dev/null 2>&1; then
    printf 'preflight unexpectedly succeeded'
    rm -rf "${temp_dir}"
    return 1
  elif [[ -n "${mutations}" ]]; then
    printf 'mutation occurred before rejection'
    rm -rf "${temp_dir}"
    return 1
  fi
  rm -rf "${temp_dir}"
)

test_maps_supported_architectures() (
  local temp_dir
  declare -F detect_platform >/dev/null || {
    printf 'detect_platform is not defined'
    return 1
  }
  temp_dir="$(mktemp -d)"
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"${temp_dir}/os-release"
  OS_RELEASE_FILE="${temp_dir}/os-release"
  machine_arch() { printf 'x86_64\n'; }
  command_exists() { [[ "$1" == "apt-get" ]]; }
  detect_platform
  [[ "${OS_FAMILY}" == "debian" ]] || { printf 'Ubuntu family mismatch'; return 1; }
  [[ "${PKG_MANAGER}" == "apt-get" ]] || { printf 'Ubuntu package manager mismatch'; return 1; }
  [[ "${ARCH}" == "64" ]] || { printf 'x86_64 mapping mismatch'; return 1; }

  printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' >"${temp_dir}/os-release"
  machine_arch() { printf 'aarch64\n'; }
  command_exists() { [[ "$1" == "dnf" ]]; }
  detect_platform
  [[ "${OS_FAMILY}" == "rhel" ]] || { printf 'Rocky family mismatch'; return 1; }
  [[ "${PKG_MANAGER}" == "dnf" ]] || { printf 'Rocky package manager mismatch'; return 1; }
  [[ "${ARCH}" == "arm64-v8a" ]] || { printf 'arm64 mapping mismatch'; return 1; }
  rm -rf "${temp_dir}"
)

test_github_failure_precedes_port_switch() (
  local switched="no"
  declare -F check_github_access >/dev/null || {
    printf 'check_github_access is not defined'
    return 1
  }
  curl() { return 28; }
  quiesce_port_443() { switched="yes"; }
  if check_github_access >/dev/null 2>&1; then
    printf 'network check unexpectedly succeeded'
    return 1
  elif [[ "${switched}" != "no" ]]; then
    printf 'port switch was called'
    return 1
  fi
)

test_bing_must_support_tls13() (
  declare -F check_reality_target >/dev/null || {
    printf 'check_reality_target is not defined'
    return 1
  }
  run_with_timeout() { printf 'Protocol  : TLSv1.2\n'; }
  if check_reality_target >/dev/null 2>&1; then
    printf 'TLS 1.2 was accepted'
    return 1
  fi
)

test_public_ipv4_rejects_invalid_output() (
  declare -F detect_public_ipv4 >/dev/null || {
    printf 'detect_public_ipv4 is not defined'
    return 1
  }
  curl() { printf 'not-an-ip\n'; }
  if detect_public_ipv4 >/dev/null 2>&1; then
    printf 'invalid output was accepted'
    return 1
  fi
)

run_platform_tests() {
  run_isolated_test test_non_root_stops_before_mutation "non-root rejected before mutation"
  run_isolated_test test_rejects_non_systemd "non-systemd rejected before mutation"
  run_isolated_test test_rejects_unsupported_os "unsupported OS rejected before mutation"
  run_isolated_test test_maps_supported_architectures "supported architectures mapped"
}

run_network_tests() {
  run_isolated_test test_github_failure_precedes_port_switch "GitHub failure precedes port switch"
  run_isolated_test test_bing_must_support_tls13 "Bing TLS 1.3 required"
  run_isolated_test test_public_ipv4_rejects_invalid_output "invalid public IPv4 rejected"
}

test_source_does_not_run_main() {
  local output
  if [[ ! -f "${INSTALLER}" ]]; then
    fail "source is inert" "missing ${INSTALLER}"
    return
  fi
  output="$(bash -c 'source "$1"' _ "${INSTALLER}" 2>&1)"
  assert_eq "source is inert" "" "${output}"
}

case "${1:-all}" in
  preflight_platform)
    run_platform_tests
    ;;
  preflight_network)
    run_network_tests
    ;;
  all)
    test_constants_are_fixed
    test_source_does_not_run_main
    run_platform_tests
    run_network_tests
    ;;
  *)
    fail "test selector" "unknown selector: $1"
    ;;
esac

printf '%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
((FAIL_COUNT == 0))
