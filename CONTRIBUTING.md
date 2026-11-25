# 参与测试与贡献指南

感谢关注 **bitchat-harmonyos** —— bitchat 的 HarmonyOS NEXT 客户端。我们正在公开邀请社区测试，你的每一次反馈都会让这个匿名 mesh 聊天网络更可靠。

## 🐛 如何反馈 Bug

**优先使用 Issue 模板**（GitHub：新建 Issue 时选择 "Bug report"；GitCode：参照 `.github/ISSUE_TEMPLATE/bug_report.md` 的字段填写）。

一份高质量的 Bug 报告应包含：

1. **设备与系统**：机型 + HarmonyOS 版本号 + API 版本
2. **App 版本**：commit hash 或发布 tag（构建日期亦可）
3. **复现步骤**：逐步操作描述（涉及 mesh 场景请说明对端设备与距离）
4. **预期结果 / 实际结果**
5. **日志**（重要）：通过 `hdc hilog` 抓取，或 DevEco Studio Log 窗口导出。本应用不记录任何消息内容与密钥，日志可以放心提交
6. **截图/录屏**（如涉及 UI）

> 隐私提醒：日志与截图中请自行遮挡你的 peerId（若不希望被关联）。

## 🔨 从源码构建

前置条件：

- DevEco Studio / DevEco Code（`DEVECO_HOME` 已配置）
- HarmonyOS SDK（API 26，compileSdk 26）
- Node.js（运行契约测试）

```bash
# 1. 构建并打包 HAP
devecocli build

# 2. 部署到已连接设备/模拟器（真机需开发者签名）
devecocli run
```

> 本工程未内置签名配置（`signingConfigs` 为空）。真机安装需在 DevEco Studio 中配置调试证书或使用 AGC 云签名。

## ✅ 运行测试

```bash
# 黄金向量契约套件（宿主 Node 运行，35 模块，无需设备）
node entry/src/test/contract/run-contract-tests.mjs
```

提交 PR 前请确保：**契约测试 35/35 全绿** + `devecocli build` 成功。

## 🌐 测试重点场景

单机即可测试：首启引导、身份创建、IRC 命令、panic 擦除、Nostr 私信、geohash 频道、主题切换。

双机/多机（价值最高）：

- BLE mesh 互发现与洪泛中继（鸿蒙 ↔ 鸿蒙、鸿蒙 ↔ Android）
- 公聊多跳、私聊 Noise XX 加密与送达/已读回执
- 私有媒体（图片/文件/语音便签）传输
- Courier 密写信使三机场景
- 实时语音对讲 PTT（≤1.5s 延迟）

跨平台互操作验收可使用 `tools/meshlab/`（9 场景，清单见 `tools/meshlab/CHECKLIST.md`）。

## 📦 提交 Pull Request

1. Fork 本仓库并创建特性分支：`git checkout -b fix/your-bugfix`
2. 保持提交原子化，commit message 说明"改了什么、为什么改"
3. 协议层改动**必须**附带或更新对应契约测试向量（向量字面值不得改动）
4. 遵循 ArkTS 严格模式规范（无 `any`、无对象字面量类型、V1/V2 状态管理不混用）
5. 提交 PR 并描述测试情况

## 🗺️ 当前状态与路线图

- ✅ 全部功能模块已实现（M1–M3 用户故事）
- ✅ 35 个黄金向量契约测试全绿
- ⏳ M1/M2/M3 真机里程碑验收进行中（`spec/bitchat-harmonyos/tasks.md` 的 T076–T078）
- 📋 完整工程决策记录见 `spec/bitchat-harmonyos/`（spec / plan / tasks / 安全复查报告）

## 📄 许可证

AGPL-3.0。提交即表示你同意贡献内容按 AGPL-3.0 授权。
