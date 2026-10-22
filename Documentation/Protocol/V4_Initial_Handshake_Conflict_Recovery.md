# v4 首次握手冲突恢复设计草案

日期：2026-10-13。

**状态：2026-10-13 设计已获用户同意，恢复路径正在实现及验证，默认开关关闭；尚未经过独立密码学评审或实体设备/VPS 验收。** 本文不能作为发布验收或安全保证。legacy v4 继续拒绝冲突，不重置或覆盖任何 Ratchet；产品安全文案不变。已有未提交修复保持原样，本轮不提交 Git。

## 1. 目标与范围

解决两个已核验身份的设备，在互相收到第一条消息之前，各自创建并提交初始发送链的冲突。保留所有已提交消息、密文重试请求和 Ratchet 推进记录；最终只有一个允许发送应用消息的会话，其他候选仅接收冲突前的在途信封。

这不是修改 Double Ratchet 密钥算法。拟扩展握手身份绑定、信封认证头、会话选择、控制消息和持久日志。v1/v2/v3 历史读取不变；已建立的旧 v4 会话不自动转换。

“双方同一个会话”指相同 proposal ID 和配对的发送/接收链，**不是两端保存完全相同的 Ratchet 状态**。双方状态的角色、链和计数器必然不同。

## 2. 源码问题分析

### 2.1 当前首次握手完整流程

1. `V4PreKeyService` 将本设备 X25519 协商身份、Ed25519 签名身份、Signed PreKey 和 One-Time PreKey 公钥上传；长期 P-256 账号身份签名绑定设备 v4 身份。
2. Repository 先请求 `claim=false` 的公钥目录。存在未建立会话的目标设备时，再请求领取一次性公钥。后端 `V4Bundle` 通过事务、`FOR UPDATE SKIP LOCKED` 和 `claimed_at` 防止并发领取同一公钥。
3. 客户端验证固定的账号身份指纹、账号对设备身份的签名、Signed PreKey 签名与版本。公钥目录返回值本身不能替代身份核验。
4. `V4Handshake.initiate` 生成临时 X25519 密钥，以身份/临时密钥与对端身份、Signed PreKey、可选 One-Time PreKey 做 DH；HKDF 绑定带签名的握手 transcript。
5. `V4RatchetState.initiator` 创建发送链。`prepare` 为第一条消息认证初始握手头、设备/消息/会话路由、Ratchet 公钥和序号；每消息链推进产生新的密钥。
6. `prepare` 将精确请求和候选状态放入 Keychain journal，并将候选 `initialHeader` 清空。本地加密 outbox 保存后，`commitPreparedSend` 提交状态，网络重试复用同一密文。
7. Backend 校验好友、屏蔽、会话成员和活动目标设备集合，在同一 PostgreSQL 事务保存 message、逐设备 envelope、Sync Event。服务器不解释内层握手，也没有创建/选择客户端 Session 的 API。
8. 接收端验证外层路由和已固定身份。无本地 Session 时，验证初始头签名、设备/身份/预密钥绑定，创建 responder Ratchet，然后验证 AEAD。
9. 接收候选与明文暂存在本设备 Keychain journal；Repository 将正文重新以 Master Key 加密保存。消息与本地游标保存后完成 Ratchet 更新及一次性私钥清理，最后发送服务端 ack。重启依据已提交本地游标续办 journal。

### 2.2 冲突在哪一步，为什么触发拒绝

双方第 6 步均已提交自己的 initiator。A 发起的 proposal 与 B 发起的 proposal 使用不同临时密钥、不同一次性预密钥和不同共享秘密，不能直接合并链计数器或交叉解密。

`V4MessageSessionService.decrypt` 的已有 Session 分支要求 `envelope.initialHeader == nil`；双方初始消息均带该头，因此在执行对端握手或解密前抛出 `untrustedIdentity`。当前 Session 仅按 `(localDeviceID, remoteDeviceID)` 索引，没有 proposal 选择信息。

本轮重新运行 `testSimultaneousInitialSessionsFailClosed`：1 项通过，确认双方拒绝、原 `stateVersion == 1`；这项测试验证安全拒绝，**不代表冲突恢复已通过**。

### 2.3 绝不能覆盖的状态

