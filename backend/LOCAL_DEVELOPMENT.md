# Luma 本地联调

本页只用于 Mac 本机或同一局域网开发；不配置公网、VPS、CI/CD 或 APNs。默认聊天保持本地模式，只有在聊天页显式切换“在线密文聊天”才使用服务端。服务端保存逐设备密文信封及可见元数据，不持有客户端私钥。

## 后端与依赖

方式一：有 Docker 时，在 `backend/` 先生成仅本机使用的持久环境文件：`printf 'LUMA_USERID_HMAC_SECRET=%s\n' "$(openssl rand -hex 32)" > .env`，然后执行 `docker compose up --build`。不要每次启动重新生成该密钥，也不要提交 `.env`。开发 Compose 启动 PostgreSQL、Redis、Go 服务和持久化本地密文卷，监听宿主机 `127.0.0.1:8080`，仅供后端接口检查。它使用开发凭据与明文 HTTP，**不能**作为 iOS 在线模式地址。

方式二：本机已安装 PostgreSQL、Redis 和 Go 1.24+ 时，启动独立的 PostgreSQL 数据库和 Redis，复制 `.env.local.example` 为 `.env.local`，填入隔离数据库、绝对存储目录和 TLS 文件路径，并用 `openssl rand -hex 32` 填写 `LUMA_USERID_HMAC_SECRET`，然后执行 `bash scripts/run-local.sh`。服务启动会运行 SQL migration，并在数据库/Redis 无法连接或 HMAC 密钥与现有索引不符时退出。`curl --cacert <根证书> https://localhost:8080/health` 应返回 `{"status":"ok"}`。

iOS 在线模式要求可信 HTTPS。可用本机开发 CA 工具为 `localhost` 及真机使用的局域网 IP 签发开发证书，并在模拟器或测试设备上**显式安装并信任**开发 CA；不要关闭 URLSession 的证书校验。真机联调时将 `LUMA_ADDR` 设为局域网可达的监听地址并限制在可信网络，证书须包含实际访问的 IP 或主机名。开发证书、私钥和 `.env.local` 不提交 Git。

## iOS 切换与双设备

在 Xcode 的 Run Scheme 环境变量设置 `LUMA_DEV_API_URL`，例如 `https://localhost:8080`；设置 → 服务器连接会预填该值，也可手填可信 HTTPS。该地址不写入源码。登记后地址保存在该账号的 Keychain；聊天仍默认为本地模式，聊天信息菜单可按会话显式切换在线模式。在线新消息使用 v4，旧版消息保持兼容读取。

用两个独立模拟器或两台测试设备分别安装 App。设备 A/B 各自注册不同 UserID，在线登记并签名登录；让一方允许精确搜索，搜索 UserID、发起并接受好友请求，再同步联系人。双方必须通过可信渠道核对身份指纹，之后建立在线会话。依次检查 A→B、B→A 文字，图片、文件、语音文件，已读、编辑、删除和 Reaction；强制退出后重新打开 App，再重复发送与接收。模拟器容器及 Keychain 相互独立；同一安装内切换账号不能代替两台设备。若需要测试同一账号的第二设备，须走已有设备授权流程；目前 UI 尚无完整新设备授权入口。

## 文件与故障边界

设置 `LOCAL_STORAGE_DIR` 后，文件 API 把**已由客户端加密**的字节写入 `ciphertext/<UUID>`。上传前声明密文字节大小与 SHA-256，完成时服务器复核，下载时客户端再次校验；服务端不能判断上传内容是否真的完成客户端加密。测试 upload/init → PUT upload → upload/complete → download/content → delete，并用另一个账号请求内容，预期返回 404。在线聊天附件已接入图片、文件和导入的语音文件；待上传密文与票据在本机加密保存，重复 PUT/complete 可恢复丢失的响应。分别在上传、下载和消息提交前断开网络，再恢复并检查密文哈希、解密结果和服务端孤儿对象清理。仅文件接口通过不等于双设备附件聊天已验收。

关闭后端后发送的在线文字和附件进入本机加密待发队列；重启后端、保持 App 解锁，队列会自动重试。服务端事件以数据库为准；WebSocket 仅通知刷新，失败事件不能推进本机游标。设备撤销后受撤销设备的 Token 和 WebSocket 失效，已下载的本机消息不会远程清除。
