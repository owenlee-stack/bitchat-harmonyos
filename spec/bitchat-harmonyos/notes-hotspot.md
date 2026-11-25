# 热点分享鸿蒙适配设计说明

- **任务**: T074（US16，可选项）
- **日期**: 2026-11-19
- **调研对象**: Android 端"Wi-Fi P2P 热点 + 内嵌 HTTP 服务器分发 APK"离线分享形态在 HarmonyOS NEXT 的适配设计（应用分享/安装包分发方案）
- **参考真源**: `bitchat_android/.../hotspot/`（只读）；HarmonyOS 本地文档（热点三方限制 FAQ、HAP 安装 FAQ、Share Kit、AppGallery 分发）
- **关联决策**: plan.md D10 —— "热点分享三期按鸿蒙'应用分享/安装包分发'方式重设计（可选）"。spec.md US16："应用内安装包分享替代 APK Web 服务器，可选"。
- **前置输入**: `notes-wifiaware.md`（T073）：鸿蒙三方应用无法以代码创建自定义热点；Wi-Fi P2P 三方可用。

---

## 1. Android 侧原形态（设计输入）

| 组件 | 职责 | 证据 |
|---|---|---|
| `HotspotManager` | Wi-Fi P2P（Wi-Fi Direct）建组：随机 SSID 后缀（8 字符安全字母表）+ 16 字符随机密码；GO 角色轮询组信息（1s）、15s 建组超时；自建组标记防误回收他人组 | `hotspot/HotspotManager.kt` |
| `ApkWebServer` | NanoHTTPD 监听 9999 端口：`/` 落地页（版本号、安装指引）、`/bitchat.apk` 直下应用自身 APK（`context` 包路径）、404 兜底 | `hotspot/ApkWebServer.kt` |
| `QrCodeGenerator` | `http://<GO-IP>:9999/bitchat.apk` 二维码 | `hotspot/QrCodeGenerator.kt` |
| `HotspotViewModel` | Aware 热点租约复用（`acquireHotspotLease`）；Activity 展示 SSID/密码/QR | `hotspot/HotspotViewModel.kt` |
| 接收端 | 任意设备连入 Wi-Fi → 浏览器扫码/输 URL → 下载 APK → 系统允许"未知来源"安装 | Android 旁路安装机制 |

**价值主张**：离线（无互联网、无应用商店）场景下向附近设备分发应用本体。

---

## 2. 鸿蒙约束盘点（已核实）

| # | 约束 | 结论 | 证据 |
|---|---|---|---|
| C1 | 三方应用不能以代码开启自定义名称/密码热点；仅系统应用可以；三方只能引导跳转系统设置 | 传输底座降级：Wi-Fi P2P 群组（三方可用，T073 已核实）可替代"AP 热点"作离线通道 | 热点 FAQ（T073 附录）；`notes-wifiaware.md` §2.2 |
| C2 | **消费者设备没有"下载 .hap → 浏览器/文件管理器安装"的旁路安装通道**。HAP 安装路径仅：① AppGallery（上架/非公开发布/开放测试）；② 开发者调试签名 + `hdc install` / DevEco / 模拟器拖拽 | **致命根因**：即使把 .hap 送达对端，普通用户也无法安装——Android 形态的"离线消费者分发"整体不成立 | HAP 安装 FAQ（"如何让HAP能够安装到其他手机上"：手动签名 + `hdc install`）；云调试/真机安装 FAQ |
| C3 | 应用无法读取自身安装包路径（`bundleManager` 只暴露 bundle 元信息，不暴露 .hap 文件句柄）；要分发包体需将发布 .hap 预置进 `resources/rawfile`（HAP-in-HAP，包体近似翻倍）或从服务端下发 | 方案 B 的工程代价约束 | 应用沙箱模型；`@ohos.bundle.bundleManager` 能力面 |
| C4 | Share Kit（`systemShare`）/华为分享提供跨应用、跨设备文本/链接/文件分享；App Linking 支持未安装应用经链接引导安装 | 方案 A 的能力底座 | Share Kit 文档（systemShare、碰一碰分享最佳实践、faqs-share-1） |
| C5 | AGC 分发渠道：公开上架、**非公开发布**（仅链接可见，适合内部/受控分发）、开放测试 | 方案 C 的渠道依据 | AppGallery FAQ（企业内部应用发布） |

