#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'Luma 安装失败：%s\n' "$*" >&2; exit 1; }
[[ -f /etc/os-release ]] || fail '仅支持 Ubuntu 22.04/24.04。'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ]] || fail '仅支持 Ubuntu 22.04/24.04。'
if [[ $(id -u) == 0 ]]; then SUDO=(); else SUDO=(sudo); fi
root() { "${SUDO[@]}" "$@"; }
if [[ $(id -u) != 0 ]]; then
    command -v sudo >/dev/null || fail '需要 sudo 权限。'
    sudo -v || fail '当前账号没有 sudo 权限。'
fi
curl -fsSI --max-time 15 https://github.com >/dev/null || fail '无法连接 GitHub；请检查 VPS 网络。'
root apt-get update -qq
root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates openssl python3 >/dev/null
root install -d -m 0755 /opt/luma
root install -d -m 0755 -o "$(id -u)" -g "$(id -g)" /opt/luma/app
if [[ ! -d /opt/luma/app/.git ]]; then
    [[ -z $(ls -A /opt/luma/app) ]] || fail '/opt/luma/app 已有其他文件，请人工检查。'
    git clone --branch main --single-branch https://github.com/koajsj/luma.git /opt/luma/app
fi
exec bash /opt/luma/app/deploy/deploy.sh
