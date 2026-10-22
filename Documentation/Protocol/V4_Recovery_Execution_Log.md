# v4 冲突恢复实施记录

依据：V4_Handshake_Recovery_Implementation_Plan.md。用户于 2026-10-13 明确授权按 Phase 0–7 实施；未授权发布。

## 基线

- HEAD：af6c529；原有未提交源码审查修复保留。
- 原 Session schema 为 formatVersion=1；Ratchet 算法不改。
- 原 migration 为 001–006；文件校验及原 Vault/Handshake 快照保存在 `/tmp/luma-recovery-baseline`，不包含运行密钥。
- 本轮重新运行现有 XCTest 全量：成功，详见该目录 xctest.log（最终新增测试后还需重跑）。
- legacy 回归包含双向 Ratchet、重开 Vault、编辑/删除/回执/Reaction、首次握手冲突失败关闭。

## 实施裁定

- 用户授权实施当前带未提交审查修复的工作区；不创建会遗漏未提交基线的独立 checkout，不覆盖已有改动。
- 计划中的所有 commit 步骤由用户“不发布”约束覆盖；本轮不提交、不推送。
- Phase 1–3 独立类型先经测试验证；默认关闭开关只有显式注入方可启用，新端不通过开关自动升级 legacy。
- 新类型不存在的 RED 构建记录在 `/tmp/luma-recovery-red.log`；它是缺接口证据，不是运行时测试通过。

## 进度与证据

- Phase 0：原 XCTest 基线通过；新增固定 legacy transcript/AAD SHA-256 向量回归，原 Ratchet 密钥算法未改。
- Phase 1–3：认证 pair/proposal、确定性 winner、状态机、独立候选/CAS/journal、控制签名及单段有界冻结清单已实现。
- Phase 4：migration 007、能力发布/验证、定向控制事务与并发幂等、block/撤销权限、OpenAPI 已实现。
- Phase 5–6：收发分流、候选协商及退休、加密控制/application outbox、cursor/journal 恢复已接入。v1/v2/v3 与 legacy v4 测试保留。
- Phase 7：隔离数据库 Backend 与双独立逻辑设备 HTTP 测试、Debug XCTest、Release build 已有成功运行；最终代码完整重跑结果待补。实体 iOS 设备、弱网与 VPS 恢复未验证。

## 独立源码复查与修复

复查未发现 P0；发现控制发送挡住入站同步、控制额度被应用消息耗尽、部分多目标准备丢失归属、取消回执丢失清单义务，以及缺失 floor 被视为空状态等问题。

回归 RED 记录 `/tmp/luma-recovery-review-red.log`；修复后的恢复测试 GREEN 记录 `/tmp/luma-recovery-review-green.log`。提交中逐次写入中断测试 RED/GREEN 记录为 `/tmp/luma-recovery-write-red.log`、`/tmp/luma-recovery-write-green.log`。PreKey 能力状态测试失败记录为 `/tmp/luma-recovery-capability-red.log`，最终完整测试另行验证修复。

## 实施裁定补充

- Ruling：保留整个 2,000 项有界清单为一个认证 segment，签名包含 index=0/count=1；验证大小能容纳两层 base64 与路由开销。未实现未来多段扩展，超界拒绝而非省略条目。
- Ruling：仅“从未提交 HTTP”的取消进入签名 burn 清单；已尝试但结果不明的回执保留精确信封并暂停。不能在缺少证据时把可能在途的密文标为取消，代价是可能等待排空/恢复发送。
- Ruling：stage 首写后、journal 尚未持久完成的注册残留失败关闭；不凭空恢复缺失的 ephemeral。已 stage 完成后的每次 commit 写入中断可续办。完整持久介质故障与整机回滚不在自动恢复保证内。

生产标识保持不变。逻辑设备、实体 iOS 设备、真实 VPS 是不同证据层；不可互相替代。

## 最终本地验证补充

- 最终全量脚本退出 0：Debug/Release build 成功，XCTest 43/43，Go build/vet/test/race 成功，无环境跳过。
- 独立普通/race/HTTP PostgreSQL 与独立 Redis；新 migration 与公钥能力/控制 HTTP 闭环通过。
- 增补修复迟到的已认证 resolve_request：只消费与已提交决议一致的控制，不重开候选或修改 Root。RED 为 `/tmp/luma-recovery-late-request-red.log`，最终 suite GREEN。
- 增补清理无 peer discovery index 的 journal：按已认证候选/日志识别设备归属，不遗留撤销设备材料。RED 为 `/tmp/luma-recovery-cleanup-red.log`，最终 suite GREEN。
- 接收提交写入中断（含 OTP 清理）验证精确控制字节保持、OTP 只消费一次；最终 suite GREEN。
- 全量日志 `/tmp/luma-recovery-final-validation.log`，文件/证据/未验证范围见 `Documentation/Security/V4_Recovery_Validation.md`。

Phase 7 的本地自动验证已完成；实体设备、真实弱网和 VPS 恢复门槛未完成。不得据此启用生产标识。
