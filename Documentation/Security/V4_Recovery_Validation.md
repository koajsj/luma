# v4 首次握手恢复验收

状态：实现与本地验证中。默认关闭，不发布，不启用生产 E2EE 标识。

## 可重复本地检查

安装本机 PostgreSQL、Redis、Go 和 Xcode，并选择可用的 iOS Simulator UUID：

```bash
LUMA_TEST_SIMULATOR=<Simulator-UUID> bash backend/scripts/validate-recovery.sh
```

脚本创建独立普通测试/race/HTTP 数据库及本地 Redis；通过真实 Go Backend 验证两个独立账号、设备认证身份及 Keychain namespace 的同时初始化、消息、定向控制、HTTP 幂等、cursor 提交后的 journal 恢复。退出清理临时服务和数据库。端口 55439/55440/55441 必须空闲；不存在环境时测试跳过不能算通过。无需 Docker 或 VPS。

## 实体设备与 VPS 手动验收（尚未执行）

1. 两台独立 iOS 设备安装同版本验证构建，显式启用恢复开关，连接相同 HTTPS Backend。分别注册新账号，接受好友请求并线下核对安全码。
2. 两端同时发送首条文字；记录非敏感 proposal ID、状态 revision、winner ID 与消息数量。两条首消息都应读取；两端 active proposal 相同，旧已提交链不回退。
3. 连续双向发送文字、附件与编辑/删除/已读/Reaction；检查唯一发送候选与状态一致性。
4. 发送期间断网，恢复后重试；代理丢弃 HTTP 成功响应，确认复用原 ID/密文且 Backend 不重复插入事件。
5. 在 prepare、本地保存与 cursor 保存之间分别强制退出 App；重新启动、重启设备后验证 journal 续办和消息完整性。
6. 保留 VPS 数据卷，重启 Backend/PostgreSQL/Redis，再恢复两端同步；不重置客户端会话。
7. 调整消息投递顺序，使控制先于 initial、落选消息逆序到达。验证在途清单全部保存后认证 drain_ack，退休落选秘密。
8. 改 control/proposal/会话/设备/nonce/tag，重放旧消息并伪造低版本。全部拒绝，失败事件不能推进 cursor。
9. 改好友身份密钥并撤销设备。旧 Session 不自动信任新身份；旧设备不能继续上传或同步，相关待发控制和会话得到清理。

只记录无秘密断言、状态和完整性结果；不导出密钥、Token、plaintext 或附件内容。独立密码学审计与真实持久介质故障测试仍为发布门槛。

## 本轮实现文件

| 范围 | 文件与改动 |
| --- | --- |
| 认证标识/状态机 | `Luma/Core/Crypto/V4HandshakeRecovery.swift`：固定设备对、proposal/conflict ID、UUID raw16 选主、单调迁移及默认关闭开关 |
| 安全存储 | `V4HandshakeRecoveryVault.swift`：独立候选、版本/摘要高水位、journal、OTP 墓碑、加密 outbox、生命周期与 Debug 写入中断钩子 |
| 协商执行 | `V4HandshakeRecoveryService.swift`：双方初始化、确认、冻结、选主、认证排空、秘密退休、精确重试与迟到控制处理 |
| 控制格式 | `V4SessionControl.swift`：身份签名的 confirm/resolve/drain 阶段；有界单段清单及从未提交的 cancellation |
| legacy 分流 | `V4Handshake.swift`、`V4DoubleRatchet.swift`、`V4MessageSessionService.swift`、`V4SessionVault.swift`：新增初始化 transcript/消息 AAD、收发分流和清理；原 Ratchet 算法不变 |
| 公钥能力 | `V4PreKeyService.swift`、`backend/internal/device/v4.go`：签名能力上传、目录核验、状态查询及避免反复发布/弱模式回退 |
| 网络与同步 | `RemoteSessionControlProvider.swift`、`RemoteMessageSyncProvider.swift`、`RemoteSyncCoordinator.swift`、`RemoteMessageRepository.swift`：定向控制、入站优先恢复、outbox、权限复核与 cursor 提交 |
| Backend | `backend/internal/message/session_control.go`、对应 integration test、`backend/cmd/luma/main.go`、`backend/migrations/007_v4_session_controls.sql`、`backend/openapi/openapi.yaml` |
| 验证 | `LumaTests/V4HandshakeRecoveryTests.swift`、`LumaTests/V4RecoveryBackendTests.swift`、`backend/scripts/validate-recovery.sh` |
| 文档 | Crypto/Protocol/Security 中的实现记录、本报告、README 与 Documentation 索引；保留之前的源码审查历史 |

## 最终本地验证结果：2026-10-13

最终完整命令：`LUMA_TEST_SIMULATOR=67B93854-A8D4-499B-BD86-7DC394098A96 LUMA_TEST_DERIVED_DATA=/tmp/luma-audit-derived bash backend/scripts/validate-recovery.sh`。

- Debug build：成功；Release build：成功。
- 全量 XCTest：43 项、0 失败；其中既有基础 20 项、恢复协议 22 项、真实本地 Backend 双逻辑设备 1 项。没有把缺环境跳过记为成功。
- `go build ./...`、`go vet ./...`、`go test -count=1 -v ./...`、`go test -race -count=1 -v ./...`：成功。普通/race/HTTP 各自独立 PostgreSQL，使用独立本地 Redis；环境相关集成测试没有跳过。
- migration 001–007 初始化成功；HTTP 测试 Backend 使用自动迁移启动。
- 同时初始化、双向首消息、认证控制、重复 HTTP、cursor 后提交恢复通过；协议测试覆盖单方初始化、控制/消息乱序、迟到 resolve_request、重放、签名/AEAD 篡改、旧版本拒绝、缺失 floor、CAS、跨会话、OTP 唯一绑定、2,000 边界、取消、秘密退休及 commit 写入中断。
- `git diff --check`、脚本 `bash -n`、OpenAPI YAML 解析通过。敏感运行文件/常见凭据模式检查未发现问题；用户 `.claude/` 内容未读取或改动。
- Release 可执行文件未包含 Debug persistence hook；构建有 Xcode 的“未依赖 AppIntents，跳过元数据提取”工具提示，没有新增 Swift 编译警告。

日志保存在 `/tmp/luma-recovery-final-validation.log`，临时数据库/服务/文件已清理。原有未提交审查修复保留；本轮未提交、推送或发布。

## 数据迁移和当前限制

SwiftData 模型不变。新增 Keychain 命名空间与 legacy 记录隔离，不把旧会话自动转成新 proposal。Backend 007 仅新增 opaque 控制幂等表及公钥能力字段；不存 Root/Chain/Message Key。

有界单段清单已验证能容纳 2,000 项；未来多段清单扩展未实现。HTTP 结果不明时，关闭已读回执会保留并暂停此前已 seal 的回执，可能等待排空，不伪造 cancellation。stage 尚未形成完整 durable journal 的残留失败关闭；完整介质损坏/整机 Keychain 回滚无自动安全恢复保证。

实体 iOS 设备强制退出/重启/弱网、真正网络中断、VPS 服务/存储恢复，以及多目标底层存储故障的完整端到端验收尚未执行。源码复查已完成并修复确认风险，但不能代替独立密码学审计。

**发布判断：不满足启用“端到端加密”标识条件。恢复路径仍默认关闭，安全文案保持不变，不发布。**
