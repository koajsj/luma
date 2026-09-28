# Luma

Luma 是基于 SwiftUI、SwiftData 和 Apple 原生安全框架的一对一隐私聊天应用。默认采用 **Local First**：本机账号、聊天与加密存储无需服务器。用户可以显式开启在线开发模式，连接仓库中的 Go 后端；后端保存密文信封和必要路由元数据，不持有客户端私钥。

> **版本边界**：v4 文字和控制事件已在两个独立 iOS 模拟器与隔离的本地 HTTPS 后端联调。图片、文件、语音附件已有客户端加密与后端密文接口，但双设备完整附件链路、两台实体设备、强制退出/断网故障注入和独立安全审计尚未完成。聊天界面继续显示“隐私保护已开启”，本仓库不宣称完整 E2EE 已通过发布验收。

## 运行与联调

- 使用 Xcode 26 打开 `Luma.xcodeproj`，选择 iOS 17 或更新版本。首次启动显示隐私介绍，完成后进入本地注册与 PIN 设置。
- 默认聊天完全在本机。在线开发模式在设置中的技术详情进入，按 [本地联调指南](backend/LOCAL_DEVELOPMENT.md)启动 PostgreSQL、Redis 和后端；开发地址可由 `LUMA_DEV_API_URL` 注入，或在应用中输入受信任的 HTTPS 地址。
- 后端代码、环境变量及启动方式见 [backend/README.md](backend/README.md)，实际 API 以 [OpenAPI](backend/openapi/openapi.yaml) 为准。
- [VPS 部署指南](deploy/README_DEPLOY.md)提供 Docker Compose 配置；当前仓库不代表已有生产部署或 HTTPS 域名已完成验收。

RC1.2 后端与部署加固涵盖 Block 权限、PreKey 可用设备筛选、Reaction 重试幂等、WebSocket 写超时、可信代理限流、就绪检查及恢复脚本补偿。Docker 镜像中的迁移文件已设为非 root 用户可读。生产 VPS 的部署、回滚和域名切换仍需实际环境验收。

## 当前能力

| 领域 | 已实现范围 | 未完成的验收或限制 |
| --- | --- | --- |
| 本机聊天 | 文字、回复、编辑、删除、Reaction、草稿、收藏、置顶、已读设置和加密备份 | 本机状态不代表其他设备已送达或已读 |
| 本地隐私 | Keychain 中的 Master/Identity/Device 密钥；消息、用户资料、好友私密字段、草稿、搜索索引等指定字段 AES-GCM 加密 | SwiftData 并非整库加密；UserID、关系、时间等元数据仍可见 |
| UserID 发现 | 本机和后端分别使用独立 HMAC-SHA256 密钥建立精确搜索索引，遵守 `searchable` 开关 | 明文 UserID 仍用于身份展示和协议路由；这不是匿名化 |
| 隐私控制 | PIN/Face ID、聊天锁、Privacy Shield、截图检测、录屏遮罩与后台隐藏 | 截图无法阻止；本机模拟在线状态不代表真实在线 |
| 在线通信 | 显式设备登记、身份安全码、好友请求、v4 逐设备文字与控制事件、游标同步及待发队列 | 双实体设备与完整异常恢复待验收；v1/v2/v3 历史消息继续可读 |
| 附件 | 图片、文件、导入语音使用独立附件密钥在客户端加密后上传密文 | 双设备经真实后端的完整附件闭环待验收 |
| 后端 | Go、PostgreSQL、Redis、本地磁盘密文文件存储、WebSocket 提示 | APNs 只预留接口；未完成生产部署与安全审计 |

密码只用于本机身份验证，不直接作为消息密钥；PIN 和 Face ID 是本机应用门禁。线上服务仍可见 UserID、好友关系、设备、消息时间与大小等元数据。安全能力与未完成项详见 [E2EE 设计](Documentation/Crypto/E2EE_Design.md)、[隐私模型](Documentation/Security/Privacy_Model.md)和[威胁模型](Documentation/Security/Threat_Model.md)。

## 文档与开发约束

完整索引见 [Documentation/README.md](Documentation/README.md)。开发新功能前，先读相关的 **Architecture、Security、Protocol** 文档，并核对代码及 OpenAPI。`Product` 记录产品范围，`Crypto` 记录密钥与协议边界，`Backend` 记录服务端设计；设计文档中的未来方案不能当作已实现或已部署能力。
