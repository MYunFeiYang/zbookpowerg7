# DeepIdle 功耗审计 · 定稿（2026-11-12）

> **状态：定稿（精简版）。** 本文只保留经复核成立的结论与未闭环线索，可直接作为后续排查的唯一入口。
>
> **修订说明（2026-11-12 20:2x）**：原稿 469 行跨四轮自我推翻，§1–§5 及「修改方案」表已被 §6/§7 全部覆盖或撤销，本次**整体删除**；§8.0、§8.1、§8.6 三处经实机复核为错误，本次**改正**。删除的是推理过程，不是证据——所有仍成立的一手证据已并入下文。
>
> **边界**：全程只读取证，**EFI 未改动**。`EFI/OC/config.plist` sha256 = `47d9c9bd0bf3aef6381c19680be274c922cbc3885aab3660b650f0ee5eab900a`（74285 B，mtime 2026-11-11 12:54；2026-11-12 复核一致），ESP 与 workspace 一致。
>
> **配套产物**：`tools/deepidle-probe.sh`（macOS 侧只读取证草稿）。原稿称「脚本已收录」，**不实**——该脚本被 `.gitignore` 的 `/tools/` 整目录忽略，**未纳入版本库**，删了不可从 git 恢复。本文档本次单独入库。

---

## 1. 结论摘要

| # | 结论 | 把握度 |
|---|---|---|
| 1 | **当前没有任何可直接执行、且代价可接受的 EFI 改动**（C1–C6 逐条否决，见 §5） | >95% |
| 2 | 睡眠功耗基线 **≈3.6 W**，且台账里**已有 4 组可复算的 ≥4h 拔电长样本**，极差仅 0.088 W（2.4%）→ **不需要重测基线，相对 A/B 可判读**（见 §4） | >95% |
| 3 | 原稿「NVMeFix 挂空挡 → NVMe 未进 APST → 1–2 W 级耗电源」是 **ASPM/APST 机制混淆**，推不出该结论；已降级为低置信线索并给出正确判据（见 §7.1） | >95% |
| 4 | 剩余工作按「只读取证先行」：NVMe APST 状态 → 睡眠期 timer → IGPU 端口在线状态；C 级授权项仅 USB 睡眠供电调低与 §7.5 两条路径（见 §9） | ~85% |

---

## 2. 取证口径与边界

- **指标口径**：本机 `powermetrics` 的 C-state 判据已作废。`docs/firmware-facts-ledger.md §10.3` 一手实测出现 `Cores Active 98.88%` / `Avg Num of Cores Active 4.56` / `Package 0 C-state residency 0.00%` 三项互斥 ⇒ macOS 侧无可信 PC10/C-state 遥测；唯一可信锚点是**拔电睡眠 ≥4h 的掉电率 %/h**（配套看 DarkWake 次数与 `IOPMSystemSleepType`）。`docs/tooling-gotchas.md` 亦把该命令列入禁用判据清单。把握 >95%。
- **时效**：原稿 §1–§5 基于截至 2026-11-02 12:30 的 boot-report 快照，而 11-03~11-10 有 **20+ 次 EFI 实验**，`config.plist` mtime 为 11-11 12:54 ⇒ 那批结论已被实验史覆盖，这是删除它们的原因。下文时间线（§6）来自 git 全量历史，逐个 commit 核实过。
- **环境**：原稿写于 Windows 侧（MINGW64），实时 macOS 命令不可用，证据来自仓库内已落盘的 310 份 boot-reports、23,277 行 `pmset -g log`、ACPI 表导出与 git 历史。本轮定稿在 macOS 侧复核了功耗台账与 config 状态。
- **工具限制**：本执行沙箱内 `log show` **不可用**（实测 zsh 缺 `watch` 模块，两次运行均零输出），改用 `pmset -g log` / `ioreg` / `system_profiler`。原稿 §8.1、§8.4 给出含 `log show` 的验证命令在本环境无效，本文已全部替换；**你在本机终端跑 `log show` 不受影响**。

---

## 3. 已闭环 / 无需再动的事实

