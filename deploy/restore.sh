#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/backup-crypto.sh"
require_install
lock_operation

state=/opt/luma/config/restore-state
old_storage=/opt/luma/data/.storage-before-restore
stage=''
state_tmp=''
config_tmp=''
services_stopped=0

cleanup_committed() {
    local staged
    staged=$(cat "$state/stage")
    [[ $staged =~ ^/opt/luma/data/\.restore\.[A-Za-z0-9]{6}$ ]] || return 1
    root rm -rf "$old_storage" || return 1
    root rm -rf "$staged" || return 1
    rm -rf "$state"
}

# A durable marker is written before any database or storage mutation. This
# operation can be retried after INT/TERM or a host restart.
recover_previous() {
    local saved_current staged
    [[ -d $state && ! -L $state ]] || return 1
    if [[ -f $state/committed ]]; then
        cleanup_committed
        return
    fi
    saved_current=$(cat "$state/current")
    staged=$(cat "$state/stage")
    [[ $saved_current =~ ^[0-9a-f]{40}$ &&
       $staged =~ ^/opt/luma/data/\.restore\.[A-Za-z0-9]{6}$ &&
       -f $state/previous-env && ! -L $state/previous-env ]] || return 1
    compose stop backend caddy || return 1
    cp "$state/previous-env" "$ENV_FILE" && chmod 600 "$ENV_FILE" || return 1
    if [[ $(git -C "$APP_DIR" rev-parse HEAD) != "$saved_current" ]]; then
        [[ -z $(git -C "$APP_DIR" status --porcelain) ]] || return 1
        git -C "$APP_DIR" reset --hard "$saved_current" || return 1
    fi
    if [[ -f $state/db-mutating ]]; then
        [[ -f $state/snapshot-complete && -f $state/previous-db.age &&
           -f $state/previous-db-key-id ]] || return 1
        backup_identity_args "$(cat "$state/previous-db-key-id")"
        compose up -d postgres --wait || return 1
        backup_decrypt "$state/previous-db.age" |
            compose exec -T postgres pg_restore -l >/dev/null || return 1
        compose exec -T postgres dropdb -U luma --if-exists luma || return 1
        compose exec -T postgres createdb -U luma -O luma luma || return 1
        backup_decrypt "$state/previous-db.age" |
            compose exec -T postgres pg_restore -U luma -d luma --no-owner --no-acl || return 1
    fi
    if [[ -f $state/storage-mutating ]]; then
        if root test -d "$old_storage"; then
            if root test -e "$STORAGE_DIR"; then
                root test ! -e "$staged/failed-storage" || return 1
                root mv "$STORAGE_DIR" "$staged/failed-storage" || return 1
            fi
            root mv "$old_storage" "$STORAGE_DIR" || return 1
        else
            root test -d "$STORAGE_DIR" || return 1
        fi
    fi
    compose up -d --build --wait && health >/dev/null || return 1
    root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma || return 1
    root rm -rf "$staged" || return 1
    rm -rf "$state"
}

if [[ ${1:-} == recover ]]; then
    [[ -d $state ]] || die '没有未完成的恢复操作。'
    if recover_previous; then
        printf '旧配置、代码、数据库和密文目录已恢复并通过就绪检查。\n'
        exit 0
    fi
    compose stop backend caddy || true
    die '自动补偿失败；对外服务已停止。保留恢复状态、原数据库加密快照和旧文件目录，请人工排查。'
fi
[[ ! -e $state ]] || die '存在未完成恢复；先运行 luma restore recover，不会覆盖残留数据。'
[[ ! -e $old_storage ]] || die '存在没有恢复日志的旧密文目录；停止操作并人工核查，不会覆盖残留数据。'
backup=${1:-}
[[ -n $backup ]] || die '用法：luma restore /opt/luma/backups/时间戳 [旧服务器 .env] [离线恢复私钥]；中断后运行 luma restore recover'
[[ ! -L $backup ]] || die '备份目录不能是符号链接。'
backup=$(realpath "$backup")
[[ $backup == "$BACKUP_DIR/"* && -d $backup && ! -L $backup ]] ||
    die '只能恢复 /opt/luma/backups 内的备份目录。'
for name in VERSION KEY_ID; do
    [[ -f $backup/$name && ! -L $backup/$name ]] || die "备份缺少 $name。"
