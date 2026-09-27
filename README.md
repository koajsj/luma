# Luma · 本地隐私架构

使用 Xcode 26 打开 `Luma.xcodeproj`，选择 iOS 17 或更新版本的设备运行。工程基于 SwiftUI、SwiftData 和 Apple 原生安全框架。

本地联调步骤见 [backend/LOCAL_DEVELOPMENT.md](backend/LOCAL_DEVELOPMENT.md)。设置 → 隐私中心 → 安全与隐私报告展示本机安全能力及当前限制。在线开发地址可由 Xcode Run Scheme 的 `LUMA_DEV_API_URL` 注入；默认聊天仍在本机。

## 工程文档

完整文档见 [Documentation/README.md](Documentation/README.md)：`Product` 记录需求与路线图，`Architecture` 记录客户端和数据结构，`Crypto` 记录本机密钥/加密边界，`Backend` 记录《Luma Backend Architecture & API Specification》及后端方案，`Protocol` 记录未来消息与同步协议，`Security` 记录隐私、威胁和审计清单。

开发新功能前必须阅读相关的 **Architecture、Security、Protocol** 文档，并与当前代码核对。独立后端基础服务已存在；iOS 可显式登记设备并访问账号、好友及同步查询接口。默认聊天仍是 Local First；显式在线文字模式支持 v3 历史信封读取和 v4 新消息。两个独立模拟器已完成本地 HTTPS 后端联调；实体设备、完整 E2EE 安全验收与 APNs 发送尚未完成。

## 独立后端基础服务

新增 [backend/README.md](backend/README.md) 与 [OpenAPI](backend/openapi/openapi.yaml)：Go、PostgreSQL、Redis、S3 兼容对象存储接口及 WebSocket 的密文路由基础。隔离的本机 HTTPS 后端与两个独立模拟器已验证 v4 双向文字、已读、编辑、删除和 Reaction；设置页可自愿进行设备登记、签名登录、资料/好友操作。实体设备闭环、身份线下核验和完整 E2EE 安全审计尚未完成。

## 当前可用

