#!/usr/bin/env bash
# Sourced by backup.sh and restore.sh. Never put private identities in backups.
BACKUP_KEY_DIR=${LUMA_BACKUP_KEY_DIR:-/opt/luma/config/backup-keys}

require_age() {
    command -v age >/dev/null && command -v age-keygen >/dev/null ||
        die '缺少 age/age-keygen；请先安装 Ubuntu age 软件包。'
}

backup_key_mode() {
    local mode
    mode=$(env_value LUMA_BACKUP_KEY_MODE) || return 1
    case ${mode:-local} in
        local|offline) printf '%s' "${mode:-local}" ;;
        *) die 'LUMA_BACKUP_KEY_MODE 只能是 local 或 offline；拒绝回退到本地密钥。' ;;
    esac
}

offline_backup_recipient() {
    local recipient key public
    recipient=$(env_value LUMA_BACKUP_RECIPIENT) || return 1
    [[ $recipient =~ ^age1[0-9a-z]{58}$ ]] || die '离线模式必须配置独立保管的原生 age 公钥。'
    printf '' | age -r "$recipient" -o /dev/null 2>/dev/null || die '离线恢复公钥校验失败。'
    # Do not describe an additional recipient backed by a retained local key as
    # offline isolation. Never remove or rotate those keys automatically.
    for key in "$BACKUP_KEY_DIR"/*.key; do
        [[ -e $key || -L $key ]] || continue
        [[ -f $key && ! -L $key ]] || die '本地备份密钥文件异常。'
        public=$(age-keygen -y "$key") || die '无法核查保留的本地备份密钥。'
        [[ $public != "$recipient" ]] || die '离线接收者对应的私钥仍在本机密钥目录；请使用另一把离线密钥。'
    done
    printf '%s' "$recipient"
}

backup_key_id() {
    local id mode recipient
    mode=$(backup_key_mode) || return 1
    if [[ $mode == offline ]]; then
        recipient=$(offline_backup_recipient) || return 1
        id=$(printf '%s' "$recipient" | sha256sum | awk '{print $1}') || return 1
        printf 'offline-%s' "$id"
        return
    fi
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
    [[ $(backup_key_mode) == local ]] || die '离线模式不生成或轮换 VPS 私钥；请在独立设备管理接收者。'
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
    local mode
    require_age
    mode=$(backup_key_mode) || return 1
    if [[ $mode == offline ]]; then
        offline_backup_recipient >/dev/null || return 1
        return
    fi
    if [[ ! -f "$BACKUP_KEY_DIR/current" ]]; then
        if [[ -d "$BACKUP_KEY_DIR" ]] && compgen -G "$BACKUP_KEY_DIR/*.key" >/dev/null; then
            die '备份密钥指针缺失，但旧私钥仍存在；请人工修复，不能自动生成替代密钥。'
        fi
        create_backup_key >/dev/null
    fi
    backup_key_id >/dev/null
}

backup_encrypt_stream() {
    local recipient external mode id
    local -a args
    mode=$(backup_key_mode) || return 1
    if [[ $mode == offline ]]; then
        recipient=$(offline_backup_recipient) || return 1
        args=(-r "$recipient")
    else
        id=$(backup_key_id) || return 1
        recipient=$(age-keygen -y "$BACKUP_KEY_DIR/$id.key") || die '无法读取备份公钥。'
        args=(-r "$recipient")
        external=$(env_value LUMA_BACKUP_RECIPIENT)
        if [[ -n "$external" ]]; then args+=(-r "$external"); fi
    fi
    age "${args[@]}" -o "$1"
}

backup_identity_args() {
    local id=$1 external=${2:-${LUMA_BACKUP_IDENTITY:-}} filesystem swap
    BACKUP_IDENTITIES=()
    if [[ $id =~ ^offline-[0-9a-f]{64}$ ]]; then
        [[ -n $external ]] || die '离线备份需要临时提供恢复私钥；未开始数据替换。'
        filesystem=$(findmnt -n -o FSTYPE -T "$external") || die '无法确认恢复私钥位于内存文件系统。'
        [[ $filesystem == tmpfs || $filesystem == ramfs ]] || die '离线恢复私钥只能临时置于 tmpfs/ramfs；禁止从 VPS 持久磁盘读取。'
        swap=$(swapon --show=NAME --noheadings) || die '无法确认交换空间状态；拒绝读取离线私钥。'
        [[ -z $swap ]] || die '存在活动交换空间，内存私钥可能写入磁盘；请人工处理后再维护。'
    else
        [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || die '备份密钥标识无效。'
        if [[ -f "$BACKUP_KEY_DIR/$id.key" && ! -L "$BACKUP_KEY_DIR/$id.key" ]]; then
            BACKUP_IDENTITIES+=(-i "$BACKUP_KEY_DIR/$id.key")
        fi
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

# Destructive maintenance must prove that its compensation snapshot will be
# recoverable before it stops services or changes code/database/files.
backup_require_recovery() {
    local probe restored id
    ensure_backup_key || return 1
    id=$(backup_key_id) || return 1
    backup_identity_args "$id" || return 1
    probe=$(openssl rand -hex 32)
    restored=$(printf '%s' "$probe" | backup_encrypt_stream - | backup_decrypt -) ||
        die '当前备份策略的恢复私钥验证失败；未开始维护。'
    [[ $restored == "$probe" ]] || die '恢复私钥验证失败；未开始维护。'
}

backup_create_manifest() {
    python3 "$APP_DIR/deploy/backup-format.py" manifest "$1" |
        backup_encrypt_stream "$1/MANIFEST.age"
}

backup_validate_manifest() {
    backup_decrypt "$1/MANIFEST.age" |
        python3 "$APP_DIR/deploy/backup-format.py" verify-manifest "$1"
}
