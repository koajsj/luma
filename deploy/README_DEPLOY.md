# Luma 自托管部署与维护

> 状态：部署脚本已提供。生产 VPS 的首次安装、HTTPS、WebSocket、文件上传和恢复仍需在实际 Ubuntu 服务器上验收。本指南不代表 v4 E2EE 或生产安全审计已经完成。

## 准备

- Ubuntu 22.04 或 24.04 VPS；建议至少 2 GiB 内存和持久磁盘。使用有 sudo 权限的账号登录。
- 云防火墙只开放 SSH 22、HTTP 80、HTTPS 443；需要 HTTP/3 时可另开放 UDP 443。PostgreSQL、Redis 和后端 8080 **不开放公网端口**。
- 可选域名：先将 A 记录指向 VPS 公网 IPv4；若有 AAAA，IPv6 也必须指向这台 VPS。Caddy 会自动申请和续期 HTTPS 证书，不要求邮箱。
- GitHub 仓库当前必须可从 VPS 访问。安装脚本会安装 Git、Docker Engine、Compose、curl、OpenSSL 和 Ubuntu 的 `age` 软件包；发现冲突的 Docker 套件时停止，不会清理现有容器。旧安装升级前如缺少 `age`，先运行 `sudo apt-get install age`，避免更新前备份无法使用新恢复脚本。

## 一条命令首次安装

SSH 登录 VPS 后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/koajsj/luma/main/deploy/install.sh | bash
```

脚本仅询问是否使用域名；选择使用域名时再输入域名。也可预先设置 `LUMA_DOMAIN=api.example.com`。不配置域名则进入 **IP 测试模式**，使用 `http://VPS_IP`；此模式没有 TLS，**不得用于真实用户、设备凭据或互联网公开服务**。正式使用前执行 `luma domain change`。

脚本克隆 main 到 `/opt/luma/app`，创建 `/opt/luma/data/postgres`、`redis`、`storage` 和 `/opt/luma/backups`，生成权限为 600 的 `/opt/luma/config/.env`。数据库、Redis 和 UserID HMAC 密钥由系统随机数生成，**不会输出到终端或提交到 Git**。`LUMA_JWT_SECRET` 仅为未来 JWT 预留；当前后端使用数据库支持的不透明 Token，不能把此变量描述为当前认证密钥。

服务由 Docker Compose 启动：PostgreSQL、Redis、Go Backend、Caddy。后端启动时自动运行版本化 PostgreSQL migration；Caddy 代理普通 HTTP 和 WebSocket。Redis 仅保存可重建的短期状态，不写持久化快照。客户端先加密附件，再上传到 `/opt/luma/data/storage/ciphertext`。服务器仍可见账号、设备、时间、大小等元数据。

部署网络固定使用 `172.31.251.0/24`，Caddy 在内部网络使用 `172.31.251.2`。后端只信任此地址转发的单个客户端 IP，Caddy 会覆盖客户端提供的 `X-Forwarded-For`。若 VPS 上已有重叠 Docker 网络，须在部署前同步修改 Compose 中的网段、Caddy 地址及 `LUMA_TRUSTED_PROXY_IP`，保持三处一致。

域名模式进程检查地址为 `https://你的域名/health`，就绪检查地址为 `https://你的域名/ready`；IP 测试模式使用 `http://VPS_IP` 加相同路径。正常结果为 `{"status":"ok"}`。部署和更新以 `/ready` 为准，它只返回通用状态，不公开 PostgreSQL、Redis 或存储的错误详情。WebSocket 地址为相同域名下的 `wss://你的域名/v1/ws`，需要有效设备认证；未经认证的直接访问被拒绝是预期行为。

## 日常管理

安装完成后可执行：

| 命令 | 用途 |
| --- | --- |
| `luma status` | 查看容器和 HTTP 健康状态 |
| `luma logs` | 查看最近 100 行后端日志；`luma logs caddy` 查看代理日志 |
| `luma update` | 先备份，拉取 main，重建并检查健康；失败时恢复旧代码、数据库和文件 |
| `luma backup` | 停止写入，流式加密 PostgreSQL 转储和密文目录，验证后生成备份 |
| `luma backup migrate /opt/luma/backups/旧目录` | 验证旧明文备份并生成独立的 `.encrypted` 加密副本；原目录不变 |
| `luma backup-key rotate` | 轮换后续备份的本地接收密钥；旧私钥保留供旧备份恢复 |
| `luma restore /opt/luma/backups/时间戳` | 先认证和校验，确认后替换数据库与密文目录 |
| `luma restore recover` | 中断后用加密的原数据库快照、原配置和旧目录恢复旧服务 |
| `luma domain change [新域名]` | 修改域名、启动 Caddy、检查 HTTPS；失败时恢复旧配置 |
| `luma rollback [备份目录]` | 确认后先备份当前版本，再恢复较早的代码与对应数据 |

备份存在 `/opt/luma/backups`，不自动删除。新格式 `FORMAT=2`：`postgres.dump.age` 和 `storage.tar.gz.age` 用 `age` 的原生接收者加密格式保护，`MANIFEST.age` 认证版本、UserID HMAC 密钥标识、密钥标识和两份密文的 SHA-256。备份目录仅含加密数据和非秘密元数据，不含 `.env` 或私钥。`age` 自行生成随机文件密钥并认证密文；脚本不自行实现密码学。备份期间短暂停止后端与 Caddy 以固定数据库和密文目录；备份前请等待大文件上传完成。回滚会覆盖备份后新增数据，更新和手动回滚都会先备份当前状态。

