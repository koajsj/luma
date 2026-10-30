# Luma 后端基础服务

这是独立的 Go 模块化单体。服务端接收每设备密文信封，保存路由元数据和密文，不能从现有 iOS 本机 v1/v2 消息直接得到可互通的线上消息。iOS v4 已在两个独立模拟器与隔离 HTTPS 服务完成文字及控制事件联调；实体设备和安全审计尚未完成，**当前不能宣称完整 E2EE 已可用**。

## 运行

- Go 1.27.3：`cd backend && go mod download && go run ./cmd/luma`
- 本地容器：先按 [本地联调指南](LOCAL_DEVELOPMENT.md)生成私有 `.env` 中的 `LUMA_USERID_HMAC_SECRET`，再执行 `cd backend && docker compose up --build`。示例仅绑定宿主机 `127.0.0.1:8080`，用开发凭据和明文 HTTP；不得直接对公网开放。
- Ubuntu VPS：使用仓库根目录的 [部署指南](../deploy/README_DEPLOY.md) 与独立 `deploy/docker-compose.yml`；由 Caddy 提供公网 HTTPS/WSS。
- 本地 iOS 联调见 [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)：使用可信开发 TLS、隔离 PostgreSQL/Redis、设备签名登录和双模拟器流程。Compose 已改用持久化本地密文卷，不再依赖 MinIO。
- 后端直接对外提供生产服务时必须设置 `TLS_CERT_FILE` 与 `TLS_KEY_FILE`。VPS Compose 则由 Caddy 终止公网 TLS；后端仅连接 Docker `internal` 私有网络，不映射宿主机端口，因此容器内显式设置 `LUMA_ALLOW_INSECURE_LOCAL=true`。严禁将该 HTTP 监听器直接暴露公网。生产还需监控、离机备份及证书管理。
- 必需：`DATABASE_URL`、`LUMA_USERID_HMAC_SECRET`（独立随机 32 字节的 64 位十六进制表示）。密钥只通过环境变量注入，不能进入数据库、日志或 Git；恢复数据库必须恢复相同密钥。可选：`REDIS_URL`、`LOCAL_STORAGE_DIR`、`S3_ENDPOINT`、`S3_BUCKET`、`S3_ACCESS_KEY`、`S3_SECRET_KEY`、`S3_SECURE`、`LUMA_ADDR`、`MIGRATIONS_DIR`。`LOCAL_STORAGE_DIR` 为绝对路径并优先于 S3；两者均未配置时文件接口返回 `503`。PostgreSQL/Redis 缺失会阻止启动。
- 兼容模式默认 `LUMA_AUTO_MIGRATE=true`：启动时执行 `migrations/*.sql` 并补齐 UserID HMAC 索引。`luma migrate` 只执行这两步，不连接 Redis/存储、不启动 HTTP。显式设置 `LUMA_AUTO_MIGRATE=false` 后，API 只读校验 migration 版本集合与 HMAC 索引，并拒绝管理员/所有者、成员角色及 DDL 权限；缺迁移、缺索引或错误 HMAC 密钥均停止启动，不回退管理员连接。迁移不含自动降级。
- 独立运行角色授权模板见 [`ops/runtime-grants.sql`](ops/runtime-grants.sql)。它必须由管理员在专用 Luma 数据库上显式执行，不属于自动 migrations。默认 VPS Compose 已将 API 固定为 `luma_api`，迁移/授权为短时管理员任务；恢复后重新授权，旧版本回滚必须通过兼容门禁。现有卷首次切换和完整容器生命周期仍需隔离演练，不能宣称已在 VPS 验收。迁移、恢复和回滚的操作边界见[部署指南](../deploy/README_DEPLOY.md#数据库权限拆分)。

OpenAPI 见 [openapi/openapi.yaml](openapi/openapi.yaml)。所有受保护 HTTP 请求和 WebSocket 握手均要求 Bearer token 与设备 Ed25519 请求签名。具体签名文本见 OpenAPI `info.description`；`/auth/refresh` 使用 refresh token 同样签名。访问 token 15 分钟、refresh token 30 天，只持久化哈希，刷新时轮换并撤销旧访问 token；重放旧 refresh token 会撤销整个令牌家族。

当前在线协议仅接受设备签署的 `luma.request.v2` 请求证明；旧 v1 证明返回 401。新消息必须是 v4；编辑、删除、已读和有序 Reaction 仅走 `/v1/messages/v4/events`，旧在线写入接口已移除。历史 v1/v2/v3 内容仍由客户端受限读取，不将旧事件解释为 v4。此版本尚未发布，不维持前代客户端在线兼容；旧后端回滚不具备安全兼容性。设备签名不证明 App 二进制未被篡改。

注册使用独立的 Ed25519 设备认证公钥，P-256 身份公钥验证 Signed PreKey。新设备由已有设备和新设备双签名授权。服务器仍无法证明密钥目录未被恶意替换；正式 E2EE 需要客户端身份核验与经审计的协议。

## 数据与事件

消息发送校验当前好友关系、会话成员、所有活动目标设备及附件归属；消息、逐设备密文信封和逐设备连续序号事件在同一 PostgreSQL 事务中提交。WebSocket 推送事件提示，离线恢复以 `GET /v1/sync/events` 为准。事件可重复投递，客户端须在本地落盘后按序 ack。发送请求需稳定的 `messageID` 和 `Idempotency-Key`。

文件上传采用带设备认证的受控 API：声明密文大小与 SHA-256 → PUT 密文字节 → 服务端验证密文字节大小/哈希并完成。服务端无法鉴定上传字节是否真由客户端正确加密；下载后客户端必须校验哈希并自行解密。附件读取要求当前所有者或仍有好友关系且未屏蔽的会话成员；已删除消息的附件不再向非所有者开放。当前上限 100 MiB，不提供分片续传。

附件状态为 `pending → stored → verified → deleted`；旧数据库的 `complete` 继续可读。删除时先撤销数据库可见性，再删除密文对象与记录；启动及定时清理已删除对象和超过 10 分钟的未完成上传。对象存储与 PostgreSQL 仍无跨系统原子事务，清理失败会保留墓碑供下一次重试。

Presence 心跳与输入提示保存在 Redis TTL；在线状态只向已确认好友且 `showPresence=true` 的用户公开。APNs 只有 `push.Sender` 接口与通用通知常量，没有真实发送或推送 token 注册。删除消息形成服务器墓碑，不能保证已下载副本被抹除。

## 当前边界

这个基础服务未完成生产安全审计、双实体设备联调、可验证公钥目录、多设备密钥同步、完整 E2EE 协议、APNs 发送和附件分片上传。服务器可见 UserID、好友/会话关系、设备、时间、大小、IP 与在线心跳等元数据。日志不记录令牌、密文或请求体。

`GET /v1/friends` 返回已确认好友的路由 UUID。身份核对读取 v4 公钥束并验证账号对设备身份及预密钥的签名；`claim=false` 不领取一次性预密钥。注册/设备审批仍保留数据库所需的传统 Signed PreKey 字段；旧 v3 公钥查询与上传接口已移除。

v4 公开密钥目录使用 `PUT /v1/devices/{id}/v4-prekeys` 与 `GET /v1/users/{id}/v4-prekey-bundle`；后者 `claim=false` 只查看，默认事务领取一次性公钥。未就绪或 PreKey 耗尽的设备会跳过并计入 `X-Luma-Skipped-Devices`；没有可用设备返回 409，部分 Bundle 仍可能因发送端必须覆盖全部活动设备而无法发送。客户端在登记后上传账号身份签名绑定的设备 v4 公钥。服务端只保存公钥与密文信封，不持有 v4 私钥或 Ratchet 状态。完整字段见 [OpenAPI](openapi/openapi.yaml)。两个独立模拟器已通过本地后端联调；实体设备及独立安全审计尚未完成。

v4 编辑、删除、已读和 Emoji 操作走 `POST /v1/messages/v4/events`。服务端核对设备、会话、目标设备和 revision，并原子写入逐设备密文同步事件；客户端再用 Ratchet 验证操作者和内容。旧在线控制接口已移除。服务端可见事件类型、路由、时间和大小，不能验证密文内的操作内容。两个独立模拟器的控制事件闭环已通过；实体设备与故障注入联调仍未完成。
# 设备撤销增量

`DELETE /v1/devices/{id}` 撤销非当前设备的访问与刷新令牌，清除其服务端预密钥，并在同一数据库事务中给仍有效的同账号设备追加 `device.revoked` 游标事件。撤销后该设备的 HTTP 认证返回 `device_revoked`，WebSocket 连接关闭；事件仅携带被撤销设备 ID，不携带密钥材料。
