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
swapped=0
committed=0
domain_cleanup() {
    local result=$? recovery_failed=0
    trap - EXIT INT TERM
    set +e
    if (( swapped && ! committed )); then
        if cp "$old" "$ENV_FILE" && chmod 600 "$ENV_FILE" &&
           compose config --quiet && compose up -d --wait && health >/dev/null; then
            printf '新域名未生效；旧配置与服务已恢复并通过健康检查。\n' >&2
        else
            compose stop backend caddy || true
            printf '旧配置或服务恢复失败；已停止对外服务。原配置副本保留在 %s，请检查 luma status 和 Caddy 日志。\n' "$old" >&2
            recovery_failed=1
            result=1
        fi
    fi
    if (( ! recovery_failed )); then rm -f "$old"; fi
    rm -f "$tmp"
    exit "$result"
}
trap domain_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$ENV_FILE" "$old"
grep -vE '^LUMA_(MODE|DOMAIN|SITE)=' "$old" > "$tmp"
printf 'LUMA_MODE=domain\nLUMA_DOMAIN=%s\nLUMA_SITE=%s\n' "$domain" "$domain" >> "$tmp"
chmod 600 "$tmp"
swapped=1
mv "$tmp" "$ENV_FILE"
if compose config --quiet && compose up -d --wait && health >/dev/null; then
    committed=1
    printf '域名已更换：https://%s\n' "$domain"
else
    die '新域名启动或健康检查失败；正在恢复旧配置。请检查 DNS、80/443 和 Caddy 日志。'
fi
