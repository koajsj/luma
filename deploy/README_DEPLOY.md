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

脚本克隆 main 到 `/opt/luma/app`，创建 `/opt/luma/data/postgres`、`redis`、`storage` 和 `/opt/luma/backups`，生成权限为 600 的 `/opt/luma/config/.env`。数据库管理员/API 独立密码、Redis 和 UserID HMAC 密钥由系统随机数生成，**不会输出到终端或提交到 Git**。`LUMA_JWT_SECRET` 仅为未来 JWT 预留；当前后端使用数据库支持的不透明 Token，不能把此变量描述为当前认证密钥。

服务由 Docker Compose 启动：PostgreSQL、Redis、Go Backend、Caddy。先运行短时 `migrate` 和 `db-grants` 任务，再启动只读校验 schema 的 API；Caddy 代理普通 HTTP 和 WebSocket。Redis 仅保存可重建的短期状态，不写持久化快照。客户端先加密附件，再上传到 `/opt/luma/data/storage/ciphertext`。服务器仍可见账号、设备、时间、大小等元数据。

部署网络固定使用 `172.31.251.0/24`，Caddy 在内部网络使用 `172.31.251.2`。后端只信任此地址转发的单个客户端 IP，Caddy 会覆盖客户端提供的 `X-Forwarded-For`。若 VPS 上已有重叠 Docker 网络，须在部署前同步修改 Compose 中的网段、Caddy 地址及 `LUMA_TRUSTED_PROXY_IP`，保持三处一致。

域名模式进程检查地址为 `https://你的域名/health`，就绪检查地址为 `https://你的域名/ready`；IP 测试模式使用 `http://VPS_IP` 加相同路径。正常结果为 `{"status":"ok"}`。部署和更新以 `/ready` 为准，它只返回通用状态，不公开 PostgreSQL、Redis 或存储的错误详情。WebSocket 地址为相同域名下的 `wss://你的域名/v1/ws`，需要有效设备认证；未经认证的直接访问被拒绝是预期行为。

## 日常管理

安装完成后可执行：

| 命令 | 用途 |
| --- | --- |
| `luma status` | 查看容器和 HTTP 健康状态 |
| `luma logs` | 查看最近 100 行后端日志；`luma logs caddy` 查看代理日志 |
| `luma update` | 先备份，拉取 main，重建并检查健康；失败时恢复旧代码、数据库和文件 |
| `luma backup` | 停止写入并流式加密；local 模式解密校验，offline 无私钥时须异地校验 |
| `luma backup migrate /opt/luma/backups/旧目录` | 验证旧明文备份并生成独立的 `.encrypted` 加密副本；原目录不变 |
| `luma backup-key rotate` | 轮换后续备份的本地接收密钥；旧私钥保留供旧备份恢复 |
| `luma restore /opt/luma/backups/时间戳` | 先认证和校验，确认后替换数据库与密文目录 |
| `luma restore recover` | 中断后用加密的原数据库快照、原配置和旧目录恢复旧服务 |
| `luma domain change [新域名]` | 修改域名、启动 Caddy、检查 HTTPS；失败时恢复旧配置 |
| `luma rollback [备份目录]` | 确认后先备份当前版本，再恢复较早的代码与对应数据 |

备份存在 `/opt/luma/backups`，不自动删除。加密格式 `FORMAT=2`（offline 标识需新版恢复脚本）：`postgres.dump.age` 和 `storage.tar.gz.age` 用 `age` 的原生接收者加密格式保护，`MANIFEST.age` 认证版本、UserID HMAC 密钥标识、密钥标识和两份密文的 SHA-256。备份目录仅含加密数据和非秘密元数据，不含 `.env` 或私钥。`age` 自行生成随机文件密钥并认证密文；脚本不自行实现密码学。备份期间短暂停止后端与 Caddy 以固定数据库和密文目录；备份前请等待大文件上传完成。回滚会覆盖备份后新增数据，更新和手动回滚都会先备份当前状态。

### 备份密钥：选择恢复便利性或离线隔离

默认 `LUMA_BACKUP_KEY_MODE=local`，保持旧安装兼容：首次备份在 `/opt/luma/config/backup-keys` 生成本地私钥（目录 `700`，文件 `600`），允许无人值守更新失败自动回滚。额外配置 `LUMA_BACKUP_RECIPIENT=age1...` 只会增加一个可独立解密的接收者，**不会撤销本机解密能力**。整台 VPS 失陷仍可能同时泄露旧备份与本机私钥。

