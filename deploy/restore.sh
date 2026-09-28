#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_install
lock_operation
backup=${1:-}
[[ -n "$backup" ]] || die '用法：luma restore /opt/luma/backups/时间戳 [旧服务器的 .env 文件]'
backup=$(realpath "$backup")
[[ $backup == "$BACKUP_DIR/"* && -d "$backup" ]] || die '只能恢复 /opt/luma/backups 内的备份目录。'
for f in postgres.dump storage.tar.gz VERSION KEY_ID SHA256SUMS; do [[ -f "$backup/$f" ]] || die "备份缺少 $f。"; done
(cd "$backup" && sha256sum -c --quiet SHA256SUMS) || die '备份完整性校验失败。'
key=$(env_value LUMA_USERID_HMAC_SECRET)
if [[ -n ${2:-} ]]; then
    [[ -f "$2" && $(stat -c %a "$2") == 600 ]] || die '旧 .env 必须存在且权限为 600。'
    key=$(sed -n 's/^LUMA_USERID_HMAC_SECRET=//p' "$2" | head -1)
fi
[[ $key =~ ^[0-9a-fA-F]{64}$ ]] || die 'UserID HMAC 密钥无效。'
key_id=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
[[ $key_id == "$(cat "$backup/KEY_ID")" ]] || die 'UserID HMAC 密钥与备份不匹配；拒绝恢复。'
version=$(cat "$backup/VERSION")
[[ $version =~ ^[0-9a-f]{40}$ ]] || die '备份版本无效。'
current=$(git -C "$APP_DIR" rev-parse HEAD)
if [[ $version != "$current" ]]; then
    require_clean_main
    git -C "$APP_DIR" cat-file -e "$version^{commit}" || die '本地仓库缺少备份对应代码。'
    git -C "$APP_DIR" merge-base --is-ancestor "$version" "$current" ||
        die '备份代码不是当前 main 的祖先版本；拒绝跨版本恢复。'
fi
[[ $(env_value LUMA_STORAGE_DIR) == "$STORAGE_DIR" ]] || die '私有配置与存储路径不一致。'
if [[ ${LUMA_RESTORE_CONFIRMED:-} != 1 ]]; then
    ( : </dev/tty ) 2>/dev/null || die '恢复会替换数据库和密文目录，需交互确认。'
    printf '将替换当前数据库和密文文件。输入 RESTORE 确认：' > /dev/tty
    read -r answer < /dev/tty
    [[ $answer == RESTORE ]] || die '已取消恢复。'
fi
stage=$(root mktemp -d /opt/luma/data/.restore.XXXXXX)
config_previous=''
config_tmp=''
previous_db=''
services_stopped=0
db_changed=0
storage_changed=0
config_swapped=0
restore_cleanup() {
    local result=$? recovery_failed=0
    trap - EXIT
    if (( result != 0 )); then
        set +e
        if (( config_swapped )); then
            cp "$config_previous" "$ENV_FILE" && chmod 600 "$ENV_FILE" || recovery_failed=1
        fi
        if [[ $version != "$current" ]]; then
            git -C "$APP_DIR" reset --hard "$current" || recovery_failed=1
        fi
        if (( db_changed )) && [[ -n $previous_db ]]; then
            compose exec -T postgres dropdb -U luma --if-exists luma &&
                compose exec -T postgres createdb -U luma -O luma luma &&
                compose exec -T postgres pg_restore -U luma -d luma --no-owner < "$previous_db" || recovery_failed=1
        fi
        if (( storage_changed )) && root test -d /opt/luma/data/.storage-before-restore; then
            root rm -rf "$STORAGE_DIR" &&
                root mv /opt/luma/data/.storage-before-restore "$STORAGE_DIR" || recovery_failed=1
        fi
        if (( services_stopped && recovery_failed == 0 )); then
            compose up -d --build --wait && health >/dev/null || recovery_failed=1
        fi
        if (( recovery_failed )); then
            compose stop backend caddy || true
            printf '恢复补偿失败，已停止对外服务；请检查数据库、密文目录和备份。\n' >&2
            [[ -z $previous_db ]] || printf '原数据库临时快照保留在 %s。\n' "$previous_db" >&2
            [[ -z $config_previous ]] || printf '原配置副本保留在 %s。\n' "$config_previous" >&2
        else
            printf '恢复失败；旧配置、代码、数据库和密文目录已恢复。\n' >&2
        fi
    fi
    root rm -rf "$stage"
    [[ -z $config_tmp ]] || rm -f "$config_tmp"
    if (( recovery_failed == 0 )); then
        [[ -z $config_previous ]] || rm -f "$config_previous"
        [[ -z $previous_db ]] || rm -f "$previous_db"
    fi
    exit "$result"
}
trap restore_cleanup EXIT
python3 - "$backup/storage.tar.gz" <<'PY'
import re
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    for item in archive:
        name = item.name.rstrip("/")
        directory = name in {"storage", "storage/ciphertext"}
        ciphertext = bool(re.fullmatch(r"storage/ciphertext/[0-9a-f-]{36}", name))
        if not ((directory and item.isdir()) or (ciphertext and item.isfile())):
            raise SystemExit("备份包含不安全的文件路径或类型")
PY
root tar -C "$stage" --no-same-owner --no-same-permissions -xzf "$backup/storage.tar.gz"
root test -d "$stage/storage" || die '备份中缺少 storage 目录。'
root test ! -e /opt/luma/data/.storage-before-restore || die '上次恢复残留旧文件目录，请先人工检查。'
if [[ -n ${2:-} ]]; then
    config_previous=$(mktemp /opt/luma/config/.env.pre-restore.XXXXXX)
    cp "$ENV_FILE" "$config_previous"
    config_tmp=$(mktemp /opt/luma/config/.env.restore.XXXXXX)
    grep -v '^LUMA_USERID_HMAC_SECRET=' "$ENV_FILE" > "$config_tmp"
    printf 'LUMA_USERID_HMAC_SECRET=%s\n' "$key" >> "$config_tmp"
    chmod 600 "$config_tmp"
    config_swapped=1
    mv "$config_tmp" "$ENV_FILE"
fi
if [[ $version != "$current" ]]; then git -C "$APP_DIR" reset --hard "$version"; fi
services_stopped=1
compose stop backend caddy
previous_db=$(mktemp "$BACKUP_DIR"/.restore-db.XXXXXX)
compose exec -T postgres pg_dump -U luma -d luma -Fc > "$previous_db"
db_changed=1
compose exec -T postgres dropdb -U luma --if-exists luma
compose exec -T postgres createdb -U luma -O luma luma
compose exec -T postgres pg_restore -U luma -d luma --no-owner < "$backup/postgres.dump"
storage_changed=1
root mv "$STORAGE_DIR" "/opt/luma/data/.storage-before-restore"
root mv "$stage/storage" "$STORAGE_DIR"
root chown -R 10001:10001 "$STORAGE_DIR"
compose up -d --build --wait
health >/dev/null || die '恢复后的服务健康检查失败。'
root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
printf '恢复完成：%s\n' "$backup"
root rm -rf /opt/luma/data/.storage-before-restore ||
    printf '旧密文目录清理失败，请检查 /opt/luma/data/.storage-before-restore。\n' >&2
