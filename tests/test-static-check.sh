#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CHECKER="${TEST_DIR}/static-check.sh"
INSTALLER="${REPO_ROOT}/install.sh"
TEMP_DIR="$(mktemp -d)"
PASS_COUNT=0
trap 'rm -rf "${TEMP_DIR}"' EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok - static %s\n' "$1"
}

expect_reject_append() {
  local name="$1" payload="$2" fixture
  fixture="${TEMP_DIR}/${name}.sh"
  cp "${INSTALLER}" "${fixture}"
  printf '\n%s\n' "${payload}" >>"${fixture}"
  if bash "${CHECKER}" "${fixture}" >/dev/null 2>&1; then
    printf 'not ok - static %s was accepted\n' "${name}" >&2
    return 1
  fi
  pass "${name} rejected"
}

[[ -f "${CHECKER}" ]] || {
  printf 'not ok - static checker is missing\n' >&2
  exit 1
}

bash "${CHECKER}" "${INSTALLER}"
pass "real installer accepted"

expect_reject_append hardcoded_uuid "UUID='123e4567-e89b-42d3-a456-426614174000'"
expect_reject_append hardcoded_private_key "PRIVATE_KEY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'"
expect_reject_append hardcoded_short_id "SHORT_ID='0123456789abcdef'"
expect_reject_append stop_ssh "systemctl stop sshd.service"
expect_reject_append disable_firewall "systemctl disable --now firewalld.service"
expect_reject_append force_kill "kill -9 1234"
expect_reject_append curl_pipe_bash "curl -fsSL https://example.invalid/install.sh | bash"

sed '/mktemp -d/d' "${INSTALLER}" >"${TEMP_DIR}/missing_mktemp.sh"
if bash "${CHECKER}" "${TEMP_DIR}/missing_mktemp.sh" >/dev/null 2>&1; then
  printf 'not ok - static missing_mktemp was accepted\n' >&2
  exit 1
fi
pass "missing_mktemp rejected"

sed '/trap .*RETURN/d; /trap .*INT TERM/d' "${INSTALLER}" >"${TEMP_DIR}/missing_trap.sh"
if bash "${CHECKER}" "${TEMP_DIR}/missing_trap.sh" >/dev/null 2>&1; then
  printf 'not ok - static missing_trap was accepted\n' >&2
  exit 1
fi
pass "missing_trap rejected"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'make_temp_dir() { mktemp -d; }' \
  "cleanup() { trap ':' RETURN; }" \
  'main() {' \
  '  quiesce_port_443' \
  '  validate_staged_server_config' \
  '}' >"${TEMP_DIR}/unsafe_order.sh"
if bash "${CHECKER}" "${TEMP_DIR}/unsafe_order.sh" >/dev/null 2>&1; then
  printf 'not ok - static unsafe_order was accepted\n' >&2
  exit 1
fi
pass "unsafe_order rejected"

printf '%s static checks passed\n' "${PASS_COUNT}"
