#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/luma/app
ENV_FILE=/opt/luma/config/.env
COMPOSE_FILE="$APP_DIR/deploy/docker-compose.yml"
REPO_URL=${LUMA_REPO_URL:-https://github.com/koajsj/luma.git}

fail() { printf '部署失败：%s\n' "$*" >&2; exit 1; }
trap 'printf "部署中断（第 %s 行）。查看服务：sudo docker compose --env-file %s -f %s logs --tail=100\n" "$LINENO" "$ENV_FILE" "$COMPOSE_FILE" >&2' ERR

[[ -f /etc/os-release ]] || fail '仅支持 Ubuntu 22.04/24.04。'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu && ( ${VERSION_ID:-} == 22.04 || ${VERSION_ID:-} == 24.04 ) ]] || fail '仅支持 Ubuntu 22.04/24.04。'
[[ $(id -u) -ne 0 ]] || fail '请以普通 sudo 用户运行，不要直接以 root 运行。'
command -v sudo >/dev/null || fail '需要 sudo 权限。'
sudo -v || fail '当前用户没有 sudo 权限。'

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates openssl >/dev/null
if ! command -v docker >/dev/null || ! sudo docker compose version >/dev/null 2>&1; then
    printf '安装 Docker Engine 与 Compose 插件…\n'
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            fail '发现其他 Docker 套件；为避免影响现有容器，请先按 Docker 官方文档迁移到 Engine + Compose 插件。'
        fi
    done
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    arch=$(dpkg --print-architecture)
    codename=${VERSION_CODENAME:?}
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
        "$codename" "$arch" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
sudo systemctl enable --now docker >/dev/null
sudo docker compose version >/dev/null || fail 'Docker Compose 插件不可用。'

sudo install -d -m 0755 /opt/luma
sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR"
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" /opt/luma/config /opt/luma/backups
sudo install -d -m 0700 -o 10001 -g 10001 /opt/luma/data/storage
if [[ ! -d "$APP_DIR/.git" ]]; then
    [[ -z $(ls -A "$APP_DIR") ]] || fail "$APP_DIR 已有文件且不是 Git 仓库，请人工检查。"
    git clone --branch main --single-branch "$REPO_URL" "$APP_DIR"
fi
[[ $(git -C "$APP_DIR" remote get-url origin) == "$REPO_URL" ]] || fail "$APP_DIR 的 origin 与预期 GitHub 仓库不同。"
[[ $(git -C "$APP_DIR" branch --show-current) == main ]] || fail "$APP_DIR 必须位于 main 分支。"
[[ -z $(git -C "$APP_DIR" status --porcelain) ]] || fail "$APP_DIR 有本地改动；请人工检查后再部署。"
[[ -f "$COMPOSE_FILE" ]] || fail '仓库缺少 deploy/docker-compose.yml；请先推送部署文件。'

if [[ ! -f "$ENV_FILE" ]]; then
    domain=${LUMA_DOMAIN:-}
    email=${ACME_EMAIL:-}
    if [[ -z "$domain" && -t 0 ]]; then read -r -p 'API 域名（如 api.example.com）：' domain; fi
    if [[ -z "$email" && -t 0 ]]; then read -r -p '证书通知邮箱：' email; fi
    [[ $domain =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || fail '请设置合法 LUMA_DOMAIN，并先将域名 A/AAAA 记录指向此 VPS。'
    [[ $email =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || fail '请设置合法 ACME_EMAIL。'
    password=$(openssl rand -hex 32)
    user_id_secret=$(openssl rand -hex 32)
    umask 077
    printf 'LUMA_DOMAIN=%s\nACME_EMAIL=%s\nPOSTGRES_PASSWORD=%s\nLUMA_USERID_HMAC_SECRET=%s\nLUMA_STORAGE_DIR=/opt/luma/data/storage\n' \
        "$domain" "$email" "$password" "$user_id_secret" > "$ENV_FILE"
    printf '已生成私有配置 %s；数据库口令未输出。\n' "$ENV_FILE"
fi
[[ $(stat -c %a "$ENV_FILE") == 600 ]] || fail "$ENV_FILE 权限必须为 600。"
grep -Eq '^LUMA_USERID_HMAC_SECRET=[0-9a-fA-F]{64}$' "$ENV_FILE" || fail '配置缺少有效 LUMA_USERID_HMAC_SECRET；请生成一次并在更新、恢复时沿用同一个值。'
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --build --wait

domain=$(sed -n 's/^LUMA_DOMAIN=//p' "$ENV_FILE" | head -1)
[[ -n "$domain" ]] || fail '配置缺少 LUMA_DOMAIN。'
printf '容器已启动。后端启动时自动执行 PostgreSQL migration。检查 HTTPS：\n'
if curl --retry 12 --retry-delay 5 --retry-connrefused -fsS "https://$domain/health"; then
    printf '\n部署完成：https://%s/health\nWebSocket：wss://%s/v1/ws（需设备认证）\n' "$domain" "$domain"
else
    fail '容器已启动但 HTTPS 健康检查失败。检查 DNS、80/443 端口与 Caddy 日志。'
fi
