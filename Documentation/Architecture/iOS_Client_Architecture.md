# iOS 客户端架构

## 当前结构（已实现）

```text
SwiftUI View → ViewModel → Repository → Service → SwiftData / Keychain / CryptoKit
                                   ↘ SyncCoordinator → Mock / Remote Provider
                                   ↘ OnlineConnectionViewModel → Remote Repository/Provider
```

工程以 `Luma/App` 作为入口，`Features` 承载 Authentication、Chat、Friends、Settings 页面；`ViewModels` 协调页面动作；`Repositories` 隔离消息与本地账号读写；`Core/Storage` 保存密文与可恢复的本地索引；`Core/Crypto` 管理算法与会话密钥；`Core/Security` 管理账号锁定和密钥生命周期；`Core/Events`、`Core/Sync`、`Core/Transport`、`Core/Network` 提供未来通信边界。

默认本地聊天路径为 `ChatViewModel → MessageRepository/LocalMessageRepository → MessageStore → EncryptionService → SwiftData`，新消息使用 v1。显式在线模式由 `ChatViewModel → RemoteMessageRepository` 发送 v4 逐设备密文；接收端验证后将可显示内容重新加密为本机 v1。v2/v3 历史读取保持兼容。本机 Mock 同步只在进程内模拟。

## 模块职责

| 模块 | 当前职责 |
| --- | --- |
| Chat | 列表、详情、输入、消息操作、已读与未读 UI。 |
| Friends | 本地联系人、备注、资料与本机模拟在线状态。 |
| Settings | 账号、隐私中心、设备信息、存储管理和加密备份。 |
| Crypto | 本机 AES-GCM、身份/设备密钥、PreKey、v4 握手及独立收发 Ratchet 链。 |
| Sync | 事件应用与 Mock 队列完成；失败事件可重试。 |
| Network | Mock 保留本地模拟；Remote API/设备认证、账户与好友请求已接入后端接口。v4 在线文字与控制事件通过隔离后端和两个模拟器验证；双实体设备及附件全链路未验收。 |

`MessageRepository` 是 UI 的消息读写边界。少数设置/资料页面仍直接使用本地 `ModelContext` 读取非消息模型，因此图示是主要路径，不是全工程已强制执行的纯净架构规则。在线连接由设置页显式发起，经 `OnlineConnectionViewModel` 调用远端 Repository/Provider；本地仓储仍是离线数据源。线上 v4 接收内容重新加密为本地 v1。双实体设备未验证。

## 开发约束

新增字段采用兼容默认值并验证旧 SwiftData/备份读取；加密和 Keychain 操作放在 Service/Repository；所有远端送达、在线、E2EE 状态必须由可验证事件驱动。具体数据关系见[数据模型](Data_Model.md)，安全边界见[安全架构](Security_Architecture.md)。

## 在线 v4 路径（文字和控制事件已通过隔离后端验证）

```text
ChatDetailView → ChatViewModel → RemoteMessageRepository
                              ├→ V4MessageSessionService / V4SessionVault / PreKey
                              ├→ RemoteAPIClient → 后端密文 API
                              └→ RemoteSyncCoordinator → RemoteMessageSyncProvider
                                                      → MessageStore → SwiftData(v1 本地密文)
```

在线模式必须由用户显式选择并先核对好友身份安全码。公钥与预密钥版本由本地信任记录约束，身份变化会暂停发送。`RemoteSyncCheckpoint` 保存逐设备连续游标；待发队列保存加密请求供幂等重试。v4 覆盖文字、编辑、删除、已读、Emoji 回应以及独立密钥加密的图片/文件/语音附件代码。附件经两台实体设备和真实后端的完整闭环、崩溃恢复与独立安全审计仍未完成。详见 [E2EE 设计](../Crypto/E2EE_Design.md)。
