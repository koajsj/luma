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
