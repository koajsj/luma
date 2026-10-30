# Luma

Luma 是基于 SwiftUI、SwiftData 和 Apple 原生安全框架的一对一隐私聊天应用。默认采用 **Local First**：本机账号、聊天与加密存储无需服务器。用户可以显式开启在线开发模式，连接仓库中的 Go 后端；后端保存密文信封和必要路由元数据，不持有客户端私钥。

> **版本边界**：v4 文字和控制事件已在两个独立 iOS 模拟器与隔离的本地 HTTPS 后端联调。图片、文件、语音附件已有客户端加密与后端密文接口，但双设备完整附件链路、两台实体设备、强制退出/断网故障注入和独立安全审计尚未完成。聊天界面继续显示“隐私保护已开启”，本仓库不宣称完整 E2EE 已通过发布验收。

## 运行与联调

- 使用 Xcode 26 打开 `Luma.xcodeproj`，选择 iOS 17 或更新版本。首次启动显示隐私介绍，完成后进入本地注册与 PIN 设置。
- 默认聊天完全在本机。在线开发模式在设置中的技术详情进入，按 [本地联调指南](backend/LOCAL_DEVELOPMENT.md)启动 PostgreSQL、Redis 和后端；开发地址可由 `LUMA_DEV_API_URL` 注入，或在应用中输入受信任的 HTTPS 地址。
- 后端代码、环境变量及启动方式见 [backend/README.md](backend/README.md)，实际 API 以 [OpenAPI](backend/openapi/openapi.yaml) 为准。
- [VPS 部署指南](deploy/README_DEPLOY.md)提供 Docker Compose 配置；当前仓库不代表已有生产部署或 HTTPS 域名已完成验收。

默认部署将数据库迁移和授权与 API 运行账号分离；API 使用受限的 `luma_api` 角色。部署脚本提供加密备份、恢复和回滚，并支持本地或独立保管备份私钥。离线保管可减少服务器失陷时的密钥暴露，但维护和恢复需要提供私钥；选择模式前请阅读[备份密钥说明](deploy/README_DEPLOY.md)。这些部署流程仍需在隔离环境完整验收。

## 当前能力

| 领域 | 已实现范围 | 未完成的验收或限制 |
| --- | --- | --- |
| 本机聊天 | 文字、回复、编辑、删除、Reaction、草稿、收藏、置顶、已读设置和加密备份 | 本机状态不代表其他设备已送达或已读 |
| 本地隐私 | Keychain 中的 Master/Identity/Device 密钥；消息、用户资料、好友私密字段、草稿、搜索索引等指定字段 AES-GCM 加密 | SwiftData 并非整库加密；UserID、关系、时间等元数据仍可见 |
| UserID 发现 | 本机和后端分别使用独立 HMAC-SHA256 密钥建立精确搜索索引，遵守 `searchable` 开关 | 明文 UserID 仍用于身份展示和协议路由；这不是匿名化 |
| 隐私控制 | PIN/Face ID、聊天锁、Privacy Shield、截图检测、录屏遮罩与后台隐藏 | 截图无法阻止；本机模拟在线状态不代表真实在线 |
| 在线通信 | 显式设备登记、身份安全码、好友请求、仅 v4 新写入、逐设备文字与控制事件、游标同步及待发队列 | 双实体设备与完整异常恢复待验收；v1/v2/v3 历史消息继续可读 |
| 附件 | 图片、文件、导入语音使用独立附件密钥在客户端加密后上传密文 | 双设备经真实后端的完整附件闭环待验收 |
| 后端 | Go、PostgreSQL、Redis、本地磁盘密文文件存储、WebSocket 提示 | APNs 只预留接口；未完成生产部署与安全审计 |

密码只用于本机身份验证，不直接作为消息密钥；PIN 和 Face ID 是本机应用门禁。线上服务仍可见 UserID、好友关系、设备、消息时间与大小等元数据。可信密钥目录尚未实现，身份固定和安全码无法证明不同设备收到的目录一致；首次验证应通过独立渠道核对安全码。安全能力与未完成项详见 [E2EE 设计](Documentation/Crypto/E2EE_Design.md)、[隐私模型](Documentation/Security/Privacy_Model.md)和[威胁模型](Documentation/Security/Threat_Model.md)。

当前在线写入使用 v4；旧版在线客户端不再保证兼容。v1/v2/v3 历史读取及受限事件处理仍需遵守现有认证规则，详见[客户端与服务器协议](Documentation/Protocol/Client_Server_Protocol.md)。同时首次握手的恢复功能默认关闭。

## 文档与开发约束

完整索引见 [Documentation/README.md](Documentation/README.md)。开发新功能前，先读相关的 **Architecture、Security、Protocol** 文档，并核对代码及 OpenAPI。`Product` 记录产品范围，`Crypto` 记录密钥与协议边界，`Backend` 记录服务端设计；设计文档中的未来方案不能当作已实现或已部署能力。

## 源码审查与验证

既有[安全治理记录](Documentation/Security/Privacy_Boundary_Governance_2026-10-22.md)汇总源码审查、定向测试和发布前验收结果，并包含两台真实设备的手动验收清单。[v4 恢复验收](Documentation/Security/V4_Recovery_Validation.md)记录恢复路径的实现状态。真实双设备、完整故障注入、Docker/Ubuntu 生命周期及独立密码学审计仍需单独验收；现有结果不构成生产 E2EE 安全认证。

后端需要 Go 1.27；在 `backend/` 可按改动范围运行 `go test` 和 `go vet`。数据库/Redis 集成测试需要明确提供隔离的 `LUMA_DEVICE_TEST_DSN`、`LUMA_DATABASE_ROLE_TEST_DSN`、`LUMA_FILE_TEST_DSN`、`LUMA_USERID_INDEX_TEST_DSN`、`LUMA_REDIS_TEST_URL`；缺少配置时会跳过，不能计为通过。不要对生产数据库运行测试。iOS 的 `Luma` Scheme 包含 `LumaTests`，可使用 Xcode 或 `xcodebuild test` 运行相关模拟器测试。
