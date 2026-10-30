# 消息与事件格式

## 当前本地结构（已实现）

`Message` 含稳定 UUID `id`、`conversationID`、`senderID`、类型、`ciphertext`、`encryptionVersion`、可选 `sessionKeyVersion` / `messageKeyIndex`、`deviceID` / `lastEventID`、创建/编辑/送达/已读/删除时间和本地状态。`MessageEvent` 含 `eventID`、`messageID`、时间、事件类型、可选 payload、actorID、deviceID。当前 Mock 事件类型为 `newMessage`、`messageSent`、`messageDelivered`、`messageRead`、`messageDeleted`、`reactionAdded`、`messageEdited`。

`ciphertext` 是 AES-GCM 组合字节，包含随机 nonce、密文及认证标签。v1 使用 Master Key；v2 本机模拟使用 Session/消息密钥。`messageKeyIndex` 只对采用基础链的新 v2 消息有意义；缺省旧 v2 路径按会话密钥解密。`eventID` 用于去重；当前 `MessageEvent` 为内存事件，不等于服务端签名凭据。

## 早期网络信封草案（历史参考）

```json
{
  "eventID": "6a8c9a9d-e400-42fa-a0cb-6f91b535f7fe",
  "messageID": "78fda1d8-e1a5-4b83-9b8a-d28e8a72c801",
  "conversationID": "42385010-7211-43a9-a147-4b36a218ea37",
  "senderDeviceID": "e3c48b05-69b4-43c1-b622-2cd34b8b9862",
  "encryptionVersion": 3,
  "recipientEnvelopes": [{
    "recipientDeviceID": "cc14a4f0-5bba-4e43-b1d6-afcb33c38970",
    "sessionKeyVersion": 1,
    "messageKeyIndex": 42,
    "ciphertext": "base64url-aead-envelope"
  }],
  "createdAt": "2026-09-25T08:00:00Z"
}
```

上例是早期 API 草案，不是当前在线信封 JSON。当前在线写入只允许 v4；v3 编码仅用于历史读取。服务器可见会话、参与设备、时间、大小和版本等路由元数据。

网络事件类型草案为 `message.created`、`message.delivered`、`message.read`、`message.deleted`、`message.edited`、`reaction.added`、`typing.started`、`typing.stopped`、`presence.updated`。服务端事件必须区分可信服务端序列与客户端提供的 `eventID`，权限与设备签名校验后才可应用；删除事件是同步意图，不是远端物理擦除保证。

## v3 设备消息信封（已在隔离后端和模拟器双账号验证）

`encryptionVersion=3` 仅用于线上逐设备信封；SwiftData 中的消息正文在接收后重新以 v1 Master Key 加密，`transportEncryptionVersion=3` 记录来源，不把线上密钥保存进数据库。服务端 `message_envelopes.ciphertext` 保存整个 JSON 信封的 UTF-8 字节（API 外层再用 base64url 编码）：

| 字段 | 可见性与作用 |
| --- | --- |
| `messageID`、`conversationID`、`senderDeviceID`、`receiverDeviceID`、`encryptionVersion`、`keyVersion`、`messageKeyIndex`、`createdAtMilliseconds` | 路由元数据，服务器可见；纳入 AES-GCM AAD 与身份签名。 |
| `ephemeralPublicKey`、`senderIdentityPublicKey`、`recipientSignedPreKey`、可选 `recipientOneTimePreKey` | 公钥，服务器可见；用于逐设备密钥协商和接收端查找私钥。 |
| `nonce`、`authenticationTag`、`signature` | 认证材料，服务器可见；nonce 每次随机。 |
| `ciphertext` | 加密正文；内含 `kind`、发送方及目标 UserID、文本；编辑消息还包含 `revision`，接收端须与事件路由版本核对。不向服务器暴露明文。 |

编码采用 `DeviceMessageEnvelope` 的 Codable JSON；二进制字段为标准 Base64。签名/AAD 不依赖 JSON 键顺序：以 `luma.device-envelope.v3` 域前缀开头，随后按上述固定顺序对每个字段写入 4 字节大端长度与原始字节。UUID 使用小写规范字符串，创建时间是 Unix 毫秒整数。AAD 是头字段；身份签名覆盖 AAD、nonce、ciphertext、tag。接收端必须同时核对服务端路由、固定的好友身份指纹、P-256 ECDSA 签名、AES-GCM 标签与目标设备 ID。

每个目标设备新建 P-256 临时密钥，用临时私钥分别与目标 Device Key、Signed PreKey 和可选 One-Time PreKey 做 ECDH；连接共享秘密，以 SHA-256(AAD) 为盐、`luma-device-message-key.v3` 为 info，经 HKDF-SHA256 派生 256 位消息密钥。`messageKeyIndex` 是每信封随机非负整数，当前不是 Double Ratchet 链序号。接收并持久化后删除用过的一次性私钥。Signed PreKey 与 Device Key 仍保留，**不能据此声称完整前向保密**。

