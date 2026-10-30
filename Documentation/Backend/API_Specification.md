# 后端 API 使用边界

实际路径、请求字段与返回状态以 [OpenAPI](../../backend/openapi/openapi.yaml) 为唯一接口清单。本文件只记录安全约束；历史早期 API 草案已移除，避免被当作当前服务调用。

## 认证与设备

注册/登录使用设备签名与短期挑战，不上传本地密码或 PIN。受保护 HTTP 请求及 WebSocket 握手需 Bearer token 和已登记设备的 `luma.request.v2` 签名，绑定方法、原始 URI、时间戳、nonce 及 token 哈希；refresh 也需同域签名。旧 v1 请求证明不再接受。设备登记、授权、撤销和 v4 PreKey 公钥束接口见 OpenAPI。`claim=false` 只读公钥；正常领取一次性预密钥需事务处理。

## 消息与同步

新消息只接受 `encryptionVersion=4`，`POST /v1/messages` 必须包含稳定 `messageID`、`Idempotency-Key` 和各活动目标设备的密文信封。编辑、删除、已读和有序 Reaction 只通过 `POST /v1/messages/v4/events` 发送逐设备密文；送达提示使用 `/v1/messages/delivered`，不表示端侧已读。握手冲突控制信封入口 `/v1/sessions/controls` 存储不透明密文；客户端 Recovery 默认关闭。WebSocket 只提示，持久真相是 `/v1/sync/events` 与连续游标 ack。

服务端验证身份、设备、好友/block、会话与目标设备权限；无法解密消息正文或证明密文内的业务顺序。已存历史 v3 密文可继续在新客户端受限读取；旧 v3 在线写入和公钥补充/查询接口已移除。请求原样重试仅在同一已认证发送设备、同一消息 ID 与内容哈希匹配时返回已有结果；新写入仍须重新通过当前路由授权。旧后端回滚可能重新开放不安全接口，须单独评估。

## 文件与可见性

上传前在客户端加密附件，服务端只校验密文字节大小、哈希及权限。上传、完成、下载和删除的精确路径见 OpenAPI。服务端仍可见 UserID、好友/设备关系、会话路由、时间、大小、IP 和密文对象标识。当前未完成真实双设备、隔离服务故障注入和独立密码学审计，不启用生产 E2EE 标识。