需要把新备份的解密能力移出 VPS 时，人工选择 **offline 模式**：

1. 在独立可信电脑生成原生 age 密钥：`age-keygen -o luma-recovery.key`。加密保管私钥和至少一份独立恢复副本。运行 `age-keygen -y luma-recovery.key` 取得公钥；只把公钥复制到 VPS。
2. 在 VPS 私有 `/opt/luma/config/.env` 设置下面两项（保持 `600` 权限）：

   ```dotenv
   LUMA_BACKUP_KEY_MODE=offline
   LUMA_BACKUP_RECIPIENT=age1...你的真实公钥...
   ```

3. 执行 `luma backup`。新备份仍是 `FORMAT=2`，`BACKUP_KEY_ID` 使用 `offline-公钥SHA256` 标识；只加密给此公钥，不生成或使用本机接收私钥。配置无效、与保留的本机私钥相同会拒绝，不回退 local。无人值守备份可运行，但没有私钥时只能检查转储/归档及加密命令是否成功，**不能完成解密恢复校验**；控制台会明确提示。
4. 将完整备份复制到独立电脑，使用同版本的 `deploy/backup-format.py` 验证。示例（`backup` 是本地备份目录，已有 age、Python 和 PostgreSQL 客户端工具）：

   ```bash
   set -o pipefail
   age -d -i luma-recovery.key backup/MANIFEST.age | python3 deploy/backup-format.py verify-manifest backup
   age -d -i luma-recovery.key backup/postgres.dump.age | pg_restore -l >/dev/null
   age -d -i luma-recovery.key backup/storage.tar.gz.age | python3 deploy/backup-format.py verify-storage >/dev/null
   ```

   全部成功后再标记该备份为已验证。独立保管备份清单摘要和版本，不把仅由 VPS 提供的哈希视为可信来源证明。age 提供密文完整性，任何持有公钥的人都能创建新归档，**不提供备份来源签名**。离线密钥与可信恢复副本丢失后无法找回备份。

旧备份及旧本机私钥不会被移动、删除或轮换。它们仍可恢复，但其原有同机泄露风险不会因新模式消失。确认所有旧备份已在独立电脑恢复验证并保存对应私钥后，才由管理员安排将旧私钥移出 VPS；本脚本不执行这项不可逆操作。旧版明文迁移命令保持可用，生成副本，不覆盖原目录；已有 FORMAT=2 旧备份保持原样。后续更换离线公钥只影响未来备份，须保留所有旧私钥；`luma backup-key rotate` 在 offline 模式会拒绝。

### offline 模式的维护与中断恢复

没有离线私钥时，`luma update` / `luma rollback` 在备份、拉取代码及数据替换前停止；`luma restore` 在替换数据前停止。不可能同时做到“VPS 无解密能力”和“VPS 无人值守解密回滚”。

维护时，在确认 VPS 可信后通过受控渠道**临时**将必要私钥送入内存文件系统（例如 `/run/luma-maintenance/identity`，目录 `700`、文件 `600`）。脚本用 `findmnt` 强制要求 tmpfs/ramfs，并拒绝活动 swap；不会自动关闭交换空间或改变服务器配置。只通过进程环境传入**文件路径**，不把私钥或路径写入 `.env`：

```bash
LUMA_BACKUP_IDENTITY=/run/luma-maintenance/identity luma update
# 或 rollback / restore；只能选择本次要执行的一项
LUMA_BACKUP_IDENTITY=/run/luma-maintenance/identity luma restore /opt/luma/backups/时间戳
```

脚本先用随机探针验证当前策略确实可解密补偿快照，再开始维护；目标备份另做完整预检。跨密钥恢复需在临时 identity 文件中提供当前补偿快照和目标备份所需的全部私钥（age 支持逐行多 identity）。旧版恢复的第三个私钥路径参数仍兼容；offline 备份的该路径同样必须为内存文件系统。

一般失败会尝试补偿。断电、SIGKILL 或私钥已移走时，保持服务停止，重新向内存目录临时提供同一所需私钥，然后执行：

```bash
LUMA_BACKUP_IDENTITY=/run/luma-maintenance/identity luma restore recover
```