发送给多个设备时必须分别生成信封；后端验证信封集合与当前活动目标设备完全一致。同一个 `messageID` 作为幂等键。接收端按连续 `deviceSeq` 验证、解密、重加密落盘，之后发送送达回执并 ack。失败不推进游标。在线文字已使用主密钥加密的持久待发队列；离线时先保存本地消息与加密意图，联网后生成信封并加密保存最终请求，重试复用同一请求和幂等键。真实两设备联调仍待完成。

## v4 设备 Ratchet 信封（新在线文字消息）

`POST /v1/messages` 的 `encryptionVersion=4`，每个 `recipientEnvelopes` 项仍传 `recipientDeviceID`、`keyVersion`、`messageKeyIndex` 和 base64url `ciphertext`。该密文字段实际是 `V4RatchetMessage` JSON：`messageID`、`conversationID`、发送/接收设备 ID、版本、Ratchet 公钥、前一发送链长度、消息序号、会话版本、首次会话握手头、随机 nonce、AES-GCM 密文及认证标签。除密文内的 `kind`、UserID、文字和编辑版本外，这些头字段及长度/时序信息均可被服务器看到；固定顺序、长度前缀的头编码作为 AES-GCM AAD。首次握手头的身份与设备绑定签名也参与认证。

客户端先验证后端返回的 P-256 账号身份与本地固定指纹一致，再验证其对 v4 Curve25519 身份的绑定签名、Signed PreKey 的 Ed25519 身份签名及版本。私钥和 Ratchet 链只保留在 Keychain；接收后的正文重新以本地 v1 Master Key 加密。v4 控制事件使用同一逐设备 Ratchet 链：密文内的 `V4EventEnvelope` 包含事件 ID、原消息 ID、会话 ID、操作者、类型、revision、可选正文或 Emoji 操作；外层只暴露路由元数据。接收端核对密文内外绑定后才应用编辑、删除、已读和 Reaction。后端将外层 UUID 规范化为小写再做会话比较和幂等判断；编码大小写不改变密文头认证数据。旧版读取保持不变。两个独立模拟器已通过本地后端闭环，实体设备与独立审计前不能宣称完整 E2EE。

## v4 附件载荷（客户端已实现，跨设备附件联调待验证）

在线附件仍使用 `POST /v1/messages`、`encryptionVersion=4` 和逐设备 `recipientEnvelopes`。外层新增 `attachmentIDs`，服务器可见随机对象 ID 并据此将已上传密文对象绑定到消息。每个 Ratchet 密文正文的 `kind=attachment`，内含发送/目标 UserID 以及 `V4AttachmentDescriptor`：本地随机附件 ID、服务器对象 ID、消息/会话 ID、图片/文件/语音类型、原文件名、随机 256 位附件密钥和 SHA-256 密文哈希。服务器看不到这些正文成员、文件名、密钥或缩略图明文；文件服务另可见对象大小与密文哈希。文件使用独立 AES-GCM，AAD 绑定附件、消息、会话 ID 和类型；AES-GCM combined 字节包含随机 nonce、密文和认证标签。接收端先验证 Ratchet 消息及描述绑定，再按哈希和认证标签校验下载文件。旧 v1/v2/v3 读取不变。


## v4 Reaction 操作顺序（CA-01 修复）

`encryptionVersion=4`、Ratchet 头、Backend API 及正文 `revision` 均不变。新 Reaction 的 `V4EventEnvelope` 增加可选字段，位于 **Ratchet 加密并认证的载荷内部**：

```json
"reactionOrder": { "version": 1, "counter": 8 }
```

- `version=1`；`counter` 是精确 JSON 无符号整数，范围 `1 ... UInt64.max-1`。其他版本、零、负数或溢出拒绝，不降级。非 Reaction 事件不得携带此字段。
- 操作 ID 复用既有的认证 `eventID`；账号、操作者设备、会话、原消息、正文 revision、Emoji、add/remove 和 occurredAt 仍在同一 AEAD 载荷中，且经过既有内外路由绑定检查。计数不上传到外层路由。
- 每个 `(会话, 消息, 操作者账号)` 是一个独立寄存器。本机生成新操作时，读取该操作者已接受的最大计数和加密待发队列中的最大计数，加一后与事件一起持久化；离线重试保留原 ID、计数和精确密文，不重新编号。
- 接收端在认证后比较 `(counter, actorDeviceID 原始16字节, eventID 原始16字节)`，字典序较大者生效。设备观测过某操作后生成的操作具有更大计数；未相互观测的多设备操作以该规则确定性合并，**不承诺按现实时间选择“最后一次点击”**。同设备异常地重复计数也以 eventID 确定性决胜，正常生成器不重复分配。
- 不使用正文 revision、服务器 `deviceSeq`/cursor/createdAt、Ratchet messageIndex 或 DH 公钥作为业务顺序。计数由认证的操作者生成；它不证明恶意或失陷操作者诚实，不能用于授予其他操作者的权限。