done
require_age
format=legacy
if [[ -e $backup/FORMAT ]]; then
    [[ -f $backup/FORMAT && ! -L $backup/FORMAT && $(cat "$backup/FORMAT") == 2 ]] ||
        die '不支持的备份格式。'
    format=2
    for name in BACKUP_KEY_ID postgres.dump.age storage.tar.gz.age MANIFEST.age; do
        [[ -f $backup/$name && ! -L $backup/$name ]] || die "备份缺少 $name。"
    done
    backup_identity_args "$(cat "$backup/BACKUP_KEY_ID")" "${3:-}"
    backup_validate_manifest "$backup" || die '备份认证或完整性校验失败。'
else
    for name in postgres.dump storage.tar.gz SHA256SUMS; do
        [[ -f $backup/$name && ! -L $backup/$name ]] || die "旧备份缺少 $name。"
    done
    python3 "$APP_DIR/deploy/backup-format.py" verify-legacy "$backup" ||
        die '旧备份完整性校验失败。'
    printf '警告：这是未加密的旧备份；SHA-256 清单不提供来源认证，请仅从可信备份恢复。\n' >&2
fi
backup_data() {
    if [[ $format == 2 ]]; then backup_decrypt "$backup/$1.age"; else cat "$backup/$1"; fi
}
backup_data postgres.dump | compose exec -T postgres pg_restore -l >/dev/null ||
    die '数据库归档损坏或解密失败。'
storage_bytes=$(backup_data storage.tar.gz |
    python3 "$APP_DIR/deploy/backup-format.py" verify-storage) ||
    die '密文目录归档损坏、解密失败或包含不安全路径。'
key=$(env_value LUMA_USERID_HMAC_SECRET)
if [[ -n ${2:-} ]]; then
    [[ -f $2 && ! -L $2 && $(stat -c %a "$2") == 600 ]] ||
        die '旧 .env 必须是权限为 600 的普通文件。'
    key=$(sed -n 's/^LUMA_USERID_HMAC_SECRET=//p' "$2" | head -1)
fi
[[ $key =~ ^[0-9a-fA-F]{64}$ ]] || die 'UserID HMAC 密钥无效。'
key_id=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
[[ $key_id == "$(cat "$backup/KEY_ID")" ]] || die 'UserID HMAC 密钥与备份不匹配。'
version=$(cat "$backup/VERSION")
[[ $version =~ ^[0-9a-f]{40}$ ]] || die '备份代码版本无效。'
current=$(git -C "$APP_DIR" rev-parse HEAD)
if [[ $version != "$current" ]]; then
    require_clean_main
    git -C "$APP_DIR" cat-file -e "$version^{commit}" || die '本地仓库缺少备份对应代码。'
    git -C "$APP_DIR" merge-base --is-ancestor "$version" "$current" ||
        die '备份代码不是当前 main 的祖先版本。'
fi
[[ $(env_value LUMA_STORAGE_DIR) == "$STORAGE_DIR" && -d $STORAGE_DIR ]] ||
    die '配置与密文目录不一致。'

# The extracted storage coexists with the old directory until the new service
# passes readiness. Reserve room for extraction, database restore and WAL.
db_bytes=$(compose exec -T postgres psql -U luma -d luma -Atc "SELECT pg_database_size('luma')")
data_free=$(df -PB1 /opt/luma/data | awk 'NR==2 {print $4}')
config_free=$(df -PB1 /opt/luma/config | awk 'NR==2 {print $4}')
data_device=$(stat -c %d /opt/luma/data)
config_device=$(stat -c %d /opt/luma/config)
if [[ $format == 2 ]]; then db_archive=$backup/postgres.dump.age; else db_archive=$backup/postgres.dump; fi
archive_bytes=$(stat -c %s "$db_archive")
python3 - "$storage_bytes" "$db_bytes" "$archive_bytes" "$data_free" "$config_free" "$data_device" "$config_device" <<'PY' ||
    die '可用磁盘空间不足，恢复未开始。'
import sys
storage, database, archive, data_free, config_free = map(int, sys.argv[1:6])
reserve = 512 * 1024 * 1024
database_room = 2 * max(database, archive)
snapshot_room = max(database, archive)
same_device = sys.argv[6] == sys.argv[7]
if (min(storage, database, archive, data_free, config_free) < 0
        or data_free < storage + database_room + reserve + (snapshot_room if same_device else 0)
        or config_free < snapshot_room + reserve):
    raise SystemExit(1)
PY
if [[ ${LUMA_RESTORE_CONFIRMED:-} != 1 ]]; then
    ( : </dev/tty ) 2>/dev/null || die '恢复会替换数据库和密文目录，需交互确认。'
    if [[ $format == legacy ]]; then expected='RESTORE LEGACY'; else expected=RESTORE; fi
    printf '将替换当前数据库和密文文件。输入 %s 确认：' "$expected" > /dev/tty
    read -r answer < /dev/tty
    [[ $answer == "$expected" ]] || die '已取消恢复。'