- 已提交的 Root、发送/接收链、Ratchet 私钥、公钥、链序号和 skipped keys。
- Keychain 状态版本高水位，以及尚未完成的 incoming/outgoing journal。
- 已生成的 outbox 请求、幂等键和密文；发送失败不能退链或以同一消息 ID 重新加密。
- 已固定的账号/设备身份、已消耗或已绑定到一个 proposal 的一次性预密钥。
- 已应用的业务事件、消息 revision、已提交游标及重放墓碑。

直接 reset 会使已发消息无法解密，或者让旧状态重用消息密钥；“接受任意初始头”则让攻击者或旧消息反复创建新会话。两者均不可作为修复。

### 2.4 当前协议允许的扩展与限制

内层 JSON 在服务器看来是 opaque ciphertext，允许扩展认证头和本机 Keychain 编码，不必改变 messages/message_envelopes 的已有业务语义。外层消息 ID、会话、设备、版本和序号仍须与内层认证绑定。

现有 `/messages/v4/events` 只接受编辑、删除、已读和 Reaction，且必须绑定已存储的业务消息，不能把握手确认伪装成这些事件。`applyV4` 只接受 text/attachment 载荷。需要专用设备级控制投递路径和 Sync 类型，不能仅增加可被服务器伪造的路由标记。

现有单一 Session 记录必须扩展为“设备对协调记录 + 独立 proposal 记录”；把新 responder 写进旧 Session 记录仍然是禁止的覆盖。

## 3. 方案比较

| 方案 | 结果 |
| --- | --- |
| 固定一个设备为唯一发起者，禁止另一端首次发送 | 能避免新冲突，但限制离线首次发送，也不能保全已经同时发出的两条消息。不选。 |
| 将两个初始秘密混合成一个新 Root，直接换掉两条链 | 需要新的换钥协议；此前密文仍依赖原链。直接替换违反状态保护要求。不选。 |
| 保留候选、确定性选主、认证确认、关闭落选发送权 | **建议方案**。不回退任一已提交链，落选在途消息可继续解密；需要明确有限的接收排空状态和恢复日志。 |

必须区分：临时保留两个候选是恢复已有密文所需的兼容状态；同时允许两条链无限继续发送才是 Session 分叉。本设计禁止后者。如果要求磁盘上任何时刻也只能有一条 Ratchet，同时禁止丢消息、回退或重新加密，这些条件无法同时满足。

## 4. 身份、proposal 与认证编码

拟使用 `encryptionVersion=4`，另加 `protocolVersion=2` 表示冲突恢复扩展。旧 v4 没有该字段，归入 legacy 模式；不得把 legacy 缺字段默认为新版。

所有派生、签名和 AAD 使用固定顺序、长度前缀编码，整数编码固定为无符号大端，UUID 为 16 字节；不使用 JSON 键顺序或本地时间决定结果。

- `pairID`：SHA-256 的带域分隔 transcript，包含排序后的两端账号 ID、设备 ID、已固定的账号身份指纹与设备 v4 身份。设备对是会话作用域；同一对自身设备同步多个聊天时，不能按 conversation 分别选出不同会话。
- `sessionProposalID`：SHA-256(`luma.v4.proposal.v2` + pairID + protocolVersion + 完整新版初始握手 transcript)。包含发起设备、双方身份、临时公钥、Signed/One-Time PreKey 公钥和版本。不能由服务器或调用者随意指定。
- `conflictIdentifier`：SHA-256(`luma.v4.conflict.v2` + pairID + 排序后的两个 proposal ID)。双方独立计算。
- 新版初始签名覆盖 protocolVersion、pairID 和握手的全部字段。proposal ID 从该已签名 transcript 导出；双方重新计算核对。
- 消息 AAD 覆盖 protocolVersion、pairID、proposal ID、原有消息/会话/设备路由、Ratchet 公钥、链长度和序号。协商控制载荷额外绑定 conflict ID 与控制序号。

不可把初始签名中没有的扩展字段只放进服务器 JSON。新 handshake 的 transcript 域同时进入原有 HKDF info；保持 DH/HKDF 算法，但隔离 legacy 与新版，防止跨版本复用。

## 5. 确定性冲突规则

仅在以下条件同时满足时识别冲突：本地有未确认的、本设备发起的 proposal；对端提供另一个有效签名且 AEAD 验证通过的首次 proposal；两者属于同一 pairID、同一身份固定周期和 protocolVersion；本周期每个发起设备最多一个 proposal。

