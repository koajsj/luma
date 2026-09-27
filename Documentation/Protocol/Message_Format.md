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

上例是早期 API 草案，不是当前信封 JSON。当前 v3 编码见下节；附件密钥封装、控制事件端侧认证和正式版本协商仍未完成。服务器可见会话、参与设备、时间、大小和版本等路由元数据。

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
