#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_install
require_clean_main
lock_operation
old=$(git -C "$APP_DIR" rev-parse HEAD)
bash "$APP_DIR/deploy/backup.sh"
backup=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -print | sort | tail -1)
[[ -n "$backup" && $(cat "$backup/VERSION") == "$old" ]] || die '更新前备份未完成。'
git -C "$APP_DIR" fetch origin main
new=$(git -C "$APP_DIR" rev-parse FETCH_HEAD)
if [[ $new == "$old" ]]; then printf '已是最新版本：%s\n' "$old"; exit 0; fi
git -C "$APP_DIR" merge --ff-only "$new"
if compose config --quiet && compose up -d --build --wait && health >/dev/null; then
    root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
    printf '更新完成：%s → %s\n' "$old" "$new"
    exit 0
fi
printf '新版本未通过健康检查，正在恢复代码、数据库与密文文件。\n' >&2
git -C "$APP_DIR" reset --hard "$old"
LUMA_RESTORE_CONFIRMED=1 bash "$APP_DIR/deploy/restore.sh" "$backup" ||
    die "自动恢复失败，服务已停止或状态未知。请保留备份 $backup 并人工排查。"
die "更新失败，已恢复到 $old。"