两候选的发起设备按 **UUID 原始 16 字节的无符号字典序** 排序，较小者的 proposal 为唯一 winner。两端设备 ID 已由固定的账号身份签名绑定；对本次设备对而言规则固定，不取决于随机临时公钥、消息到达顺序、时间或服务器选择。proposal ID 用于精确绑定，不能通过反复生成临时密钥改变 winner。

设备 ID 相同、pairID 不同、身份改变、版本不符、同一发起设备出现第二个 proposal，均拒绝或进入身份异常处理，不增加第三个候选。已确认的普通会话收到新 initial 也不能进入冲突恢复。

winner 保持其原有 initiator/responder Ratchet，**不产生新 Root、不重建该链**。loser 已提交的发送链原样留存并冻结；已经加密的请求继续按原字节投递，不再从 loser 派生新的应用消息密钥。

## 6. 状态机

下面是设备对的协调状态，不等于 Ratchet 链序号。协调记录使用独立单调 revision，并保存允许的前驱与证据摘要。

| 状态 | 含义 | 允许的迁移与条件 |
| --- | --- | --- |
| NONE | 本身份周期无 proposal，无高水位/墓碑残留 | 本地 durable prepare → INITIAL_CREATED；验证对端首次消息并 durable prepare → INITIAL_RECEIVED |
| INITIAL_CREATED | 本机唯一 proposal 与首信封已准备 | 本地 outbox 与 Ratchet commit → INITIAL_SENT；收到对端 initial 先完成已有 journal，再判定冲突 |
| INITIAL_SENT | 初始密文已具备稳定重试能力；不等同服务器已投递 | 收到该 proposal 的认证确认 → SESSION_ESTABLISHED；收到合法对端 proposal → CONFLICT_DETECTED |
| INITIAL_RECEIVED | 对端初始消息已认证并持久化，确认已 durable 排队 | 按该 proposal 继续；认证确认流程完成 → SESSION_ESTABLISHED |
| CONFLICT_DETECTED | 两候选已认证，winner 已计算，所有旧 outbox 均已归属 | 原子协调 journal 记录冻结边界 → CONFLICT_NEGOTIATING |
| CONFLICT_NEGOTIATING | loser 无新增发送权；认证确认和排空可重试 | 双方相同决议已确认、winner 的本机候选 commit → SESSION_ESTABLISHED |
| SESSION_ESTABLISHED | 唯一可发送应用消息的 winner | 单调 Ratchet 推进；不能回到首次握手态；独立 drain 子状态继续处理 loser 在途密文 |
| SUSPENDED | 身份变化、矛盾证明、版本/状态损坏 | 保留已提交状态和日志；不自动重新发起，不由超时解除 |

`INITIAL_SENT` 依赖本地提交，不依赖网络响应，以覆盖发送成功但响应丢失。非法跳转、同 revision 不同内容、旧 revision、不同 winner 的后续消息均拒绝。暂时断线不改变协调状态，只改变重试状态。

正常单方首次握手的 responder **不得另建本机 proposal**；发出认证 confirmation 后使用已接收 proposal。由于正常确认和对端本地初始化可能并发，处理前须串行读取协调记录和已有 journal，不能用 await 前的快照决定是否初始化。

## 7. 认证确认与在途排空

### 7.1 控制载荷

增加加密控制类型 `session.confirm`、`session.confirm_ack`、`session.resolve`、`session.resolve_ack`、`session.drain_ack`。每个控制有稳定 control ID、pairID、protocolVersion、操作者身份/设备、proposal ID；冲突控制还包含两份签名 proposal、conflict ID、winner ID、冻结证明摘要。使用 **winner 的正常 Ratchet 消息密钥** 加密，重试复用精确密文。

冻结证明由 loser 发起设备的身份签名覆盖：pairID、两个 proposal、winner、协议版本，以及 loser 原始发送链的 exclusive cutoff 和提交清单摘要。另一设备不能替它声明“旧链已结束”。确认必须精确匹配本机独立算出的决议，服务端的 stored/ack 不算对端确认。

