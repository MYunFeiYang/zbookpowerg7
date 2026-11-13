# DeepIdle 功耗审计 · 定稿（2026-11-12）

> **状态：定稿（精简版）。** 本文只保留经复核成立的结论与未闭环线索，可直接作为后续排查的唯一入口。
>
> **修订说明**：删去已被覆盖的旧轮次与「修改方案」表；§8.0 / §8.1 / §8.6 三处经实机复核为错误，已改正。删除的是推理过程，不是证据。
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

##### 2026-11-13 补证（只读取证）：本节判据已满足，线索关闭

> 只追加补证，不改写上文定稿内容。

- `ioreg -c IONVMeController -r -d 1 -w0` 实测 **`"apst" = Yes`**；`IOPowerManagement` 五键全为 `2`（`CurrentPowerState=2` / `MaxPowerState=2`）。
- `ioreg -l -w0` 的 `IOKitDiagnostics → Classes` 实测 **`"NVMePMProxy" = 1`**（同表另有 `"NVMeFix" = 1`）。此前 `ioreg -c NVMePMProxy -r -l -w0` 返回空，是该类不以可枚举 IOService 节点形式出现所致，**不是对象未创建**；按类名直查会误判。
- `ioreg -l -w0` 实测 `"ps-max-latency-us" = <a086010000000000>` = 100000 µs（100 ms），与本节「APST 容忍上限、非禁用」的描述一致。
- 结论：**§7.1 两项判据（`apst` 存在 + `NVMePMProxy` 已创建）同时满足 ⇒ APST 正常，NVMe 不是「1–2 W 耗电源」，本节线索关闭**（>95%）。§9 第 1 步的 ① 已完成。

### 7.2 USB 睡眠供电预算（原 §8.2，C 级）

`SSDT-USBX.dsl`（git `7753b2e1`）实值 `kUSBSleepPowerSupply = 0x13EC (5100)`、`kUSBSleepPortCurrentLimit = 0x0834 (2100)`；文件头注释「**置 0 致唤醒黑屏，勿在本机把 sleep power 设为 0**」，09-29 文档亦记。历史只试过 0（黑屏）与原值，**中间值从未试过**；若睡眠时蓝牙 HS06 / 摄像头 HS04 按预算取电，调低可能省电且不触发黑屏。注意这是「上限」而非实际消耗，无设备取电则收益为零。置信度**中低**，因果未测。一次只改一个值，先验能睡能醒不黑屏，再测 ≥4h %/h；回退=还原 0x13EC。与「整 XHC 断电零收益」不冲突（撤总线 vs 调预算）。

### 7.3 IGPU 端口在线状态（原 §8.3）

`boot-args` 有 `igfxonln=1`；`DeviceProperties` 的 `Pci(0x2,0x0)` 另有 `force-online=01000000`、`complete-modeset=01000000`、`disable-agdc=1`。C4 只评估了 `igfxonln`，**`force-online` 从未单独评估**，可能让显示管线在 S0ix 下误判外接显示器在线。置信度**低**（属性存在是硬证据，无因果证据）。先只读 `ioreg -c AppleIntelFramebuffer -r -l -w0 | grep -iE "online|power|link"` 看睡眠前后端口状态；**不要与 `igfxonln` 一起动**，否则 panic 无法归因。

##### 2026-11-13 补证（源码级）：上述 `force-online` 假设不成立，本节待办结案

> 只追加补证，不改写上文定稿内容。来源均为 `github.com/acidanthera` 上游。

- WEG `WhateverGreen/kern_igfx.cpp` → `IGFX::ForceOnlineDisplay::processKernel` 原文：
  `if (PE_parse_boot_argn("igfxonln", &forceOnline, sizeof(forceOnline))) { enabled = forceOnline != 0; ... } else if (WIOKit::getOSDataValue(info->videoBuiltin, "force-online", forceOnline)) { ... }`
  ⇒ **boot-arg 优先，二者是 `if / else if` 而非叠加**；只要 `igfxonln` 出现在 boot-args，设备属性分支根本不执行。
