# 密钥管理与生命周期

## 当前实现

| 密钥 | 用途与生成 | Keychain | SwiftData |
| --- | --- | --- | --- |
| Master Key | 每本机账号 256 位系统安全随机数，用于本地 AES-GCM | 原始密钥，`WhenUnlockedThisDeviceOnly` | 不存密钥 |
| Identity Key | CryptoKit P-256 密钥协商身份对 | 私钥 | 公钥和 SHA-256 指纹在 `User` |
| Device Key | 当前设备独立 P-256 密钥协商对 | 私钥 | 公钥与设备元数据在 `Device` |
| Session Key | 本机模拟 ECDH/HKDF 派生，按版本保存 | 会话根密钥 | `SessionKey` 仅保存关系、版本和时间 |
| Signed PreKey | P-256 预密钥，身份私钥对其公钥签名 | 私钥 | 公钥、签名、指纹、时间在 `PreKeyMetadata` |
| One-Time PreKey | 本机初始化池默认生成 100 个 | 未用私钥 | 公钥及 `usedAt`；消耗时删除私钥 |
| Chain Key | v2 基础对称链当前状态 | 当前链密钥 | `ChainState` 只保存序号和链版本 |

`KeychainManager` 提供读、必需读、保存/更新、删除，并区分不存在、损坏和系统状态错误。`KeyLifecycleManager` 在新账号创建时创建 Master/Identity/Device/Signed PreKey/一次性密钥池；旧账号解锁时校验现有 Master Key 并补齐可兼容密钥。现有 Master Key 丢失时不得自动生成替代值，否则旧消息无法解密。

锁定时 `SecurityManager` 清除内存中的解锁密钥引用；实际 Keychain 条目的访问由设备解锁状态限制。删除好友会清理对应会话和链状态；删除账号会清理该账号的本地密钥、预密钥记录、会话链与数据。Keychain 和 SwiftData 非原子事务，清理失败必须保留错误并复核残留。

## 不应混淆的边界

本地密码/PIN 保存的是带盐的 PBKDF2-SHA256 验证值，密码不作为 Master Key。备份密码用于独立的备份密钥派生，不导出上述 Keychain 密钥。身份/设备密钥当前并非 Secure Enclave 硬件密钥，也未通过服务器完成可信发布。一次性 PreKey 不参与旧 v2 Session Key 派生；v3 设备信封会在有可用预密钥时混入 ECDH，成功落盘后清理对应私钥。未来多设备须定义每设备身份认证、密钥目录变更通知、撤销与恢复策略。

## v3 密钥使用补充

v3 每个目标设备临时生成 P-256 密钥，结合其 Device Key、已由身份密钥签名的 Signed PreKey、可选一次性 PreKey 派生该信封专用 AES-GCM 密钥。临时私钥与消息密钥只在发送/接收调用期间使用，不进入 SwiftData、文件或日志。收到消息并以 Master Key 重加密落盘后，客户端标记并删除对应一次性私钥；中断后重放同一事件会继续清理。`RemoteDeviceTrust` 只保存公钥与版本以拒绝回滚。删除账号会清理本地身份/设备/预密钥和信任元数据；本阶段 v3 不持久化 Session Root 或链密钥，也不能宣称完整前向保密。

v4 为每个已登记设备生成独立 Curve25519 身份协商键、Ed25519 签名键、Signed PreKey 和一次性 PreKey 池。P-256 账号身份私钥对该设备的 v4 公钥与版本作绑定签名；后端仅发布公开材料。`V4SessionVault` 以 `WhenUnlockedThisDeviceOnly` Keychain 项保存私钥、会话 Root/Chain/Ratchet 状态及中断恢复记录；SwiftData 的 `V4DeviceMetadata` 和 `V4SessionMetadata` 只保存非密钥字段。已用的一次性私钥在接收消息和游标持久化后删除；好友身份变化、设备撤销和账号删除清理相关会话材料。Keychain 项不随加密备份导出；换机或丢失该设备密钥后不能用旧备份恢复 v4 会话，需要重新建立。两个独立模拟器已验证在线收发与控制事件；实体设备重启恢复、密钥故障注入和独立安全审计仍未完成。

附件每次新建独立随机 AES-GCM 密钥；它随附件描述通过 v4 逐设备 Ratchet 密文分发，不上传为独立服务器字段。本机仅在 Master Key 加密的 `Attachment.encryptedMetadata` 中保存恢复下载所需材料，不存明文密钥字段。删除消息、好友或账号时清理对应本机描述和缓存；历史加密备份或已下载的对端副本不受远端删除控制。
