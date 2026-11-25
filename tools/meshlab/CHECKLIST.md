# 跨平台 Mesh Lab 互操作验收清单（FR-032 / US16 / T075）

本清单为 FR-032 的执行依据：在真机双机环境完成 mesh 互操作验收（发现、公告、公聊、私聊、回执、同步、媒体、信使；Nostr 为 US13 增列项）。所有场景需在以下两个设备对上各执行一遍：

- **hm-hm**：鸿蒙 ↔ 鸿蒙
- **hm-android**：鸿蒙 ↔ Android（参考实现 `bitchat_android/bitchat-android-main`，作为协议黄金真源）

## 0. 执行前准备（setup）

| 项 | 要求 |
| --- | --- |
| 鸿蒙设备 | 已开发者模式 + USB 调试（hdc 可见）；安装本工程 debug/发布 HAP |
| Android 设备 | USB 调试（adb 可见）；安装参考仓库 debug APK（含 TestHook，不强制启用） |
| 环境 | 蓝牙可开启；两机物理距离 ≤ 2 米；`hdc`/`adb` 在 PATH |
| 网络（仅 nostr 场景） | 两机均可访问公网 wss:// 中继 |
| 引导 | 双机均完成引导页（昵称、权限授予、默认频道 #general） |

一键准备：

```bash
python tools/meshlab/meshlab.py doctor
python tools/meshlab/meshlab.py setup --hap build/entry/entry-default-unsigned.hap --apk <android-debug.apk>
```

## 1. 场景矩阵

每个场景 × 每个设备对 = 一条验收记录（`PASS` 方可计入 FR-032 完成）。

| # | 场景 id | 内容 | 预期时长 |
| --- | --- | --- | --- |
| 1 | discovery | 发现：双机互相进入 peer 列表 | 2 min |
| 2 | announce | 公告：昵称/身份公告包互通 | 3 min |
| 3 | public-chat | 公聊：#general 双向消息 | 2 min |
| 4 | dm | 私聊：Noise 会话与双向 DM | 3 min |
| 5 | receipts | 回执：送达/已读回执 | 2 min |
| 6 | media | 媒体：私聊语音/图片传输 | 5 min |
| 7 | sync | 同步：离线补拉 | 4 min |
| 8 | nostr | Nostr：中继连通与中继消息 | 5 min |
| 9 | courier | 信使：courier 暂存（三机增强） | 5–10 min |

各场景的操作步骤、预期日志标记与通过标准见 `scenarios.json`（机器可读）与下文摘要。

执行（以 discovery 为例）：

```bash
python tools/meshlab/meshlab.py watch --scenario discovery --pair hm-android
python tools/meshlab/meshlab.py watch --scenario discovery --pair hm-hm
```

脚本会：清理并采集双机 hilog/logcat → 打印操作步骤 →（定时或按回车）停止采集 → 扫描场景标记 TAG → 由操作者确认屏幕结果 → 落盘 `out/<时间戳>_<场景>_<设备对>/evidence.json`。

## 2. 通过标准

单条记录判定为 `PASS` 需同时满足：

1. **操作者确认**：`scenarios.json` 中该场景的 `pass` 标准在屏幕上成立；
2. **日志标记**（参考性，不单独决定结论）：双侧设备日志中命中该场景预期的协议 TAG（鸿蒙侧 `BleMeshService`/`GattClient`/`ChatViewModel` 等，Android 侧 `BluetoothMeshService`/`PacketProcessor` 等）；
3. **无崩溃**：采集期间任一设备无 jscrash/ANR/fatal。

`PARTIAL`（操作者通过但标记缺失）需在记录备注中说明原因（如日志级别被裁剪）后方可计入；`FAIL` 必须修复后重跑。

## 3. 证据与留档

- 证据目录：`tools/meshlab/out/`（脚本自动创建）；
- 每次运行包含：`evidence.json`（场景、设备对、时间、标记命中、判定）与两台设备的原始日志；
- **隐私规则**：日志与记录可能包含昵称、消息元数据等观察数据，**仅本地留档，禁止提交仓库或外传**；对外汇报仅引用 `evidence.json` 中的判定与统计；
- 汇总查看：`python tools/meshlab/meshlab.py evidence`。

## 4. 已知限制与说明

1. **鸿蒙侧无 TestHook**：与 Android 参考仓库的 `TestHookReceiver`（intent 驱动、JSON 结果文件）不同，鸿蒙应用未内置调试钩子，本 Lab 为"脚本备机 + 人工执行屏幕步骤 + 日志自动断言"的半自动形态；若后续需要全自动化，需在鸿蒙侧增设计 TestHook 等价物（不在 T075 范围）。
2. **courier 场景**：完整验证需三台设备（发送方 / courier / 收件人）；双机仅验证"courier 暂存半程"（暂存目录仅密文无明文）。三机记录在案时补全。
3. **标记扫描是启发式**：日志 TAG 命中只证明对应模块有活动，不等于协议语义正确；最终判定以操作者屏幕确认为准。
4. **Wi-Fi Aware / 热点**不在本清单内（结论见 `spec/bitchat-harmonyos/notes-wifiaware.md`、`notes-hotspot.md`：跨平台 mesh 通道以 BLE 为唯一互通路径）。
