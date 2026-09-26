# 未来 PostgreSQL Schema

**状态：逻辑设计，尚无迁移脚本或运行数据库。** 表名用蛇形复数；UUID 主键，`created_at` 使用带时区时间。敏感密文字段用 `bytea`；实际索引、分区和保留期应按规模与隐私评审确定。

| 表 | 核心字段 | 约束与说明 |
| --- | --- | --- |
| `users` | `id`, `user_id`, `nickname`, `avatar_ref`, `identity_public_key`, `searchable`, `created_at` | 规范化 `user_id` 唯一；头像仅存受控引用，头像是否公开需单独定义。 |
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
