#!/usr/bin/env bash
# Sourced by backup.sh and restore.sh. Never put private identities in backups.
BACKUP_KEY_DIR=${LUMA_BACKUP_KEY_DIR:-/opt/luma/config/backup-keys}

require_age() {
    command -v age >/dev/null && command -v age-keygen >/dev/null ||
        die '缺少 age/age-keygen；请先安装 Ubuntu age 软件包。'
}

backup_key_id() {
    local id
    [[ -f "$BACKUP_KEY_DIR/current" && ! -L "$BACKUP_KEY_DIR/current" ]] || die '备份密钥未初始化。'
    id=$(cat "$BACKUP_KEY_DIR/current")
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || die '备份密钥标识无效。'
    [[ -f "$BACKUP_KEY_DIR/$id.key" && ! -L "$BACKUP_KEY_DIR/$id.key" ]] || die '备份私钥缺失；拒绝生成替代密钥。'
    [[ $(stat -c %a "$BACKUP_KEY_DIR") == 700 &&
       $(stat -c %a "$BACKUP_KEY_DIR/current") == 600 &&
       $(stat -c %a "$BACKUP_KEY_DIR/$id.key") == 600 ]] ||
        die '备份密钥目录或文件权限过宽。'
    printf '%s' "$id"
}

create_backup_key() {
    local id tmp current_tmp
    require_age
    install -d -m 0700 "$BACKUP_KEY_DIR"
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8)"
    [[ ! -e "$BACKUP_KEY_DIR/$id.key" ]] || die '备份密钥标识冲突。'
    tmp=$(mktemp -d "$BACKUP_KEY_DIR/.new.XXXXXX")
    if ! age-keygen -o "$tmp/identity" >/dev/null 2>&1; then
        rm -f "$tmp/identity"
        rmdir "$tmp" 2>/dev/null || true
        die '生成备份密钥失败。'
    fi
    chmod 600 "$tmp/identity"
    mv "$tmp/identity" "$BACKUP_KEY_DIR/$id.key"
    rmdir "$tmp"
    current_tmp=$(mktemp "$BACKUP_KEY_DIR/.current.XXXXXX")
    printf '%s\n' "$id" > "$current_tmp"
    chmod 600 "$current_tmp"
    mv "$current_tmp" "$BACKUP_KEY_DIR/current"
    printf '%s' "$id"
}

ensure_backup_key() {
    require_age
    if [[ ! -f "$BACKUP_KEY_DIR/current" ]]; then
        if [[ -d "$BACKUP_KEY_DIR" ]] && compgen -G "$BACKUP_KEY_DIR/*.key" >/dev/null; then
            die '备份密钥指针缺失，但旧私钥仍存在；请人工修复，不能自动生成替代密钥。'
        fi
        create_backup_key >/dev/null
    fi
    backup_key_id >/dev/null
}

backup_encrypt_stream() {
    local recipient external
    local -a args
    recipient=$(age-keygen -y "$BACKUP_KEY_DIR/$(backup_key_id).key") || die '无法读取备份公钥。'
    args=(-r "$recipient")
    external=$(env_value LUMA_BACKUP_RECIPIENT)
    if [[ -n "$external" ]]; then args+=(-r "$external"); fi
    age "${args[@]}" -o "$1"
}

backup_identity_args() {
    local id=$1 external=${2:-}
    BACKUP_IDENTITIES=()
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || die '备份密钥标识无效。'
    if [[ -f "$BACKUP_KEY_DIR/$id.key" && ! -L "$BACKUP_KEY_DIR/$id.key" ]]; then
        BACKUP_IDENTITIES+=(-i "$BACKUP_KEY_DIR/$id.key")
    fi
    if [[ -n $external ]]; then
        [[ -f $external && ! -L $external && $(stat -c %a "$external") == 600 ]] ||
            die '外部恢复私钥必须是权限为 600 的普通文件。'
        BACKUP_IDENTITIES+=(-i "$external")
    fi
    (( ${#BACKUP_IDENTITIES[@]} > 0 )) || die '缺少该备份的解密私钥；请提供离线恢复私钥。'
}

backup_decrypt() {
    age -d "${BACKUP_IDENTITIES[@]}" "$1"
}

backup_create_manifest() {
    python3 "$APP_DIR/deploy/backup-format.py" manifest "$1" |
        backup_encrypt_stream "$1/MANIFEST.age"
}

backup_validate_manifest() {
    backup_decrypt "$1/MANIFEST.age" |
        python3 "$APP_DIR/deploy/backup-format.py" verify-manifest "$1"
}
