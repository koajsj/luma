# iOS 客户端架构

## 当前结构（已实现）

```text
SwiftUI View → ViewModel → Repository → Service → SwiftData / Keychain / CryptoKit
                                   ↘ SyncCoordinator → Mock Provider
                                   ↘ OnlineConnectionViewModel → Remote Repository/Provider
```

工程以 `Luma/App` 作为入口，`Features` 承载 Authentication、Chat、Friends、Settings 页面；`ViewModels` 协调页面动作；`Repositories` 隔离消息与本地账号读写；`Core/Storage` 保存密文与可恢复的本地索引；`Core/Crypto` 管理算法与会话密钥；`Core/Security` 管理账号锁定和密钥生命周期；`Core/Events`、`Core/Sync`、`Core/Transport`、`Core/Network` 提供未来通信边界。

正式聊天路径为 `ChatViewModel → MessageRepository/LocalMessageRepository → MessageStore → EncryptionService → SwiftData`。`MessageEncryptor` 可按版本选择本机主密钥或模拟会话密钥；正式聊天发送保持 v1。本机 Mock 同步路径为 `SyncCoordinator → MessageSyncProvider → MockMessageTransport`，仅在进程内模拟，不是现有聊天界面的远端消息源。

## 模块职责

| 模块 | 当前职责 |
| --- | --- |
| Chat | 列表、详情、输入、消息操作、已读与未读 UI。 |
| Friends | 本地联系人、备注、资料与本机模拟在线状态。 |
| Settings | 账号、隐私中心、设备信息、存储管理和加密备份。 |
| Crypto | AES-GCM、P-256 密钥、本机会话、PreKey、基础链式派生。 |
| Sync | 事件应用与 Mock 队列完成；失败事件可重试。 |
| Network | Mock 保留本地模拟；Remote API/设备认证、账户与好友请求已经接入后端接口。v3 在线文字发送和事件落盘通过隔离后端与模拟器双账号验证；双实体设备未验证。 |

`MessageRepository` 是 UI 的消息读写边界。少数设置/资料页面仍直接使用本地 `ModelContext` 读取非消息模型，因此图示是主要路径，不是全工程已强制执行的纯净架构规则。在线连接由设置页显式发起，经 `OnlineConnectionViewModel` 调用远端 Repository/Provider；本地仓储仍是离线数据源。默认聊天仍使用本地 v1；显式在线模式通过 v3 逐设备信封传输，并在接收后重新加密为本地 v1。隔离后端与模拟器双账号闭环已验证，双实体设备未验证。

## 开发约束

新增字段采用兼容默认值并验证旧 SwiftData/备份读取；加密和 Keychain 操作放在 Service/Repository；所有远端送达、在线、E2EE 状态必须由可验证事件驱动。具体数据关系见[数据模型](Data_Model.md)，安全边界见[安全架构](Security_Architecture.md)。

## v3 在线文字路径（已通过隔离后端验证，未完成双实体设备验证）

```text
ChatDetailView → ChatViewModel → RemoteMessageRepository
                              ├→ DeviceSessionManager / Keychain / PreKeyManager
                              ├→ RemoteAPIClient → 后端密文 API
                              └→ RemoteSyncCoordinator → RemoteMessageSyncProvider
                                                      → MessageStore → SwiftData(v1 本地密文)
```

在线模式必须由用户显式选择并先核对好友身份指纹。每个设备的公钥与 Signed PreKey 版本由 `RemoteDeviceTrust` 固定，旧版本或同版本公钥变化会拒绝发送。`RemoteSyncCheckpoint` 保留每个后端设备的最高连续已落盘序号。默认本地模式、v1/v2 读取与 Mock Provider 保持独立。在线文字发送先写入本地 v1 密文和 `OutgoingMessageQueueItem`，联网后生成 v3 信封并保存加密请求供幂等重试。当前在线模式仅覆盖文字、编辑、删除、Emoji 回应及送达/已读回执；文件信封与完整新设备授权恢复仍未完成。
