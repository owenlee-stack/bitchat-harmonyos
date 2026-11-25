# Tasks: bitchat 鸿蒙手机版（HarmonyOS NEXT）WBS

**Input**: Design documents from `spec/bitchat-harmonyos/`（spec.md v2 + plan.md v2）
**Prerequisites**: plan.md（技术栈/架构/D1–D13 决策）、spec.md（17 个用户故事、34 条功能需求）
**交付边界**: 本文件为 WBS 规划文档（v2 基线，含 WBS 字典/活动清单/CPM/网络图/交付物清单）；任务路径均相对于新建工程根目录 `bitchat-harmonyos/`。
**里程碑映射**: M1 一期 MVP = US1–US8 · M2 二期 = US9–US12 + US17 · M3 三期 = US13–US16
**基线与变更管理**: 本文件为评审通过后的 v2 基线；任何范围/进度变更须经评审门禁确认并更新文档，禁止未评审的 scope creep（排除清单见 spec.md）。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 所属用户故事（US1–US17）；Setup/Foundational/Polish/Verification 阶段无此标签

## Path Conventions

- 任务路径均相对新建工程根目录 `bitchat-harmonyos/`（如 `entry/src/main/ets/...`）
- 参考源码位于 `bitchat_android/bitchat-android-main/`（只读，黄金向量与协议语义对照来源，不修改）
- 规划文档位于 `spec/bitchat-harmonyos/`

## WBS 总览

```text
1 bitchat 鸿蒙手机版
├── 1.1 Setup 工程初始化 (T001–T004)
├── 1.2 协议内核 Foundational (T005–T017)
├── 1.3 一期 M1 — MVP
│   ├── 1.3.1 US1 身份初始化 (T018–T020)
│   ├── 1.3.2 US2 BLE 发现互连 (T021–T025)
│   ├── 1.3.3 US3 公聊广播+中继优化 (T026–T031)
│   ├── 1.3.4 US4 Noise 私聊+发件箱 (T032–T036)
│   ├── 1.3.5 US5 垃圾过滤 (T037–T038)
│   ├── 1.3.6 US6 IRC 命令+双主题 (T039–T042)
│   ├── 1.3.7 US7 紧急擦除 (T043–T044)
│   └── 1.3.8 US8 后台保活+通知 (T045–T046)
├── 1.4 二期 M2
│   ├── 1.4.1 US9 密码频道 (T047–T049)
│   ├── 1.4.2 US10 私有媒体 v1 (T050–T054)
│   ├── 1.4.3 US11 收藏+QR 验证 (T055–T057)
│   ├── 1.4.4 US12 Nostr 私信 (T058–T060)
│   └── 1.4.5 US17 Courier 信使系统 (T061–T065)
├── 1.5 三期 M3
│   ├── 1.5.1 US13 geohash 位置频道 (T066–T068)
│   ├── 1.5.2 US14 实时语音 PTT (T069–T070)
│   ├── 1.5.3 US15 Tor (T071–T072)
│   └── 1.5.4 US16 调研+互操作验收 (T073–T075)
├── 1.6 收尾加固 Polish (T076–T081)
└── 1.7 验证交付 Verification (T082–T083)
```

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: 工程初始化与共享配置

- [x] T001 创建 HarmonyOS 工程骨架（devecocli create，API 12+、模块与签名配置）于 bitchat-harmonyos/
- [x] T002 [P] 配置 entry/src/main/module.json5：权限（ACCESS_BLUETOOTH、LOCATION、NOTIFICATION、INTERNET、MICROPHONE[二期]、CAMERA[二期]）、bluetoothInteraction 长时任务模式、通知能力声明
- [x] T003 [P] 创建 MVVM 目录骨架（entry/src/main/ets/ 下 pages/views/components/viewmodel/model/service/protocol|mesh|noise|media|sync|routing|identity|nostr/data/common，entry/src/test/ 下 contract/unit）与系统路由表 resources/base/profile/router_map.json
- [x] T004 [P] 建立 entry/src/main/resources/ 资源骨架：应用图标、双主题色板（dark/light）、中英双语 string 资源框架

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 协议内核与共享基础设施——所有用户故事的阻塞前置

**⚠️ CRITICAL**: 本阶段（含 T017 契约测试全绿门禁）完成前不得开始任何用户故事

- [x] T005 定义协议常量中心 entry/src/main/ets/common/ProtocolConstants.ets（GATT UUID、TTL=7/钳制 5、分片 469B/13B 头/守卫 256片/1MiB/64集/4MiB/20ms、载荷限额、压缩阈值 100B/炸弹比 1032、去重 LRU 1000/5min、公告 4s/15-30s/60s reachable/180s stale、发件箱 100/24h/8、Nostr 退避 1s→300s、抖动 10-220ms，逐项对照 Android AppConstants）
- [x] T006 [P] 实现字节工具 entry/src/main/ets/common/ByteUtils.ets（Hex/Base64/Base64url 编解码、大端 u16/u32/u64 读写、Uint8Array 拼接/切片）
- [x] T007 [P] 实现事件总线 entry/src/main/ets/common/EventBus.ets（服务层→ViewModel 单向事件分发，主线程投递）
- [x] T008 [P] 实现领域模型层 entry/src/main/ets/model/（BitchatPacket.ets、BitchatMessage.ets、PeerInfo.ets、IdentityModels.ets、FragmentModels.ets，字段语义对齐 plan.md Data Model）
- [x] T009 实现密码学原语门面 entry/src/main/ets/service/noise/NoisePrimitives.ets：按 D1 决策核对 cryptoFramework（API 12）可用清单，缺口以纯 ArkTS 补齐，输出可用性结论记录于 spec/bitchat-harmonyos/notes-crypto.md（性能不达标时记录 C++ NAPI 兜底建议）✅ 2026-11-05：NoisePrimitives 门面 = ChaChaPolyCipher（noise-java ChaChaCore/Poly1305 直移植）+ Curve25519（BigInt RFC 7748）+ hkdfSha256 双输出；可用性结论落 notes-crypto.md（Noise 路径全部纯 ArkTS，cryptoFramework 全异步不适用）；RFC 7539/7748/5869 + OpenSSL 重生成黄金向量全绿（NoisePrimitivesContractTests），node:crypto 交叉验证（chacha20-poly1305 200 轮/x25519 50 轮 fuzz）全过；性能基准留待真机（D1 兜底 C++ NAPI）
- [x] T010 实现安全存储门面 entry/src/main/ets/data/SecureKeyStore.ets（Asset Store 存身份密钥/设备种子、HUKS 派生密钥做应用层 AES-GCM 加解密、备份排除、panic 清除接口）✅ 2026-11-05：putKey/getKey/hasKey/removeKey 走 Asset Store（SYNC_TYPE NEVER，update-then-add）；ensureDerivedKey/encryptData/decryptData/encryptFile/decryptFile 走 HUKS 非导出 AES-256-GCM（信封 [ver1][nonce12][ct][tag16]，64KiB 分段 updateSession，AAD 常量绑定）；备份排除 = backup_config.json allowToBackupRestore=false（BackupExclusionContract 断言）+ Asset 系统级排除；panicWipe()=removeAllKeys（分页查询逐条清除）+removeDerivedKey；SecureStoreError 保留 SDK 错误码
- [x] T011 [P] 实现偏好门面 entry/src/main/ets/data/PreferenceStore.ets（@ohos.data.preferences 封装 + panic 清单注册）✅ 2026-11-05：单文件 bitchat_prefs，init 幂等并发共享，类型化 get/set（boolean/number/string，getSync+putSync+flush），has/remove/clearAll——panic 清单覆盖 = 全部偏好经此门面单文件落盘，clearAll() 即 T043 的"清 UI 状态"阶段入口
- [x] T012 实现二进制协议编解码器 entry/src/main/ets/service/protocol/BinaryProtocol.ets（v1 14B/v2 16B 头部、大端字段、Flags、变长区顺序、签名前像 TTL 归零、保留线上原始压缩字节 WirePayload）
- [x] T013 [P] 实现载荷治理 entry/src/main/ets/service/protocol/PacketPayloadLimits.ets 与 Compression.ets、MessagePadding.ets（按类型限额 10MiB/128KiB/64KiB/8KiB/1280B/4KiB、DEFLATE 与受控解压、1032:1 炸弹防护、Noise 帧 256/512/1024/2048 桶填充）
- [x] T014 实现分片重组器 entry/src/main/ets/service/mesh/FragmentManager.ets（>512B 触发、单片 ≤469B、13B 分片头、30s 超时、守卫 256片/1MiB/64集/4MiB、片间 20ms）
- [x] T015 实现安全闸门 entry/src/main/ets/service/mesh/SecurityGate.ets（Ed25519 先验签后记录、LRU 去重集 1000/5min、重放窗口、已处理上限 10,000、UI 去重 30s/5s）
- [x] T016 [P] 移植黄金向量契约测试到 entry/src/test/contract/（ClientRewriteWireContractTest、PacketPayloadLimitsWireContractTest、NoiseExternalVectorTest、GCSFilterTest/GCSFilterParameterTest、Bech32PaddingTest、BackupExclusionContractTest、ClientRewriteNostrContractTest，向量字面值取自 bitchat_android app/src/test 对应测试文件，不得改动）— 8/8 全部移植完成：Wire、PacketPayloadLimits、GCSFilter、GCSFilterParameter、Bech32、BackupExclusion（NoisePrimitives 向量附带落位）、NoiseExternalVectorTest（cacophony XX 全向量，落位 NoiseSessionContractTests）、NostrProtocolTest（随 US5 落位 NostrContractTests，NIP-44/secp256k1 就绪）
- [x] T017 运行 entry/src/test/contract/ 契约测试并修复至全绿（协议内核互通门禁，对应 FR-031）— 当前 35 passed 0 failed（全部模块全绿，2026-11-25 实测复核）

**Checkpoint MS1**: 协议内核就绪且契约测试全绿——用户故事可并行展开

---

## Phase 3: User Story 1 - 首次启动与身份初始化 (Priority: P1) 🎯 M1

**Goal**: 无账号首启体验：权限引导、身份密钥生成、昵称设置
**Independent Test**: 全新安装完成引导进入主界面，重启后身份与昵称保持；peerID = SHA-256(Noise 静态公钥) 前 8 字节

