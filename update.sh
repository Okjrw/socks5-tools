#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SERVICE_NAME="xray-socks5"
readonly INSTALL_DIR="/opt/xray-socks5"
readonly CONFIG_FILE="/etc/xray-socks5/config.json"
readonly UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly BACKUP_DIR="/var/backups/xray-socks5"

VERSION=""
SHA256=""

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：sudo ./update.sh --version vX.Y.Z --sha256 SHA256

说明：
  只替换 Xray 二进制，不修改端口、账号和路由配置。
  必须显式提供目标版本和官方 SHA256，避免自动信任 latest。

示例：
  sudo ./update.sh --version v26.3.27 \
    --sha256 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
EOF
}

need_value() {
  [[ $# -ge 2 ]] || die "参数 $1 缺少值"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      need_value "$@"
      VERSION="$2"
      shift 2
      ;;
    --sha256)
      need_value "$@"
      SHA256="$2"
      shift 2
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
[[ ${VERSION} =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]] || die "版本格式应类似 v26.3.27"
[[ ${SHA256} =~ ^[0-9A-Fa-f]{64}$ ]] || die "SHA256 必须是 64 位十六进制"
SHA256="${SHA256,,}"

[[ -x ${INSTALL_DIR}/xray ]] || die "未检测到已安装的 Xray"
[[ -r ${CONFIG_FILE} ]] || die "未找到配置文件 ${CONFIG_FILE}"
[[ -e ${UNIT_FILE} ]] || die "未找到 systemd 服务"

for cmd in curl unzip sha256sum systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：${cmd}"
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

zip_name="Xray-linux-64.zip"
url="https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${zip_name}"

echo "下载 Xray ${VERSION}"
curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
  --connect-timeout 10 --max-time 300 \
  -o "${tmpdir}/${zip_name}" "${url}"

actual_sha256="$(sha256sum "${tmpdir}/${zip_name}" | awk '{print $1}')"
[[ ${actual_sha256} == "${SHA256}" ]] \
  || die "Xray 校验失败：期望 ${SHA256}，实际 ${actual_sha256}"

unzip -p "${tmpdir}/${zip_name}" xray > "${tmpdir}/xray"
[[ -s ${tmpdir}/xray ]] || die "压缩包中未找到 xray 二进制"
chmod 0755 "${tmpdir}/xray"

"${tmpdir}/xray" version >/dev/null 2>&1 || die "新版本 Xray 无法运行"
echo "使用现有配置校验新版本"
"${tmpdir}/xray" run -test -config "${CONFIG_FILE}" >/dev/null || die "新版本无法通过现有配置校验"

install -d -m 0700 -o root -g root "${BACKUP_DIR}"
stamp="$(date +%Y%m%d-%H%M%S)"
old_version="$("${INSTALL_DIR}/xray" version 2>/dev/null | awk 'NR==1{print $2}')"
cp -a "${INSTALL_DIR}/xray" "${BACKUP_DIR}/xray-${old_version:-unknown}.${stamp}"

was_active=0
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  was_active=1
  systemctl stop "${SERVICE_NAME}"
fi

install -m 0755 -o root -g root "${tmpdir}/xray" "${INSTALL_DIR}/xray.new"
mv -f "${INSTALL_DIR}/xray" "${INSTALL_DIR}/xray.previous"
mv -f "${INSTALL_DIR}/xray.new" "${INSTALL_DIR}/xray"

if (( was_active )); then
  systemctl start "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
    mv -f "${INSTALL_DIR}/xray.previous" "${INSTALL_DIR}/xray"
    systemctl start "${SERVICE_NAME}" || true
    die "新版本启动失败，已回滚旧版本"
  fi
fi

rm -f "${INSTALL_DIR}/xray.previous"
echo "更新完成：$("${INSTALL_DIR}/xray" version | head -n1)"
