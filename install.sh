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

utc_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

root_path() {
  printf '%s%s\n' "${VRI_ROOT:-}" "$1"
}

create_backup_dir() {
  local backup_root="${BACKUP_ROOT:-/root/vless-reality-installer-backups}"
  local timestamp candidate suffix=0

  timestamp="$(utc_timestamp)"
  candidate="${backup_root}/${timestamp}"
  while [[ -e "${candidate}" ]]; do
    suffix=$((suffix + 1))
    candidate="${backup_root}/${timestamp}-$(printf '%02d' "${suffix}")"
  done
  mkdir -p "${candidate}/files"
  BACKUP_DIR="${candidate}"
  SERVICE_STATE_FILE="${BACKUP_DIR}/service-states.tsv"
  : >"${SERVICE_STATE_FILE}"
}

backup_one_path() {
  local absolute_path="$1"
  local source_path destination

  source_path="$(root_path "${absolute_path}")"
  [[ -e "${source_path}" || -L "${source_path}" ]] || return 0
  destination="${BACKUP_DIR}/files${absolute_path}"
  mkdir -p "$(dirname "${destination}")"
  cp -a "${source_path}" "${destination}"
}

backup_existing_state() {
  local path
  local -a paths=(
    /usr/local/etc/xray
    /usr/local/bin/xray
    /etc/xray
    /etc/v2ray
    /etc/systemd/system/xray.service
    /etc/systemd/system/xray@.service
    /etc/systemd/system/xray.service.d
    /etc/systemd/system/xray@.service.d
    /etc/nginx
    /etc/caddy
    /etc/httpd
    /etc/apache2
    "${CLIENT_OUTPUT}"
  )

  [[ -n "${BACKUP_DIR:-}" ]] || { die "未创建备份目录。"; return 1; }
  for path in "${paths[@]}"; do
    backup_one_path "${path}"
  done
}

run_systemctl() {
  systemctl "$@"
}

get_port_443_pids() {
  ss -H -ltnp "sport = :${XRAY_PORT}" 2>/dev/null \
    | grep -oE 'pid=[0-9]+' \
    | cut -d= -f2 \
    | sort -n -u || true
}

systemd_unit_for_pid() {
  local pid="$1" proc_root="${PROC_ROOT:-/proc}" unit verified
  local cgroup_file="${proc_root}/${pid}/cgroup"

  [[ -r "${cgroup_file}" ]] || return 1
  unit="$(grep -oE '[^/[:space:]]+\.service' "${cgroup_file}" | tail -n 1)"
  [[ -n "${unit}" && "${unit}" == *.service ]] || return 1
  verified="$(run_systemctl show --property=Id --value "${unit}" 2>/dev/null)" || return 1
  [[ "${verified}" == "${unit}" ]] || return 1
  printf '%s\n' "${unit}"
}

process_name_for_pid() {
  local pid="$1" proc_root="${PROC_ROOT:-/proc}"
  if [[ -r "${proc_root}/${pid}/comm" ]]; then
    head -n 1 "${proc_root}/${pid}/comm"
  else
    ps -p "${pid}" -o comm= 2>/dev/null || printf 'unknown\n'
  fi
}

service_active_state() {
  run_systemctl is-active "$1" 2>/dev/null || true
}

service_enabled_state() {
  run_systemctl is-enabled "$1" 2>/dev/null || true
}

capture_service_state() {
  local unit="$1" active enabled
  [[ -n "${SERVICE_STATE_FILE:-}" ]] || { die "服务状态文件未初始化。"; return 1; }
  if grep -Fq "${unit}"$'\t' "${SERVICE_STATE_FILE}" 2>/dev/null; then
    return 0
  fi
  active="$(service_active_state "${unit}")"
  enabled="$(service_enabled_state "${unit}")"
  [[ -n "${active}" ]] || active="inactive"
  [[ -n "${enabled}" ]] || enabled="disabled"
  printf '%s\t%s\t%s\n' "${unit}" "${active}" "${enabled}" >>"${SERVICE_STATE_FILE}"
}

