# Implementation Plan: bitchat 鸿蒙手机版（HarmonyOS NEXT）

**Input**: Feature specification from `spec/bitchat-harmonyos/spec.md` (v2)

## Summary

为 HarmonyOS NEXT (API 12+) 手机开发 bitchat 去中心化 P2P 通信客户端，与 Android/iOS 客户端线上协议二进制互通。技术路径：以 ArkTS 重写 bitchat 协议内核（二进制包、分片、中继优化洪泛[含 TTL 钳制/扇出子集/源路由]、Noise XX/X 加密、gossip 同步），BLE 传输层对齐现有 GATT UUID 约定；按三期里程碑交付（MVP：BLE mesh + 公聊/私聊 → Nostr/私有媒体/频道/Courier 信使 → geohash/PTT/Tor）。本次交付为规划文档（本 plan + WBS tasks.md），不含代码实现。

## Technical Context

**Language/Version**: ArkTS（ArkTS 严格模式，兼容 TS 子集），HarmonyOS SDK API 12+；协议内核中性能敏感的密码学原语保留 C++ NAPI 原生实现选项。
**Primary Dependencies**:
- 蓝牙：`@kit.ConnectivityKit`（`@ohos.bluetooth.ble`，GATT Server/Client + BLE 广播）
- 网络：`@kit.NetworkKit`（`@ohos.net.webSocket`，Nostr 中继，二期）
- 加密：`@kit.CryptoArchitectureKit`（cryptoFramework：SHA-256、HMAC、AES-GCM、ChaCha20-Poly1305、X25519、Ed25519 按可用性接入）；`@kit.UniversalKeystoreKit`（HUKS 密钥保管）；`@kit.AssetStoreKit`（Asset Store 关键资产存储）
- 数据：`@kit.ArkData`（RelationalStore 关系库、Preferences 轻量偏好）
- 后台：`@kit.BackgroundTasksKit`（长时任务 continuous task）+ `@kit.NotificationKit`（通知）
- 媒体：`@kit.MediaKit`（AVRecorder/AVPlayer，语音消息与 PTT）、`@kit.CoreFileKit`（沙箱文件）
- 二维码：`@kit.ScanKit`（扫码/生成码，二期 QR 验证）

**State Management**: 全新工程，采用 State Management V2（`@ComponentV2` / `@Local` / `@Param` / `@Event` / `@Monitor` / `@ObservedV2`+`@Trace`）；服务层向 UI 单向输出事件流（emitter/回调 → ViewModel 状态）。
**Storage**: Preferences（用户偏好/轻量状态）；RelationalStore（私聊会话库，载荷 AES-GCM 加密后入库）；Asset Store + HUKS（身份密钥、加密根密钥）；沙箱文件（媒体文件、发件箱加密持久化、公共历史缓存、信使携带邮件/喷洒历史持久化）。
**Testing**: hypium 单元测试 + 从 Android 契约测试套移植的黄金向量测试（ClientRewriteWireContractTest、PacketPayloadLimitsWireContractTest、NoiseExternalVectorTest、GCSFilterTest/GCSFilterParameterTest、Bech32PaddingTest、BackupExclusionContractTest、ClientRewriteNostrContractTest 等，向量字面值不变）；真机双机互操作验收（Mesh Lab 等价流程）。
**Target Platform**: HarmonyOS NEXT 手机，API 12+；真机测试矩阵覆盖主流机型。
**Project Type**: mobile-app（单 entry HAP；协议内核是否拆 HAR 见 Research D7）。
**Performance Goals**: 消息流滚动 60 fps；冷启动至可发消息 ≤ 5s；PTT 端到端延迟 ≤ 1.5s（三期）；BLE 包处理吞吐满足 8 peer 并发下无积压（入包队列丢弃率 < 1%）。
**Constraints**: 后台 BLE 常驻受系统调度约束（需长时任务）；协议互通为硬约束（黄金向量 100% 通过）；离线可用（无网环境下 mesh 全功能可用）。
**Scale/Scope**: 三期 17 个用户故事、34 条功能需求；估算规模一期 ~48 个 ArkTS/C++ 文件、二三期累计 ~85 个；UI 屏幕 6 个主视图 + 若干 Sheet/Dialog。

## Project Structure

### Documentation (this feature)

```text
spec/bitchat-harmonyos/
├── spec.md              # 需求规格（Phase 1 产出，v2）
├── plan.md              # 本文件（Phase 2 产出）
└── tasks.md             # WBS 任务分解（Phase 3 产出）
```

### Source Code (repository root)

新建 HarmonyOS 工程 `bitchat-harmonyos/`（devEco 标准模板，单 entry 模块）：

