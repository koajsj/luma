#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/backup-crypto.sh"
require_install
lock_operation
require_no_incomplete_restore
ensure_backup_key
if [[ ${1:-} == migrate ]]; then
    legacy=${2:-}
    [[ -n $legacy && ! -L $legacy ]] || die '用法：luma backup migrate /opt/luma/backups/旧备份目录'
    legacy=$(realpath "$legacy")
    [[ $legacy == "$BACKUP_DIR/"* && -d $legacy && ! -e $legacy/FORMAT ]] ||
        die '只能转换 backups 内的旧版明文备份。'
    python3 "$APP_DIR/deploy/backup-format.py" verify-legacy "$legacy" || die '旧备份完整性校验失败。'
    compose exec -T postgres pg_restore -l < "$legacy/postgres.dump" >/dev/null || die '旧数据库归档损坏。'
    python3 "$APP_DIR/deploy/backup-format.py" verify-storage < "$legacy/storage.tar.gz" >/dev/null ||
        die '旧密文目录归档损坏。'
    complete="$legacy.encrypted"
    target="$complete.partial"
    [[ ! -e $complete && ! -e $target ]] || die '转换目标已存在；不会覆盖。'
    mkdir -m 0700 "$target"
    trap 'rm -rf "$target"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    backup_encrypt_stream "$target/postgres.dump.age" < "$legacy/postgres.dump"
    backup_encrypt_stream "$target/storage.tar.gz.age" < "$legacy/storage.tar.gz"
    cp "$legacy/VERSION" "$legacy/KEY_ID" "$target/"
    printf '2\n' > "$target/FORMAT"
    backup_key_id > "$target/BACKUP_KEY_ID"
    backup_create_manifest "$target"
    backup_identity_args "$(cat "$target/BACKUP_KEY_ID")"
    backup_validate_manifest "$target" || die '转换后的加密备份校验失败。'
    chmod 600 "$target"/*
    mv "$target" "$complete"
    printf '加密副本已生成：%s；原旧备份保持不变，请核对后另行安全处置。\n' "$complete"
    exit 0
fi
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
compose exec -T postgres pg_dump -U luma -d luma -Fc | backup_encrypt_stream "$target/postgres.dump.age"
root tar -C /opt/luma/data --exclude='storage/ciphertext/.upload-*' -czf - storage |
    backup_encrypt_stream "$target/storage.tar.gz.age"
git -C "$APP_DIR" rev-parse HEAD > "$target/VERSION"
printf '%s' "$(env_value LUMA_USERID_HMAC_SECRET)" | sha256sum | awk '{print $1}' > "$target/KEY_ID"
printf '2\n' > "$target/FORMAT"
backup_key_id > "$target/BACKUP_KEY_ID"
backup_create_manifest "$target"
backup_identity_args "$(cat "$target/BACKUP_KEY_ID")"
backup_validate_manifest "$target" || die '备份认证校验失败。'
backup_decrypt "$target/postgres.dump.age" | compose exec -T postgres pg_restore -l >/dev/null || die '数据库备份验证失败。'
backup_decrypt "$target/storage.tar.gz.age" |
    python3 "$APP_DIR/deploy/backup-format.py" verify-storage >/dev/null || die '密文目录备份验证失败。'
chmod 600 "$target"/*
mv "$target" "$complete"
compose up -d --wait >/dev/null
health >/dev/null || die '备份后服务健康检查失败。'
services_stopped=0
printf '备份完成：%s\n' "$complete"
printf '数据库和密文目录已加密并认证；备份不包含私钥或 .env。跨服务器恢复需另行保管恢复私钥和原 UserID HMAC 密钥。\n'