- 上游 `acidanthera/bugtracker#1471` 维护者原话「**Boot-args has a priority over Propertys.**」交叉验证同一语义。
- 本机 `igfxonln=1` 经 config.plist / README / `shutdownStall` 报告头三处实测一致 ⇒ `DeviceProperties` 里的 `force-online=01000000` **不被读取、不生效**（>95%）。故「`force-online` 从未单独评估、可能让 S0ix 误判外接在线」前提不成立：**无需单独评估，也无理由移除**。真正生效的是 `igfxonln=1`，C4 已评估且移除有 panic 复发风险 ⇒ 保持不动。
- 实现形态：`ForceOnlineDisplay` hook `AppleIntelFramebuffer::getDisplayStatus`，在返回值 `!= 1` 时强制返回 1（online）；该返回值**不写入 IORegistry**。⇒ 本节建议的 `ioreg ... | grep -iE "online|power|link"` **从原理上观测不到该效果**。11-13 睡眠前后两份快照实测 `online`/`link` 键均为 **0 条**，端口对象、`IODisplayConnectFlags`、`CurrentPowerState` 前后完全一致；且睡眠期 CPU 停止本就无法采样。取证路线应换（DEBUG 版 WEG 的 `DBGLOG("igfx", "getDisplayStatus forces %u")` 或 `-igfxfbdump`），但按 §9 不列为可执行改动。
- 版本核对：本机 WEG 实测 **1.7.2**（kext Info.plist）；官方 tags 无 `1.7.2`（最新为 `1.7.1` + 一个无名 tag `ac8b935`）。`1.7.1` tag 与 master 的 `kern_igfx.cpp` 同为 99940 B、该段逻辑逐字一致 ⇒ 1.7.1→master 区间内未变，本机 1.7.2 落在该区间（>90%）。
- 结论：**§7.3 的 C 级候选可关闭**，不产生 EFI 改动；§1「当前无可直接执行、代价可接受的 EFI 改动」进一步加强。

### 7.4 周期性采样 kext 的睡眠期 timer（原 §8.4）

`SMCProcessor` / `SMCSuperIO` / `SMCBatteryManager` 二进制均有 `IOTimerEventSource` + `timerCallback`，同时也有 `registerPowerDriver` / `setIdleTimerPeriod`（`SMCBatteryManager` 还有 `BatteryManager::sleep()`）；`VoodooI2C` 控制器侧有 `setPowerState` / `Going to sleep` / `_PS0`/`_PS3`。⇒ 系统里除已知触控板轮询外还有多条 timer 源，**有**电源管理钩子，但 S0ix 下是否真正停表未见证据。置信度**低**（符号存在 ≠ 睡眠时仍在跑）。验证改用 `pmset -g log` 对照睡眠区间（本沙箱 `log show` 不可用）；本机终端可用 `log show --last 6h --predicate 'process == "kernel"' | grep -iE "SMCProcessor|SMCSuperIO|BatteryManager|VoodooI2C.*sleep"`。

##### 2026-11-13 补证（一次有效睡眠的 `pmset` 记录）：仍不结案

- 11-13 `13:27:17` `Entering Sleep state due to 'Software Sleep pid=50765'` → `13:28:40` `Wake from Deep Idle [CDNVA] due to PWRB/User`，实睡 **83 s**，`WakeTime 2.496 sec`；`pmset -g stats`：**Sleep 1 / Dark Wake 0 / User Wake 1**，睡眠区间内无 DarkWake 行。
- 两条 `Wake Requests`（`UserWake 13:31:11 com.apple.alarm.user-invisible-GaugingMitigationActions,104`、`CSPNEvaluation 15:27:47`）均为计划唤醒，用户 13:28:38 手动唤醒使其未触发。
- **判据边界**：以上只能证明「这些 timer 没有把系统拉出 S0ix」（>95%），**不能证明 timer 在睡眠期停表** —— timer 完全可在唤醒窗口内运行而不产生 DarkWake 记录。`log show --predicate 'process == "kernel"'` 属 kernel 侧符号级证据，AI 沙箱硬禁、未在用户终端执行，故本节「S0ix 下是否真正停表」**仍属未知（<80%）**，不结案，仅上调「无系统级唤醒」这一项的把握度。
- 入睡侧 `Delays to Sleep` 有 `com.apple.bluetooth.sleep is slow(524 ms)`；与 §8 已记录的 `PowerUIAgent MaintenanceWake` 同属入睡前行为，非睡眠中。