```text
bitchat-harmonyos/
├── AppScope/
│   └── resources/                          # 应用级资源（图标、字符串）
├── build-profile.json5                     # 工程配置（签名、模块、API 版本）
├── entry/
│   ├── src/main/
│   │   ├── module.json5                    # 权限、长时任务模式、能力声明
│   │   ├── ets/
│   │   │   ├── entryability/               # Ability 入口（启动初始化链）
│   │   │   ├── pages/                      # 页面装配与导航宿主
│   │   │   │   ├── ChatPage.ets            # 主聊天页（Navigation 宿主）
│   │   │   │   ├── OnboardingPage.ets      # 首启引导页
│   │   │   │   └── GeohashPickerPage.ets   # 地球仪选择页（三期）
│   │   │   ├── views/                      # 业务视图
│   │   │   │   ├── PublicChatView.ets      # 公共聊天室视图
│   │   │   │   ├── PrivateChatView.ets     # 私聊视图
│   │   │   │   ├── ChannelChatView.ets     # 频道视图（二期）
│   │   │   │   ├── ConversationListView.ets# 会话列表视图
│   │   │   │   ├── PeerNetworkView.ets     # 网络成员列表视图
│   │   │   │   └── SettingsView.ets         # 设置视图
│   │   │   ├── components/                 # 通用 UI 组件
│   │   │   │   ├── MessageBubble.ets       # 消息气泡（双 UI 模式）
│   │   │   │   ├── MessageInput.ets        # 输入栏（命令补全）
│   │   │   │   ├── PeerAvatar.ets          # 头像/颜色种子
│   │   │   │   ├── MediaBubble.ets         # 图片/文件/语音气泡（二期）
│   │   │   │   └── CommonDialogs.ets       # 通用对话框
│   │   │   ├── viewmodel/                  # UI 状态与业务编排
│   │   │   │   ├── ChatViewModel.ets       # 主编排器
│   │   │   │   ├── ChatState.ets           # UI 状态容器
│   │   │   │   └── CommandProcessor.ets    # IRC 命令处理
│   │   │   ├── model/                      # 领域模型（纯数据类型）
│   │   │   │   ├── BitchatPacket.ets       # 线上包模型 + MessageType 枚举
│   │   │   │   ├── BitchatMessage.ets      # 消息模型（含类型/回执枚举）
│   │   │   │   ├── PeerInfo.ets            # peer 模型
│   │   │   │   ├── IdentityModels.ets      # 身份/公告 TLV 模型
│   │   │   │   ├── FragmentModels.ets      # 分片/文件/语音包模型
│   │   │   │   └── CourierModels.ets       # 信使信封/StoreForward 模型（二期）
│   │   │   ├── service/                    # 领域服务与算法
│   │   │   │   ├── protocol/
│   │   │   │   │   ├── BinaryProtocol.ets  # v1/v2 编解码 + 签名前像
│   │   │   │   │   ├── PacketPayloadLimits.ets # 按类型载荷上限 + 压缩炸弹防护
│   │   │   │   │   ├── Compression.ets     # DEFLATE + 受控解压
│   │   │   │   │   └── MessagePadding.ets  # 填充策略（仅 Noise 帧 256/512/1024/2048 桶）
│   │   │   │   ├── mesh/
│   │   │   │   │   ├── BleMeshService.ets  # BLE 传输协调器（GATT 双角色）
│   │   │   │   │   ├── GattServer.ets      # GATT 服务端封装
│   │   │   │   │   ├── GattClient.ets      # GATT 客户端封装
│   │   │   │   │   ├── PacketProcessor.ets # 入包有序处理（Worker 池）
│   │   │   │   │   ├── PacketRelay.ets     # 中继决策（TTL 钳制/扇出子集/抖动/split horizon）
│   │   │   │   │   ├── TopologyMap.ets     # 公告拓扑图 + 源路由决策（一期）
│   │   │   │   │   ├── SecurityGate.ets    # 验签/去重/重放窗口
│   │   │   │   │   ├── FragmentManager.ets # 分片/重组（守卫 256片/1MiB/64集/4MiB）
│   │   │   │   │   ├── PeerManager.ets     # peer 生命周期（reachable 60s / stale 180s）
│   │   │   │   │   ├── AnnounceScheduler.ets # 公告调度（事件驱动 + 隔离期 4s / 连接后 15-30s）
│   │   │   │   │   ├── SpamFilter.ets      # 垃圾过滤
│   │   │   │   │   ├── CourierManager.ets  # 信使信封池/轮换标签/喷洒（二期）
│   │   │   │   │   ├── StoreForwardManager.ets # Store-Forward 缓存补发（二期）
│   │   │   │   │   └── PeerStateManager.ets# PEER_STATE 0x21 能力协商/钉扎（二期）
│   │   │   │   ├── noise/
│   │   │   │   │   ├── NoiseSession.ets    # 单会话（XX 模式状态机）
│   │   │   │   │   ├── NoiseSessionManager.ets # 会话表/握手超时清扫
│   │   │   │   │   ├── NoiseXSeal.ets      # Noise X 单向密封（信使信封，二期）
│   │   │   │   │   ├── NoisePrimitives.ets # X25519/ChaChaPoly/SHA256 原语门面
│   │   │   │   │   └── ChannelEncryption.ets  # 频道密码 PBKDF2+AES-GCM（二期）
│   │   │   │   ├── media/                  # 私有媒体 v1（二期）
│   │   │   │   │   └── MediaTransferManager.ets # 文件 TLV + Noise 0x20 加密分片传输 + 回退 0x22
│   │   │   │   ├── sync/
│   │   │   │   │   ├── GossipSyncManager.ets  # 同步调度（周期 ~15s + 新 peer 触发）
│   │   │   │   │   └── GCSFilter.ets      # Golomb 编码集过滤器
│   │   │   │   ├── routing/
│   │   │   │   │   ├── MessageRouter.ets  # 私信路由 + 发件箱（mesh→nostr→courier→outbox）
│   │   │   │   │   └── Outbox.ets         # 发件箱（加密持久化/重试）
│   │   │   │   ├── identity/
│   │   │   │   │   ├── IdentityManager.ets # 身份生成/指纹/panic 擦除
│   │   │   │   │   └── VerificationService.ets # QR 验证（二期）
│   │   │   │   └── nostr/                  # 二期+
│   │   │   │       ├── NostrRelayManager.ets # 多中继 WebSocket 客户端
│   │   │   │       ├── NostrProtocol.ets    # 事件/信封/secp256k1/Bech32
│   │   │   │       └── GeohashService.ets   # geohash/位置频道（三期）
│   │   │   ├── data/                       # 持久化访问
│   │   │   │   ├── SecureKeyStore.ets      # 密钥/资产存储门面（HUKS/Asset）
│   │   │   │   ├── ConversationStore.ets   # 私聊库（RelationalStore+加密载荷）
│   │   │   │   ├── PreferenceStore.ets     # 偏好读写门面
│   │   │   │   ├── FavoritesStore.ets      # 收藏/映射持久化（二期）
│   │   │   │   └── MediaFileStore.ets      # 媒体文件存取（二期）
│   │   │   └── common/                     # 常量与工具
│   │   │       ├── ProtocolConstants.ets   # 协议常量中心（UUID/TTL/限额/中继参数）
│   │   │       ├── EventBus.ets            # 服务→UI 事件分发
│   │   │       └── ByteUtils.ets           # 字节/Hex/Base64 工具
│   │   └── resources/                      # base/media/string/color/profile 等资源
│   ├── src/ohosTest/                       # 仪器化测试
│   └── src/test/                           # hypium 单元测试 + 黄金向量
│       ├── contract/                       # 线上契约黄金向量（移植自 Android）
│       └── unit/                           # 协议/会话/过滤逻辑单元测试
├── hvigor/                                 # 构建配置
└── (可选) library_native/                   # C++ 密码学原生库（按 D1 决策）
```

