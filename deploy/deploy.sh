#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(dirname "$0")/lib.sh"
[[ -f /etc/os-release ]] || die '仅支持 Ubuntu 22.04/24.04。'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ]] || die '仅支持 Ubuntu 22.04/24.04。'
if [[ $(id -u) != 0 ]]; then sudo -v || die '需要 sudo 权限。'; fi
command -v python3 >/dev/null || die '缺少 Python 3；请重新运行 install.sh。'
[[ -d "$APP_DIR/.git" ]] || die '先运行 install.sh 拉取仓库。'
[[ $(git -C "$APP_DIR" remote get-url origin) == https://github.com/koajsj/luma.git ]] || die 'origin 与官方仓库不符。'
require_clean_main
root install -d -m 0700 -o "$(id -u)" -g "$(id -g)" /opt/luma/config "$BACKUP_DIR"
root install -d -m 0755 /opt/luma/data
lock_operation
if [[ ! -d /opt/luma/data/postgres ]]; then root install -d -m 0700 /opt/luma/data/postgres; fi
if [[ ! -d /opt/luma/data/redis ]]; then
    root install -d -m 0700 -o 999 -g 999 /opt/luma/data/redis
fi
root install -d -m 0700 -o 10001 -g 10001 "$STORAGE_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
    mode=ip
    domain=''
    if [[ -n ${LUMA_DOMAIN:-} ]]; then
        mode=domain
        domain=$LUMA_DOMAIN
    elif ( : </dev/tty ) 2>/dev/null; then
        printf '是否配置域名并自动启用 HTTPS？[y/N] ' > /dev/tty
        read -r answer < /dev/tty || answer=n
        if [[ $answer == y || $answer == Y ]]; then
            printf '请输入已指向此 VPS 的域名：' > /dev/tty
            read -r domain < /dev/tty || die '读取域名失败。'
            mode=domain
        fi
    fi
    if [[ $mode == domain ]]; then
        [[ $domain =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || die '域名格式不正确。'
        site=$domain
    else
        site=:80
    fi
    password=$(openssl rand -hex 32)
    redis_password=$(openssl rand -hex 32)
    jwt_secret=$(openssl rand -hex 32)
    user_id_secret=$(openssl rand -hex 32)
    printf 'LUMA_MODE=%s\nLUMA_DOMAIN=%s\nLUMA_SITE=%s\nPOSTGRES_PASSWORD=%s\nREDIS_PASSWORD=%s\nLUMA_JWT_SECRET=%s\nLUMA_USERID_HMAC_SECRET=%s\nLUMA_STORAGE_DIR=%s\n' \
        "$mode" "$domain" "$site" "$password" "$redis_password" "$jwt_secret" "$user_id_secret" "$STORAGE_DIR" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi
require_install
[[ $(env_value LUMA_STORAGE_DIR) == "$STORAGE_DIR" ]] || die '存储目录与部署配置不一致。'
grep -Eq '^LUMA_USERID_HMAC_SECRET=[0-9a-fA-F]{64}$' "$ENV_FILE" || die 'UserID HMAC 密钥无效；不可重新生成已有数据库的密钥。'
for key in POSTGRES_PASSWORD REDIS_PASSWORD LUMA_JWT_SECRET; do
    grep -Eq "^$key=[0-9a-fA-F]{64}$" "$ENV_FILE" || die "$key 缺失或无效。"
done
redis_password=$(env_value REDIS_PASSWORD)
redis_config=$(mktemp)
printf 'save ""\nappendonly no\ndir /data\nrequirepass %s\n' "$redis_password" > "$redis_config"
redis_changed=0
if [[ -f /opt/luma/config/redis.conf ]] && ! root cmp -s "$redis_config" /opt/luma/config/redis.conf; then
    redis_changed=1
fi
root install -m 0400 -o 999 -g 999 "$redis_config" /opt/luma/config/redis.conf
rm -f "$redis_config"
if ! command -v docker >/dev/null || ! root docker compose version >/dev/null 2>&1; then
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            die '发现冲突的容器套件。为保护现有容器，请先人工迁移到 Docker Engine + Compose。'
        fi
    done
    root install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | root tee /etc/apt/keyrings/docker.asc >/dev/null
    root chmod a+r /etc/apt/keyrings/docker.asc
    arch=$(dpkg --print-architecture)
    codename=${VERSION_CODENAME:?}
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$codename" "$arch" |
        root tee /etc/apt/sources.list.d/docker.sources >/dev/null
    root apt-get update -qq
    root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
root systemctl enable --now docker >/dev/null
if root docker volume inspect luma_pgdata >/dev/null 2>&1 &&
   [[ -z $(root find /opt/luma/data/postgres -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    die '检测到旧版 PostgreSQL Docker volume，而新数据目录为空。已停止以防启动空数据库；先备份并迁移旧 volume。'
fi
compose config --quiet
if [[ $redis_changed == 1 && -n $(compose ps -q redis) ]]; then compose restart redis; fi
compose up -d --build --wait
health >/dev/null || die '容器启动后健康检查失败，请检查 DNS、端口和 Caddy 日志。'
root install -m 0755 "$APP_DIR/deploy/luma" /usr/local/bin/luma
printf '部署完成：%s\n管理命令：luma status | logs | update | backup | restore | domain change | rollback\n' "$(show_address)"
if [[ $(env_value LUMA_MODE) == ip ]]; then
    printf 'IP 测试模式仅使用 HTTP，不适合真实用户或设备凭据。配置域名后运行 luma domain change。\n'
fi
