#!/usr/bin/env bash
set -Eeuo pipefail

# 复制为 deploy.local.sh 后修改下面两项。
# deploy.local.sh 已加入 .gitignore，不要上传到公开仓库。
SOPT="3223"
UUID="CHANGE_ME_BEFORE_USE"
INSTALL_URL="https://raw.githubusercontent.com/OWNER/REPO/COMMIT/socks5-only/install.sh"

if [[ ${INSTALL_URL} == *"OWNER/REPO"* ]]; then
  echo "请先把 INSTALL_URL 改成你自己的固定 commit 地址" >&2
  exit 1
fi

if [[ ${UUID} == "CHANGE_ME_BEFORE_USE" ]]; then
  echo "请先把 UUID 改成你自己的强密码" >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  SCRIPT_PATH="$(readlink -f "$0")"
  exec sudo bash "${SCRIPT_PATH}" "$@"
fi

tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT

curl -fLsS --proto '=https' --tlsv1.2 "${INSTALL_URL}" -o "${tmpfile}"
sopt="${SOPT}" uuid="${UUID}" bash "${tmpfile}" "$@"