**Structure Decision**: 全新工程，选择 **MVVM 层级结构**。触发条件全部命中：多页面视图、持久化、复杂业务服务（mesh 协议栈）、跨页状态、可测试领域逻辑。文件数（一期约 48 个，超过 MVVM 默认 6–12 个）的理由：本项目为完整通信协议栈移植，参考源（bitchat-android）含约 300 个源文件；已按"一个文件聚合一个领域职责"压缩（如 BinaryProtocol 聚合全部编解码、GattServer/Client 各一文件），协议内核的模块边界（protocol/mesh/noise/sync/routing/media）与 wear 共享清单划定的"可脱离 UI 的协议内核"一致，无法进一步无损合并。页面（pages/）仅做装配与导航，算法、持久化、业务编排分别位于 service/、data/、viewmodel/，符合 MVVM 职责边界。资源全部置于 `entry/src/main/resources/`。若 Phase 4 启动时团队希望复用协议内核（如未来手表端），可按 D7 决策将 protocol/noise/sync 抽为 HAR，不影响当前结构。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| 文件数 ~48（一期），超出 MVVM 默认 6–12 | 完整 mesh 协议栈（编解码/分片/中继/安全/同步/加密会话/拓扑路由）无法在少量文件中保持可测试性与协议模块边界 | 合并为 10 余个大文件会让黄金向量测试无法按协议层定位缺陷，且丧失与 Android 源的对照可追溯性 |
| 可选 C++ 原生库（library_native） | ChaCha20-Poly1305/X25519 等原语若 cryptoFramework 覆盖不全，纯 ArkTS 性能不足（每包加解密） | 全部走 ArkTS 纯实现的吞吐在 8 peer 并发场景下可能成为瓶颈；最终按 D1 调研结论取舍 |
| 单工程内多个并列 service 域（mesh/nostr/media/identity） | 三期范围覆盖多套独立子系统 | 拆多 HAP/HAR 会引入跨模块调用与构建复杂度，单 HAP 分域目录已满足隔离需求 |

## Research & Decisions

**D1 - Noise/密码学原语实现路径**
- **Decision**: 加密原语优先接入 `@kit.CryptoArchitectureKit`（cryptoFramework：SHA-256/HMAC/AES-GCM/ChaCha20-Poly1305/X25519/Ed25519，按 API 12 实际可用清单核对）；Noise XX 状态机（握手序列 32/96/48 字节、会话密钥链、重放窗口）与 Noise X 单向密封（信使信封，二期）以纯 ArkTS 移植 noise-java 语义；cryptoFramework 缺失的原语以纯 ArkTS 实现补齐；若性能测试不达标，热点原语降级为 C++ NAPI 库。全部以 Noise 外部黄金向量 + Android 契约测试锁定正确性。
- **Rationale**: 协议互通要求字节级一致；状态机语义（握手时序、rekey、重放窗口、X 模式密封）必须与 noise-java 对齐，纯 ArkTS 移植可控性最高；原语走系统能力可受益于硬件加速与安全审计。
- **Alternatives considered**: ① 全套 C++ 移植 noise-java（放弃：构建/调试成本高，仅作性能兜底）；② 引用第三方 ArkTS Noise 库（放弃：生态不成熟，安全关键代码需自审）；③ HUKS 直接做会话加密（放弃：HUKS 面向密钥保管而非高频流式加解密）。