##### 2026-11-13 二次补证（VirtualSMC 源码级）：三个 kext 的停表行为并不一致，仍不结案

按上游父页→源码的顺序取证（`acidanthera/VirtualSMC` master，源码路径为 `Sensors/<kext>/*.cpp`，不是先前 404 的 `VirtualSMC/kern_*.cpp`）：

| kext | 源码事实 | 判读 |
|---|---|---|
| `SMCBatteryManager` | `BatteryManager::sleep()` 函数体只有 `timerEventSource->disable()`；`wake()` 末尾 `timerEventSource->enable()`，`checkDevices()` 里还有 `cancelTimeout()` | **显式停表**（源码级 >95%） |
| `SMCSuperIO` | `PMinit()` + `joinPMtree()` + `registerPowerDriver(this, powerStates, 2)`；`setPowerState()` 只调 `dataSource->powerStateChanged(state)`，**不碰 timerEventSource** | 有 PM 状态回调，**未见**停表调用 |
| `SMCProcessor` | 创建 `IOTimerEventSource` + `timerCallback`；源码中 `registerPowerDriver` / `setPowerState` / `disable()` **0 命中** | **没有注册电源管理驱动** |

⇒ 修正 §7.4 正文「三个 kext 都有电源管理钩子」的笼统表述：只有 `SMCBatteryManager` 有显式停表，`SMCSuperIO` 仅转发电源状态，`SMCProcessor` 连 PM 钩子都没有（>90% 源码级）。但**这仍不回答「S0ix 下 timer 是否真正停表」**：源码只能证明代码路径存在，且本机二进制未与 master 源码逐字节核对（版本台账显示本机为 master 构建，>90%，非逐字节验证）；S0ix 是 CPU/芯片组级状态，timer 由内核与硬件统一处理，kext 的 `disable()` 只是显式保险。**故 §7.4 维持未知（<80%）、不结案**，只把「timer 未把系统拉出 S0ix」上调到 >95%、并细化了源码事实。

**工具坑**：`nm` 才能看到这些符号（本机三个 RELEASE 二进制分别命中 4 / 4 / 5 个），`strings` 只有 35 / 194 / 81 行、完全看不到 `IOTimerEventSource` 等符号 —— 正文的「二进制有符号」结论没错，但**用 `strings` 复核会误判为不存在**。

### 7.5 触控板轮询的三条路径（原 §7.2/§7.3，均未执行、均不牺牲手感）

| 路径 | 内容 | 判断 |
|---|---|---|
| A（低风险 / 收益不确定） | 在 `PciRoot(0x0)/Pci(0x15,0x0)` 追加 `force-polling = <01000000>`（VoodooI2C ≥2.5.3 官方支持 per-device property），同时移除全局 boot-arg，只让触控板控制器走轮询 | 本机 DSDT 有 6 个 I2C 控制器、实测枚举 2 个 PCI 控制器但仅 1 个 TPD3 ⇒ 全局 boot-arg 至少让一个无 HID 设备的控制器也跳过了 GPIO 中断注册。**⚠️ 收益可能为零**：轮询 timer 由 satellite 持有，第 2 个控制器无 satellite 本就不产生轮询。写错则触控板退回中断模式 ⇒ 不跟手；必须一次只改、先验手感、可加回 |
| B（理论最优 / 工程量大） | 睡眠时暂停 satellite 轮询 timer、唤醒恢复 | 大概率需改 `VoodooI2CHIDDevice` 源码重编译（需 macOS + Xcode），只作方向记录，不建议当前推进 |
| C（零永久改动 / 建议先做） | 临时移除 boot-arg → 拔电睡 ≥4h 测 %/h → **立刻加回** | 「轮询拉低 PC10、抬高功耗」只是 `e51cd16` 的推测性描述，**从未 A/B**；期间触控板不跟手但只需一个睡眠周期。无显著变化 ⇒ 轮询不是主因、线索关闭；差异显著 ⇒ 才值得投 B |

