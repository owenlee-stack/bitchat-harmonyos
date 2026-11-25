# Feature Specification: bitchat 鸿蒙手机版（HarmonyOS NEXT）

**Created**: 2026-10-28
**Status**: Reviewed (v2 — 经 Android 源码深度核对修订)
**Input**: 参考 bitchat-android v2.2.0（本地代码库 `bitchat_android/bitchat-android-main`，行为真源；`WHITEPAPER.md` v2.0 为协议语义真源），为 HarmonyOS NEXT (API 12+) 手机开发 bitchat 去中心化点对点通信应用，采用分阶段 MVP 策略，交付需求范围与 WBS 规划文档。
**修订说明**: v2 依据 Android 源码逐项核对修订：修正 7 处数值/行为冲突；新增 Courier 信使系统（US17，二期）、私有媒体 v1（US10 修订）、中继优化三件套（FR-004/033 修订）、`/hug` `/slap` `/w` 命令（FR-017 修订）；固化明确排除清单。

## Overview

bitchat 是一个去中心化、无账号、无中心服务器的点对点即时通信应用：近距离设备通过 BLE（蓝牙低功耗）组成自组织 mesh 网络实现离线通信，远距离互为收藏的联系人通过 Nostr 中继经互联网互通。本特性为 HarmonyOS NEXT 手机开发 bitchat 客户端，与现有 Android/iOS 客户端**线上协议二进制兼容**（互通），并按三期里程碑交付：一期 MVP（协议内核 + BLE mesh + Noise 加密 + 公聊/私聊 + 中继优化），二期（Nostr + 媒体私有加密 + 频道 + Courier 信使），三期（geohash 位置频道 + 实时语音 + Tor 等高级特性）。

**范围裁剪决策**（已确认）：
- Wi-Fi Aware (NAN)：鸿蒙无直接等价 API，一期不做，三期仅安排调研评估任务。
- Wear 手表端：不在范围内。
- 热点 APK 分享：三期按鸿蒙应用分享方式适配（可选）。
- Tor (Arti)：三期任务，依赖原生库鸿蒙移植可行性。

**明确排除项（经用户确认，记录为已知差距，禁止纳入范围）**：
- `/pay` Cashu 令牌命令（独立 ecash 货币协议解析，非通信核心）。
- Globe 3D 地球视图（Nostr 中继/节点分布展示，纯展示性功能）。
- 电池感知占空比扫描策略（鸿蒙端采用系统默认 BLE 扫描调度）。
- 交付指标本地计数器（§6.5 本地 bare counters；panic 清单中相应去掉"本地指标"项）。
- 开机自启（BootCompletedReceiver 等价能力）。

## User Scenarios & Testing *(mandatory)*

用户故事按三期里程碑组织，P1 为一期 MVP（最高优先级），P2 为二期，P3 为三期。同一期内按依赖关系排序。

---

### User Story 1 - 首次启动与身份初始化 (Priority: P1)

用户首次打开应用，系统引导完成权限授权（蓝牙、位置、通知），自动生成设备身份密钥（Noise 静态密钥 + Ed25519 签名密钥），用户设置昵称后进入主聊天界面。身份密钥安全存储于设备安全区，无需注册账号、手机号或邮箱。

**Why this priority**: 身份与权限是一切通信功能的前置条件；bitchat "无账号"的核心体验由此建立。

**Independent Test**: 安装应用后独立启动，完成引导并进入主界面，即验证昵称持久化与密钥生成。

**Acceptance Scenarios**:

1. **Given** 全新安装的应用，**When** 用户完成权限引导并输入昵称（上限 15 字符），**Then** 身份密钥生成并安全持久化，进入主界面且重启后昵称与身份保持不变。
2. **Given** 用户拒绝蓝牙/位置权限，**When** 进入应用，**Then** 显示受限模式提示，并可在系统设置中重新授权后恢复完整功能。
3. **Given** 已初始化的设备，**When** 计算节点 ID，**Then** 其值等于 Noise 静态公钥 SHA-256 指纹的前 8 字节，与 Android/iOS 客户端算法一致。

---

### User Story 2 - BLE Mesh 发现与连接 (Priority: P1)

设备作为 GATT 服务端与客户端同时工作，扫描并发现附近（蓝牙范围内）的 bitchat 设备，建立 BLE 连接；公告（Announce）为**事件驱动**（服务就绪、连接建立后定向发送等），设备隔离时每 4 秒广播一次、建立连接后退避至约 15–30 秒（含抖动）；公告负载为签名 TLV（昵称/Noise 公钥/Ed25519 公钥/直接邻居列表[最多 10×8 字节]/能力位域），验签通过的 peer 保持 reachable 状态 **60 秒**（自最后接触起），超过 **180 秒**（STALE_PEER_TIMEOUT）无接触的 peer 被过期清理（清理扫描周期 60 秒）。已验证的 peer 显示在"网络"列表中。

**Why this priority**: mesh 邻居发现是所有消息收发的物理前提；公告携带的邻居列表是一期源路由（US3）的数据来源。

**Independent Test**: 两台 HarmonyOS 设备（或一台鸿蒙 + 一台 Android/iOS bitchat）靠近，双方 peer 列表互见。

**Acceptance Scenarios**:

1. **Given** 两台已初始化设备且蓝牙开启，**When** 进入主界面，**Then** 双方在数秒内互相发现并在网络列表显示对方昵称与 peer ID。
2. **Given** 已连接的 peer，**When** 对方离开蓝牙范围，**Then** 该 peer 在 60 秒后不再 reachable；180 秒后被从 peer 表过期清理。
3. **Given** 鸿蒙设备与 Android bitchat 设备同处，**When** 扫描，**Then** 双方使用相同的 GATT Service/Characteristic UUID 完成互发现与互连（跨平台互通）。
4. **Given** 收到对方公告，**When** 验签解析，**Then** 正确读出昵称 TLV(0x01)、Noise 公钥 TLV(0x02)、Ed25519 公钥 TLV(0x03)、直接邻居 TLV(0x04)、能力位域 TLV(0x05，小端位域，未知位容忍)；未知 TLV 透传不报错。

---

### User Story 3 - 公共聊天室广播 (Priority: P1)

