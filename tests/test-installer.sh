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

test_backup_uses_unique_utc_directory() (
  local temp_dir first second
  declare -F create_backup_dir >/dev/null || { printf 'create_backup_dir is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_ROOT="${temp_dir}/backups"
  utc_timestamp() { printf '20261009T010203Z\n'; }
  create_backup_dir
  first="${BACKUP_DIR}"
  create_backup_dir
  second="${BACKUP_DIR}"
  [[ "${first}" != "${second}" ]] || { printf 'backup directories collided'; return 1; }
  [[ -d "${first}" && -d "${second}" ]] || { printf 'backup directory missing'; return 1; }
  rm -rf "${temp_dir}"
)

test_backup_copies_only_declared_paths() (
  local temp_dir
  declare -F backup_existing_state >/dev/null || { printf 'backup_existing_state is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  VRI_ROOT="${temp_dir}/source"
  BACKUP_ROOT="${temp_dir}/backups"
  mkdir -p "${VRI_ROOT}/usr/local/etc/xray" "${VRI_ROOT}/var/log/xray" "${VRI_ROOT}/var/www/site"
  printf 'config' >"${VRI_ROOT}/usr/local/etc/xray/config.json"
  printf 'secret log' >"${VRI_ROOT}/var/log/xray/access.log"
  printf 'website' >"${VRI_ROOT}/var/www/site/index.html"
  create_backup_dir
  backup_existing_state
  [[ -f "${BACKUP_DIR}/files/usr/local/etc/xray/config.json" ]] || { printf 'declared config not copied'; return 1; }
  [[ ! -e "${BACKUP_DIR}/files/var/log/xray/access.log" ]] || { printf 'log was copied'; return 1; }
  [[ ! -e "${BACKUP_DIR}/files/var/www/site/index.html" ]] || { printf 'website data was copied'; return 1; }
  rm -rf "${temp_dir}"
)

test_previous_client_file_is_preserved() (
  local temp_dir
  declare -F backup_existing_state >/dev/null || { printf 'backup_existing_state is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  VRI_ROOT="${temp_dir}/source"
  BACKUP_ROOT="${temp_dir}/backups"
  mkdir -p "${VRI_ROOT}/root"
  printf 'old-link' >"${VRI_ROOT}${CLIENT_OUTPUT}"
  create_backup_dir
  backup_existing_state
  [[ "$(cat "${BACKUP_DIR}/files/root/VLESS-REALITY-Vision.txt")" == "old-link" ]] || {
    printf 'previous client file was not preserved'
    return 1
  }
  rm -rf "${temp_dir}"
)

test_known_systemd_owner_is_stopped_and_disabled() (
  local temp_dir actions=""
  declare -F quiesce_port_443 >/dev/null || { printf 'quiesce_port_443 is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_DIR="${temp_dir}"
  SERVICE_STATE_FILE="${temp_dir}/service-states.tsv"
  get_port_443_pids() { printf '111\n'; }
  systemd_unit_for_pid() { printf 'nginx.service\n'; }
  service_active_state() { printf 'active\n'; }
  service_enabled_state() { printf 'enabled\n'; }
  run_systemctl() { actions+="$*|"; }
  quiesce_port_443
  [[ "${actions}" == "stop nginx.service|disable nginx.service|" ]] || { printf 'unexpected actions: %s' "${actions}"; return 1; }
  grep -qx $'nginx.service\tactive\tenabled' "${SERVICE_STATE_FILE}" || { printf 'service state not recorded'; return 1; }
  rm -rf "${temp_dir}"
)

test_multiple_systemd_owners_are_recorded() (
  local temp_dir
  declare -F quiesce_port_443 >/dev/null || { printf 'quiesce_port_443 is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_DIR="${temp_dir}"
  SERVICE_STATE_FILE="${temp_dir}/service-states.tsv"
  get_port_443_pids() { printf '111\n222\n'; }
  systemd_unit_for_pid() { [[ "$1" == "111" ]] && printf 'nginx.service\n' || printf 'caddy.service\n'; }
  service_active_state() { printf 'active\n'; }
  service_enabled_state() { printf 'enabled\n'; }
  run_systemctl() { :; }
  quiesce_port_443
  [[ "$(wc -l <"${SERVICE_STATE_FILE}" | tr -d ' ')" == "2" ]] || { printf 'expected two recorded services'; return 1; }
  grep -q '^nginx.service' "${SERVICE_STATE_FILE}" || { printf 'nginx missing'; return 1; }
  grep -q '^caddy.service' "${SERVICE_STATE_FILE}" || { printf 'caddy missing'; return 1; }
  rm -rf "${temp_dir}"
)

test_unknown_owner_aborts_without_kill() (
  local temp_dir actions="" output
  declare -F quiesce_port_443 >/dev/null || { printf 'quiesce_port_443 is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_DIR="${temp_dir}"
  SERVICE_STATE_FILE="${temp_dir}/service-states.tsv"
  get_port_443_pids() { printf '333\n'; }
  systemd_unit_for_pid() { return 1; }
  process_name_for_pid() { printf 'custom-daemon\n'; }
  run_systemctl() { actions+="$*|"; }
  if quiesce_port_443 >"${temp_dir}/output" 2>&1; then
    printf 'unknown owner was accepted'
    return 1
  fi
  output="$(cat "${temp_dir}/output")"
  [[ -z "${actions}" ]] || { printf 'systemctl was called'; return 1; }
  [[ "${output}" == *'333'* && "${output}" == *'custom-daemon'* ]] || { printf 'PID/process not reported'; return 1; }
  rm -rf "${temp_dir}"
)

test_ssh_unit_is_never_stopped() (
  local temp_dir actions=""
  declare -F quiesce_port_443 >/dev/null || { printf 'quiesce_port_443 is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_DIR="${temp_dir}"
  SERVICE_STATE_FILE="${temp_dir}/service-states.tsv"
  get_port_443_pids() { printf '444\n'; }
  systemd_unit_for_pid() { printf 'sshd.service\n'; }
  process_name_for_pid() { printf 'sshd\n'; }
  run_systemctl() { actions+="$*|"; }
  quiesce_port_443 >/dev/null 2>&1 && { printf 'SSH owner was accepted'; return 1; }
  [[ -z "${actions}" ]] || { printf 'SSH service was changed'; return 1; }
  rm -rf "${temp_dir}"
)

test_restore_service_states_exactly() (
  local temp_dir actions=""
  declare -F restore_service_states >/dev/null || { printf 'restore_service_states is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  SERVICE_STATE_FILE="${temp_dir}/service-states.tsv"
  printf 'nginx.service\tactive\tenabled\ncaddy.service\tinactive\tdisabled\n' >"${SERVICE_STATE_FILE}"
  run_systemctl() { actions+="$*|"; }
  restore_service_states
  [[ "${actions}" == *'enable nginx.service|'* && "${actions}" == *'start nginx.service|'* ]] || { printf 'nginx state not restored'; return 1; }
  [[ "${actions}" == *'disable caddy.service|'* && "${actions}" == *'stop caddy.service|'* ]] || { printf 'caddy state not restored'; return 1; }
  rm -rf "${temp_dir}"
)

test_downloads_official_installer_to_mktemp() (
  local temp_root calls=""
  declare -F run_official_xray_installer >/dev/null || { printf 'run_official_xray_installer is not defined'; return 1; }
  temp_root="$(mktemp -d)"
  make_temp_dir() { mkdir -p "${temp_root}/download"; printf '%s\n' "${temp_root}/download"; }
  download_file() { calls+="download:$1:$2|"; printf '#!/usr/bin/env bash\n' >"$2"; }
  execute_installer_script() { calls+="execute:$*|"; }
  run_official_xray_installer
  [[ "${calls}" == download:https://github.com/XTLS/Xray-install/raw/main/install-release.sh:* ]] || { printf 'wrong official URL: %s' "${calls}"; return 1; }
  [[ "${calls}" == *'|execute:'*'/install-release.sh install --without-geodata|' ]] || { printf 'downloaded script was not executed with expected args: %s' "${calls}"; return 1; }
  [[ ! -d "${temp_root}/download" ]] || { printf 'temporary installer directory not cleaned'; return 1; }
  rm -rf "${temp_root}"
)

test_does_not_pipe_curl_to_shell() (
  local temp_root order=""
  declare -F run_official_xray_installer >/dev/null || { printf 'run_official_xray_installer is not defined'; return 1; }
  temp_root="$(mktemp -d)"
  make_temp_dir() { mkdir -p "${temp_root}/download"; printf '%s\n' "${temp_root}/download"; }
  download_file() { order+="download|"; printf '#!/usr/bin/env bash\n' >"$2"; }
  execute_installer_script() { [[ -f "$1" ]] || return 1; order+="execute|"; }
  run_official_xray_installer
  [[ "${order}" == 'download|execute|' ]] || { printf 'installer was not downloaded before execution: %s' "${order}"; return 1; }
  rm -rf "${temp_root}"
)

test_existing_xray_is_not_restarted_before_switch() (
  local installs=0 actions=""
  declare -F ensure_xray_binary >/dev/null || { printf 'ensure_xray_binary is not defined'; return 1; }
  xray_is_usable() { return 0; }
  run_official_xray_installer() { installs=$((installs + 1)); }
  run_systemctl() { actions+="$*|"; }
  ensure_xray_binary
  [[ "${installs}" -eq 0 ]] || { printf 'existing Xray was upgraded early'; return 1; }
  [[ -z "${actions}" ]] || { printf 'existing Xray service was changed: %s' "${actions}"; return 1; }
  [[ "${XRAY_WAS_PRESENT}" == "1" ]] || { printf 'existing Xray not recorded'; return 1; }
)

test_fresh_install_does_not_touch_other_443_service() (
  local attempts=0 actions=""
  declare -F ensure_xray_binary >/dev/null || { printf 'ensure_xray_binary is not defined'; return 1; }
  xray_is_usable() { attempts=$((attempts + 1)); ((attempts > 1)); }
  run_official_xray_installer() { :; }
  run_systemctl() { actions+="$*|"; }
  ensure_xray_binary
  [[ "${actions}" == 'stop xray.service|disable xray.service|' ]] || { printf 'unexpected service changes: %s' "${actions}"; return 1; }
  [[ "${XRAY_WAS_PRESENT}" == "0" ]] || { printf 'fresh Xray state not recorded'; return 1; }
)

test_credentials_have_expected_shapes() (
  declare -F generate_credentials >/dev/null || { printf 'generate_credentials is not defined'; return 1; }
  run_xray() {
    if [[ "$1" == 'uuid' ]]; then
      printf '123e4567-e89b-42d3-a456-426614174000\n'
    else
      printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPassword: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
    fi
  }
  generate_short_id() { printf '0123456789abcdef\n'; }
  generate_credentials
  [[ "${UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { printf 'UUID shape invalid'; return 1; }
  [[ "${PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || { printf 'private key shape invalid'; return 1; }
  [[ "${PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || { printf 'public key shape invalid'; return 1; }
  [[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || { printf 'short ID shape invalid'; return 1; }
)

test_two_runs_rotate_all_credentials() (
  local temp_dir first second
  declare -F generate_credentials >/dev/null || { printf 'generate_credentials is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  printf '0' >"${temp_dir}/counter"
  run_xray() {
    local count
    count="$(cat "${temp_dir}/counter")"
    if [[ "$1" == 'uuid' ]]; then
      if [[ "${count}" == '0' ]]; then
        printf '123e4567-e89b-42d3-a456-426614174000\n'
      else
        printf '223e4567-e89b-42d3-a456-426614174001\n'
      fi
    else
      if [[ "${count}" == '0' ]]; then
        printf 'Private key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nPublic key: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
      else
        printf 'Private key: CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\nPublic key: DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD\n'
      fi
      printf '%s' "$((count + 1))" >"${temp_dir}/counter"
    fi
  }
  generate_short_id() { [[ "$(cat "${temp_dir}/counter")" == '1' ]] && printf '1111111111111111\n' || printf '2222222222222222\n'; }
  generate_credentials
  first="${UUID}|${PRIVATE_KEY}|${PUBLIC_KEY}|${SHORT_ID}"
  generate_credentials
  second="${UUID}|${PRIVATE_KEY}|${PUBLIC_KEY}|${SHORT_ID}"
  [[ "${first}" != "${second}" ]] || { printf 'credentials were reused'; return 1; }
  rm -rf "${temp_dir}"
)

test_private_key_never_appears_in_git_files() (
  local temp_dir
  declare -F render_staged_server_config >/dev/null || { printf 'render_staged_server_config is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  BACKUP_DIR="${temp_dir}/backup"
  mkdir -p "${BACKUP_DIR}"
  UUID='123e4567-e89b-42d3-a456-426614174000'
  PRIVATE_KEY="$(printf '%043d' 7)"
  PUBLIC_KEY="$(printf '%043d' 8)"
  SHORT_ID='abcdef0123456789'
  render_staged_server_config
  [[ -f "${BACKUP_DIR}/staged-config.json" ]] || { printf 'staged config missing'; return 1; }
  if git -C "${REPO_ROOT}" grep -Fq "${PRIVATE_KEY}"; then
    printf 'generated private key leaked into tracked files'
    return 1
  fi
  grep -q '"port": 443' "${BACKUP_DIR}/staged-config.json" || { printf 'fixed port missing'; return 1; }
  grep -q '"network": "raw"' "${BACKUP_DIR}/staged-config.json" || { printf 'raw transport missing'; return 1; }
  grep -q '"target": "www.bing.com:443"' "${BACKUP_DIR}/staged-config.json" || { printf 'target missing'; return 1; }
  rm -rf "${temp_dir}"
)

test_staged_config_is_validated_in_place() (
  local temp_dir args=""
  declare -F validate_staged_server_config >/dev/null || { printf 'validate_staged_server_config is not defined'; return 1; }
  temp_dir="$(mktemp -d)"
  STAGED_CONFIG="${temp_dir}/staged-config.json"
  printf '{}\n' >"${STAGED_CONFIG}"
  run_xray() { args="$*"; }
  validate_staged_server_config
  [[ "${args}" == "run -test -config ${STAGED_CONFIG}" ]] || { printf 'unexpected validation args: %s' "${args}"; return 1; }
  rm -rf "${temp_dir}"
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

run_backup_tests() {
  run_isolated_test test_backup_uses_unique_utc_directory "backup directories are unique"
  run_isolated_test test_backup_copies_only_declared_paths "backup copies only declared paths"
  run_isolated_test test_previous_client_file_is_preserved "previous client file is preserved"
}

run_port_tests() {
  run_isolated_test test_known_systemd_owner_is_stopped_and_disabled "known systemd owner is quiesced"
  run_isolated_test test_multiple_systemd_owners_are_recorded "multiple systemd owners are recorded"
  run_isolated_test test_unknown_owner_aborts_without_kill "unknown owner aborts without kill"
  run_isolated_test test_ssh_unit_is_never_stopped "SSH unit is protected"
  run_isolated_test test_restore_service_states_exactly "service states restore exactly"
}

run_xray_prepare_tests() {
  run_isolated_test test_downloads_official_installer_to_mktemp "official installer is downloaded locally"
  run_isolated_test test_does_not_pipe_curl_to_shell "installer download precedes execution"
  run_isolated_test test_existing_xray_is_not_restarted_before_switch "existing Xray is not restarted early"
  run_isolated_test test_fresh_install_does_not_touch_other_443_service "fresh Xray install only stops Xray"
  run_isolated_test test_credentials_have_expected_shapes "generated credentials have valid shapes"
  run_isolated_test test_two_runs_rotate_all_credentials "repeated runs rotate credentials"
  run_isolated_test test_private_key_never_appears_in_git_files "private key remains outside repository"
  run_isolated_test test_staged_config_is_validated_in_place "staged config is validated in place"
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
  backup)
    run_backup_tests
    ;;
  port)
    run_port_tests
    ;;
  xray_prepare)
    run_xray_prepare_tests
    ;;
  all)
    test_constants_are_fixed
    test_source_does_not_run_main
    run_platform_tests
    run_network_tests
    run_backup_tests
    run_port_tests
    run_xray_prepare_tests
    ;;
  *)
    fail "test selector" "unknown selector: $1"
    ;;
esac

printf '%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
((FAIL_COUNT == 0))
