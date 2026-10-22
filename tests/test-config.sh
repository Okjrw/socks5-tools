#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"

if [[ -z ${XRAY_BIN:-} ]]; then
  echo "用法：XRAY_BIN=/path/to/xray ./tests/test-config.sh" >&2
  exit 1
fi
[[ -x ${XRAY_BIN} ]] || {
  echo "XRAY_BIN 不可执行：${XRAY_BIN}" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

awk '
  /^CIDR_JSON=""$/ { capture=1 }
  capture { print }
  capture && /^EOF$/ { exit }
' "${INSTALL_SCRIPT}" > "${tmpdir}/generate-config.sh"

run_case() {
  local name="$1"
  local expected_final="$2"
  shift 2

  local case_dir="${tmpdir}/${name}"
  mkdir -p "${case_dir}"

  (
    set -Eeuo pipefail
    tmpdir="${case_dir}"
    LISTEN_ADDR="0.0.0.0"
    PORT="23456"
    LOGIN="s5-test"
    PASSWORD="0123456789abcdef0123456789abcdef"
    ENABLE_UDP=0
    UDP_JSON="false"
    ALLOW_LIST=("$@")
    # shellcheck disable=SC1091
    source "${tmpdir}/../generate-config.sh"

    [[ $(grep -c '"final":' "${case_dir}/config.json") -eq 1 ]]
    grep -q "\"final\": \"${expected_final}\"" "${case_dir}/config.json"
    "${XRAY_BIN}" run -test -config "${case_dir}/config.json" >/dev/null
  )

  echo "${name}: OK"
}

run_case open direct
run_case allow blocked 203.0.113.10/32 2001:db8::/48
