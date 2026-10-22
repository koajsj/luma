# 本地安全边界治理记录（2026-10-22）

基线：本地 `main` 为 `af6c5293`，远端跟踪分支为 `96676678`；工作区原有修改全部保留。以当前源码为准；`Source_Audit_2026-10-22.md` 的四类修复在本地仍存在，Recovery 配置保持默认关闭。本轮未合并、发布或操作 VPS。

## 服务端实际可见范围

按 `backend/internal/auth`、`user`、`friend`、`device`、`message`、`sync`、`file`、`presence` 与 iOS `RemoteAuthProvider`、`RemoteMessageRepository` 的字段和调用链核对：服务器保存 UserID、昵称、身份与设备公钥、好友和会话关系、设备路由、消息时间/版本/大小、已读及编辑等事件元数据、在线心跳/IP、令牌哈希、消息密文、附件密文及其大小和哈希。推送令牌表可见设备关联；当前未验证真实 APNs 发送。

注册/登录请求没有本地密码、PIN 或 Face ID 数据。v4 消息和附件在客户端加密；文件初始化请求只有密文大小及哈希，不传文件名。服务端表没有私钥或 Master/Session/Message/Attachment Key 字段；当前检查的日志调用未输出令牌、密文或私钥。以上是源码边界，不等于恶意服务器、被攻陷客户端或部署环境的独立安全证明。

## 已修复且完成定向验证

- 之前的 Ratchet journal 清理、Recovery OTP tombstone/索引恢复和 Refresh Token 家族撤销：代码与前次审查记录一致；本轮未重复构建或全量测试。其验证范围见 `Source_Audit_2026-10-22.md`。

## 已修复，仍需隔离环境验证

- 好友申请与屏蔽并发：`backend/internal/friend/friend.go` 在同一事务取得双方 advisory lock 后检查 block 并插入申请，防止申请在屏蔽检查之后抢先写入。接受申请改为先取得用户对锁、再重新检查并锁定申请行，避免反向锁序死锁；移除好友也使用用户对锁。需使用隔离 PostgreSQL 验证真实并发顺序。
- S3 缺失对象下载：`backend/internal/file/storage.go` 在返回对象流之前执行 `Stat`，使授权后的对象存储错误能在 HTTP 200 写出前被处理。需使用隔离对象存储验证缺失对象和故障响应。
- VPS 固定网段：`deploy/deploy.sh` 在 Compose 启动前检查现有 Docker IPAM 网段与 `172.31.251.0/24` 是否重叠；只跳过带 Luma Compose 标签的自有网络。需在有其他 Docker 网络的隔离 Ubuntu 主机验证。

## 部分缓解与剩余边界

