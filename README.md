# bitchat-harmonyos

bitchat 的 HarmonyOS NEXT (API 12+, compileSdk 26) 客户端：BLE mesh 匿名聊天 + Noise 端到端私聊 + Nostr 中继互通。协议与交互以 Android 参考实现（`bitchat_android/bitchat-android-main`）为黄金真源逐任务移植，全部线上格式由黄金向量契约测试锁定。

## 功能总览（对应 spec 用户故事）

| 模块 | 内容 |
| --- | --- |
| 身份 | 无账号：Noise 静态 + Ed25519 签名密钥生成于 Asset Store（永不云同步），peerId = SHA-256(noisePub)[0..8] |
| Mesh | BLE GATT 双角色（client/server）广播与发现、分片重组、洪泛中继、拓扑图、公告调度 |
| 聊天 | 公聊广播、主题频道（可选 PBKDF2 密码保护）、私聊（Noise XX + 送达/已读回执）、IRC 式命令（`/nick` `/join` `/who` …） |
| 隐私 | 三连击 logo 分阶段紧急擦除（panic wipe，任一阶段失败明示 `system_panic_incomplete`）、垃圾过滤、载荷上限准入 |
| 媒体 | 私聊图片/文件/语音便签（端到端加密，发件箱补投）、按住说话 PTT（实时波形） |
| Nostr | 多中继 WebSocket（默认 damus/primal/offchain/nostr21）、seal/gift-wrap 私信、geohash 位置频道、收藏互信离线投递、Courier 密封信使 |
| 网络 | SOCKS 代理参数化（自定义地址即禁直连，fail-closed；Arti/Tor 接入点预留） |
| 互操作 | BLE 为鸿蒙↔Android 唯一跨平台 mesh 通道；验收工具见 `tools/meshlab/` |

## 构建

前置：DevEco Studio / DevEco Code（`DEVECO_HOME` 已配置），HarmonyOS SDK（API 26）。

```bash
devecocli build          # 编译并打包 HAP（build/entry/entry-default-unsigned.hap）
devecocli run            # 构建并部署到已连接设备/模拟器
devecocli run --skip-build   # 部署上次构建产物
```

签名：工程未内置签名配置（`signingConfigs` 未配置），发布需在 DevEco Studio 中配置证书或使用 AGC 云签名；调试部署到真机需开发者签名。

## 测试

```bash
# 黄金向量契约套件（宿主 Node 运行，35 模块，无需设备）
node entry/src/test/contract/run-contract-tests.mjs

# ArkTS 严格模式静态检查
arkts_check <files...>   # 或随 devecocli build 联动
```

契约套件移植自 Android `app/src/test`（ClientRewriteWire、PacketPayloadLimits、NoiseExternalVector、GCSFilter、Bech32Padding、BackupExclusion 等），向量字面值不变；协议内核（`service/`）保持纯 ArkTS（无 `@ohos`/`@kit` 依赖）以运行于宿主测试机。

## 部署与验收

1. **单机**：`devecocli run --skip-build` 安装启动；首启完成引导（蓝牙/位置/通知权限、昵称 ≤15 字符）。
2. **双机 mesh**（FR-032 / SC-001~007）：使用 `tools/meshlab/` 执行互操作验收：
   ```bash
   python tools/meshlab/meshlab.py doctor
   python tools/meshlab/meshlab.py setup --hap <hap> --apk <android-apk>
   python tools/meshlab/meshlab.py watch --scenario discovery --pair hm-android
   ```
   9 场景（发现/公告/公聊/私聊/回执/媒体/同步/Nostr/信使）× 设备对（hm-hm、hm-android），清单与通过标准见 `tools/meshlab/CHECKLIST.md`；证据落 `tools/meshlab/out/`（仅本地，勿提交）。
3. **性能验收**（SC-006/007）：冷启动 grep hilog `ColdStartReady`（预算 5000ms）；队列丢弃率由 PacketProcessor 诊断串（`Drop Rate`，预算 <1%）与 `getDebugInfo()` 读取；PTT ≤1.5s 由 meshlab media/PTT 场景实测。
4. **里程碑记录**：M1/M2/M3 真机验收记录落 `spec/bitchat-harmonyos/acceptance-*.md`。

## 目录速览

```
entry/src/main/ets/
  entryability/    启动链（并行 bootstrap）、后台任务、通知
  service/mesh/    BLE 传输、包处理、洪泛中继、SpamFilter、频道、拓扑
  service/noise/   Noise XX 会话与密钥协商
  service/nostr/   中继连接、seal/gift-wrap、geohash 频道、SOCKS 策略
  service/identity/ 身份与 panic 阶段机
  service/media/   私有媒体分片传输
  data/            PreferenceStore / RDB 会话库 / SecureKeyStore(HUKS+Asset)
  viewmodel/       ChatViewModel（单一状态源）+ ChatState(@ObservedV2)
  views/ components/ pages/  ArkUI (@ComponentV2) 界面
entry/src/test/contract/   35 个黄金向量契约模块 + Node runner
tools/meshlab/             跨平台互操作验收（FR-032）
spec/bitchat-harmonyos/    WBS(tasks.md)、spec.md、plan.md、调研/安全复查报告
.github/ISSUE_TEMPLATE/    Bug 反馈 / 功能建议 Issue 模板
```

## 多语言

资源层已中英全覆盖（`resources/zh_CN`、`resources/en_US`、`base` 三套一致键集：应用名、权限说明等）；界面主文案当前为中文直写（141 处，与 Android 默认语言路径平价），完整 UI i18n 抽取为后续独立工程。备份默认整体拒绝（`backup_config.json: allowToBackupRestore=false`，由契约套件断言）。

## 隐私与安全要点

- 密钥：Asset Store（SYNC NEVER）存身份密钥；HUKS 非导出 AES-256-GCM 封存派生数据；无任何密钥进入普通文件/首选项。
- 传输：私聊 Noise XX 前向保密；频道密码 PBKDF2(100k)+AES-GCM；Nostr seal/gift-wrap；中继只见密文。
- panic：14 阶段擦除（FR-019 顺序），每阶段确认，失败明示不静默。
- 日志：不记录消息内容、密钥与线上载荷（T080 复查，报告见 `spec/bitchat-harmonyos/notes-security-review.md`）。

## 参与测试与反馈

本项目正在公开邀请社区测试。发现 Bug 请在仓库的 **Issues** 页面提交（GitHub 端选择 "Bug report" 模板；GitCode 端参照 `.github/ISSUE_TEMPLATE/bug_report.md` 字段填写），高质量报告请附机型/系统版本/复现步骤/hilog 日志。

测试指南、重点场景、构建与 PR 流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

当前状态：全部功能模块已实现（M1–M3 用户故事），契约测试 35/35 全绿；M1/M2/M3 真机里程碑验收进行中（见 `spec/bitchat-harmonyos/tasks.md` T076–T078）。

## 许可证

[AGPL-3.0](LICENSE) © bitchat-harmonyos contributors
