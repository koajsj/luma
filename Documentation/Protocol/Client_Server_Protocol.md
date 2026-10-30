# iOS 与未来服务器交互协议

**状态：部分实现。** `Core/Network` 现有 `RemoteAPIClient` 与 `RemoteAuthProvider`：显式在线登记、设备挑战签名、Keychain token、资料与好友 API 已有客户端实现。`RemoteMessageSyncProvider` 可读取后端事件，`WebSocketTransport` 和密文文件接口已有独立实现，但已接入显式在线文字聊天；未知或验证失败的 v3 信封不应用、不确认游标。现有本地 `SyncCoordinator` 仍连接本地仓储与内存 Mock，线上由 `RemoteMessageRepository` 负责游标处理。

## 设计中的交互

1. **注册/登录**：客户端本地生成并保存私钥，仅上传身份/设备公钥；设备认证使用将来单独定义的签名键挑战响应。服务端不接收本地密码/PIN/Face ID 数据。新设备需已有可信设备授权；账户恢复方式尚待设计。
2. **建联**：好友请求经双方确认；客户端拉取并验证每设备的身份与预密钥束。公钥目录的替换检测、身份变化告警与核验方式必须在真实 E2EE 前完成。
3. **发送**：客户端为目标设备生成经过协议认证的密文信封，调用 HTTPS 发送；本地先持久化待发项，通过 `Idempotency-Key` 重试。服务端只校验权限和路由，不解密正文。
4. **接收**：WebSocket `sync.available` 或 APNs 只提示有新数据；客户端通过 HTTPS 游标拉取、验证事件来源与密文，再由 Repository 应用到 SwiftData 并 ack。
5. **文件**：客户端先加密文件，再申请受限上传票据上传密文；下载后先校验密文哈希，再在设备上解密。附件密钥只在客户端的 E2EE 消息内传递。

未来实现替换 Mock API/Auth/Sync/Presence/File Provider；保持 `MessageRepository` 和本机加密存储作为离线数据源。`SyncCoordinator` 扩展为网络重试与事件验真协调入口，View 不直接接触网络或 CryptoKit。正式聊天当前 v1 是本机主密钥密文，不能把它原样上传后宣称接收方可解密；启用网络必须先完成新的可互操作 E2EE 信封格式及版本迁移。

传输使用 HTTPS/WSS、TLS 证书校验、短时访问令牌与设备绑定证明；WebSocket 重连后仍需游标补账。服务端返回时间不应被当作已读、送达或可信身份的唯一证明。详见[API](../Backend/API_Specification.md)与[同步协议](Sync_Protocol.md)。

## v3 接入增量

聊天页显式选择“在线密文聊天”后，经 `ChatViewModel → RemoteMessageRepository → RemoteAPIClient` 发送文本。`GET /v1/friends` 提供已确认好友路由 UUID；`GET /v1/users/{id}/v4-prekey-bundle?claim=false` 供身份指纹核对，不占用一次性预密钥。正常发送领取公钥束并为每个活动目标设备生成信封。`GET /v1/sync/events` 按连续游标应用到本地加密存储；聊天页定时拉取。后端仍只接收公钥、路由元数据和密文。

隔离的本机 HTTPS 后端与两个独立 iOS 模拟器已完成 v4 双向文字、编辑、删除、已读、Reaction 和一次离线待发恢复；实体设备尚未验证。首次身份固定必须通过可信渠道核对，点击“已核对”本身不构成身份保证。本次联调只从后端目录取得测试指纹，没有验证独立线下核对。持久待发队列与已登记设备撤销已加入代码；图片、文件、导入语音的加密上传与下载代码已有局部验证，但完整双设备附件、强制退出恢复及实时通知仍待后续验收。

## v4 首次初始化恢复控制

`POST /v1/sessions/controls` 接收 controlID、conversationID、receiverDeviceID、encryptionVersion=4 和 base64url opaque envelope。身份、pair、proposal、winner、冻结清单及控制签名位于客户端认证密文内；服务端只校验路由权限、活动设备、block 和幂等。

产生定向 `session.control` Sync Event，eventID 等于 controlID；路由包含发送账号/设备、目标设备及会话。客户端验证路由与内层认证字段后处理，不显示聊天气泡。相同 ID/精确内容返回原结果，改内容返回冲突。HTTP 201/200 不等于对端认证确认。