在恢复成功、就绪检查通过且确认无 `restore-state` 后，管理员删除**本次临时** identity；不要删除恢复日志、旧密文目录或旧备份。脚本不会删除管理员提供的私钥。内存目录重启后消失，因此不能承诺无人工介入的主机断电补偿。root 入侵、运行时内存读取、休眠/转储及维护时窃取仍在威胁范围；tmpfs 不是硬件隔离，也不承诺完全擦除内存。应禁用该维护目录的采集、休眠及系统转储。

恢复到不支持 offline 模式的旧代码后，旧脚本可能忽略新配置并重新使用本机密钥；再次运行备份/更新自动化前，必须先审核并安装支持 offline 的维护脚本。备份中没有私钥和 `.env`，跨服务器还需另行保管原 UserID HMAC 密钥。

恢复先认证 `MANIFEST.age`、校验密文哈希和完整的数据库/附件归档，再检查 UserID HMAC 密钥、代码祖先版本和磁盘可用空间，最后要求输入 `RESTORE`。数据替换前会停止对外服务，并把原数据库流式加密成 `/opt/luma/config/restore-state/previous-db.age`，保留原配置及旧密文目录，直到新服务通过 `/ready`。INT/TERM 或一般命令失败会尝试补偿；补偿失败时停止后端和 Caddy，保留恢复状态与原数据。主机断电或 SIGKILL 后，**先保持服务停机**，运行 `luma restore recover`，成功并确认 `/ready` 后才能再次备份或更新。磁盘空间预检只提供保守估算，不能保证磁盘故障时自动补偿成功；此时不要手动删除 `restore-state`、旧目录或唯一备份。

恢复日志还保留了本次恢复所用的脚本副本。如果切换到旧代码后 `luma restore recover` 不可用，使用 `bash /opt/luma/config/restore-state/restore.sh recover`；不要先更新代码或删除日志。数据目录与配置目录位于同一文件系统时，空间预检会合并计算数据库快照、暂存目录和恢复空间。`recover` 完成后需再次核对服务和数据；无法通过就绪检查时保持停机并保留所有快照。

旧版没有 `FORMAT` 的备份仍支持恢复，但它们是明文且 `SHA256SUMS` 不具备来源认证，必须来自可信位置，交互时需输入 `RESTORE LEGACY`。先运行 `luma backup migrate /opt/luma/backups/旧目录` 生成新的加密副本并验证，再考虑单独安全处置旧目录；脚本不会自动删除或覆盖。恢复要求备份的 `VERSION` 为当前 main 的祖先；跨版本时仅切换到支持独立数据库账号的对应代码；更早的归档须按下文显式保留当前代码恢复，不能重新让 API 使用管理员。更新失败调用当前新版恢复脚本处理其备份，恢复旧代码、数据库、配置和文件。

## 更换服务器

1. 旧 VPS 上执行 `luma backup`，安全保存完整备份目录。
2. 新 VPS 运行安装命令，使用新的数据库和 Redis 密码。
3. 将**加密备份目录**复制到新 VPS 的 `/opt/luma/backups`。另行安全转移旧 VPS 的 `/opt/luma/config/.env`，暂存为 `/opt/luma/config/old.env`（权限 `600`）。备份不包含它，原 UserID HMAC 密钥与数据库必须成对保留。local 备份可另行转移对应的 `backup-keys/<BACKUP_KEY_ID>.key` 到新服务器相同受限目录；offline 备份只临时提供内存文件系统中的私钥，按上文配置 offline 策略并检查 swap，不能把私钥复制到持久磁盘。不要通过聊天、工单或 Git 传输私钥。
4. 使用本地旧密钥时运行 `luma restore /opt/luma/backups/时间戳 /opt/luma/config/old.env`；使用离线私钥时在末尾追加其文件路径。脚本只导入原 UserID HMAC 密钥，保留新服务器的数据库和 Redis 密码。核对健康、账号、消息和附件后，安全处置临时配置与外部私钥文件。旧服务器确认停用后再切换 DNS，避免双端同时写入。

若新 VPS 的本地仓库没有备份对应提交，或备份提交不是当前 main 的祖先，恢复会停止，不会猜测 schema 兼容性。恢复完成后可按顺序执行 `luma update`；offline 模式仍需临时恢复私钥。

## 常见问题与安全边界

