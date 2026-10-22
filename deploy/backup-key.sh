#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/backup-crypto.sh"
require_install
lock_operation
require_no_incomplete_restore
require_age
if [[ -f "$BACKUP_KEY_DIR/current" ]]; then
    backup_key_id >/dev/null
elif [[ -d "$BACKUP_KEY_DIR" ]] && compgen -G "$BACKUP_KEY_DIR/*.key" >/dev/null; then
    die '旧备份私钥仍存在，但当前密钥指针缺失；拒绝轮换。'
fi
new=$(create_backup_key)
printf '当前备份密钥已更新：%s。旧私钥仍保留，以便恢复旧备份；请在服务器外安全保存恢复私钥。\n' "$new"