### 7.6 蓝牙崩溃：按 `process == "bluetoothd"` 全量重抓的取证结论（2026-11-13）

> 对应项目记忆 §6 待办①「先按 `process=="bluetoothd"` 全量重抓崩前日志，再定是否动 EFI」。日志由用户在终端执行 `log show --last 12h --info --debug --style compact --predicate 'process == "bluetoothd"' > ~/bt-full.log` 产出，AI 侧只读分析；**本节不产生 EFI 改动**。

- 样本：**33.4 MB / 203642 行 / `02:43:25–13:17:01`**。启动标志 `Super Server Robot Destroyer` **28 次、26+ 个不同 PID**，其中 **25 个短命 PID** 各仅 12–14 行。
- 短命 PID 的日志模板逐条一致，止于 `[Server.Coex] Registering for WiFi Callback` + `No persisted cache`。完整样本 `09:11:59.814–.823 PID 10642`（12 行）：`main -- xpc_transactions_enable()` → `IOKitWaitQuiet()` → `BT_HCI_TRANSPORT` → `HCI Transport is set to USB` → `Warning: BT driver=` → `Registering for WiFi Callback`。**没有一条到达 HCI 栈初始化**。
- 全日志 `Stack initialization complete` 仅 **3 次**，全部属于稳定 PID `169`，时间 `02:43:29` / `12:32:46` / `12:41:11`（三次开机）⇒ 25 个短命进程**无一次完成 HCI 栈初始化**（>95%）。`LE Scan` / `Local Device Static Random Address` 相关行均出现在 PID 169 的上下文中。
- 重启间隔 `10s×6 → 20/40/80/160/320/640 → 1200s` 封顶（形态观测 >95%；「launchd 指数退避」为推断 ~85%）。12:41 本次开机后 36 分钟内 **0 个新 PID**，PID 169 稳定运行。12 条 Fault 均为三次开机时固定的 4 条组合（`simulated` HCI error + BiomeStorage `Wrong domain`），属启动固有噪声（>90%）。无 `.panic` / `.ips`。
- **上游硬证据（`lshbluesky/IntelBluetoothFirmware` release notes 原文）**：`v2.5.0-d3`(06-14) Tahoe 26.5 LE 修复；`v2.5.1`(06-27) 更新 AX201 等固件；`v2.5.2`(10-18) `Inject LE Data Length Change to clear LE_READY_WAIT_FOR_LENGTH`；**`v2.5.3`(11-03) 只有 `Add BlazarU (hw_variant 0x1d) support and ibt-0093-0041 firmware for 8087:0033`**。本机 `ioreg -p IOUSB` 实测蓝牙 `idVendor=32903(0x8087)` / `idProduct=38(0x0026)` = **AX201 `8087:0026`** ⇒ v2.5.3 对本机**零针对性改动**（>90%）。
- 结论：**待办①把「升 v2.5.3」当目标的理由不成立**（「最新即最优」被 release notes 证伪）。且本次崩前序列发生在 HCI 栈初始化**之前**，与 IntelBTPatcher FAQ 所述「LE Scan 随机地址未设 → 固件返回 0x12 → bluetoothd 立即崩溃」是否同一机制，**属未知（<80%）**：短命进程内无 HCI 命令日志；kernel 侧日志（含 `Resend LE SCAN PARAM` patch 标记）不在本 predicate 内，`Resend LE` 0 命中**不能**据此判定 patch 未生效。要定机制仍需 kernel 侧日志或真 HCI 包（macOS 14.5+ 须先装 Apple Developer Bluetooth logging profile 并重启）。
- ⇒ **不产生 EFI 改动**，§1「当前无可直接执行、代价可接受的 EFI 改动」维持。
- 附：§9 第 1 步三项只读取证现状 —— ① APST 完成并结案（§7.1 补证）；② 睡眠期 timer 仅完成 `pmset` 侧、仍未知（§7.4 补证）；③ IGPU 取证完成且**取证路线作废、假设不成立**（§7.3 补证）。

