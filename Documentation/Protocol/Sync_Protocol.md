# 游标与事件同步协议

**状态：部分实现。** 当前 `SyncCoordinator` 仍只处理进程内 Mock 邮箱。`RemoteMessageSyncProvider` 可读取后端游标事件，`WebSocketTransport` 可收到提示后触发事件检查；v3 在线文字聊天现已实现验证、落盘和逐事件 ack，并持久化服务端游标。隔离的本机 HTTPS 后端与模拟器中两个独立账号已验证发送、同步、已读、编辑和删除；双实体设备尚未验证。APNs 未接入。

## 可靠性模型

服务器为每个目标设备分配单调 `deviceSeq`，将事件及密文信封写入 PostgreSQL；`eventID` 全局唯一。客户端调用 `GET /v1/sync/events?cursor=...&limit=...`，按序验证、去重、写入本地存储后，再用 `POST /v1/sync/ack` 确认**最高连续且已经持久化**的序号。服务端可重复投递，客户端按 `(targetDeviceID,eventID)` 幂等处理；不能以“收到 WebSocket”代替落盘或 ack。

```text
离线/重连 → 带上上次已落盘 cursor 拉取 → 验证与本地应用 → ack
在线提示(WebSocket) ────────────────────────────┘
APNs 唤醒 ────────────────────────────────────┘
```

发送端使用稳定 `messageID` / `Idempotency-Key` 重试；同一键同一内容返回原结果，不同内容返回冲突。网络失败后保留待发队列，指数退避并在恢复时补发。客户端不得将本地“已发送”直接升级为“已送达”；只有目标设备持久化并产生回执后才记录 delivered，read 必须由接收端隐私设置允许且由明确事件产生。编辑、删除、Reaction 同样按事件版本/权限与消息序列处理，迟到事件不得覆盖更新状态。

WebSocket 为低延迟提示，使用同一认证上下文。事件帧草案：

```json
{
  "protocolVersion": 1,
  "eventID": "f3357137-184b-4bb6-8bf8-34ac12f9632f",
  "deviceSeq": 184,
  "type": "message.created",
  "createdAt": "2026-09-25T08:00:00Z",
  "payload": { "messageID": "78fda1d8-e1a5-4b83-9b8a-d28e8a72c801" }
}
```

支持类型：`message.created`、`message.delivered`、`message.read`、`message.deleted`、`message.edited`、`reaction.added`、`typing.started`、`typing.stopped`、`presence.updated`。持久事件经游标同步；typing/presence 是有 TTL 的短暂状态，不保证离线回放。游标过期或事件压缩时返回 `resync_required`，客户端做授权快照对账，不应凭空跳过事件。服务端保留期、冲突解决和墓碑有效期在上线前冻结。

| 事件 | 未来负载要点 | 持久性 |
| --- | --- | --- |
| `message.created` | `messageID`、目标设备密文信封引用 | 持久 |
| `message.delivered` / `message.read` | `messageID`、回执设备、时间；已读受隐私开关限制 | 持久 |
| `message.deleted` / `message.edited` | `messageID`、操作版本、删除墓碑或新的密文信封 | 持久 |
| `reaction.added` | `messageID`、回应 ID 与受保护负载 | 持久 |
| `device.revoked` | 同账号被撤销的设备 ID；客户端删除对应信任记录并暂停旧待发信封 | 持久 |
| `typing.started` / `typing.stopped` | 会话 ID、短 TTL | 临时 |
| `presence.updated` | 允许公开的状态及更新时间 | 临时 |

WebSocket 握手必须绑定已认证的设备；帧中的 `actorID` 不是授权依据。收到提示后仍从 HTTPS 持久事件源取数。APNs 只发通用“收到新消息”及非敏感唤醒标识，不能放消息正文，也不能以推送成功判定送达。

## v3 客户端实现增量

`RemoteMessageRepository.sync` 使用每账号/后端设备的 SwiftData `RemoteSyncCheckpoint`，逐条要求 `deviceSeq` 连续。`message.created`/`message.edited` 的信封验签解密并以 Master Key 重加密落盘；删除、送达、已读回执应用到本地模型。落盘后发送送达回执，随后推进本地 cursor 并调用 `/v1/sync/ack`。解密失败、缺少预密钥、身份未固定或未知事件时停止，不 ack 该事件。当前聊天页在线模式以 10 秒间隔拉取；WebSocket 通知接口仍保留，但聊天页未用它唤醒同步。

新生成的 `message.edited` v3 密文正文包含 `revision`；接收端要求它与服务端事件的版本相同。旧版未携带此字段且尚未应用的编辑事件会停在当前 cursor，需在迁移方案确定后处理，不能将未认证的路由版本直接用于覆盖正文。

**当前补充**：在线文字待发项以本地主密钥 AES-GCM 保护并持久化，最多自动尝试 5 次，失败后保留条目供用户手动重试；网络恢复且应用解锁时定期重试。设备撤销在服务端事务中撤销令牌、清理预密钥并给仍有效的同账号设备追加 `device.revoked` 事件。客户端按游标处理事件，删除对应信任记录并暂停旧待发信封；被撤销设备的 HTTP 访问返回 `device_revoked`，客户端清理本地在线会话。服务端 WebSocket 连接收到撤销后关闭，并有周期性认证复核。

**限制**：服务端事件的删除/回执仅由服务器授权，不含端侧签名；会话版本冲突、已失败队列的自动重组及多设备撤销后的恢复需要进一步联调。线上部署与双实体设备闭环尚未验证。
