# Wi-Fi Aware 鸿蒙等价能力调研报告

- **任务**: T073（US16，FR-030）
- **日期**: 2026-11-19
- **调研对象**: Android 端 Wi-Fi Aware（NAN，Neighbor Awareness Network）mesh 传输在 HarmonyOS NEXT 上的等价能力（结论：等价 API / 降级 / 不可行）
- **参考真源**: `bitchat_android/bitchat-android-main/`（只读）；HarmonyOS 本地 API 文档（`@ohos.wifiManager`、P2P 开发指南）
- **关联决策**: plan.md D10 —— 一期不实现 Wi-Fi Aware；三期仅安排调研（结论可为不可行/降级 BLE/可等价实现），不承诺开发。spec.md L13、FR-030。

---

## 1. Android 侧现状基线（调研输入）

Android 端 Wi-Fi Aware 是 BLE 之外的第二条 mesh 传输，**默认关闭、调试开关启用**（`DebugPreferenceManager.getWifiAwareEnabled(false)`）：

| 维度 | Android 实现 | 证据 |
|---|---|---|
| 系统能力 | `WifiAwareManager`（NAN）：`attach()` → `WifiAwareSession`；publish/subscribe 双向发现；`WifiAwareNetworkSpecifier` 建立 datapath（无需 AP 参与） | `wifi-aware/WifiAwareMeshService.kt` |
| 硬件门槛 | `FEATURE_WIFI_AWARE` 系统特性 + 位置开关（attach 在定位关闭时抛 SecurityException） | `wifi-aware/WifiAwareSupport.kt` |
| 权限 | `NEARBY_WIFI_DEVICES`（API 33+）/历史 `ACCESS_FINE_LOCATION` | `onboarding/PermissionManager.kt` |
| 传输桥接 | `WifiAwareMeshService` 实现 `MeshService` + `TransportLayer`，与 BLE 并存于 `UnifiedMeshService` 多路复用 | `mesh/UnifiedMeshService.kt` |
| 功耗治理 | `PowerManager.WifiAwareSchedule`（发现会话刷新 2s–15min 分档；按电池档位调整） | `mesh/PowerManager.kt` |
| 热点租约 | `WifiAwareController.acquireHotspotLease()`（HotspotViewModel 复用 Aware 能力做热点分享） | `hotspot/HotspotViewModel.kt` |
| 验收矩阵 | publish/subscribe 生命周期、datapath 认证提升、Wi-Fi/定位/飞行模式切换恢复、与 BLE 同侪合并为一行、跨传输 failover/TTL/回环抑制 | `docs/device-transport-test-matrix.md` L73–99 |

**NAN 的核心价值**（对照项）：无 AP 基础设施的邻居发现 + 直连数据通路、比 BLE 高一个数量级的吞吐、与 STA 并发不互斥。

---

## 2. 鸿蒙能力盘点（已核实）

### 2.1 Wi-Fi Aware / NAN：**无对应 API**

`@ohos.wifiManager`（Connectivity Kit，API 9+）模块定位为"WLAN 基础功能（接入/加密/漫游）、**P2P（peer-to-peer）服务**、Wi-Fi 消息通知"——全 SDK 范围内无 NAN/Wi-Fi Aware 接口（无 attach/publish/subscribe/datapath 等价物，也无对应系统能力 SystemCapability）。spec.md L13 的预判（"鸿蒙无直接等价 API"）经查证成立。

### 2.2 Wi-Fi P2P（Wi-Fi Direct）：**三方应用可用**（最接近的替代底座）

`@ohos.wifiManager` P2P 接口（SystemCapability.Communication.WiFi.P2P）：

| 接口 | 功能 | 权限（三方可用性） |
|---|---|---|
| `createGroup` / `removeGroup` | 创建（netId -1 临时组 / -2 永久组）/删除群组（GO 角色） | `GET_WIFI_INFO` |
| `startDiscoverDevices` / `stopDiscoverDevices` | P2P 设备发现 | `GET_WIFI_INFO`（API 10+） |
| `getP2pPeerDevices` / `getP2pLocalDevice` | 对端/本机设备信息 | `GET_WIFI_INFO` |
| `p2pConnect` / `p2pCancelConnect` | GO 协商连接/取消 | `GET_WIFI_INFO` |
| `on/off('p2pDeviceChange'/'p2pPeerDeviceChange'/'p2pConnectionChange'/'p2pPersistentGroupChange')` | 状态事件 | `GET_WIFI_INFO` |
| `enableWifi` / `disableWifi` | 开关 Wi-Fi | **三方不可用**（`MANAGE_WIFI_CONNECTION` 仅系统应用）；只能 `isWifiActive()` 查询 |

要点：
- 设备地址默认**随机化**（真实 MAC 需 `GET_WIFI_PEERS_MAC`，普通应用拿不到）——与 bitchat 的隐私立场一致。
- 数据面：P2P 组建立后走标准 TCP/IP socket（GO 为组内 DHCP/网关），应用层自行建 socket + 协议加密。
- `netId -2` 永久组可免除重复 GO/WPS 协商，适合已配对设备复连。

### 2.3 BLE（已实现，无需调研确认）

鸿蒙端一期已交付 `BleMeshService.ets`（GATT client+server 双角色）与 `Transport`/`TransportRegistry` 抽象，`TransportRegistry`（`service/mesh/Transport.ets:31`）即为未来传输的注册扩展位（T023 预留）。

---

## 3. 等价性映射（NAN → 鸿蒙）