##### 2026-11-13 追加：`pmset` 时间轴对齐

- 把 25 次短命启动与 `pmset -g log` 逐条对齐：**20:53:47 入睡前 30 秒内 3 次**（20:53:18/28/38）→ 过夜长睡 **11:56:05** → `08:49:52 Wake from Deep Idle` → **唤醒后 6 秒**（08:49:58）首个短命 PID，15 分钟内 **12 次**，随后按 `10→20→40→80→160→320→640→1200s` 退避并封顶，一直持续到 11:52（>95%）。
- 对照组：`12:01:31` 睡 27m42s → `12:29:13` 唤醒，**0 次**；`13:27:17` 睡 83 s → `13:28:40` 唤醒，**0 次**（>95%）。
- ⇒ 硬结论：**这批崩溃集中在过夜长睡唤醒之后**，与 README / 项目记忆 §3「Intel 蓝牙 S0ix 唤醒后崩溃、未根治」一致。「长睡才崩、短睡不崩」只有 3 个唤醒样本，**样本不足，属未知（<80%）**，只作假设；验证需按 §9 做 ≥4h 拔电睡眠的对照 A/B，不据此改 EFI。
- 上游交叉：`betteray/BluetoothFix` 用 sleepwatcher 在唤醒时 `kill bluetoothd` 兜底同症状，但项目记忆 §3 已实测 `launchctl kickstart -k` 后立刻又崩 ⇒ **重启进程类兜底对本机已证伪**（>85%）。`OpenIntelWireless/IntelBluetoothFirmware#145`（AX201 `8087:0026` 睡醒后蓝牙不可用，2020）说明症状非 Tahoe 独有，仅作方向参考、不作判据。

##### 2026-11-13 二次补证：`-btlfxallowanyaddr` 的官方语义与「地址重复」假说

按「查证三查」取到源码级硬证据，用于给待办①的取证方向定型：

