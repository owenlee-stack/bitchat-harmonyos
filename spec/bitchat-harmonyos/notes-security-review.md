# T080 安全加固复查报告

日期：2026-11-20　范围：FR-007 / FR-019 / SC-003 相关代码与配置　结论：**通过（含 1 处修复）**

## 1. 密钥存储边界 — PASS

| 项 | 结论 |
| --- | --- |
| 设备身份（Noise 静态 / Ed25519 签名） | Asset Store（owner-only、`SYNC_TYPE NEVER`），别名隔离；见 `data/SecureKeyStore.ets` putKey/getKey |
| Nostr 身份（secp256k1 私钥） | `data/NostrIdentityStore.ets`：Asset Store 原始密钥别名 `nostr_private_key_v1`，并发创建共享单飞 Promise，损坏即弃置重生成 |
| 派生数据（发件箱密文、收藏文档、peerID→npub 索引） | HUKS 非导出 AES-256-GCM 信封（`[ver][nonce12][ct][tag16]`，固定 AAD），密钥永不出 TEE |
| 频道密码派生密钥 | `service/mesh/ChannelManager.ets`：PBKDF2 派生密钥仅内存（注入式 ChannelCrypto），不落盘 |
| peer 状态 pin | `data/PeerStatePinStore.ets`：明文 hex，但内容为对端公钥+能力位（公开数据，Android 平价）；持久化先于发布替换 Ed 密钥的次序由 store 接口保证 |
| 验证结论 | 无任何密钥材料进入 PreferenceStore / 普通文件 |

## 2. 备份排除 — PASS

- `resources/base/profile/backup_config.json`：`allowToBackupRestore: false`（框架级整体拒绝，强于 Android 的逐项排除规则）；
- runner 内联契约 `BackupExclusionContract`（run-contract-tests.mjs）每次执行断言该文件为 deny-by-default，当前 35 模块套件内 PASS；
- Asset Store 条目 `SYNC_TYPE NEVER`，HUKS 密钥不可导出：即使备份被强行打开也无密钥可取。

## 3. panic 完整性 — PASS

- `service/identity/IdentityManager.ets` 阶段机与 FR-019 顺序逐项一致：STOP_SERVICES → CLEAR_PRIVATE_MEDIA_CONSENT → STOP_ADMISSION → DELETE_CONVERSATION_STORE → CLEAR_UI_STATE → CLEAR_DEDUP_AND_OUTBOX → CLEAR_SPAM_FILTER → CLEAR_CRYPTO_DATA → CLEAR_NOTIFICATIONS → DELETE_MEDIA → CLEAR_NOSTR_GEOHASH → CLEAR_FAVORITES → RESET_NICKNAME → REBUILD_IDENTITY；
- 每阶段独立确认（runStage/runAsyncStage 捕获异常计为失败不中断全局），任一失败 → `PANIC MODE INCOMPLETE` 日志 + UI `system_panic_incomplete` 明示，`completed=false`；
- CLEAR_CRYPTO_DATA = `SecureKeyStore.panicWipe()`（分页清空全部 Asset 条目 + 删除 HUKS 密钥）；CLEAR_UI_STATE 内 `PreferenceStore.clearAll()` 覆盖昵称/设置/垃圾过滤开关/引导标志全量清单；
- ChatViewModel 重入保护（panicWipeInProgress）防二次触发竞态。

## 4. 日志脱敏 — 1 处修复后 PASS

全量扫描 main sources 的 hilog 调用（100+ 处）：

- BLE/Mesh/Nostr 路径仅记录 deviceId、长度、计数器与 err.message，无线上载荷、无密钥、无 nsec/npub；
- **修复**：`service/nostr/NostrRelayManager.ets` `handleMessage` 解析失败分支原样打印中继原始文本——畸形消息仍可能携带他人内容进入 hilog。已改为仅记录来源 URL 与长度（`failed to parse relay message from %{url}, len=%{n}`），不落内容。

## 5. 反滥用参数复核 — PASS（契约锁定）

| 参数组 | 值 | 锁定 |
| --- | --- | --- |
| SpamFilter 三桶 | 消息 6 条/10s、字符 1200/min、链接 2/min + 3 类重复检测（自重复/自历史/跨用户），隐藏消息不耗令牌但入重复历史 | SpamFilterContractTests |
| 载荷上限 | DEFLATE 比率 1032；分片 1280B / 控制 4KiB / 同步 8KiB / 信封 64KiB / TWICE-v1 128KiB；未知类型收 4KiB | PacketPayloadLimitsContractTests（Android 黄金向量） |
| 中继 | 初始退避 1s、倍率 2.0、上限 300s、最多 10 次；读 ACK 350ms；去重 10,000；48h gift-wrap 回看 | NostrRelay/NostrTransportContractTests |
| 发件箱 | 每 peer 100 条 / 24h TTL / 最多 8 次重发；握手退避 5/15/30/60s | MessageRouter/GossipSyncContractTests |
| 入包准入 | 16 槽×64 队列、全局 8MiB 预算、按类型收包上限、丢弃计数 + SC-006 丢弃率（T079） | PacketProcessorContractTests |

## 验证闸门

- 契约测试 35/35 PASS（含 BackupExclusionContract）
- arkts_check 0 errors（本轮改动文件）
- devecocli build SUCCESS
