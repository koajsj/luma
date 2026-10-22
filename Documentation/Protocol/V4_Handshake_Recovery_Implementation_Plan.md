# v4 首次握手冲突恢复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution, or superpowers:subagent-driven-development if the user selects delegation. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不回退或替换已提交 Ratchet 的前提下，恢复新版双方同时首次握手，保全两端在途消息。

**Architecture:** 设备对协调记录选择唯一发送 proposal，独立候选记录保留已有 Ratchet。认证控制通过专用密文投递路径协调确认及落选链排空；Keychain 日志恢复跨存储提交。已有会话及历史读取走原路径。

**Tech Stack:** Swift / CryptoKit / Keychain / XCTest；Go / PostgreSQL / Redis；现有 Repository、SyncCoordinator。

**Spec:** [已确认设计](V4_Initial_Handshake_Conflict_Recovery.md)。本计划已获用户同意，实施与验证记录见 V4_Recovery_Execution_Log.md；不代表发布通过。

## Global Constraints

- 不重置、回退或覆盖已提交 Ratchet，不重新派生旧消息。
- `encryptionVersion=4`；新初始化显式使用 `protocolVersion=2`。legacy 已建立会话不转换。
- 每设备对、固定身份周期至多两个候选；UUID 原始 16 字节较小的发起设备获选。
- 未确认链至多 2,000 个待排空序号；不支持新版的设备失败关闭。
- 私钥、链材料及 journal 仅进入本设备 Keychain；控制端点只存密文。
- 不更改 UI 安全标识，不自动提交或推送，不触碰现有未提交修复及 `.claude/`。

## Review Focus

- 同一设备对跨多个 conversation：唯一协调状态，不按聊天分叉（任务 1、6）。
- 控制先于首条应用消息到达：使用同一签名 initial 和 skipped keys，不再次消费 PreKey（任务 3、5）。
- 本地已加密但服务器响应丢失：精确重试，冻结清单包含该信封（任务 3、6）。
- 部分 Keychain 写入或 cursor 已存后退出：恢复日志，不跳过失败认证（任务 2、6）。
- 旧冲突缺失原 initial 证据：保持暂停，不合成 proposal 或降级（任务 1、7）。

---

## 文件职责

| 文件 | 职责 |
| --- | --- |
| `Luma/Core/Crypto/V4Handshake.swift`、`V4DoubleRatchet.swift` | 新握手 transcript 与消息认证头；不替换 Ratchet 密钥算法 |
| 新 `Luma/Core/Crypto/V4HandshakeRecovery.swift` | 编码、proposal 标识、确定性选择、纯状态迁移验证 |
| 新 `Luma/Core/Crypto/V4HandshakeRecoveryVault.swift` | Keychain 协调、候选、高水位、OTP 绑定、冻结日志、控制 outbox |
| 新 `Luma/Core/Crypto/V4SessionControl.swift` | 确认/冲突/排空控制格式与证据验证 |
| `V4SessionVault.swift`、`V4MessageSessionService.swift` | legacy 分流、新候选提交与恢复集成 |
| `V4PreKeyService.swift`、`backend/internal/device/v4.go` | 签名能力发布与核验 |
| 新 `backend/internal/message/session_control.go`、`backend/migrations/007_v4_session_controls.sql` | 定向密文控制、授权及事务幂等 |
| `backend/cmd/luma/main.go`、`backend/openapi/openapi.yaml` | 注册控制端点及接口说明 |
| 新 `Luma/Core/Sync/RemoteSessionControlProvider.swift` | 控制上传和精确重试 |
| `RemoteMessageRepository.swift`、`RemoteSyncCoordinator.swift` | 收发选路、控制同步、提交与 cursor 恢复 |
| 新 `LumaTests/V4HandshakeRecoveryTests.swift` | 协议与故障注入回归 |
| 新 `backend/internal/message/session_control_integration_test.go` | 控制定向、权限、并发重试集成验证 |

## 任务 1：认证标识与纯协调状态机