- **官方语义（>95%）**：`acidanthera/BrcmPatchRAM` 的 `BlueToolFixup.cpp` 中，`shouldPatchAddress = checkKernelArgument("-btlfxallowanyaddr")` 的条件是 `(Monterey && minor >= 5) || > Monterey`（注释 `12.4 Beta 3+, XNU 21.5`），本机 26.7.3 满足；patch 目标是 `_cs_validate_page` 路由上的地址检查。官方 README 原文：*"On macOS 12.4 and newer versions, a new address check has been introduced in `bluetoothd`, thus an error will be triggered if two Bluetooth devices have the same address. However, this check can be circumvented by adding the boot argument `-btlfxallowanyaddr`."*
- **本机适用性（>90%）**：`BlueToolFixup_Mod.kext` 版本 **2.7.2**，与官方最新 release `2.7.2`(2026-03-20) 同版；二进制含 `-btlfxoff` / `-btlfxdbg` / `-btlfxbeta` / `-btlfxboardid` / `-btlfxallowanyaddr` / `-btlfxnvramcheck` 全套官方 boot-arg；git `edadb45`(10-14) 与 `04012de`(10-19) 提交说明均写明「rename BT/USB kexts … **content unchanged**, skip OCAT version check」⇒ `_Mod` 只是改名，官方语义适用。另：`-btlfxnvramcheck` 源码条件为 `<= Sonoma`，本机 Tahoe 26 不满足，该参数（本机未启用）在此版本**不会生效**。
- **「地址重复」假说：无正向证据，但也证伪不了（未知，<80%）**。`bt-full.log` 全 203642 行检索：`same address` / `duplicate.*address` / `address.*error` / `allowanyaddr` / `btlfx` **全部 0 命中**；96 条 `localAddress` 全是稳定 PID 169 的 `MUC - _concateBTAddresses … localAddress 0x0` 密钥拼接，9658 条 `duplicate` 全是 `[Server.LE.Scan] duplicate filter` 去重过滤，与地址冲突无关。但 `-btlfxallowanyaddr` 是 **kernel 侧** kext patch（`_cs_validate_page`），userspace 日志本就不打印 patch 是否生效 ⇒ **0 命中不能判定 patch 未生效，也不能排除地址检查是退出原因**。
- **与项目记录的关系**：README / 项目记忆 §3 把它记为「缓解 Tahoe 下 Intel 蓝牙 S0ix 唤醒后崩溃」的实测手段（commit `336542b` / `945966c`，且**未根治**）。官方语义是「绕过地址重复检查」，两者**是否同一机制未知（<80%）**；短命进程止于 `Registering for WiFi Callback`（HCI 栈初始化之前），地址检查若发生在此阶段则时间上相容，但没有一条日志证据。
- **⇒ 不产生 EFI 改动**。待办①的取证方向因此收敛：要定机制应看 **kernel 侧 BlueToolFixup / `_cs_validate_page` patch 日志**或真 HCI 包，而不是继续在 `process=="bluetoothd"` 里找；`log show` 在 AI 沙箱硬禁，需用户终端执行，本轮未取。

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
| 常用 kext「比官方 release 高 0.0.1」是否算过期（2026-11-13 核对） | **不是过期，无需按 release 号升级**（>90%，版本级证据非二进制哈希）。本机 10 个 acidanthera 组件全部比最新 release 高一个补丁号：Lilu `1.7.3`/`1.7.2`、WEG `1.7.2`/`1.7.1`、AppleALC `1.9.9`/`1.9.8`、VirtualSMC `1.3.9`/`1.3.8`、NVMeFix `1.1.4`/`1.1.3`、RestrictEvents `1.1.7`/`1.1.6`、VoodooPS2 `2.3.8`/`2.3.7`、IntelMausi `1.0.9`/`1.0.8`、CPUFriend `1.3.1`/`1.3.0`、BrightnessKeys `1.0.4`/`1.0.3`（左本机 / 右官方 release）。上游 master 的 `MODULE_VERSION` 实测 Lilu `1.7.3` / WEG `1.7.2` / AppleALC `1.9.9`，与本机逐字一致 ⇒ 本机为 **master 源码构建**，OpenCore `REL-109-2026-10-27` 同为 nightly。唯一明确落后的是一个 fork：蓝牙三件套 `2.5.0` vs lshbluesky `v2.5.3`，但见 §7.6，不建议动 |

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

## 11. 2026-11-13 补遗：EFI 配置清单体检与优化决策台账

> 承接 11-13 全天 7 轮只读取证，把分散结论收敛成一张可执行决策表。本节仍为**只读 + 文档**，`config.plist` 与 ESP 两份 sha256 全程 `47d9c9bd…900a`，**一字未动**。

### 11.1 配置清单 × 磁盘实物全量交叉核对（>95%）

官方 `ocvalidate` 只校验 schema，**不校验 Path 指向的文件是否真实存在**。按 `config.plist` 四类清单逐项对盘：

| 清单 | 条目 | 文件存在 | BundleIdentifier 不符 | 孤儿文件 |
|---|---|---|---|---|
| `ACPI/Add` | 16（全 Enabled） | 16/16 | — | `ACPI/disabled/`（归档目录） |
| `Kernel/Add` | 31（含 4 个 VoodooI2C PlugIns 内嵌 bundle） | 31/31 | 0 | 0 |
| `UEFI/Drivers` | 8（2 项 Linux 启动 `Enabled=False`） | 8/8 | — | `AudioDxe.efi` |
| `Misc/Tools` | 1 | 1/1 | — | `startup.nsh` |

