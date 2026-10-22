# Luma 源码审查与修复记录

日期：2026-10-13。范围：当前工作区的 SwiftUI/SwiftData 客户端、Go 后端、迁移、部署脚本、构建配置及工程文档。没有提交或推送 Git；已有 `.claude/` 未跟踪目录保持原样。

## 整体判断

Local First、Repository、SyncCoordinator 与版本化消息读取的主要边界仍清晰。CryptoKit/Keychain 与后端公钥、密文路由的职责保持分离。设置和资料页面仍有直接 SwiftData 访问，文档已明确这一现状；本轮没有为追求形式分层而重写页面。

本轮修复了可复现的凭据/PreKey 异步竞态、隐私搜索和后端权限问题，并补齐数据库结果错误与部署中断处理。构建和现有核心测试通过，但发现并确认了尚未解决的首次会话并发冲突。因此适合继续开发及受控联调，**不能作为生产 E2EE 发布验收通过的结论**。

## P0

本轮未确认私钥/明文消息外传、可利用的核心协议认证绕过或可复现的崩溃。此结论仅代表本次源码与测试范围，不是独立密码学安全认证。

## 已修复 P1

| 问题 | 文件 | 根因与修复 |
| --- | --- | --- |
| 并发请求重复轮换同一 Refresh Token，可能被后端判为重用并撤销会话 | `Luma/Core/Network/RemoteAPIClient.swift` | 多个 APIClient 各自刷新；增加跨实例的 actor 协调，合并同一 Token 的在途刷新，执行前复查 Keychain。测试先观察到 2 次刷新，修复后只有 1 次。 |
| 退出登录期间的在途刷新重新写回 Token | 同上 | 网络返回后未检查凭据是否已清理；保存前重新检查当前 Token，没有凭据则拒绝保存，轮换后不覆盖新凭据。 |
| PreKey 上传用旧快照覆盖当前状态，恢复已消费的一次性私钥 | `Luma/Core/Crypto/V4PreKeyService.swift` | await 期间接收流程可以消费私钥；串行发布，返回后重读设备状态并验证身份/版本，只清除本次公钥的发布标记。 |
| 已删除/孤儿消息仍能通过残留搜索索引展示 | `Luma/Core/Storage/SearchIndexService.swift` | 索引匹配未复核源数据；解密索引前验证账号、有效消息、附件、好友与聊天保护状态。按 ID 映射同时减少循环查找。 |
| 屏蔽关系未约束精确 UserID 搜索 | `backend/internal/user/user.go` | 搜索 SQL 缺少双向 blocks 校验；双向屏蔽均返回与不可搜索用户相同的 404。 |
| 多后端实例并发启动迁移冲突 | `backend/internal/database/database.go` | 执行版本检查前没有互斥；专用连接持有 PostgreSQL advisory lock，仍逐文件事务提交。取消后用独立超时上下文释放锁，释放失败则关闭连接，不把带锁连接放回池。 |
| 回执查询中途失败可能提交不完整通知集合 | `backend/internal/message/message.go` | 忽略 Scan/Rows.Err；错误时结束请求并回滚回执事务。 |
| restore 收到 INT/TERM 时可能跳过补偿 | `deploy/restore.sh` | 只注册 EXIT；增加显式信号退出处理并进入原有配置/数据库/文件补偿。仅静态验证，未运行 VPS 数据恢复。 |

## 已修复 P2

| 问题 | 文件 | 修复 |
| --- | --- | --- |
| 停用账号仍能签发/刷新不可用令牌 | `backend/internal/auth/auth.go` | 登录与刷新均检查 users.disabled_at，与受保护接口的账号状态条件保持一致。 |
| 限流 INCR 与 EXPIRE 分离，中断可能留下永久计数 | `backend/internal/middleware/http.go` | Redis Lua 原子计数及设置 TTL，并修复已有无 TTL 计数。隔离 Redis 验证 TTL 与额度。 |
| Sync/会话/设备/好友请求列表将读取中途错误当成功 | `backend/internal/sync/sync.go`、`conversation/conversation.go`、`device/device.go`、`friend/friend.go` | 返回 200 前检查 Rows.Err，失败仅给出通用 503。 |
| 最小 Ubuntu 环境可能在安装 curl 前调用 curl | `deploy/install.sh` | 先安装依赖，再检查 GitHub 可达性。 |
| 数据模型文档仍称真实附件上传不存在 | `Documentation/Architecture/Data_Model.md` | 校正为已有 v4 密文接口及加密描述；不把局部测试描述为真机验收。 |

