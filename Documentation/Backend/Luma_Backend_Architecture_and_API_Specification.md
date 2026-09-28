# Luma Backend Architecture & API Specification

**状态：后端基础服务已实现，隔离的本机 HTTPS 后端与 iOS 模拟器双账号已完成文字消息功能联调；未部署，线上 E2EE 协议仍需审计。** 本文件是后端总览；完整规格分为[架构](Backend_Architecture.md)、[API](API_Specification.md)、[数据库](Database_Schema.md)、[客户端协议](../Protocol/Client_Server_Protocol.md)、[消息格式](../Protocol/Message_Format.md)和[同步协议](../Protocol/Sync_Protocol.md)。这些文档共同构成未来实现基线，具体字段与密码学协议上线前仍需评审、版本冻结。

服务器职责仅为账号/设备身份、好友确认、密文消息与文件路由、同步、在线状态及无正文推送。服务器不得接收聊天明文、附件明文、账户本地密码、私钥、Master Key 或 Session Key。它仍可看到路由与时间等元数据，且恶意服务器可能替换公钥；真正端到端安全依赖客户端可验证的密钥目录与协议，不由“只存密文”的数据库设计自动保证。

当前基础工程采用 Go 模块化单体、PostgreSQL 持久化、Redis 临时状态和限流、本地磁盘密文存储及 WebSocket 提示；S3 兼容存储为可选接口，APNs 仅预留。客户端以 HTTPS 游标同步为可靠数据源。iOS 默认本地聊天为 v1，显式在线模式已有设备认证和 v4 逐设备密文路径；文字与控制事件经过隔离后端和两个模拟器联调。生产部署、双实体设备、附件完整闭环及独立安全审计尚未完成，不应描述为已验收的完整 E2EE。