- [x] T018 [P] [US1] 实现身份管理器 entry/src/main/ets/service/identity/IdentityManager.ets（密钥对生成、peerID 派生、指纹、昵称 ≤15 字符、身份持久化经 SecureKeyStore）✅ 2026-11-05：Noise 静态对=随机 32B 私钥+纯 ArkTS Curve25519 公钥（noise-java 语义）；Ed25519=cryptoFramework 生成/签名/验签，原始 32B 密钥经固定 DER 头（PKCS#8 302e...657e / SPKI 302a...657e）wrap/unwrap 与 Android/iOS 线格式一致；peerId=NoisePeerIdentity.derivePeerID（SHA-256 前 8B hex）；指纹=静态公钥全量 SHA-256 hex；昵称经 PreferenceStore（≤UiConstants.MAX_NICKNAME_LENGTH=15，首读生成 anon1000-9998 对齐 Android Random.nextInt(1000,9999)）；initialize 幂等并发共享，密钥缺失/尺寸错误时按对独立重生成；sign/verify 失败返回 null/false（对齐 Android）
- [x] T019 [P] [US1] 实现引导页 entry/src/main/ets/pages/OnboardingPage.ets（权限引导流、昵称输入、受限模式提示）✅ 2026-11-05：三步状态机（权限说明→受限提示→昵称）；蓝牙=ACCESS_BLUETOOTH normal 级安装即授（仅说明）；位置对 LOCATION+APPROXIMATELY_LOCATION 经 atManager.requestPermissionsFromUser（PermissionRequestResult 自 @kit.AbilityKit 根导入）；通知=isNotificationEnabled→requestEnableNotification（拒绝不阻断，走受限语义）；位置拒绝→受限模式提示（重新授权/继续使用）；昵称输入 maxLength 15+计数+校验，完成时 setNickname→onboarding_completed=true→router.replaceUrl 主页；已注册 main_pages.json；遗留：requestEnableNotification/replaceUrl 弃用告警（通知重申请 UX 挂后续 UI 任务；replaceUrl 随 T030 Navigation 路由消亡）
- [x] T020 [US1] 实现启动初始化链 entry/src/main/ets/entryability/EntryAbility.ets（服务单例装配、身份加载、EventBus 接线、首启路由分支）✅ 2026-11-05：onWindowStageCreate 同步入口→async bootstrap：PreferenceStore.init（单次共享加载）→读 onboarding_completed 首启分支→IdentityManager.initialize（幂等 load-or-generate，先于页面渲染就绪）→loadContent(onboarded ? pages/Index : pages/OnboardingPage)；EventBus 为纯静态总线（订阅方挂后续 ViewModel 任务）；Index.ets 改为临时身份主页占位（昵称+peerID+指纹，T030 由 ChatPage 替换）

**Checkpoint**: US1 独立可测——可演示完整首启流程

---

## Phase 4: User Story 2 - BLE Mesh 发现与连接 (Priority: P1) 🎯 M1

**Goal**: GATT 双角色互发现互连，事件驱动公告（隔离期 4s/连接后 15-30s），reachable 60s/stale 180s，跨平台互通
**Independent Test**: 双机互见 peer 列表；与 Android bitchat 设备互发现（FR-032 前置）

- [x] T021 [P] [US2] 实现 GATT 服务端 entry/src/main/ets/service/mesh/GattServer.ets（createGattServer、Service/Characteristic UUID 对齐、广播 service data 携带 peer ID、notify 下行、连接管理 5s/3 次/宽限 10s/最大 8 连接）
- [x] T022 [P] [US2] 实现 GATT 客户端 entry/src/main/ets/service/mesh/GattClient.ets（扫描过滤、连接、服务发现、MTU 协商、write 上行）
- [x] T023 [US2] 实现 BLE 传输协调器 entry/src/main/ets/service/mesh/BleMeshService.ets 与 Transport 抽象（start/stop/send/事件回调，注册未来 Wi-Fi Aware 扩展位；集成 FragmentManager/SecurityGate 收发链路）
- [x] T024 [US2] 实现公告与 peer 管理 entry/src/main/ets/service/mesh/AnnounceScheduler.ets 与 PeerManager.ets（事件驱动+隔离期 4s/连接后 15-30s、公告 TLV 0x01-0x05 编解码/验签/邻居 ≤10/能力位域、reachable 60s、stale 180s/清理 60s）
- [x] T025 [US2] 实现网络成员视图 entry/src/main/ets/views/PeerNetworkView.ets（成员列表、昵称/peerID/在线状态展示）

**Checkpoint**: US2 独立可测——双机互发现；与 Android 端互发现验证

---

## Phase 5: User Story 3 - 公共聊天室广播（含中继优化三件套） (Priority: P1) 🎯 M1

**Goal**: 签名广播 + 洪泛控制（TTL 钳制/扇出子集/split horizon）+ 拓扑源路由 + gossip 同步 6 小时公共历史
**Independent Test**: 三机链式组网 A→B→C 多跳收达；新设备入网补齐历史；重复包不重复展示

- [x] T026 [US3] 实现入包处理器 entry/src/main/ets/service/mesh/PacketProcessor.ets（Worker 池按 peer 哈希串行、有界队列过载丢弃计数，D4 并发模型）
- [x] T027 [US3] 实现中继决策 entry/src/main/ets/service/mesh/PacketRelay.ets（TTL 钳制：稠密 ≥6 链路广播 TTL≤5/细链全深度、抖动 10-220ms、split horizon、广播 log₂(度) 消息 ID 种子子集扇出、公告/分片/同步全扇出、有向流量 TTL−1 不子集、重复先到取消已调度中继、REQUEST_SYNC TTL=0 不中继）
- [x] T028 [P] [US3] 实现拓扑图与源路由 entry/src/main/ets/service/mesh/TopologyMap.ets（解析公告邻居 TLV 0x04 构建浅层拓扑 60s 新鲜度、双向确认路径源路由、失败回退洪泛，FR-033）
- [x] T029 [US3] 实现 gossip 同步 entry/src/main/ets/service/sync/GossipSyncManager.ets 与 GCSFilter.ets（周期 ~15s+新 peer 触发、GCS SHA-256 前 8B/MSB 位流/P≤32/256B/1% 误报/上限 1024B、包 ID 派生、6h 窗口、缓存 1000 包持久化）
- [x] T030 [US3] 实现主页面与状态编排 entry/src/main/ets/pages/ChatPage.ets、entry/src/main/ets/viewmodel/ChatViewModel.ets、ChatState.ets（Navigation 宿主、@ObservedV2 状态容器、会话/公共时间线状态）
- [x] T031 [US3] 实现公共聊天视图 entry/src/main/ets/views/PublicChatView.ets（公共时间线渲染、消息分组、发送广播接入 PacketRelay/TopologyMap）

**Checkpoint**: US3 独立可测——MVP 核心闭环（发现→广播→中继→同步）可演示

---

## Phase 6: User Story 4 - 端到端加密私聊 (Priority: P1) 🎯 M1

**Goal**: Noise XX 会话加密私聊、送达/已读回执、发件箱离线补投
**Independent Test**: 双机私聊互通（含与 Android 端）；断连重连后发件箱按序补投

- [x] T032 [P] [US4] 实现 Noise 会话 entry/src/main/ets/service/noise/NoiseSession.ets（XX 模式 32/96/48B 握手、密钥链、1024 位滑动重放窗、rekey 1h/1000/10000、载荷类型 0x01/0x02/0x03/0x08/0x10/0x11/0x20/0x21，语义对齐 noise-java 并通过契约向量）— 落位 NoiseSymmetricState/NoiseXXHandshake/NoiseSession + NoiseSessionContractTests（cacophony XX 向量全转录；重放窗滑动方向修复 Android ushr/shl 颠倒 bug，收包计数器补齐 Android 不递增 bug，均已在头注记）；载荷类型已在 IdentityModels.ets；12/12 全绿
- [x] T033 [P] [US4] 实现会话管理器 entry/src/main/ets/service/noise/NoiseSessionManager.ets（每 peer 会话表、10s 握手超时、2s 清扫、响应方候选防降级）— 落位 NoiseSessionManager + NoiseSessionManagerContractTests（移植 Android 两个测试类：超时清扫/身份绑定全语义，固定 4 身份碰撞矩阵 6 对；清扫调度器/时钟/临时密钥源注入保持 host 可跑）；13/13 全绿
- [x] T034 [US4] 实现私信路由与发件箱 entry/src/main/ets/service/routing/MessageRouter.ets 与 Outbox.ets（mesh 优先路由、tick 2s、发件箱 100 条/peer、24h TTL、8 次重试、握手退避 5/15/30/60s、重连冲刷、加密持久化）— 落位 Outbox（FIFO/100 上限逐出上报/24h TTL/快照 API）+ MessageRouter（RouteResult MESH/NOSTR 预留/QUEUED/DROPPED、直发失败落箱、5/15/30/60s 封顶退避、握手 8 次自动预算、2s 自调度 tick）+ MessageRouterContractTests（移植 Android MessageRouterTest 全语义 + 快照往返/预算上限/调度器）；14/14 全绿
- [x] T035 [P] [US4] 实现私聊持久化 entry/src/main/ets/data/ConversationStore.ets（RelationalStore、载荷 AES-GCM 加密、单 Worker 串行写、保留裁剪、panic 删库）— 落位 ConversationStore（private_conversations.db S1、conversations/private_messages/删除墓碑三表、message_id 去重 upsert、到达序保留 1000/20000/64/256 四级裁剪、回执优先级阶梯 FAILED<SENDING<SENT<PARTIALLY<DELIVERED<READ、async 串行队列即单 Worker 串行写、dropAll panic 抹行+重置序列失败则 deleteRdbStore）+ ConversationPayloadCodec（载荷二进制 TLV 0x01 版本 + 11 标签替代 Android JSON，messageID 内嵌绑定替代逐消息 AAD）+ ConversationPayloadCodecContractTests（全字段往返/null vs 空串/空 mentions 列表/decodeAndVerify 绑定/未知标签跳过/截断/坏版本/编码确定性）；15/15 全绿；数据页 ConversationStore/SecureKeyStore/PreferenceStore 由 harness @kit 检测自动 SKIP
- [x] T036 [US4] 实现私聊视图 entry/src/main/ets/views/PrivateChatView.ets（私聊渲染、回执状态展示、多别名归一入 ConversationListView）— 落位 PrivateChatView（NavDestination 根、系统路由表 router_map name 'privateChat' + @Builder PrivateChatViewBuilder、分组气泡渲染、回执阶梯 发送中/已送达/已读/发送失败/部分送达 依 store 优先级守卫、aboutToDisappear 关闭会话态）+ ConversationListView（会话列表 未读角标/最近消息预览/同日 HH:mm 否则 M月d日、canonicalConversationId 归一）+ ChatViewModel 私聊管线（NoiseSessionManager 设备装配：注入 cryptoFramework Random 临时密钥源 + setTimeout 调度；MessageRouter+Outbox 挂图、onSessionEstablished 注册 Noise 静态键别名并冲刷发件箱、handleNoiseHandshake/Encrypted 实装：XX 喂入/应答、解密分发 PRIVATE_MESSAGE→持久化+发布+DELIVERED 回执、DELIVERED/READ_RECEIPT→状态阶梯、连续 3 次解密失败重置重握手；sendPrivateText 发送路径 SENDING 持久化→路由直发/落箱、入站 byte≤255 校验；openPrivateConversation 载入+标记已读+补发 READ_RECEIPT 去重集）+ EntryAbility 引导链补 ConversationStore.init + ChatPage 三 tab（会话/公共聊天/网络成员）+ PeerNetworkView 行点击 startPrivateChatWithPeer 入口；顺带修 4 处 arkts-limited-throw（NoiseSession/NoiseXXHandshake throw e 归一为 Error 重抛，语义不变）；三闸全绿：harness 15/15、arkts_check 0 错、build SUCCESS