用户在公共聊天室发送文本消息，消息经签名后向 mesh 内所有 peer 广播（TTL=7 受控洪泛），支持多跳中继到达非直连 peer；接收方验签后展示在公共时间线。中继执行与 Android 对齐的洪泛控制：稠密图（≥6 链路）广播 TTL 钳制为 5、细链（≤2 链路）按入向全深度转发；广播消息按 log₂(度) 规模的消息 ID 种子确定性子集扇出，公告/分片/同步包全扇出；有向流量（握手/私信/信使信封）确定性 TTL−1 转发、不子集；入向链路排除（split horizon）；转发抖动 10–220ms（稠密时更宽）。基于公告邻居列表（US2 TLV 0x04）构建浅层拓扑图（60 秒新鲜度），存在双向确认路径时按源路由转发，路由失败回退洪泛。公共历史通过 gossip 同步（每约 15 秒 GCS 过滤器对账），新加入或穿行于分区的设备可获取最近 6 小时的公共消息（缓存 1000 包、持久化）。

**Why this priority**: 公共广播是 mesh 离线通信的最小可用形态，也是验证协议栈正确性的最直接场景；中继优化三件套（TTL 钳制/扇出子集/源路由）经用户确认纳入一期，保证密集组网下与 Android 行为一致。

**Independent Test**: 三台及以上设备组网，一台发送，全部可见；新设备中途加入可同步到历史消息。

**Acceptance Scenarios**:

1. **Given** 三台设备 A-B-C 链式组网（A、C 不直连），**When** A 发送公共消息，**Then** C 经 B 中继收到并展示，消息内容与发送方昵称一致。
2. **Given** 设备 D 加入 mesh，**When** gossip 同步执行（周期约 15 秒），**Then** D 补齐最近 6 小时窗口内其缺失的公共消息。
3. **Given** 重复/迟到的广播包，**When** 到达任一节点，**Then** 依据去重集合（LRU 1000 条目、5 分钟过期；UI 消息去重 30s、系统事件 5s）被丢弃，时间线不出现重复消息；先到的重复包会取消已调度的中继。
4. **Given** 超过链路 MTU 的消息，**When** 发送，**Then** 自动分片（≤469 字节/片、13 字节分片头）独立中继并在接收端重组（30 秒超时）。
5. **Given** 稠密网络（本节点 ≥6 链路），**When** 收到广播包，**Then** 转发 TTL 钳制为 5 且按消息 ID 种子子集扇出；公告与分片包仍全扇出。

---

### User Story 4 - 端到端加密私聊 (Priority: P1)

用户向已连接 peer 发起私聊，双方执行 Noise XX 握手（X25519 + ChaCha20-Poly1305 + SHA-256）建立前向保密会话；私聊消息以密文传输，中继节点仅见不透明密文。支持送达回执与已读回执（Noise 载荷类型 DELIVERED 0x03 / READ_RECEIPT 0x02）。对方离线时消息进入发件箱（每 peer 上限 100 条、24 小时 TTL、最多 8 次重发，路由 tick 2 秒，握手重试退避 5/15/30/60 秒），重连后自动冲刷投递。密钥重协商策略：会话 1 小时或加密 1000 条消息（会话级上限 10000 条）触发 rekey。

**Why this priority**: 私聊是 IM 核心场景；发件箱保证"对方不在场"时的最终送达，是 bitchat 的关键差异化能力。

**Independent Test**: 双机私聊收发 + 断开重连后发件箱自动补投。

**Acceptance Scenarios**:

1. **Given** 双方已建立 Noise 会话，**When** A 向 B 发送私聊消息，**Then** B 收到后明文展示，中继节点（C）无法解密内容，且 A 收到 B 的送达回执；B 阅读后 A 显示已读状态。
2. **Given** B 离线，**When** A 发送 3 条私聊消息，**Then** 消息进入发件箱并显示待投递状态；B 重新入网后按序收到全部消息。
3. **Given** 发件箱中超过 24 小时或重发 8 次仍失败的消息，**When** 达到阈值，**Then** 标记为发送失败并可见。
4. **Given** 鸿蒙端与 Android 端私聊，**When** 互发消息，**Then** 双方均可正常解密阅读（Noise XX 跨平台互通）。

---

### User Story 5 - 消息去重、限流与垃圾过滤 (Priority: P1)

mesh 内所有入包经过统一准入：载荷按类型限额、重放窗口校验、先验签后记入去重集合；解压执行压缩炸弹防护（声明原始大小 > 1032 × 压缩字节数即拒绝，1032:1 为 DEFLATE 硬上限）；应用层对公共消息执行垃圾过滤——令牌桶速率（消息 6 容量/每 10 秒 +1；字符 1200 容量/每秒 +20；链接 2 容量/每 30 秒 +1）、最大回溯 1 小时、跟踪 1000 个发送者与 4000 条判定记录、重复检测（REPEATED_MESSAGE / REPEATED_ACROSS_USERS / REPEATED_CHARACTERS），超限消息静默丢弃。

**Why this priority**: 受控洪泛网络必须有泛洪滥用防护，否则网络不可用；与白皮书 §8 的抗滥用要求对应。

**Independent Test**: 构造重复包、超限包与高频发送场景，验证丢弃行为。

**Acceptance Scenarios**:

1. **Given** 相同消息 ID 的包再次到达，**When** 已在去重集合中，**Then** 直接丢弃且不中继。
2. **Given** 某 peer 高速连发消息，**When** 超过令牌桶速率，**Then** 超限消息被过滤，正常消息不受影响。
3. **Given** 声明解压后超过 1032 倍压缩字节数的载荷，**When** 解压，**Then** 拒绝解压并丢弃该包。

---

### User Story 6 - IRC 风格命令与基础聊天 UI (Priority: P1)

主界面提供聊天列表与消息流，支持 IRC 风格命令（`/join`(`/j`)、`/msg`(`/m`)、`/who`(`/w`)、`/clear`、`/block`、`/unblock`、`/channels`、`/hug`、`/slap`）及命令/提及(@)自动补全；消息按发送者分组显示、支持深浅双主题（Matrix 终端式与气泡式两套 UI 模式）、链接可识别。昵称上限 15 字符。

