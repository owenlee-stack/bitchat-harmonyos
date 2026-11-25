# Arti (Rust) 鸿蒙移植可行性评估报告

- **任务**: T071（US15，FR-029）
- **日期**: 2026-11-19
- **评估对象**: 将 Android 端已落地的 Arti（Rust Tor 客户端）原生库方案移植到 HarmonyOS NEXT
- **参考真源**: `bitchat_android/bitchat-android-main/tools/arti-build/`（只读）
- **关联决策**: plan.md D6 —— Tor 分三期：①SOCKS 代理参数化（T072）；②默认关闭；③Arti 移植评估（本报告）。若原生移植不可行，须输出明确结论与替代建议（FR-029）。

---

## 1. Android 侧现状基线（移植输入）

| 项 | 值 | 证据 |
|---|---|---|
| Arti 版本 | `arti-v1.9.0`（commit `ba421ece`） | `tools/arti-build/TOOLCHAIN.env` |
| Rust 工具链 | 1.95.0（rust-toolchain.toml 固定） | `TOOLCHAIN.env` / `rust-toolchain.toml` |
| Android 构建模式 | cargo-ndk 4.1.2 + NDK r27d，4 ABI | `TOOLCHAIN.env` / `build-arti.sh` |
| 包装 crate | `arti-android-wrapper`（cdylib，JNI） | `tools/arti-build/Cargo.toml` / `src/lib.rs` |
| arti-client features | tokio, rustls, compression, bridge-client, onion-service-client, static, static-sqlite | `Cargo.toml` |
| release profile | `opt-level="z"` / LTO / codegen-units=1 / strip / panic=abort | `Cargo.toml` |
| 可复现构建 | 固定 `SOURCE_DATE_EPOCH`、`--remap-path-prefix`、digest-pinned 容器、SHA256SUMS manifest | `build-arti.sh` / `rebuild-in-container.sh` |
| 构建验收闸门 | ①llvm-nm 校验 JNI 导出符号；②readelf 校验 16KB 页对齐（0x4000）；③strings 拒绝 host 路径泄漏 | `build-arti.sh` L430–459、L507–566 |
| Kotlin 集成 | `ArtiTorManager`（TorState: OFF/STARTING/BOOTSTRAPPING/RUNNING/STOPPING/ERROR + bootstrapPercent）、`ArtiNative` JNI 绑定、`ArtiProxy`、`ArtiLogListener` | `app/src/main/java/com/bitchat/android/net/ArtiTorManager.kt` |
| 默认 SOCKS 端口 | 9060 | `ArtiTorManager.kt` / README |

**已交付 .so 体积**（`app/src/main/jniLibs/`）:

| ABI | 大小（字节） |
|---|---|
| arm64-v8a | 5,422,384 |
| armeabi-v7a | 3,921,272 |
| x86 | 6,145,740 |
| x86_64 | 6,286,736 |

**依赖栈关键 crate**（`Cargo.lock` 实测存在）: `libc`、`mio`、`rustls`、`ring`、`rusqlite`（static-sqlite）、`openssl-sys`（见 §5 风险 R3）。未出现 `aws-lc-rs`/`aws-lc-sys`（TLS provider 走 ring 路线，利好 OHOS 移植）。

---

## 2. 交叉编译工具链评估

### 2.1 Rust 官方 OHOS target（成立）

Rust 上游已内置 OpenHarmony target（OpenHarmony Rust SIG 贡献）：

| target | 上游状态 | 用途 |
|---|---|---|
| `aarch64-unknown-linux-ohos` | Tier 2（含 host tools，Rust 1.78 起正式发布） | 真机（手机/平板均为 aarch64） |
| `armv7-unknown-linux-ohos` | Tier 2 | 旧 32 位设备（可裁剪） |
| `x86_64-unknown-linux-ohos` | Tier 2 | 模拟器 |

- `rustup target add aarch64-unknown-linux-ohos` 即可获得 std（musl 系 libc）。
- Android 侧锚定的 Rust 1.95.0 ≥ 1.78，target 支持无版本障碍。

