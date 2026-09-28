#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/luma/app
ENV_FILE=/opt/luma/config/.env
COMPOSE_FILE="$APP_DIR/deploy/docker-compose.yml"
[[ -f "$ENV_FILE" && -d "$APP_DIR/.git" ]] || { echo '尚未部署；先运行 bash deploy/deploy.sh。' >&2; exit 1; }
[[ -z $(git -C "$APP_DIR" status --porcelain) ]] || { echo '服务器仓库有本地改动，停止更新，避免覆盖。' >&2; exit 1; }
[[ $(git -C "$APP_DIR" branch --show-current) == main ]] || { echo '服务器仓库必须位于 main 分支。' >&2; exit 1; }
grep -Eq '^LUMA_USERID_HMAC_SECRET=[0-9a-fA-F]{64}$' "$ENV_FILE" || { echo '请先在私有 .env 中设置持久的 LUMA_USERID_HMAC_SECRET；不要每次更新重新生成。' >&2; exit 1; }

"$APP_DIR/deploy/backup.sh"
git -C "$APP_DIR" pull --ff-only origin main
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --build --wait
domain=$(sed -n 's/^LUMA_DOMAIN=//p' "$ENV_FILE" | head -1)
curl --retry 12 --retry-delay 5 --retry-connrefused -fsS "https://$domain/health" >/dev/null
printf '更新完成：https://%s/health\n' "$domain"
