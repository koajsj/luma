#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
require_install
require_clean_main
lock_operation
current=$(git -C "$APP_DIR" rev-parse HEAD)
backup=${1:-}
if [[ -z "$backup" ]]; then
    while IFS= read -r candidate; do
        if [[ -f "$candidate/VERSION" && $(cat "$candidate/VERSION") != "$current" ]]; then backup=$candidate; break; fi
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -print | sort -r)
fi
[[ -n "$backup" ]] || die '没有可用的旧版本备份。'
backup=$(realpath "$backup")
[[ $backup == "$BACKUP_DIR/"* && -f "$backup/VERSION" ]] || die '备份路径无效。'
old=$(cat "$backup/VERSION")
git -C "$APP_DIR" cat-file -e "$old^{commit}" || die '本地仓库缺少备份版本的代码。'
if [[ ${LUMA_ROLLBACK_CONFIRMED:-} != 1 ]]; then
    ( : </dev/tty ) 2>/dev/null || die '回滚会替换数据库，需要交互确认。'
    printf '回滚到 %s 将覆盖当前数据。输入 ROLLBACK 确认：' "$old" > /dev/tty
    read -r answer < /dev/tty
    [[ $answer == ROLLBACK ]] || die '已取消回滚。'
fi
printf '将回滚到 %s。先创建当前版本的安全备份。\n' "$old"
bash "$APP_DIR/deploy/backup.sh"
LUMA_RESTORE_CONFIRMED=1 bash "$APP_DIR/deploy/restore.sh" "$backup" ||
    die "回滚恢复失败；请检查服务状态及回滚前备份。目标备份保留在 $backup。"
root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
printf '回滚完成：%s → %s\n' "$current" "$old"
