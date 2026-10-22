# 客户端会话协议基础

## 当前本机模拟

```text
IdentityKeyManager → 本机身份公钥/私钥
PreKeyManager → 本地签名预密钥 + 一次性预密钥池
KeyAgreementService → P-256 ECDH + HKDF → Session 根密钥
SessionManager → 会话元数据与 Keychain 根密钥版本
RatchetManager → 按发送者和序号推进基础对称链 → 每消息密钥
MessageEncryptor → 依据 encryptionVersion 加解密
```

`SessionManager` 提供建立、读取、轮换和删除本机会话。建立时核对本地保存的好友指纹，并消耗一次性预密钥作为池记账；根密钥仅由身份 ECDH/HKDF 派生，**未混入**预密钥。`PreKeyManager` 本地生成和验证签名预密钥，管理一次性池。`RatchetManager` 对每个发送者维护链版本/消息序号，派生独立消息密钥；接收端仍可从保留的根密钥重算。

因此这只是协议实验基座：无真实对端认证、无完整握手、无前向保密、无妥善处理多设备、乱序和恶意服务器。`SessionKey`、`PreKeyMetadata`、`ChainState` 是本地元数据，不构成可互操作的线上协议规格。

## 未来协议设计待定项

1. 将身份签名键、密钥协商键和设备认证键的角色、编码及签名域分开定义。
2. 明确 Signed/One-Time PreKey 如何进入经认证的握手，服务端如何原子分配一次性密钥与防重放。
3. 定义每设备会话标识、链推进、跳过消息密钥上限、版本迁移与密钥过期。
4. 定义好友身份变更告警和线下指纹核验；服务器替换公钥必须可检测。
5. 完成独立协议评审后才把正式聊天从 v1 切换到网络 E2EE。

消息元数据约定见[消息格式](../Protocol/Message_Format.md)。

## v4 客户端接入状态

`V4Handshake` 验证签名预密钥和已固定的账号身份绑定，结合身份密钥、临时密钥、签名预密钥及可选一次性预密钥派生初始共享密钥。`V4RatchetState` 建立独立发送与接收链，支持 DH 换钥、每消息密钥、有限乱序和重放拒绝。新在线文字消息已经过 `RemoteMessageRepository` / `RemoteSyncCoordinator`；`V4SessionVault` 将私钥和会话链放入 Keychain，SwiftData 仅保留元数据。发送和接收分别使用待提交记录恢复中断状态；一次性预密钥由后端事务领取，接收消息与游标落盘后才删除本机私钥。

控制事件现已接入逐设备 Ratchet 认证密文。两个独立模拟器经本地 HTTPS 后端完成双向文字及控制事件联调；Ratchet Keychain 重开、乱序、重放和篡改由聚焦测试覆盖。实体设备、真实强制退出和后台恢复、更多故障注入及独立安全审计尚未完成。当前不能把本实现称为完整 Signal 协议或已审计 E2EE。

2026-09-27 最终验证轮重新通过本机 Ratchet 状态重开、认证事件与附件描述传递的聚焦测试，并通过隔离 PostgreSQL 后端处理器测试。连接中的两台实体设备与运行中的联调后端均不可用，因此本轮没有重新验证实体设备握手、强制退出恢复、断网待发和附件上传下载闭环；会话可恢复性仍以局部测试为证据，不能据此启用完整 E2EE 状态。

设计参考：[Signal X3DH 规范](https://signal.org/docs/specifications/x3dh/)与[Signal Double Ratchet 规范](https://signal.org/docs/specifications/doubleratchet/)。当前实现是 Luma 的实验性子集，不能声称兼容 Signal 协议。

## 2026-10-13 源码审查补充

PreKey 发布按本设备串行执行；状态查询和上传返回后重新读取 Keychain 中的当前私钥池，只清除本次已发布公钥的待发布标记。上传期间被接收流程消费的一次性私钥不得由旧快照重新写回。该调整不改变 v4 握手或信封格式。

**legacy/默认关闭路径的发布阻塞项（原审查记录）**：设备双方同时发起第一次握手并提交各自发送链后，当前实现拒绝对方携带初始握手头的消息，不覆盖已有 Ratchet 状态。新增测试确认双方拒绝且状态版本不变；这不是通信成功验证。后续默认关闭的 protocolVersion=2 恢复路径见下方实现记录；生产验收尚未通过，不能通过静默重置 Session 绕过。

## v4 protocolVersion=2 恢复执行器

- `V4HandshakeRecoveryService` 串行执行设备对的 prepare/receive/协商；认证控制不直接替换 Ratchet。
- `V4HandshakeRecoveryVault` 按 proposal/version 保存独立候选，协调高水位绑定记录摘要。journal 保存精确输出、前驱版本、待消费 OTP 和控制 outbox。根、链、skipped key、接收暂存 plaintext 均仅进入本设备 Keychain。
- 每设备目标的 application outbox 保留精确信封，覆盖部分多目标准备及 HTTP 结果丢失；提交可以续办，重试不重新 seal。发送尝试前持久记录 `wasSubmitted`。
- 已提交 cursor 启动时先完成 incoming journal，再向服务器 ack。缺失高水位、同版本不同内容或旧版本写入失败关闭，不假造空会话。
- 控制传输失败不挡住入站同步。控制无需等待未来对端确认才提交当前已认证事件。
- 2,000 个未确认应用序号与恢复控制的额度分开；控制 outbox 有独立上限。当前有界清单使用一个签名 segment（index=0/count=1），超界拒绝，未实现可扩展多段清单。
- 从未进入 HTTP 的已 seal 事件可生成签名 cancellation 条目；结果不明确的 HTTP 请求必须保留，不能当作取消。关闭已读回执后此类历史回执暂停，不新增发送；若落选清单仍有缺口，排空可等待，不能超时重置。

开关 `LumaV4HandshakeRecoveryEnabled` 缺省 false，只允许显式验证配置启用新版初始化。已有恢复状态仍须恢复，不把开关关闭解释为 legacy 降级。
