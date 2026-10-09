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

get_effective_uid() {
  id -u
}

machine_arch() {
  uname -m
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

systemd_is_running() {
  [[ -d /run/systemd/system ]] && command_exists systemctl
}

require_root() {
  [[ "$(get_effective_uid)" == "0" ]] || die "请以 root 身份运行。"
}

detect_platform() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local machine id_like_words
  local ID="" ID_LIKE=""

  [[ -r "${os_release_file}" ]] || die "无法读取 ${os_release_file}。"
  # shellcheck disable=SC1090
  source "${os_release_file}"
  machine="$(machine_arch)"

  case "${machine}" in
    x86_64 | amd64) ARCH="64" ;;
    aarch64 | arm64) ARCH="arm64-v8a" ;;
    *) die "不支持的 CPU 架构: ${machine}" || return ;;
  esac

  id_like_words=" ${ID_LIKE:-} "
  case "${ID:-}" in
    debian | ubuntu)
      OS_FAMILY="debian"
      ;;
    centos | rocky | almalinux | ol)
      OS_FAMILY="rhel"
      ;;
    *)
      if [[ "${id_like_words}" == *" debian "* ]]; then
        OS_FAMILY="debian"
      elif [[ "${id_like_words}" == *" rhel "* || "${id_like_words}" == *" centos "* || "${id_like_words}" == *" fedora "* ]]; then
        OS_FAMILY="rhel"
      else
        die "不支持的 Linux 发行版: ${ID:-unknown}" || return
      fi
      ;;
  esac

  if [[ "${OS_FAMILY}" == "debian" ]]; then
    command_exists apt-get || { die "未找到 apt-get。"; return 1; }
    PKG_MANAGER="apt-get"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  else
    die "未找到 dnf 或 yum。" || return
  fi
}

preflight_platform() {
  require_root || return
  systemd_is_running || { die "仅支持使用 systemd 的 Linux。"; return 1; }
  detect_platform
}

install_dependencies() {
  if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl unzip openssl ca-certificates iproute2
  else
    "${PKG_MANAGER}" install -y curl unzip openssl ca-certificates iproute
  fi
}

check_github_access() {
  curl -4 -fsSI --connect-timeout 5 --max-time 15 \
    https://github.com/XTLS/Xray-install >/dev/null || {
    die "无法访问 GitHub，请检查 DNS 和网络。"
    return 1
  }
}

is_ipv4() {
  local value="$1" octet
  local old_ifs="${IFS}"
  local -a parts

  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a parts <<<"${value}"
  IFS="${old_ifs}"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for octet in "${parts[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
  done
}

detect_public_ipv4() {
  local endpoint candidate
  for endpoint in \
    https://api.ipify.org \
    https://ifconfig.me/ip \
    https://icanhazip.com; do
    candidate="$(curl -4 -fsS --connect-timeout 5 --max-time 10 "${endpoint}" 2>/dev/null || true)"
    candidate="${candidate//$'\r'/}"
    candidate="${candidate//$'\n'/}"
    if is_ipv4 "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  die "无法检测服务器公网 IPv4。"
}

run_with_timeout() {
  timeout "$@"
}

check_reality_target() {
  local tls_output
  tls_output="$(run_with_timeout 15 openssl s_client \
    -connect "${REALITY_DEST}" \
    -servername "${REALITY_HOST}" \
    -tls1_3 </dev/null 2>&1)" || {
    die "${REALITY_DEST} 的 TLS 1.3 握手失败。"
    return 1
  }
  grep -q 'TLSv1\.3' <<<"${tls_output}" || {
    die "${REALITY_DEST} 未报告 TLS 1.3。"
    return 1
  }
}

preflight() {
  preflight_platform || return
  install_dependencies || return
  check_github_access || return
  PUBLIC_IPV4="$(detect_public_ipv4)" || return
  readonly PUBLIC_IPV4
  check_reality_target
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