⇒ **0 缺失、0 路径错、0 BundleID 不符、0 孤儿 kext**。配置里没有「残留/失效条目」这类可清理垃圾 —— 这是「优化 EFI」最容易出收益的盲区，已排除（>95%）。

三个孤儿文件均为良性，**不要删**：

- `Drivers/AudioDxe.efi`：`UEFI/Audio/AudioSupport=False`、`PlayChime=Auto`、`PickerAudioAssist=False` ⇒ 未列入 config 是**有意关闭启动音**，与 `Resources/Audio/` 资源目录并存不矛盾。
- `Tools/startup.nsh`：OpenShell 同目录自动执行脚本，供 S4 memmap 采样用。
- `ACPI/disabled/`：历史 AML 归档目录。

### 11.2 新发现：`MaxKernel=25.99.99` 是跨代升级阻断项（当前无害，>95%）

`Kernel/Add` 中 `SimpleHDA.kext` 与 `AirportItlwm-Tahoe.kext` 均为 `MinKernel=25.0.0` + `MaxKernel=25.99.99`。本机实测 `uname -r = 25.6.0`（macOS 26.7.3 / build 25G342 —— **Darwin 25，不是 26**），落在门槛内；`kextstat` 实证二者均已加载：`cn.laobamac.SimpleHDA (1.0.0)`、`com.zxystd.AirportItlwm (2.4.0)`。

⇒ 当前正常，但 Darwin 26（下一代 macOS）起这两个 kext 会被 OC **静默跳过**，Wi‑Fi 与音频同时失效。项目文档此前 `MaxKernel` 0 命中、无台账 ⇒ 记此一条，**升级大版本前必须复核**。这不是当前改动项。

### 11.3 全会话 EFI 优化候选收敛表

| # | 候选 | 结论 | 把握度 | 处置 |
|---|---|---|---|---|
| 1 | §5 C1–C6 | 逐条否决，无可直接执行且代价可接受的改动 | >95% | **不动** |
| 2 | §7.1 NVMe APST | `apst=Yes` + `NVMePMProxy=1` ⇒ 已启用，非 1–2 W 耗电源 | >95% | 结案 |
| 3 | §7.3 `force-online` | WEG 源码 `if (igfxonln) ... else if (force-online)`，本机 `igfxonln=1` ⇒ DP 注入**不被读取**，是死键 | >95% | 可删但零收益，且删它要动 config ⇒ **保留** |
| 4 | §7.3 IGPU 睡眠前后对照 | 有效深睡 83 s；拓扑/端口/电源状态前后完全一致；ioreg 无 `online`/`link` 属性，该路线**原理上**测不到在线状态 | >95% 观测 | 假设未验证也未证伪，**不动** |
| 5 | `-igfxblr` / `-igfxblt` 并存 | git 硬证据：S4 单变量 E14 加入→删→为匹配唯一能进 S4 的配置加回；上游 #2560 支持 macOS 26.7 起 `-igfxblt` 失效 | >90% | **保留**，不做单变量删除 |
| 6 | 升 WEG + Lilu 治 #967 | 本机 10 个 acidanthera 组件均为 **master 源码构建**，无可升目标 | >90% | 结案 |
| 7 | 蓝牙升 lshbluesky v2.5.3 | 该版只加 BlazarU (`hw_variant 0x1d`)；本机 `ioreg -p IOUSB` 实测 AX201 `8087:0026` ⇒ 零针对性改动 | >90% | **不升** |
| 8 | `-btlfxallowanyaddr` | 官方语义已定案（patch macOS 12.4+ 蓝牙地址重复检查）；patch 在 kernel 侧，userspace 日志 0 命中不可判读 | 语义 >95% / 是否命中 <80% 未知 | **保留** |
| 9 | §7.4 睡眠期 timer | 未把系统拉出 S0ix，但「是否停表」无 kernel 侧日志 ⇒ 未证实 | <80% 未知 | 不结案，不动 |
| 10 | ESP 重复 FAT 目录项 | 两条同 inode 44 / 同 107 B；`boot-log` 判据已判假阴性 ⇒ 运行时影响未知 | <80% 未知 | 修需改 `ACPI/Add[8].Path` + 手工镜像，代价 > 收益 ⇒ **不动**，每次重启监控 |
| 11 | 官方 `ocvalidate` 3 条 `No schema` | 是 **OC-Mod fork 专属键**（`EnableForAll`×2 / `SkipCustomEntryCheck`），本机二进制 `strings` 认识；剥离后 `No issues found` | >95% | **禁止按报错删键** |
| 12 | AppleRTC Kernel Patch 空 `Find` | 官方 `Configuration.tex` Kernel Patch 段：空 Find + 有 Base = `Immediate replacement at Base` | >95% | 合法，结案 |
| 13 | `boot-log` 判据 | 假阴性；「AppleDebug 挤占条目」已由源码（`OcAppleLog.c` 同一 `AddEntry`）+ 本机键名 `boot-log00000…00026` 连续无跳号**排除**；真机制仍未知 | 排除 >90% / 机制 <80% | 见 `tooling-gotchas.md`；②「关 AppleDebug 重读」不再成立 |
| 14 | 配置清单体检（本轮 §11.1） | 0 缺失 / 0 不符 / 0 孤儿 kext | >95% | 无可清理项 |
| 15 | `MaxKernel` 门槛（本轮 §11.2） | 当前正常，跨代阻断 | >95% | 仅记账 |
| 16 | 恢复 OC 日志可观测性（`Target 7→71`） | 唯一能验证 #10 的诊断性改动，需写 ESP | ~85% 方案有效性 | **待用户授权**，见 §11.4 |

