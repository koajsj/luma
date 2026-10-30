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
resume_services() {
    compose up -d --no-deps --wait backend &&
        compose up -d --no-deps --wait caddy
}
start_services() {
    # Explicit runs are necessary after a restore even if Compose remembers a
    # previous successful one-shot container. Never start the API before grants.
    compose up -d --wait postgres redis &&
        compose run --rm --no-deps migrate &&
        compose run --rm --no-deps db-grants && resume_services
}
require_split_database_version() {
    local version=$1 definition
    definition=$(git -C "$APP_DIR" show "$version:deploy/docker-compose.yml") || return 1
    [[ $definition == *'LUMA_AUTO_MIGRATE: "false"'* && $definition == *'postgres://luma_api:'* ]] || {
        printf '目标版本不支持独立运行角色；拒绝恢复为管理员 API。请先在隔离环境准备兼容代码。\n' >&2
        return 1
    }
}
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
require_install() {
    [[ -f "$ENV_FILE" && -d "$APP_DIR/.git" && -f "$COMPOSE_FILE" ]] || die '未找到完整安装；请先运行 install.sh。'
    [[ $(stat -c %a "$ENV_FILE") == 600 ]] || die '私有配置权限必须为 600。'
}
require_no_incomplete_restore() {
    [[ ! -e /opt/luma/config/restore-state && ! -e /opt/luma/data/.storage-before-restore ]] ||
        die '存在未完成的恢复；先运行 luma restore recover，禁止继续备份或更新。'
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
        curl --retry 12 --retry-delay 5 --retry-connrefused --retry-all-errors -fsS --max-time 10 "https://$domain/ready"
    else
        curl --retry 12 --retry-delay 5 --retry-connrefused --retry-all-errors -fsS --max-time 10 http://127.0.0.1/ready
    fi
}
show_address() {
    if [[ $(env_value LUMA_MODE) == domain ]]; then
        printf 'https://%s' "$(env_value LUMA_DOMAIN)"
    else
        printf 'http://%s' "$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    fi
}
