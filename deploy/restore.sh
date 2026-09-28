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
stage=$(mktemp -d /opt/luma/data/.restore.XXXXXX)
trap 'root rm -rf "$stage"' EXIT
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
[[ -d "$stage/storage" ]] || die '备份中缺少 storage 目录。'
[[ ! -e /opt/luma/data/.storage-before-restore ]] || die '上次恢复残留旧文件目录，请先人工检查。'
config_previous=''
if [[ -n ${2:-} ]]; then
    config_previous=$(mktemp /opt/luma/config/.env.pre-restore.XXXXXX)
    cp "$ENV_FILE" "$config_previous"
    config_tmp=$(mktemp /opt/luma/config/.env.restore.XXXXXX)
    grep -v '^LUMA_USERID_HMAC_SECRET=' "$ENV_FILE" > "$config_tmp"
    printf 'LUMA_USERID_HMAC_SECRET=%s\n' "$key" >> "$config_tmp"
    chmod 600 "$config_tmp"
    mv "$config_tmp" "$ENV_FILE"
    trap 'printf "恢复中断；原配置保留在 %s。\n" "$config_previous" >&2; root rm -rf "$stage"' EXIT
fi
if [[ $version != "$current" ]]; then git -C "$APP_DIR" reset --hard "$version"; fi
compose stop backend caddy
compose exec -T postgres dropdb -U luma --if-exists luma
compose exec -T postgres createdb -U luma -O luma luma
compose exec -T postgres pg_restore -U luma -d luma --no-owner < "$backup/postgres.dump"
root mv "$STORAGE_DIR" "/opt/luma/data/.storage-before-restore"
root mv "$stage/storage" "$STORAGE_DIR"
root chown -R 10001:10001 "$STORAGE_DIR"
compose up -d --build --wait
health >/dev/null || die '恢复后的服务健康检查失败。旧密文目录仍在 /opt/luma/data/.storage-before-restore。'
root rm -rf /opt/luma/data/.storage-before-restore
root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
if [[ -n "$config_previous" ]]; then rm -f "$config_previous"; fi
trap 'root rm -rf "$stage"' EXIT
printf '恢复完成：%s\n' "$backup"
