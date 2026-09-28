#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_install
lock_operation
domain=${1:-}
if [[ -z "$domain" ]]; then
    ( : </dev/tty ) 2>/dev/null || die '请提供新域名。'
    printf '新域名：' > /dev/tty
    read -r domain < /dev/tty
fi
[[ $domain =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || die '域名格式不正确。'
old=$(mktemp /opt/luma/config/.env.previous.XXXXXX)
tmp=$(mktemp /opt/luma/config/.env.next.XXXXXX)
trap 'rm -f "$old" "$tmp"' EXIT
cp "$ENV_FILE" "$old"
grep -vE '^LUMA_(MODE|DOMAIN|SITE)=' "$old" > "$tmp"
printf 'LUMA_MODE=domain\nLUMA_DOMAIN=%s\nLUMA_SITE=%s\n' "$domain" "$domain" >> "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
if compose config --quiet && compose up -d --wait && health >/dev/null; then
    printf '域名已更换：https://%s\n' "$domain"
else
    cp "$old" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    compose up -d --wait || true
    die '新域名健康检查失败；已恢复原配置。请检查 DNS、80/443 和 Caddy 日志。'
fi