| 项 | 结论 | 依据 |
|---|---|---|
| XDCI / GPE 0x6D 唤醒风暴 | **已修，非当前问题** | 10-26 `Sleep 57 / DarkWake 56`（53 次 `LPCB XDCI/`，约 45 s 一轮）；git `05142cb`（10-26 20:45）剪掉 GPE 0x6D 唤醒源后 DarkWake 归零。11-01 的 20 次 `/HibernateError` 是 `hibernatemode=25` S4 实验残留，11-02 已回 `hibmode=0` |
| CFG Lock / MSR 0xE2 | **已由 OC 覆盖，无需解锁** | `AppleXcpmCfgLock=True`；HP 固件无 IFR（`tooling-gotchas.md` 三条硬判据全 0），`setup_var` 路径不可靠且有变砖风险 ⇒ C6 不建议执行 |
| SMBIOS | **MacBookPro16,4 正确，不改** | 6C/12T 45W H 系列与机型匹配；`5abf141`（11-05）由 16,2 还原为 16,4，说明已试过并回退。注意 16,4 是 2019 16"（i7-9750H），不是 4 核 Ice Lake 13"（16,2） |
| SSDT-DeepIdle / S3 禁用 | 三件套齐全（131 B：`_TTS`+`SLTP`+`LPS0`+`LXEN`），`IOPMDeepIdleSupported=Yes`、`IOPMSystemSleepType=7` 实测命中；`SSDT-NameS3-disable` 与 `_S3→XS3` patch 严格配套 | git + config 实读 |
| pmset 收紧 | 已到位 | `womp=0 / powernap=0 / tcpkeepalive=0 / standby=0 / autopoweroff=0 / hibernatemode=0 / networkoversleep=0`；每条 Sleep 日志带 `TCPKeepAlive=disabled` |
| 雷电 JHL7540 / SD 读卡器 / 以太网 I219-LM | 无剩余嫌疑 | 雷电：`SSDT-thunderbolt-nhi-disable` + Kernel/Block 封板；EP02/TXHC ASPM 注入够不到下游已删，TXHC 由 `AppleUSBXHCITR` 自带 L1。SD：DSDT 38,295 行中 `SDHC/SDXC/RTSX` 全 0 命中。I219-LM：`IntelMausi 1.0.9` + `womp=0`，`LinkCap=0` 注入 ASPM 无意义 |
| 常态 DarkWake | **0**，高功耗不是唤醒频率造成 | `hang-2026-09-28-clock-jump.md:337`「现 5.5–7.1 %/h 是 DarkWake 0 的值」；恢复 Power Nap 反而更耗电 |
| `-vi2c-force-polling` | **保留**（手感优先），不是残留参数 | `e51cd16` 明文：换 16,2 后 ELAN 固件中断上报率偏低、GPIO 中断下触控板不跟手，恢复轮询换手感，代价是拉低 PC10 / 抬高 DeepIdle 功耗。**用户 11-12 实测去掉后触控板不跟手**，证伪了「16,4 还原后前提已消失」的推断 |
| CPUFriend | **已启用且不可停用** | `1b61341` 加入（EPP=Max Power Saving 最省电档）；11-03 21:01 禁用 → 11-04 08:59 重新启用（DeepIdle 修复已稳定通过）。再做一次停用 A/B 无信息价值且可能重现睡眠唤醒故障。注：data provider 基于 MBP16,2 频率 plist 生成、与当前 16,4 错配（`Frequencies{3800,4100}` 与 i7-10750H 不符），但 EPP 已是最省电档 ⇒ **列为待查，不是改动项** |
| XHC 整表断电 / 睡眠关 Wi-Fi-BT | **实测零收益且破坏蓝牙，降级** | `bba9c58`（11-10）：整 XHC `_STA=0` 得 3.612 W vs 带表 3.669 W（差值在噪声内），并导致唤醒后蓝牙丢失，已整表回退；随后 `336542b`/`945966c` 连做两次 BT 唤醒崩溃修复 |

---