新会话未收到对端认证 confirmation 之前，每个发送信封携带同一份已签名初始头，便于先收到序号较大的控制或消息时建立同一 proposal；不得再次消费 PreKey。已确认会话不重复携带初始头。

正常无冲突：responder durable 提交首次接收并排队 `session.confirm`；initiator 验证后 durable 排队 `session.confirm_ack`，才允许自身进入 established；responder 收到该 ack 后进入 established。所有控制绑定原 proposal，不允许建立另一个发送 proposal。

冲突确认的具体次序：

1. 任一端检测两份已认证 proposal 后冻结 loser 的本机新增发送权。若本机是 winner，可先发送 `session.resolve` 的 `request` 阶段，包含两份 proposal；request 不能宣称另一端已冻结，也不能完成收敛。
2. loser 的发起端完成已 prepared 请求的归属，签名冻结证明，通过 winner Ratchet 发送 `session.resolve` 的 `offer` 阶段；所有分段完整后才构成有效 offer。peer 可能通过该控制先看到 winner 初始头，建立的仍是已选择 proposal，不是第三次握手。
3. winner 发起端核对自己的唯一 proposal、对端 proposal、确定性 winner 和完整冻结证明，durable 排队 `session.resolve_ack`，其中签名/密文绑定完整决议摘要。不得在接到 offer 前自行声明对端的 cutoff。
4. loser 端收到匹配 ack 后 durable 记录已确认决议，排队 `session.resolve` 的 `commit` 阶段；winner 端验证 commit 后记录相同决议。所有阶段均使用同一 conflict ID 与决议摘要，不能接受早于本机前置证据的阶段；可以持久暂存并重试，不能跳过验证。
5. 协商阶段已认证的 winner 应用消息可先安全保存，不能因等待未来控制而阻塞整个 Sync 流。是否向用户显示发送成功仍以现有业务回执为准。

以上不保证双方在完全相同的时刻知道对方已完成；丢包时一端可仍处于 negotiating。安全目标是它们在任何阶段都不会选择不同的发送 proposal；网络最终投递时，双方最终收敛。不能把异步网络解释为原子双端提交。

### 7.2 保留先前消息

冻结清单覆盖 loser 链已经 durable seal 的应用/事件信封，含 proposal、ratchet public key、message index、message/control ID 与精确信封摘要；覆盖已发送、待发和服务器响应丢失的条目。不能仅依赖服务器的最后一个 deviceSeq。

为处理既有 journal 的烧号、取消和部分多目标提交，清单还需明确哪些索号没有可投递信封；这些项由链拥有者签名，并且不能覆盖已有认证消息或把待发消息伪装为取消。接收端只接受冻结范围内与清单一致的 loser 消息，逐条认证、保存并推进独立接收候选。清单以确定顺序分段，分段计数与整份摘要被签名，接收完整清单前不确认排空。

双方确认 winner 后只用 winner 发送新的文字、附件和控制事件。loser 候选仅用于上述在途接收；保存它不允许调用它的 encrypt。未来收到新 proposal 或冻结边界之外的 loser 密文应拒绝，不能自动扩展排空范围。

排空并得到认证 `drain_ack` 后保留永久的 proposal/消息摘要墓碑。已消费消息密钥不保留；不需要的接收材料按明确退休流程清理。**这不是为了建立新会话而删除/覆盖旧 Ratchet**；若对“禁止删除 Ratchet 状态”的要求是永久保留全部秘密，则与缩短秘密生命周期的目标冲突，需要在实现前明确，不能默认永久留存。

### 7.3 有界资源与安全暂停

每个设备对最多两个候选，未确认初始链最多 2,000 个未排空序号，与当前跳过密钥上限一致。超出后保存加密发送意图并暂停派生，不丢弃旧密文、不重建 proposal、不降级。控制优先调度并保证幂等；网络永久丢包或恶意服务器阻断时无法保证协商完成，应保留状态而不是超时 reset。

## 8. 后端投递设计

新增拟议的 `/v1/sessions/controls` opaque 控制接口；这是设备级投递，不是服务器 Session 建立或选主。请求包含 control ID、发送/目标设备、会话路由、encryptionVersion 与 opaque envelope；服务器只校验调用者、活动设备、同账号设备或未屏蔽好友的会话权限、大小及幂等。