- 部署使用非 root 后端、仅私有 Docker 网络接入 PostgreSQL/Redis、本机文件目录 `0700` 和密文文件 `0600`。Compose 中固定网段和 80/443 端口仍要求安装前检查现有服务；新检查只覆盖 Docker 网段，不覆盖主机端口占用。
- Compose 当前让后端使用 `luma` 数据库所有者凭据，运行态数据库权限尚未拆成迁移角色与最小权限应用角色。已有安装的角色与 migration 依赖该所有权；需要先设计兼容迁移和回滚，不能在本轮直接换凭据。可选 S3 存储的实际 bucket policy 由部署者管理，本轮没有隔离对象存储验收。
- VPS 新格式备份使用 `age` 分别加密 PostgreSQL 转储和密文目录，认证清单绑定代码版本、UserID HMAC 标识及密文哈希；密钥保存在 `/opt/luma/config/backup-keys`，不进入备份。轮换后旧私钥保留。旧版明文目录仍能显式恢复或转换为独立加密副本，原目录不会被脚本删除。恢复前执行认证、归档和空间预检，破坏性阶段以加密原库快照与持久状态标记补偿；INT/TERM 自动尝试恢复。此机制尚未在 VPS/隔离 PostgreSQL 上完整验收；完全失陷的 VPS 可同时暴露本地恢复私钥与数据库运行态元数据。离线额外接收者密钥可改善跨机灾备，不消除该风险。
- 本次复核发现恢复预检把同一文件系统的数据目录与配置目录当作两份独立空间，可能在恢复中途耗尽磁盘；已合并计算占用。恢复日志现保留脚本副本，避免代码切到旧提交后失去 `recover` 入口。错误私钥、密文单字节篡改和危险 tar 路径的隔离验证均被拒绝；完整 PostgreSQL 恢复、断电与补偿仍未在隔离服务中验收，不能标记为已充分验证。
- iOS Keychain 使用 `WhenUnlockedThisDeviceOnly`；Face ID 是应用解锁门禁，并非所有 Keychain 条目的独立生物识别访问控制。丢失唯一设备且没有预备恢复材料时，私钥可能无法恢复。内存清除不作保证。
- 本机退出登录曾只清除本地会话标记，仍保留在线 Access/Refresh Token；现已同步删除当前账号的本机 Token，并在已有账号流程测试中加入断言。离线退出无法保证即时撤销服务器端已签发会话；设备丢失仍应从其他已登录设备执行撤销，服务器端效果需真实后端验证。
- Redis 限流使用原子脚本；故障时返回 503。实际抗滥用仍依赖代理正确覆盖转发 IP、网络层限速与独立环境验证。
- 服务器能够延迟、丢弃、排序事件，并可观察关系及时间元数据；客户端身份固定与事件认证不能证明恶意服务器不可阻断通信。旧版 v3 和历史编辑事件仍需独立兼容审查；不得静默降低 v4 验证要求。

## 需要协议升级或兼容迁移

- 若要进一步隐藏好友关系、会话路由、在线时间或 UserID，现有 API/数据库契约需要协议级隐私设计；不能通过删除必需索引字段完成。
- 旧协议历史读取与编辑事件的更强认证需先制定版本化兼容与迁移方案；本轮未更改 v3/v4 格式。

## 需要真实设备或独立密码学审计

- 两台真实设备的同时首次握手、Keychain 锁定与恢复、身份变化、设备撤销、断网重试及附件闭环。
- 独立审计 v4 握手、Double Ratchet、恢复控制消息及恶意服务器模型。当前不满足生产 E2EE 发布判断。

本轮最终验证：`go test ./internal/friend ./internal/file`、`go vet ./internal/friend ./internal/file`、`bash -n deploy/deploy.sh` 和 `git diff --check` 均通过。隔离数据库集成测试未配置，未验证事务并发的真实运行结果；未运行全量 iOS 构建、生产迁移或 VPS 部署。

## 本次追加核查与项目精简

- 再次核对服务端 `auth`、`user`、`friend`、`device`、`message`、`file`、`presence`、`sync`、WebSocket、SQL 迁移及客户端在线请求：公开昵称和 UserID、关系、路由、在线时间、IP、密文大小及文件哈希仍是服务端可见数据；没有确认新的明文附件名、客户端密码/PIN、私钥或对称密钥上传路径。该结论限于所查源码，未覆盖真实流量和运维日志。
- 已修复且完成定向验证：备份格式对错误密钥、篡改密文和路径穿越归档拒绝；原有 Ratchet、Recovery 和 Token 修复沿用上述已有验证记录，本次没有重复运行全量测试。
- 已修复但尚未充分验证：恢复空间预检和跨版本恢复脚本保留；通过 Shell 语法与静态流程检查，缺少隔离 PostgreSQL/Docker 下的故障注入。
- 部分缓解：本地 `age` 私钥支持无人值守回滚，但 VPS 完全失陷时不能保护同机备份；另行保管离线恢复私钥并限制服务器权限仍属必要运维措施。
- 需要协议升级或兼容迁移：现有 API 暴露必要关系与时间元数据，历史 v3/旧编辑事件的认证边界不能靠删除字段解决。
- 需要真实设备、隔离服务或独立密码学审计：两台设备的 Recovery、锁定 Keychain、设备撤销、隔离数据库恢复和完整 E2EE 安全结论。
- 测试精简复核：Ratchet、Handshake Recovery、PreKey、Token、备份、权限和并发测试各有独立场景；本次没有证据支持删除。`storage_test.go` 是不依赖 PostgreSQL 的路径约束与磁盘往返测试，`file_integration_test.go` 验证数据库授权/生命周期且无隔离 DSN 时跳过，两者并不重复。未新增大规模测试套件，已移除本轮生成的 Python 字节码缓存。
- 本次实际检查：受影响的部署 Shell 脚本 `bash -n`、`git diff --check` 通过；隔离样例的 `age` 解密、错误密钥、密文篡改、危险 tar 路径及空间预检边界通过。iOS 只运行 `LocalFoundationTests.testLocalAccountAndChatUserFlow`：首次禁用代码签名时 Keychain 返回 `-34018`，改用模拟器本地签名重跑后 1 项通过。没有运行 Go 全量测试、隔离 PostgreSQL 恢复、Docker 或 VPS 操作。