**Why this priority**: 命令体系是 bitchat 的标志性交互，双主题与分组是其视觉识别度来源；保证基础可用性。`/hug` `/slap` `/w` 经用户确认纳入以保持命令集对齐（`/pay` Cashu 明确排除，见排除清单）。

**Independent Test**: 在输入框执行各命令，验证对应行为与 UI 反馈。

**Acceptance Scenarios**:

1. **Given** 主界面输入框，**When** 输入 `/`，**Then** 弹出命令自动补全建议列表。
2. **Given** 公共聊天室，**When** 执行 `/msg <peer> <内容>`，**Then** 打开与该 peer 的私聊并发送消息。
3. **Given** 设置面板，**When** 切换 UI 模式（终端式 ↔ 气泡式）与深浅主题，**Then** 立即生效且重启后保持。
4. **Given** 输入 `/hug <peer>` 或 `/slap <peer>`，**When** 执行，**Then** 生成对应趣味消息展示在当前会话；`/w` 与 `/who` 行为等价。

---

### User Story 7 - 紧急擦除 (Panic Wipe) (Priority: P1)

用户三连击应用 logo 触发确认对话框，确认后分阶段擦除：停止定位服务 → 清私媒同意状态 → 停消息准入 → 私聊会话数据库（失败则保持停机并明示）→ UI 状态/消息/频道/私聊数据 → 去重存储与发件箱 → 垃圾过滤器 → 全部密钥学数据 → 通知 → 媒体文件 → Nostr/geohash 状态 → 收藏/书签 → 重置昵称为 `anon<1000-9999>` → 重建 mesh 服务与新身份；全部成功后应用回到未初始化状态。每个落盘阶段都必须确认成功，任一阶段失败必须明确提示 "system_panic_incomplete" 且不静默跳过。（注：交付指标计数器不在范围内，panic 清单相应不含该项，见排除清单。）

**Why this priority**: 紧急擦除是 bitchat 的安全核心承诺（白皮书 §7），属于隐私保护刚需，必须在 MVP 中可用。

**Independent Test**: 触发 panic 后验证所有持久化数据（含密钥）不可恢复，应用回到首启状态。

**Acceptance Scenarios**:

1. **Given** 已有身份与聊天记录的设备，**When** 三连击 logo 并确认，**Then** 全部本地数据与密钥被清除，应用回到引导页并生成全新身份（昵称重置为 anon 加随机四位数字）。
2. **Given** 擦除过程中某阶段失败，**When** 流程结束，**Then** 明确提示擦除不完整（system_panic_incomplete），不假装成功。

---

### User Story 8 - 后台保活与新消息通知 (Priority: P1)

应用退到后台或锁屏后，mesh 连接通过前台常驻服务（鸿蒙长时任务）维持；新私聊/提及消息触发系统通知，点击通知跳转对应会话；提供常驻状态通知显示当前 mesh 连接数。

**Why this priority**: IM 应用的基本可用性要求——后台断网等于不可用。

**Independent Test**: 熄屏 10 分钟后另一设备发消息，验证仍在后台收到并通知。

**Acceptance Scenarios**:

1. **Given** 应用退后台且屏幕熄灭，**When** mesh peer 发来私聊消息，**Then** 系统通知栏出现消息通知，点击进入对应会话。
2. **Given** 常驻通知，**When** mesh 连接数变化，**Then** 通知内容更新为当前连接的 peer 数。

---

### User Story 9 - 频道聊天（含密码频道） (Priority: P2)

用户可创建/加入主题频道进行群聊；频道可选密码保护：密码经 PBKDF2（100,000 次迭代，频道名作盐）派生密钥，频道消息以 AES-256-GCM 加密，未持密码者仅见密文。频道成员列表（`/who`）可见，频道列表（`/channels`）可浏览。

**Why this priority**: 频道把一对一/广播扩展为分组协作场景，是 mesh 社交的核心玩法；依赖一期消息管道成熟后实现性价比最高。

**Independent Test**: 两台设备加入同一密码频道互发消息，第三台无密码设备只见密文。

**Acceptance Scenarios**:

1. **Given** 设备 A 创建密码频道并广播，**When** 设备 B 使用相同密码加入，**Then** B 可解密阅读频道消息并可发言。
2. **Given** 设备 C 无密码，**When** 收到该频道消息，**Then** 仅显示加密占位提示，无法解密。

---

### User Story 10 - 媒体消息：图片 / 文件 / 语音消息（私有媒体 v1） (Priority: P2)

用户在私聊中发送图片、任意文件与录制的语音消息，采用**私有媒体 v1** 协议与 Android 现版互通：文件 TLV（0x01 文件名 / 0x02 文件大小 u64 大端 / 0x03 MIME / 0x04 内容分块，每块 ≤65,535 字节）整包经 Noise 端到端加密（外层 NOISE_ENCRYPTED 0x11 + Noise 载荷类型 0x20）后再分片走 mesh 传输，**绝不广播**；文件大小上限 **10,350,592 字节**（10 MiB − 132 KiB，预留 TLV/加密开销），且每包 ≤256 分片。对端能力通过 PEER_STATE（Noise 载荷 0x21：version + 能力 TLV + Ed25519 公钥 TLV）协商并钉扎（HSTS 式，5 秒代际看门狗）；对不支持私有媒体的旧客户端回退为签名裸 FILE_TRANSFER(0x22) 传输，UI 必须明示"非端到端加密"。接收方显式接受后内容才落盘（接受意图保留 15 秒），存储于应用私有目录（受存储配额约束）；发送方与接收方均可见传输进度。语音消息录制为 AAC，播放支持波形与倍速。

**Why this priority**: 私有媒体 v1 是与 Android 端媒体互通的硬性要求（经用户确认），且保持媒体端到端加密的安全承诺；依赖一期分片/重组与 Noise 会话。

**Independent Test**: 鸿蒙与 Android 双机互发一张图片与一条语音消息，验证加密传输、进度、存储与回放。

**Acceptance Scenarios**:

1. **Given** 双方均已协商私有媒体能力（PEER_STATE 0x21 钉扎完成），**When** A 发送图片，**Then** 图片以 NOISE_ENCRYPTED + 载荷 0x20 加密分片传输，B 显式接受后完整落盘并可全屏查看，中继节点无法解密。
2. **Given** 会话输入栏，**When** 长按录音并发送，**Then** 对方收到语音气泡，可播放并看到波形。
3. **Given** 对端为不支持私有媒体的旧客户端，**When** 发送文件，**Then** 回退签名裸 FILE_TRANSFER(0x22) 且发送方 UI 明示"非端到端加密"。
4. **Given** 超过大小上限（10,350,592 字节）的文件，**When** 尝试发送，**Then** 拒绝并提示超限。

---

### User Story 11 - 收藏好友与 QR 身份验证 (Priority: P2)

用户可将 peer 加为收藏（互为收藏解锁 Nostr 互联网投递通道与更大的信使/Store-Forward 配额）；面对面可通过扫 QR 码完成身份验证——URL 方案 `bitchat://verify`（携带 v/noise/sign/npub/nick/ts/nonce/sig 参数），将昵称与 Noise 指纹在可信信道绑定（Ed25519 签名挑战/响应，签名上下文 `bitchat-verify-v1` / 应答 `bitchat-verify-resp-v1`，nonce 16 字节随机，时间戳容差 300 秒，QR 缓存 60 秒），验证后 peer 显示已验证标记。

**Why this priority**: 收藏是 Nostr 路由（二期）与信使信任分层（US17）的信任前提；QR 验证提供防中间人的身份确认，属隐私安全增强。

**Independent Test**: 双机互加收藏 + 互扫 QR，验证双方均出现收藏与已验证标记。

**Acceptance Scenarios**:

1. **Given** 双方已连接，**When** A 将 B 加为收藏，**Then** B 出现在 A 的收藏列表，且 B 侧显示被收藏提示。
2. **Given** 双方打开验证页，**When** A 扫 B 的 QR 码并完成挑战/响应，**Then** 双方昵称旁出现已验证标记，绑定关系跨会话保持。

---

### User Story 12 - Nostr 互联网私信（互收藏回退通道） (Priority: P2)

互为收藏的双方在 mesh 不可达时，私聊消息自动经 Nostr 中继投递：消息按 bitchat 私有信封协议封装（rumor kind14 → seal kind13 → gift wrap kind1059，`v2:` 前缀 base64url(24 字节 nonce + XChaCha20-Poly1305 密文 + 16 字节 tag)，secp256k1 ECDH + HKDF-SHA256 密钥协商），中继仅见不透明信封；该格式复用 NIP-17/59 的 kind 编号但**不与 NIP-17/44/59 兼容**，仅与 bitchat 客户端互通。外层 seal/envelope 时间戳随机化 ±15 分钟，实际消息时间戳加密。客户端维护多中继 WebSocket 连接（初始退避 1 秒、倍率 2.0、上限 300 秒、最多 10 次；读取 ACK 间隔 350ms；去重容量 10,000；订阅校验周期 30 秒），重连后按 **48 小时**回看窗口（gift wrap）拉取离线消息。默认中继含 `wss://relay.damus.io`、`relay.primal.net`、`offchain.pub`、`nostr21.com`；中继目录资产（CSV，约 370 条含经纬度）打包为 raw 资源。geohash 别名路由至 Nostr。

**Why this priority**: 打通"mesh 之外"的全球可达性，补齐最终送达链路（白皮书 §6.4）。回看窗口按代码行为真源修正为 48 小时（白皮书 §6.4 记 24 小时，以代码为准）。

**Independent Test**: 两台设备不在蓝牙范围（均有网络），互发私聊消息验证经 Nostr 收达。

**Acceptance Scenarios**:

1. **Given** 互为收藏的 A、B 不在 mesh 范围但均有互联网，**When** A 发送私聊消息，**Then** 消息经 Nostr 中继投递，B 在线收到；B 离线期间的消息在其上线后 48 小时窗口内补收。
2. **Given** 中继连接断开，**When** 网络恢复，**Then** 按指数退避（1s→300s，×2）自动重连并恢复订阅。
3. **Given** 鸿蒙端与 Android 端互为收藏，**When** 经 Nostr 互发，**Then** 双方均可解密（信封格式跨平台互通）。

---

### User Story 17 - Courier 信使系统（离线密封邮件携带投递） (Priority: P2)

当 mesh 与 Nostr 均无法及时投递时，私聊消息以 Noise X 单向模式密封为**信使信封**（发送方身份在密文内认证；此路径无前向保密），交给最多 3 个可能物理 encountering 收件人的已连接 peer 携带：

- **不透明寻址**：唯一路由信息是 16 字节轮换收件人标签（收件人静态密钥与 UTC 日的 HMAC），仅已知该密钥方可计算，信使无法得知发/收件人与内容，标签跨日不关联。
- **信任分层配额**：互收藏 peer 每方可存 5 封、任何公告验签 peer 可存 2 封，入有界池（40 槽中 20 槽），收藏邮件永不被普通邮件挤出；信封 ≤16 KiB、24 小时 TTL，溢出优先逐出最旧的已验证层邮件。
- **Spray and wait**：信封携带复制预算（初始 4、上限 8），信使相遇时 handing 半数剩余预算，邮件在移动人群中扩散；预算/喷洒历史/携带邮件跨应用重启持久化。
- **投递（handover）**：收到收件人**直接**公告的验证后，匹配信封经活跃链路投递并移除；**中继**公告时向收件人方向定向洪泛一份副本（原件保留），每信封每 10 分钟至多尝试一次。
- **Store-Forward 缓存补发**：本机作为中继为离线 peer 缓存其私信（缓存 12 小时、普通 peer 最多 100 条、收藏 peer 1000 条、每 10 分钟清理），peer 上线后按时间排序补发（间隔 10ms）；不缓存握手/公告/广播。
- 接收方按消息 ID 去重（冗余副本与发件箱原件无害）；被屏蔽发件人的信使邮件在解密时丢弃。

**Why this priority**: Courier 是白皮书四大 store-and-forward 机制中现有 spec 唯一缺失的一环（经用户确认纳入二期）；补齐后"对方不在场"的最终送达链路与 Android 完全对齐。

**Independent Test**: A、B、C 三机：A 与 B 不相邻，C 先后进入 A、B 范围，A 发给 B 的私信经 C 携带最终送达 B。

**Acceptance Scenarios**:

1. **Given** A 与 B 互为收藏且不在彼此范围，**When** A 发送私聊消息，**Then** 消息以 Noise X 信封存入相邻信使 C 的有界池（配额内）。
2. **Given** 信使 C 携带信封进入 B 的范围，**When** 收到 B 的验证直接公告，**Then** 信封经活跃链路投递，B 解密展示，C 移除该信封。
3. **Given** 收件人静态密钥未知的一方（其他信使/旁观者），**When** 查看信封，**Then** 仅见 16 字节轮换标签与密文，无法关联收件人身份或跨日跟踪。
4. **Given** 池内普通配额（2 封/方）已满，**When** 新的互收藏 peer 邮件到达，**Then** 优先逐出最旧的普通邮件收纳收藏邮件。
5. **Given** 离线 peer 的缓存私信（Store-Forward），**When** 该 peer 重新上线，**Then** 按时间排序补发全部缓存消息。

---

### User Story 13 - geohash 位置频道 (Priority: P3)

用户通过 3D 地球仪选择器或定位服务进入地理范围频道（建筑 8 级 / 街区 7 级 / 社区 6 级 / 城市 5 级 / 省份 4 级 / 区域 2 级），频道消息经 Nostr 中继（g/n 标签）广播，支持地名反解显示、位置书签、按 geohash 派生临时身份以隔离真实身份；可开启 PoW 防垃圾（NIP-13 nonce tag，默认难度 12，默认关闭）。geohash presence 事件（kind 20001）回看窗口 1 小时。

**Why this priority**: 突破蓝牙半径的区域社交，属三期高级特性，依赖二期 Nostr 基础设施。

**Independent Test**: 两台有网络的设备加入同一城市级频道互见消息。

**Acceptance Scenarios**:

1. **Given** 地球仪选择页，**When** 用户旋转地球并点击某城市网格，**Then** 进入对应 geohash 频道并显示地名。
2. **Given** 两设备加入同一城市频道，**When** 一方发送消息，**Then** 另一方经 Nostr 收到；频道内身份为 geohash 派生身份，不泄露 mesh peer ID。

---

### User Story 14 - 实时语音对讲 (PTT) (Priority: P3)

用户按住对讲键向已建立 Noise 会话的 peer 实时发送语音流（AAC-LC 16kHz 单声道 16kbps，codec ID 0x01，1024 采样/帧 ≈64ms；burst 协议线格式 `[burstID:8B][seq:u16 BE][flags:u8][payload]`，START/FRAMES/END(含总包数与时长)/CANCELED，最短 600ms），接收端实时滚动波形显示；语音帧不进入 gossip 同步。接收端配额：并发组装 ≤8、单 burst ≤384 KiB、缓冲包 ≤128，超限丢弃。

**Why this priority**: 实时性要求高、QoS 复杂，放在 mesh 稳定成熟后的三期。

**Independent Test**: 双机 PTT 对讲，验证实时收听与波形滚动。

**Acceptance Scenarios**:

1. **Given** 双方已有 Noise 会话，**When** A 按住对讲键说话，**Then** B 近实时听到语音并看到滚动波形；A 松开后语音正常结束。

---

### User Story 15 - Tor 匿名网络 (Priority: P3)

Nostr 流量可经内置 Tor 代理（Arti）走洋葱路由，提供 SOCKS 代理端口供中继连接使用（Android 默认端口 9060）；用户可开关 Tor 模式（OFF/ON），开启后所有互联网流量均走代理且未引导完成时禁止直连。

**Why this priority**: 强隐私增强项；依赖 Arti 原生库的鸿蒙移植可行性，放三期并允许降级为"暂不支持"。

**Independent Test**: 开启 Tor 后 Nostr 连接经代理建立并发消息成功。

**Acceptance Scenarios**:

1. **Given** 设置页 Tor 开关，**When** 用户开启，**Then** Arti 代理启动成功后 Nostr 流量经代理收发，直连流量被抑制。

---

### User Story 16 - 三期调研与适配项 (Priority: P3)

包含：Wi-Fi Aware 鸿蒙等价能力调研（结论可为不可行/降级 BLE）；热点分享鸿蒙适配（应用内安装包分享替代 APK Web 服务器，可选）；跨平台 Mesh Lab 双机（鸿蒙↔Android/iOS）互操作验收测试。

**Why this priority**: 为后续版本扩展预留调研与验收通道，不阻塞主线。

**Independent Test**: 产出调研报告与互操作测试记录。

**Acceptance Scenarios**:

1. **Given** 鸿蒙与 Android 各一台真机，**When** 执行互操作验收（发现/公告/公聊/私聊/回执/媒体/同步/Nostr/信使），**Then** 全部场景通过并留档。

---

### Edge Cases

- BLE 权限被系统回收或用户关闭蓝牙：进入受限模式并引导重新开启，缓存的历史会话仍可浏览。
- 分片丢失/乱序/超时（30 秒）：丢弃未完成的重组，发送方依赖上层重试或用户重发；分片守卫（每 ID ≤256 片、≤1 MiB、活跃集 ≤64、全局 ≤4 MiB）超限即丢弃。
- 收到损坏包、签名验证失败包、非本协议包：静默丢弃，不影响会话状态。
- 压缩炸弹（声明原始大小 >1032× 压缩字节）：拒绝解压并丢弃。
- 对方更换身份（panic 后）：旧会话保留只读，新身份作为新 peer 出现。
- 发件箱/信使多路径重复到达：按消息 ID 去重，仅展示一次。
- 信使池溢出：优先逐出最旧普通层邮件；被屏蔽发件人邮件解密即丢弃。
- 存储空间不足：媒体写入失败时提示用户清理，聊天文本消息不受影响。
- 中继目录全部不可达：mesh 功能不受影响，仅 Nostr 功能降级并提示。
- 时钟漂移（公告/LEAVE 时间窗校验）：允许有界偏移（公告 60s 新鲜度、QR 300s 容差），超出按白皮书规则处理。
- PEER_STATE 代际超时（5 秒看门狗）：能力协商失败时按"不支持私有媒体"降级处理。

## Requirements *(mandatory)*

### Functional Requirements

**协议与加密内核（一期）**