## 4. 功耗基线（更正原 §8.0）

**原稿错误**：称「台账只有 3 条记录、3.612/3.669 W 不在台账、无法复算，必须先做一次干净 ≥4h 基线」，并据此把「校准尺子」列为第一优先。

**实测更正**：同目录 `docs/backups/sleep-power-samples/points.jsonl`（7118 B，11-11 14:01 更新）**就是 `tools/sleep-power-measure.sh` 的正式数据源**（脚本第 27 行 `POINTS="$STORE/points.jsonl"`）。原稿只看了两个 `.md` 汇总表，漏看了 jsonl 原始打点。逐组复算：

| 区间（拔电 → 唤醒） | 时长 | ΔmAh | 平均电压 | 复算功率 |
|---|---|---|---|---|
| 11-04 19:36 → 11-05 08:50 | 13.24 h | 4414 | 11.101 V | **3.700 W** |
| 11-05 21:34 → 11-06 08:52 | 11.29 h | 3743 | 11.114 V | **3.683 W** |
| 11-06 18:38 → 11-07 08:47 | 14.15 h | 4736 | 10.958 V | **3.669 W** |
| 11-09 21:09 → 11-10 08:55 | 11.76 h | 3823 | 11.111 V | **3.612 W** |

其中 3.683 / 3.669 / 3.612 W 三组与 11-06、11-09 工作日志逐字吻合（Δ3743 mAh、11.76h/Δ3823 mAh / 11.111 V）⇒ 这些数字**本来就在台账里、可复算**，把握 >95%。

- 4 组跨 6 天、不同 EFI 配置，极差 **0.088 W（2.4%）** ⇒ **相对 A/B 的重复性远好于原稿说的 ±30%**。
- `tooling-gotchas.md:188` 的 ±30% 是电池遥测**绝对刻度**漂移（`SystemPower` 1507 笔全 NULL、`MaxCapacity` 在 5372~5736 间漂、相邻两天差 31%），**不等于相对比较不可判读**。同协议配对 A/B 只要同负载、同电源条件即可。
- 结论：**不需要重测基线**；原稿「不校准尺子则后面所有 A/B 都不可读」不成立。若要对绝对刻度，可用墙插功率计同负载校一次，但那是可选增强，不是前置条件。

---

## 5. C1–C6 逐条否决（当前无可执行的 EFI 改动）

| 候选 | 否决理由 |
|---|---|
| C1 停用 CPUFriend | 11-03→11-04 已 A/B 并回退，结论「重新启用」 |
| C2 补 `SSDT-PCI0.LPCB-Wake-AOAC` 的 `_PS0`/`_PS3` | 219 B 版本 `362db2b` 在 10-19 全 EFI 回滚时被有意撤掉，回退后睡眠唤醒正常、DarkWake 归零 ⇒ 无因果证据。当前 175 B 确实缺 OC-Little 标准配套，属缺口非主因 |
| C3 移除 `-vi2c-force-polling` | **用户实测证伪**：去掉后触控板不跟手；`e51cd16` 的「手感优先」取舍继续有效 |
| C4 移除 `igfxonln=1` | 该参数用于压制 IGPU `SafeForceWake` / #967 panic，移除有复发风险 |
| C5 睡眠关 Wi-Fi / BT | 更彻底的整 XHC 断电实测零收益且导致蓝牙丢失，11-10 又连做两次 BT 唤醒崩溃修复 ⇒ 「预期降幅最大」不成立，风险显著上调 |
| C6 解锁 CFG Lock | 已由 `AppleXcpmCfgLock` 覆盖；HP 无 IFR，风险大于收益 |

**⇒ 当前没有任何可直接执行且代价可接受的 EFI 改动（把握 >95%）。** 下表「修改方案」及原稿 §1–§5 的推理过程已整体删除，避免后来者误按执行。

---

## 6. 关键 git 时间线（逐个 commit 核实）