### 2.2 链接器与 sysroot（成立）

OHOS 无独立 "NDK" 概念，由 **HarmonyOS SDK `native` 目录**提供 LLVM 工具链与 sysroot（clang/lld/llvm-ar/llvm-readelf 等，DevEco Studio 自带）。`.cargo/config.toml` 目标配置形如：

```toml
[target.aarch64-unknown-linux-ohos]
linker = "<SDK>/native/llvm/bin/aarch64-unknown-linux-ohos-clang"   # 或 clang + --target
ar = "<SDK>/native/llvm/bin/llvm-ar"
rustflags = [
  "-C", "link-arg=--target=aarch64-unknown-linux-ohos",
  "-C", "link-arg=-Wl,-z,max-page-size=16384",   # 与 Android 16KB 对齐策略对齐
]
```

cargo-ndk 不可用于 OHOS（其仅封装 Android NDK）；替代方案是直接 cargo + 上述 target 配置（cargo-ndk 本质也只是设置 linker/rustflags，无硬依赖）。

### 2.3 可复现构建链（成立，可平移）

Android 链的全部机制在 OHOS 场景均有直接对应物：

| Android 机制 | OHOS 对应 |
|---|---|
| digest-pinned 构建容器 | 相同（容器内装 HarmonyOS SDK 命令行工具，SDK 包从 AGC 固定版本+校验和下载） |
| `SOURCE_DATE_EPOCH` + `--remap-path-prefix` | 相同（rustc 参数与目标平台无关） |
| cargo-ndk 调用 | 替换为 cargo `--target aarch64-unknown-linux-ohos` |
| llvm-nm / llvm-readelf / strings 验收 | 相同工具，取自 `<SDK>/native/llvm/bin` |
| SHA256SUMS manifest | 相同 |
| NDK r27d pin | 改为 pin HarmonyOS SDK 版本（compileSdkVersion 26 对应包） |

**结论（工具链）**: 交叉编译路径完整成立，无需等第三方补齐；工具链 pin 粒度从 "NDK 版本" 换为 "SDK native 版本"。

---

## 3. NAPI 绑定路径评估

### 3.1 JNI → NAPI 的映射关系（成立，需重写包装层）

| Android（JNI） | HarmonyOS（NAPI/Node-API） |
|---|---|
| `JavaVM*` 全局 + `JNI_OnLoad` | `napi_env`/模块注册 `napi_module_register`（`NM_MODULE`） |
| `Java_com_bitchat_android_net_ArtiNative_*` 命名绑定 | `napi_property_descriptor` 导出函数表 |
| `jstring`/`jbyteArray` 转换 | `napi_get_value_string_utf8` / `napi_get_arraybuffer` 等 |
| `NewDirectByteBuffer`（SOCKS 端口 int、状态回调） | `napi_create_int32` / `napi_call_function` 回调 ArkTS |
| Kotlin `external fun` | ArkTS `import arti from 'libarti.so'` 声明式导入 |

Rust 侧两条路线：

- **R-A（推荐）**: 保持 arti-android-wrapper 的分层 —— 核心 `extern "C"` 纯 C ABI 面不变，把 JNI 适配层替换为 NAPI 适配层（约 500 行 Rust + 手写 `napi` FFI，或薄 C adapter）。与 Android 版共享同一套核心包装逻辑，双端维护面最小。
- **R-B**: 使用 napi-rs 3.x（已支持 OHOS target）宏生成绑定。省 FFI 手写，但引入额外构建依赖与版本耦合，且 arti 的异步/回调模型仍需手工桥接。

### 3.2 运行时模型

- `tokio` Runtime 持有在原生线程（与 Android 相同），NAPI 只做启动/查询/停止的同步入口 + 事件回调转发 —— 映射直接，无事件循环融合难题。
- 日志回调：Android 的 `ArtiLogListener` 模式可平移为 NAPI `napi_threadsafe_function`（跨线程回调必需，OHOS NAPI 支持 threadsafe function）。

