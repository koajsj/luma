#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR=/opt/luma/app
ENV_FILE=/opt/luma/config/.env
COMPOSE_FILE="$APP_DIR/deploy/docker-compose.yml"
STORAGE_DIR=/opt/luma/data/storage
BACKUP_DIR=/opt/luma/backups
[[ -f "$ENV_FILE" && -d "$APP_DIR/.git" && -d "$STORAGE_DIR" ]] || { echo '部署目录不完整。' >&2; exit 1; }
[[ $(sed -n 's/^LUMA_STORAGE_DIR=//p' "$ENV_FILE" | head -1) == "$STORAGE_DIR" ]] || {
    echo '存储目录与备份脚本不一致，停止备份。' >&2; exit 1;
}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
target="$BACKUP_DIR/$stamp.partial"
complete="$BACKUP_DIR/$stamp"
mkdir -m 0700 "$target"
sudo docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    pg_dump -U luma -d luma -Fc > "$target/postgres.dump"
sudo tar -C /opt/luma/data -czf "$target/storage.tar.gz" storage
sudo chown "$(id -u):$(id -g)" "$target/storage.tar.gz"
chmod 600 "$target/postgres.dump" "$target/storage.tar.gz"
mv "$target" "$complete"
printf '备份完成：%s\n请将备份安全复制到 VPS 之外；不要提交到 Git。\n' "$complete"
