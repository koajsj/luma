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