## 后续治理：数据库权限与注销补偿

- 数据库最小权限仍需兼容迁移：`deploy/docker-compose.yml` 把 `POSTGRES_USER=luma` 的初始化账号及密码同时交给后端；PostgreSQL 镜像会使该初始化账号拥有管理员权限。`backend/cmd/luma/main.go` 又在 API 进程启动时执行 migration 和 UserID 索引补齐，不能仅替换连接串。安全拆分需要先将迁移移到独立的一次性任务，创建仅具所需表/序列 DML 权限的运行角色，并在新装、已有卷、备份恢复和旧版回滚中验证角色、默认权限与迁移顺序。当前没有隔离 PostgreSQL 恢复环境证明该路径，故未改生产部署凭据或执行 SQL；运行账号权限过大仍为未解决风险。
- 离线退出登录的本机 Token 仍立即删除；若存在服务器登记，先在本机 Keychain 留下**不含 Token** 的待撤销标记。在线退出及后续重试共用设备签名挑战，取得临时访问令牌后立即调用 `/auth/revoke` 撤销该设备全部会话。仅收到服务器成功响应才清除标记；失败时明确提示服务端会话未确认撤销。临时令牌不写入 Keychain。服务器不可达、设备认证私钥丢失或本地账号已删除时，远端会话仍可能持续到过期或由其他设备撤销；不能称为即时远端注销。
- `age` 备份私钥与自动回滚所需的备份数据仍在同一 VPS。额外的离线接收者公钥只增加异地恢复手段，**不会**让同机备份抵抗完整 VPS 失陷。若改为只由离线密钥解密，将失去现有无人值守自动回滚能力，必须另行设计、迁移并验证新旧备份恢复；本轮未删除旧私钥或改变备份格式。
- 已有 Ratchet、Handshake Recovery、PreKey、Token 重用、权限、并发和恢复测试的覆盖场景不重复，故未为减少数量而删除。只合并了新增注销路径中重复的设备挑战取令牌代码，并增加一项失败撤销后重试的定向回归测试；Recovery 继续默认关闭。
- 验证范围：iPhone 17 Pro iOS 26.5 模拟器先运行 `LocalFoundationTests.testLocalAccountAndChatUserFlow` 与 `testOfflineSignOutRetriesWithDeviceSignatureWithoutKeepingTokens`，2 项通过、0 失败；注销路径统一后再次定向运行后一项，1 项通过、0 失败。`git diff --check` 与改动 Swift 文件语法解析通过。前两次定向编译分别发现 `SecurityManager` 抛错表达式位置错误和已有设备页依赖 `localState()` 双元组，均修复后通过。未重跑 Go 全量测试、Docker、VPS、真实双设备 E2EE、完整隔离环境恢复或独立密码学审计。