**D2 - BLE 传输与后台保活**
- **Decision**: 使用 `@ohos.bluetooth.ble` 实现 GATT Server（`createGattServer`，Service `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`、Characteristic `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D`，与 Android/iOS 一致）+ GATT Client（`createGattClientDevice`）+ BLE 广播（service data 携带 8 字节 peer ID）；声明 `ohos.permission.ACCESS_BLUETOOTH`；连接管理对齐 Android（重试 5s/最多 3 次、断开宽限 10s、最大连接数 8）；扫描策略采用系统默认调度（电池感知占空比扫描不在范围，见 spec 排除清单）；后台通过 `@kit.BackgroundTasksKit` 申请长时任务（bluetoothInteraction 通信类）+ 常驻通知维持 mesh。
- **Rationale**: 鸿蒙 BLE API 与 Android GATT 模型一一对应，UUID 级对齐即可互通；长时任务是鸿蒙后台常驻的唯一合规路径。
- **Alternatives considered**: ① 仅前台运行（放弃：IM 场景不可接受）；② 推送保活（放弃：去中心化无服务器，且离线场景必须本地常驻）。

**D3 - 密钥与敏感数据存储**
- **Decision**: 身份密钥（Noise 静态私钥、Ed25519 私钥、设备种子）与加密根密钥存 Asset Store（`@kit.AssetStoreKit`，系统级加密、防拷贝、排除于云备份——对应 Android BackupExclusionContractTest 语义）；派生数据（加密偏好、发件箱密文、信使携带邮件/喷洒历史、公共历史缓存）用 HUKS 内 AES-GCM 密钥加密后落沙箱文件；panic wipe 通过"清除 Asset 条目 + 删除派生文件 + 删除会话库"三段确认实现，每落盘阶段确认成功，失败明示 system_panic_incomplete。
- **Rationale**: 等价 Android Keystore/EncryptedSharedPreferences 的安全边界；Asset Store 提供免密钥管理的系统级保护，HUKS 补足应用层加密运算。
- **Alternatives considered**: ① 全部 HUKS（可行，但密钥元数据管理繁琐）；② 明文偏好 + 应用沙箱隔离（放弃：不满足白皮书保密性要求）。

**D4 - 并发模型**
- **Decision**: BLE 回调与 Worker 池分离：GATT 收包在事件回调中仅入队，由 Worker 线程池（`@ohos.taskpool`，按 peer ID 哈希到固定 Worker 串行处理）执行验签/解密/去重/分发；会话库单 Worker 串行写入；UI 状态经 EventBus（emitter）投递主线程。队列有界（过载丢新包并计数）。
- **Rationale**: 对齐 Android PacketProcessor worker 按 peer 哈希串行模型（保证同 peer 包序），避免主线程加解密卡顿；有界队列防内存膨胀。
- **Alternatives considered**: ① 全主线程处理（放弃：加解密阻塞 UI）；② 每包独立 TaskPool 任务（放弃：无法保证同 peer 有序性）。

**D5 - 持久化映射**
- **Decision**: 偏好→Preferences（`@ohos.data.preferences`）；私聊会话→RelationalStore（单库单写线程，消息载荷字段经 AES-GCM 加密后入库，库结构对齐 ConversationDatabase 语义）；公共历史缓存/发件箱/信使携带邮件（含预算与喷洒历史）/Store-Forward 缓存→加密文件（HUKS 密钥）；收藏/映射→加密 JSON 文件。全部在 data/ 层门面后，服务层不直接触碰存储 API。
- **Rationale**: 与 Android 端"自建 SQLite + SharedPreferences + Gson JSON"结构一一映射，降低移植歧义；data/ 门面保证 panic wipe 单点可控；信使携带邮件密文持久化对应白皮书"budgets, spray history, and carried mail persist across app restarts"。
- **Alternatives considered**: ① 全文件存储（放弃：会话查询/裁剪需要关系查询）；② 分布式数据对象（放弃：无多端同步需求）。

**D6 - Nostr 客户端与 Tor（二期/三期）**
- **Decision**: Nostr 中继用 `@ohos.net.webSocket` 自实现（多中继管理、指数退避 1s→300s 倍率 2.0 最多 10 次、读取 ACK 350ms、去重 10,000、订阅校验 30s、gift wrap 回看 48h、geohash presence 回看 1h），事件签名 secp256k1 走 D1 同一套原语门面（不足则纯 ArkTS + 向量测试）；默认中继 4 个（damus/primal/offchain/nostr21）+ 中继目录 CSV（约 370 条含经纬度，打包 raw 资源）；Tor 支持先做"SOCKS 代理参数化"接口预留（对齐 Android 默认端口 9060，开启后全部流量走代理且未引导完成禁止直连），三期评估 Arti C++/Rust 库鸿蒙移植（NDK→NAPI 工具链）可行性，不可行则输出报告并保留代理配置能力。
- **Rationale**: Android 端 Nostr 全部自实现无第三方库，语义可平移；webSocket Kit 能力足够；Arti 为 Rust 原生库，鸿蒙移植成本高且非核心链路，参数化代理先行可保架构开放。
- **Alternatives considered**: ① 二期即引入 Arti（放弃：阻塞二期交付，收益低）；② 完全放弃 Tor（保留为三期决策，避免关闭产品选项）。