PreKey 公钥束增加设备 Ed25519 签名的 recoveryProtocolVersion=2 能力；客户端验证账号绑定、能力签名及固定身份。服务端移除能力只能导致新版初始化拒绝，不能触发自动降级。版本/签名详情见 OpenAPI。


## 可信密钥目录接入合同 v1（2026-10-23，未接入生产）

### 状态、范围及实施顺序

本节是应用层合同和接入门禁，不是新的密码学证明算法。`contractVersion=1`、下述见证恢复投影及其预期动作已固定；**透明度 wire、账号 roster 签名字节及 v4 新 AAD 尚未冻结**。没有可接受的真实证明向量前，suite 状态必须是 `not_frozen`，不能把合同检查器的成功当成目录验证成功。

本轮执行顺序：核对候选证明/现有握手 → 固定见证恢复接口与失败向量 → 明确目录上下文迁移 → 定向验证并记录缺口。只实现离线恢复合同检查器和共享夹具；没有新增线上 API、数据库表、签名服务或握手分支。完整授权矩阵沿用[治理设计](../Security/Privacy_Boundary_Governance_2026-10-22.md#授权合同与验收要求补齐2026-10-23尚未冻结-wire)，不复制原方案。

### A. 证明套件冻结合同与阻塞项

候选源固定为 server `2eb0ead9a23dc4bd2dcb75a2f803c6e8ee85600c`、auditor `13a9126a63081c189de8422bb2e7dca770adec9f`、libsignal `b2a5c30f3245c1bcad04b27b1e752a38321c793d`。这些是评估输入，不是已验证互操作的 suite。不能把 IETF 草案 05 的结构与 Signal 应用差异混搭，也不能自动跟随 upstream main。

冻结包必须由同一个不可变 `suiteID/configID` 定义以下内容；任何一项缺失都不能进入客户端强制阶段：

| 输入 | 必须冻结的内容 / 验证行为 | 当前状态 |
| --- | --- | --- |
| 实现与格式 | 服务、Rust 验证器、FFI、auditor 的提交/构建特性、许可证、proto 描述及字节向量摘要；未知版本拒绝 | 源码候选已固定；互操作、许可与评审未完成 |
| 配置与信任根 | 日志签名/VRF 公钥、模式、指定必需 auditor、checkpoint 起点和更换根的授权；独立可信渠道分发 | 没有 Luma 真实独立根/运营方；服务器响应不能创建根 |
| 完整值及授权 | 同一账号 UUID/身份代次的完整活动集合+撤销墓碑，最终设备 UUID、版本及前序快照；账号授权和设备持钥证明 | 授权需求已有；规范签名字节、域与跨语言向量未完成 |
| 证明 | 最新值查找/承诺打开、包含、客户端已存历史的一致性、监控状态更新及 required auditor | 采用上游完整验证器，不移植 Merkle/VRF 片段；真实兼容证明未执行 |
| 规范化与上下文 | 字段类型/顺序/长度/上限、重复设备拒绝、UUID 原始值、整数编码、签名/哈希/AEAD 的独立域；所有版本/账号/配置参与绑定 | 不把 JSON 序列化、普通哈希或本机 revision 当规范签名或证明；未定值前不得生成正式签名 |
| 新鲜度与边界 | 固定检查点时间窗口、审计落后策略、可信时钟异常和长期离线的恢复；单调树头/revision 下限 | 策略仍须审阅并定值；缺参数拒绝，不借用服务器时间默认通过 |

**本轮确认的候选适配差异**：[固定 libsignal 验证器](https://github.com/signalapp/libsignal/blob/b2a5c30f3245c1bcad04b27b1e752a38321c793d/rust/keytrans/src/verify.rs#L170)允许 auditor 检查点落后于查询树头。这是候选本身的策略，不是已证实漏洞；不能把较早历史的一致性证明说成本次变更已经被 auditor 检查。Luma 的首期严格接入要求：用于激活 roster/新会话的查询结果与 required auditor **同一个树大小和根**，且满足被冻结的新鲜度；若候选不能提供该受见证树头上的最新值证明，必须等待或更换经过评审的适配方案，不修改上游证明算法、伪造 proof 或降低要求。只有旧的受见证快照仍在时限内时才可能继续旧授权，不能据此声称即时检测所有撤销。

客户端必须向验证器要求最新版本查找，不能由服务器指定一个有合法包含证明的旧 revision。验证成功后同时提交 `value + tree head + monitoring state`；不能只持久化树大小，丢弃未来检查历史所需的状态。更新账号完整快照时，authorized → pending_log → witnessed → active 不得被 API 201 或孤立包含证明代替。

**冻结向量的验收合同**：真实二进制输入必须包括配置、可信账号身份、先前验证状态、请求、完整响应、受控时钟、预期返回值与状态更新/固定错误类别，并附来源、源码版本、输入摘要及独立推导说明。Go 生产器与 Swift/Rust 接收端读取同一份不可变字节；正常向量需与规范/上游官方向量和独立审阅对照，负向量从该正常向量单独修改一个认证维度。不能用双方“输出相同”、服务器生成的期望值或 stub 全拒绝冒充正确性证据。

只保留三个合并验证组：①账号授权/完整集合（新增、轮换、撤销、未授权、隐藏设备、重复 ID）；②真实证明（错误打开、旧值、同大小分叉、不同大小不一致、错配置/域/版本、旧/缺见证）；③历史/迁移（回滚、新端引导、长期离线、状态丢失和恢复）。本轮共享 JSON **仅是见证恢复动作向量**，不能列入这三个密码学验证组通过项。

### B. 独立见证持久化与恢复合同

**边界**：主 Backend 不持 witness 私钥，不决定其签名、不替它初始化历史。见证必须独立取得并逐步验证日志演进；完整集合授权仍由客户端核验。单独进程、同一个 root/Docker/云账号/备份管理员并不算独立。见证 signer 和防回滚锚点不得与可被恢复的本地状态一起回滚；没有这个条件，只能停止签名，不能声称防止整份备份回退。

**接口（设计，尚无生产 adapter）**：

| 接口 | 输入与结果要求 |
| --- | --- |
| `VerifyEvolution(config, previousFrontier, exactCandidate)` | 调用被冻结的上游验证器；返回不可变完整新 frontier、精确签名输入及被验证 checkpoint。缺历史/错误证明失败，不能只信 server 签名 |
| `Store.Prepare(expectedGeneration, exactDecision)` | 单写者 CAS、同操作同内容幂等；持久化完整决策后返回。写结果未知必须读回相同内容，禁止新建候选替代 |
| `Anchor.Reserve(expectedPrevious, generation, decisionDigest)` | 不与本地备份同回滚域的持久 CAS；同 generation 同 digest 幂等、不同 digest 永久冲突；超时先查询，不能当未写入 |
| `Signer.SignReserved(generation, decisionDigest, exactInput)` | signer 内部以锚点 fencing 核对本次决定与签名字节，禁止只由调用方“刚查过”保证；并发/过期 worker 不能签另一输入 |
| `Store.SaveSigned(expectedDecision, signature)` | 保存精确签名和已验证 frontier，落盘完成且读回一致后才允许向外输出；这是主服务可能看到签名之前的必要边界 |
| `Publish(exactSignedCheckpoint)` | 精确重试；HTTP 成功只表明传输收到，不创建见证历史，不授权覆盖本地状态 |

**完整持久化记录（设计）**：版本/配置/见证 ID、key epoch、generation、previous generation/decision、旧/新 checkpoint、前序 frontier、完整新 frontier、输入证明及其摘要、精确签名输入、decision digest、阶段、精确输出签名及通知状态。私钥单独在 signer。decision 的字节规范/摘要域须随 suite 冻结，覆盖所有安全字段且不随投递状态变化；普通 JSON 不是该签名输入。记录的完整性认证、原子替换/数据库事务、fsync/读回、备份、single-writer fencing 和磁盘损坏处理都需 adapter 提供；只有 checksum 不能抵抗恶意回滚。

恢复状态机：`prepared → anchored → signed → published`。`anchored` 从独立 Anchor 查询得出；本地阶段仅有 `prepared/signed/published`，避免两份可以互相矛盾的“已 anchored”布尔值。每个 generation 只对应一个不可变 decision；没有受验证的前序和锚点不能从空状态自动创建 genesis。新 epoch/新根必须走独立审阅的配置迁移，不能作为恢复失败的 fallback。

| 崩溃/恢复窗口 | 必须执行的下一步 |
| --- | --- |
| prepare 前 / 持久化失败 | 没有外发签名；保留旧已确认状态，先确定是否写入，不越过未知决定 |
| 本地 prepared、锚点仍是前序 | 重新验证完整字节与历史，再 CAS reserve；不能先签后 reserve |
| reserve 回应丢失、锚点已是该 decision | 只恢复该决定；重新验证并由 fenced signer 签同一输入，再持久化签名 |
| 本地 signed、发布前/发布响应丢失 | 校验签名、frontier 和锚点，精确重发已保存输出，不重新选择状态 |
| published 后重启 | 重验记录和完整历史，从同一 frontier 恢复；重复通知不重新推进 generation |
| 锚点领先/落后、同 generation 不同 digest、记录损坏/缺失、不可达 | 停止签名和信任升级，保留记录与证据；不清空状态，不拿旧备份强行启动 |

同一 key 的 replicas 必须共用上述不能回滚的签署约束。若 signer/锚点和本地快照一同失陷或回退，软件无法证明没有已泄露的冲突签名；恢复时必须通过独立保存的已发布 checkpoint/签署下限对账，无法补回精确决定则停机审阅。单机 fsync、文件哈希、自签恢复记录都不能代替这个假设。

**可执行部分**：[离线恢复合同检查器](../../backend/ops/keydirectory-contract/main.go)只读取 stdin 的公开状态投影，输出 `requiredNextStep` 或固定错误码（非零退出），不访问网络/Keychain/数据库、不签名、不写存储。用法：仓库 `backend/` 下 `go run ./ops/keydirectory-contract < recovery-projection.json`。它检查格式、配置/epoch/锚点绑定、generation 连续性、阶段及明显树头回退；返回的每个动作仍以重新证明验证为前置条件，不是签名许可。客户端或独立见证的将来实现可消费[同一份夹具](Fixtures/key_directory_witness_recovery_v1.json)：version=1，先按 RFC 7396 将各 patch 应用于 base，再断言唯一 `next` 或 `error`。预期结果由本节真值表指定，不由两端相互生成。当前夹具有 23 个决策场景，SHA-256 为 `6764cc9b6f9601a4d026f7867bdbc5b1e3da32cfe9efffcc41645628d9452513`（仅固定夹具版本，不是透明度证明）；改变合同预期需显式审阅版本。

投影格式固定为：`record`（可缺失）含 `version=1`、`config/witness/decision/previousDecision`（32 字节小写 hex ID/digest）、`keyEpoch/generation/previous`（规范十进制 uint64 字符串）、`phase`、`from/to {size,root}`；`anchor` 含 `status/config/witness/keyEpoch/generation/decision`。未知字段/版本拒绝；数字不用 JSON 浮点。该投影不包含签名输入/输出，**不是完整见证持久化格式或防回滚实现**。checkpoint 摘要仅作引用，不能证明包含/一致性；实际记录缺少证明或精确字节时不得采取 checker 建议的步骤。

### C. v4 目录上下文迁移合同（设计，未改现有 wire）

`encryptionVersion=4` 保持；新增目录子版本必须独立于 `sessionVersion` 和 Recovery 的 `initialHeader.protocolVersion=2`。不得重用它们来暗示目录已验证。以下状态是后续实现要求，不是已上线开关：

| 阶段 | 允许行为与迁移门禁 |
| --- | --- |
| `legacy` | 保留现有身份固定/版本检查及 v1–v4 历史；不能声称已解决目录分叉 |
| `observe` | 旁路验证、持久化证明与报警；失败不授予 strict 能力，不能把旧列表回填成账号签名快照 |
| `required_pending` | 账号签署完整快照及能力/策略，全部必要设备升级并准备证据；不自动复制账号私钥 |
| `required` | 在受见证账号策略和本机下限均持久化后生效；旧服务/客户端、缺证明/上下文均暂停相关新发送。不可通过重装或服务器声明自动退回 legacy |

**上下文输入**：suite/config/log/auditor policy ID、双方账号 UUID/身份代次/账号固定指纹、完整 roster revision/digest、日志 checkpoint 引用、发送/接收最终设备 ID/身份版本、被授权 Signed PreKey 版本、公钥摘要及目录子版本。首次引导必须独立核对根和账号身份；OTP 的领取结果必须属于同一已授权设备和 SPK，不能为了设备 OTP 不可用省略该设备。

**新握手**：先验证双方完整快照和同一配置下的历史，再领取/核对 bundle；加密准备和上传前（含 Token 等待之后）复核账号、信任、策略/目录授权代次。若变化使目标身份/设备不再授权，暂停精确 outbox 和待提交 journal，不向旧目标继续发、不向新目标重 seal。已领取而未确认使用的 OTP 保留领取/候选记录，不能放回池或再次消费；只更新证明不能重新派生已提交 Root/Chain。

**认证绑定，尚待字节冻结**：未来目录版 initial 签名输入必须含双方目录上下文；消息、编辑、删除、已读和 Reaction 的 AEAD AAD 必须同样绑定。拟用独立的 initial/message 上下文域包裹现有认证头与规范上下文字节，而非附加一个服务端 JSON 字段。账号 roster 的授权域、目录值承诺域、initial 签名域与 message AAD 域不能互换。精确域名、字段顺序/编码及长度上限需随 suite 和跨语言向量审阅；本轮不生成似乎已可用的新 header。不能更改现有 Ratchet 算法或给旧 header 重新签名“升级”。

**已有会话**：建立单独目录授权记录，引用原 Ratchet ID/安全版本，不能复制/重建旧链。启用目录上下文的双方确认必须经过现有 Ratchet 认证，并绑定目录迁移操作 ID、双方快照/版本和每条链的切换边界；控制类型、AAD 与崩溃提交向量需在实现前冻结。只在一方本机设置“已迁移”不足以证明对方支持。不能用 Backend 的时间/ACK 充当双方确认。未完成确认的既有会话不冒称 strict，新会话与重新授权也不能绕过 required 策略。

**撤销与历史**：本地已验证保存的历史内容继续可读。撤销后未见过的旧上下文消息，包括可能合法的在途消息，不能仅凭旧签名/createdAt 接受为撤销前发送；默认暂停应用并保留密文、链和日志，等待经过审阅的历史/排空授权。若要保留自动在途接收，必须有链级或精确信封摘要 cutoff 认证及有界恢复机制，并覆盖被撤销端不合作；当前没有该合同，不承诺能同时即时拒绝撤销端和无条件接收所有旧在途消息。不以跳过游标、丢弃信封或替换 Root 消除阻塞；严格策略可能牺牲可用性。

**失败恢复**：目录及授权记录先持久化可恢复意图，再准备链/消息；保留已经 seal 的精确字节、所用 context 和每收件人 journal。成功上传响应不是对端应用确认；无法确认 Keychain/SwiftData/cursor 一致时不推进确认。恢复只能接续该配置/历史/迁移操作，不能用过期 proof 自动重新启用；配置或本机状态丢失必须重新可信引导并与外部下限对账。历史读取和迁移写入分别验收，不破坏旧 schema。

### 接入资格判定

三个必要证据为：①固定套件的真实 Go/Swift 证明向量与适配审阅；②独立 signer/锚点/持久化 adapter 的重启、响应丢失、存储恢复和回滚故障注入；③正式 v4 认证上下文/切换边界的双设备迁移及撤销在途策略验收。缺任一项都不能接入 required。本轮仅固定恢复决策合同与迁移要求；没有完整证明/见证服务/迁移实现。Recovery 继续默认关闭，不启用生产 E2EE 标识。

## 当前在线协议与历史读取边界（2026-10-26）

- 在线认证仅接受设备签署的 `luma.request.v2`，绑定令牌、已登记设备、方法、原始 RequestURI、时间戳和 nonce；旧 v1 请求证明返回 401。签名域不是 App 二进制远程证明。
- 新消息仅允许 `encryptionVersion=4`。编辑、删除、已读和有序 Reaction 只通过逐设备 v4 密文事件写入。服务端旧 v3 消息、编辑、删除、已读及 Reaction 写入口已移除；传输送达提示仅用于 v4，不能作为端侧认证的已读。
- 好友身份核对使用只读 v4 公钥束，检查账号签名、设备绑定和 Signed PreKey；不消费 OTP。首次信任仍需可信带外安全码核对。注册/设备审批的传统 Signed PreKey 数据字段暂保留，旧 v3 在线公钥查询与补充接口已移除。
- 已存的 v1/v2/v3 历史消息继续在客户端按原版本解密。合法旧 v3 同步事件仍须完成原有签名/AEAD/归属验证；无因果顺序的 Reaction 只作无状态消费，未经端侧认证的删除/已读不改变正文。无法证明归属的历史编辑暂停游标并保留 journal，不跳过认证。
- 未知版本、身份变化或认证失败时暂停处理，不退回旧在线协议、不重置 Ratchet。服务端仍可能保留并投递此前写入的旧事件；删除旧 API 不清除历史队列。当前版本尚未发布，因此不承诺旧二进制在线兼容。回滚旧后端可能重新开放弱认证入口，必须经单独安全审查。

Recovery 默认关闭，生产 E2EE 标识继续关闭。真实双设备、断网/崩溃故障注入和独立密码学审计尚未完成。