**接口：** `V4RecoveryPair` 包含排序设备/账号及已固定身份；`V4ProposalID`、`V4ConflictID` 是 32 字节摘要。`V4HandshakeRecovery.winner(first:second:) throws -> V4ProposalID`；`validateTransition(from:to:evidence:) throws` 验证 revision、身份周期与前驱。

- [ ] 写失败测试：交换输入顺序 winner 不变；同发起端第二 proposal、第三候选、跨 pair、旧 revision、非法跳转全部拒绝。
- [ ] 固定新 transcript 字段顺序、UUID/整数编码；pair 身份周期以固定身份摘要定义，不引入本地时间 epoch。
- [ ] 扩展 initial 签名、HKDF info、message AAD，支持显式新版字段；保留原 legacy 编码字节路径。
- [ ] 测试：修改版本/pair/proposal/初始签名均失败；legacy 测试原样通过；跨 conversation 的 pair 相同。

## 任务 2：候选存储、CAS 与崩溃日志

**接口：** `V4HandshakeRecoveryVault.loadPair(pairID:)`、`stage(operation:)`、`finish(operationID:)`、`recover(pairID:)`；记录含前驱版本及精确后继摘要。每 proposal Ratchet 独立寻址；active 指针只能引用获选候选。

- [ ] 失败测试覆盖旧版本覆盖、同版本异内容、写一半重建 vault、重放 journal。
- [ ] 实现协调及候选高水位、事务阶段、OTP 的 proposal reservation/消费墓碑。认证失败不得建立 reservation。
- [ ] 将已提交 envelope 摘要和索号归属纳入日志；明确 prepared 请求的完成路径，不取消后释放序号。
- [ ] 每次 Keychain 写入后注入失败，重启恢复必须等价于一次提交；第二 proposal 使用同 OTP 拒绝。
- [ ] 添加纯同步临界区入口，处理同 pair 的发送/接收/冻结；网络 await 外执行，不跨 await 持有旧状态再提交。

## 任务 3：控制协议与冻结证明

**接口：** `V4SessionControl` 编码 confirm/confirm_ack、resolve(request/offer/commit)、resolve_ack、drain_ack；`V4FrozenManifest` 固定排序、分段摘要及 exclusive cutoff；`V4ControlVerifier.verify(control:context:) throws`。

- [ ] 测试完整正常确认与冲突 request→offer→ack→commit，缺前驱证据不能跳转。
- [ ] 实现身份签名的冻结证明、精确信封摘要、明确取消/烧号项目；冻结清单不能取消已认证或待发的消息。
- [ ] 控制使用 winner 原 Ratchet，未确认的 initiator 信封保留同一 initial；确认后不再附带 initial。
- [ ] 测试延迟、乱序、重复控制及缺段清单；同 ID 异内容、伪造 cutoff、篡改 conflict、跨设备重放拒绝且状态不变。
- [ ] 达到 2,000 索号后暂停派生并保留加密发送意图；不得丢弃旧请求或超时重建。

## 任务 4：签名能力与后端定向投递

**接口：** `POST /v1/sessions/controls` 请求包含 controlID、conversationID、receiverDeviceID、encryptionVersion、opaque envelope。调用方身份由 token 得出；客户端控制签名和内层认证不由服务器代替。

- [ ] 集成失败测试：非成员、block、撤销设备、disabled 账号、相同 ID 异请求拒绝；同 ID 并发同请求只产生一条事件。
- [ ] 增加能力签名 transcript 域：原设备绑定内容加 protocolVersion，上传/目录均保持 legacy 兼容；新版首次握手必须验证新版能力。
- [ ] migration 新建控制幂等表，外键关联发送/接收设备和 conversation，不改 messages/envelopes 字段。
- [ ] 事务内校验权限、锁定幂等 ID、写记录与定向 `session.control` Sync Event；提交后通知。
- [ ] 注册路由，补 OpenAPI；检查移除能力、未知能力、伪造绑定不能触发 legacy 回退。

