# Luma 自托管部署与维护

> 状态：部署脚本已提供。生产 VPS 的首次安装、HTTPS、WebSocket、文件上传和恢复仍需在实际 Ubuntu 服务器上验收。本指南不代表 v4 E2EE 或生产安全审计已经完成。

## 准备

- Ubuntu 22.04 或 24.04 VPS；建议至少 2 GiB 内存和持久磁盘。使用有 sudo 权限的账号登录。
- 云防火墙只开放 SSH 22、HTTP 80、HTTPS 443；需要 HTTP/3 时可另开放 UDP 443。PostgreSQL、Redis 和后端 8080 **不开放公网端口**。
- 可选域名：先将 A 记录指向 VPS 公网 IPv4；若有 AAAA，IPv6 也必须指向这台 VPS。Caddy 会自动申请和续期 HTTPS 证书，不要求邮箱。
- GitHub 仓库当前必须可从 VPS 访问。安装脚本会安装 Git、Docker Engine、Compose、curl 和 OpenSSL；发现冲突的 Docker 套件时停止，不会清理现有容器。

## 一条命令首次安装

SSH 登录 VPS 后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/koajsj/luma/main/deploy/install.sh | bash
```

脚本仅询问是否使用域名；选择使用域名时再输入域名。也可预先设置 `LUMA_DOMAIN=api.example.com`。不配置域名则进入 **IP 测试模式**，使用 `http://VPS_IP`；此模式没有 TLS，**不得用于真实用户、设备凭据或互联网公开服务**。正式使用前执行 `luma domain change`。

脚本克隆 main 到 `/opt/luma/app`，创建 `/opt/luma/data/postgres`、`redis`、`storage` 和 `/opt/luma/backups`，生成权限为 600 的 `/opt/luma/config/.env`。数据库、Redis 和 UserID HMAC 密钥由系统随机数生成，**不会输出到终端或提交到 Git**。`LUMA_JWT_SECRET` 仅为未来 JWT 预留；当前后端使用数据库支持的不透明 Token，不能把此变量描述为当前认证密钥。

服务由 Docker Compose 启动：PostgreSQL、Redis、Go Backend、Caddy。后端启动时自动运行版本化 PostgreSQL migration；Caddy 代理普通 HTTP 和 WebSocket。Redis 仅保存可重建的短期状态，不写持久化快照。客户端先加密附件，再上传到 `/opt/luma/data/storage/ciphertext`。服务器仍可见账号、设备、时间、大小等元数据。

域名模式健康地址为 `https://你的域名/health`；IP 测试模式为 `http://VPS_IP/health`。正常结果为 `{"status":"ok"}`。WebSocket 地址为相同域名下的 `wss://你的域名/v1/ws`，需要有效设备认证；未经认证的直接访问被拒绝是预期行为。

## 日常管理

安装完成后可执行：

| 命令 | 用途 |
| --- | --- |
| `luma status` | 查看容器和 HTTP 健康状态 |
| `luma logs` | 查看最近 100 行后端日志；`luma logs caddy` 查看代理日志 |
| `luma update` | 先备份，拉取 main，重建并检查健康；失败时恢复旧代码、数据库和文件 |
| `luma backup` | 备份 PostgreSQL、密文目录、代码版本和 SHA-256 校验清单 |
| `luma restore /opt/luma/backups/时间戳` | 校验后交互确认，替换数据库和密文目录 |
| `luma domain change [新域名]` | 修改域名、启动 Caddy、检查 HTTPS；失败时恢复旧配置 |
| `luma rollback [备份目录]` | 确认后先备份当前版本，再恢复较早的代码与对应数据 |

备份存在 `/opt/luma/backups`，不自动删除。请监控磁盘，并定期将备份加密复制到 VPS 之外。备份的 `KEY_ID` 是 HMAC 密钥的 SHA-256 标识，不含密钥本身，用来阻止错误密钥恢复。备份期间脚本会短暂停止后端与 Caddy，以固定数据库和密文目录；数据库与文件系统仍不是跨系统原子事务，故备份前应等待大文件上传完成。回滚使用备份的 PostgreSQL 数据覆盖当前数据库，**备份之后产生的数据会丢失**；更新前与手动回滚前都会先保存当前备份。

恢复要求备份的 `VERSION` 是当前 main 的祖先提交；若不同，脚本先切回备份对应代码，再恢复数据库与密文目录。不能只回退容器而保留更新后的数据库 schema。恢复使用 `SHA256SUMS` 检查数据完整性；该校验不提供真实性保证，只从可信来源导入备份。恢复前将当前备份另外复制到安全位置，确认操作会替换当前数据。

## 更换服务器

1. 旧 VPS 上执行 `luma backup`，安全保存完整备份目录。
2. 新 VPS 运行安装命令，使用新的数据库和 Redis 密码。
3. 将备份目录复制到新 VPS 的 `/opt/luma/backups`。**另行安全转移**旧 VPS 的 `/opt/luma/config/.env`，在新 VPS 上暂存为 `/opt/luma/config/old.env`，权限设为 600。备份不包含它；原 UserID HMAC 密钥与数据库必须成对保留。不要发在聊天、工单或 Git 中。
4. 运行 `luma restore /opt/luma/backups/时间戳 /opt/luma/config/old.env`。脚本只导入原 UserID HMAC 密钥，保留新服务器自动生成的数据库和 Redis 密码，并切回相容的备份代码版本。核对健康、账号、消息和附件后，安全移除暂存的旧配置。旧服务器确认停用后再切换 DNS，避免双端同时写入。

若新 VPS 的本地仓库没有备份对应提交，或备份提交不是当前 main 的祖先，恢复会停止，不会猜测 schema 兼容性。恢复完成后可按顺序执行 `luma update`。

## 常见问题与安全边界

- HTTPS 失败：检查 DNS、80/443、Caddy 日志和证书申请限制。不要关闭 TLS 校验。
- Backend 不健康：检查 PostgreSQL、Redis、migration 日志。不要在缺少数据库备份时手工修改 schema。
- 存储权限失败：密文目录应由容器 UID 10001 持有。不要改成全员可写。
- `.env` 不进入 Git，且必须保持 600；更新和恢复时不要重置 UserID HMAC 密钥。Docker 管理员可读取容器环境与密文数据，应限制服务器 root 和 Docker 权限。
- 如曾使用旧版 `luma_pgdata` 命名卷，脚本发现新 PostgreSQL 目录为空时会停止，避免启动空数据库。先对旧卷做独立备份并迁移数据；不要直接删除旧卷。
- 部署日志不得主动输出 Token、私钥、消息正文或附件内容；不要把实际日志贴到公开渠道。
- 当前没有 APNs 正式推送、生产双真机验收或独立安全审计。应用安全状态仍以客户端可验证的实际能力为准。