**Checkpoint**: US4 独立可测——M1 全部 P1 主链故事完成

---

## Phase 7: User Story 5 - 去重、限流与垃圾过滤 (Priority: P1) 🎯 M1

**Goal**: 应用层垃圾过滤与泛洪滥用防护（在 SecurityGate 之上补齐应用层准入）
**Independent Test**: 高频/重复消息被过滤，正常消息不受影响

- [x] T037 [P] [US5] 实现垃圾过滤器 entry/src/main/ets/service/mesh/SpamFilter.ets（令牌桶：消息 6/10s、字符 1200/s+20、链接 2/30s+1；回溯 1h；跟踪 1000 发送者/4000 判定；六类判定；可调配置）— 落位 SpamFilter.ets（SpamVerdict 六类判定+spamVerdictIsSpam、TokenBucketConfig/SpamFilterConfig 深比较、SpamTuning toConfig/fromConfig/DEFAULT/equals、LinkCounter lookbehind 正则、RepetitionDetector：NFKD 归一+Mark/Format 码位区间表+lowerPoint 单码位小写+对齐峰值打分（run 3 档/字符不重用）+三元组重合归并游走、TokenBucketSchedule 插入回放+修剪检查点、SpamFilter：LRU 发送者 Map（get 刷新序）+判定缓存（messageId 去重）+flagged≤500+debugBypass 标记不隐藏+isLocalNotice/meshSenderKey/nostrSenderKey 静态；pointAt 收窄 codePointAt undefined 修编译器三错）+ SpamFilterContractTests（移植 Android SpamFilterTest 全部 ~40 用例：六态伪装/洪泛 17 显示/回溯 6-of-10/跨用户第 3 份隐藏/自相似 0.85/REPEATED_CHARACTERS/静态帮助；SeededRandom mulberry32 种子 7 替代 Kotlin Random(7)，FilterHarness 假时钟）；算法先经 scratch 验证器 83/83 对齐再落 ArkTS；三闸全绿：harness 16/16、arkts_check 0 错、build SUCCESS
- [x] T038 [US5] 将 SpamFilter 与载荷限额接入 PacketProcessor 分发链 entry/src/main/ets/service/mesh/PacketProcessor.ets，并接入调试开关偏好 — 落位 PacketProcessor 入口按类型载荷限额（processPacket 先查 PacketPayloadLimits.maxPayloadBytes，超限丢弃计数，不占全局 8MB 预算不进处理器；重组包经 handleReceivedPacket 直入不受入口检查、由 BinaryProtocol 解码侧限额兜底）+ ChatViewModel.handleMessage 垃圾准入（对应 Android IncomingMessageAdmission：isLocalNotice 豁免、!豁免&&shouldHide 拒入时间线与 UI 回调，onPublicPacketSeen 提前无条件执行——隐藏洪泛仍进 gossip 缓存、仍计存活、仍可中继，与 Android 传输层缓存语义一致）+ SpamFilterPreferences.ets（Android SpamFilterPreferences 全量移植：enabled 默认开/debugBypass/11 项 SpamTuning 调参键名 1:1，经 PreferenceStore 持久化，开关切换 reset 清桶，setter 持久化尽力而为失败不阻断活过滤器）+ EntryAbility 启动链 PreferenceStore.init 后接入 SpamFilterPreferences.init；PacketProcessorContractTests 预算测试改用 FILE_TRANSFER（10MB 类型上限）保持全局预算语义 + 新增按类型入口限额断言（超限 MESSAGE/ANNOUNCE/FRAGMENT 丢弃、边界恰好放行、不占预算不达处理器）；三闸全绿：harness 16/16、arkts_check 0 错、build SUCCESS

**Checkpoint**: US5 独立可测

---

## Phase 8: User Story 6 - IRC 命令与基础聊天 UI (Priority: P1) 🎯 M1

**Goal**: 命令体系（含 /hug /slap /w 别名）、自动补全、双主题双 UI 模式
**Independent Test**: `/` 触发补全，`/msg` 等命令全部生效，主题/模式切换即时生效且持久

- [x] T039 [P] [US6] 实现命令处理器 entry/src/main/ets/viewmodel/CommandProcessor.ets（/join /j、/msg /m、/who /w、/clear、/block、/unblock、/channels、/hug、/slap + @提及补全）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - 新增 `viewmodel/CommandProcessor.ets`（纯内核，host-runnable）：`CommandProcessorDelegate` 20 方法接口 + `processCommand` 分发（大小写不敏感；/j //join、/m //msg、/w //who（任务新增别名）、/clear、/block、/unblock、/hug、/slap、/channels、未知命令回退），通知字符串与 Android CommandProcessor.kt 逐字一致；BASE_COMMANDS 9 条（无 /pay //pass）；命令补全（getCommandSuggestions/selectCommandSuggestion）与 @提及补全（getMentionSuggestions/selectMentionSuggestion、isUnannouncedNickname、filterMentionCandidates：trim→滤空→滤未公布 anon→大小写不敏感前缀→去重→排序）。
    - 新增 `viewmodel/CommandSuggestion.ets`（command/aliases/argsHint/description）。
    - `ChatState.ets`：+4 `@Trace` 字段（showCommandSuggestions/commandSuggestions/showMentionSuggestions/mentionSuggestions）。
    - `ChatViewModel.ets`：implements CommandProcessorDelegate；`sendPrivateText` 重构为 `doSendPrivateText`（显式会话发送路径供 /msg //hug //slap）；blockedPeerIds/joinedChannels 内存注册表；handleMessage 与 handleIncomingPrivateMessage 加 blocked 守卫；补全管道 processCommandInput/updateCommandSuggestions/updateMentionSuggestions/selectCommandSuggestion/selectMentionSuggestion/clearSuggestionPopups。getNickname 复用 AnnounceSchedulerDelegate 实现（返回 string，协变满足 string|null 接口）。
    - `PublicChatView.ets` / `PrivateChatView.ets`：发送路径 `/` 前缀路由到 processCommandInput。
    - 新增 `test/contract/CommandProcessorContractTests.ets`（RecordingDelegate 20 方法录制假件；覆盖分发面、/join、/msg、/w //who、/clear 三路路由、/block //unblock、/hug //slap、/channels、未知命令、命令与提及补全），注册为 harness 第 17 套。
    - 修正 2 处测试预期（对齐 Android 真实行为）：/m 带消息每次调用 startPrivateChat（期望 2 非 1）；无 @ 选中提及直接拼接不插空格（'hello@alice '）。
- [x] T040 [US6] 实现输入栏 entry/src/main/ets/components/MessageInput.ets（命令/提及自动补全建议列表）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - 新增 `components/MessageInput.ets`（@ComponentV2，纯展示组件）：TextInput + 发送按钮 + 两个自动补全弹层（命令列表渲染 command+argsHint+description、提及列表渲染 @+nickname，List+constraintSize 上限内滚动、ForEach 以 command/nickname 为 key）。
    - 文本经 V2 `!!` 双向绑定（子 `@Param inputText` + `@Event $inputText`，父 `MessageInput({ inputText: this.inputText!! })`）：子 onChange/选中建议时经 `this.$inputText(...)` 回写父组件；父在发送成功后赋值自身 @Local 即清空输入框。
    - onChange 同时驱动 `updateCommandSuggestions` + `updateMentionSuggestions`（Android ChatScreen 双调用对等）；选中建议 → `selectCommandSuggestion`/`selectMentionSuggestion` 替换文本 + `clearSuggestionPopups()`（内核 select 为纯函数，弹层关闭由组件负责，对齐 Android select* 内清状态的可观察行为）。
    - `PublicChatView.ets` / `PrivateChatView.ets`：删除各自内联 inputBar，改用 MessageInput（placeholder/maxLength/sending/按钮色按上下文传入）；父组件保留 `/` 命令路由与 plain 文本发送，发送成功清空后调用 `clearSuggestionPopups()`（程序化清空不触发 onChange，弹层需显式关闭——Android ChatScreen 同款处理）。
- [x] T041 [P] [US6] 实现消息气泡 entry/src/main/ets/components/MessageBubble.ets（终端式/气泡式双模式分支、发送者分组、链接识别）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - 新增 `components/MessageBubble.ets`（@ComponentV2，纯展示组件，两个聊天面共用行渲染器）：三路分支——bubbles 模式（自己右侧强调色气泡+说话侧小尾角 borderRadius、他人左侧带发送者表头，对齐 Android BubbleTextMessageLayout）、terminal/Matrix 模式（等宽字体扁平左对齐全宽行+时间/发送者表头）、系统通知（居中灰色旁白行，模式无关）。链接识别按 FAQ faqs-arkui-1233 方案二：`splitMessageIntoSegments` 纯函数以 http(s)/www. 正则切分为 plain/link 段（尾随标点 `.,;:!?)]}'"` 剥离回纯文本、退化匹配降级为纯文本、bare host 补 https:// 前缀——Android normalizeMessageUrl 对等），Text 内 ForEach 渲染 Span，链接 Span 着色 #64B5F6 + 下划线 + `.onClick` 经 `UIAbilityContext.openLink(url, { appLinkingOnly: false })` 拉起系统浏览器（Promise.catch + hilog；上下文取自 EntryAbility 新增静态 `uiAbilityContext` 持有器，onCreate 前可空调用）。
    - 发送者分组对齐 Android `MessageGrouping`：窗口从 3 分钟改为 **GROUPING_WINDOW_MS = 5 分钟**（双视图统一）；系统行双向永不分组（`isSystemEntry`：senderPeerId==='' 且 nickname==='system'）；私聊按 isMine+窗口分组不变。
    - `ChatState.ets`：+`@Trace bubblesMode: boolean = true`（默认 Bubbles，Android ChatUiModeManager 对等）；`ChatViewModel.ets`：+`setBubblesMode(bubbles)`（T042 接 PreferenceStore 持久化）。
    - `PublicChatView.ets` / `PrivateChatView.ets`：ChatRow/PrivateRow 携带 showSender(+isSystem) 预计算，messageRow 改用 MessageBubble（公共 #2E7D32 / 私聊 #1565C0 强调色经 mineBackgroundColor 传入）；私聊送达梯队仍由视图在自己气泡下渲染；formatTime/pad2 下沉至 MessageBubble。
    - `EntryAbility.ets`：+静态 `uiAbilityContext: common.UIAbilityContext | null`（onCreate 赋值 this.context，天然 UIAbilityContext 类型无需断言）+ `getUiAbilityContext()` 可空取用。
