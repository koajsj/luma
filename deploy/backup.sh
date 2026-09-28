#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_install
lock_operation
[[ -d "$STORAGE_DIR" ]] || die '密文目录不存在。'
stamp=$(date -u +%Y%m%dT%H%M%SZ)
target="$BACKUP_DIR/$stamp.partial"
complete="$BACKUP_DIR/$stamp"
[[ ! -e "$target" && ! -e "$complete" ]] || die '本秒已有备份，请稍后重试。'
mkdir -m 0700 "$target"
services_stopped=0
backup_cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    if (( services_stopped )); then
        if compose up -d --wait >/dev/null && health >/dev/null; then
            printf '备份退出前已恢复服务。\n' >&2
        else
            printf '备份退出时服务恢复或健康检查失败，请立即检查 luma status。\n' >&2
            result=1
        fi
    fi
    if (( result != 0 )); then root rm -rf "$target"; fi
    exit "$result"
}
trap backup_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
services_stopped=1
compose stop backend caddy
compose exec -T postgres pg_dump -U luma -d luma -Fc > "$target/postgres.dump"
root tar -C /opt/luma/data --exclude='storage/ciphertext/.upload-*' -czf "$target/storage.tar.gz" storage
root chown "$(id -u):$(id -g)" "$target/storage.tar.gz"
git -C "$APP_DIR" rev-parse HEAD > "$target/VERSION"
printf '%s' "$(env_value LUMA_USERID_HMAC_SECRET)" | sha256sum | awk '{print $1}' > "$target/KEY_ID"
(cd "$target" && sha256sum postgres.dump storage.tar.gz VERSION KEY_ID > SHA256SUMS)
chmod 600 "$target"/*
mv "$target" "$complete"
compose up -d --wait >/dev/null
health >/dev/null || die '备份后服务健康检查失败。'
services_stopped=0
printf '备份完成：%s\n' "$complete"
printf '包含数据库、密文文件、代码版本与校验；不包含私有 .env。迁移服务器还需安全转移原 .env。\n'
