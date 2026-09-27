# 数据模型

## 当前 SwiftData 模型（已实现）

| 模型 | 关键字段与关系 | 存储边界 |
| --- | --- | --- |
| `User` | `id`、唯一 `userID`、`nickname`、头像/简介、`identityPublicKey`、`identityFingerprint`、`encryptedPreferences` | `passwordHash` 是本地验证值，不是明文密码；`searchable` 为本机发现标志。 |
| `Device` | `id`、`ownerID`、设备名、系统版本、`publicKey`、创建与最后活动时间 | 私钥在 Keychain，当前只表示本机设备。 |
| `Friend` | `id`、`ownerID`、对方 `userID`、昵称、`encryptedRemark`、身份指纹、会话状态、待核验指纹 | 备注经主密钥加密；旧 `remark` 是迁移字段。身份变更状态阻止旧在线信封继续发送。 |
| `Conversation` | `id`、`ownerID`、`friendID`、`draft`、聊天锁、置顶、未读数 | `draft` 为加密字节；关系和计数仍是元数据。 |
| `Message` | `id`、`conversationID`、`senderID`、类型、`ciphertext`、时间、状态、回执/编辑/删除时间、`deviceID`、`lastEventID`、`encryptionVersion`、`sessionKeyVersion`、`messageKeyIndex` | 正文在 `ciphertext`；`content` 仅供旧版迁移，新记录为空。 |
| `Attachment` | `id`、`messageID`、类型、`encryptedMetadata` | 真实附件上传尚无；旧路径字段仅供迁移。 |
| `SessionKey` | `id`、`ownerID`、`friendID`、版本和时间 | 只存元数据，密钥在 Keychain。 |
| `PreKeyMetadata` | `id`、`ownerID`、类型、公钥/签名/指纹、使用时间 | 私钥在 Keychain。 |
| `V4DeviceMetadata` / `V4SessionMetadata` | 后端设备 ID、版本、好友关联、发布/更新时间和状态 | 只存元数据；v4 身份私钥、预密钥私钥、Ratchet 根/链密钥和待提交记录在 Keychain。 |
| `ChainState` | `sessionID`、发送者、链版本、消息序号 | 链密钥在 Keychain；此模型只记进度。 |

辅助模型：`Reaction` 保存本机回应，`UserPresence` 保存本机模拟在线记录，`SearchIndexEntry` 保存加密索引。`MessageEvent` / `ReadReceiptEvent` 是 Codable 事件结构，目前由 Mock 流程使用，**不是**持久化的服务端事件表。

稳定性模型：`OutgoingMessageQueueItem` 按本地用户及后端设备保存 AES-GCM 加密的待发文字意图或完整 v3 请求，状态为 pending/sending/sent/failed/identityChanged；不会保存明文正文。`CleanupState` 记录账号删除的 started/processing/completed/failed 阶段，备份恢复细分为 preparing/restoring/verifying/completed/failed；恢复清理清单使用主密钥加密，完成后删除标记。

## 关系与迁移

当前关系主要靠 UUID 字段关联，而非 SwiftData 的显式 `@Relationship` 级联约束；删除时由服务层按 owner → friend → conversation → message → attachment/reaction 等范围清理。旧可选字段按默认值解释：旧消息缺少 `encryptionVersion` 时按 v1 读取。登录解锁阶段迁移旧明文消息与隐私字段，验证成功后清空兼容字段。迁移前的物理残留不能据此认定已彻底擦除。

未来服务器的 `users`、`devices`、`messages` 等表是独立设计，不能把 SwiftData 模型直接当作后端 Schema。见[数据库设计](../Backend/Database_Schema.md)。