- **FR-001**: 系统 MUST 实现 bitchat 二进制协议 v1/v2 包格式（v1 头 14 字节/v2 头 16 字节：版本、类型、TTL、时间戳 u64 大端、Flags、载荷长度 v1 用 2 字节/v2 用 4 字节；变长区顺序：SenderID(8B) → RecipientID(8B 可选) → Route(v2 可选) → 载荷 → 签名(64B 可选)），字节布局与现有客户端逐字节兼容；解码保留线上原始压缩字节（WirePayload）。
- **FR-002**: 系统 MUST 实现 DEFLATE 压缩（阈值 100 字节）、压缩炸弹防护（声明原始大小 > 1032× 压缩字节数拒绝）与按消息类型的接收载荷上限（FILE_TRANSFER/NOISE_ENCRYPTED 10 MiB、MESSAGE 及群消息 128 KiB、信使信封/Nostr 载体 64 KiB、REQUEST_SYNC 8 KiB、FRAGMENT 1,280 B、ANNOUNCE/LEAVE/NOISE_HANDSHAKE/VOICE_FRAME 4 KiB、未知类型 128 KiB），拒绝超限包。
- **FR-003**: 系统 MUST 实现分片与重组（>512 字节触发、单片 ≤469 字节、13 字节分片头、30 秒超时、清理周期 10 秒；每消息 ID ≤256 片、单 ID 总量 ≤1 MiB、活跃分片集 ≤64、全局分片总量 ≤4 MiB、片间发送延迟 20ms）。
- **FR-004**: 系统 MUST 实现与 Android 对齐的 TTL 受控洪泛中继：初始 TTL 7、同步包 TTL 0；稠密图（≥6 链路）广播 TTL 钳制为 5、细链（≤2 链路）全深度转发；转发抖动 10–220ms（稠密更宽）；入向链路排除（split horizon）；广播按 log₂(度) 消息 ID 种子确定性子集扇出，公告/分片/同步包全扇出；有向流量确定性 TTL−1、不子集；重复包先到取消已调度中继。
- **FR-005**: 系统 MUST 实现去重与重放保护（LRU seen 集 1000 条目、5 分钟过期，按 sender+timestamp+type+payload digest 键；先验签后记录；安全层已处理上限 10,000、去重窗口 60s、密钥交换上限 1,000；UI 消息去重 30s、系统事件 5s），保证重复包不被二次展示或二次中继。
- **FR-006**: 系统 MUST 实现 Noise `XX_25519_ChaChaPoly_SHA256` 会话加密（握手消息 32/96/48 字节序列、滑动窗口重放保护、会话超时清扫、rekey：1 小时/加密 1000 条/会话 10000 条），Noise 加密载荷类型编码（PRIVATE_MESSAGE 0x01 / READ_RECEIPT 0x02 / DELIVERED 0x03 / VOICE_FRAME 0x08 / VERIFY_CHALLENGE 0x10 / VERIFY_RESPONSE 0x11 / FILE_TRANSFER 0x20 / PEER_STATE 0x21），并与 Android/iOS 客户端互通。
- **FR-007**: 系统 MUST 生成并安全保管设备身份：Noise 静态密钥、Ed25519 签名密钥；peer ID = Noise 静态公钥 SHA-256 指纹前 8 字节（16 位小写 hex）；密钥以平台安全存储保管且排除于任何云备份之外。
- **FR-008**: 系统 MUST 实现事件驱动的签名身份公告（TLV：0x01 昵称/0x02 Noise 公钥/0x03 Ed25519 公钥/0x04 直接邻居 ≤10×8B/0x05 能力位域小端[bit0 prekeys、bit1 Wi-Fi bulk、bit2 gateway、bit3 群组、bit4 board、bit5 vouch、bit6 mesh 诊断、bit7 bridge、bit8 私有媒体、bit9 私有媒体回执]，未知 TLV 透传、未知能力位容忍），Ed25519 签名覆盖全部 TLV；隔离期每 4 秒、连接后约 15–30 秒（抖动）公告；验签通过标记 peer reachable 60 秒，180 秒无接触过期清理（扫描周期 60 秒）。
- **FR-009**: 系统 MUST 实现 gossip 公共历史同步（周期约 15 秒 GCS 过滤器对账：SHA-256 前 8 字节、MSB 优先位流、P ≤ 32、默认过滤器 256B、误报率 1.0%、接受上限 1024B；包 ID = SHA-256 派生；6 小时可同步窗口、缓存 1000 包、持久化）。
- **FR-010**: 系统 MUST 实现私聊发件箱（每 peer 100 条、24 小时 TTL、最多 8 次重发、路由 tick 2 秒、握手重试退避 5/15/30/60 秒、重连自动冲刷），并以磁盘加密形态持久化。
- **FR-011**: 系统 MUST 实现应用层垃圾过滤（令牌桶：消息 6 容量/10 秒 +1、字符 1200 容量/秒 +20、链接 2 容量/30 秒 +1；最大回溯 1 小时；跟踪 1000 发送者/4000 判定；判定类型含 MESSAGE_RATE/CHARACTER_RATE/LINK_RATE/REPEATED_MESSAGE/REPEATED_ACROSS_USERS/REPEATED_CHARACTERS）与可调配置。
- **FR-033**: 系统 MUST 实现基于公告拓扑的源路由（公告邻居 TLV 构建浅层拓扑图、60 秒新鲜度、双向确认路径源路由、失败回退洪泛）。

**BLE 传输与后台（一期）**

- **FR-012**: 系统 MUST 以相同 GATT Service/Characteristic UUID（Service `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`、Characteristic `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D`）实现 BLE 服务端与客户端双角色（与 Android/iOS 互通），含广播 service data 携带 peer ID；连接管理对齐（重试 5 秒/最多 3 次、断开宽限 10 秒、最大连接数 8）。
- **FR-013**: 系统 MUST 提供后台常驻能力（鸿蒙长时任务/前台服务等价物），锁屏与后台状态下维持 mesh 连接。
- **FR-014**: 系统 MUST 在新消息到达时发送系统通知（私聊/提及优先），点击通知跳转对应会话。
- **FR-015**: 系统 MUST 实现按 peer 串行化的入包有序处理（同 peer 包有序、跨 peer 并行、过载保护）。

**聊天业务（一期）**