- HTTPS 失败：检查 DNS、80/443、Caddy 日志和证书申请限制。不要关闭 TLS 校验。
- Backend 不健康：检查 PostgreSQL、Redis、migration 日志。不要在缺少数据库备份时手工修改 schema。
- 存储权限失败：密文目录应由容器 UID 10001 持有。不要改成全员可写。
- `.env` 不进入 Git，且必须保持 600；更新和恢复时不要重置 UserID HMAC 密钥。Docker 管理员可读取容器环境与密文数据，应限制服务器 root 和 Docker 权限。
- 恢复私钥不得写入备份、日志、Git 或普通工单；旧版明文备份即使转换成加密副本，原目录仍需单独处置。备份不会保护数据库中服务器本来可见的关系、时间等元数据免受运行中 VPS 失陷者读取。
- 如曾使用旧版 `luma_pgdata` 命名卷，脚本发现新 PostgreSQL 目录为空时会停止，避免启动空数据库。先对旧卷做独立备份并迁移数据；不要直接删除旧卷。
- 部署日志不得主动输出 Token、私钥、消息正文或附件内容；不要把实际日志贴到公开渠道。
- 当前没有 APNs 正式推送、生产双真机验收或独立安全审计。应用安全状态仍以客户端可验证的实际能力为准。

## 数据库权限拆分

### 默认运行路径

Compose 中长期 Backend 只收到 `luma_api` 的 `LUMA_DATABASE_RUNTIME_PASSWORD`，固定 `LUMA_AUTO_MIGRATE=false`；没有 PostgreSQL 管理员密码或备用迁移 URL。PostgreSQL 本身仍保留原初始化管理员 `luma`。短时 `migrate` 使用该账号执行迁移/HMAC 补齐，短时 `db-grants` 创建/校验独立运行角色并应用权限模板，再允许启动 API。保留原数据库/表所有权，不做 REASSIGN OWNED，不重建已有卷。

新安装由脚本自动生成独立的 32 字节十六进制 API 密码，权限 `600`。已有 `.env` 仅在显式运行 `deploy.sh` 且字段缺失时补充新 API 密码；不会更换管理员、HMAC、age 密钥或旧密码。发现既有 `luma_api` 拥有对象、角色成员关系、管理权限或异常 ACL 时拒绝，不静默降权覆盖。不要将它用于其他应用共享的数据库。

首次从旧部署迁入：先在隔离环境演练并用**原版本维护工具**完成可验证备份，妥善保管原 `.env`/age 材料；再经人工审核更新代码，执行 `bash deploy/deploy.sh`。新脚本会先构建、停止 API/代理，再迁移和授权；失败则保持停机，保留原数据/配置并人工排查，不退回管理员 API。旧版 `luma update` 不具有此迁移保证，不得将它当自动升级路径。未经隔离演练不要对现有生产卷执行。

`start_services` 每次明确重跑迁移/授权，避免恢复后复用已退出容器的旧“成功”状态；失败阶段不会启动 API/代理。正常备份退出和域名切换仅恢复现有 API/代理，不在在线服务期间意外执行迁移。默认依赖链也支持首次 `docker compose up -d`；手工重启不能替代恢复后的重新授权。

### 权限与恢复边界

迁移账本只读，运行角色无 DDL、TRUNCATE、角色继承或所有权；不授权预留推送表、当前无需的序列及未来表。新 migration 须同步审阅 `backend/ops/runtime-grants.sql`。它是表级 DML 最小化，不是逐用户 RLS，API 对象权限检查仍不可缺少。

备份仍由维护进程用 `luma` 管理员转储，不给 API 开放备份权限。恢复/补偿继续以 `luma` 还原 `--no-owner --no-acl`，随后必须重跑 `migrate`、`db-grants`，通过 API 和代理就绪检查后才清理旧快照。管理员/运行角色密码不在归档内，换 VPS 使用新随机密码；原 UserID HMAC 和 age 恢复材料继续单独保管。

回滚/恢复在任何数据替换前检查目标 Compose 支持独立账号，拒绝回到管理员 API 的旧代码。补偿日志指向旧管理员版本时同样暂停，不先重写代码/配置/数据库；应保留原快照，在隔离环境审阅旧日志及对应工具后人工处理。停止命令失败会明确报告状态未知，不声称服务已停。旧归档不删除也不覆盖：如需从权限拆分前的归档恢复，在隔离环境先验证代码/schema 兼容，然后显式执行：

```bash
LUMA_RESTORE_KEEP_CODE=1 luma restore /opt/luma/backups/旧时间戳
# 交互输入 RESTORE CURRENT CODE；跨服务器仍按原参数提供旧 env/离线私钥。
```

