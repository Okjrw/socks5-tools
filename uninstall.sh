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

ASSUME_YES=0

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：sudo ./uninstall.sh [--yes]

  --yes    不交互确认，直接卸载

脚本会先备份配置到 /var/backups/xray-socks5，再停止并删除服务。
防火墙和云安全组规则不会被自动修改。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行"

if (( !ASSUME_YES )); then
  read -r -p "确认卸载 ${SERVICE_NAME}？[y/N] " answer
  [[ ${answer} == "y" || ${answer} == "Y" ]] || exit 0
fi

if [[ -e ${CONFIG_FILE} || -e ${UNIT_FILE} || -e ${INSTALL_DIR} ]]; then
  install -d -m 0700 -o root -g root "${BACKUP_DIR}"
  stamp="$(date +%Y%m%d-%H%M%S)"
  [[ -e ${CONFIG_FILE} ]] && cp -a "${CONFIG_FILE}" "${BACKUP_DIR}/config.json.uninstall.${stamp}"
  [[ -e ${UNIT_FILE} ]] && cp -a "${UNIT_FILE}" "${BACKUP_DIR}/${SERVICE_NAME}.service.uninstall.${stamp}"
fi

systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -f "${UNIT_FILE}"
systemctl daemon-reload >/dev/null 2>&1 || true

rm -rf -- "${INSTALL_DIR}" "${CONFIG_DIR}"

if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  userdel "${SERVICE_USER}" >/dev/null 2>&1 || true
fi
if getent group "${SERVICE_USER}" >/dev/null 2>&1; then
  groupdel "${SERVICE_USER}" >/dev/null 2>&1 || true
fi

echo "已卸载 ${SERVICE_NAME}。"
echo "配置备份位于 ${BACKUP_DIR}。"
echo "防火墙和云安全组规则未修改，如需关闭端口请手动删除对应规则。"