**D7 - 模块划分（单 HAP vs 协议内核 HAR）**
- **Decision**: 一期采用单 entry HAP + 分域目录；protocol/noise/sync 等纯逻辑目录保持零 UI/零平台 API 依赖（仅 cryptoFramework 门面），为未来抽出 HAR 预留边界；若后续出现手表端等复用需求再拆 HAR，不提前拆分。
- **Rationale**: 避免多模块构建复杂度；wear 共享清单已证明该边界可行。
- **Alternatives considered**: ① 一期即拆 HAR（放弃：无第二个消费方，YAGNI）。

**D8 - 状态管理与 UI 架构**
- **Decision**: State Management V2（greenfield 默认）；单 Navigation 宿主 + NavDestination 路由（系统路由表 router_map）；ChatViewModel 作为唯一编排器持有 ChatState（@ObservedV2+@Trace），服务层只发事件不持 UI 引用；双主题/双 UI 模式经资源限定 + 组件分支实现。
- **Rationale**: V2 为新工程标准；单宿主多 Destination 与 Android 单 Activity 模型对应，避免多 Entry。
- **Alternatives considered**: ① V1 状态管理（放弃：新工程不选旧代）。

**D9 - 兼容性验证策略**
- **Decision**: 将 Android `app/src/test` 中的契约/黄金向量测试（ClientRewriteWireContractTest、PacketPayloadLimitsWireContractTest、NoiseExternalVectorTest、GCSFilterTest/GCSFilterParameterTest、Bech32PaddingTest、BackupExclusionContractTest、ClientRewriteNostrContractTest、FragmentManagerTest、PacketPayloadLimitsTest、BinaryProtocolTest、DecompressionResourcePoolTest、CommandProcessorTest、VerificationServiceTest、SpamFilterTest、MessageRouterTest、StoreForward 相关 FileTransferTest 等）作为移植基准，逐套移植到 `entry/src/test/`（hypium），向量字面值不变；真机互操作验收按 spec FR-032 执行双机脚本化场景。
- **Rationale**: 黄金向量是跨客户端线上兼容的唯一可执行证据；字面值不变保证"编码器与解码器共享同一缺陷"不会漏检。
- **Alternatives considered**: ① 仅做联调冒烟（放弃：无法证明字节级兼容）；② 自行设计向量（放弃：失去与参考实现的对齐锚点）。

**D10 - Wi-Fi Aware 与 wear 端（裁剪确认）**
- **Decision**: 一期不实现 Wi-Fi Aware；三期仅安排鸿蒙 NAN 等价能力调研任务（结论可为：不可行/降级 BLE/可等价实现），不承诺开发。Wear 端完全排除。热点分享三期按鸿蒙"应用分享/安装包分发"方式重设计（可选）。
- **Rationale**: 用户已确认裁剪；鸿蒙无公开 NAN API，避免不可控风险。
- **Alternatives considered**: ① 二期实现（放弃：无系统 API 支撑）。

**D11 - Courier 信使系统架构（二期，新增）**
- **Decision**: 新增 `service/mesh/CourierManager.ets`（信封池[40 槽/20 可用]、信任配额[互收藏 5/验签 2]、16B 轮换收件人标签[静态密钥 HMAC + UTC 日]、spray-and-wait 预算[4→8]、handover[直接公告→活跃链路投递移除；中继公告→定向洪泛副本、每信封每 10 分钟一次]、存款重试[新合格信使连接时重试、上限 3 信使]、信封 ≤16KiB/24h）与 `service/mesh/StoreForwardManager.ets`（缓存 12h、普通 100/收藏 1000、10 分钟清理、上线按序补发间隔 10ms、不缓存握手/公告/广播）；密封经 `service/noise/NoiseXSeal.ets`（Noise X 单向模式，发送方身份密文内认证）；携带邮件/预算/喷洒历史经加密文件持久化（D5）；路由次序接入 MessageRouter（mesh→Nostr→Courier→Outbox，FR-026/FR-034）；被屏蔽发件人邮件解密时丢弃。
- **Rationale**: Courier 是白皮书四大 store-and-forward 机制之一（§6.2），spec v2 经用户确认纳入二期；模块边界对齐 Android `mesh/StoreForwardManager.kt` 与白皮书语义；轮换标签的 HMAC 原语复用 D1 门面。
- **Alternatives considered**: ① 合并进 Outbox（放弃：语义不同——Outbox 是本机待发队列，Courier 是第三方携带密封邮件，生命周期/信任模型独立）；② 三期再做（用户已选二期）。