### 3.3 ArkTS 集成面

- `ArtiNative.ets`：`import arti from 'libarti.so'` + 显式接口声明（对齐禁 `any` 约束，回调参数全部显式类型）。
- `ArtiTorManager.ets`：状态机（OFF/STARTING/BOOTSTRAPPING/RUNNING/STOPPING/ERROR + bootstrapPercent）为纯 ArkTS 移植，无技术风险。
- T072 落地后，SOCKS 代理参数化（默认端口 9060）即 Arti 的接入点，无需返工。

---

## 4. 依赖兼容性风险表

| # | 依赖 | OHOS 前景 | 置信度 | 缓解 |
|---|---|---|---|---|
| R1 | `libc` / `mio` / `tokio` | OHOS target 为 linux-like（musl libc），mio 走 epoll；libc crate 已含 ohos 支持 | 高 | PoC 直接编译验证 |
| R2 | `rustls` + `ring` | lock 中 TLS provider 为 ring（无 aws-lc）；ring 0.17.x 已加入 OHOS target 支持 | 中高 | PoC 锁定 lock 内 ring 版本验证；如个别 asm 缺失可降级 C 实现或升级 ring |
| R3 | `openssl-sys` | lock 中存在（来自 arti static 相关 feature 链）；Android 侧经 NDK 编译通过，OHOS 需确认其在最终产物是否实际链接，若是则需 openssl vendor 化交叉编译 | 中 | **PoC 必查项**：`llvm-nm`/`readelf -d` 确认是否真链接；必要时 feature 裁剪 |
| R4 | `rusqlite`（static-sqlite） | bundled SQLite 为纯 C，clang 交叉编译即可 | 高 | 无 |
| R5 | 压缩（zlib/zstd） | C 库，clang 交叉编译 | 高 | 无 |
| R6 | `arti-client` 主体 | 纯 Rust，target 支持跟随 Rust 版本 | 高 | 无 |

**风险定性**: 无阻塞性（blocking）风险；R2/R3 为 PoC 必验项，均为"可绕过"型（换 provider 版本 / feature 裁剪 / vendor 补丁）。

---

## 5. 体积评估

- 当前鸿蒙 HAP（unsigned）实测 **3,340,624 B ≈ 3.19 MiB**（T070 完成后构建产物）。
- 参照 arm64-v8a：`libarti.so`（aarch64-unknown-linux-ohos，同 opt-level=z/LTO/strip 配置）预估 **5.0–6.0 MiB** 未压缩。
- HAP 为 zip 打包，已 strip 的 .so 压缩率约 45–55%，即净增 **约 2.5–3.5 MiB**，HAP 总量预估 **约 6–7 MiB**。
- OHOS 真机仅需 aarch64 单架构（x86_64 仅供模拟器调试，可不打入发布包），优于 Android 4-ABI 分发。
- 结论：体积代价可接受（< 2× 当前包体），不构成否决项；AppGallery 单包限额远高于此。

---

## 6. 合规与分发评估

### 6.1 上架与资质（主要风险区）

| 维度 | 评估 |
|---|---|
| AppGallery 中国区 | **高风险/事实不可行**：内置 Tor 客户端属于 VPN 类能力，商业分发涉及增值电信业务资质与 VPN 监管要求；且 Tor 网络在中国大陆可达性差，产品价值本身受限 |
| AppGallery 海外区 | **可行**：需隐私声明（流量经 Tor 中继）、网络权限说明；有 Orbot 等 Tor 应用上架先例可参照 |
| 鸿蒙工程合规 | native .so（NAPI）为官方支持形态，无额外障碍；HAP 需 AGC 签名（既有流程） |

### 6.2 出口管制与密码监管

- Arti 为 Tor Project 开源（MIT OR Apache-2.0），公开可得源码的加密功能在美国 EAR 下一般适用公开可得/TSU 豁免路径；Arti 自身无出口管制声明。
- 中国大陆《密码法》/商用密码监管对内置境外密码协议的消费 App 属灰色地带，叠加 6.1，进一步支持"中国大陆区不启用/不分发内置 Tor"的边界。