- **FR-016**: 系统 MUST 提供公共聊天室、端到端加密私聊（送达/已读回执）与会话列表。
- **FR-017**: 系统 MUST 支持 IRC 风格命令集（`/join`(`/j`)、`/msg`(`/m`)、`/who`(`/w`)、`/clear`、`/block`、`/unblock`、`/channels`、`/hug`、`/slap`）与命令/提及自动补全。
- **FR-018**: 系统 MUST 提供屏蔽（block）能力：屏蔽后丢弃来自该发送者的私信、中继投递邮件与信使邮件（解密时丢弃），双向生效。
- **FR-019**: 系统 MUST 实现紧急擦除：确认后分阶段清除（定位服务→私媒同意→消息准入→会话库→UI 状态→去重/发件箱→垃圾过滤器→密钥学数据→通知→媒体文件→Nostr/geohash 状态→收藏/书签→重置昵称→重建身份），每落盘阶段确认成功，任一阶段失败必须明示（system_panic_incomplete）。
- **FR-020**: 系统 MUST 提供深浅双主题与终端式/气泡式双 UI 模式，偏好持久化；昵称上限 15 字符。

**二期功能**

- **FR-021**: 系统 MUST 实现主题频道（创建/加入/成员列表）与可选密码保护（PBKDF2 100k 迭代 + AES-256-GCM，参数与 Android 端一致以互通）。
- **FR-022**: 系统 MUST 实现私有媒体 v1：文件 TLV（0x01 文件名/0x02 大小/0x03 MIME/0x04 分块 ≤65,535B）整包 Noise 端到端加密（NOISE_ENCRYPTED 0x11 + 载荷 0x20）后分片传输、绝不广播；大小上限 10,350,592 字节、每包 ≤256 分片；PEER_STATE（0x21）能力协商与钉扎（5 秒代际看门狗）；旧客户端回退签名裸 FILE_TRANSFER(0x22) 且 UI 明示非加密；显式接受后落盘（接受意图 15 秒）、配额管理；语音消息 AAC 录制（波形/倍速播放）。
- **FR-023**: 系统 MUST 实现收藏关系（互为收藏解锁 Nostr 通道与更大信使/Store-Forward 配额）与跨启动持久化。
- **FR-024**: 系统 MUST 实现 QR 身份验证（`bitchat://verify` 深链、Ed25519 挑战/响应、上下文 `bitchat-verify-v1`/`bitchat-verify-resp-v1`、nonce 16B、时间戳容差 300 秒、QR 缓存 60 秒、验证状态持久展示）。
- **FR-025**: 系统 MUST 实现 Nostr 多中继客户端（WebSocket、指数退避 1s→300s 倍率 2.0 最多 10 次、读取 ACK 350ms、去重 10,000、订阅校验 30s、gift wrap 回看 **48 小时**、geohash presence 回看 1 小时）与 bitchat 私有信封（kind 13/14/1059、`v2:` 前缀 XChaCha20-Poly1305、secp256k1 ECDH + HKDF-SHA256、外层时间戳随机化 ±15 分钟、默认中继 4 个 + CSV 目录资产），格式与现有客户端互通。
- **FR-026**: 系统 MUST 实现私信智能路由：mesh 会话优先，mesh 不可达且 Nostr 映射可用走 Nostr，均不可达走信使（FR-034），否则入发件箱。
- **FR-034**: 系统 MUST 实现 Courier 信使系统：Noise X 密封信封（发送方身份密文内认证）；16 字节轮换收件人标签（静态密钥 + UTC 日的 HMAC）；信任配额（互收藏 5 封/方、验签公告 2 封/方、池 20/40 槽、收藏邮件不被挤出）；信封 ≤16 KiB/24h、溢出逐出最旧已验证层；spray-and-wait 复制预算（初始 4、上限 8）与喷洒历史跨重启持久化；新合格信使连接时重试存件直至 3 个信使携带或过期；直接公告验证后活跃链路投递移除、中继公告定向洪泛副本（每信封每 10 分钟一次）；Store-Forward 缓存（12 小时、普通 100 条/收藏 1000 条、10 分钟清理、上线按序补发间隔 10ms、不缓存握手/公告/广播）；接收按消息 ID 去重。

**三期功能**

- **FR-027**: 系统 SHOULD 实现 geohash 位置频道（geohash 编解码、六级 LEVEL 枚举[BUILDING 8/BLOCK 7/NEIGHBORHOOD 6/CITY 5/PROVINCE 4/REGION 2]、地球仪选择、地名反解、geohash 派生身份、g/n 标签、presence kind 20001 回看 1h、PoW 可选防垃圾[NIP-13，默认难度 12，默认关闭]）。
- **FR-028**: 系统 SHOULD 实现实时语音对讲（AAC-LC 16kHz 单声道 16kbps、burst 线格式 `[burstID:8B][seq:u16 BE][flags:u8][payload]`、START/FRAMES/END/CANCELED、最短 600ms、接收配额[并发 ≤8/单 burst ≤384 KiB/缓冲 ≤128]、实时波形、不进 gossip）。
- **FR-029**: 系统 SHOULD 支持经 Tor 的 Nostr 连接（Arti 代理，SOCKS 端口对齐 Android 默认 9060），开启后全部互联网流量走代理且未引导完成禁止直连；若原生移植不可行 MUST 输出明确结论与替代建议。
- **FR-030**: 系统 SHOULD 完成 Wi-Fi Aware 鸿蒙可行性调研并输出报告（含结论：等价 API / 降级 / 不可行）。

**质量与兼容**

- **FR-031**: 系统 MUST 通过从 Android 客户端测试套件移植的黄金向量契约测试（ClientRewriteWireContractTest、PacketPayloadLimitsWireContractTest、NoiseExternalVectorTest、GCSFilterTest/GCSFilterParameterTest、Bech32PaddingTest、BackupExclusionContractTest、ClientRewriteNostrContractTest 等关键线上格式），向量字面值不变。
- **FR-032**: 系统 MUST 在真机双机（鸿蒙↔鸿蒙、鸿蒙↔Android）环境完成 mesh 互操作验收（发现、公告、公聊、私聊、回执、同步、媒体、信使）。

### Key Entities *(include if feature involves data)*