## 未解决 P1：双方同时首次握手

`V4MessageSessionService.decrypt` 在已有 Session 时要求 incoming.initialHeader 为 nil。当 A/B 同时准备并提交各自第一条消息，两端已有独立发起的发送链，随后都拒绝对方的初始握手头。回归场景确认双方拒绝、原 Session 状态版本仍为 1，没有静默覆盖状态。同步会停止确认，消息不会因该失败被 ack，但当前没有该冲突的自动恢复。

本轮没有通过删除/覆盖旧 Session 绕过验证，因为这可能破坏已发消息的 Ratchet 状态和历史可读性。安全处理需要明确并发会话选择、未确认密文与崩溃恢复规则，再作为独立协议一致性修复验证。**此项阻止宣称所有 P1 已消除或启用完整 E2EE 发布标识。**

## 审查覆盖与保持的边界

- Keychain：私钥、Master Key、Token、v4 状态与事务日志采用本设备可用的 Keychain 条目。SwiftData 保存公开身份、路由及选定敏感字段密文。
- 消息：保留 v1/v2/v3 读取及 v4 信封/事件格式；AAD、身份固定、版本、重放与篡改拒绝没有弱化。
- 附件：独立附件密钥封装在认证消息和本机加密描述中；缓存经 Master Key 加密。后端校验密文大小/哈希、授权及墓碑清理。
- 隐私：搜索在展示前再次验证源记录与保护状态；日志扫描未发现生产密钥、Token、消息正文日志。Debug 诊断服务与入口受 `#if DEBUG` 控制。
- 部署：检查 Docker 非 root、静态 migration 权限、COPY 与 ignore、私有网络、可信代理及恢复脚本；没有启动 Docker 或修改 VPS。
- 性能：搜索的消息/附件关联改为 ID 映射。大量数据场景仍有全量 SwiftData fetch、索引重建和同步备份操作；没有 Instruments 或大规模数据基准，不能宣称已完成性能认证。
- 工程：没有新增依赖或测试框架，没有修改数据 Schema 或核心密码算法。仓库未配置 CI 和 SwiftLint，本轮执行既有工具链检查，不新建部署/发布体系。

## 验证证据

- iOS：Xcode、iOS 26.5 Simulator，Debug XCTest **20 项通过，0 失败**。覆盖资料迁移、本地聊天、备份、删除恢复、待发队列、v3/v4 加解密、附件错钥/篡改、身份变化、事件验证及新增竞态测试。
- 双首次握手测试是**失败关闭行为测试**，不是双向通信成功测试。
- iOS Release：模拟器 Release 构建成功。模拟器通过 simctl 启动 App；未用 UI 自动点击验收。
- 编译日志只有 Xcode 工具的 AppIntents 元数据跳过提示；没有项目 Swift 编译诊断。本项目未使用 AppIntents，未通过添加无用依赖或隐藏诊断消除该工具提示。
- Go：`go build ./...`、`go vet ./...`、`go test -race -count=1` 通过。
- 数据库/Redis：使用 `/tmp` 的一次性 PostgreSQL/Redis 环境执行集成测试；Migration 初始化、重复/并发执行、Block、PreKey、设备撤销、v4 事件权限/幂等、密文文件权限及新回归测试通过。测试结束停止服务并删除临时数据。
- HTTP：真实本机 Go 服务通过 `/health`、`/ready`、注册、Challenge 签名登录、设备认证、Sync、WebSocket 握手、密文文件上传/下载/删除及 Token 轮换。测试凭据只在进程内使用，没有写入仓库。
- Shell/Git：全部部署脚本 `bash -n`、`git diff --check` 通过；未新增真实 `.env`、证书、Token、私钥、本地数据库或日志。

## 发布与后续边界

两台实体设备完整内容链路、强制退出/断网故障注入、Ubuntu VPS 恢复补偿、恶意服务器与独立安全审计仍未验证。当前不满足完整 E2EE 发布标准；保持“隐私保护已开启”的文案。解决并发首次握手后仍需完成这些验收，不能仅凭单元测试通过替代。