- [x] T042 [US6] 实现主题与 UI 模式切换 entry/src/main/ets/views/SettingsView.ets（dark/light 资源切换、UI 模式偏好持久化经 PreferenceStore）
- [x] T042 [US6] 实现主题与 UI 模式切换 entry/src/main/ets/views/SettingsView.ets（dark/light 资源切换、UI 模式偏好持久化经 PreferenceStore）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - 新增 `data/SettingsPreferences.ets`：`ThemePreference` 枚举（System/Light/Dark，Android ThemePreference.kt 对等）+ 单例持久化管理器；键名与存储值字符串与 Android 完全一致（`theme_preference`: 'System'/'Light'/'Dark'，`chat_ui_mode`: 'Bubbles'/'Matrix'，Android ChatUiModeManager 默认 Bubbles 对等）；主题经 `ApplicationContext.setColorMode(COLOR_MODE_NOT_SET/LIGHT/DARK)` 即时切换 dark/light 资源限定词（'system' 解除覆盖），applyTheme try/catch 包裹消除告警；chat UI mode 为纯持久化标志（数据层不 import viewmodel，由调用方应用到 ChatState）；全部走 PreferenceStore 门面（D9），panic wipe 一并清除。
    - 新增 `views/SettingsView.ets`（@ComponentV2 + NavDestination，router_map 'settings'，`SettingsViewBuilder`）：两节设置——外观主题（跟随系统/浅色/深色单选行）与聊天界面风格（气泡模式/终端模式单选行，含描述文案）；选中即时生效（主题 setColorMode / UI 模式经 `ChatViewModel.setBubblesMode` 写共享 `@Trace bubblesMode`，两聊天面即时重渲染）+ PreferenceStore 异步持久化（`.catch` + hilog 尽力而为）。
    - `EntryAbility.ets` bootstrap：`SettingsPreferences.init`（PreferenceStore 就绪后、loadContent 前）应用持久化主题并以 `isBubblesMode()` 播种 ChatViewModel 状态。
    - 路由接入：router_map.json + 'settings'；`PublicChatView.ets` 表头新增 `@Param pathStack` + '设置' 入口（`pushPathByName('settings', '')`）；`ChatPage.ets` 传递 pathStack。
    - 范围说明：应用自有颜色仍为固定深色 hex（与 T041 决策一致，peer-stable 色与浅色资源配色后续迭代）；主题切换即时作用于系统组件与 $r 资源的 dark/light 限定词解析。

**Checkpoint**: US6 独立可测

---

## Phase 9: User Story 7 - 紧急擦除 Panic Wipe (Priority: P1) 🎯 M1

**Goal**: 三连击确认后分阶段全量擦除，失败明示 system_panic_incomplete
**Independent Test**: 触发后密钥/会话/收藏/缓存全部不可恢复，应用回到首启态

- [x] T043 [US7] 实现分阶段擦除编排 entry/src/main/ets/service/identity/IdentityManager.ets 的 panicWipe 流程（停服务→清私媒同意→停准入→删会话库→清 UI 状态→清去重/发件箱→清垃圾过滤器→清密钥学数据→清通知→删媒体→清 Nostr/geohash→清收藏/书签→重置昵称 anon<1000-9999>→重建身份，逐阶段确认、失败标记 incomplete）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - `IdentityManager.ets` 新增分阶段擦除编排（Android `performPanicClearAllData` 对等）：`PanicWipeStage`（14 阶段字符串枚举）、`PanicWipeStageResult`/`PanicWipeResult`（stages/completed/criticalFailure/oldPeerId/newPeerId）、`PanicWipeDelegate` 13 方法接口（服务/存储/过滤器侧阶段）、`panicWipe(delegate)` 主流程——逐阶段执行并记录确认（runStage/runAsyncStage 静态辅助：单阶段异常只记失败不中断整体）；阶段 8 清密钥学数据 = `SecureKeyStore.panicWipe()`（Asset 全键 + HUKS 派生键）+ 内存密钥清零 + initialized/initPromise 复位；阶段 14 重建身份 = `initialize()` 生成全新密钥（新 peerID）+ delegate 重启 mesh。
    - 关键语义（Android 对等）：会话库擦除失败 = **criticalFailure**——隐私优先于可用性，不重启 mesh、不重建身份，报告 incomplete；`completed` 要求全部 14 阶段确认（成功消息是安全保证）；单阶段抛异常计为该阶段失败。
    - `ChatViewModel.ets` implements `PanicWipeDelegate`：`panicWipeAllData()` 入口（重入守卫 panicWipeInProgress；完成后以系统通知展示结果——'all data wiped — new identity created' / 'wipe incomplete — some data may remain. triple-tap the logo to try again.'，Android R.string 逐字对等）；停服务=stop() 并确认 graph==null；删会话库=`ConversationStore.dropAll()`（既有 panic 阶段，失败时销毁库文件兜底）；清 UI 状态=ChatState 全字段 + 会话别名/封禁/频道注册表 + `PreferenceStore.clearAll()`（D9 panic 清单：所有偏好一并清除）；清去重/发件箱=timelineIds/sentReadReceipts/Outbox.clearAll()；清垃圾过滤器=`SpamFilter.shared.reset()`；重置昵称=anon<1000-9999>（1000..9998）经 IdentityManager.setNickname 持久化并同步 state；重建身份=panicRestartMesh→start()（幂等 initialize 复用新密钥、重建服务图）。私媒同意/通知/媒体/Nostr/geohash/收藏六阶段为确认式 no-op（对应功能后续阶段落地后填充）。
- [x] T044 [US7] 实现触发与确认 UI entry/src/main/ets/components/CommonDialogs.ets 与 AboutSheet（三连击 logo、确认对话框、结果提示）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - `components/CommonDialogs.ets`（新增）：共享对话框辅助类。`showPanicConfirm(uiContext)` 经 `UIContext.showAlertDialog` 弹出确认对话框（Android ChatScreen showPanicConfirmation 对等；文案 strings.xml 逐字对等：'Wipe all data?' / 'This permanently deletes your identity, keys, messages, and media on this device and creates a new identity. It can't be undone.' / 确认 'Wipe'（DialogButtonStyle.HIGHLIGHT 强调）/ 取消 'Cancel' 置左）；确认后 `runPanicWipe` 调 `ChatViewModel.panicWipeAllData()`（T043 编排），结果经 `showResultToast`（`UIContext.getPromptAction().showToast`，3.5s，try/catch 包裹）以 completed/incomplete 文案提示（与时间线系统通知一致文案）；重入中（返回 null）静默忽略。
    - `views/AboutView.ets`（新增，Android AboutSheet 对等）：router_map 新路由 'about' + `AboutViewBuilder`。Hero 区圆形品牌 logo（三连击触发器，`MULTI_CLICK_THRESHOLD_MS=300` 对等 Android BitChatBrandButton.MultiClickThreshold——tapCount + setTimeout 复位，第 3 击清零并弹确认框，aboutToDisappear 清理定时器）+ bitchat 字标 + 'The sidegroup chat' tagline + v1.0.0；特性区（离线通信/端到端加密/本地频道/无追踪）、使用方法区（昵称/频道/成员/收藏/@提及/命令/三连击提示 共 7 行，Android AboutHowToUseSection 对等翻译）、紧急擦除区（about_emergency_title/about_panic_desc 对等）。
    - `views/SettingsView.ets`（编辑）：新增 '关于 bitchat' 入口行（NavDestination onReady 取 pathStack → pushPathByName('about')）。
    - `resources/base/profile/router_map.json`（编辑）：注册 about 路由。
    - 触发链路：About 页 logo 三连击 → CommonDialogs.showPanicConfirm → 确认 → panicWipeAllData（14 阶段擦除 + 时间线系统通知，T043）→ 结果 toast。

**Checkpoint**: US7 独立可测

---

## Phase 10: User Story 8 - 后台保活与新消息通知 (Priority: P1) 🎯 M1

**Goal**: 长时任务 + 常驻通知维持 mesh，新消息通知跳转会话
**Independent Test**: 熄屏 30 分钟后台在线，peer 发消息收到通知，点击直达会话

- [x] T045 [US8] 实现长时任务与常驻通知 entry/src/main/ets/entryability/EntryAbility.ets（BackgroundTasksKit bluetoothInteraction 长时任务申请、常驻通知显示当前连接数）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - `entryability/BackgroundTaskCoordinator.ets`（新增单例，Android MeshForegroundService 对等）：`start(connectedCount)` 申请 BLUETOOTH_INTERACTION 长时任务（`backgroundTaskManager.startBackgroundRunning(context, BackgroundMode.BLUETOOTH_INTERACTION, wantAgent)`，wantAgent = START_ABILITY 回 EntryAbility、UPDATE_PRESENT_FLAG；starting/running 幂等守卫）+ 发布常驻通知（id=10001 Android NOTIFICATION_ID 对等，SlotType.SERVICE_INFORMATION 无声，内容 'Mesh running — N peers' Android mesh_service_notification_content 逐字对等，additionalText 'The sidegroup chat'，点击经 wantAgent 回应用）；`updateNotification(count)` 连接数变化时同 id 重发更新（lastNotifiedCount 去重）；`stop()` 取消长时任务（stopBackgroundRunning）+ cancel(10001) 通知；publish 失败（通知开关关闭 1600004 等）仅 hilog 降级——长时任务照常运行。EntryAbility.onCreate `init(this.context)` 注入上下文（SettingsPreferences.init 模式），ChatViewModel 直接引用 Coordinator，避免 ChatViewModel↔EntryAbility 循环导入。
    - `module.json5`：requestPermissions 新增 ohos.permission.KEEP_BACKGROUND_RUNNING（normal 级，无需 reason）；EntryAbility backgroundModes: ["bluetoothInteraction"] 已就绪。
    - `ChatViewModel.ets` 挂钩：doStart 成功尾（serviceRunning=true 后）→ start(count)；stop() 尾 → stop()；onPeerConnected/onPeerDisconnected 的 connectedCount 更新后 → updateNotification(count)。panic 擦除经 stop→start 链路自动停/重启长时任务与通知。