目标是一个明确设备，不要求给会话中所有设备复制相同协商控制。服务器不能解密确认、选择 winner 或生成有效控制。重复 control ID 与相同调用者/精确请求 hash 返回原结果；相同 ID 的不同请求拒绝。事务内保存幂等记录与 Sync Event，WebSocket 仅提示同步。

需要一份新增控制幂等 migration 和 OpenAPI 描述；不改变现有 messages/envelopes 表字段。Sync 新增 `session.control`，内层路由认证后由 Crypto 服务处理，不生成用户聊天气泡或明文日志。

客户端接收 first initial 时可完成其认证、保存原消息和候选协调状态，并 durable 排队控制，再 ack 原事件；**不等待未来远端确认才释放当前 cursor**，否则会阻塞排在后面的确认事件。不能跳过失败认证或未持久化事件来解除阻塞。

## 9. Keychain 和崩溃一致性

新增设备对协调记录、按 proposal ID 区分的 Ratchet 记录、每条记录高水位、一次性密钥的 proposal 预留/消费墓碑，以及控制 outbox。私钥、Root/Chain、skipped key、中间 plaintext 仅进入本设备 Keychain；SwiftData 仅保存协调元数据或 Master Key 保护的精确请求。

所有发送/接收/协商操作必须通过同一设备对串行执行器，不能让发送 journal 与接收候选从相同旧版本独立推进。执行器禁止跨 await 保存旧状态，重启时先恢复 journal。

事务仍为 `prepared → applying → committed / failed`，不伪造跨 Keychain/SwiftData 的原子提交：

1. 验证路由、签名、身份固定和 AEAD，生成候选；未经认证的冲突不写协调状态。
2. 将候选推进、预计前驱版本、待消费 PreKey、控制精确请求和业务写入意图 durable stage。
3. 准备新 proposal 时对 One-Time PreKey 做持久 reservation，绑定唯一 proposal；同 proposal 重试仅使用既有候选或 journal。其他 proposal 使用同一 PreKey 必须拒绝。
4. 保存业务数据及协调进度，逐项完成 Keychain CAS 和 PreKey 清理。各记录同版本同内容重试幂等，旧版本/同版本不同内容拒绝。
5. 只有全部相关状态一致才发送同步 ack；本地 cursor 比 Keychain 完成得早时，启动 recovery 必须先续办原 journal，再向服务器确认。

冻结前已 prepared 的旧请求必须完成本地 commit 并纳入清单，不能直接取消后释放发送序号。崩溃在冻结/控制 staging 中途，下次恢复使用精确冻结证明和控制密文，不重新生成消息密钥。

Keychain 高水位防止单条旧状态或旧 journal 覆盖较新状态；**不能抵抗攻击者将整个 Keychain 和所有高水位一起回滚**。现有平台实现没有外部不可回滚锚点，本设计不能新增虚假的抗整机回滚保证。

## 10. 兼容与降级

- v1/v2/v3 历史读取及已建立 legacy v4 Ratchet 保持原路径。
- 新创建的冲突恢复会话必须使用 protocolVersion=2；任何缺失、未知版本或不匹配签名/AAD 均失败关闭，不回退到 legacy 首次握手。
- 通过新版受账号/设备身份签名保护的能力信息发布支持状态；服务器移除能力只能导致拒绝建立，不能触发弱模式。该能力绑定需要同步扩展 PreKey 上传/Bundle 验证。
- 已建立 legacy v4 收到新版 initial 不得自动迁移。现有冲突记录通常已清空 initialHeader，且已发送请求可能已从 outbox 移除；不能保证恢复原签名 proposal。缺少证据时维持暂停，不能自行合成一个旧 proposal ID。
- 因此“新建双方同时握手恢复”和“已经发生的 legacy 冲突迁移”是不同验收项。后者没有完整 durable 证据时，不能承诺无损自动修复。

## 11. 安全论证边界

