#!/usr/bin/env bash

set -Eeuo pipefail

readonly XRAY_PORT="443"
readonly REALITY_HOST="www.bing.com"
readonly REALITY_DEST="www.bing.com:443"
readonly CLIENT_OUTPUT="/root/VLESS-REALITY-Vision.txt"

log() {
  printf '[vless-reality-installer] %s\n' "$*"
}

die() {
  printf '[vless-reality-installer] 错误: %s\n' "$*" >&2
  return 1
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