- 本机账号注册、UserID 与密码登录；UserID 仅在本机保证唯一。
- 6 位 PIN 与 Face ID 解锁。密码和 PIN 分别保存带随机盐的 PBKDF2-SHA256 验证值。
- 每个账号独立生成 256 位随机 Master Key，使用 `WhenUnlockedThisDeviceOnly` 存入 Keychain。密码只用于身份验证，不派生消息密钥。
- 注册时生成 P-256 CryptoKit 身份密钥对和当前设备密钥对；两个私钥分别保存在 Keychain，公钥与身份公钥的 SHA-256 指纹保存在 SwiftData。旧账号通过验证并解锁后补齐身份与设备密钥，原有 Master Key 不轮换。
- 设置中的个人资料展示身份指纹，聊天安全详情展示本地加密、身份密钥、设备密钥和未启用的端到端加密状态。账号删除会清理该账号的本地记录及对应 Keychain 密钥。
- 消息内容用 CryptoKit AES-GCM 加密后写入 SwiftData。每次加密生成随机 nonce，密文包含版本、nonce 和认证标签；消息 ID 与会话 ID 作为认证数据。解锁后才持有可用于解密的内存密钥，锁定或退出时释放该引用。
- 消息的 `encryptionVersion` 区分主密钥加密 v1 与本机模拟会话密钥加密 v2；旧记录缺省按 v1 读取。v2 还保存 `sessionKeyVersion`，以便轮换后读取旧密文。正式聊天发送仍使用 v1。
- 已有第一阶段明文消息在账号通过验证并解锁时加密，随后清空兼容字段。新消息的兼容字段始终为空。聊天、好友、设置页面和原有本地模拟消息入口保持可用。
- 附件模型预留 `encryptedPath` 和 `encryptionMetadata`，尚未写入真实附件。
- 消息支持本机编辑、回复引用定位和已编辑标记；编辑会重新生成 AES-GCM 密文，`editedAt` 与 `readAt` 为后续同步保留。会话草稿也以密文保存，退出再进入可恢复。
- 好友备注优先用于展示；好友资料支持备注、删除及本地隐私标记。在线状态与正在输入状态仅可在本机模拟，不代表远端实时状态。
- 每个会话可开启额外 PIN / Face ID 门禁。聊天列表对锁定会话隐藏消息预览，离开前台后再次进入需重新验证。隐私模式可覆盖在线状态、最后上线、消息预览和后台隐藏，并可选锁定全部聊天。
- 隐私中心新增隐私护盾：可检测截图并生成本机事件，系统报告录屏、镜像或 AirPlay 捕获时隐藏内容，进入后台时显示隐私占位。敏感聊天额外要求解锁，并从本地搜索和收藏摘要中排除。系统截图不能被拦截；通知预览策略仅为后续通知接入预留。
- 隐私中心提供本地安全状态与偏好设置；用户资料支持相册头像、昵称和简介。设备管理保存当前设备的本地信息。
- Phase 4 将隐私偏好、好友备注和附件元数据写入独立的 AES-GCM 密文字段，草稿继续使用原有密文。旧字段在验证解锁时迁移并清空逻辑值。为了本机账号发现，`searchable` 仍作为公开的最小发现标志保留；用户资料、昵称、头像和消息时间等元数据仍是明文。
- 本地搜索按需重建加密索引，可查消息、模拟文件名与好友备注；索引文本只在已解锁的内存中用于匹配，SwiftData 不保存明文关键词。聊天可置顶、标记未读、收藏、用四种 Emoji 回应和在本机联系人间转发。
- Phase 5B 增加 P-256 ECDH/HKDF 本机会话派生、Keychain 会话密钥保存、轮换和清理。安全详情可对本机已有账号模拟建立会话；`MessageRepository.sendSession` 可显式生成 v2 密文和事件，正常聊天不会自动切换。会话密钥不进入 SwiftData 或备份；备份恢复会把导出的消息重新加密为 v1，并清理旧会话密钥。
- Phase 5C 增加由身份私钥签名的本地 Signed PreKey、一次性 PreKey 池、Keychain 私钥与 SwiftData 公钥元数据。新账号初始化 100 个一次性 PreKey；本机模拟建会话消耗一个，但当前静态 ECDH 会话根密钥尚未混入 PreKey。新 v2 消息按发送者与序号从会话根密钥推进基础对称链，逐条派生不同的 AES-GCM 密钥；编辑也分配新序号。旧 v2 消息无序号时继续按原会话密钥读取。链状态只存序号，当前链密钥存 Keychain；账号、好友或会话清理时同时清理关联链密钥。
- 存储管理显示本机消息与头像体积、清理该页面生成的临时加密备份，并支持密码加密的 Luma Backup。备份使用独立随机盐和 PBKDF2-SHA256 派生 AES-GCM 密钥；导出资料、好友、会话、消息、设置与本地附件元数据，不导出密码验证值、PIN、登录状态或 Keychain 密钥。恢复要求同一 UserID，内容重新用当前主密钥加密。真实附件文件目前尚不存在，也不会出现在备份中。
- 消息状态保留 `sending`、`sent`、`delivered`、`read`。本机发送完成显示“已发送”；“已送达”和“已读”只供未来可信回执驱动，本阶段不会伪造对方确认。接收本机消息可增加未读计数；进入已解锁聊天时记录本机 `readAt` 并清零未读。关闭已读回执后不显示远端已读，也不向外发送回执。阅后即焚可在本机阅读后按设置启动计时并删除本机记录。
- Phase 5A 的聊天 ViewModel 通过 `MessageRepository` 调用 `LocalMessageRepository`；`MessageStore` 继续负责消息密文和草稿。`MessageEvent` 定义新消息、送达、已读、删除、回应和编辑事件，`ReadReceiptEvent` 承载读取者与时间。消息记录增加可选的 `deviceID`、`lastEventID` 与 `deletedAt`，旧数据库和旧加密备份缺省仍可读取。
- `MessageTransport` 与 `MockMessageTransport`、`MessageSyncService` 可在内存中模拟两个测试端点的事件收发。Mock 使用同一测试密钥，没有服务器、账号认证或跨设备密钥交换；它未接入正式聊天界面，正式界面仍只显示真实的本地状态。`RemoteMessageRepository` 现在负责 v3 线上文字信封和逐条游标应用；Mock 与本地路径继续保留。
- `Core/Network` 定义 `APIClient`、`AuthProvider`、`MessageSyncProvider`、`PresenceProvider` 和 `FileProvider`。API 与认证 Mock 明确返回“未连接通信服务”；消息 Mock 仍只用内存邮箱。`SyncCoordinator` 统一处理六类消息事件、回执和状态变化；处理失败的事件留在 Mock 队列中供重试。现有 `MessageSyncService` 是兼容入口，正式聊天仍采用本机仓储。
- `PresenceService` 保存和读取本机模拟在线、最后在线与内存中的输入状态；界面继续注明模拟状态。`FileTransferService` 为未来附件提供按账号和附件 ID 隔离的本机 AES-GCM 文件接口，文件名不含明文元数据；目前聊天只发送模拟附件，不会创建真实文件。账号删除会清理对应的本机附件目录。

