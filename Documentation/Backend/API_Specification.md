# 未来 HTTPS API 规格

**状态：设计基线。** `backend/` 已实现基础端点；实际请求字段、返回状态和当前支持范围以 [OpenAPI](../../backend/openapi/openapi.yaml) 为准。iOS v3 文字信封已通过本机隔离 HTTPS 后端与模拟器双账号功能联调，双实体设备和生产部署未验证。统一前缀 `/v1`，JSON 请求/响应，UTC RFC 3339 时间，UUID 标识；二进制密文用 Base64url。认证端点之外使用 `Authorization: Bearer` 和设备绑定证明；消息发送需 `Idempotency-Key`。错误体统一为 `{ "code": "...", "message": "...", "requestID": "..." }`，不得在错误中回显凭据或消息内容。

## 认证、用户与设备

| 方法与路径 | 用途 / 关键约束 |
| --- | --- |
| `POST /v1/auth/register/challenge` | 对规范化 UserID 与设备发短期随机挑战；限流。 |
| `POST /v1/auth/register` | 上传 UserID、资料、身份公钥、设备认证公钥与设备签名证明；服务器不收密码。 |
| `POST /v1/auth/challenge` | 已登记设备领取登录挑战。 |
| `POST /v1/auth/token` | 验证设备签名后签发短期 access token 与可轮换 refresh token。 |
| `POST /v1/auth/refresh` / `POST /v1/auth/revoke` | 刷新令牌轮换 / 撤销设备会话。 |
| `GET /v1/users/me` / `PATCH /v1/users/me` | 当前资料与 `searchable` 开关；资料公开范围另按隐私策略控制。 |
| `GET /v1/users/search?userID=...` | 仅精确搜索；不可搜索用户返回统一的不可发现结果，不给枚举信号。 |
| `GET /v1/devices` / `POST /v1/devices/authorize` / `DELETE /v1/devices/{id}` | 设备列表、由现有可信设备授权新设备、撤销。无可信设备时恢复方案须另行设计。 |
| `PUT /v1/devices/{id}/prekeys` / `GET /v1/users/{id}/prekey-bundle` | 上传签名公钥束、原子取用一次性预密钥；要验证签名与身份绑定。 |

注册/登录所需**设备认证签名键**是未来新增的角色，不能把当前 P-256 `DeviceKeyManager` 的协商键直接当签名键。当前本地密码、PIN、Face ID 继续仅用于本机解锁。令牌短期有效，刷新令牌只存哈希、每次使用轮换并支持整设备撤销；具体寿命应在实施时依据风险评审固定。

## 好友、会话与消息

| 方法与路径 | 用途 / 关键约束 |
| --- | --- |
| `POST /v1/friend/request` / `POST /v1/friend/accept` / `DELETE /v1/friend` | 发请求、接受、删除；双方权限校验、拉黑/限流/防骚扰。 |
| `GET /v1/conversations` / `POST /v1/conversations` | 仅一对一会话及成员关系；服务器不读聊天正文。 |
| `POST /v1/messages` | `messageID`、`conversationID`、`encryptionVersion`、各目标设备密文信封、附件引用；事务写入事件。 |
| `GET /v1/messages/sync?cursor=...&limit=...` | 当前设备的增量事件；与 `/v1/sync/events` 同一持久源，最终实现可保留兼容别名。 |
| `DELETE /v1/messages/{id}` | 授权范围内发删除墓碑；仅表示服务器与可达设备的删除意图，不能保证所有副本物理擦除。 |
| `POST /v1/messages/read` | 提交被允许的已读事件；不得从客户端本机打开自动推断远端已读。 |
| `POST /v1/messages/edit` | 提交新密文版本和编辑事件；不得上传明文差异。 |
| `POST /v1/messages/reaction` | 提交回应事件；若回应内容属于隐私数据，应使用密文负载。 |

`POST /v1/messages` 示例的规范字段见[消息格式](../Protocol/Message_Format.md)。服务器必须验证发送者属于会话、目标设备属于成员、`messageID` 幂等、密文大小与版本限制。服务器不能解密以验证文本或文件内容。

发送请求草案：

```json
{
  "messageID": "78fda1d8-e1a5-4b83-9b8a-d28e8a72c801",
  "conversationID": "42385010-7211-43a9-a147-4b36a218ea37",
  "encryptionVersion": 3,
  "recipientEnvelopes": [
    { "recipientDeviceID": "cc14a4f0-5bba-4e43-b1d6-afcb33c38970", "ciphertext": "base64url-aead-envelope" }
  ]
}
```

v3 当前是客户端已实现的设备信封基础格式，尚无完整 Double Ratchet、线上联调或独立审计。编辑也提交新的每设备密文信封；已读提交消息 ID、读取设备与时间，服务端验证成员权限并按接收方隐私策略处理。删除操作形成可同步的墓碑，无法保证已下载副本被擦除。

## 文件、同步、在线与推送

| 方法与路径 | 用途 / 关键约束 |
| --- | --- |
| `POST /v1/files/upload/init` | 申请短时密文对象上传票据，声明大小/哈希；只接受密文。 |
| `POST /v1/files/upload/complete` | 校验对象存在、大小及密文哈希，建立附件引用。 |
| `GET /v1/files/{id}/download` / `DELETE /v1/files/{id}` | 授权下载票据 / 删除引用及按策略回收密文对象。 |
| `GET /v1/sync/events?cursor=...&limit=...` / `POST /v1/sync/ack` | 每设备游标拉取与最高连续持久化序号确认。 |
| `PUT /v1/presence/heartbeat` / `GET /v1/presence/{userID}` | TTL 心跳与获授权的在线状态；遵守隐私开关。 |
| `PUT /v1/devices/{id}/push-token` | 关联 APNs token；撤销设备时删除。 |

常见状态：`400` 格式错误、`401` 未认证、`403` 权限拒绝、`404` 不可发现/不存在、`409` 版本或幂等冲突、`429` 限流、`503` 暂不可用。避免返回不同细节泄露 UserID 存在性。文件对象使用短时限、限定对象键与大小的签名 URL；未来大文件可用分片上传。更多事件与重试规则见[同步协议](../Protocol/Sync_Protocol.md)。