### 11.4 唯一建议的可执行下一步（需用户授权，本轮不执行）

按 §9 与「实测前写清三件事」纪律列全：

- **改动**：仅 `Misc/Debug/Target` `7 → 71`（加 `0x40` 文件日志），其余键一律不动；仓库与 ESP 双写，两份 `plutil -lint`。
- **预期形态**：成功 = 重启后 EFI 卷根出现 `opencore-YYYY-MM-DD-HHMMSS.txt`，含 `OCA:` / `OCS:` 行，据此判定 ESP 重复 FAT 目录项是否导致 `Failed to add ACPI` / `only 0 bytes`；失败 = 无文件生成 ⇒ 回退并记为 OC-MOD 行为差异。
- **回滚点**：改回 `Target=7`（`AppleDebug=True` 保持）；git 已提交状态按用户约定不做全量备份，靠 git 历史回滚。
- **不可逆风险**：**无**。不写固件、不改 NVRAM 启动项、不动 ACPI / Kext / 驱动路径；唯一副作用是 ESP 累积日志文件，验证后删除即可。
- **§9 豁免说明（我的判断，~85%）**：「≥4h 拔电 %/h A/B」针对**功耗类**改动；日志位不进入电源管理路径，单变量 + 单次重启即可判读，无需 4h 对照。
- **代价**：一次重启 + 一次手工同步 ESP + 事后清理日志。

### 11.5 结论

**当前 `config.plist` 没有值得改的项（>90%）**。7 轮取证把 C1–C6 与 11-13 新增候选全部收敛为「不动 / 结案 / 未知但无可执行路径」，本轮体检进一步证明配置清单与磁盘实物 100% 对齐。§1 #1 继续成立，EFI 保持 sha `47d9c9bd…900a` 不变。若要继续推进，只有 §11.4 这一个动作有信息增益，且必须由用户点头才写 ESP。

---

**EFI 全程未改动**，`config.plist` sha256 = `47d9c9bd…`（2026-11-12 复核；2026-11-13 全程复核一致）。