## 安全边界

当前保护的是**指定字段的本机静态存储**，并非整库加密。UserID、昵称、头像、公开搜索标志、好友公开资料、会话关系、消息类型、时间、状态与计数仍在 SwiftData 中明文保存。旧版数据库的 SQLite 历史页或系统备份可能留有迁移前明文，清空模型字段不能保证物理擦除。Keychain 密钥受设备解锁状态保护，PIN 和 Face ID 是应用会话门禁，并非对 Master Key 的二次硬件封装。

身份与设备密钥当前使用 CryptoKit P-256 密钥协商密钥对，私钥由软件生成并放在 Keychain 的仅此设备、解锁后可访问条目中；目前尚未使用 Secure Enclave。Signed PreKey 用同一身份私钥的签名视图进行本地签名验证，尚无对端身份验证。会话根密钥为读取旧消息而保留，链密钥可以从根密钥重算，因此当前逐消息派生**不提供前向保密**，也不是完整 Double Ratchet。一次性 PreKey 消耗目前只是本机池状态，没有参与会话密钥协商。删除 Keychain 条目与 SwiftData 数据不是跨存储原子事务；若删除期间遇到系统存储错误，应用会提示失败，需要检查本机残留数据。

头像、简介、在线模拟状态及设备信息仍是本地 SwiftData 元数据，未单独加密。聊天锁是界面访问门禁，不等同于独立的每会话加密密钥；正式聊天中的已读、在线和输入状态不向任何人发送。Mock 事件只存在于当前进程内存，不能证明真正的远端送达或 E2EE。备份恢复目前只在当前账号上替换本地数据，Keychain 与 SwiftData 之间没有原子事务；遇到存储故障应保留原备份文件并重新检查数据。

加密备份只包含附件元数据，不包含未来的本机加密附件文件。恢复会丢弃旧会话与链状态，将消息重新加密为本机 v1，并重新检查当前账号的身份、设备与签名预密钥。网络账号认证已有客户端实现；v3 信封、事件验证和游标落盘通过隔离后端与模拟器双账号验证。持久待发队列、可续行本机清理及设备撤销事件已加入代码，仍需真实离线与双实体设备联调及独立安全审计。

后端尚未部署；服务器账号/好友接口与本地聊天并行，显式在线文字模式已在隔离后端和模拟器双账号完成基础闭环，但未完成双实体设备验证。没有完整多设备同步或 APNs 发送；线上 v3 消息可通过后端删除事件通知其他设备，但无法保证已下载副本物理擦除。本机阅后销毁只处理已打开的本地消息，不控制其他设备。“删除双方”仍只影响本机。截图与录屏设置只在本机检测和提醒，无法通知对方或阻止截图。`Core/Services/FutureServices.swift` 保留将来网络 E2EE、附件加密和同步的边界。
