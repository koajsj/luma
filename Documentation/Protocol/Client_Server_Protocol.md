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

聊天页显式选择“在线密文聊天”后，经 `ChatViewModel → RemoteMessageRepository → RemoteAPIClient` 发送文本。`GET /v1/friends` 提供已确认好友路由 UUID；`GET /v1/users/{id}/prekey-bundle?claim=false` 仅供身份指纹核对，不占用一次性预密钥。正常发送领取公钥束并为每个活动目标设备生成信封。`GET /v1/sync/events` 按连续游标应用到本地加密存储；聊天页定时拉取。后端仍只接收公钥、路由元数据和密文。

隔离的本机 HTTPS 后端与模拟器中的两个独立账号已完成文字消息、编辑、删除和回执联调；两个实体设备尚未验证。首次身份固定必须通过可信渠道核对，点击“已核对”本身不构成身份保证。持久待发队列与已登记设备撤销已加入代码；文件、完整新设备授权恢复与完整实时通知仍待后续完成。