首次备份自动在 `/opt/luma/config/backup-keys` 生成本地私钥，目录权限 `700`、私钥和当前指针 `600`。请通过受控离线渠道保存私钥副本；**只复制备份目录而没有对应私钥无法恢复**。可在私有 `.env` 配置 `LUMA_BACKUP_RECIPIENT=age1...`，使新备份同时加密给一把在 VPS 外生成并保管的恢复公钥；绝不能把该私钥写入 `.env`。本地私钥允许无人值守更新失败时自动回滚，但 VPS 完全失陷时攻击者可能同时取得备份和本地私钥，离线副本不能消除这一风险。`luma backup-key rotate` 只更换未来备份的本地密钥；旧备份的私钥必须一直保留到其备份全部安全退役。密钥丢失时脚本拒绝自动生成替代密钥。请监控磁盘并将加密备份复制到 VPS 之外。

恢复先认证 `MANIFEST.age`、校验密文哈希和完整的数据库/附件归档，再检查 UserID HMAC 密钥、代码祖先版本和磁盘可用空间，最后要求输入 `RESTORE`。数据替换前会停止对外服务，并把原数据库流式加密成 `/opt/luma/config/restore-state/previous-db.age`，保留原配置及旧密文目录，直到新服务通过 `/ready`。INT/TERM 或一般命令失败会尝试补偿；补偿失败时停止后端和 Caddy，保留恢复状态与原数据。主机断电或 SIGKILL 后，**先保持服务停机**，运行 `luma restore recover`，成功并确认 `/ready` 后才能再次备份或更新。磁盘空间预检只提供保守估算，不能保证磁盘故障时自动补偿成功；此时不要手动删除 `restore-state`、旧目录或唯一备份。

恢复日志还保留了本次恢复所用的脚本副本。如果切换到旧代码后 `luma restore recover` 不可用，使用 `bash /opt/luma/config/restore-state/restore.sh recover`；不要先更新代码或删除日志。数据目录与配置目录位于同一文件系统时，空间预检会合并计算数据库快照、暂存目录和恢复空间。`recover` 完成后需再次核对服务和数据；无法通过就绪检查时保持停机并保留所有快照。

旧版没有 `FORMAT` 的备份仍支持恢复，但它们是明文且 `SHA256SUMS` 不具备来源认证，必须来自可信位置，交互时需输入 `RESTORE LEGACY`。先运行 `luma backup migrate /opt/luma/backups/旧目录` 生成新的加密副本并验证，再考虑单独安全处置旧目录；脚本不会自动删除或覆盖。恢复要求备份的 `VERSION` 为当前 main 的祖先；跨版本时会切换到对应代码，避免只回退容器而保留新 schema。更新失败调用当前新版恢复脚本处理其备份，恢复旧代码、数据库、配置和文件。

## 更换服务器

1. 旧 VPS 上执行 `luma backup`，安全保存完整备份目录。
2. 新 VPS 运行安装命令，使用新的数据库和 Redis 密码。
3. 将**加密备份目录**复制到新 VPS 的 `/opt/luma/backups`。另行安全转移旧 VPS 的 `/opt/luma/config/.env`，暂存为 `/opt/luma/config/old.env`（权限 `600`）。备份不包含它，原 UserID HMAC 密钥与数据库必须成对保留。另行转移对应的 `backup-keys/<BACKUP_KEY_ID>.key` 到新服务器相同受限目录，或将离线恢复私钥临时置于权限 `600` 的文件中。不要通过聊天、工单或 Git 传输私钥。
4. 使用本地旧密钥时运行 `luma restore /opt/luma/backups/时间戳 /opt/luma/config/old.env`；使用离线私钥时在末尾追加其文件路径。脚本只导入原 UserID HMAC 密钥，保留新服务器的数据库和 Redis 密码。核对健康、账号、消息和附件后，安全处置临时配置与外部私钥文件。旧服务器确认停用后再切换 DNS，避免双端同时写入。

若新 VPS 的本地仓库没有备份对应提交，或备份提交不是当前 main 的祖先，恢复会停止，不会猜测 schema 兼容性。恢复完成后可按顺序执行 `luma update`。

## 常见问题与安全边界

- HTTPS 失败：检查 DNS、80/443、Caddy 日志和证书申请限制。不要关闭 TLS 校验。
- Backend 不健康：检查 PostgreSQL、Redis、migration 日志。不要在缺少数据库备份时手工修改 schema。
- 存储权限失败：密文目录应由容器 UID 10001 持有。不要改成全员可写。
- `.env` 不进入 Git，且必须保持 600；更新和恢复时不要重置 UserID HMAC 密钥。Docker 管理员可读取容器环境与密文数据，应限制服务器 root 和 Docker 权限。
- 恢复私钥不得写入备份、日志、Git 或普通工单；旧版明文备份即使转换成加密副本，原目录仍需单独处置。备份不会保护数据库中服务器本来可见的关系、时间等元数据免受运行中 VPS 失陷者读取。
- 如曾使用旧版 `luma_pgdata` 命名卷，脚本发现新 PostgreSQL 目录为空时会停止，避免启动空数据库。先对旧卷做独立备份并迁移数据；不要直接删除旧卷。
- 部署日志不得主动输出 Token、私钥、消息正文或附件内容；不要把实际日志贴到公开渠道。
- 当前没有 APNs 正式推送、生产双真机验收或独立安全审计。应用安全状态仍以客户端可验证的实际能力为准。