quiesce_port_443() {
  local pid unit name existing
  local -a pids=() units=()

  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done < <(get_port_443_pids)

  for pid in "${pids[@]}"; do
    unit="$(systemd_unit_for_pid "${pid}" 2>/dev/null || true)"
    name="$(process_name_for_pid "${pid}" 2>/dev/null || printf 'unknown')"
    if [[ -z "${unit}" ]]; then
      die "443 端口由未知非 systemd 进程占用: PID=${pid}, process=${name}。"
      return 1
    fi
    if [[ "${unit}" == "ssh.service" || "${unit}" == "sshd.service" ]]; then
      die "拒绝停止 SSH 服务 ${unit} (PID=${pid})。"
      return 1
    fi
    existing=" no "
    if ((${#units[@]} > 0)); then
      existing=" ${units[*]} "
    fi
    [[ "${existing}" == *" ${unit} "* ]] || units+=("${unit}")
  done

  for unit in "${units[@]}"; do
    capture_service_state "${unit}"
  done
  for unit in "${units[@]}"; do
    run_systemctl stop "${unit}"
    run_systemctl disable "${unit}"
  done
}

restore_service_states() {
  local unit active enabled
  [[ -f "${SERVICE_STATE_FILE:-}" ]] || return 0
  while IFS=$'\t' read -r unit active enabled; do
    [[ -n "${unit}" ]] || continue
    case "${enabled}" in
      enabled) run_systemctl enable "${unit}" ;;
      disabled) run_systemctl disable "${unit}" ;;
      masked) run_systemctl mask "${unit}" ;;
    esac
    if [[ "${active}" == "active" ]]; then
      run_systemctl start "${unit}"
    else
      run_systemctl stop "${unit}"
    fi
  done <"${SERVICE_STATE_FILE}"
}

make_temp_dir() {
  mktemp -d
}

download_file() {
  local url="$1" output="$2"
  curl -fsSL --connect-timeout 10 --max-time 120 "${url}" -o "${output}"
}

execute_installer_script() {
  bash "$@"
}

run_official_xray_installer() {
  local temp_dir installer status=0
  temp_dir="$(make_temp_dir)"
  installer="${temp_dir}/install-release.sh"
  trap 'rm -rf "${temp_dir}"' RETURN

  download_file \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    "${installer}" || status=$?
  if ((status == 0)); then
    execute_installer_script "${installer}" install --without-geodata "$@" || status=$?
  fi

  rm -rf "${temp_dir}"
  trap - RETURN
  return "${status}"
}

locate_xray_binary() {
  if command_exists xray; then
    command -v xray
  elif [[ -x /usr/local/bin/xray ]]; then
    printf '/usr/local/bin/xray\n'
  else
    return 1
  fi
}

run_xray() {
  "${XRAY_BIN:-/usr/local/bin/xray}" "$@"
}

xray_is_usable() {
  local binary
  binary="$(locate_xray_binary)" || return 1
  XRAY_BIN="${binary}"
  run_xray version >/dev/null 2>&1 || return 1
  run_xray uuid >/dev/null 2>&1 || return 1
  run_xray x25519 >/dev/null 2>&1 || return 1
}

ensure_xray_binary() {
  if xray_is_usable; then
    XRAY_WAS_PRESENT="1"
    return 0
  fi

  XRAY_WAS_PRESENT="0"
  run_official_xray_installer || return
  xray_is_usable || { die "Xray 安装后仍无法执行。"; return 1; }
  run_systemctl stop xray.service
  run_systemctl disable xray.service
}

generate_short_id() {
  openssl rand -hex 8
}

generate_credentials() {
  local x25519_output
  UUID="$(run_xray uuid | tr '[:upper:]' '[:lower:]')" || return
  x25519_output="$(run_xray x25519)" || return
  PRIVATE_KEY="$(awk -F ': *' '/^(PrivateKey|Private key):/{print $2; exit}' <<<"${x25519_output}")"
  PUBLIC_KEY="$(awk -F ': *' '/^(PublicKey|Public key|Password):/{print $2; exit}' <<<"${x25519_output}")"
  SHORT_ID="$(generate_short_id | tr '[:upper:]' '[:lower:]')" || return

  [[ "${UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
    die "Xray 生成的 UUID 格式无效。"
    return 1
  }
  [[ "${PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || { die "REALITY 私钥格式无效。"; return 1; }
  [[ "${PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || { die "REALITY 公钥格式无效。"; return 1; }
  [[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || { die "REALITY Short ID 格式无效。"; return 1; }
}

render_staged_server_config() {
  [[ -n "${BACKUP_DIR:-}" ]] || { die "未创建备份目录。"; return 1; }
  STAGED_CONFIG="${BACKUP_DIR}/staged-config.json"
  umask 077
  command cat >"${STAGED_CONFIG}" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${UUID}", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_HOST}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
}

validate_staged_server_config() {
  [[ -f "${STAGED_CONFIG:-}" ]] || { die "待校验的 Xray 配置不存在。"; return 1; }
  run_xray run -test -config "${STAGED_CONFIG}"
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
