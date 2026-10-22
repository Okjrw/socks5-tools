#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SERVICE_NAME="xray-socks5"
readonly SERVICE_USER="xray-socks5"
readonly INSTALL_DIR="/opt/xray-socks5"
readonly CONFIG_DIR="/etc/xray-socks5"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly BACKUP_DIR="/var/backups/xray-socks5"
readonly XRAY_VERSION="v26.3.27"
readonly XRAY_ZIP="Xray-linux-64.zip"
readonly XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ZIP}"
readonly XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"

# 兼容 argosbx 的一键变量：sopt=端口，uuid=用户名和密码
PORT="${sopt:-23456}"
LOGIN="${uuid:-}"
PASSWORD="${uuid:-}"
LISTEN_ADDR="0.0.0.0"
ENABLE_UDP=0
FORCE=0
ALLOW_CIDRS=()

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

info() {
  printf '[%s] %s\n' "$SERVICE_NAME" "$*"
}

usage() {
  cat <<'EOF'
用法：sudo ./install.sh [选项]

选项：
  --port N              监听端口，默认 23456（范围 1024-65535）
  --username NAME       SOCKS5 用户名，默认随机生成
  --password PASS       SOCKS5 密码，默认随机生成
  --listen ADDR         监听地址，默认 0.0.0.0；可填 :: 启用 IPv6
  --allow-cidr CIDR     允许连接的来源 IP/CIDR，可重复或逗号分隔
  --udp                 开启 SOCKS5 UDP ASSOCIATE，默认关闭
  --force               覆盖现有安装；旧配置会先备份
  -h, --help            显示帮助

示例：
  sudo ./install.sh --port 23456
  sudo ./install.sh --port 23456 --allow-cidr 203.0.113.10/32
  sudo ./install.sh --port 23456 --allow-cidr 203.0.113.0/24 --udp

兼容 argosbx 环境变量：
  sopt="3223" uuid="自定义账号密码" sudo -E bash install.sh
EOF
}

need_value() {
  [[ $# -ge 2 ]] || die "参数 $1 缺少值"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      need_value "$@"
      PORT="$2"
      shift 2
      ;;
    --username)
      need_value "$@"
      LOGIN="$2"
      shift 2
      ;;
    --password)
      need_value "$@"
      PASSWORD="$2"
      shift 2
      ;;
    --listen)
      need_value "$@"
      LISTEN_ADDR="$2"
      shift 2
      ;;
    --allow-cidr)
      need_value "$@"
      ALLOW_CIDRS+=("$2")
      shift 2
      ;;
    --udp)
      ENABLE_UDP=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（使用 --help 查看用法）"
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"
[[ -r /etc/os-release ]] || die "无法识别操作系统"

# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == "ubuntu" ]] || die "此安装包仅针对 Ubuntu 24.04"
[[ ${VERSION_ID:-} == "24.04" ]] || die "此安装包仅针对 Ubuntu 24.04，当前为 ${VERSION_ID:-未知}"
[[ $(uname -m) == "x86_64" ]] || die "此安装包仅针对 x86_64"
command -v systemctl >/dev/null 2>&1 || die "系统未使用 systemd"

missing_deps=0
for cmd in curl unzip sha256sum openssl ss install; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing_deps=1
  fi
done

if (( missing_deps )); then
  info "安装基础依赖"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl unzip openssl iproute2
fi

[[ ${PORT} =~ ^[0-9]+$ ]] || die "端口必须是数字"
PORT=$((10#${PORT}))
(( PORT >= 1024 && PORT <= 65535 )) || die "端口必须在 1024-65535 之间"

case "${LISTEN_ADDR}" in
  0.0.0.0|::) ;;
  127.0.0.1|::1) ;;
  *)
    [[ ${LISTEN_ADDR} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || ${LISTEN_ADDR} =~ ^[0-9A-Fa-f:]+$ ]] \
      || die "监听地址格式不正确"
    ;;
esac

[[ -n ${LOGIN} ]] || LOGIN="s5-$(openssl rand -hex 6)"
[[ -n ${PASSWORD} ]] || PASSWORD="$(openssl rand -hex 24)"

[[ ${LOGIN} =~ ^[A-Za-z0-9._-]{4,64}$ ]] \
  || die "用户名只能包含字母、数字、点、下划线、连字符，长度 4-64"
[[ ${PASSWORD} =~ ^[A-Za-z0-9._~-]{12,128}$ ]] \
  || die "密码只能包含字母、数字、点、下划线、波浪号、连字符，长度 12-128"

