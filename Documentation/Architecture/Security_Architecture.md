# 客户端安全架构

## 当前密钥与数据流

```text
本地密码 ──PBKDF2 验证──→ 允许登录
本地 PIN / Face ID ──门禁──→ 解锁应用会话
Keychain 中的随机 Master Key ──AES-GCM──→ 本地消息和选定私密字段

Identity 私钥（Keychain） + 本机模拟对端公钥
    └─P-256 ECDH/HKDF→ Session 根密钥（Keychain）
        └─基础对称链→ 每条 v2 消息密钥
Device 私钥、PreKey 私钥分别在 Keychain；SwiftData 留公钥与元数据
```

**已实现**：本地密码只用于验证，不直接派生 Master Key。Master Key 由系统随机生成。身份/设备密钥和会话根密钥分开存储；私钥不进入 SwiftData。解锁后内存持有 Master Key 引用，锁定或退出清除引用。旧账号在验证后补建身份、设备和签名预密钥，但不静默轮换 Master Key。

**安全边界**：Face ID 与 PIN 是应用访问门禁，不是 Master Key 的第二层硬件封装。Identity/Device P-256 私钥当前为软件生成并保存在 `WhenUnlockedThisDeviceOnly` Keychain 条目，未使用 Secure Enclave。本机 v2 不认证真实远端身份；PreKey 尚未参与根密钥协商；保留会话根密钥使旧消息密钥可重算，所以不具备前向保密。当前没有真实服务器 E2EE。

SwiftData 只保护指定敏感字段：消息正文、草稿、好友备注、偏好、索引和附件元数据；UserID、昵称、头像、会话关系、消息时间与状态等仍为明文元数据。迁移清空旧字段不保证 SQLite 历史页或系统备份被物理擦除。详情见[隐私模型](../Security/Privacy_Model.md)。

账号删除尝试清理本地数据、临时备份、附件目录及 Master/Identity/Device/Session/PreKey/Chain 密钥。Keychain 与 SwiftData 没有跨存储原子事务，错误需提示和复查。加密备份使用独立密码与随机盐，不包含登录状态、验证值或 Keychain 密钥；恢复到同一 UserID 后把消息重新加密为本地 v1。

账号删除现在先持久化 `CleanupState`，启动时可继续尚未完成的文件、SwiftData 和 Keychain 清理。备份恢复先校验完整归档，在单个 SwiftData 事务中替换数据；提交后以加密的清理清单删除旧会话密钥与附件文件，应用再次解锁时可续行。两者均不声称跨存储原子性；恢复前数据库提交失败时保留旧数据。

恢复标记现区分 `preparing`、`restoring`、`verifying`、`completed`、`failed`。事务提交后会复核本机 Master/Identity/Device Key 与附件元数据，再清理旧密钥及文件；失败标记在下次解锁时重试。备份不包含附件字节，恢复时不会沿用旧本机文件路径。好友身份公钥变化会保存待核验指纹并暂停旧会话，用户通过可信渠道核对后才更新身份固定值；旧 v2 会话保留供历史消息读取，但不得再用于发送。

RC 验收发现：现有备份不保存服务端游标和已消耗的一次性私钥，直接恢复在线 v3 历史可能跳过事件或无法重放。恢复前现会检查备份与当前账号的在线消息、待发队列及游标；存在这些状态时明确拒绝恢复且不替换数据。在线历史的可恢复方案仍需单独设计。