| commit | 时间 | 内容与结论 |
|---|---|---|
| `3aa1a9b` | 11-03 15:13 | OCAT 更新 Lilu 1.7.3 / VoodooI2C 2.9.1 |
| `e51cd16` | 11-03 19:54 | 试 MacBookPro16,2 → ELAN 中断下触控板不跟手，**主动加回 `-vi2c-force-polling`**；原文承认「代价：拉低 PC10 驻留率、抬高 DeepIdle 待机功耗，用户选择手感优先」 |
| `1b61341` | 11-03 20:40 | 加入 CPUFriend 1.3.0 + CPUFriendDataProvider（基于 MBP16,2 X86 频率 plist，EPP 最省电档）；`PowerTimeoutKernelPanic=true` |
| `a702367` → `60eeb02` | 11-03 21:01 → 11-04 08:59 | 临时禁用 CPUFriend 隔离睡眠唤醒故障 → **重新启用**（DeepIdle 修复已稳定通过） |
| `b0c4a46` | 11-03 21:18 | 对齐 SSDT-DeepIdle 到 131 B + 补回 NameS3-disable / `_S3→XS3`，修复睡眠无法唤醒 |
| `05142cb` | 10-26 20:45 | 剪掉 GPE 0x6D 唤醒源（XDCI / XHC / GPE 三条补丁），止住 3s DarkWake 循环 |
| `5abf141` | 11-05 10:24 | SMBIOS 由 16,2 还原为 **16,4** |
| `8d11a19` → `bba9c58` | 11-04 14:20 → 11-10 09:00 | SSDT-XHC-Sleep（睡眠时整 XHC `_STA=0`）→ **因唤醒后蓝牙丢失整表回退**；实测对 S0ix 功耗零收益（3.612 vs 3.669 W） |
| `336542b` / `945966c` / `0dcd835` | 11-10 19:27~20:37 | XHC `built-in` 注入 + `-btlfxallowanyaddr` + 已有 NVRAM 键，修 Tahoe Intel BT S0ix 唤醒崩溃；CPUFriend 1.3.0→1.3.1、VoodooI2C 系列更新 |

---

## 7. 剩余未闭环线索

### 7.1 NVMe APST 状态（更正原 §8.1）

**原稿错误**：由 `pci-aspm-custom` 0 命中推出「NVMeFix 挂空挡 → NVMe 未进 APST → 1–2 W 级耗电源，量级足以解释 3.6 W」，并把 §2.2 的「NVMe 未见异常」上调。

**更正**（依据 acidanthera/NVMeFix 官方 README，上游仓库可作判据）：
- `pci-aspm-custom` 是 **PCIe 链路层 ASPM** 被 NVMeFix 改写后的可见标记；**APST 是 NVMe 控制器自主电源状态，属于另一套机制**，启用状态由 `IONVMeController` 的 **`apst` 属性**报告，主动电源管理成功会创建 **`NVMePMProxy`**。
- `ps-max-latency-us` 是 **APST 容忍上限**（本机 100000 µs = 100 ms，宽松但允许 APST；设 `0` 才是禁用）。
- 本机走的是 OC 注入 `pci-aspm-default` 的日常用法，`pci-aspm-custom` 不出现**属预期**，推不出 APST 失效。
- **证据时效问题**：原稿引用的 `docs/boot-time-audit.md` §六（09-22）与 `docs/sleep-wake-failure-2026-09-29.md` §十「已排除的变量」/ASPM 条目（09-29）比 §0 自己批评过的 11-02 boot-report **还老一个半月**；§6.1 正是因「取证时效已过时」推翻 §1–§5，§8.1 却用更老的证据直接下当前结论，方法论自相矛盾。且这两份文档被 `.gitignore` 排除、未入库（注：引用改用章节号，因 2026-11-13 文档整理后行号已漂移）。

**结论**：NVMe 是否进 APST **属未知（<80%）**，不能作为「1–2 W 耗电源」。正确验证（只读取证，把握 >95% 判据正确）：
```
ioreg -c IONVMeController -r -d 1 -w0 | grep -iE "apst|NVMePMProxy|IOPowerManagement|CurrentPowerState"
ioreg -l -w0 | grep ps-max-latency-us
```
若 `apst` 存在且 `NVMePMProxy` 已创建 ⇒ APST 正常，这条线索可关闭。