**D12 - 私有媒体 v1 架构（二期，新增）**
- **Decision**: 新增 `service/media/MediaTransferManager.ets`：文件 TLV（0x01 文件名/0x02 大小 u64 BE/0x03 MIME/0x04 分块 ≤65,535B）整包 Noise 加密（外层 NOISE_ENCRYPTED 0x11 + Noise 载荷 0x20）后经 FragmentManager 分片，绝不广播；大小上限 10,350,592B、每包 ≤256 分片；能力协商经 `service/mesh/PeerStateManager.ets`（PEER_STATE 载荷 0x21：version + 能力 TLV + Ed25519 公钥 TLV、5 秒代际看门狗、HSTS 式钉扎）；旧客户端回退签名裸 FILE_TRANSFER(0x22) 且 UI 明示"非端到端加密"；接收显式接受（意图 15 秒）后经 `data/MediaFileStore.ets` 落盘（配额管理、会话清理）；接受状态纳入 panic 清单。
- **Rationale**: 私有媒体 v1 是与 Android 现版媒体互通的硬性要求（Android `docs/PRIVATE_MEDIA_V1.md`）；PEER_STATE 钉扎防止能力降级攻击。
- **Alternatives considered**: ① 直接明文 FILE_TRANSFER（放弃：降级 E2EE 承诺，且与 Android 现版不互通）；② 三期再做加密（用户已选二期实现）。

**D13 - 中继优化实现（一期，新增）**
- **Decision**: `service/mesh/PacketRelay.ets` 实现完整洪泛控制：TTL 钳制（稠密 ≥6 链路广播 TTL≤5、细链 ≤2 全深度）、抖动 10–220ms（稠密更宽）、入向链路排除（split horizon）、广播 log₂(度) 消息 ID 种子确定性子集扇出（公告/分片/同步全扇出、有向流量确定性 TTL−1 不子集）、重复先到取消已调度中继；新增 `service/mesh/TopologyMap.ets`：解析公告邻居 TLV(0x04 ≤10×8B) 构建浅层拓扑（60s 新鲜度）、双向确认路径源路由、失败回退洪泛（FR-004/FR-033）。
- **Rationale**: 用户确认中继优化三件套纳入一期；密集组网下与 Android 中继行为一致是互通性能要求；TopologyMap 独立成文件因拓扑维护与转发决策职责分离、可独立单测。
- **Alternatives considered**: ① 二期再做（用户已选一期）；② 并入 SecurityGate（放弃：职责混杂，扇出子集与验签去重是不同关注点）。

## Data Model

核心实体（字段为规格级定义，实现时映射为 ArkTS class/interface；全部字段语义与 Android 端对齐以保证互通）：

- **BitchatPacket**（线上包）：`version: 1|2`、`type: MessageType`（ANNOUNCE 0x01 / MESSAGE 0x02 / LEAVE 0x03 / NOISE_HANDSHAKE 0x10 / NOISE_ENCRYPTED 0x11 / FRAGMENT 0x20 / REQUEST_SYNC 0x21 / FILE_TRANSFER 0x22 / VOICE_FRAME 0x29）、`ttl: number`、`timestamp: number(u64 BE)`、`flags`（HAS_RECIPIENT 0x01 / HAS_SIGNATURE 0x02 / IS_COMPRESSED 0x04 / HAS_ROUTE 0x08）、`senderId: Uint8Array(8)`、`recipientId?: Uint8Array(8)`（广播 = 全 0xFF）、`route?: Uint8Array[]`（v2 源路由）、`payload: Uint8Array`（保留线上原始压缩字节 WirePayload）、`signature?: Uint8Array(64)`。校验规则：签名前像排除 TTL 字节（TTL 归一化 0）；载荷长度 v1 用 2 字节 / v2 用 4 字节；变长区顺序 SenderID→RecipientID→Route→Payload→Signature。
- **PeerInfo**：`peerId: string(16 hex 小写)`、`nickname: string(≤15)`、`noisePublicKey?: Uint8Array(32)`、`ed25519PublicKey?: Uint8Array(32)`、`directNeighbors?: string[](≤10)`、`capabilities?: number`（小端位域：b0 prekeys/b1 Wi-Fi bulk/b2 gateway/b3 群组/b4 board/b5 vouch/b6 mesh 诊断/b7 bridge/b8 私有媒体/b9 私有媒体回执，未知位容忍）、`reachable: boolean`（验签公告后 60 秒有效）、`staleAt: number`（180 秒过期）、`isFavorite / isVerified / isBlocked: boolean`、`lastSeen: number`。
- **BitchatMessage**：`id: string`、`senderId`、`senderNickname`、`content: string`、`timestamp`、`type`（TEXT/IMAGE/FILE/AUDIO/SYSTEM）、`isRelayed: boolean`、`deliveryStatus`（PENDING/SENT/DELIVERED/READ/FAILED）、`channel: string`、`wirePayload?: Uint8Array`（防解压非规范化破坏签名）。
- **Conversation**：`kind`（PUBLIC/CHANNEL/PRIVATE）、`peerOrChannelId: string`、`aliasKeys`（peerID/NoiseKeyHex/npub 多别名归一）、`messages: BitchatMessage[]`、`unreadCount`、`passwordProtected?: boolean`。
- **Identity**：`noiseStaticKeyPair`、`ed25519KeyPair`、`nostrKeyPair?`（二期）、`deviceSeed?`；派生：`peerId = SHA-256(noiseStaticPub)[0..8]`。
- **NoiseSession**：`peerId`、`remoteStaticPub`、`sessionToken`、`sendState/receiveState`（密钥链）、`replayWindow: Bitfield(1024)`、`handshakeStage`、`establishedAt`、`rekeyPolicy`（1h/1000 加密/10000 会话）；状态迁移：INIT → XX_MSG1/2/3 → ESTABLISHED → REKEYED。Noise 加密载荷类型：PRIVATE_MESSAGE 0x01 / READ_RECEIPT 0x02 / DELIVERED 0x03 / VOICE_FRAME 0x08 / VERIFY_CHALLENGE 0x10 / VERIFY_RESPONSE 0x11 / FILE_TRANSFER 0x20 / PEER_STATE 0x21。
- **OutboxEntry**：`message: BitchatMessage`、`targetAlias`、`expiresAt`（24h）、`retryCount ≤ 8`、`lastAttemptAt`（路由 tick 2s、握手退避 5/15/30/60s）。
- **CourierEnvelope**（二期新增）：`ciphertext: Uint8Array`（Noise X 密封、≤16KiB）、`recipientTag: Uint8Array(16)`（静态密钥 HMAC + UTC 日轮换）、`copyBudget: number`（初始 4、上限 8）、`createdAt`（24h TTL）、`tier: FAVORITE|VERIFIED`（配额 5/2，池 40 槽 20 可用）。
- **StoreForwardEntry**（二期新增）：`targetPeerId`、`message`（密文）、`cachedAt`（12h TTL）、`tier: NORMAL|FAVORITE`（配额 100/1000）。
- **PeerState**（二期新增）：`peerId`、`generation: number`（5 秒看门狗）、`capabilities: number`（钉扎）、`ed25519PublicKey`、`pinned: boolean`（HSTS 式）。
- **Favorite**：`meshPeerId ↔ noiseKeyHex ↔ nostrNpub`（二期）双向映射。
- **Channel**：`name`、`isEncrypted`、`derivedKey?`（PBKDF2 100k 迭代、频道名盐）、`members: Set<peerId>`。
- **Relay**（二期）：`url`、`status`（CONNECTING/OPEN/BACKOFF/CLOSED）、`subscriptions`、`backoffMs`（1s→300s 指数 ×2，最多 10 次）。
- **FilePacket**（二期）：`fileName`、`fileSize: number(u64 BE)`、`mimeType`、`chunks: Uint8Array[](≤65,535B/块)`、未知 TLV 跳过。
- **VoiceBurstPacket**（三期）：`burstId: Uint8Array(8)`、`seq: number(u16 BE)`、`flags: number(u8)`、`payload`；Start/Frames/End(总包数+时长ms)/Canceled；AAC-LC 16kHz 单声道 16kbps、1024 采样/帧。