### 持久化、移除和接收事务

`Message.encryptedReactionState` 是新增可选字节字段：Master Key AES-GCM 加密的版本 1 账本，AAD 绑定 ownerID、消息本机会话 ID 和消息 ID。内容为每个操作者的胜出操作戳，以及每个已接受操作 ID 的完整解码事件摘要（SHA-256，Swift JSONEncoder sortedKeys）；不保留历史 Emoji 明文或消息密钥。摘要是本机幂等记录，不是新的签名方案或跨语言规范编码。

移除会删除可见 `Reaction` 行，但保留操作戳和摘要。相同 ID、相同事件幂等；相同 ID、不同内容拒绝，保留接收 journal，不确认游标。合法旧操作记录摘要但不改可见状态，**仍通过原 Ratchet 接收事务提交**。不同操作者互不覆盖。

账本与可见 Reaction 在同一 SwiftData save 中提交。失败保留原接收 journal，重试使用原认证明文；游标只有在业务保存后推进，随后提交 Ratchet 并 ack。账号切换和身份校验沿用现有门禁。删除/过期目标不恢复正文、附件或 Reaction；独立 `MessageTombstone` 可保留嵌套加密账本，只恢复空隐藏行。

### 兼容与恢复限制

- 旧行没有账本时按空账本读取，已有 Reaction 只作为未排序的历史展示快照，**不伪造历史操作版本**。第一份新版有序操作可替换快照。
- 旧 v4 Reaction 没有 `reactionOrder`（包括已有待发密文）：仍须完整认证、权限/版本检查及原链提交，但不修改 Reaction。不得为已经准备或提交的旧密文补写新版本或重新加密。
- 未知新版本安全暂停，不转为旧路径。旧客户端会忽略新增 JSON 字段，仍存在原到达顺序问题；只有升级客户端执行本规则。混合版本期间，旧设备的 Reaction 变化不会应用到新客户端；不能宣称整个设备集合已收敛。发布前需明确最低兼容版本/升级安排，本轮不增加未经认证的能力协商。
- v1/v2 本地操作不变。v3 历史创建和带签名 revision 的编辑继续读取；v3 Reaction 的后续受限处理见下节。
- 在线消息的便携备份导出/覆盖门禁不变；不新增丢弃账本的恢复路径。保留原数据库及 Keychain 才能维持状态。完整旧快照回滚、旧二进制降级写入和实际历史库升级仍需外部验收，不能从已丢失数据推断删除事实。
- 摘要随消息/删除证据保留，不按时间裁剪。长期高频操作会增加本机账本体积；不能仅为节省空间移除唯一的冲突检测证据。

## v3 历史 Reaction 限制（D-02）

v3 Reaction 的 P-256 签名与 AES-GCM 认证覆盖信封，但加密正文只有 `kind/senderUserID/targetUserID/text`，没有认证的操作 ID、增删动作或全局/因果顺序。无 OTP 的合法旧信封能重复解密；即使每个信封使用不同 OTP，服务器仍能把合法旧操作延迟到新操作之后投递。外层 `eventID/deviceSeq/createdAt` 由服务器控制，不能补作业务版本。

升级客户端接收 `reaction.added` 时仍校验 v3 信封签名、AEAD、固定身份、会话/设备和正文身份；已有目标必须属于同一 v3 会话。合法事件随后仅作无状态消费，不改可见 Reaction；目标已物理删除时也不重新创建。既有本地 Reaction 行保留为历史快照，不由其推断先后或生成伪操作墓碑。当前客户端停止向 `/messages/reaction` 发送 v3 操作，保留 v4 有序 Reaction；旧式已读/删除仍只作通知消费。历史 v3 文字消息及签名 revision 编辑读取不变：若本机保留已删除的目标行，合法迟到编辑只推进 revision，不恢复正文；目标已物理删除且没有可信归属证据时仍暂停，不能凭路由猜测并跳过。

当前服务端已移除旧 v3 Reaction 写入口，也拒绝新 v3 消息写入；历史同步队列中已存在的密文仍按上述受限规则读取，不从缺失的因果证据恢复旧快照。当前在线协议和失败行为见[客户端与服务器协议](Client_Server_Protocol.md#当前在线协议与历史读取边界2026-10-26)。
