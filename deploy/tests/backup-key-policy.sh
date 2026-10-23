#!/usr/bin/env bash
# Targeted policy regression; no Docker, database, VPS or installed keys are used.
set -Eeuo pipefail
umask 077
project=$(cd "$(dirname "$0")/../.." && pwd)
command -v age >/dev/null && command -v age-keygen >/dev/null || { printf '需要 age/age-keygen。\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/keys"
chmod 700 "$work/keys"
# Model Linux permissions and volatile mounts when the test runs on macOS.
if [[ $(uname -s) == Darwin ]]; then
    cat > "$work/bin/stat" <<'PY'
#!/usr/bin/env python3
import os, sys
assert sys.argv[1:3] == ['-c', '%a']
print(oct(os.stat(sys.argv[3]).st_mode & 0o777)[2:])
PY
    chmod 700 "$work/bin/stat"
fi
cat > "$work/bin/findmnt" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TEST_FS_TYPE:-tmpfs}"
SH
chmod 700 "$work/bin/findmnt"
cat > "$work/bin/swapon" <<'SH'
#!/usr/bin/env bash
printf '%s' "${TEST_SWAP:-}"
SH
chmod 700 "$work/bin/swapon"
export PATH="$work/bin:$PATH"
export LUMA_BACKUP_KEY_DIR="$work/keys"
ENV_FILE="$work/config"
die() { printf '%s\n' "$*" >&2; exit 1; }
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
source "$project/deploy/backup-crypto.sh"
fail() { printf '失败：%s\n' "$*" >&2; exit 1; }
rejects() { if ( "$@" ) >/dev/null 2>&1; then fail "$* 未拒绝"; fi; }
age-keygen -o "$work/offline.key" >/dev/null 2>&1
age-keygen -o "$work/other.key" >/dev/null 2>&1
recipient=$(age-keygen -y "$work/offline.key")
# Old local keys are retained, but must not decrypt an offline-only backup.
local_id=20261023T000000Z-0000000000000001
cp "$work/other.key" "$work/keys/$local_id.key"
printf '%s\n' "$local_id" > "$work/keys/current"
printf 'LUMA_BACKUP_KEY_MODE=offline\nLUMA_BACKUP_RECIPIENT=%s\n' "$recipient" > "$ENV_FILE"
ensure_backup_key
id=$(backup_key_id)
[[ $id == offline-* ]] || fail '未产生离线标识'
[[ $(cat "$work/keys/current") == "$local_id" ]] || fail '覆盖了旧密钥指针'
printf 'test backup payload' | backup_encrypt_stream "$work/data.age"
if age -d -i "$work/other.key" "$work/data.age" >/dev/null 2>&1; then fail '本机旧私钥可解密离线备份'; fi
rejects backup_identity_args "$id"
export LUMA_BACKUP_IDENTITY="$work/offline.key"
backup_require_recovery
backup_identity_args "$id"
[[ $(backup_decrypt "$work/data.age") == 'test backup payload' ]] || fail '离线恢复失败'
export LUMA_BACKUP_IDENTITY="$work/other.key"
rejects backup_require_recovery
export LUMA_BACKUP_IDENTITY="$work/offline.key" TEST_FS_TYPE=ext4
rejects backup_require_recovery
unset TEST_FS_TYPE LUMA_BACKUP_IDENTITY
export LUMA_BACKUP_IDENTITY="$work/offline.key" TEST_SWAP=/swapfile
rejects backup_require_recovery
unset TEST_SWAP LUMA_BACKUP_IDENTITY
# Legacy IDs remain usable after switching to offline policy.
backup_identity_args "$local_id"
# Choosing a recipient whose private key is already on this VPS is not isolation.
printf 'LUMA_BACKUP_KEY_MODE=offline\nLUMA_BACKUP_RECIPIENT=%s\n' "$(age-keygen -y "$work/other.key")" > "$ENV_FILE"
rejects ensure_backup_key
printf 'LUMA_BACKUP_KEY_MODE=invalid\n' > "$ENV_FILE"
rejects ensure_backup_key
printf 'LUMA_BACKUP_KEY_MODE=offline\nLUMA_BACKUP_RECIPIENT=age1%058d\n' 0 > "$ENV_FILE"
rejects ensure_backup_key
# A new offline installation must never create a local private key or pointer.
export LUMA_BACKUP_KEY_DIR="$work/new-keys"
BACKUP_KEY_DIR=$LUMA_BACKUP_KEY_DIR
printf 'LUMA_BACKUP_KEY_MODE=offline\nLUMA_BACKUP_RECIPIENT=%s\n' "$recipient" > "$ENV_FILE"
ensure_backup_key
[[ ! -e $BACKUP_KEY_DIR ]] || fail '为离线模式生成了本地密钥'
BACKUP_KEY_DIR="$work/keys"
# Unconfigured installations retain the original local-key behavior.
printf '' > "$ENV_FILE"
ensure_backup_key
[[ $(backup_key_id) == "$local_id" ]] || fail '破坏了旧安装兼容'
printf 'legacy payload' | backup_encrypt_stream "$work/local.age"
backup_identity_args "$local_id"
[[ $(backup_decrypt "$work/local.age") == 'legacy payload' ]] || fail '旧密钥恢复失败'
# age must fail closed on tampered ciphertext.
cp "$work/data.age" "$work/damaged.age"
printf 'x' >> "$work/damaged.age"
export LUMA_BACKUP_IDENTITY="$work/offline.key"
backup_identity_args "$id"
rejects backup_decrypt "$work/damaged.age"
# The unchanged v2 manifest still binds both encrypted archives and metadata.
APP_DIR=$project
mkdir "$work/backup"
printf 'LUMA_BACKUP_KEY_MODE=offline\nLUMA_BACKUP_RECIPIENT=%s\n' "$recipient" > "$ENV_FILE"
printf '2\n' > "$work/backup/FORMAT"
printf '%040d\n' 0 > "$work/backup/VERSION"
printf '%064d\n' 0 > "$work/backup/KEY_ID"
printf '%s' "$id" > "$work/backup/BACKUP_KEY_ID"
cp "$work/data.age" "$work/backup/postgres.dump.age"
cp "$work/data.age" "$work/backup/storage.tar.gz.age"
backup_create_manifest "$work/backup"
backup_validate_manifest "$work/backup"
printf 'tampered' >> "$work/backup/storage.tar.gz.age"
rejects backup_validate_manifest "$work/backup"
printf '备份密钥策略：离线隔离、错误密钥、持久磁盘/交换空间拒绝、旧密钥兼容、密文及清单篡改拒绝通过。\n'