---

## 3. 适配设计

### 方案 A（推荐）：应用分享入口 → 应用市场安装（在线）

对齐 spec"应用内安装包分享"意图的鸿蒙正解：不再离线分发包体，而是分享安装入口。

```
设置页 / 关于页
  └─ "分享应用" 入口
       └─ systemShare 分享面板（Share Kit）
            └─ 分享内容：AGC 应用详情页链接（App Linking URI）
                 └─ 接收端：华为分享/信息等渠道 → 点开链接 → AppGallery 安装
```

- **前提**：应用已在 AGC 上架（公开或非公开发布）。
- **工作量**：2–3 天（一个分享入口 + `SharedData` 链接记录；无新权限）。
- **覆盖场景**：日常"推荐给他人"；离线场景不覆盖（如实接受）。

### 方案 B（受控场景，可选）：Wi-Fi P2P + HTTP 分发 .hap（仅开发者/受控分发）

Android `ApkWebServer` 形态的鸿蒙等价，但**仅面向已具备开发者签名/受控安装通道的接收端**（Mesh Lab 双机联调、企业 MDM），不面向消费者：

```
发起端：Wi-Fi P2P createGroup（netId -2 永久组，随机 passphrase）
        → 组内 socket HTTP 服务器（对齐 ApkWebServer：/ 落地页 + /bitchat.hap 直下）
        → QR（复用 T062 QR 能力）展示 http://<GO-IP>:<port>/bitchat.hap
接收端：P2P 连入 → 浏览器/文件管理下载 .hap → hdc install（开发者流程）
```

- **包体来源**（约束 C3）：发布 .hap 预置 `resources/rawfile`（包体近似翻倍，仅 debug 构建携带）或局域网服务端下发；不做线上包。
- **工作量**：2–3 周（P2P 群组状态机 + HTTP 服务 + QR + debug 开关）；依赖 T073 §5 的 P2P 评估结论（仅数据面承载）。
- **不推荐启动**：消费者不可安装（C2），开发者场景已有 USB/hdc 更省事；仅当 Mesh Lab（T075）出现"无 PC 现场刷机"硬需求再议。

### 方案 C（企业/内部）：AGC 非公开发布

不上架公开市场的内部使用场景，直接用 AGC"非公开发布"链接分发（C5），零开发量。

### 不采纳：复刻 Android 原形态（P2P 热点 APK Web 服务器面向消费者）

根因 C2 不可绕过——鸿蒙消费者设备无旁路安装通道，传输层做出来也无接收端闭环。**该形态在鸿蒙判不可行**，与 T073 热点约束（C1）共同构成双否决。

---

## 4. 结论

1. **Android 原形态（离线热点 APK 分发→消费者安装）在鸿蒙不可行**：致命根因是 C2（无消费者旁路安装），叠加 C1（三方无热点控制权，传输底座需换 P2P）。
2. **推荐替代为方案 A**（应用分享入口 → AGC 链接安装，在线）：与 spec"应用分享"指引一致，工作量 2–3 天，待应用上架 AGC 后即可实施。
3. **本期决策**：按 D10 任务为"可选"，本设计说明即为交付物，**不承诺开发**。若后续启动：优先方案 A；方案 B 仅在 Mesh Lab 出现无 PC 受控分发硬需求时立项；方案 C 为内部场景零成本备选。

---

## 附录 A：证据文件清单

- `bitchat_android/.../hotspot/ApkWebServer.kt` —— NanoHTTPD :9999 APK 分发（Android 形态）
- `bitchat_android/.../hotspot/HotspotManager.kt` —— Wi-Fi P2P 建组/随机凭据/QR
- `bitchat_android/.../hotspot/HotspotViewModel.kt` —— Aware 热点租约
- HarmonyOS 本地文档：热点三方限制 FAQ（T073 已引）、HAP 安装 FAQ（手动签名 + hdc）、Share Kit（systemShare/App Linking/碰一碰）、AppGallery 非公开发布 FAQ
- `spec/bitchat-harmonyos/notes-wifiaware.md` —— T073 前置结论（P2P 可用性、热点约束）
- `spec/bitchat-harmonyos/plan.md` D10 —— "应用分享/安装包分发"重设计边界