- **BitchatPacket**: 线上二进制包（版本 1|2、类型、TTL、时间戳 u64 大端、Flags[HAS_RECIPIENT 0x01/HAS_SIGNATURE 0x02/IS_COMPRESSED 0x04/HAS_ROUTE 0x08]、发送者/接收者 peer ID(8B)、可选源路由（v2：1 字节数 + N×8B）、载荷（保留线上原始压缩字节）、可选签名 64B）。校验规则：签名前像为"去掉签名字段、TTL 归一化为 0"的编码；广播接收者 = 8 字节全 0xFF。
- **Peer**: 网络中的对等节点（peer ID 16 位小写 hex、昵称 ≤15 字符、Noise 公钥、Ed25519 公钥、直接邻居列表 ≤10、能力位域小端、reachable 状态 60s、stale 过期 180s、收藏/验证/屏蔽标记）。
- **BitchatMessage**: 聊天消息（发送者、内容、时间戳、类型：文本/图片/文件/语音/系统、送达/已读状态、所属会话、wirePayload 保留原始压缩字节）。
- **Conversation**: 会话（公共频道 / 频道 / 私聊三类；成员、消息时间线、未读计数、别名归一）。
- **NoiseSession**: 与某 peer 的加密会话（远端静态公钥、会话令牌、重放窗口、rekey 状态[1h/1000/10000]）。
- **Identity**: 设备身份（Noise 静态密钥对、Ed25519 签名密钥对、Nostr 密钥[二期]）；派生：`peerId = SHA-256(noiseStaticPub)[0..8]`。
- **OutboxEntry**: 发件箱条目（目标会话、消息、剩余 TTL 24h、重试计数 ≤8）。
- **CourierEnvelope**: 信使信封（Noise X 密文、16B 轮换收件人标签、复制预算 4→8、创建时间 24h TTL、≤16 KiB、存款方信任层）。
- **StoreForwardEntry**: Store-Forward 缓存条目（目标 peer、消息、缓存时间 12h TTL、目标配额层[普通 100/收藏 1000]）。
- **PeerState**: 私有媒体能力状态（代际、能力 TLV、Ed25519 公钥 TLV、5 秒看门狗、HSTS 式钉扎）。
- **Favorite**: 收藏关系（mesh peer ID ↔ Noise 公钥 ↔ Nostr npub 映射[二期]）。
- **Channel**: 主题频道（名称、可选密码派生密钥[PBKDF2 100k/频道名盐]、成员集合、消息时间线）。
- **Relay**: Nostr 中继（URL、连接状态、订阅集合、退避 1s→300s[二期]）。
- **FilePacket**: 媒体文件 TLV（文件名、大小 u64 大端、MIME、内容分块 ≤65,535B、未知 TLV 跳过）。
- **VoiceBurstPacket**: PTT 线格式（burstID 8B、seq u16 BE、flags u8、载荷；Start/Frames/End/Canceled）。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 一期完成后，两台 HarmonyOS 设备在 30 秒内完成互发现，公聊/私聊消息端到端送达率 ≥ 99%（20 条样本），断连重连后发件箱自动补投成功率 100%。
- **SC-002**: 鸿蒙端与 Android 端可互发现、互加私聊并正常收发（跨平台互通验收通过），协议黄金向量测试 100% 通过。
- **SC-003**: 私聊消息在任一中继节点处不可解密（抽验中继设备只见密文）；panic wipe 后设备上无可恢复的身份密钥与聊天明文。
- **SC-004**: 熄屏后台 30 分钟内 mesh 连接保持，新消息通知送达率 100%（10 次抽验）。
- **SC-005**: 二期完成后：互收藏双方在无 mesh 场景下经 Nostr 互发消息送达率 ≥ 95%；10,350,592 字节内文件端到端加密传输完整率 ≥ 99%；密码频道对无密码者零明文泄露；Courier 场景（三机 A-C-B）密封邮件携带投递成功。
- **SC-006**: 三期完成后：geohash 城市频道双机互通可用；PTT 端到端延迟 ≤ 1.5 秒；Tor 开关生效（或输出不可行结论报告）。
- **SC-007**: 冷启动至可发送第一条消息 ≤ 5 秒（已授权设备）；主界面消息流滚动 60 fps 无卡顿。

## Assumptions

- 目标平台为 HarmonyOS NEXT (API 12+) 手机形态；BLE、通知、长时任务、安全存储（HUKS 等价）等系统能力可用。
- 与 Android/iOS bitchat 客户端的线上协议互通为硬性要求，以 Android 端现有测试套件（契约/黄金向量测试）为兼容性基准来源。
- Android 端实现为功能与协议的行为真源（白皮书 WHITEPAPER.md v2.0 为协议语义真源）；白皮书与代码冲突时以代码为准（如 gift wrap 回看 48h、分片活跃集 64）。
- 开发团队具备 ArkTS/ArkUI 开发能力；密码学原语（Noise、ChaCha20-Poly1305、X25519、Ed25519、secp256k1、PBKDF2、AES-GCM）优先采用鸿蒙生态可用库，不足处自行移植并以黄金向量验证。
- 一期采用系统默认 BLE 扫描调度（电池感知占空比扫描策略不在范围）；如真机测试发现 mesh 稳定性问题，可在不改变协议行为的前提下于后续版本引入扫描策略调优。
- Wi-Fi Aware、Wear 端、多语言（一期先中英双语资源框架）、热点 APK 分享的 Android 原形态不在一期范围；`/pay` Cashu、Globe 视图、交付指标计数器、开机自启全程不在范围（见排除清单）。
- 文档交付边界：本次交付 spec.md（本文件）、plan.md（架构规划）、tasks.md（WBS）；不包含代码实现。

## Open Questions

- Arti (Tor) 原生 Rust 库在鸿蒙上的移植成本与合规性尚无结论，三期任务是否保留需在调研任务（US15/US16）后决策。
- 鸿蒙 BLE 后台扫描与连接的厂商省电策略差异（不同机型）可能影响 mesh 稳定性，需要真机测试矩阵覆盖范围在 Phase 3 细化。
- 鸿蒙侧 Nostr 中继目录（默认中继列表）沿用 Android 端资产文件（relay CSV，约 370 条）已在 FR-025 确认打包为 raw 资源。
