#!/usr/bin/env bash

set -euo pipefail

TARGET="${1:-install.sh}"

[[ -f "${TARGET}" ]] || {
  printf 'static-check: file not found: %s\n' "${TARGET}" >&2
  exit 1
}

reject_pattern() {
  local description="$1" pattern="$2"
  if grep -En "${pattern}" "${TARGET}" >/dev/null; then
    printf 'static-check: rejected %s\n' "${description}" >&2
    return 1
  fi
}

reject_pattern 'hardcoded UUID' "UUID=['\"][0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}['\"]"
reject_pattern 'hardcoded REALITY private key' "PRIVATE_KEY=['\"][A-Za-z0-9_-]{43}['\"]"
reject_pattern 'hardcoded REALITY short ID' "SHORT_ID=['\"][0-9a-fA-F]{16}['\"]"
reject_pattern 'SSH stop or disable command' '(systemctl|run_systemctl)[[:space:]]+(stop|disable)([[:space:]]+--now)?[[:space:]]+(ssh|sshd)(\.service)?'
reject_pattern 'firewall shutdown command' '(systemctl|run_systemctl)[[:space:]]+(stop|disable)([[:space:]]+--now)?[[:space:]]+(firewalld|ufw)(\.service)?|ufw[[:space:]]+disable|iptables[[:space:]]+-F|nft[[:space:]]+flush'
reject_pattern 'forced process kill' '(^|[;&|[:space:]])(kill[[:space:]]+-9|pkill|killall)([;&|[:space:]]|$)'
reject_pattern 'curl piped to a shell' 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh)([[:space:]]|$)'

grep -Eq 'mktemp[[:space:]]+-d' "${TARGET}" || {
  printf 'static-check: mktemp -d is required\n' >&2
  exit 1
}
grep -Eq 'trap[[:space:]]+' "${TARGET}" || {
  printf 'static-check: cleanup trap is required\n' >&2
  exit 1
}

main_body="$(awk '/^main\(\)[[:space:]]*\{/{inside=1} inside{print} inside && /^}/{exit}' "${TARGET}")"
validate_line="$(grep -n 'validate_staged_server_config' <<<"${main_body}" | head -n 1 | cut -d: -f1 || true)"
switch_line="$(grep -nE 'run_install_transaction|quiesce_port_443' <<<"${main_body}" | head -n 1 | cut -d: -f1 || true)"
if [[ -z "${validate_line}" || -z "${switch_line}" || "${validate_line}" -ge "${switch_line}" ]]; then
  printf 'static-check: config validation must precede the port switch\n' >&2
  exit 1
fi

printf 'static-check: %s passed\n' "${TARGET}"