| Android NAN 能力 | 鸿蒙状态 | 说明 |
|---|---|---|
| attach（加入 NAN 集群，无 AP） | **无等价** | P2P 发现需要 `startDiscoverDevices` 且连接需 GO 协商/群组，不是 NAN 那种持续、低干扰的邻居发现 |
| publish/subscribe 双向订阅发现 | **部分等价（P2P）** | `startDiscoverDevices` + `on('p2pPeerDeviceChange')`；发现结果为设备级（无 publish service-specific payload 语义，Bitchat 需在连接后自证身份——协议层 Noise 路由已支持） |
| NetworkSpecifier datapath（安全直连） | **部分等价（P2P）** | 群组内 TCP/IP socket；安全性由应用层 Noise/协议加密承担（与 BLE 路径同级） |
| 与 STA 并发不互斥 | **待真机验证** | P2P 与 STA 并发为 Wi-Fi Alliance 标准场景，但厂商实现差异需 Mesh Lab 实测 |
| 后台持续发现 | **无等价承诺** | P2P 发现无文档化的后台节流承诺，且 GO 协商/系统弹窗交互重，不适合无感后台 mesh |
| 硬件能力探测（FEATURE_WIFI_AWARE） | **无对应** | 鸿蒙无 NAN 硬件特性概念；P2P 可用性只能以 `isWifiActive()` + 接口错误码（801/2801000）探测 |
| 跨平台互通（Android↔鸿蒙） | **不可行** | NAN 协议互通在理论层面存在（WiFi Alliance NAN 标准），但 Android 侧 bitchat 的 Aware 传输绑定 `WifiAwareNetworkSpecifier` 私有握手与 Bitchat 包封装，鸿蒙无 NAN API，双端互通无从建立 |

---

## 4. 结论（FR-030 要求的三选一）

**结论：不可行（无等价 NAN API）→ 采用降级路径：BLE 为主传输（已实现），不引入 Wi-Fi P2P 替代开发。**

1. **等价 API：不存在**。HarmonyOS NEXT SDK 无 NAN/Wi-Fi Aware 任何接口，等价移植无从谈起。
2. **降级 BLE：已是现实且为唯一跨平台路径**。BLE 传输（T023–T025）已交付且是鸿蒙↔Android 互通的唯一 mesh 通道（iOS 同样无 NAN 对外 API），跨平台互操作（T075/FR-032）依赖 BLE，降级不损失互通性。
3. **Wi-Fi P2P 作为可选增强：本调研不建议启动**。理由：
   - 收益仅限于吞吐（媒体/大文件），而大文件私有媒体（US10）已在 BLE MTU 分片约束下交付；
   - 成本：GO 协商状态机 + 系统连接交互 + 永久组管理 + 与 BLE 的同侪合并/failover（Android 端 `UnifiedMeshService` 的整套多路复用逻辑），工程量约 3–4 周 + 真机验收；
   - P2P 发现的后台行为、并发互斥、厂商差异均无文档保证，Mesh Lab 实测成本高；
   - `TransportRegistry` 扩展位已预留，未来若启动，按 Android `WifiAwareMeshService` 的 `Transport` 实现形态接入即可，无架构返工。
4. **对 T074 的输入**：热点分享侧同样受约——鸿蒙三方应用**不能**以代码开启自定义名称/密码热点（官方 FAQ 明确，仅系统应用可；三方只能引导跳转系统设置），Android 的 `acquireHotspotLease`（Aware 热点租约）在鸿蒙无对应物，T074 应走"应用分享/安装包分发"路线（与 D10 一致）。

---

## 5. 后续触发条件（若重新评估 Wi-Fi P2P）

满足其一再立项，且仅作为 BLE 的高吞吐补充传输（发现仍走 BLE，P2P 仅承载数据面）：
1. 私有媒体/文件传输的实测吞吐成为用户可感知瓶颈（BLE 517 MTU 分片实测 < 100 KB/s 量级）；
2. Mesh Lab 双机验收（T075）发现 BLE 拥塞丢包率超标（SC-006 队列丢弃率 <1%）且无法以调度优化解决。

届时建议技术方案：BLE 发现 + 认证 → `p2pConnect`（netId -2 永久组）→ 群组内 TCP socket 承载 BitchatPacket（复用现有分片/加密层）→ `TransportRegistry.register('wifiP2p', …)`。

---

## 附录 A：证据文件清单

- `bitchat_android/.../wifi-aware/WifiAwareMeshService.kt` —— NAN publish/subscribe + datapath 传输实现
- `bitchat_android/.../wifi-aware/WifiAwareSupport.kt` —— FEATURE_WIFI_AWARE / 位置开关门槛
- `bitchat_android/.../mesh/PowerManager.kt` —— WifiAwareSchedule 功耗分档
- `bitchat_android/.../docs/device-transport-test-matrix.md` L73–99 —— Wi-Fi Aware 与跨传输 failover 验收项
- `bitchat_android/.../hotspot/HotspotViewModel.kt` —— acquireHotspotLease（T074 相关）
- HarmonyOS 本地文档：`@ohos.wifiManager (WLAN)` 模块定位（无 NAN）、P2P 接口/权限表、`enableWifi` 系统应用限制、热点三方限制 FAQ
- `bitchat-harmonyos/.../service/mesh/Transport.ets:31` —— TransportRegistry 扩展位（T023 预留）
- `spec/bitchat-harmonyos/plan.md` D10 —— 三期仅调研不承诺开发的边界