该选项仅保留当前代码，不跳过 age、哈希、HMAC、磁盘空间、备份版本格式或恢复确认；更高 schema 不能因它而被旧 API 接受。任何失败仍用原代码/配置/数据库快照/旧文件目录补偿；不得为了启动而改回管理员连接。恢复失败保留 `restore-state`，按原恢复步骤处理。

已在临时 PostgreSQL 17 验证真实授权脚本、拒绝权限、dump/restore 后重新授权；脚本阶段失败有本地控制流回归。**尚未运行 Docker/Ubuntu 的完整 install/update/restore/rollback 故障注入，不能把静态 Compose 检查视为容器部署验收。** 对旧卷的实际切换继续保留人工门禁。

### 自定义账号（非默认 Compose）

直接运行二进制时，`luma migrate` 接收短时迁移连接；长期 API 仅传运行连接并设置 `LUMA_AUTO_MIGRATE=false`。可自行准备非超级用户的专用数据库所有者 `luma_migrator` 与无所有权/成员关系的 API LOGIN 角色；使用 `psql` 的 `\password` 或秘密管理器设置密码，不放命令参数或 Git。

管理员显式应用同一模板：

```sh
psql -X -v ON_ERROR_STOP=1 -v database=luma \
  -v migration_role=luma_migrator -v runtime_role=luma_api \
  -f backend/ops/runtime-grants.sql
```

只有实际迁移角色拥有全部已知对象时才能使用此例；默认部署保持原所有者 `luma`，不要直接替换此参数或全局 REASSIGN。模板拒绝异常所有权、未知表和既有隐藏列级授权；当前 UUID schema 不需序列，新增对象必须另行审阅权限。自定义恢复也须恢复到正确所有者后再授权，不能把备用管理员 URL 传入 API。

## 隔离 Ubuntu 生命周期验收（待执行）

以下用于专门的可销毁 Ubuntu 22.04/24.04 VM，不是生产运维指令，也不表示已经通过。使用合成账号/文件/密钥、独立磁盘、网络及快照；不得挂载宿主机现有 `/opt/luma`、真实备份或生产 Docker socket。每个破坏性场景从 VM 快照重建，不能在唯一恢复副本上实验。

**版本前提**：固定包含待验收修改的已评审提交和旧版对照提交，记录 SHA、Ubuntu/Docker/Compose/PostgreSQL 版本。当前未提交改动不能用远端 main 的安装结果替代验收；旧安装迁入必须先验证旧工具生成的备份，再切换到待验收代码。不要为绕过版本门禁把已有测试或生产目录 reset 为另一版本。

在隔离 VM 中可定义下面的只读检查入口（不要使用 `compose config` 无参数或打印整个容器环境，避免泄露插值后的密码）：

```bash
dc() { sudo docker compose --env-file /opt/luma/config/.env -f /opt/luma/app/deploy/docker-compose.yml "$@"; }
dc config --quiet
dc ps -a
dc exec -T backend sh -c 'test "$LUMA_AUTO_MIGRATE" = false && test -z "${POSTGRES_PASSWORD+x}" && case "$DATABASE_URL" in postgres://luma_api:*) exit 0;; *) exit 1;; esac'
dc exec -T postgres psql -X -U luma -d luma -v ON_ERROR_STOP=1 <<'SQL'
SELECT rolname,rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls
FROM pg_roles WHERE rolname='luma_api';
SELECT has_database_privilege('luma_api','luma','CREATE') AS database_create,
       has_database_privilege('luma_api','luma','TEMP') AS database_temp,
       has_schema_privilege('luma_api','public','CREATE') AS schema_create,
       has_table_privilege('luma_api','public.schema_migrations','UPDATE') AS ledger_update;
SELECT version FROM schema_migrations ORDER BY version;
SQL
```

上面的角色属性及四个权限应全为 `false`，迁移集合应与固定提交的 migration 一致；不能只看 API 能启动就判权限正确。现有 `TestRuntimeRoleBoundary` 覆盖的实际 DML/禁止权限及 dump/restore 后重授权不需在每轮开发重复执行，但容器镜像与已有卷切换仍须如下验收。