| 风险 | 必须验证的约束 | 不能声称的保证 |
| --- | --- | --- |
| 身份替换/MITM | 固定账号身份、设备绑定、初始签名、AEAD、显式身份变化暂停 | 仅从恶意服务器首次取指纹不构成真实身份核验 |
| 重放 | proposal/控制/消息墓碑、PreKey 单 proposal reservation、每链序号和幂等请求 | 服务端事件 ID 不等于密码学重放保护 |
| 分叉 | 固定设备顺序、同周期最多两个候选、唯一 sendActive 指针、双方认证相同决议 | 单方选择或 server ack 不能确认双方收敛 |
| 回滚 | 每 proposal 和协调记录 CAS、单调 revision、高水位和日志重放约束 | 整机失陷/整体 Keychain 回滚不在现有防护范围内 |
| 降级 | 版本进入签名/HKDF/AAD，新初始化严格要求新版 | 不支持的旧端不能被悄悄当成支持新协议 |
| 前向安全 | 不重用 PreKey/消息密钥、不保存初始共享秘密供重算、继续原 DH Ratchet、限时排空 | 尚未消费 skipped key、未排空接收链及运行时内存仍有暴露窗口；Swift Data 不能保证内存擦除 |
| 可用性 | 同一请求精确重试、恢复 journal、控制 outbox | 恶意服务器永久不投递时不存在确定的完成时间 |

上述是设计约束，不是完成的密码学证明。基础算法参考 [X3DH 安全注意事项](https://signal.org/docs/specifications/x3dh/) 和 [Double Ratchet 规范](https://signal.org/docs/specifications/doubleratchet/)，不宣称兼容完整 Signal 协议。

## 12. 实现范围与验证计划

拟涉及：`V4Handshake`（新版签名/能力/域）、`V4RatchetMessage`（认证扩展；不替换 Ratchet 算法）、`V4SessionVault`（候选/协调/CAS/journal）、`V4MessageSessionService`（选主/冻结/控制）、`V4PreKeyService`（能力与预留）、Repository/RemoteSyncCoordinator（控制路径与恢复）、后端控制路由/幂等 migration/OpenAPI。UI 不改变安全标识。

### 协议与恢复测试

1. 双方向单方首次握手；含真实 OTP 的首次消息、认证确认和连续双向消息。
2. 独立 Keychain namespace 的 A/B 同时 durable initial；分别先交付 A/B、交付确认早于首消息、延迟 loser 多条消息。两端 winner 一致、只有一条发送链、初始两条消息均可读、版本只增不减。
3. 对端 initial 到来时本机 outgoing 仍 prepared/applying；每个阶段故障注入、重新创建 vault/repository/context、恢复精确请求和冻结证明。
4. 重复投递、同 control ID 改载荷、乱序、断网、服务端成功但响应丢失、旧 initial、第三 proposal；无重复业务应用、无重复预密钥领取/消费、无 cursor 越过失败事件。
5. 改 proposal/conflict/version/身份/设备/冻结清单/索号/nonce/tag；伪造身份签名、篡改 AEAD、去掉版本、跨会话/跨设备重放；全部拒绝且 durable 状态不变。
6. 将单条旧 proposal/协调状态/高水位不一致的 journal 放回；拒绝覆盖，不产生新的消息密钥或 outbox。
7. 设备撤销与身份变化中断协商，停止旧请求和控制发送；所有正常已建立 v4 与旧版本回归通过。
8. 双设备真实 Backend：两个新账号、朋友身份核验、同时发送、双向事件、断线续发、进程重启与服务恢复。服务端只保存密文控制，权限/屏蔽/撤销/幂等测试通过。

### 验证证据分层

实施后运行 iOS Debug/Release build 与协议单元测试、Go test/vet/race，以及隔离 PostgreSQL/Redis 集成和真实本机 HTTP 双逻辑设备闭环。两台实体设备、真实弱网络、App 强制终止与 Ubuntu VPS 恢复需要实际可用的设备和环境；缺少环境时输出明确人工步骤，标为未验证。不能把两个逻辑设备或模拟器称为两台实体设备。

## 13. 实现前需要审阅的决策

1. 是否接受“一个发送活动会话 + 临时受限接收候选”，并在双方认证排空后退休不再需要的秘密，保留永久重放墓碑？这是无损保留在途消息的关键。
2. 是否接受新版显式协议能力/认证头和设备级 opaque 控制接口，旧新端未共同支持时失败关闭？
3. 是否认可当前只能承诺修复新建会话的冲突；无法恢复完整旧 proposal 证据的 legacy 冲突不能自动重置？

审阅通过后形成具体实施计划，再写协议级失败测试和实现。未完成协议及真实环境验收前，发布阻塞项仍然保留。