fi
ensure_backup_key
stage=$(root mktemp -d /opt/luma/data/.restore.XXXXXX)
root test -d "$stage" || die '无法创建恢复暂存目录。'
config_tmp=''
services_stopped=0
restore_cleanup() {
    local result=$? recovered=0
    trap - EXIT INT TERM
    if [[ -n $config_tmp ]]; then rm -f "$config_tmp" || printf '临时配置清理失败：%s\n' "$config_tmp" >&2; fi
    if [[ -n $state_tmp ]]; then rm -rf "$state_tmp" || printf '临时恢复日志清理失败：%s\n' "$state_tmp" >&2; fi
    if (( result != 0 )); then
        set +e
        if [[ -d $state ]]; then
            recover_previous && recovered=1
        elif (( services_stopped )); then
            compose up -d --wait && health >/dev/null && recovered=1
        else
            recovered=1
        fi
        if (( recovered )); then
            [[ -z $stage ]] || root rm -rf "$stage"
            printf '恢复未完成，原服务已恢复或尚未改变。\n' >&2
        else
            compose stop backend caddy || true
            printf '补偿失败：对外服务已停止，恢复状态与原数据保留。运行 luma restore recover 或人工检查。\n' >&2
        fi
    fi
    exit "$result"
}
trap restore_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
backup_data storage.tar.gz |
    root tar -C "$stage" --no-same-owner --no-same-permissions -xzf -
root test -d "$stage/storage" || die '备份中缺少 storage 目录。'
root find "$stage/storage" -type d -exec chmod 700 {} +
root find "$stage/storage" -type f -exec chmod 600 {} +

state_tmp=$(mktemp -d /opt/luma/config/.restore-state.XXXXXX)
cp "$ENV_FILE" "$state_tmp/previous-env"
cp "$APP_DIR/deploy/restore.sh" "$APP_DIR/deploy/lib.sh" \
    "$APP_DIR/deploy/backup-crypto.sh" "$state_tmp/"
printf '%s\n' "$current" > "$state_tmp/current"
printf '%s\n' "$stage" > "$state_tmp/stage"
backup_key_id > "$state_tmp/previous-db-key-id"
chmod 600 "$state_tmp"/*
mv "$state_tmp" "$state"
state_tmp=''
services_stopped=1
compose stop backend caddy
compose exec -T postgres pg_dump -U luma -d luma -Fc |
    backup_encrypt_stream "$state/previous-db.age"
backup_identity_args "$(cat "$state/previous-db-key-id")"
backup_decrypt "$state/previous-db.age" |
    compose exec -T postgres pg_restore -l >/dev/null || die '原数据库快照验证失败。'
: > "$state/snapshot-complete"

if [[ -n ${2:-} ]]; then
    config_tmp=$(mktemp /opt/luma/config/.env.restore.XXXXXX)
    grep -v '^LUMA_USERID_HMAC_SECRET=' "$ENV_FILE" > "$config_tmp"
    printf 'LUMA_USERID_HMAC_SECRET=%s\n' "$key" >> "$config_tmp"
    chmod 600 "$config_tmp"
    mv "$config_tmp" "$ENV_FILE"
    config_tmp=''
fi
if [[ $version != "$current" ]]; then git -C "$APP_DIR" reset --hard "$version"; fi
: > "$state/db-mutating"
compose exec -T postgres dropdb -U luma --if-exists luma
compose exec -T postgres createdb -U luma -O luma luma
# Restore with the backup identity, not the key used for the compensation snapshot.
if [[ $format == 2 ]]; then backup_identity_args "$(cat "$backup/BACKUP_KEY_ID")" "${3:-}"; fi
backup_data postgres.dump |
    compose exec -T postgres pg_restore -U luma -d luma --no-owner --no-acl
: > "$state/storage-mutating"
root mv "$STORAGE_DIR" "$old_storage"
root mv "$stage/storage" "$STORAGE_DIR"
root chown -R 10001:10001 "$STORAGE_DIR"
compose up -d --build --wait
health >/dev/null || die '恢复后的服务就绪检查失败。'
root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
: > "$state/committed"
cleanup_committed || die '数据已恢复且服务就绪，但旧文件清理未完成；运行 luma restore recover。'
printf '恢复完成：%s\n' "$backup"