- [x] T046 [US8] 实现新消息通知 entry/src/main/ets/common/ 下通知分发器（NotificationKit、私聊/提及优先、want 点击跳转对应会话路由）
  - 实现说明（三闸全绿：harness 17/17 / arkts_check 0 errors / build SUCCESS）：
    - `common/MessageNotificationDispatcher.ets`（新增单例，Android NotificationManager/MeshDelegateHandler 对等）：`notifyPrivateMessage(conversationId, senderNickname, content, isViewingConversation)`——抑制规则 `background || !viewing`（Android 对等），按会话分组（Map<string, PendingMessage[]>，上限 25 条/会话），每会话稳定通知 id（计数器自 100 起）同 id 重发更新，标题 'nickname (N messages)'、正文 'content (+N more)'（单条时为 nickname/content），SlotType.SOCIAL_COMMUNICATION（私聊优先），wantAgent 点击带 want.parameters（notify_route='private'、conversation_id、sender_nickname）；`notifyMeshMention(senderNickname, content, isViewingPublicChat)`——同一抑制规则，单一 id 4000，标题 'Mentioned in Mesh Chat' / 'N mentions in Mesh Chat'（Android notification_mesh_mention_title_singular/_plural 逐字对等），want.parameters notify_route='public'；`clearPrivateNotifications(conversationId)` 打开会话时按 id cancel；`clearMentionNotifications()` 公共聊天可见时 cancel；`clearAll()` panic 擦除全清；`init(context)`（SettingsPreferences.init 模式避免循环导入）、`setAppBackground(bool)`、`handleWant(want)`（冷启动 onCreate + onNewWant 解析 want.parameters Record 存 pendingRoute）、`takePendingRoute()` 一次性取出。
    - `EntryAbility.ets`：onCreate → dispatcher.init(this.context) + handleWant(want)；新增 onNewWant(want) → handleWant；onForeground/onBackground → setAppBackground(false/true)。
    - `ChatViewModel.ets` 挂钩：handleIncomingPrivateMessage 构建消息后 → notifyPrivateMessage（conversationID、message.sender、content、isOpen）；handleMessage 公共入口 appendTimeline 接受且 sender 非本人 → isMentionToMe('@'+nickname 小写 needle + [A-Za-z0-9_] 边界正则 indexOf 扫描，Android checkForMeshMention 手工对等避免 \p{L} 风险) → notifyMeshMention(display, content, publicChatActive)；openPrivateConversation → clearPrivateNotifications(conversationID)；panic 委托阶段 panicClearNotifications() 由 no-op 改为 clearAll() 返回 true；新增 setPublicChatActive(bool) 记录公共聊天 tab 可见性。
    - `pages/ChatPage.ets`：@Local activeTabIndex（原 tabIndex 与内置属性方法冲突改名）+ `Tabs({ index: this.activeTabIndex!! })` 双向绑定 + onChange 回写/上报 setPublicChatActive；onPageShow → takePendingRoute 消费深链——'private' → startPrivateChatWithPeer 后 pushPathByName('privateChat', conversationId)，'public' → activeTabIndex=1 切公共聊天 tab。
    - `views/PublicChatView.ets`：aboutToAppear → clearMentionNotifications()（提及通知随公共聊天可见即退役；私聊侧经 openPrivateConversation 挂钩覆盖）。

**Checkpoint**: M1（一期 MVP）全部用户故事完成

---

## Phase 11: User Story 9 - 频道聊天含密码频道 (Priority: P2) 🎯 M2

**Goal**: 主题频道群聊 + PBKDF2/AES-GCM 密码频道
**Independent Test**: 双机加入同一密码频道互通，无密码第三机只见密文占位

- [x] T047 [P] [US9] 实现频道加密 entry/src/main/ets/service/noise/ChannelEncryption.ets（PBKDF2 100k 迭代/频道名盐 + AES-256-GCM，参数与 Android 端一致）
  - 实现说明（三闸全绿：harness 17/17（本文件 @kit 导入按规则 SKIP）/ arkts_check 0 errors / build SUCCESS）：
    - `service/noise/ChannelEncryption.ets`（新增单例，Android NoiseChannelEncryption/iOS 字节级对等）：`deriveChannelKey` PBKDF2-HmacSHA256（`cryptoFramework.createKdf('PBKDF2|SHA256')` + PBKDF2Spec{password, salt=utf8(频道名), iterations=100000, keySize=32}，generateSecretSync 同步系列）——与 Android PBKDF2WithHmacSHA256/PBEKeySpec 参数逐项一致；`encryptChannelMessage` AES-256-GCM（`createCipher('AES256|GCM|NoPadding')`，12 字节随机 IV `createRandom().generateRandomSync`，aad 空，doFinalSync 输出=密文||tag(16)，线格式 IV(12)||密文||tag(16) 与 Android Cipher AES/GCM/NoPadding 完全一致）；`decryptChannelMessage` 拆 IV/tag/GcmParamsSpec{authTag=末 16 字节} 解密，认证失败/短数据/无 key 返回 null；`calculateKeyCommitment` SHA-256(key) 小写 hex（createMd updateSync/digestSync，ByteUtils.bytesToHex）、`verifyKeyCommitment` 大小写不敏感；`setChannelPassword/removeChannelPassword/hasChannelKey/getChannelPassword/getActiveChannels/clear`（panic）Android 对等 API。
    - 全同步 cryptoFramework 系列（convertKeySync/initSync/doFinalSync，IdentityManager verifySync 先例），同步 mesh 管线不阻塞 UI 线程；失败 null/false 不抛异常。
- [x] T048 [US9] 实现频道管理 entry/src/main/ets/service/mesh/ 下的频道逻辑模块（创建/加入/成员列表/密码门控，/join /channels 联动 CommandProcessor）
  - 实现说明（三闸全绿：harness 18/18（新增 ChannelManagerContractTests）/ arkts_check 0 errors / build SUCCESS）：
    - `service/mesh/ChannelManager.ets`（新增，纯 ArkTS 无 @kit 导入，host 可测；Android ChannelManager/DataManager 对等）：`ChannelJoinResult` 枚举（JOINED/NEEDS_PASSWORD/WRONG_PASSWORD/INVALID_NAME）+ `ChannelCrypto` 接口（setChannelPassword/hasChannelKey/removeChannelPassword，由 T047 ChannelEncryption 实现——签名逐项一致仅加 implements）；注册表四表：joinedChannels/passwordProtectedChannels/channelMembers（Map<string,Set>）/channelCreators（Android addChannelCreator 对等）；`normalizeChannelName`（trim + '#' 前缀）；`createChannel`（密码非空 → 标记保护 + 立即派生 key + 记录 creator + join）、`joinChannel`（密码门控：已加入但保护未派生 → 需密码；未加入保护未派生 → NEEDS_PASSWORD/派生失败 WRONG_PASSWORD/成功派生 JOINED；普通频道首加入者成为 creator——Android 对等；WRONG_PASSWORD 语义 = 派生失败，Android verify TODO 恒 true 对等：错误但可派生的密码照常加入、解密时只见密文占位）、`leaveChannel`（成员/creator/key 全清，保护标记保留）、成员 API（addChannelMember/removeChannelMember/isChannelMember/getChannelMembers 排序输出/cleanupDisconnectedMembers 保留 self+在线）、`clearAllChannels`（panic：先经 crypto 清 key 再清四表）。
    - `service/noise/ChannelEncryption.ets`：+`implements ChannelCrypto`（接口方法签名 T047 已一致，零逻辑改动）。
    - `viewmodel/ChatState.ets`：+@Trace currentChannel（''=主时间线）/passwordPromptChannel/showPasswordPrompt（T049 对话框绑定）。
    - `viewmodel/ChatViewModel.ets`：移除 T039 占位 joinedChannels Set，改持有 `ChannelManager(ChannelEncryption.getInstance())`；joinChannel 委托 → JOINED 置 currentChannel、NEEDS_PASSWORD/WRONG_PASSWORD 置提示状态返回 false、getJoinedChannels/getCurrentChannel 改读注册表与 state；panicClearUiState → channelManager.clearAllChannels() + 频道 state 复位；clearChannelMessages 留 T049（频道时间线）。/join /channels 经 CommandProcessor delegate 已联动。
    - `entry/src/test/contract/ChannelManagerContractTests.ets`（新增）：normalize/生命周期/幂等重进/排序/非法名/密码门控三态/派生失败拒绝/leave 清理/成员增删/cleanup/panic 全清，stub ChannelCrypto 注入；harness 注册第 18 套件 + ChannelCrypto 加入 import-type 重写名单。
- [x] T049 [US9] 实现频道视图 entry/src/main/ets/views/ChannelChatView.ets 与密码输入对话框（PasswordPromptDialog 于 CommonDialogs.ets）
  - 实现说明（三闸全绿：harness 18/18 / arkts_check 0 errors / build SUCCESS）：
    - `views/ChannelChatView.ets`（新增，router_map 名 'channelChat'）：NavDestination 频道页，aboutToAppear 捕获 viewingChannel（挂载时 currentChannel 快照，覆盖叠加不清误清），渲染 `ChatState.channelMessages` 按频道时间线（ChannelRow 分组 = MessageGrouping 5 分钟窗口），MessageInput 复用（`!!` 双绑，/命令仍走 CommandProcessor），Leave 走 `.menus()`（NavigationMenuItem）→ ChatViewModel.leaveChannel + pathStack.pop（onReady 取 ctx.pathStack）；aboutToDisappear 仅在 currentChannel===viewingChannel 时 closeChannelView（返回保留成员籍，Android 对等）。
    - `components/CommonDialogs.ets`：+`PasswordPromptDialogParams`（channel + onJoin/onCancel 回调）+ `@Builder PasswordPromptDialogBuilder`（wrapBuilder 用）+ `@ComponentV2 PasswordPromptDialogContent`（@Param 参数对象、@Local 密码输入、InputType.Password、Join 按钮 trim 非空才启用）；字符串逐字 Android parity：'Enter Channel Password' / 'Channel %s is password protected. Enter the password to join.' / 'Password' / 'Join' / 'Cancel'。
    - `pages/ChatPage.ets`（对话框宿主，@ComponentV2 不能用 CustomDialogController → ComponentContent+promptAction 方案）：`@Monitor('chatState.showPasswordPrompt')` 开/关；`openPasswordDialog` = `new ComponentContent<Params>(ui, wrapBuilder(builder), params)` + `getPromptAction().openCustomDialog(content, { autoCancel, alignment: Center, onDidDisappear→dismissPasswordPrompt })`；`closePasswordDialog` = closeCustomDialog(content)；Join 回调 = joinChannel(提示频道, 密码) 后无条件关框（Android 无论成败都关，错密码只留公共时间线 notice），Cancel/点外 = dismissPasswordPrompt。
    - `viewmodel/ChatState.ets`：+@Trace `channelMessages: Map<string, ChatEntry[]>`（V2 @Trace Map，set/delete 即刷新）。
    - `viewmodel/ChatViewModel.ets`：+`sendChannelMessage(content, channel)`（普通频道：BitchatMessage.channel='#tag' flag 0x40，签名+广播复用 sendPublicMessage 管线；保护频道：ChannelEncryption.encryptChannelMessage → isEncrypted flag 0x80 + encryptedContent 上线，本地时间线存明文）；handleMessage 守卫放宽（isEncrypted && channel===null 才拒），spam 检查后 channel!==null 分支 → `handleIncomingChannelMessage`（解密成功→明文，失败/无 key→'[encrypted message]' 占位；按 packet-ID 每频道去重 `appendChannelTimeline`（容量 1000 修剪）+ channelManager.addChannelMember）；+`leaveChannel`（注册表 leave + currentChannel 复位，时间线保留重进可恢复）、`closeChannelView`（返回仅清 currentChannel 保留成员籍）、`dismissPasswordPrompt`；`clearChannelMessages` 落地（/clear 联动 getCurrentChannel）；panicClearUiState + channelMessages/channelTimelineIds 复位。
    - `views/PublicChatView.ets`：+`@Monitor('chatState.currentChannel')` 非空 → pushPathByName('channelChat', tag)，清空不推（返回/离开不误推）。
    - `resources/base/profile/router_map.json`：+channelChat 路由项（buildFunction 'ChannelChatViewBuilder'）。