## 任务 5：Crypto 收发与选主接入

**接口：** 现有 `prepare` / `decrypt` 保留调用入口，内部按 legacy 或 recovery 路由；新增控制 prepare/apply 返回可持久化 operation，不在 crypto 层访问网络。

- [ ] 先写独立 A/B vault 测试：双方 durable initial 后按两个顺序交付，初始两条消息均可读、winner 一致。
- [ ] 新发起保存不可变 proposal；遇合法对端 initial 时创建独立接收候选，不写进现有 Session 键。
- [ ] 冻结 loser 本地派生权；获选 Ratchet 继续自身原状态。落选只接受冻结清单里的在途信封。
- [ ] 正常 responder 只确认对端 proposal，不另建本机 initiator；控制先到时可建立相同 proposal。
- [ ] 验证双向连续消息、乱序、重放、篡改；已建立会话收到任意新 initial 拒绝。
- [ ] 排空经认证后退休无用秘密并保留墓碑；缺少排空证明不删除候选。

## 任务 6：Repository、同步与恢复

**接口：** `RemoteSessionControlProvider.send(prepared:) async throws` 发送精确请求；`RemoteSyncCoordinator` 对 `session.control` 调用 Crypto 处理并完成日志后 ack，不产生气泡。

- [ ] 测试服务器收下但 HTTP 失败、断线重连、incoming journal 未完成、cursor 保存后退出。
- [ ] 扩展 encrypted outbox 调度控制请求；发送前复查身份和设备活动状态，控制优先但不阻塞 Sync 后续确认。
- [ ] 原消息持久化与 durable 控制排队完成后可提交该事件；认证或持久化失败不推进 cursor。
- [ ] 同一 device pair 多 conversation 复用唯一协调记录；跨多目标部分提交也保留已 seal 信封清单。
- [ ] 身份变化/设备撤销暂停并清理生命周期允许清理的记录，停止旧控制重试；账号删除包含新增 Keychain 命名空间。
- [ ] 用重建 vault/context/service 的测试证明重启后恢复精确请求，不重复派生消息密钥。

## 任务 7：完整验证与安全复查

- [ ] XCTest 保留既有 v1/v2/v3 与 established legacy v4 回归；旧冲突证据不足明确失败关闭。
- [ ] 执行 Debug / Release build、完整 Unit Tests；选择当时实际可用 simulator destination，输出日志在 `/tmp`。
- [ ] 执行 `go build ./...`、`go test ./...`、`go vet ./...`、`go test -race ./...`（cwd `backend/`）；使用隔离 PostgreSQL/Redis 跑集成，不能把环境跳过当成通过。
- [ ] 双独立逻辑设备通过实际 HTTP Backend 完成同时首次握手、双向消息和控制、断网重试、服务恢复；逐项保存无秘密的断言结果。
- [ ] 复查恶意服务器只能阻断投递、不能选主/伪造有效控制；测试降级、MITM、replay、单记录 rollback、非法状态迁移。
- [ ] `git diff --check`、敏感信息检查；确认没有私钥、plaintext、token 进入日志或新增文件。

## 任务 8：文档与发布判定

- [ ] 更新 Crypto/Protocol/Security：已实现状态、兼容策略、恢复机制和已知限制。
- [ ] 输出两台实体 iOS 设备同时首次发送、弱网、强制退出、设备重启、VPS 恢复的手动步骤；缺环境时保持未验证。
- [ ] 报告明确新建冲突是否恢复、legacy 证据不足范围、独立密码学评审情况。未经完整验证不宣称生产 E2EE 通过，不启用新安全文案。

## 执行与审阅

推荐在当前会话直接逐任务实施，避免并行修改共用 Crypto/Vault 接口。设计已经用户确认；本实施计划已按用户同意进入直接实施；以执行记录中的实际证据为进度依据。所有任务复用现有测试设施；不新增测试框架。保留本工作区其他未提交修改，不自行发布。
