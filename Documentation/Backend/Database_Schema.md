# 未来 PostgreSQL Schema

**状态：后端已有 SQL migration；生产运行尚未验收。** 表名用蛇形复数；UUID 主键，`created_at` 使用带时区时间。敏感密文字段用 `bytea`；实际索引、分区和保留期应按规模与隐私评审确定。

| 表 | 核心字段 | 约束与说明 |
| --- | --- | --- |
| `users` | `id`, `user_id`, `user_id_hash`, `nickname`, `avatar_object_id`, `identity_public_key`, `searchable`, `created_at` | 规范化 `user_id` 唯一；`user_id_hash` 在迁移 006 后保存 Go 服务使用环境密钥计算的 HMAC-SHA256。启动前为旧行补齐；密钥不写入数据库。账号标识仍为明文，服务端仍可见 UserID。 |
| `devices` | `id`, `user_id`, `device_name`, `device_public_key`, `auth_public_key`, `last_active_at`, `revoked_at` | `user_id → users.id`；协商公钥与认证签名公钥分角色。 |
| `signed_prekeys` | `id`, `device_id`, `public_key`, `signature`, `version`, `created_at`, `expires_at` | 服务端只持公钥与签名。 |
| `one_time_prekeys` | `id`, `device_id`, `public_key`, `created_at`, `consumed_at` | 取用须事务性标记；不存私钥。 |
| `friend_requests` / `friendships` | 申请者、接收者、状态、时间；`user_a`,`user_b` | 双人关系规范排序后唯一；需要拉黑与滥用状态。 |
| `conversations` / `conversation_members` | `id`, `type`, `created_at`；`conversation_id`,`user_id` | 初版 `type=direct`，成员关系决定读写权限。 |
| `messages` | `id`, `conversation_id`, `sender_user_id`, `sender_device_id`, `encryption_version`, `created_at`, `deleted_at` | 只放路由和版本；**禁止** `message_text`、明文文件名。 |
| `message_envelopes` | `message_id`, `recipient_device_id`, `ciphertext`, `session_key_version`, `message_key_index` | 每目标设备独立密文；唯一 `(message_id, recipient_device_id)`；nonce/认证标签包含在约定信封中。 |
| `message_receipts` | `message_id`, `recipient_device_id`, `delivered_at`, `read_at` | 只有明确事件可更新，尊重用户已读策略。 |
| `attachments` | `id`, `message_id`, `object_key`, `ciphertext_size`, `ciphertext_hash`, `status`, `created_at` | 实现中按 `pending → stored → verified → deleted` 管理，旧 `complete` 保持兼容；删除先撤销数据库读取权限，再清理密文对象与记录。 |
| `presence_snapshots` | `user_id`, `last_seen_at` | 可选持久最后活动时间；在线/输入 TTL 在 Redis。 |
| `sync_events` | `event_id`, `target_device_id`, `device_seq`, `type`, `payload_ciphertext`, `created_at` | 唯一 `(target_device_id, device_seq)` 和 `(target_device_id,event_id)`；负载不含消息明文。 |
| `sync_cursors` | `device_id`, `acked_seq`, `updated_at` | 每设备最高连续 ack；事件清理与游标保留期协调。 |
| `auth_challenges` / `refresh_sessions` | 挑战摘要/过期时间；刷新令牌哈希、设备、撤销时间 | 不落明文 token、密码或私钥。 |
| `push_tokens` | `device_id`, `token_ciphertext`, `environment`, `updated_at` | token 应加密并严格授权读取；推送内容无消息正文。 |

核心事务：创建消息时验证会话成员和目标设备，写 `messages`、各设备 `message_envelopes`、递增的 `sync_events` 与推送待办；成功后再应答。`device_seq` 必须对每个设备单调且无可见空洞，避免 ack 跳过事件。数据库备份同样只含密文和公钥，但可暴露联系人、时间、设备与流量元数据；按[隐私模型](../Security/Privacy_Model.md)制定保留期和删除策略。


## 运行账号与迁移账号

`luma migrate` 可独立执行现有 migration 与 HMAC 补齐；API 设置 `LUMA_AUTO_MIGRATE=false` 时只读检查版本集合/索引，并检查运行角色。管理员授权模板位于 [`backend/ops/runtime-grants.sql`](../../backend/ops/runtime-grants.sql)，不属于自动 SQL migrations：已有角色、对象所有权和数据库必须明确匹配，否则事务拒绝。运行角色只获当前 API 所需 DML 和只读迁移账本；预留推送表、DDL、序列及未来对象不自动授权。默认 ACL 必须针对实际创建对象的迁移角色设置。

原 `001`–`007` 文件和模型未修改，未执行生产迁移。默认 Compose API 使用独立 `luma_api`，迁移/授权由短时 `luma` 管理员任务执行；原卷所有权保持，恢复后重新授权并阻止不兼容旧代码回滚。SQL 授权和恢复已在临时 PostgreSQL 验证，容器全生命周期及已有卷首次切换仍须隔离验收，见[部署指南](../../deploy/README_DEPLOY.md#数据库权限拆分)。
