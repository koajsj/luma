# 游标与事件同步协议

**状态：部分实现。** 当前 `SyncCoordinator` 仍只处理进程内 Mock 邮箱。`RemoteMessageSyncProvider` 可读取后端游标事件，`WebSocketTransport` 可收到提示后触发事件检查；v4 在线文字及认证控制事件已有验证、落盘和逐事件 ack，并持久化服务端游标；v3 仅保留历史读取。隔离的本机 HTTPS 后端与模拟器中两个独立账号已验证发送、同步、已读、编辑和删除；双实体设备尚未验证。APNs 未接入。

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

## 历史 v3 同步读取边界

`RemoteMessageRepository.sync` 使用每账号/后端设备的 SwiftData `RemoteSyncCheckpoint`，逐条要求 `deviceSeq` 连续。`message.created`/`message.edited` 的信封验签解密并以 Master Key 重加密落盘；送达作为服务器传输提示应用。v3 已读/删除没有端侧认证，现只消费通知，不改变本地已读、删除或 revision。仅 v4 创建事件在落盘后发送传输送达提示，随后推进本地 cursor 并调用 `/v1/sync/ack`。解密失败、缺少预密钥、身份未固定或未知事件时停止，不 ack 该事件。当前聊天页在线模式以 10 秒间隔拉取；WebSocket 通知接口仍保留，但聊天页未用它唤醒同步。

一次性 PreKey 私钥只在消息和本地 cursor 均落盘后删除；如果删除被中断，下次同步会清理已标记消耗的私钥。消息已落盘但 cursor 未推进时重放同一创建事件应按 `eventID` 幂等处理，不能提前销毁重放可能需要的密钥。

新生成的 `message.edited` v3 密文正文包含 `revision`；接收端要求它与服务端事件的版本相同。旧版未携带此字段且尚未应用的编辑事件会停在当前 cursor，需在迁移方案确定后处理，不能将未认证的路由版本直接用于覆盖正文。

**当前补充**：在线文字待发项以本地主密钥 AES-GCM 保护并持久化，最多自动尝试 5 次，失败后保留条目供用户手动重试；网络恢复且应用解锁时定期重试。设备撤销在服务端事务中撤销令牌、清理预密钥并给仍有效的同账号设备追加 `device.revoked` 事件。客户端按游标处理事件，删除对应信任记录并暂停旧待发信封；被撤销设备的 HTTP 访问返回 `device_revoked`，客户端清理本地在线会话。服务端 WebSocket 连接收到撤销后关闭，并有周期性认证复核。

**v3 兼容限制**：保留历史内容读取及认证编辑；停止发送旧版已读通知，旧消息的“删除双方”返回不支持，本机删除仍可用。已在旧客户端应用的删除/已读状态不自动回退，也不声称可以补证其真实性。需要远端已读/删除时使用 v4 认证事件；不自动升级旧密文或降低 v4 校验。已失败队列的自动重组及多设备撤销后的恢复需要进一步联调。线上部署与双实体设备闭环尚未验证。

## v4 消息提交边界

新在线文字消息在加密后逐设备形成 v4 信封。本地待发项保存精确请求后才将发送链状态写入 Keychain；网络重试沿用原信封与 `Idempotency-Key`。接收时先验证设备身份和信封，在 Keychain 暂存候选 Ratchet 状态；本地消息和游标持久化后，再完成 Ratchet 状态与一次性预密钥的更新，最后 ack。重启时依据已落盘游标继续完成待提交记录。状态缺失、版本冲突或解密失败时停止同步，不跳过事件。

v4 编辑、删除、已读和 Reaction 由客户端逐设备生成 Ratchet 密文事件，经 `/messages/v4/events` 存储与分发。接收端核对操作者、原消息、会话、revision 和事件 ID 后才落盘并推进游标。编辑与删除要求下一 revision；已读与 Reaction 可引用不超过当前版本的历史 revision，以容纳离线期间的编辑。旧在线控制接口已移除。待发事件本地加密保存并按创建顺序、事件 ID 幂等重试；连续网络失败不会在第五次后永久堵塞后续事件。两个独立模拟器已通过本地后端的文字/控制事件闭环及一次离线编辑重试；实体设备、强制退出、同步故障注入、服务端篡改与密钥变化的跨设备联调仍是发布前门槛。

Release Candidate 增量：本地 Mock 事件经 `EventVerifier` 检查操作者、会话归属与 v1/v2 版本；在线 v4 送达提示只表示传输状态，不提供端侧已读认证。好友身份公钥变化时保存待核验指纹，停止发送已准备的旧信封，用户重新核对前不建立新会话。旧 v3 删除/已读现为不改变内容的兼容通知；v4 的编辑、删除、已读及 Reaction 由 Ratchet 密文认证，送达不能视为端侧已读证明。

发送与接收事务不能交叉派生 legacy v4 Ratchet：存在未完成接收 journal 时拒绝新的发送准备，存在未完成发送 journal 时拒绝新的接收推进；原样 journal 重试仍保留。等待事务不消耗待发队列的网络重试次数。消息已保存但游标未提交的创建重投，还须匹配 journal 的 eventID、deviceSeq 和密文摘要，不能仅凭服务器 eventID 跳过校验。发送正文/控制事件在 Token 刷新后、交给 URLSession 前再次检查账号、固定身份及待发项；这不能撤回已经发出的密文。上述策略不改变 Ratchet 算法、信封格式或 Recovery 默认关闭状态。

v4 控制事件现在集中由 `V4EventVerifier` 核对路由设备、目标设备、会话、加密版本、消息索引，再在 Ratchet 解密后核对事件 ID、操作者、类型及 revision。签名验证仍是未来扩展点；当前真实性依赖已固定身份的会话密钥与 AES-GCM 认证。状态写入或验证失败时不得确认游标。Keychain Crypto Transaction 状态可在重启后按已提交本地游标重放；`failed` 记录保留原请求供恢复，不自动跳过失败事件。

Final Hardening：会话状态另有 Keychain 单调版本高水位；候选 Ratchet 状态若落后，待提交记录会保留并停止同步，不能用旧链覆盖新链。`GET /v1/devices/{id}/v4-prekeys/status` 仅供已认证的本设备查询剩余一次性公钥数量，客户端低库存时幂等补充。默认领取公钥束会跳过未就绪或一次性 PreKey 耗尽的设备，并在响应头标明跳过数量；没有可用设备时返回 409，不会降级为缺少一次性 PreKey 的握手。发送端仍须满足消息路由的全部活动目标设备校验，部分 Bundle 不代表消息可发送。此流程不改变 v4 信封格式或事件格式。

### 历史 v4 删除证据（本机持久化补充）

独立的 Master Key 加密墓碑只来自现存且可核对的本机已删消息记录，不是服务端删除证明。消息行缺失时可恢复空隐藏行，再完成原 v4 事件的设备、会话、actor 和 revision 认证；成功落盘后仍按原 cursor → Ratchet finish → ack 顺序提交，不重建旧消息密钥。正文、附件及 Reaction 不从此恢复。

没有原记录/证据的迟到 mutation，或旧接收 journal 缺少本机持久化标记且消息/墓碑均缺失时，明确暂停并保留 journal/cursor，不借服务端路由补造作者或跳过事件。便携备份不能覆盖现存墓碑/在线会话。删除证据保留至账号清理；旧记录完全丢失及已删除整段会话的恢复仍需独立兼容验收。详见[治理记录](../Security/Privacy_Boundary_Governance_2026-10-22.md)。
