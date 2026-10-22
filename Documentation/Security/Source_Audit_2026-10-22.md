# Luma 源码审查与修复记录

日期：2026-10-22
本地基线：`af6c5293dd2c430283a1ccee106946122062fe38`（`main`，`v0.1.0-rc1.2`）
远端 `main`：`96676678a9747a6367e6d51ab1e7675f6335c49a`

## 结论

本轮检查覆盖 iOS 本地存储与安全生命周期、v4 握手恢复、Ratchet 事务日志、同步游标、离线队列、附件保护、Token 刷新，以及 Go 后端认证、权限、密文消息、文件、迁移和部署脚本。未确认 P0 问题；修复了四类会造成会话状态丢失、PreKey 重用窗口或认证撤销不可靠的 P1 问题。

当前源码适合继续受控开发和模拟器/隔离后端联调。恢复功能仍默认关闭，且没有完成两台真实设备、VPS 故障注入和独立密码学审计，因此不能据此宣称生产 E2EE 已通过，也不能启用生产安全标识。

## 仓库状态

- 审查开始时本地 `main` 是远端 `main` 的祖先，落后 5 个提交；已知提交 `9667667` 存在于远端。
- 工作区在本轮前已有大量未提交的握手恢复、同步、后端和文档修改，以及用户的 `.claude/` 目录。本轮没有 pull、reset、merge、提交或推送，也没有覆盖这些改动。
- 审查结束时 HEAD 未改变；工作区仍保留全部既有改动和本轮修复。

## 审查范围

- iOS：`Core/Crypto`、`Core/Security`、`Core/Storage`、`Core/Sync`、`Core/Network`、`Repositories`、相关 ViewModel 与 SwiftData 模型。
- Crypto：Identity/Device/PreKey、v1-v4 读取边界、v4 Handshake、Double Ratchet、Session Vault、Handshake Recovery Vault、消息/事件/附件信封及 Keychain 生命周期。
- Backend：Auth、Device、Friend/Block、Message/Session Control、Sync、WebSocket、File、Presence、中间件、数据库迁移。
- 工程：Dockerfile、Compose、安装/更新/备份/恢复/回滚脚本、ignore 和安全文档。

## P0

未确认可复现的私钥或明文外传、核心认证绕过、不可恢复数据破坏或崩溃。该结论只覆盖本轮源码和实际测试，不是密码协议安全认证。

## P1 修复

### 1. 删除 peer 时可能丢失已开始的 Ratchet 事务

**文件**：`Luma/Core/Crypto/V4SessionVault.swift`、`LumaTests/V4SessionVaultJournalTests.swift`

`deletePeer` 和 `discardPendingForRemoteUser` 原先会直接删除包含目标 peer 的发送/接收日志。多设备发送若已写入部分 Session，会让其他接收设备的 Ratchet 永久落后；接收日志被删时，Vault 又无法判断 SwiftData 消息和同步游标是否已经提交。

修复后：

- 仅允许直接取消尚未开始写 Session 的 `prepared` 发送事务。
- `applying`、`failed` 或 `committed` 发送事务先幂等完成全部 Session 写入。
- 接收事务保持原日志并返回 `pendingOperation`，由同步协调器根据持久化游标恢复。
- 清理顺序改为事务收口后再删除 recovery/session 状态。

### 2. Recovery peer 清理绕过事务日志保护

**文件**：`Luma/Core/Crypto/V4HandshakeRecoveryVault.swift`、`LumaTests/V4HandshakeRecoveryTests.swift`

恢复会话的 `removePeer` 直接删除 pair 前缀，可能删除处于 `applying` 的候选 Ratchet 或尚未确认上层提交结果的接收日志。

修复后先收集全部相关 operation：存在接收 operation 时拒绝清理；已开始的发送 operation 先幂等完成；最后再删除 pair。OTP tombstone 保留到账号/设备清理，避免旧 PreKey 再次使用。

### 3. 首次 Recovery stage 的崩溃窗口可能造成永久损坏或 OTP 复用

**文件**：`Luma/Core/Crypto/V4HandshakeRecoveryVault.swift`、`Luma/Core/Crypto/V4HandshakeRecoveryService.swift`、`LumaTests/V4HandshakeRecoveryTests.swift`

原写入顺序先暴露全局 pair 索引，再写精确 journal。两步之间退出后，`load` 会发现一个无 floor、无 journal 的 pair 并永久报损坏。调整 journal 顺序后又暴露第二个问题：OTP 占用晚于 journal，且相同事务重试不会补占用，进程退出时竞争 proposal 可能占用同一 OTP。