## Contracts & Interfaces

**线上协议契约（对外，硬性互通）**
- BLE GATT：Service UUID `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`、Characteristic UUID `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D`（与 Android/iOS 一致，常量中心定义）；广播 service data 携带 8 字节 peer ID。
- 二进制包：v1(14B 头)/v2(16B 头) 布局、大端字段、Flags 语义、变长区顺序（SenderID→RecipientID→Route→Payload→Signature）、签名前像规则（去签名、TTL 归 0）、每类型载荷上限（10MiB/128KiB/64KiB/8KiB/1280B/4KiB）、DEFLATE 压缩（阈值 100B、炸弹防护 1032:1）——以移植的黄金向量为验收。
- 中继：TTL 7 起始/稠密钳 5/同步 0；抖动 10–220ms；split horizon；广播 log₂ 子集扇出、公告/分片/同步全扇出、有向流量 TTL−1 不子集；拓扑源路由（公告 TLV 0x04、60s 新鲜度）失败回退洪泛。
- 分片：>512B 触发、≤469B/片、13B 头、30s 超时、守卫 256片/1MiB/64集/4MiB、片间 20ms。
- Noise：`Noise_XX_25519_ChaChaPoly_SHA256`（握手 32/96/48 字节；rekey 1h/1000/10000）+ `Noise_X` 单向密封（信使信封）；填充仅 Noise 帧（256/512/1024/2048 桶、PKCS#7 式、>255B 填充不填充）；频道加密 PBKDF2(100000, SHA-256, 频道名盐) + AES-256-GCM。
- 公告：TLV 0x01 昵称/0x02 Noise 公钥/0x03 Ed25519 公钥/0x04 直接邻居 ≤10×8B/0x05 能力位域小端；Ed25519 签名覆盖全部 TLV；事件驱动 + 隔离期 4s/连接后 15–30s；reachable 60s/stale 180s。
- 同步：REQUEST_SYNC（TTL=0）+ GCS 过滤器（SHA-256 前 8B、MSB 位流、P≤32、默认 256B、误报率 1%、上限 1024B），包 ID = SHA-256(type|sender|ts|payload) 前 16 字节；周期 ~15s；6h 窗口、缓存 1000 包。
- 私有媒体 v1（二期）：NOISE_ENCRYPTED 0x11 + 载荷 0x20（文件 TLV 整包加密后分片）、PEER_STATE 0x21（version+能力 TLV+Ed25519 TLV、5s 看门狗）、回退 FILE_TRANSFER 0x22（UI 明示非加密）、上限 10,350,592B、≤256 分片/包。
- Courier（二期）：Noise X 密封信封、16B 轮换标签（静态密钥 HMAC+UTC 日）、配额 5/2、池 20/40、≤16KiB/24h、spray 预算 4→8、handover（直接→链路投递/中继→定向洪泛副本 10min 节流）、Store-Forward（12h、100/1000、上线按序补发 10ms 间隔）。
- Nostr（二期）：kind 13/14/1059 信封、`v2:` 前缀 base64url(24B nonce + XChaCha20 密文 + 16B tag)、secp256k1 ECDH + HKDF-SHA256、Bech32 严格校验（拒绝非零丢弃位）、外层时间戳随机化 ±15 分钟、gift wrap 回看 48h/presence 1h、默认中继 4 个 + CSV 目录资产；复用 NIP-17/59 kind 编号但不兼容 NIP-17/44/59。
- QR 验证（二期）：`bitchat://verify?v&noise&sign&npub&nick&ts&nonce&sig` 深链、上下文 `bitchat-verify-v1`/`bitchat-verify-resp-v1`、nonce 16B、容差 300s、QR 缓存 60s。