**Checkpoint**: US9 独立可测

---

## Phase 12: User Story 10 - 私有媒体 v1：图片/文件/语音 (Priority: P2) 🎯 M2

**Goal**: 文件 TLV 经 Noise 端到端加密（0x11+0x20）分片传输，PEER_STATE 能力钉扎，旧客户端回退 0x22 明示
**Independent Test**: 鸿蒙与 Android 双机互发图片与语音消息，加密传输、进度、落盘、回放全链路可用

- [x] T050 [P] [US10] 实现媒体文件存取 entry/src/main/ets/data/MediaFileStore.ets（沙箱私有目录、配额、EXIF 朝向处理、会话清理）
  - 实现说明（三闸全绿：harness 18/18 / arkts_check 0 errors / build SUCCESS）：
    - `data/MediaFileStore.ets`（新增，单例，@kit 文件 harness SKIP）：init(context) 捕获 filesDir/cacheDir 双沙箱根；saveIncomingFile(fileName, fileSize, mimeType, content)（FileUtils.kt saveIncomingFile 对等 + #592 cacheDir 防御）：mimeType image→images/ 其余 files/，incoming 子目录；文件名清洗 `[^A-Za-z0-9._-]`→'_'，重名 'name (1).ext' 去重 ≤1000 次，mkdirSync(recursion) 失败逐级回退到沙箱根，openSync(READ_WRITE|CREATE|TRUNC)+writeSync 全异常吞并返回 null（仅告警 hilog）。
    - downscaleImageForSending(sourcePath)（ImageUtils.kt downscaleAndSaveToAppFiles 对等）：image kit createImageSource → getImagePropertySync(PropertyKey.ORIENTATION) 读 EXIF → DecodingOptions.rotate 按度烘焙（3→180/5,6→90/7,8→270）→ pixelMap.scale 压到 ≤512 → createImagePacker packToData('image/jpeg', 85) → filesDir/images/outgoing/img_<ts>.jpg；source/pixelMap/packer 全 release。
    - isWithinTransferQuota 复用 ProtocolConstants.ets MediaConstants.MAX_FILE_SIZE_BYTES（10MB−132KB=10,350,592B）；clearAllMedia（filesDir/cacheDir 全子目录 rmdirSync + cacheDir 根 catch-all 清空 + 重建子目录）；deleteConversationMedia(deleted, retained)/deleteStoredMediaPaths(paths)（FileUtils.kt canonicalFile 对等）：normalizeAbsolutePath 手动 '.'/'..' 归一（fs 无 realpathSync）+ 沙箱根包含检查（isInsideSandboxRoots）防路径逃逸；静态 formatFileSize/messageTypeForMime/exifOrientationToDegrees。
    - `entryability/EntryAbility.ets`：bootstrap 串接 MediaFileStore.getInstance().init(this.context)（SettingsPreferences 之后）。
    - `viewmodel/ChatViewModel.ets`：panicDeleteMedia 占位落地 → MediaFileStore.clearAllMedia()（panic 清单第 15 阶段实装）。
- [x] T051 [P] [US10] 实现 peer 能力状态管理 entry/src/main/ets/service/mesh/PeerStateManager.ets（PEER_STATE 载荷 0x21：version+能力 TLV+Ed25519 TLV、5s 代际看门狗、HSTS 式钉扎）
  - 实现说明（三闸全绿：harness 19/19（新第 19 套件 PeerStateManagerContractTests）/ arkts_check 0 errors / build SUCCESS）：
    - `model/IdentityModels.ets`：+`AuthenticatedPeerState`（Android AuthenticatedPeerState.kt 对等，0x21 载荷编解码）：`[version=0x01][TLV 0x01 len 1..8 最小 LE capabilities][TLV 0x02 len 32 Ed25519]`；未知 TLV 跳过、两已知字段各恰一次、capabilities 非最小编码拒绝（decoded.encoded() 逐字节回验）、字段顺序无关；金样 `[01 01 02 00 01 02 20]+key`。
    - `service/mesh/PeerStateManager.ets`（新增，纯 ArkTS 无 @kit，Android AuthenticatedPeerStateCoordinator 对等）：注入式依赖（PeerStateManagerDeps：authenticatedSessionProvider/withAuthenticatedSession/store/localStateProvider/applyAuthenticatedState/sendState/onResolution/proofTimeoutMs/schedule/cancel）——看门狗调度器与 Noise 代际提供者均注入，宿主测试用假调度器同步驱动，设备侧后续任务接线（真 NoiseSessionManager + setTimeout/clearTimeout）。
      - 代际交换：每个已认证 Noise 代际（remoteStatic+handshakeHash token）独立 0x21 交换；每代际发一次本地状态，首个有效证明 echo 恰一次；同代际重复等值证明幂等、异值证明拒绝（首证不可替换）；代际切换（rekey/加密交换）自动采纳新 token 为 AWAITING，旧代际证明拒绝；迟到的旧代际回调/快照被 live-session 校验丢弃。
      - 5s 代际看门狗（PROOF_TIMEOUT_MS=5000）：status() 读取不重置不重排；超时置 TIMED_OUT + onResolution；不信任持久化的先前状态。
      - HSTS 式钉扎（PeerStateStore 接口：load/persist(fingerprint, state, onCommitted)/isPrivateMediaPinned）：fingerprint = SHA-256(staticKey) hex；证明先 persist 后 publish（onCommitted 内 applyAuthenticatedState，持久化纪元锁语义——失败持久化绝不发布内存态，防 copied-static 首播毒化重启复开）；公告永不能创建/刷新 pin；isPrivateMediaPinned 经 live 代际 static key 查询持久 pin。
      - API：onSessionAuthenticated/receive/status（PeerStateStatus MISSING/AWAITING/TIMED_OUT/PROVEN）/provenState/persistedSigningKeyFor/isPrivateMediaPinned/clear/static fingerprint。
    - `entry/src/test/contract/PeerStateManagerContractTests.ets`（新增）：0x21 编解码金样（canonical bytes/乱序+未知 TLV/11 组非法拒收/0x21 NoisePayload 包装）+ 协调器语义（每代际发一次+echo 恰一次/重复幂等/异值拒绝/代际切换采纳/看门狗 20ms 假调度触发+读取不重置/忽略持久旧态/迟到达旧回调不覆盖/copy-static 毒化防护（apply 携带认证 static key+证明 Ed key）/持久化失败不发布/陈旧 lease 拒绝/clear）；MemoryPeerStateStore+FakeScheduler 桩。
    - harness：run-contract-tests.mjs +import/tests 数组第 19 套件 + 重写正则加 PeerStateStore|PeerStateManagerDeps。
- [x] T052 [US10] 实现私有媒体传输 entry/src/main/ets/service/media/MediaTransferManager.ets（文件 TLV 0x01-0x04 编解码、整包 Noise 载荷 0x20 加密后经 FragmentManager 分片 ≤256 片、绝不广播、上限 10,350,592B、显式接受意图 15s、回退签名裸 FILE_TRANSFER 0x22 且 UI 明示非加密、传输进度事件）
  - 纯 ArkTS（无 @kit）注入式实现：PrivateMediaWireMode（ENCRYPTED_NOISE_0X20/SIGNED_DIRECTED_RAW_0X22）；PreparedPrivateMediaTransfer 单次 commit（含失败后不可重试）；PrivateMediaPolicyDecision 五态（Encrypted/RequiresLegacyConsent/NeedsHandshake/AwaitingPeerState/Blocked(reason)）；PrivateMediaSecurityController.sendPolicy（PeerStateManager PeerStateStatus 绑定 + HSTS pin 语义：PROVEN 无能力且已 pin → Blocked、TIMED_OUT 已 pin → Blocked、MISSING 视作等待而非超时）；PrivateMediaTransferPreparer（先 120,064B=256×469 绝对上限再 policy；加密路径 NoisePayload(0x20, fileTLV) → 注入 encrypt（GenerationChanged 重试一次→仍变则 AwaitingPeerState）→ version 1/2 NOISE_ENCRYPTED 定向包；legacy 路径 version 2 FILE_TRANSFER 明文 TLV；finalize 失败/签名非 64 字节 → Rejected；fragment 空或 >256 → Rejected；Ready 携带 BuiltPrivateMediaTransfer + 单次 commit 闭包）；TransferProgressEvent/Manager（start/progress/complete/fail，监听器异常隔离）；PrivateMediaSendIntentManager（MediaSendingManager 状态机移植：单 pending 槽、NeedsHandshake/AwaitingPeerState 保留首发意图 + 15s 超时唯一调度、consent 恰一次消费、approve 升级加密路径、策略变更中途 abort、evaluate 重入 rerun 循环防递归）。
  - `entry/src/test/contract/MediaTransferContractTests.ets`（新增第 20 套件）：进度事件/单次 commit 语义/安全策略矩阵（无会话、短 key/token、AWAITING/MISSING/PROVEN±能力±pin/TIMED_OUT±pin 精确 reason）/加密路径（NOISE_ENCRYPTED、version 1/2、定向非广播、噪声包装明文等于 NoisePayload(0x20,encode)、代际变更重试一次、持续变更 AwaitingPeerState、encrypt 抛异常、120,065B 超限先于 policy、TLV 编码失败、未签名/63 字节签名拒绝、空/>256 分片拒绝、commit 恰一次）/legacy 路径（FILE_TRANSFER v2 明文 TLV 定向签名、无 consent 精确警告、未签名拒绝）/直通（NeedsHandshake/AwaitingPeerState/Blocked reason）/意图状态机（15s 超时消息、过期意图不重试、consent 流程（错误 id 无操作、正确 id 恰一次、approve 开 fallback）、8 字符 peer 前缀昵称回退、cancel 后 approve 无操作、消费后仍需 consent → policy changed 消息、单 pending 槽消息、Rejected 释放槽位、prepare 抛异常→'mesh exploded'、重入 rerun 一次、clear 全清）；MediaFakeScheduler/PreparerRig/SecurityRig/IntentRig 桩。
  - harness：run-contract-tests.mjs +import/tests 数组第 20 套件 + 重写正则加 PrivateMediaSecurityDeps|PrivateMediaTransferPreparerDeps|PrivateMediaSendIntentDeps；三闸全绿（20/20、arkts_check 0 错误、build SUCCESS）。
  - BitchatFilePacket TLV 编解码复用 T0xx 已有 model/FragmentModels.ets（含 WireContractTests 金样）；UI 级 10,350,592B 预检沿用 MediaFileStore.isWithinTransferQuota；设备侧接线（BleMeshService 注入 encrypt/finalize/fragment/commit、ChatViewModel onReady 本地回显）留待 T053。