| 场景 | 隔离环境步骤 | 必须观察到的结果 |
| --- | --- | --- |
| 新安装 | 固定测试版本执行安装，选择 IP 模式仅做无凭据健康检查；另用隔离测试域名/受信测试 CA 检查 TLS/WSS | `migrate`、`db-grants` 成功退出后 API/代理才就绪；`/health`、`/ready` 均正常。IP HTTP 成功不算 HTTPS 或认证通过。 |
| 旧数据卷迁入 | 旧版写入合成账号、密文消息/附件，验证备份可解密；保存数据卷/配置快照，再显式运行新版 deploy | 原账号/表所有权及 HMAC/age 材料不变；仅增加运行口令。相同密文/行数可读，API 为 `luma_api`；失败保持停机，不退回管理员 API。 |
| 迁移/授权失败 | 在 VM 分别制造不可用迁移和异常运行角色 ACL；运行维护入口，检查进程退出码 | 任一步失败不启动后续 API/Caddy；原数据和可用备份保留，异常权限不静默覆盖。人工修复后从同一状态续办。 |
| 更新与自动补偿 | 从支持权限拆分的旧测试提交运行 `luma update`；分别在构建、迁移、授权、readiness 阶段制造失败 | 新版成功须 ready；失败恢复同一旧代码/配置/数据库/附件组合，恢复后重新授权。比较行数、密文摘要、版本和 API 角色；失败仍返回非零。 |
| local/offline 备份 | local 模式创建并独立解密；offline 模式只配置外部公钥创建新归档，维护时按本指南临时提供内存私钥 | 归档不含 `.env`/私钥；旧钥可恢复旧归档但不能解密新 offline 归档。offline 无私钥时 backup 可加密，update/restore/rollback 在破坏性操作前拒绝。 |
| 恢复预检 | 在副本上分别用错误 identity、篡改密文、删必要文件、制造空间不足；执行 restore | 非零退出；现有数据库/storage/config 摘要不变；不删除原归档或旧钥，不进入破坏性阶段。 |
| 恢复中断 | 在日志持久化、原库快照验证、`db-mutating`、`storage-mutating`、就绪检查后等边界分别发送 TERM；另从 VM 快照做 SIGKILL/重启 | 要么整体完成，要么完整补偿，要么对外停机并保留 `restore-state`、原库加密快照及旧 storage。按 `luma restore recover` 续办；缺离线密钥时保持门禁，不能半库半文件运行。 |
| 回滚/旧归档 | 新版回滚到支持权限拆分的已备份测试提交；再尝试旧管理员 API 提交；单独验证 `LUMA_RESTORE_KEEP_CODE=1` 恢复旧归档 | 兼容回滚保持四者一致，重新授权并 ready；不兼容代码在数据替换前拒绝。保留代码恢复旧数据仍做版本/完整性/HMAC/空间检查。 |
| 进程异常及服务依赖 | 单独暂停/恢复 PG、Redis、API，重启 VM；中断维护时再重启 | `/health` 只表示 API 进程，依赖失败 `/ready` 为通用 503、无内部错误；维护中断须先显式 recover，不能仅凭容器 running 判成功。 |
| 网络与其他应用隔离 | VM 内另建合成服务和冲突网段/占用端口；外部测试节点扫描 VM 端口 | 拒绝网段冲突，不停止其他服务；PG/Redis/8080 不可从外部直连。发现端口冲突停止排查，不自动杀占用进程。 |
| 文件、WebSocket 和恢复后认证 | 用隔离测试客户端发送密文文件、下载校验、未授权下载及撤销；建立 WSS、断网重连后 cursor sync | 密文哈希一致、未授权拒绝、撤销旧连接失效、无重复事件；新角色有必要 DML。日志/通知不得出现正文、文件名、密钥或 Token。 |

只记录提交、阶段、退出码、行数、密文摘要及权限断言；不要把 `docker inspect` 完整输出、`.env`、dump、Token 或设备密钥贴进报告。Docker restart 不会执行 Shell 恢复日志；存在 `restore-state` 时继续维护前必须按恢复门禁处理，需检查对外停机是否实际维持。出现日志与服务状态不符、旧配置未恢复或任一数据组合不一致即阻塞发布，保留 VM 证据供排查。

真实 iOS、Face ID、目录证明与独立审计的验收要求统一记录在[安全治理报告](../Documentation/Security/Privacy_Boundary_Governance_2026-10-22.md#外部安全验收门槛待执行)，不以本章的 VM/逻辑设备测试代替。