**内部模块接口（service 边界）**
- `Transport`（传输抽象）：`start/stop`、`send(packet, recipient?)`、事件：`onPacketReceived / onPeerConnected / onPeerDisconnected`——一期实现 BleTransport，为 Wi-Fi Aware/未来传输预留注册位。
- `MeshService`（传输门面）：`broadcast(message)`、`sendPrivate(peerId, payload)`、`getPeers()`、`isReachable(peerId)`；输出事件流。
- `MessageRouter`：`route(privateMessage) → mesh | nostr | courier | outbox` 四级决策；`flushOutbox(trigger)`；新合格信使连接触发 Courier 存款重试。
- `CourierManager`（二期）：`sealAndDeposit(message, recipientStaticKey)`、`carryPool`（配额/池管理）、`onDirectAnnounce(peer)`→handover、`onRelayedAnnounce(peer)`→定向副本（10min 节流）、`spray(otherCourier)`。
- `StoreForwardManager`（二期）：`cache(entry, tier)`、`onPeerOnline(peerId)`→按序补发、清理周期 10min。
- `PeerStateManager`（二期）：`negotiate(peerId)`→PEER_STATE 交换、`isPrivateMediaCapable(peerId)`（钉扎后）、看门狗 5s。
- `MediaTransferManager`（二期）：`send(file, peerId)`（TLV→Noise 0x20→分片）、`accept(transferId)`（意图 15s）、`fallbackLegacy(file, peerId)`（0x22 + UI 明示）。
- `IdentityManager`：`initialize()`、`getPeerId()`、`sign(bytes)`、`verify(bytes, sig, pubKey)`、`panicWipe()`（分阶段、逐段确认、失败 system_panic_incomplete）。
- `SecureKeyStore`：`putKey/getKey/removeAll`（Asset Store 后端）；`encryptFile/decryptFile`（HUKS 后端）。
- `EventBus`：服务层→ViewModel 单向事件（`peer-updated`、`message-received`、`session-established`、`outbox-flushed`、`courier-deposited`、`courier-delivered`、`transfer-progress`、`peer-state-pinned` 等），UI 不得反向直呼服务内部。

**持久化接口**
- `ConversationStore`：`append(encryptedMessage)`、`query(peerOrChannel, limit)`、`trim(policy)`、`dropAll()`（panic）。
- `PreferenceStore`：类型化 get/set + panic 清单注册。
- 测试契约：`entry/src/test/contract/` 黄金向量 100% 通过为发布门禁；真机互操作验收清单见 spec FR-032。

**系统能力声明（module.json5 级）**
- 权限：ACCESS_BLUETOOTH、INTERNET（二期）、LOCATION（BLE 扫描合规）、NOTIFICATION、MICROPHONE（二期语音）、CAMERA（二期扫码）等，全部带用途文案。
- 后台模式：bluetoothInteraction 长时任务 + 常驻通知。

## Changelog

- **2026-10-29（v2 修订，对齐 spec.md v2）**：
  - 新增 D11（Courier 信使系统架构）、D12（私有媒体 v1 架构）、D13（中继优化实现）三项决策。
  - Project Structure 新增文件：`CourierManager.ets`、`StoreForwardManager.ets`、`PeerStateManager.ets`、`NoiseXSeal.ets`、`TopologyMap.ets`、`MediaTransferManager.ets`（service/media/ 新域）、`CourierModels.ets`。
  - Data Model 新增实体：CourierEnvelope、StoreForwardEntry、PeerState、FilePacket、VoiceBurstPacket；PeerInfo 补 directNeighbors/capabilities 位域/staleAt；NoiseSession 补 rekey 策略与载荷类型枚举。
  - Contracts 更新：中继洪泛控制全参数、私有媒体 v1 线格式、Courier 线上契约、Nostr 回看 48h（修正自 24h，以代码为行为真源）、公告调度（事件驱动+隔离期 4s）、分片守卫全参数、压缩炸弹防护 1032:1、QR 验证深链全参数。
  - D2 更新：连接管理参数对齐（5s/3 次/宽限 10s/最大 8 连接）、扫描策略采用系统默认（电池占空比扫描排除）。
  - D3 更新：备份排除语义（对应 BackupExclusionContractTest）、panic 逐段确认。
  - D5 更新：信使携带邮件/喷洒历史加密持久化。
  - D9 更新：契约测试清单扩充（PacketPayloadLimitsWireContractTest 等）。