- [x] T053 [P] [US10] 实现媒体气泡 entry/src/main/ets/components/MediaBubble.ets（图片/文件/语音三种气泡、全屏查看器、接收确认交互、进度展示、回退"非端到端加密"提示）
  - MediaBubble.ets（@ComponentV2，双模式 bubble/terminal）：图片 200×150 file:// 缩略图 + bindContentCover 全屏 Swiper 查看器（counter/onChange/关闭）；文件徽章卡 + bindContentCover 信息面板（名称/大小/路径 + DocumentViewPicker.save 保存）；语音圆钮占位（T054 播放器）；进度 Linear Progress + percent/发送失败；'非端到端加密 · 明文回退发送' 琥珀标签。
  - ChatViewModel 接线（MeshGraph +5 服务：peerStateManager/mediaSecurity/mediaPreparer/mediaIntents/mediaProgress，doStart 于 noiseSessions 后构造，onSessionEstablished → onSessionAuthenticated）：sendPrivateMediaFromPicker（picker 读取 → 10,350,592B 预检 → 图片 stageTempFile+downscaleImageForSending / 文件 saveOutgoingFile → BitchatFilePacket → sha256Hex transferId → submitPrivateMedia → syncConsentPrompt）；dispatchPrivateMediaFragments（recipientId null 拒绝广播回退，progress start/progress/complete/fail）；commitPrivateMediaEcho（commit 优先 → SENT/FAILED 本地回显 + transferId + wireMode==0x22 时 notEndToEndEncrypted）；addPrivateSystemMessage（策略/超时/consent 行持久化+发布）；handleNoiseEncrypted 切 decryptWithSession + 0x20 FILE_TRANSFER→publishIncomingPrivateMedia（120,064B 先检后存 + DELIVERED/READ 回执 + '[图片]/[文件]/[语音]' 通知）+ 0x21 PEER_STATE→peerStateManager.receive；handleMessage 0x22 早分派（SecurityGate 已验签）→ legacy 接收（无回执）；applyDeliveryTransition 拷贝 messageType/transferId/notEndToEndEncrypted；stop() 清 consent/progress；panicDeleteMedia 同步清 PeerStatePinStore（两清不短路）。
  - ChatState：PrivateMessageEntry +messageType/transferId/notEndToEndEncrypted（带默认值，旧调用兼容）；MediaTransferProgress + LegacyConsentPrompt 类；@Trace mediaProgress Map + pendingLegacyConsent。
  - BitchatMessage +notEndToEndEncrypted/transferId（非序列化）；ConversationPayloadCodec 前向兼容 TLV 0x0C/0x0D/0x0E（未知 tag 跳过，旧行兼容）；ConversationStore encodePayload/payloadToMessage 透传。
  - MediaFileStore：saveOutgoingFile（filesDir/files/outgoing 去重命名）、stageTempFile/deleteTempFile（cacheDir/staging 入 panic 清扫）。
  - IdentityManager.signSync（Ed25519 convertKeySync→initSync→signSync）；PeerStatePinStore（EntryAbility init + panic 接线）。
  - PrivateChatView：媒体行分派（MESSAGE→MessageBubble，媒体→MediaBubble 绑 progress/imagePaths/imageIndex，系统行居中灰字）、图片/文件 picker（PhotoViewPicker/DocumentViewPicker→sendPrivateMediaFromPicker）、bindContentCover legacy consent（仍要发送/取消 → approveLegacyMediaConsent/cancelLegacyMediaConsent）。
  - 三闸全绿（harness 20/20、arkts_check 0 错误、build SUCCESS）。
- [x] T054 [US10] 实现语音消息录制与播放（AudioCapturer/AVPlayer 接入 service/media/ 语音模块 + 波形渲染于 MediaBubble.ets）
  - SDK 核验（T054 前置）：SDK 无音频解码器、AVRecorder 无振幅 API → 录音改走 AudioCapturer（8kHz 单声道 S16LE PCM 累积 → 停止时 G.711 μ-law 编码写 WAV format tag 7、8,000 B/s，10s ≈ 80KB ≤ 120,064B 接收上限）；播放 AVPlayer（'fd://'+fd、stateChange initialized→prepare→prepared→play、completed 自动 release、timeUpdate 进度）。
  - VoiceNoteWaveform.ets（纯 ArkTS 无 @kit，host 可跑）：mulawEncode/mulawDecode（bias-132 16-bit 约定 = 通用 g711.c ulaw2linear 表的精确逆；[260<<s,264<<s) 网格间隙步进 s+1 并钳位，编码 0=0xFF/32767=0x80/−32768=0x00，解码 0xFF=0/0x00=−32124/0x80=+32124/0x7F=0，往返误差 ≤1024）；buildMulawWav（44B RIFF 头）；parseWavInfo/WavInfo（chunk 步进解析，未知 chunk 按尺寸跳过+奇数补位，durationMs）；parseMulawWavWaveform（逐字节解码→峰值分桶→max 归一，非 format-7/空数据 → null）；normalizeAmplitudeSample（ln(1+a)/ln(1+32768) Waveform.kt 对齐）；resampleWave（线性插值）；VOICE_NOTE_SAMPLE_RATE=8000、WAVEFORM_BINS=120。
  - VoiceNoteRecorder.ets：start()（createAudioCapturer 8k/S16LE/CHANNEL_1/SOURCE_TYPE_MIC、on('readData') 峰值振幅+PCM 累积、MAX_CAPTURE_SAMPLES=80000）、stop(canceled)（off→stop→release→μ-law 编码写 filesDir/voicenotes/outgoing/voice_<ts>.wav）、pollAmplitude()。
  - VoiceNotePlayer.ets：单例共享 AVPlayer（一次一条）、VoiceNotePlaybackListener（onVoiceNoteProgress/onVoiceNoteFinished/onVoiceNoteError）、play/pause/resume/seekFraction/release、fd 持有至 release。
  - VoiceNoteWaveformContractTests.ets（第 21 套件）：μ-law 金样（含 bias-132 网格间隙 −8192 用例）、WAV 头布局（10s ≤120,064B）、chunk 步进解析（LIST 跳过+奇数补位+非 WAV 拒绝）、波形提取（静/响分桶归一、稀疏命中、format 1/非 WAV/空数据/0 桶拒绝）、振幅归一、重采样（空/恒等/扩展/收缩/钳位/120 桶）。
  - ChatState：VoicePlaybackState 类 + @Trace voiceRecording/voiceRecordingElapsedMs/voiceRecordingAmplitude/voiceRecordingWaveform/voicePlayback。
  - ChatViewModel（implements VoiceNotePlaybackListener，构造器 setListener）：startVoiceRecording（80ms setInterval 轮询 normalizeAmplitudeSample→resampleWave 32 条实时条形，10,000ms 自动停止发送）、stopVoiceRecordingAndSend（→ sendVoiceNoteFile → submitPrivateMediaFile('audio/wav') 复用 T053 全管线）、cancelVoiceRecording、toggleVoiceNotePlayback（同路径 pause/resume，异路径 play 替换）、seekVoiceNote、getVoiceWaveform（120 桶缓存 Map）、getVoiceNoteDurationMs（.wav 按 (size−44)/8 推导，播放后取 AVPlayer）；onVoiceNoteProgress/Finished/Error 镜像 state；teardownVoiceNotes 于 stop() 与 panicDeleteMedia()（取消录制+停播+清波形缓存）。
  - MediaBubble：audioContent 重做——播放/暂停圆钮（三角/双竖条）+40 条波形（resampleWave→AudioBar heightVp+played，ForEach 键含 tint 值、未播 #64748B/已播 #64B5F6）+点击 ClickEvent.x/198 seek+时长文本；'语音不可用' 降级；新 @Param waveform/isPlaying/playbackFraction/durationText + @Event onTogglePlay/onSeekWaveform。
  - PrivateChatView：语音 按钮（abilityAccessCtrl.createAtManager().requestPermissionsFromUser(getContext(this), ['ohos.permission.MICROPHONE'])，authResults==0 才录）、录制条（红点+mm:ss+实时红条 ForEach（键含值）+取消/发送，voiceRecording 时替换附件栏）、MediaBubble 音频参数接线（audioWaveformOf/audioPlayingOf/audioFractionOf/audioDurationTextOf）。
  - 三闸全绿（harness 21/21、arkts_check 0 错误、build SUCCESS）。

**Checkpoint**: US10 独立可测

---

## Phase 13: User Story 11 - 收藏好友与 QR 身份验证 (Priority: P2) 🎯 M2

**Goal**: 收藏关系持久化 + 面对面 QR 验证（Ed25519 挑战/响应）
**Independent Test**: 双机互加收藏 + 互扫 QR，双方出现已验证标记且跨会话保持

