#!/usr/bin/env bash
APP_DIR=/opt/luma/app
ENV_FILE=/opt/luma/config/.env
COMPOSE_FILE="$APP_DIR/deploy/docker-compose.yml"
BACKUP_DIR=/opt/luma/backups
STORAGE_DIR=/opt/luma/data/storage
if [[ $(id -u) == 0 ]]; then SUDO=(); else SUDO=(sudo); fi
die() { printf 'Luma：%s\n' "$*" >&2; exit 1; }
root() { "${SUDO[@]}" "$@"; }
compose() { root docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
require_install() {
    [[ -f "$ENV_FILE" && -d "$APP_DIR/.git" && -f "$COMPOSE_FILE" ]] || die '未找到完整安装；请先运行 install.sh。'
    [[ $(stat -c %a "$ENV_FILE") == 600 ]] || die '私有配置权限必须为 600。'
}
require_clean_main() {
    [[ $(git -C "$APP_DIR" branch --show-current) == main ]] || die '服务器仓库必须位于 main 分支。'
    [[ -z $(git -C "$APP_DIR" status --porcelain) ]] || die '服务器仓库有本地改动；为防止覆盖，操作已停止。'
}
lock_operation() {
    [[ ${LUMA_LOCK_HELD:-} == 1 ]] && return
    command -v flock >/dev/null || die '缺少 flock。'
    exec 9>/opt/luma/config/operation.lock
    flock -n 9 || die '另一项部署或数据操作正在运行。'
    export LUMA_LOCK_HELD=1
}
health() {
    local mode domain
    mode=$(env_value LUMA_MODE)
    domain=$(env_value LUMA_DOMAIN)
    if [[ $mode == domain ]]; then
        curl --retry 12 --retry-delay 5 --retry-connrefused -fsS --max-time 10 "https://$domain/health"
    else
        curl --retry 12 --retry-delay 5 --retry-connrefused -fsS --max-time 10 http://127.0.0.1/health
    fi
}
show_address() {
    if [[ $(env_value LUMA_MODE) == domain ]]; then
        printf 'https://%s' "$(env_value LUMA_DOMAIN)"
    else
        printf 'http://%s' "$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    fi
}
