# Luma Backend：Ubuntu VPS 部署

此方案把后端、PostgreSQL、Redis 和 Caddy 部署到一台 Ubuntu 22.04/24.04 VPS。公网只开放 Caddy 的 80/443；后端、数据库和 Redis 只在 Docker 私有网络内通信。Caddy 自动申请 HTTPS 证书并代理 WebSocket。上传文件由客户端先加密，再写入 VPS 的 `/opt/luma/data/storage/ciphertext`。**服务端仍能看到账号和通信元数据；这份部署配置不代表完成 E2EE 安全验收。**

## 准备

1. 一台可使用 `sudo` 的 Ubuntu 22.04/24.04 VPS，建议至少 2 GiB 内存、足够的持久磁盘和已配置的 SSH 密钥。
2. 一个域名，例如 `api.example.com`。在域名服务商处添加 A 记录指向 VPS 公网 IPv4；如配置 AAAA，IPv6 也必须指向此 VPS。等待 DNS 生效。
3. 云平台防火墙放行 TCP 22、80、443；需要 HTTP/3 时再放行 UDP 443。不要对公网开放 8080、5432、6379。
4. GitHub 仓库 `https://github.com/koajsj/luma.git` 可访问。私有仓库需预先给服务器配置只读 Git 凭据；脚本不会管理 GitHub 凭据。

## 首次部署

在自己的电脑上用 SSH 登录 VPS：

```bash
ssh ubuntu@YOUR_VPS_IP
```

在 VPS 上执行：

```bash
git clone https://github.com/koajsj/luma.git luma-setup
cd luma-setup
bash deploy/deploy.sh
```

首次运行会检查 Ubuntu、安装 Git/Docker/Compose，把 `main` 克隆到 `/opt/luma/app`，创建 `/opt/luma/data/storage`、`/opt/luma/backups` 和权限为 600 的 `/opt/luma/config/.env`。交互输入 API 域名和证书通知邮箱；数据库密码和 UserID 索引 HMAC 密钥分别由 `openssl` 随机生成，不输出到终端。无人值守时可先设置 `LUMA_DOMAIN` 与 `ACME_EMAIL` 环境变量。已有 `.env` 不会被覆盖。示例字段见 [.env.example](.env.example)；不要把真实 `.env` 放进仓库。更新和恢复时必须沿用原 HMAC 密钥；密钥不匹配会阻止服务启动。

Docker 使用[官方 Ubuntu apt 仓库](https://docs.docker.com/engine/install/ubuntu/)安装；若服务器已有冲突的 Docker 套件，脚本会停止，以免影响其他容器。

脚本运行 `docker compose up -d --build --wait`。后端连接数据库后会按顺序执行 `backend/migrations`，再提供 `/health`。DNS 与 80/443 可用后，检查：

```bash
curl -fsS https://api.example.com/health
sudo docker compose --env-file /opt/luma/config/.env -f /opt/luma/app/deploy/docker-compose.yml ps
```

正常健康接口返回 `{"status":"ok"}`。WebSocket 地址为 `wss://api.example.com/v1/ws`，需要有效设备认证，不能用无凭据的浏览器访问来判断故障。iOS 的在线模式在设置页输入 `https://api.example.com`；本地模式不受影响。开发环境可继续使用 Xcode 的 `LUMA_DEV_API_URL`，客户端没有硬编码生产地址。

## 日常维护

更新前自动备份，然后快进拉取 `main`、重新构建并等待健康：

```bash
bash /opt/luma/app/deploy/update.sh
```

手动备份数据库与密文目录：

```bash
bash /opt/luma/app/deploy/backup.sh
```

备份写入 `/opt/luma/backups/<UTC时间>/`，包含 `postgres.dump` 和 `storage.tar.gz`，**不包含** `.env` 或 HMAC 密钥。两份数据文件必须一起保管，建议加密后复制到 VPS 之外；运维需在独立的密钥管理系统中保管原 HMAC 密钥，以供恢复时重新注入环境。当前备份不是数据库与文件系统的原子快照，重要恢复前应暂停写入并再备份一次。备份不会自动清理，需监控磁盘。不要提交备份到 Git。

查看状态和日志（日志不要复制到公开渠道）：

```bash
sudo docker compose --env-file /opt/luma/config/.env -f /opt/luma/app/deploy/docker-compose.yml ps
sudo docker compose --env-file /opt/luma/config/.env -f /opt/luma/app/deploy/docker-compose.yml logs --tail=100 backend caddy
```

## 恢复

先在隔离环境演练，再对真实 VPS 操作。确认备份可信且版本兼容，保留当前数据的另一份离线副本；数据库迁移没有自动回滚。

```bash
COMPOSE=/opt/luma/app/deploy/docker-compose.yml
ENV=/opt/luma/config/.env
BACKUP=/opt/luma/backups/YYYYMMDDTHHMMSSZ
sudo docker compose --env-file "$ENV" -f "$COMPOSE" stop backend
sudo docker compose --env-file "$ENV" -f "$COMPOSE" exec -T postgres pg_restore -U luma -d luma --clean --if-exists --no-owner < "$BACKUP/postgres.dump"
sudo tar -C /opt/luma/data -xzf "$BACKUP/storage.tar.gz"
sudo chown -R 10001:10001 /opt/luma/data/storage
sudo docker compose --env-file "$ENV" -f "$COMPOSE" up -d --wait
curl -fsS https://api.example.com/health
```

恢复会替换同路径文件并可能保留备份后新增的密文文件。请在隔离环境核对数据库、附件与账号后再开放服务；不要盲目恢复到比备份更旧的代码版本。

## 常见故障

- `HTTPS 健康检查失败`：核对 DNS、云防火墙 80/443、Caddy 日志与证书申请限制。不要绕过证书校验。
- `backend unhealthy`：查看后端日志与 PostgreSQL/Redis 状态；迁移失败时不要重复手改数据库，先备份并检查具体迁移。
- `permission denied`：检查 `/opt/luma/data/storage` 是否由 UID 10001 拥有；不要把目录改成全员可写。
- 数据库密码、域名变更：编辑 `/opt/luma/config/.env`，保持权限 600。**已有 PostgreSQL 数据卷不会因为修改 `POSTGRES_PASSWORD` 而自动改密码**，应按数据库维护流程单独变更。