### 7.2 USB 睡眠供电预算（原 §8.2，C 级）

`SSDT-USBX.dsl`（git `7753b2e1`）实值 `kUSBSleepPowerSupply = 0x13EC (5100)`、`kUSBSleepPortCurrentLimit = 0x0834 (2100)`；文件头注释「**置 0 致唤醒黑屏，勿在本机把 sleep power 设为 0**」，09-29 文档亦记。历史只试过 0（黑屏）与原值，**中间值从未试过**；若睡眠时蓝牙 HS06 / 摄像头 HS04 按预算取电，调低可能省电且不触发黑屏。注意这是「上限」而非实际消耗，无设备取电则收益为零。置信度**中低**，因果未测。一次只改一个值，先验能睡能醒不黑屏，再测 ≥4h %/h；回退=还原 0x13EC。与「整 XHC 断电零收益」不冲突（撤总线 vs 调预算）。

### 7.3 IGPU 端口在线状态（原 §8.3）

`boot-args` 有 `igfxonln=1`；`DeviceProperties` 的 `Pci(0x2,0x0)` 另有 `force-online=01000000`、`complete-modeset=01000000`、`disable-agdc=1`。C4 只评估了 `igfxonln`，**`force-online` 从未单独评估**，可能让显示管线在 S0ix 下误判外接显示器在线。置信度**低**（属性存在是硬证据，无因果证据）。先只读 `ioreg -c AppleIntelFramebuffer -r -l -w0 | grep -iE "online|power|link"` 看睡眠前后端口状态；**不要与 `igfxonln` 一起动**，否则 panic 无法归因。

### 7.4 周期性采样 kext 的睡眠期 timer（原 §8.4）

`SMCProcessor` / `SMCSuperIO` / `SMCBatteryManager` 二进制均有 `IOTimerEventSource` + `timerCallback`，同时也有 `registerPowerDriver` / `setIdleTimerPeriod`（`SMCBatteryManager` 还有 `BatteryManager::sleep()`）；`VoodooI2C` 控制器侧有 `setPowerState` / `Going to sleep` / `_PS0`/`_PS3`。⇒ 系统里除已知触控板轮询外还有多条 timer 源，**有**电源管理钩子，但 S0ix 下是否真正停表未见证据。置信度**低**（符号存在 ≠ 睡眠时仍在跑）。验证改用 `pmset -g log` 对照睡眠区间（本沙箱 `log show` 不可用）；本机终端可用 `log show --last 6h --predicate 'process == "kernel"' | grep -iE "SMCProcessor|SMCSuperIO|BatteryManager|VoodooI2C.*sleep"`。

### 7.5 触控板轮询的三条路径（原 §7.2/§7.3，均未执行、均不牺牲手感）

| 路径 | 内容 | 判断 |
|---|---|---|
| A（低风险 / 收益不确定） | 在 `PciRoot(0x0)/Pci(0x15,0x0)` 追加 `force-polling = <01000000>`（VoodooI2C ≥2.5.3 官方支持 per-device property），同时移除全局 boot-arg，只让触控板控制器走轮询 | 本机 DSDT 有 6 个 I2C 控制器、实测枚举 2 个 PCI 控制器但仅 1 个 TPD3 ⇒ 全局 boot-arg 至少让一个无 HID 设备的控制器也跳过了 GPIO 中断注册。**⚠️ 收益可能为零**：轮询 timer 由 satellite 持有，第 2 个控制器无 satellite 本就不产生轮询。写错则触控板退回中断模式 ⇒ 不跟手；必须一次只改、先验手感、可加回 |
| B（理论最优 / 工程量大） | 睡眠时暂停 satellite 轮询 timer、唤醒恢复 | 大概率需改 `VoodooI2CHIDDevice` 源码重编译（需 macOS + Xcode），只作方向记录，不建议当前推进 |
| C（零永久改动 / 建议先做） | 临时移除 boot-arg → 拔电睡 ≥4h 测 %/h → **立刻加回** | 「轮询拉低 PC10、抬高功耗」只是 `e51cd16` 的推测性描述，**从未 A/B**；期间触控板不跟手但只需一个睡眠周期。无显著变化 ⇒ 轮询不是主因、线索关闭；差异显著 ⇒ 才值得投 B |