validate_cidr() {
  local cidr="$1"
  local base prefix octet
  local -a octets

  [[ ${cidr} =~ ^[0-9A-Fa-f:./]+$ ]] || return 1

  if [[ ${cidr} == *:* ]]; then
    [[ ${cidr} =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] || return 1
    prefix=128
    [[ ${cidr} == */* ]] && prefix="${cidr#*/}"
    (( 10#${prefix} <= 128 )) || return 1
  else
    [[ ${cidr} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    base="${cidr%%/*}"
    IFS='.' read -r -a octets <<< "${base}"
    for octet in "${octets[@]}"; do
      (( 10#${octet} <= 255 )) || return 1
    done
    prefix=32
    [[ ${cidr} == */* ]] && prefix="${cidr#*/}"
    (( 10#${prefix} <= 32 )) || return 1
  fi
}

ALLOW_LIST=()
parse_allow_cidrs() {
  local group cidr
  local -a entries

  for group in "${ALLOW_CIDRS[@]}"; do
    IFS=',' read -r -a entries <<< "${group}"
    for cidr in "${entries[@]}"; do
      cidr="${cidr//[[:space:]]/}"
      [[ -n ${cidr} ]] || continue
      validate_cidr "${cidr}" || die "来源 CIDR 格式不正确：${cidr}"
      ALLOW_LIST+=("${cidr}")
    done
  done
}
if ((${#ALLOW_CIDRS[@]} > 0)); then
  parse_allow_cidrs
fi

port_in_use() {
  local proto="$1"
  if [[ ${proto} == "tcp" ]]; then
    ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q .
  else
    ss -H -lun "sport = :${PORT}" 2>/dev/null | grep -q .
  fi
}

if [[ -e ${CONFIG_FILE} || -e ${UNIT_FILE} || -e ${INSTALL_DIR}/xray ]]; then
  (( FORCE )) || die "检测到已有安装；如需重装请加 --force，旧配置会先备份"
  install -d -m 0700 -o root -g root "${BACKUP_DIR}"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -e ${CONFIG_FILE} ]]; then
    cp -a "${CONFIG_FILE}" "${BACKUP_DIR}/config.json.${stamp}"
  fi
  if [[ -e ${UNIT_FILE} ]]; then
    cp -a "${UNIT_FILE}" "${BACKUP_DIR}/${SERVICE_NAME}.service.${stamp}"
  fi
  info "已备份旧配置到 ${BACKUP_DIR}"
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  port_in_use tcp && die "TCP 端口 ${PORT} 已被占用"
  if (( ENABLE_UDP )); then
    port_in_use udp && die "UDP 端口 ${PORT} 已被占用"
  fi
fi

if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
  groupadd --system "${SERVICE_USER}"
fi
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --gid "${SERVICE_USER}" --home-dir /nonexistent \
    --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

install -d -m 0755 -o root -g root "${INSTALL_DIR}"
install -d -m 0755 -o root -g root "${CONFIG_DIR}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

info "下载 Xray ${XRAY_VERSION}"
curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
  --connect-timeout 10 --max-time 300 \
  -o "${tmpdir}/${XRAY_ZIP}" "${XRAY_URL}"

actual_sha256="$(sha256sum "${tmpdir}/${XRAY_ZIP}" | awk '{print $1}')"
[[ ${actual_sha256} == "${XRAY_SHA256}" ]] \
  || die "Xray 校验失败：期望 ${XRAY_SHA256}，实际 ${actual_sha256}"

unzip -p "${tmpdir}/${XRAY_ZIP}" xray > "${tmpdir}/xray"
[[ -s ${tmpdir}/xray ]] || die "压缩包中未找到 xray 二进制"
chmod 0755 "${tmpdir}/xray"
"${tmpdir}/xray" version >/dev/null 2>&1 || die "下载的 Xray 无法运行"

if (( ENABLE_UDP )); then
  UDP_JSON="true"
else
  UDP_JSON="false"
fi

CIDR_JSON=""
for cidr in "${ALLOW_LIST[@]}"; do
  CIDR_JSON+="${CIDR_JSON:+,}\"${cidr}\""
done

BLOCK_IPS='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","198.18.0.0/15","::1/128","fc00::/7","fe80::/10","ff00::/8"]'

if [[ -n ${CIDR_JSON} ]]; then
  ROUTING_RULES="      {
        \"type\": \"field\",
        \"ip\": ${BLOCK_IPS},
        \"outboundTag\": \"blocked\"
      },
      {
        \"type\": \"field\",
        \"source\": [${CIDR_JSON}],
        \"outboundTag\": \"direct\"
      }"
  ROUTING_FINAL="blocked"
else
  ROUTING_RULES="      {
        \"type\": \"field\",
        \"ip\": ${BLOCK_IPS},
        \"outboundTag\": \"blocked\"
      }"
  ROUTING_FINAL="direct"
fi

cat > "${tmpdir}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks5-in",
      "listen": "${LISTEN_ADDR}",
      "port": ${PORT},
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "${LOGIN}",
            "pass": "${PASSWORD}"
          }
        ],
        "udp": ${UDP_JSON}
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
${ROUTING_RULES}
    ],
    "final": "${ROUTING_FINAL}"
  }
}
EOF

info "校验 Xray 配置"
"${tmpdir}/xray" run -test -config "${tmpdir}/config.json" >/dev/null \
  || die "Xray 配置校验失败"

systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
port_in_use tcp && die "TCP 端口 ${PORT} 已被其他进程占用"
if (( ENABLE_UDP )); then
  port_in_use udp && die "UDP 端口 ${PORT} 已被其他进程占用"
fi

install -m 0755 -o root -g root "${tmpdir}/xray" "${INSTALL_DIR}/xray"
install -m 0600 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
  "${tmpdir}/config.json" "${CONFIG_FILE}"

cat > "${tmpdir}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Minimal SOCKS5 proxy (Xray)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${INSTALL_DIR}/xray run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
TimeoutStopSec=5
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=65536
TasksMax=256

[Install]
WantedBy=multi-user.target
EOF

install -m 0644 -o root -g root "${tmpdir}/${SERVICE_NAME}.service" "${UNIT_FILE}"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
systemctl restart "${SERVICE_NAME}"
sleep 1

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
  die "服务启动失败"
fi

if ! ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q .; then
  journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
  die "服务已启动，但端口 ${PORT} 未监听"
fi

if [[ ${LISTEN_ADDR} == "0.0.0.0" || ${LISTEN_ADDR} == "::" ]]; then
  if [[ ${LISTEN_ADDR} == *:* ]]; then
    PUBLIC_IP="$(curl -6 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  else
    PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ -n ${PUBLIC_IP} ]] || PUBLIC_IP="<VPS_PUBLIC_IP>"
else
  PUBLIC_IP="${LISTEN_ADDR}"
fi

DISPLAY_HOST="${PUBLIC_IP}"
[[ ${PUBLIC_IP} == *:* ]] && DISPLAY_HOST="[${PUBLIC_IP}]"

if ((${#ALLOW_LIST[@]} > 0)); then
  ALLOW_DISPLAY="${ALLOW_LIST[*]}"
else
  ALLOW_DISPLAY="任意来源"
fi

cat <<EOF

================ SOCKS5 客户端参数 ================
代理类型：SOCKS5
服务器：${DISPLAY_HOST}
端口：${PORT}
用户名：${LOGIN}
密码：${PASSWORD}
UDP：$([[ ${UDP_JSON} == true ]] && echo 开启 || echo 关闭)
允许来源：${ALLOW_DISPLAY}
===================================================

服务命令：
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f

配置文件：
  ${CONFIG_FILE}

EOF

print_ufw_rules() {
  local proto="$1"
  if ((${#ALLOW_LIST[@]} > 0)); then
    for cidr in "${ALLOW_LIST[@]}"; do
      printf '  ufw allow from %s to any port %s proto %s\n' "${cidr}" "${PORT}" "${proto}"
    done
  else
    printf '  ufw allow %s/%s\n' "${PORT}" "${proto}"
  fi
}

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  echo "检测到 UFW 已启用。脚本没有自动改防火墙，请按需执行："
  print_ufw_rules tcp
  if (( ENABLE_UDP )); then
    print_ufw_rules udp
  fi
  echo
fi

if ((${#ALLOW_LIST[@]} == 0)); then
  echo "警告：当前允许任意来源连接 SOCKS5。"
  echo "SOCKS5 不提供传输加密，建议使用 --allow-cidr 限制来源，并在云安全组只放行所需端口。"
  echo
fi

echo "别忘了在 VPS 云厂商安全组放行 TCP/${PORT}$([[ ${ENABLE_UDP} -eq 1 ]] && echo " 和 UDP/${PORT}")。"
echo "测试：curl --socks5-hostname ${DISPLAY_HOST}:${PORT} --proxy-user '${LOGIN}:${PASSWORD}' https://api.ipify.org"