- [x] T055 [P] [US11] 实现收藏持久化 entry/src/main/ets/data/FavoritesStore.ets（peerID↔NoiseKeyHex↔npub 映射、加密 JSON、panic 清单联动）
  - ContactIdentityResolver.ets（纯 ArkTS）：isMeshPeerId/isNoiseKeyHex/isNostrAlias、noiseKeyHex 小写、fingerprintHex=sha256Hex、contact_ 会话 ID 判定/解析、peerIdForNoiseKey(-Hex)=指纹前 16、bytesFromHex 严格校验、nostrPubkeyHex（npub/64-hex 归一）、npubFromHex（Bech32）、nostrAliasForPubkey('nostr_'+hex16）。
  - FavoriteModels.ets（纯 ArkTS）：FavoriteRelationship（withPeerFavoritedUs：null→裸 received-only 'Unknown'、existing→保留我方字段仅刷新 theyFavoritedUs/lastUpdated；isMutual；equals）、FavoriteRelationshipData、FavoriteRelationshipCodec（toJson 小写键/fromJson 跳过坏条目）、FavoriteControlMessage.parse/encode '[FAVORITED]:npub'/'[UNFAVORITED]:npub'（npub 经 nostrPubkeyHex 归一，无效→null）。
  - FavoritesStore.ets（@kit 单例）：SecureKeyStore HUKS AES-GCM 双文档 filesDir/favorites/relationships.aead + peerid_index.aead；updateFavorite/unfavorite/setPeerFavoritedUs/updateNostrPublicKey(+ForPeerID)/isFavorite/getFavorite/getAll/findByPeerID/clearAllFavorites；FavoritesChangeListener(onFavoriteChanged/onAllCleared)；EntryAbility 构造器 init(context)。
- [x] T056 [P] [US11] 实现 QR 验证服务 entry/src/main/ets/service/identity/VerificationService.ets（ScanKit 扫码/生成码、bitchat://verify 深链、上下文 bitchat-verify-v1/-resp-v1、nonce 16B、容差 300s、QR 缓存 60s）
  - 纯 ArkTS（签名/验签/随机注入 VerificationSigner/SignatureVerifier/NonceFactory）：VerificationQR canonicalBytes（255 截断长度前缀）/toUrlString（percent-编码、npub 省略）/fromUrlString（严格解析、first-occurrence-wins、非整数 v/ts 拒绝；修复 v→noise 字段错位 bug）；buildMyQRString（60s 静态缓存、昵称/npub 变化失效）+clearQrCache；verifyScannedQR（双向 300s 容差）；buildVerifyChallenge TLV [01][02]/buildVerifyResponse [01][02][03]（签名覆盖 [RESPONSE_CONTEXT][len][noise][nonceA raw]）/parse/verifyResponseSignature；verificationTimestampSkewSeconds（饱和 MAX_SAFE_INTEGER）。
  - ChatViewModel 接线：handleNoiseEncrypted 分发 VERIFY_CHALLENGE 0x10/VERIFY_RESPONSE 0x11；handleIncomingPrivateMessage 在 persist/ack/display 前拦截 FavoriteControlMessage；onSessionEstablished 冲刷 pendingQrIntents；收藏通知仅走已建立会话的 sendPrivateMessage；panic 清收藏+QR 缓存+pending；verified_fingerprints PreferenceStore 持久化；FavoritesChangeListener 镜像到 ChatState 4 个 @Trace Set/字段。
- [x] T057 [US11] 实现用户操作单与验证状态 UI entry/src/main/ets/components/ 下 ChatUserSheet（收藏/屏蔽/验证入口、已验证标记）
  - ChatUserSheet.ets（@ComponentV2）：@Param conversationId + @Event onClose/onRequestVerification/@Local blocked 镜像；@Computed peerName/favorited/peerFavoritedUs/verified/fingerprintText；收藏/屏蔽/身份验证 action 行 + 状态提示（相互收藏/已收藏/对方收藏了你/已验证 chip）。
  - VerificationSheet.ets（@ComponentV2）：generateBarcode.createBarcode QR 码 480px PixelMap + scanBarcode.startScanForResult 扫码（取消码 1000500002 静默）→ beginQRVerification；状态文案/颜色方法；取消验证→unverifyConversation。
  - PrivateChatView.ets：peerHeaderBar（名字+已验证 chip+'›' 入口）→ NavDestination 单 bindContentCover identitySheetBuilder if/else 切换 VerificationSheet/ChatUserSheet。
  - 三闸全绿（harness 22/22（新增 VerificationContractTests 第 22 套：resolver/favorites/codec/control-message/skew/canonical golden/URL/cache/freshness/TLV golden）、arkts_check 0 错误、build SUCCESS）。

**Checkpoint**: US11 独立可测

---

## Phase 14: User Story 12 - Nostr 互联网私信 (Priority: P2) 🎯 M2

**Goal**: 互收藏双方 mesh 不可达时经 Nostr 中继投递私信（信封格式与现有客户端互通）
**Independent Test**: 双机不在蓝牙范围（均有网）经 Nostr 互发收达；与 Android 端经 Nostr 互通

- [x] T058 [P] [US12] 实现 Nostr 协议层 entry/src/main/ets/service/nostr/NostrProtocol.ets（Bech32 严格校验、secp256k1 签名/ECDH、HKDF-SHA256、kind 13/14/1059 信封、v2: 前缀 XChaCha20-Poly1305、时间戳随机化 ±15min、gift wrap 回看 48h/presence 1h、中继目录 CSV raw 资产、默认中继 4 个，通过契约向量）
- [x] T059 [P] [US12] 实现中继客户端 entry/src/main/ets/service/nostr/NostrRelayManager.ets（@ohos.net.webSocket 多中继、退避 1s→300s ×2 最多 10 次、ACK 350ms、去重 10,000、订阅校验 30s、订阅恢复）
- [x] T060 [US12] 扩展私信路由 entry/src/main/ets/service/routing/MessageRouter.ets（mesh→Nostr→发件箱三级决策，收藏变化冲刷发件箱）并接入 ChatViewModel 私聊链路

**Checkpoint**: US12 独立可测

---

## Phase 15: User Story 17 - Courier 信使系统 (Priority: P2) 🎯 M2

**Goal**: Noise X 密封信封 + 信使携带投递 + spray-and-wait + Store-Forward 缓存补发
**Independent Test**: 三机 A-C-B 场景，A 发给 B 的私信经信使 C 携带最终送达 B

- [x] T061 [P] [US17] 实现信使模型 entry/src/main/ets/model/CourierModels.ets（CourierEnvelope/StoreForwardEntry/轮换标签模型，字段对齐 plan.md Data Model）
- [x] T062 [P] [US17] 实现 Noise X 密封 entry/src/main/ets/service/noise/NoiseXSeal.ets（X 模式单向密封、发送方身份密文内认证，通过 Noise 外部向量）
- [x] T063 [US17] 实现信使管理器 entry/src/main/ets/service/mesh/CourierManager.ets（信封池 40 槽/20 可用、配额互收藏 5/验签 2、16B 轮换标签 HMAC+UTC 日、spray 预算 4→8、handover：直接公告→链路投递移除/中继公告→定向洪泛副本 10min 节流、存款重试至 3 信使、≤16KiB/24h、溢出逐出最旧已验证层、携带邮件/预算/喷洒历史加密持久化、屏蔽发件人解密丢弃）
- [x] T064 [P] [US17] 实现 Store-Forward 缓存 entry/src/main/ets/service/mesh/StoreForwardManager.ets（缓存 12h、普通 100 条/收藏 1000 条、10min 清理、上线按序补发间隔 10ms、不缓存握手/公告/广播）
- [x] T065 [US17] 集成信使路由 entry/src/main/ets/service/routing/MessageRouter.ets（mesh→Nostr→Courier→Outbox 四级决策、新合格信使连接触发存款重试）与 EventBus 事件接线（courier-deposited/delivered）

**Checkpoint**: M2（二期）全部用户故事完成

---

## Phase 16: User Story 13 - geohash 位置频道 (Priority: P3) 🎯 M3

**Goal**: 3D 地球仪选择地理频道（六级），Nostr g/n 标签广播，geohash 派生临时身份
**Independent Test**: 双机加入同一城市级频道互见消息，频道内身份与 mesh peer ID 隔离

- [x] T066 [P] [US13] 实现 geohash 服务 entry/src/main/ets/service/nostr/GeohashService.ets（geohash 编解码、六级 LEVEL、派生身份、g/n 标签事件、presence kind 20001 回看 1h、PoW NIP-13 难度 12 默认关闭）
- [x] T067 [US13] 实现地球仪选择页 entry/src/main/ets/pages/GeohashPickerPage.ets（Canvas 地球渲染、飞行动画、geohash 网格点选、书签）
- [x] T068 [US13] 接入位置频道 UI entry/src/main/ets/views/ 下位置频道会话视图与公共入口（频道路由、地名显示、书签持久化）

**Checkpoint**: US13 独立可测

---

## Phase 17: User Story 14 - 实时语音对讲 PTT (Priority: P3) 🎯 M3

**Goal**: 按住对讲键实时语音流（AAC-LC 16k burst 协议），接收端实时波形
**Independent Test**: 双机 PTT 对讲近实时收听（≤1.5s），波形滚动

- [x] T069 [US14] 实现实时语音模块 entry/src/main/ets/service/ 下 live-voice 管理器与 VoiceBurstPacket（[burstID:8B][seq:u16 BE][flags:u8][payload] 编解码、Start/Frames/End/Canceled、AAC-LC 16kHz 16kbps 1024 采样/帧、接收配额 8/384KiB/128、拥塞降 TTL、不进 gossip）
- [x] T070 [US14] 实现 PTT 交互与实时波形 UI entry/src/main/ets/components/ 下 PTT 按钮与滚动波形组件（按住采集/松开结束、最短 600ms、AAC 经 AVRecorder 缓冲流）

**Checkpoint**: US14 独立可测

---

## Phase 18: User Story 15 - Tor 匿名网络 (Priority: P3) 🎯 M3

**Goal**: Arti 移植可行性评估 + SOCKS 代理参数化先行
**Independent Test**: 开启代理后 Nostr 流量经代理收发；Arti 报告产出

- [x] T071 [P] [US15] 完成 Arti (Rust) 鸿蒙移植可行性评估并输出报告 spec/bitchat-harmonyos/notes-arti-port.md（交叉编译工具链、NAPI 绑定、合规与体积结论）
- [x] T072 [US15] 实现 SOCKS 代理参数化 entry/src/main/ets/service/nostr/NostrRelayManager.ets 代理配置与 SettingsView.ets 开关（OFF/自定义代理、对齐 Android 默认端口 9060、开启后禁止直连，为 Arti 接入预留）

**Checkpoint**: US15 独立可测

---

## Phase 19: User Story 16 - 三期调研与互操作验收 (Priority: P3) 🎯 M3

**Goal**: Wi-Fi Aware 调研、热点分享适配设计、跨平台 Mesh Lab 互操作验收
**Independent Test**: 调研报告与双机互操作验收记录留档

- [x] T073 [P] [US16] 输出 Wi-Fi Aware 鸿蒙等价能力调研报告 spec/bitchat-harmonyos/notes-wifiaware.md（结论：等价 API / 降级 / 不可行）
- [x] T074 [P] [US16] 输出热点分享鸿蒙适配设计说明 spec/bitchat-harmonyos/notes-hotspot.md（应用分享/安装包分发方案，可选项）
- [x] T075 [US16] 建立跨平台互操作验收清单与脚本 bitchat-harmonyos/tools/meshlab/（鸿蒙↔Android 双机场景：发现/公告/公聊/私聊/回执/媒体/同步/Nostr/信使，对应 FR-032）

**Checkpoint**: M3（三期）全部用户故事完成

---

## Phase 20: Polish & Cross-Cutting Concerns

**Purpose**: 里程碑验收、性能、安全加固、文档

- [ ] T076 执行 M1 里程碑真机验收（双机全场景：互发现/公聊多跳/私聊回执/发件箱补投/panic/后台保活）并记录 spec/bitchat-harmonyos/acceptance-m1.md
- [ ] T077 执行 M2 里程碑真机验收（Nostr 互通/私有媒体/密码频道/QR 验证/Courier 三机场景）并记录 spec/bitchat-harmonyos/acceptance-m2.md
- [ ] T078 执行 M3 里程碑真机验收（geohash/PTT/代理）并记录 spec/bitchat-harmonyos/acceptance-m3.md
- [x] T079 [P] 性能优化（冷启动 ≤5s、消息流 60fps、BLE 入包吞吐与队列丢弃率 <1%、PTT 延迟 ≤1.5s，对齐 spec SC-001~SC-007）
- [x] T080 [P] 安全加固复查（密钥存储边界、备份排除、panic 完整性、日志脱敏、反滥用参数复核）
- [x] T081 [P] 完善多语言资源 entry/src/main/resources/（中英全量覆盖）与应用文档 bitchat-harmonyos/README.md（构建/部署/验收指引）

---

## Phase 21: Verification

<!-- verification_scope: build-only -->

**Purpose**: 构建与部署验证

- [x] T082 构建工程并修复全部编译错误（devecocli build，迭代修复直至成功）
- [ ] T083 部署应用到真机/模拟器（devecocli run --skip-build）确认可安装启动