修复后：

- proposal 绑定的 OTP tombstone 最先持久化；当前协议只允许每次 operation 消耗一个本机 OTP。
- 精确 journal 在 discovery 索引之前落盘。
- 相同 operation 重试会补齐 OTP tombstone、pair 列表和 peer 索引。
- `finish` 继续使用 CAS/version floor 幂等提交，不重新派生 Ratchet 或历史消息密钥。
- 移除 Service 层重复的 OTP 占用调用，由 Vault 统一负责持久化顺序。

### 4. Refresh Token 重用检测可能在撤销失败时返回成功处置

**文件**：`backend/internal/auth/auth.go`

重用分支忽略 refresh/access family 两次撤销和事务提交错误，数据库异常时可能返回 `refresh_reuse_detected`，但会话族仍保持有效。

修复后逐项检查撤销和 commit；未完成持久撤销时返回通用 `503 storage_unavailable`，只有事务提交成功后才返回重用检测结果。响应和日志不包含 Token。

## P2 与观察项

- 未为追求形式分层重写仍稳定工作的 UI/SwiftData 调用，也未更换密码算法或数据模型。
- Backend 文件下载在响应流已经开始后无法可靠返回结构化错误；当前授权、对象键生成、密文哈希和大小验证均保持。生产网关仍应设置连接和带宽限制。
- PreKey 服务器领取是事务安全的一次性 claim；客户端崩溃可消耗库存但不会安全地“退回”可能已使用的密钥。这是可用性限制，不能通过自动 unclaim 修复。

## 验证结果

### iOS

- 使用 Xcode 26.6、iOS 26.5 Simulator。
- 定向执行 `V4HandshakeRecoveryTests` 与 `V4SessionVaultJournalTests`。
- 首轮共执行 28 项：27 项通过；新增 OTP 测试因测试夹具未写入对应设备私钥，在清理阶段报 `missing`。
- 补齐真实 Keychain 设备/OTP 私钥夹具后，仅重跑该失败项：1 项通过、0 失败。复用首轮未受夹具修改影响的 27 项结果，未重复全量构建。
- 覆盖：正常/并发首次握手、确定性选主、重放与篡改拒绝、乱序、commit 故障点、OTP 单次占用、peer 清理与接收日志保留。
- 未单独执行 Release build、全量 XCTest 或静态分析；用户要求避免非必要构建。

### Backend 与脚本

- `go test ./...`：通过。
- `go vet ./...`：通过。
- `go test -race ./...`：通过。
- 当前未配置 `LUMA_*_TEST_DSN`/`LUMA_REDIS_TEST_URL`，依赖隔离 PostgreSQL/Redis 的集成用例按其保护条件跳过；没有把跳过项计为已验证。
- 所有 `deploy/` 与 `backend/scripts/` Shell 脚本 `bash -n`：通过。
- `git diff --check`：通过。
- 静态敏感文件/密钥特征扫描：未发现 `.env`、证书、私钥、Token、本地数据库或日志进入工作区改动。
- 未运行 Docker、VPS、生产 migration 或真实服务部署。

## 遗留风险与发布阻塞

1. Recovery feature flag 默认关闭；启用前仍需两台独立真实 iOS 设备完成同时首次握手、断网、强退、重启和附件闭环。
2. 需要在可销毁的 PostgreSQL/Redis 环境进行明确的数据库故障注入，验证 refresh family 撤销失败路径和 session control 重试。
3. 需要验证 VPS/Backend 重启期间 cursor、encrypted outbox、control outbox 与 Ratchet journal 的恢复。
4. 需要独立密码学审计确认 X3DH/Double Ratchet 组合、冲突恢复控制协议和恶意服务器模型；单元测试不能替代该审计。
5. 未验证真实设备 Keychain 锁定、系统备份边界、后台终止和设备撤销的端到端行为。

在这些项目完成前，保持现有谨慎安全文案，不发布、不更新生产 E2EE 状态。

## 远端审查记录的合并说明

远端 PR #1（合并提交 `ee6e8ec`）独立审查并修复了 peer 删除时丢失 Ratchet journal 的问题。该远端审查环境未能运行构建或测试；本地后续定向测试及其范围已在上文记录。远端报告另外指出 PreKey 领取后客户端崩溃导致库存耗尽、硬编码 Docker 网段冲突以及 Redis 限流 TTL 失败风险；前者仍是可用性限制，后两项由本地后续改动分别增加网段冲突检查和原子限流脚本。远端原始审查见 GitHub PR #1 历史；本报告汇总合并后的源码与实际验证，不将审查本身视为独立密码学认证。