### 6.3 许可证

- Arti：MIT OR Apache-2.0；rustls：Apache-2.0/ISC/MIT；rusqlite：MIT；ring：多许可（均宽松）。**无 copyleft 污染面**，但须随包分发第三方许可清单（ring 的多许可声明尤其要列入 NOTICE）。

### 6.4 页对齐

- Android 16KB 页对齐是 Google Play 要求；HarmonyOS 当前无等价强制要求，但沿用 `-Wl,-z,max-page-size=16384`（§2.2）零成本且前向兼容，建议保留该验收闸门。

---

## 7. 工作量估算（若启动移植）

| 阶段 | 内容 | 估算 |
|---|---|---|
| P1 PoC | aarch64-unknown-linux-ohos 交叉编译 arti-client minimal + NAPI hello 双风险点验证（R2/R3） | 1–2 周 |
| P2 包装层 | JNI→NAPI 适配（R-A 路线）+ ArtiNative.ets + ArtiTorManager.ets 状态机移植 | 2 周 |
| P3 可复现构建链 | 容器化、SDK pin、SOURCE_DATE_EPOCH、符号/对齐/host-path 三闸、SHA256SUMS | 1 周 |
| P4 集成 | 接入 T072 SOCKS 参数（9060）、Settings 开关、引导进度 UI、日志面板 | 1 周 |
| 合计 | | **约 5–6 周**（P1 失败则整体止损，沉没成本 ≈1–2 周） |

---

## 8. 结论（FR-029）

1. **技术可行性：可行（有条件）**。Rust 官方支持 OHOS target，HarmonyOS SDK 提供 LLVM 交叉工具链，JNI→NAPI 为确定性的适配层重写而非架构难题；无阻塞性依赖风险，R2（rustls/ring）/R3（openssl-sys 实链接性）两项需 1–2 周 PoC 实证。
2. **体积：可接受**。aarch64 单架构净增约 2.5–3.5 MiB（HAP 3.2 → 6–7 MiB），且优于 Android 的 4-ABI 分发。
3. **合规：为主要约束，非技术约束**。中国大陆区分发事实不可行（资质+可达性）；海外区分发可行。合规边界建议固化为"Tor 能力仅随海外分发构建启用，中国大陆区构建不内置"。
4. **本期决策：不启动移植**。理由：US15 为 P3/M3；T072（SOCKS 代理参数化，默认端口 9060、开启后禁直连）已提供用户侧替代能力与未来 Arti 接入点；5–6 周投入与合规不确定性在本期不匹配收益。
5. **后续触发条件**（满足其一再立项）：①明确海外分发需求；②PoC 预算（1–2 周）获批。届时按 §7 P1→P4 顺序执行，验收闸门直接平移 Android 链（符号校验、16KB 对齐、host-path 拒绝、SHA256SUMS、可复现构建）。

---

## 附录 A：证据文件清单

- `bitchat_android/.../tools/arti-build/TOOLCHAIN.env` —— 版本与工具链 pin
- `bitchat_android/.../tools/arti-build/Cargo.toml` —— wrapper crate 与 features、release profile
- `bitchat_android/.../tools/arti-build/Cargo.lock` —— 依赖栈实测（libc/mio/rustls/ring/rusqlite/openssl-sys，无 aws-lc）
- `bitchat_android/.../tools/arti-build/build-arti.sh` —— 三验收闸门（L430–459 strip+16KB、L472–480 host-path、L507–566 JNI 符号）
- `bitchat_android/.../app/src/main/jniLibs/` —— 4-ABI .so 体积
- `bitchat_android/.../app/src/main/java/com/bitchat/android/net/ArtiTorManager.kt` —— 状态机与端口 9060
- `bitchat-harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap` —— 当前包体 3,340,624 B
- `spec/bitchat-harmonyos/plan.md` D6 —— Tor 三期决策
- `spec/bitchat-harmonyos/tasks.md` T071/T072 —— 任务定义
