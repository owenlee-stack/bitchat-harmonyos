# meshlab — 跨平台 Mesh 互操作验收工具（FR-032 / T075）

鸿蒙 ↔ 鸿蒙、鸿蒙 ↔ Android 双机 mesh 互操作验收的清单与脚本。完整执行流程见 `CHECKLIST.md`。

## 组成

| 文件 | 作用 |
| --- | --- |
| `CHECKLIST.md` | FR-032 验收清单（场景矩阵、通过标准、证据规则） |
| `scenarios.json` | 机器可读场景定义（9 场景：发现/公告/公聊/私聊/回执/媒体/同步/Nostr/信使） |
| `meshlab.py` | hdc/adb 编排脚本（doctor / setup / watch / evidence） |
| `out/` | 本地证据目录（自动生成，**禁止提交**） |

## 快速开始

```bash
# 1. 检查工具与设备
python tools/meshlab/meshlab.py doctor

# 2. 安装并启动（任选一侧或双侧）
python tools/meshlab/meshlab.py setup --hap <entry.hap> --apk <android-debug.apk>

# 3. 逐场景 × 逐设备对执行
python tools/meshlab/meshlab.py watch --scenario discovery --pair hm-hm
python tools/meshlab/meshlab.py watch --scenario public-chat --pair hm-android
# ... 其余场景见 scenarios.json；--duration 0 可改为回车手动停止采集

# 4. 汇总历史记录
python tools/meshlab/meshlab.py evidence
```

## 依赖

- Python 3.9+（仅标准库）
- `hdc`（HarmonyOS SDK toolchains，需在 PATH）
- `adb`（Android platform-tools，仅 hm-android 对需要）
- 鸿蒙真机 1–2 台（开发者模式 + USB 调试）；Android 真机 1 台（可选）

## 隐私

`out/` 中的日志与 `evidence.json` 可能包含昵称、消息元数据等运行期观察数据：仅本地留档，禁止提交仓库或外传。