---

## 8. 已复核「不是遗漏」的点（避免重复排查）

| 项 | 复核结论 |
|---|---|
| EP02 / TXHC ASPM L1 | `aspm-verification-2026-10-23.md §四` 已闭环：OC 注入够不到雷电下游交换机，两条死配置已删；TXHC 由 `AppleUSBXHCITR` 驱动自带 L1。15 个 `LinkCap=0` 的 PCH 集成端点注入无意义 |
| FanControlKExt 的 1–2s 轮询 | 源码/产物只在 `docs/fan-kext/`，**不在 `EFI/OC/Kexts/`、不在 `Kernel/Add`** ⇒ 未加载，不是当前耗电源 |
| SimpleHDA #6 音频空转（6.6→3.7 W） | 10-27 实测本机 `AFGLowPowerState=<000000000000>`=0，前提不成立 ⇒ 已关闭 |
| `com.apple.obc` 等高频断言（1090 次） | `pmset.txt:106-111` 实读为 `PowerUIAgent` 的 `MaintenanceWake [System: BGTask SRPrevSleep kCPU]`，属**入睡前**维护，非睡眠中；与 DarkWake=0 一致 |
| `system-overhead-audit.md` 常驻软件清单 | 影响的是**亮屏日常开销**（远程控制×2、清理工具、`WindowServer`/`apfsd` 50% CPU），与 DeepIdle 是两条轴，不应混入待机 A/B |
| 两条常驻 USB 内核断言（BT HS06 + 摄像头 HS04） | 不阻止入睡（`PreventSystemSleep=0`）；整 XHC 断电实测零收益 ⇒ 「USB 断言常驻是功耗主因」诊断强度已下调 |

---

## 9. 执行顺序（更正原 §8.6）

**原稿错误**：把「先做一次干净 ≥4h 基线校准尺子」列为最高优先级，并据 §8.1 把「NVMeFix 是否生效」排第二。前者是重复劳动（§4 已有 4 组可复算长样本），后者判据错误（§7.1）。

**更正后的顺序**（把握 ~85%）：

1. **只读取证先行，三项都无需改 EFI、在 macOS 侧即可做**：
   - ① NVMe APST 状态：按 §7.1 的正确命令抓 `apst` / `NVMePMProxy`，若正常则线索直接关闭；
   - ② 睡眠期 timer：`pmset -g log` 对照睡眠区间（§7.4）；
   - ③ IGPU 端口在线状态：睡眠前后 `ioreg -c AppleIntelFramebuffer`（§7.3）。
2. **若三项均无异常**，再考虑 C 级授权项：USB 睡眠供电中间值（§7.2）、§7.5 路径 C 的临时 A/B（零永久改动，建议优先于 A）。
3. **任何 EFI 改动都要单变量 A/B**：一次只改一处，配 ≥4h 拔电 %/h 对照，先验能睡能醒/手感/无 panic，保留明确回退点。cfg 改前打印 diff（按用户约定：git 已提交的状态不做全量备份，回滚靠 git 历史）。

---

## 10. 待用户拍板

1. 是否执行 §9 第 1 步的三项只读取证（可整理成一条只读脚本一次性回传）；
2. 是否跑 §7.5 路径 C 的临时轮询 A/B（牺牲一个睡眠周期的手感）；
3. USB 睡眠供电调低（§7.2）属 C 级，需明确授权；
4. `tools/deepidle-probe.sh` 目前被 `.gitignore` 忽略、未入库，是否要用 `git add -f` 纳入，避免文档引用不入库文件。

---

**EFI 全程未改动**，`config.plist` sha256 = `47d9c9bd…`（2026-11-12 复核）。
