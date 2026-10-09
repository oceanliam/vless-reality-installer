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

load_installer() {
  if [[ ! -f "${INSTALLER}" ]]; then
    fail "installer exists" "missing ${INSTALLER}"
    return 1
  fi
  # shellcheck source=../install.sh
  source "${INSTALLER}"
}

test_constants_are_fixed() {
  load_installer || return
  assert_eq "port is fixed" "443" "${XRAY_PORT:-}"
  assert_eq "reality host is fixed" "www.bing.com" "${REALITY_HOST:-}"
  assert_eq "reality destination is fixed" "www.bing.com:443" "${REALITY_DEST:-}"
  assert_eq "client output is fixed" "/root/VLESS-REALITY-Vision.txt" "${CLIENT_OUTPUT:-}"
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

test_constants_are_fixed
test_source_does_not_run_main

printf '%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
((FAIL_COUNT == 0))
