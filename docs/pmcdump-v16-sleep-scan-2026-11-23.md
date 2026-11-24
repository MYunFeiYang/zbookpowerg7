# PMCDump v1.6：修好从未生效的睡眠钩子（2026-11-23 19:45-19:55）

> 触发：用户确认 BIOS `USB Charging Port Function` 本来就是关的 ⇒ 该路线作废；转查 macOS 侧时发现一个**从未真正执行过**的实验。

## §1 发现：sleep_log 一直是 "never run"

运行时状态（`sysctl -a | grep pmcdump`）：

| sysctl | 值 | 含义 |
|---|---|---|
| `debug.pmcdump.sleep_gate` | **1** | 声称"睡眠期把 6 个设备设 D3"已启用 |
| `debug.pmcdump.sleep_log` | **never run** | 该钩子**一次都没执行过** |
| `debug.pmcdump.ltr_ignore` | 0 | 重启归零（历史 §67 测过 8280） |
| `debug.pmcdump.maxbusdelay` | 75000 | 只读 oid（§1527），且睡眠入口会被 `xcpm_restore_mbd` 清零（§1529） |

`sleep_log = never run` 是判决性的：**v1.4.0 → v1.4.5 五个版本的睡眠钩子全部未触发**。git 历史三次尝试的失败原因各不相同：

1. v1.4.0 `PMinit + registerPowerDriver`：缺 `joinPMtree`，standalone node 不在 PM 传播路径；
2. v1.4.1 `IOService::registerInterest(gIOGeneralInterest)`：被 `IOPMrootDomain::systemMessageFilter` 静默丢弃（只放行 root domain 自己创建的 `IOPMServiceInterestNotifier`）；
3. v1.4.2 改为在 `getPMRootDomain()` 上注册：仍然 never run。

⇒ **"睡眠入口把 I2C0/I2C1/SERIO/XHC/CNVW/HDEF 强制拉 D3"（Windows S0ix 模型）这个实验，本机从未真正跑过**。此前若记作"阴性"，属 confounded（变量没生效），不是 negative。

## §2 为什么这条现在值得补

- 新证据（同日 IOReport）：`PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` 与 `PKGC_C3_ENTRANCE_COUNTER` 三次采样严格相等（732 → 睡眠 133s → 60,801），说明每次封装落 C3 都是"想关 BCLK，被 PCH 侧 IOSF 未 block 打回"。
- IOSF 能否 block 的直接前提是 **PCH 内各 IP 是否都进了 D3**。而本机**从未观测过睡眠入口各设备的 D-state**——`sleep-scan` 属性从未发布过。
- 已封死的对照：LTR 三路（设备侧注入 / PMC 聚合 `ltr_ignore=8280` / ILTR override）全阴性（§64/§66/§67）；`0xE2`、`maxbusdelay` 阴性或对睡眠期无效。

## §3 v1.6 改了什么

1. **注册路径**：改为 xnu 文档点名的三步 `PMinit() → provider->joinPMtree(this) → registerPowerDriver(this, gPmStates, 2)`，并实现 `setPowerState(ordinal, device)`（ordinal 0 = 系统睡眠，1 = 唤醒），`stop()` 补 `PMstop()`。保留原 `registerInterest` 作为冗余路径（两条都触发时 `sleepGate` 幂等）。
2. **默认改为纯诊断**：`gSleepGateMode` 默认 1 → **0**；`sleepGate()` 新增 `doGate` 参数，`mode=0` 时**照常扫描但一个设备都不写**，只发布 `sleep-scan`。
3. 产物：`~/automation-workspace/pmcdump-kext/PMCDump.kext`，版本 1.6.0，49,888 B，sha256 `fb967943f3598eb2c772f4ea6eb81213a7d60de7e9009bd2ec016e8991bcdc98`，Info.plist lint OK。符号核对：`__ZN7PMCDump13setPowerStateEmP9IOService` 存在；`PMinit/joinPMtree/registerPowerDriver` 为动态查找（正常 kext）。

## §4 装上后能拿到什么

`sleep-scan` = 睡眠入口那一刻，**每一台 IOPCIDevice 的冻结快照**：`dev`(vendor/device)、`pmcsr`(PM 能力寄存器，低 2 位即 D-state)、`ltr`(扩展能力 0x0018 真值)、`linkctl/linksta`(ASPM 位 + 链路状态)、`cls`(class code)。

判读规则：**睡眠入口仍在 D0 且带 LTR 的设备 = 嫌疑**。这一步是只读诊断，不改任何设备功能。

## §5 把握度

| 判断 | 把握度 | 依据 |
|---|---|---|
| sleep_gate 从未生效（历史实验 confounded） | **>95%** | `sleep_log=never run` + 三版 git 提交信息自述失败 |
| 缺 `joinPMtree` 是根因 | **~85%** | SDK `IOService.h:1633` 明确三步组合；v1.4.0 注释自述 setPowerState 未触发 |
| v1.6 能收到 setPowerState | **~85%** | 文档路径正确 + 编译符号齐全；黑苹果环境未实测 |
| 睡眠入口确有 IP 滞留在 D0 | **<80% 未知** | 这正是本实验要测的，尚无数据 |

## §6 热加载尝试失败（2026-11-23 20:09，用户实际执行 kextunload/kextload）

用户的执行结果可以从内核日志完整还原（`log show --last 40m --predicate 'eventMessage CONTAINS[c] "pmcdump"'`）：

```
20:09:56.571 kernelmanagerd  unloadExtensions: Unloading identifiers: ["local.pmcdump"]
20:09:56.571 kernelmanagerd  Unable to find the extension to unload (local.pmcdump) in auxKC, looking in system/bootKC
20:09:56.572 kernel           Can't remove kext local.pmcdump; unsupported by cache.
20:09:56.680 kernelmanagerd  Loading paths: ["/Users/thinkway/automation-workspace/pmcdump-kext/PMCDump.kext"]
20:09:56.681 kernelmanagerd  requestedExts: [Kext local.pmcdump v1.4.5 in loaded boot kernel collection]
20:09:56.682 kernelmanagerd  loading extension from in-kernel fileset: local.pmcdump
```

判读（>95%）：
1. 这个 kext 是被 OpenCore 注入 **BootKC（boot kernel collection）**的，**BootKC 里的 kext 不支持卸载**（`unsupported by cache`）。
2. 卸载失败后，`kextload <新路径>` 被 kernelmanagerd 解析成「已经在 bootKC 里的同 identifier kext」，于是直接返回、不加载新二进制。

⇒ **结论：任何「热替换」都不可行，v1.6.x 只能进 ESP + 重启生效。**

## §7 一个反证：内核日志显示睡眠消息本来"发到了" local.pmcdump

同一次日志抓取里，每次睡眠/唤醒都有：

```
19:18:17.117 kernel  PMRD: kIOMessageSystemWillSleep[119] to local.pmcdump
19:20:56.005 kernel  PMRD: kIOMessageSystemWillPowerOn to local.pmcdump
19:20:58.491 kernel  PMRD: kIOMessageSystemHasPoweredOn to local.pmcdump
```

（13:09、13:26、17:59、18:23 同样是三条一组。）

这条日志出自 xnu `IOPMrootDomain::traceNotification()`，位于 `IOServicePM.cpp:pmTellClientWithResponse` 调用 `messageClient()` **之前**，即"正在把消息派发给这个 notifier"。

两个来源互相矛盾：
- 日志：消息派发到了 `local.pmcdump`；
- 现场：`sleep_log` 仍是 `never run`，且 ioreg 里**没有** `sleep-scan` 属性（v1.4.3 起只要有扫描就会发布）。两处都是我们自己的代码写的，任何一条路径跑过都会留下痕迹。

⇒ **"notifier 收不到消息"这个解释不完整**（把握度降到 <80%，标未知）。能确定的只有事实本身：**这套路径在本机从未产出过数据**。

因此 v1.6.x 不去猜哪条路对，改为**两条路都注册 + 都计数**（见 §8），让机器自己回答。

## §8 v1.6.1 改动（相对 §3 的 v1.6.0）

| 项 | v1.6.0 | v1.6.1 |
|---|---|---|
| 电源管理注册 | `PMinit → provider->joinPMtree → registerPowerDriver` | 改为 **root domain 优先**：`rd->joinPMtree(this)`（`IOResources` 这个 provider 可能根本没有 PM 节点），provider 仅作兜底 |
| 通知路径 | setPowerState + root-domain registerInterest | 不变（双路并存） |
| 可观测性 | 只靠 `sleep_log` / `sleep-scan` | 新增 ioreg 属性：`interest-hits` / `powerdriver-hits` / `pm-last-ordinal` / `pm-join-root` / `pm-join-provider` / `pm-reg-driver` |
| 默认模式 | `sleep_gate=0`（纯诊断） | 不变 |

计数器由 5 秒定时器写进属性，所以**唤醒后定时器一恢复就能读到真值**，不依赖 IOLog（实测本机 `IOLog` 根本不进 unified log，`log show` 里搜不到 kext 自己的任何一行）。

产物：`PMCDump.kext` 50,104 B，sha256 `763e66e04223f10a2872669f34b556eb8e3e5fab9c6544bc848c705bcaa15e79`，`CFBundleVersion 1.6.1`。

## §9 部署与回退

已部署（三处一致，sha 均为 `763e66e0…`）：

1. 构建目录 `/Users/thinkway/automation-workspace/pmcdump-kext/PMCDump.kext`
2. 仓库镜像 `EFI/OC/Kexts/PMCDump.kext`
3. ESP `/Volumes/ESP/EFI/OC/Kexts/PMCDump.kext`

`config.plist`（仓库与 ESP 两份，sha `d162b859…` 一致）里 `Kernel:Add[31].Comment` 由 `V1.4.5 …` 改为 `V1.6.1 …`，只改注释字段，`plutil -lint` 通过。

回退：旧版 1.4.5 已字节级备份在 `/Users/thinkway/automation-workspace/pmcdump-kext-backup-1.4.5/`（sha `4809f0db…`），`ditto` 回 ESP 即可。

⚠️ 部署时踩到一次已有记录的坑：往 ESP 写完并当场 sha 复验通过后，**几秒内又被 FreeFileSync 从仓库反向覆盖回去**（`EFI/OC/sync.ffs_lock` 出现，ESP 侧变回 `4809f0db…`）。重写后连测两次才稳定。⇒ ESP 写入必须以「间隔 ≥5 秒的两次 sha 复验」为准，不能只验一次。

## §11 v1.6.1 首次真实睡眠结果（2026-11-23 20:38:23 → 20:40:10，107 s）

### 11.1 回调确实被调用了（历史首次）

| 计数器 | 开机 20:35 | 睡后 20:40 | 判读 |
|---|---|---|---|
| `powerdriver-hits` | 1 | **3** | 睡眠一次 + 唤醒一次 ⇒ `setPowerState` 真被调用 |
| `pm-last-ordinal` | 1 | 1 | 最后一次是唤醒（ordinal 1），与事实一致 |
| `interest-hits` | 21 | 38 | interest 路径同时活着 |
| `pm-reg-driver` / `pm-join-root` | 0 / 0 | 0 / 0 | 注册成功、挂 root domain |

⇒ 「`rd->joinPMtree + registerPowerDriver + setPowerState`」这条路在本机**确实通了**（1.4.0~1.4.5 全程 never run 的真空档被补上，>95%）。

### 11.2 `sleep-scan` 已发布，但**全部 D0**（不可直接判读）

25 台设备（比开机时的 22 台多了 XHCI 06ed、GbE 0d4e、TB xHCI 15e9），PMCSR 解码结果：

- D0：21 台（含 `06ed` xHCI、`0d4e` I219-LM、`06c8` HDEF、`06e8/06e9` I2C、`06e0` MEI、`15e8` TB NHI、`15e9` TB xHCI、四个 `15e7` 根端口、NVMe）
- 读不到（PMCSR=0xFFFF）：4 台（`9b54` host bridge、`068e` LPC、`06a3` SMBus、`06a4` SPI）

**判读（<80%，标未知）**：`setPowerState(0)` 在电源管理树里被调用得**过早**——此时驱动栈尚未开始把设备拉下去。因此这份快照既不能证明"设备赖在 D0"，也不能证明"设备会进 D3"。**结论：采样时机不对，不是数据结论。**

### 11.3 顺带做实的一件事：清醒态根本不尝试 PC6

关屏（`pmset displaysleepnow`，非系统睡眠）75 秒：`PKGC_C3_ENTRANCE` 13388 → 13388、`IOSF_NOT_BLOCKED` 13388 → 13388、`PKGC_C6_ENTRANCE` 0 → 0。**零增量。**

⇒ macOS 在清醒空闲（含关屏）状态下**完全不发起**封装 C6 尝试；BCLK 关断这一层只在系统睡眠期发生。这条把"睡眠 3.6W"与"PC3→PC6 被 IOSF 挡回"的绑定关系钉死。

### 11.4 第四次独立验证 1:1

本次开机至 20:40：`PKGC_C3_ENTRANCE = 13,388`、`PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED = 13,388`（**严格相等，第四次**）；`PC6/C7/C8/C9/C10` 全 0；5 个 DEMOTE 原因里其余 4 个、10 个 RESOLVE 原因全部为 0。

另记两条原始计数（同批，供后续比对）：`PKGC_BREAK_CAUSE_SB_RING` = 35,415 / 61,300（sideband ring 打断，居首）、`PKGC_BREAK_CAUSE_DOUBLE_STRIKE` = 64,770。这两个数大于 C3 进入次数，说明它们不是"每次进入一次"的 1:1 计数，量纲待定（<80%）。

### 11.5 v1.6.2：把单点快照改成过渡期连续采样

改动（`PMCDump.cpp`）：

| 项 | v1.6.1 | v1.6.2 |
|---|---|---|
| 采样次数 | 1 次（`setPowerState(0)` 内） | **首次 + 每 200 ms 一次，最多 16 轮** |
| 设备枚举 | 每轮重新 `getMatchingServices` | 首轮枚举后 retain 缓存，索引稳定 |
| 后续轮次 | — | 只读 PMCSR（不碰扩展配置空间），降低拆卸期风险 |
| 新增属性 | — | `sleep-scan-first`（首轮全量）、`sleep-scan`（末轮）、`sleep-scan-d3mask`（每轮 D3 位图，uint64/轮）、`sleep-scan-passes`（实际轮数） |
| 发布时间 | 睡眠入口 | **唤醒时**（避免睡眠期写 registry） |

D3 位图直接回答"谁进了 D3、谁没有"：位 i 置 1 = 缓存中第 i 台设备该轮 PMCSR 的 PowerState=3。

产物：`PMCDump.kext` 50,464 B，sha256 `b775f9a4c0d50ca86fc96423988b17b11ff7f17125f5220f7178a93329680eb3`，`CFBundleVersion 1.6.2`，三处一致（构建目录 / 仓库镜像 / ESP），6 秒后复验未回落，`config.plist` 两份 `Kernel:Add[31].Comment` → V1.6.2，`plutil -lint` 通过。

### 11.6 仍存在的残余风险（<80%）

- 若定时器在平台真正入睡前全部跑完且每轮都是 D0，仍无法区分"设备不进 D3"与"定时器太早停"。届时改看 `sleep-scan-passes`：若 passes=16（说明 3.2 s 窗口全部跑完）而 D3 位图恒 0，则倾向"macOS 不为 S0ix 把设备置 D3"这一结论。
- 若唤醒时先跑了定时器再执行 `setPowerState(1)`，末轮会记到全 D0。缓解：`scanRunning` 在 `setPowerState(1)` 第一句置 false，且位图序列本身能暴露这种异常（前面几轮非零、末轮归零）。

## §12 v1.6.2 首次真实结果（2026-11-23 20:51:28 → 20:54:13，165 s）

### 12.1 passes = 2 ⇒ 内核定时器在 S0ix 内停摆（>95%）

`pmset -g log` 记该次睡眠 **165 秒**；若 `scanTimer` 的 200 ms 链真在跑，3.2 s 内就该跑满 16 轮。实测 `sleep-scan-passes = 2`（`setPowerState(0)` 内的首轮 + 200 ms 后一轮），随后不再增长。

⇒ **IOTimerEventSource 在平台进入 S0ix 后不再被调度**，§11.5 设想的"过渡期连续 16 轮"物理上拿不到，可观测窗口只有睡眠入口那 200~400 ms。后续不要再在 kext 里加"睡眠中定时采样"，那条路走不通。

### 12.2 D3 位图：入口时 0 台，400 ms 后 7 台

`scanD3` 两轮（旧版未排除 `PMCSR=0xFFFF`，需手工剔除）：

| 轮 | 原始 | 位 | 判读 |
|---|---|---|---|
| pass0 | `0x0001a001` | 0,13,15,16 | **全是 `0xFFFF` 伪值**（无 PM 能力）⇒ 真实 D3 = **0 台** |
| pass1 | `0x0087e321` | 0,5,8,9,13,14,15,16,17,18,23 | 剔除 0/13/15/16 ⇒ 真实 D3 = **7 台：5,8,9,14,17,18,23** |

对应的 7 台（索引按 `sleep-scan-first` 顺序，字段 = id/PMCSR/LTR/LinkCtl/LinkSta/class）：

| idx | vid:did | 设备 | PMCSR pass0 → pass1 |
|---|---|---|---|
| 5 | 8086:06ed | PCH xHCI (USB 3) | `0x0008` → `0x010b`（D3hot） |
| 8 | 8086:06e8 | PCH I2C/LPSS | `0x0008` → `0x000b` |
| 9 | 8086:06e9 | PCH I2C/LPSS | `0x0008` → `0x000b` |
| 14 | 8086:06c8 | HDEF（音频） | `0x0008` → `0x000b` |
| 17 | 8086:0d4e | I219-LM GbE | `0x2008` → `0x200b` |
| 18 | 15b7:501a | NVMe (SN730) | `0x0008` → `0x000b` |
| 23 | 8086:15e9 | TB3 xHCI | `0x0000` → `0x0003` |

**未下 D3 的全部是根端口与桥**：`1901`、`06c0`、`06b8`、`15e7`×4、`15e8`（TB NHI）。PCIe 根端口在 S0ix 里本来就该保持 D0（链路走 L1.2/CLKREQ# 而非 D3），所以这**不是异常**（~85%）。

⇒ 结论修正：§11.2 的"全部 D0"只是采样过早。**macOS 确实会在睡眠入口把 leaf 设备推到 D3hot**，"macOS 不为 S0ix 做 PCI 电源管理"这个怀疑**被否定**（>90%）。D-state 这条线到此处**没有更多可挖的异常**。

### 12.3 第五次独立验证 1:1，稳态未变

| 计数 | 值（20:54 唤醒后） |
|---|---|
| `PKGC_C3_ENTRANCE_COUNTER` | **14,506** |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` | **14,506** |
| `PKGC_C6/C7/C8/C9/C10_ENTRANCE` | 0 / 0 / 0 / 0 / 0 |
| 其余 4 个 DEMOTE 原因、10 个 RESOLVE 原因 | 全 0 |

（自 20:40 的 13,388 起 +1,118，跨 20:38→20:40 的 107 s 与 20:51→20:54 的 165 s 两段睡眠。）

### 12.4 新线索：SLP_S0 硬件计数为 0，但**当前不可判读**

`pmc-regs` / `pmc-regs-presleep` 两份快照里：

| PMC 寄存器 | 值 |
|---|---|
| `SLP_S0_RES_COUNTER` 0x193C | **0 / 0** |
| `SLP_S0_DBG0` 0x10B4 | 0x00000000 |
| `SLP_S0_DBG1` 0x10B8 | 0x00000000 |
| `SLP_S0_DBG2` 0x10BC | 0x00000000 |
| `PM_CFG` 0x1818 | 0x2baf0007（bit22 read-disable = 0，可读） |
| `LTR_IGNORE` 0x1B0C | 0 |
| `ME` LTR 0x1B74 | 0x000088a0（非 0 ⇒ 映射没读错） |
| `CUR_PLT` / `CUR_ASLT` / `SPA` | 0x00040201 / 0x0174a251 / 0x0174a251 |

Linux `intel_pmc_core` 的 `pmc_core_slps0_dbg_show()` 在读这三张 map **之前**必须先 `pmc_core_slps0_dbg_latch(false)`，即把 `slps0_dbg_offset` 的 **BIT(31)**（`CNP_PMC_LATCH_SLPS0_EVENTS`）置 1，读完再清。**我们从未置过这一位**，所以三张 map 恒 0 属预期，**不能据此推断"PCH 从未进 SLP_S0"**（<80%，标未知）。`SLP_S0_RES_COUNTER=0` 同样缺独立交叉验证，暂列未知。

## §13 v1.6.3：arm SLP_S0 debug latch（等待一次重启验证）

### 13.1 改动

| 位置 | 动作 |
|---|---|
| `setPowerState(0)` 睡眠入口 | 读 0x10B4 → 发布 `slps0-armed-pre` → 写 `value \| BIT(31)` → 发布 `slps0-armed-now` |
| `setPowerState(1)` 唤醒 | 读 0x10B4/0x10B8/0x10BC → 发布 `slps0-dbg0/1/2`；读 0x193C → 发布 `slps0-res`；发布 `slps0-read-at`（当时的 `powerdriver-hits`）；随后写 `d0 & ~BIT(31)` 解除 latch（与 Linux 读完清位一致） |
| `scanPass()` | 位图剔除 `PMCSR == 0xFFFF` 的伪 D3（v1.6.2 遗留） |

解码表（`cnp_slps0_dbg0/1/2_map`，直接来自 Linux `drivers/platform/x86/intel/pmc/cnp.c`）：

- dbg0：`AUDIO_D3`(0) `OTG_D3`(1) `XHCI_D3`(2) `LPIO_D3`(3) `SDX_D3`(4) `SATA_D3`(5) `UFS0_D3`(6) `UFS1_D3`(7) `EMMC_D3`(8)
- dbg1：`SDIO_PLL_OFF`(0) `USB2_PLL_OFF`(1) `AUDIO_PLL_OFF`(2) `OC_PLL_OFF`(3) `MAIN_PLL_OFF`(4) `XOSC_OFF`(5) `LPC_CLKS_GATED`(6) **`PCIE_CLKREQS_IDLE`(7)** `AUDIO_ROSC_OFF`(8) `HPET_XOSC_CLK_REQ`(9) `PMC_ROSC_SLOW_CLK`(10) `AON2_ROSC_GATED`(11) **`CLKACKS_DEASSERTED`(12)**
- dbg2：`MPHY_CORE_GATED`(0) `CSME_GATED`(1) `USB2_SUS_GATED`(2) `DYN_FLEX_IO_IDLE`(3) `GBE_NO_LINK`(4) `THERM_SEN_DISABLED`(5) **`PCIE_LOW_POWER`(6)** `ISH_VNNAON_REQ_ACT`(7) `ISH_VNN_REQ_ACT`(8) `CNV_VNNAON_REQ_ACT`(9) `CNV_VNN_REQ_ACT`(10) `NPK_VNNON_REQ_ACT`(11) `PMSYNC_STATE_IDLE`(12) `ALST_GT_THRES`(13) `PMC_ARC_PG_READY`(14)

位 = 1 表示"该条件在锁存时刻满足"。`PCIE_CLKREQS_IDLE` / `CLKACKS_DEASSERTED` 正对应 `IOSF_NOT_BLOCKED` 挡回的那一层。

### 13.2 判读规则（实验前先写死，避免事后解释）

1. 出现**部分位=1**：锁存生效，PCH 确实尝试过 S0ix。**0 的位就是没满足的条件** ⇒ 直接点名要治的 IP（首次能拿到"哪个 IP"，此前一直 <80%）。
2. **三张 map 仍全 0** 而 `slps0-armed-now` 的 bit31 确实 =1：PMC 从未执行 S0ix 锁存 ⇒ PCH 侧从未进入 SLP_S0，与 `SLP_S0_RES_COUNTER=0` 互相印证（升级到 ~85%）。
3. `slps0-armed-now` bit31 读回 0：写被硬件拒/该 PCH-H 的偏移不同 ⇒ 映射假设错，需换 offset（对照 TGL 0x192C 等）。

### 13.3 部署与回退

`PMCDump.kext` sha256 `bbdf55e5bf1b24ff823e583e55051bfa54f675ae0a0a55c959b684b324f02419`，`CFBundleVersion 1.6.3`，构建目录 / 仓库镜像 `EFI/OC/Kexts` / `/Volumes/ESP/EFI/OC/Kexts` 三处一致，7 秒后复验未回落；`config.plist` 两份 `Kernel:Add[31].Comment` → V1.6.3，`plutil -lint` OK。

回退：`git checkout 6716a8c -- EFI/OC/Kexts/PMCDump.kext`（v1.6.2）后同步回 ESP。写操作只有 PMC 0x10B4 的 bit31 一个 debug 位，`slps0-armed-pre` 已记录写前值；重启本身即复位。


## §14 v1.6.3 首次结果：latch 写进去了，但 SLP_S0_DBG 依赖 C10 entry（21:11-21:13）

### 14.1 执行链验证通过

睡眠 **146 s**（21:11:21 → 21:13:47，AC）。三个属性证明写入与读回都成立：

| 属性 | 值 | 判读 |
|---|---|---|
| `slps0-armed-pre` | 0 | 写前 0x10B4 = 0 |
| `slps0-armed-now` | `0xFFFFFFFF80000000`（截 32 位 = `0x80000000`） | **bit31 写入成功**，硬件接受 |
| `slps0-read-at` | 3 | 唤醒时 `powerdriver-hits` = 3（睡+醒各一次） |

### 14.2 三张表解码（dbg0 含 latch 位）

| 表 | 原始 | 置 1 的位 | 为 0 的关键位 |
|---|---|---|---|
| dbg0 0x10B4 | `0x80000032` | bit31（latch）+ bit1 OTG_D3 + bit4 SDX_D3 + bit5 SATA_D3 | **AUDIO_D3(0) / XHCI_D3(2) / LPIO_D3(3) 全 0** |
| dbg1 0x10B8 | `0x00000AC9` | SDIO_PLL_OFF、OC_PLL_OFF、LPC_CLKS_GATED、**PCIE_CLKREQS_IDLE**、HPET_XOSC_CLK_REQ、AON2_ROSC_GATED | USB2_PLL_OFF、AUDIO_PLL_OFF、MAIN_PLL_OFF、XOSC_OFF、**CLKACKS_DEASSERTED** |
| dbg2 0x10BC | `0x0000028A` | CSME_GATED、DYN_FLEX_IO_IDLE、bit7、bit9 | MPHY_CORE_GATED、USB2_SUS_GATED、**GBE_NO_LINK**、PCIE_LOW_POWER、PMSYNC_STATE_IDLE |

### 14.3 ★ dbg0 全 0 与 `sleep-scan` 首轮完全吻合 ⇒ 采到的是"睡眠入口瞬间"

`dbg0` 的 `XHCI_D3 / AUDIO_D3 / LPIO_D3` 全 0（只有 OTG/SDX/SATA 三条在 PCH-H 上无意义或本就静止的位为 1），而本轮 `sleep-scan-d3mask` 的 **pass0 恰为 `0x0`（0 台 D3）**、pass1 为 bits 5/8/9/14/17/18/24；§12.2 的 `sleep-scan` **第二轮**明明看到 7 台下了 D3hot。两边不矛盾：**dbg0 反映的是 `setPowerState(0)` 那一刻（arm 写入瞬间）**，此时设备全在 D0——与 `sleep-scan` 首轮"真实 D3 = 0 台"逐位一致。两份独立来源互相印证，说明映射没读错（>90%）。

### 14.4 官方文档解释：这张表**依赖 C10 entry**，本机永远拿不到

Intel 400 系列 PCH 寄存器数据库（`SLP_S0# Debug 2 – Offset 10bc`，文档 615146 v1.2）原文：

> This register captures the state of low power events involved in SLP_S0# entry to assist with debug. **The status is captured as part of C10 entry (once CPU has entered package C10).**

本机 `PKGC_C6..C10_ENTRANCE` **全 0**（连 PC6 都进不去），所以"由 C10 entry 触发的 capture"永远不会发生。⇒ **"用 SLP_S0_DBG 点名阻碍 IP"这条路是循环依赖**（要先能进深 C 态才能看到为什么进不去），对本机无效（~85%）。以后不要再往这上面加版本。

顺带核出官方 dbg2 位表与 Linux `cnp_slps0_dbg2_map` 的差异：官方 bit7 / bit9 标 **Reserved**（Linux 表把它们写成 ISH/CNV），实测这两位读到 1 ⇒ `ISH_VNNAON_REQ_ACT` / `CNV_VNNAON_REQ_ACT` 这条映射在 PCH-H 上不可用，不能当判据。**唯一双源一致可用的位是 bit4 `GBE_NO_LINK` 与 bit6 `PCIE_LP`、bit1 `CSME_PG`。**

### 14.5 ★ `SLP_S0_RES_COUNTER = 0` 现在可以坐实

§12.4 曾因"未 arm"而无法判读。本次 arm 后 mAP 能读出非零值，说明 PMC MMIO 映射正确；同一映射下 `0x193C` 仍是 **0**。Linux `intel_pmc_core` 用的正是同一指标（`slp_s0_residency_usec`），其判据原文是：

> `intel_pmc_core INT33A1:00: CPU did not enter SLP_S0!!! (S0ix cnt=0)`

⇒ **PCH 侧从未进入 SLP_S0**（~85%，从 <80% 升级）。这条与"PC6 从不发生 / C3 每次都被 IOSF 挡回"是同一件事的两侧。

### 14.6 ★★ 捞到一条可外部验证的真线索：GbE 有链路

`dbg2` bit4 `GBE_NO_LINK = 0`（= GbE **有连接**），且实测：

```
en0: media: autoselect (1000baseT <full-duplex>)  status: active
      inet 200.200.15.35        ← 默认路由也走 en0
PCI 0d4e (I219-LM) PMCSR = 0x200b → PME_En(bit8)=0, PME_Status(bit15)=0   ⇒ 不是 WoL
```

**国外一手先例（两个独立来源，2026-11）**：

- Launchpad **#2174973**（Dell，I219 `8086:57b3`，e1000e）：s2idle 进不了 S0ix，`slp_s0_residency_usec` 不增长，报 `CPU did not enter SLP_S0!!! (S0ix cnt=0)`；`GBE_PGD0_PG_STS / GBE_D3_STS / GBE_VNN_REQ_STS` 全 0，而 `CPU_C10_REQ_STS = 1` —— 即 **CPU 够深了，卡在 GbE 不 power gate**。
- linux-kernel 邮件（2026-11-20，Ye Shu）：**HP ZBook 8 G2i 14 + I219-LM** 复现同一问题；`disable-k1 off` 时 1/4 成功进 S0ix，`disable-k1 on` 时 6/6、4/4 成功（每组 120 s rtcwake）。

⇒ GbE 是 S0ix 的必要条件之一，且"有链路"会让它拒绝 power gate。本机 `GBE_NO_LINK=0` 是**如实反映现状**（网线插着千兆），不是读数错误。

### 14.7 下一步：断链 A/B（不需要重启、不需要改任何配置）

1. `sudo ifconfig en0 down`（或直接拔网线）→ 确认 `ifconfig en0` 变 `status: inactive`
2. 睡 ≥120 s
3. 读 `PKGC_C6_ENTRANCE_COUNTER` 是否 >0、`IOSF_NOT_BLOCKED` 是否停止增长、`slps0-res` 是否 >0
4. 醒后 `sudo ifconfig en0 up`

判读：C6 出现 ⇒ GbE 是（至少一个）主阻碍，接着做"睡前自动 down / 醒后自动 up"的常态化；C6 仍 0 ⇒ GbE 排除，回到 `USB2_PLL_OFF / AUDIO_PLL_OFF / PCIE_LP` 这三条（注意 USB2 那两条与 xHCI 已进 D3hot 并存，说明 D3hot 不等于 IP power gate）。

## §15 ★ GbE 断链 A/B 结果：排除（2026-11-23 21:22 → 11-24 09:00，41,865 s）

### 15.1 实验条件确认

| 项 | 值 |
|---|---|
| `en0`（I219-LM） | `status: inactive`，`media: autoselect (<unknown type>)`，默认路由已切 `en1` |
| 睡眠时长 | **41,865 s（11.6 h）**，`Software Sleep`，AC 供电 |
| `slps0-armed-pre` | 50（`0x32`，上一轮 disarm 后的残留位） |
| `slps0-armed-now` | `0x80000032`（bit31 写入成功） |
| **`slps0-dbg2` bit4 `GBE_NO_LINK`** | **1**（置位 ⇒ PMC 确认 GbE 已断链） |

⇒ 实验条件成立：GbE 在睡眠入口对 PMC 而言已经是"无连接"。

### 15.2 结果：C6 仍然 0

| 计数 | 值 | 判读 |
|---|---|---|
| `PKGC_C6_ENTRANCE_COUNTER` | **0** | 仍未进入 PC6 |
| `PKGC_C7/C8/C9/C10_ENTRANCE` | 0 / 0 / 0 / 0 | — |
| `PKGC_C3_ENTRANCE_COUNTER` | **6,139** | 注：低于 21:19 的 15,927，PMT 在唤醒后重载分段（已知），整夜增量不可算 |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` | **6,139** | **第 8 次 1:1** |
| 其余 4 个 DEMOTE 原因 | 全 0 | — |
| `slps0-res`（SLP_S0_RES_COUNTER） | **0** | PCH 仍未进 SLP_S0 |

**⇒ GbE 有链路不是本机 S0ix 不成立的原因**（~90%）。虽然 Linux 上 Dell I219 / HP ZBook I219 确有同类案例，但那些机器 CPU 已达 C10、仅卡在 GbE power gate；本机连 PC6 都不进，阻碍在更前面。

### 15.3 SLP_S0_DBG 表的"入口快照"性质再次确认

`dbg0` 本轮仍为 `0x80000032`：`AUDIO_D3 / XHCI_D3 / LPIO_D3` 全 0，而同一次睡眠的 `sleep-scan-d3mask` pass0 = `0x0`（0 台 D3）、pass1 = bits 5/8/9/14/17/18/24。两者逐位一致 ⇒ **这三张表反映的是 arm 时刻（睡眠入口），不是 S0ix 期间**。因此 `USB2_PLL_OFF=0 / AUDIO_PLL_OFF=0 / PCIE_LOW_POWER=0 / CLKACKS_DEASSERTED=0` **不能作为阻碍证据**，只是"那一刻还没关"。§14.4 的结论（依赖 C10 entry）在此再次成立。

### 15.4 PPFEAR（IP power-gate ack）现状

`0x1D90` 起逐字节（Linux `cnp_pfear_map`，1 位/IP）：`64 ad 97 ff | ff 48 70 1c`

- bucket0 `0x64`：PMC=0 **OPI-DMI=0 SPI/eSPI=1 XHCI=0 SPA=0 SPB=1 SPC=1 **GBE=0****
- bucket1 `0xad`：SATA=1 HDA_PGD0=0 HDA_PGD1=1 HDA_PGD2=1 HDA_PGD3=0 SPD=1 LPSS=0 LPC=1
- bucket2 `0x97`：SMB=1 ISH=1 P2SB=1 NPK_VNN=0 SDX=1 SPE=0 Fuse=1 SBR8=1
- bucket3 `0xff` 全 1；bucket4 `0xff` 全 1

`GBE=0` 与 §15.2 互证（GbE 的 PFET 在 macOS 下从未 enable）。但这类位更像**静态配置**而非运行状态（多个 bucket 恒 `0xff`），不能当动态判据（<80%）。

### 15.5 结论与下一步方向

排除清单更新：电源参数、计划唤醒、器件裁剪、deepidle 用户态、**GbE 链路（本次）**、SLP_S0_DBG 路径（不可用）。剩下的定位手段只有**在固件层逐个禁用 PCH IP 做二分**（LAN / Audio / Thunderbolt / Card Reader / 指纹 / CNVi），每关一项睡一次看 `C6_ENTRANCE`。

## §16 ★★★ 收口（2026-11-24）：整条"找那个不放手 IP"的路是伪问题

### 16.1 触发

用户问「WiFi 睡眠的时候现在本来就会关闭吧？」→ 查证成立（`AirportItlwm::setPowerState` 在符号表里是 `T` 定义，含 `setPowerStateOff/On` + block 回调）→ 顺手复查 LTR 表，发现之前"XHCI 独紧"是**比错列**（Raw 含 bit31 使能位，2.3e9 的 IP 其实是 bit31=1、XHCI 的 `0x88A0` 是 bit31=0）。按解码后的 Snoop 列：**SPE 69µs / XHCI 164µs / GBE 185µs / CNV 631µs**，WiFi 是最宽松的那个。

### 16.2 新实测：清醒态也会尝试 PC6（推翻 §12.4 的旧结论）

60 s 全量增量（屏幕亮、系统活跃）：

| 通道 | Δ/60s |
|---|---|
| `PKGC_C3_ENTRANCE_COUNTER` | **+11** |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` | **+11**（第 9 次 1:1）|
| `PKGC_BREAK_CAUSE_SNOOP_TIMER_NONZERO` | **+744** |
| `PKGC_BREAK_CAUSE_SB_RING` | +20 |
| `PKGC_BREAK_CAUSE_DOUBLE_STRIKE` | +13 |

关屏（`pmset displaysleepnow` + `caffeinate -i` 保持系统醒）60 s：

| 通道 | Δ/60s |
|---|---|
| C3 / C6 / IOSF_NOT_BLOCKED / 其余 BREAK_CAUSE | **全 0** |
| `PKGC_BREAK_CAUSE_SNOOP_TIMER_NONZERO` | **+1,748（29/s）** |

⇒ 两条修正：①**清醒态（屏亮）确实会尝试 PC6 并失败**，旧结论"只有睡眠期才尝试"作废；②但速率只有 0.18/s，比睡眠期的 452/s 低 2500 倍，清醒态**不适合**做 A/B（信噪比太差）。③关屏反而完全不尝试，反直觉，未解（<80% 未知）。

### 16.3 关键真相：`SSDT-NameS3-disable.aml` 是我们自己加的

`ACPI/Add[15]` = `SSDT-NameS3-disable.aml`（Enabled）。反编译（iasl 20260408）：

```asl
DefinitionBlock ("", "SSDT", 2, "OCLT", "S3-Fix", 0)
{
    External (XS3_, IntObj)
    If (_OSI ("Darwin")) {}          // ← macOS 下 _S3 不定义
    Else { Method (_S3, 0) { Return (XS3) } }
}
```

**这是 oc-little 的"禁用 S3"补丁**：在 Darwin 下让 `_S3` 不存在，macOS 因此**看不到 S3 状态**，只能走 Deep Idle（`IOPMDeepIdleSupported = Yes`，ioreg 实证）。

### 16.4 完整因果链（闭合，~90%）

1. **固件 AOAC-only**：BIOS `Modern Standby = *Enable` 且 `IsReadOnly=1`（`docs/bios-update-forensics-2026-10-09.md:150`），S3 被固件压住。
2. **强制 S3 会 panic**：2026-09-17 实测 159 s 后唤醒 + panic，机制 `AppleACPIEC EC OBF=1 poll timed out` → EC 罢工（`docs/deepidle-power-audit-2026-11-12.md:1533`）。
3. **⇒ 加 `SSDT-NameS3-disable`**，macOS 改走 Deep Idle。
4. **Deep Idle 要省电必须真进 S0ix**，而 S0ix 需要 **PEP**（`\_SB.PEPD._DSM`，UUID `c4eb40a0-6cd2-11e2-bcfd-0800200c9a66`）**替 OS 收集全机设备 D-state 约束、向平台声明暂停意图**。
5. **macOS 没有 PEP**：`kmutil showloaded | grep -i pep` **零命中**；ioreg 里 `PEPD` / `PINT33A1` / `LPNP0D80` **零命中**；`ACPI/Add` 里也没有 PEPD 所在的 `SSDT-16`。`SSDT-DeepIdle` 只提供假的 `LPS0`/`LXEN`，能把 `IOPMDeepIdleSupported` 置 Yes，**但没有设备协调能力**。
6. **⇒ PCH 从未收到"可以进 SLP_S0"的信号**，所有 IP 保持 IOSF 活跃 ⇒ PCU 每次尝试关 BCLK 都被 `IOSF_NOT_BLOCKED` 打回 ⇒ 只能落 PC3。
7. **⇒ 整机停在 PC3 空闲 = 3.6 W 地板。**

**推论（重要）**：`C3_ENTRANCE == IOSF_NOT_BLOCKED` 的严格 1:1 **不是"找到了具体阻碍"，而是同一事件的两个投影**——每落一次 PC3，就意味着一次 PC6 尝试失败。所以"点名哪个 IP 不放手"是**伪问题**：没有 IP 需要"放手"，因为整个 S0ix 序列没启动。这也解释了为什么断 WiFi / 断 GbE / 逐个断设备**全部无效**。

### 16.5 已被证伪的具体嫌疑（累计）

| 嫌疑 | 处置 | 依据 |
|---|---|---|
| GbE 有链路 | 排除 ~90% | 断网 A/B，`GBE_NO_LINK=1` 仍 C6=0（§15）|
| WiFi 不睡 | 排除 ~90% | `setPowerState` 已实现；CNV LTR 631µs 最宽松（§16.1）|
| macOS 不做 PCI PM | 排除 >90% | 入口 400 ms 内 7 台 leaf 进 D3hot（§12.2）|
| 缺 `AppleIntelPCHPMC` | 排除 | `com.apple.driver.AppleIntelPCHPMC (2.0.1)` 已加载 |
| CPUFriend 限了 PC 状态 | 排除 | 解码 `cf-frequency-data`：无 CStateLimit 字段，只有频率/Thermal/DarkWake |
| LTR 太紧 | 排除 | `BREAK_CAUSE_LATENCY = 0` |
| 定时采样能看睡眠期 | 排除 >95% | `IOTimerEventSource` 进 S0ix 即停摆（§12.1）|

### 16.6 三条出路全部封死

| 路径 | 状态 | 阻断点 |
|---|---|---|
| S3 | **死** | 固件 AOAC-only，强制即 panic（09-17 实测）|
| S0ix | **无实现** | macOS 无 PEP；社区无 Intel macOS 跑通 PEP 的先例（11-16 查证）|
| S4 / hibernate | **死** | `rtcfx_exclude` 与"能恢复"互斥，放开踩 POST 005（固件层）|

### 16.7 唯一未实测项（价值低、风险低）

把 `SSDT-16`（含 `\_SB.PEPD` + `_DSM`）重新加入 `ACPI/Add`，实测 macOS 是否**偶然**调用它。预期**不会**（`_DSM` 需 OS 主动调用，Apple 侧无调用者）——但"注入后也无用"这句一直是从机制推断的，从未实测。代价：一次 ESP 写入 + 一次重启；风险：PEPD 里唯一副作用是 `ECNT` 写 `EC0.SLPT`，只在 `_DSM` 被调时发生，不调则完全惰性。**收益预期 <10%。**

### 16.8 结论

**3.6 W 是"AOAC-only 固件 + macOS 无 PEP"这一组合下的硬地板（~90%）。** 它不是某个设备/kext/参数能压下去的，继续在"哪个 PCH IP 不放手"这一层找下去不会有产出。想要更低，只有三条路：① 接受（当前）；② 写一个模拟 `intelpep` 的 kext 去做 `LPS0 _DSM` 协调 —— 社区无先例、工程量极大；③ 换一台有真 S3 的机器。

## §17 ★★★ 清醒 vs 睡眠对照：睡眠只省 0.5W，3.6W 是整机地板（11-24 10:10-10:20）

### 17.1 从 points.jsonl 重算全部 18 段（2026-11-04 ~ 11-11）

原始采样 `docs/backups/sleep-power-samples/points.jsonl`，46 点 → 18 个 start/stop 段，按 `ΔmAh × V / Δt` 折算：

| 类型 | 段数 | 时长 | 瓦数 |
|---|---|---|---|
| **过夜睡眠** | 4 | 11.3 / 11.8 / 13.2 / 14.1 h | **3.61 / 3.67 / 3.68 / 3.70 W** |
| **清醒 idle（电池）** | 4 | 36 / 38 / 57 / 64 min | **4.11 / 4.13 / 4.14 / 4.53 W** |
| 清醒负载 | 3 | 0.5~6 min | 12.2 / 17.4 / 21.1 / 26.9 W |

### 17.2 ★ 关键结论：睡眠只比清醒 idle 省 0.5~0.9 W

4.11~4.53（清醒）− 3.61~3.70（睡眠）= **0.4~0.9 W**，正好约等于屏幕背光那点电。

⇒ **3.6 W 不是"睡眠没生效"，而是这台机器"关机以外最低就这么多"。**
⇒ "降低睡眠功耗"这个目标本身已经没有空间：不是没找到路，是地板就在这（~95%）。

### 17.3 本轮新排除 6 项（全部只读取证）

| 嫌疑 | 排除依据 | 把握 |
|---|---|---|
| dGPU 漏电 | 物理无独显：`pci10de`/`pci1002` 零命中；`SSDT-dGPU-PowerOff-Darwin` 已生效（`DGPU` 节点 registered、`PEG0.PEGP` 下无 PCI 子设备）| >95% |
| NVMe 未做 APST | `org.acidanthera.NVMeFix (1.1.4)` 已加载，与 `IONVMeFamily 2.1.0` 同栈 | >95% |
| 过热降频浪费功耗 | `machdep.xcpm.cpu_thermal_level = 0`；`pmset -g therm` 报 `CPU_Speed_Limit = 100`、`CPU_Available_CPUs = 12`；无 thermal/perf warning 记录 | >95% |
| USB 睡眠供电过大 | `kUSBSleepPowerSupply = 5100` / `kUSBSleepPortCurrentLimit = 2100` 是 MacBookPro16,4 原厂值；TB 端口 `kPortStatConnectCount = 0`、`kPowerStateSuspended` 占 99% ⇒ 无负载，静态损耗仅几十 mW | ~85% |
| 内存异常 | 2×8GB DDR4-2933 Samsung `M471A1K43DB1-CWE`，标准 JEDEC；`PKGC_BREAK_CAUSE_DDR_TIME_NONZERO = 9` | >95% |
| 外接显示器（PHL 241B8Q）| 走 HDMI 直连 iGPU（非 USB-C：TB xHCI `connectCount=0`）；睡眠期 iGPU 已进 RC6 84.94%，显示管道关闭 ⇒ 贡献 < 0.1 W | ~70% |

### 17.4 蓝牙修复：病因对，但缺"零件"

| 检查 | 结果 |
|---|---|
| `/usr/sbin/bluetoothd` | 23,555,568 B，mtime **2026-11-06 13:12**，`codesign --verify --strict` 仍 **invalid signature** |
| `csrutil authenticated-root` | **disabled**（可 unseal）|
| 根卷 | `/dev/disk1s1s1 on / (apfs, sealed, read-only)` |
| Time Machine | 14 个快照，**全部只有 `Mac OS - 数据`**（系统卷不在 TM 范畴）|
| `/Volumes/Mac OS` | 26.7.3 / 25G342，与当前同源，**同样 invalid signature** |
| APFS 快照 | 仅 1 个（`9249D30A…`，即当前根）|
| 本地安装器 | 无 `Install macOS*` |

⇒ 要修必须：下载 12 GB 安装器 → `mount -uw /` unseal → 替换 → 重启。综合把握度 **~75%**（unseal 后黑苹果可能不启动），低于 80% 纪律线。

### 17.5 策略含义

电池 5,736 mAh × 12.74 V ≈ 73 Wh：

| 场景 | 12 h 耗电 | 占电池 |
|---|---|---|
| 合盖睡眠 | 3.6 W × 12 h ≈ **43 Wh** | **~59%** |
| 关机（S5）| 估 0.2 W × 12 h ≈ **2.4 Wh** | ~3% |

⇒ 若"过夜"是主要场景，**关机比睡眠省 40 Wh（约 55% 电池）**，代价是开盖要冷启动。

## §18 全球 EFI 盘点（2026-11-24 10:25-10:35）：这个型号只有两份，我们这份是最完整的

### 18.1 精确型号（HP ZBook Power G7 / CML-H）

GitHub 全站搜索 `zbook power g7`、`zbook hackintosh`，属于**同一型号**的仓库只有 2 个：

| 仓库 | 平台 | 状态 | 最后更新 | star |
|---|---|---|---|---|
| `MYunFeiYang/zbookpowerg7` | macOS 26 / Darwin 25，OC 1.0.9 | **在用，完整**（docs + SysReport + scripts）| 2026-11-24 | 3 |
| `PrashantSingh5946/ZbookG7PowerOpencore` | Big Sur 时代 | README 原文 **"Unfortunately not working at the moment, will fix as soon as possible"**；仓库只有一个 `EFI.zip`(24 MB) + 225 B README，无 ACPI 源码、无 docs、无 issue | 2022-10-08 | 5 |

⇒ **这个型号在全球范围内没有第二份可用 EFI**（>95%）。

### 18.2 同厂同代（更有参考价值）：ZBook Firefly 14 G7（CML-U，i7-10610U）

`sambow23/HP-ZBook-Firefly-14-G7-Hackintosh`（2024-11 更新，含 EFI 明文目录）。README 关键一句：

> Sleep — **Uses Deep Idle instead of S3, blame HP not me :)**

我们的 `SSDT-DeepIdle.aml` 与它的**反编译结果逐行同源**（都是 oc-little `OEM Table ID = "IDLE"` 的桩：`_SB.LPS0` 返回 1、`_GPE.LXEN` 返回 1）；我们这份 131 B，它那份 94 B（我们多了几行）。

ACPI 差异（它 15 张，我们 25 张）：

| 它有我们没有 | 作用 | 与睡眠功耗有关? |
|---|---|---|
| `DMAR.aml` | 中断重映射表 | 否 |
| `SSDT-HPET.aml` | HPET 计时器修补 | 否（计时器/唤醒稳定性）|
| `SSDT-PTSWAKTTS.aml` | PTS/WAK 方法钩子 | 否（唤醒流程稳定性）|
| `SSDT-XOSI.aml` | 我们已用 `SSDT-AWAC` | 否 |
| `SSDT-TB3-HP.aml` | 我们已有 `SSDT-thunderbolt-nhi-disable` | 否 |
| `SSDT-HP-FixLidSleep.aml` | 我们已有 `SSDT-LID-G7` | 否 |

Kext 差异：它 19 个，是我们 31 个的**子集**；唯一我们没有的是 `HibernationFixup`（休眠用，我们 `hibernatemode 0`，且 S4 已封）。

⇒ **它的 EFI 里没有任何一项能改变睡眠瓦数**（>90%）。

### 18.3 权威补丁集核对：oc-little「01-关于AOAC」五件套

社区唯一的 AOAC 补丁集是 `daliansky/OC-little` → `01-关于AOAC`，共 5 项：

| 项 | 文件 | 本机 |
|---|---|---|
| 01-1 禁止 S3 睡眠 | `SSDT-NameS3-disable.dsl` | **已有**（ACPI/Add[15]）|
| 01-2 AOAC 禁止独显 | `SSDT-NDGP_OFF-AOAC.dsl` | **已有**（`SSDT-dGPU-PowerOff-Darwin`）|
| 01-3 电源空闲管理 | `SSDT-DeepIdle.dsl` | **已有** |
| 01-4 AOAC 唤醒方法 | `SSDT-PCI0.LPCB-Wake-AOAC.dsl` | **已有** |
| 01-5 睡眠自动关闭蓝牙 WiFi | （`_PTS` 里置 BT/WiFi 复位）| **未用**（可选；且 §16.2/§16.5 已证断设备无效）|

⇒ **这条线上社区没有我们缺的补丁**（>90%）。

### 18.4 ★ 修正 §17.2 的一个数字：地板是"这固件+这系统"的地板，不是硬件地板

External anchors（区分来源，勿混用）：

| 机型 | 状态 | 实测睡眠功耗 | 来源 |
|---|---|---|---|
| Framework 13 **Intel**（RPL-P）+ Linux s2idle | S0ix 驻留 **98.9%** | **0.53 W** | sjg.io 2026-04 一手实测 |
| 16" MacBook Pro（Apple Silicon，M2 Pro/Max）| Apple 官方 | **0.38 W** | Apple Product Environmental Report 2023-01 |
| **本机**（MacBookPro16,4 SMBIOS，CML-H）| S0ix 驻留 **0**（`slp_s0=0`）| **3.6 W** | points.jsonl 四段 |

⇒ 差距 **≈3.2 W**，不是 §17.2 里按封装功耗推算的"最多 0.8 W"。§17.2 的 0.8 W 只说明"相对本机清醒态，睡眠没省多少"，**不说明硬件极限**。真进 S0ix/S3 的整机应在 0.4~1.5 W 量级。

同时注意另一面：本机清醒 idle 4.1 W **低于** Apple 16" 的 6.8 W（屏亮 idle），说明清醒侧没有浪费 —— 3.2 W 全部来自"没真睡"这一个状态。

但拿回这 3.2 W 的前提没变：**S3**（HP 固件摘掉，强开 EC panic）或 **S0ix**（需 PEP，macOS 无此驱动）。两者都不在 EFI 层，因此"换/借鉴 EFI"这条路到此为止（~90%）。

### 18.5 唯一还值得抄的（如果以后要碰稳定性，不是功耗）

`SSDT-PTSWAKTTS`（睡/醒方法钩子）+ `SSDT-HPET`/`DMAR`：改善唤醒路径稳定性与计时器，**对瓦数零影响**。当前无唤醒异常，暂不引入（避免无收益的变量）。

## §19 ★★★ 纠错：固件"给了" S3，但 S3 的 EC 分支靠 `ECRG` 门控，而 macOS 下 `ECRG=0`（11-24 10:40-11:00）

### 19.1 起因

用户问「那先到 3.2？」（指 §18.4 的 3.2 W 差距）。复核时发现两处需要修正：一是 **3.2 W 这个数字本身不严谨**（拿另一台机器的锚点减出来的），二是 **§16.4 的「固件 AOAC-only ⇒ S3 被固件压住」表述是错的**。

### 19.2 ★ 事实一：S3 在 ACPI 层是"完整定义"的，不是"被压住"

| 证据 | 值 | 判读 |
|---|---|---|
| `FACP-1.dsl` Flags | `0x002384A5` | — |
| └ `Hardware Reduced (V5)` bit20 | **0** | **不是**硬件精简 ACPI ⇒ PM1a Event/Control Block（`0x1800`/`0x1804`）、PM Timer（`0x1808`）全在，传统 S3 硬件路径完整 |
| └ `Low Power S0 Idle (V5)` bit21 | **1** | 固件**同时**声明 AOAC/S0ix 能力 ⇒ BIOS 里 `Modern Standby` 只读=Enable 的来源 |
| `DSDT.dsl:5708` | `Name (SS3, One)` | S3 状态开关为**真** |
| `DSDT.dsl:37697` | `If (SS3) { Name (_S3, Package{0x05,0,0,0}) }` | **`_S3` 确实被定义**，SLP_TYP=5（标准 S3） |
| `config.plist` `ACPI:Delete` | 只有 `DMAR` | **没有任何删除 `_S3` 的补丁** |
| `config.plist` `ACPI:Patch` | PNLF→XNLF、GNUMGPDI→TPNMGPDI、… | **无 `_S3`/`XS3` 相关改名** |
| `SSDT-NameS3-disable.aml` | `If (_OSI("Darwin")) {} Else { Method(_S3){Return(XS3)} }`，而 DSDT 里 **无 `XS3`** | ⇒ **在 Darwin 下它什么都没做**（`Else` 分支永不执行，`Return(XS3)` 从不被解析）|

⇒ **修正 §16.4 第 1 条**：不是「固件把 S3 摘掉了」，而是「固件**同时**提供 S3 与 S0ix 两套，BIOS 默认偏好 S0ix」。09-17 的实验（撤 `\SB.LPS0` ⇒ `IOPMDeepIdleSupported` Yes→No）能让系统**真的进 S3**，恰恰因为 `_S3` 一直存在。**「固件不支持 S3」这个说法作废（>90%）。**

### 19.3 事实二：S3 的差不在"能不能进"，在"进去之后 EC 崩"

09-17 实测：进 S3 → 159 s 后 RTC 唤醒 → `AppleACPIEC EC OBF=1 poll timed out` 连绵 → PS2/SMBus 死等 → USB 栈 panic。

查 `_PTS` / `_WAK` 的 S3 分支：

| 位置 | 对 `Arg0==3`（S3）做了什么 |
|---|---|
| `_PTS` 主体 | 只有 `TRAP (0x02, 0x1E)`（DTSE 调试），**无任何 EC 操作** |
| `_PTS` → `HPTS(3)` | `\SB.ODGW(0x5403)`（走 `ODBB` → SMI `0xB2` 的 OEM data block 写，由 BIOS SMI handler 接管）；**不设 `EC0.ACPI`** |
| `_PTS` → `HPTS(4/5)` | **才**设 `EC0.ACPI = Zero`（S4/S5 专属） |
| `_WAK` → `HWAK(3)` | `EC0.ITLB()`；**`If (EC0.ECRG)` 才**做 `EC0.ACPI = One` + `EC0.OST = GTOS()`；`Arg0>2` 时做 `_TZ.RETD()` / `INTM(1)` / `UDTS(0,0)` |

⇒ **唤醒后恢复 EC 的 `ACPI` 位与 `OST`，整段被 `If (EC0.ECRG)` 门控。**

### 19.4 ★★ 而 `ECRG` 在 macOS 下是 0（实测过）

- `DSDT.dsl:27002` `Method (_REG, 2) { If (Arg0 == 0x03) { ECRG = Arg1; ... } }`
- `ECRG` 只在 OS 为 **EmbeddedControl region 装 handler**、触发 `_REG(3,1)` 时才变 1
- 本机 region 名是 **`ERAM` / `ECRM`**（`DSDT.dsl:26960` / `:27014`），**不是 AppleACPIEC 认的 `ECOR`**
- 09-29 v8 kext 实测（`docs/fan-ec-control-audit.md` §6.10）：**基线 `ECRG = 0`**（`ret=0`），且手工调 `_REG(3,1)` 后虽能翻成 1，但**随即 EC 字段读返回 `kIOReturnError`**、还原返回 `kIOReturnUnsupported`（只能重启复位）

⇒ 在 macOS 下，**固件所有 `If (ECRG)` 包裹的 EC 同步代码一律不执行**（电池能读数走的是 `ECEnabler` 的旁路，不是这套）。

### 19.5 因果链（~70%，未实测故不写 >80%）

```
macOS 无 ECOR region handler
  ⇒ _REG(3,1) 从不被调
  ⇒ ECRG = 0
  ⇒ _WAK/HWAK 里"唤醒后恢复 EC(ACPI 位/OST)"整段被跳过
  ⇒ S3 唤醒后 EC 停在未定义状态
  ⇒ macOS 发 RD_EC(0x80) 无响应，OBF 恒 1
  ⇒ AppleACPIEC 超时连绵 → PS2/SMBus 死等 → panic
```

**为什么 Windows/Linux 不出事**：它们有 EmbeddedControl handler ⇒ `ECRG=1` ⇒ 同一段 `_WAK` 代码正常跑；而且它们绝大多数时候根本不走 S3（AOAC 优先 S0ix）。

### 19.6 能不能修：三条，全部不到 80%

| 方案 | 做法 | 阻碍 |
|---|---|---|
| A. 改 region 名 `ERAM/ECRM` → `ECOR` | ACPI patch，让 AppleACPIEC 装 handler，`_REG(3,1)` 触发 | ① 改 region 名会影响所有引用它的字段（电池、风扇、热区）；② **v8 实测 `ECRG=1` 之后 EC 字段读就失败**（`kIOReturnError`），可能比现在更糟；③ 需要 `mount`-级改写 DSDT 引用面，风险中高 |
| B. SSDT 覆盖 `_WAK`，绕过 `ECRG` 无条件恢复 EC | 在 `_WAK(3)` 后强制 `EC0.ACPI = One` + `OST` | 写 EC 字段本身要 region handler ⇒ **同一个死结**；且写错 EC 位可能让电池/键盘彻底失效 |
| C. 自建 kext 在 S3 唤醒早期做 EC 硬复位 | 端口级写 EC（`SMCSuperIO` 已证可行） | 时序在 `_WAK` 之前，kext 拿不到那么早的钩子；且复位序列**无公开规格**（HP EC 私有协议） |

⇒ **S3 这条路不是"固件不给"，而是"固件给了但它的 S3 分支依赖一个 macOS 永远拿不到的门（`ECRG`）"**。要过这道门必须改 region 名，而改完之后 EC 读会失败（已实测）——**闭环（~80%）**。

### 19.7 ★ 修正 §18.4 的"3.2 W"：应为本机实测口径的 ~2.2 W，且不存在中间台阶

§18.4 拿外部锚点（Framework 13 Intel 0.53 W / 16" MBP 0.38 W）减本机 3.6 W = 3.2 W，**是跨机器对比，不严谨**。按本机自己的功耗分解重算：

| 分项 | 现状（PC3） | 真进 PC6 后（估） | 依据 |
|---|---|---|---|
| core | 1.12 W | ~0.05 W | 6 核已全 C6，PC6 后核心电压域整体关断 |
| DDR | 0.57 W | ~0.05 W | PC6 后 DDR 进自刷新 |
| uncore | 0.36 W | ~0.05 W | PC6 后大部分 PCH/ring 关闭 |
| 封装合计 | **2.06 W** | **~0.2 W**（含 VR 损耗） | — |
| 真非 CPU | 1.23 W | ~1.23 W（保守不变） | EC/面板/VR/SSD 待机 |
| **整机** | **3.6 W** | **~1.4 W** | ⇒ **收益 ~2.2 W** |

外部锚点仍可作旁证（说明 3.6 W 不是硬件极限），但**不能用来算收益**。

⇒ **不存在"先到 3.2"这个台阶**：只有 3.6 W（现状）与 ~1.4 W（真睡）两档，中间是空的。因为功耗不是"调参调低"的连续量，而是"进不进 S0ix/S3"的开关量。

### 19.8 结论

1. 「固件不给 S3」**作废**（`_S3` 定义完整、无补丁删除）。
2. 「S3 能用」也不成立：S3 的 EC 恢复逻辑被 `ECRG` 门控，而 macOS 下 `ECRG=0`，且改 region 名会让 EC 读失败（v8 实测）。
3. 「3.2 W 差距」应修正为 **~2.2 W 收益**，且没有中间档。
4. 3.6 W 是"这套固件 + 这套 OS"的稳态地板，与 §17.2 一致；继续在 OS 层找不可达。

### 19.9 「可以进 S3 吗」——能进，出不来

**能进（已实测 >95%）**：`_S3` 定义完整、无补丁删除，09-17 撤 `\SB.LPS0` 后系统**真的进了 S3**（159 s 后由 RTC 唤醒）⇒ 硬件的 S3 电源循环走通了。

**出不来（已实测 >95%）**：唤醒后 `AppleACPIEC EC OBF=1 poll timed out` 连绵 → PS2/SMBus 死等 → USB 栈 panic。`docs/sleep-power-final-2026-11-20.md:41` 当时的记录更精确：不是"EC 进了 S3 又坏"，而是「**EC 未进入 S3**」。

**为什么 EC 不跟着进（~85%，两处独立证据吻合）**：

| 证据 | 内容 |
|---|---|
| `_PTS` → `HPTS(3)` | 只发 `ODGW(0x5403)`（SMI `0xB2`，handler 在 BIOS 内，ACPI 层看不到）；**只有 `Arg0==4/5` 才**设 `EC0.ACPI = Zero`。S3 分支对 EC **无任何动作** |
| `_WAK` → `HWAK(3)` | 恢复部分被 `If (EC0.ECRG)` 门控，而 `ECRG=0`（见 §19.4） |

⇒ **固件里 S3 的 EC 进入/恢复流程是空壳**（HP 只为 AOAC 路径实现，因为这台机器设计上永远走 S0ix）。

**EC 在正常态是健康的**（2026-11-24 11:44 实测）：`CommandCount=48919`、`OBFPollTimeout=0`、`IBFPollTimeout=0`、`MissingSCI=0`、`CommandRetry=11` ⇒ 平时好、S3 后才坏，与"EC 没被通知进 S3"一致。

**补不了**：要补必须在 `_PTS(3)` 里自己给 EC 发 S3 命令，而 HP EC 的 S3 命令字无公开规格（`ODGW(0x5403)` 交给 BIOS SMI handler，ACPI 层拿不到具体序列）。

**即使补上，实用价值也接近零**：

| 场景 | 现状（合盖 S0ix 3.6 W） | 若 S3 可用（~1.4 W） | 关机（~0.2 W） |
|---|---|---|---|
| 短时离开 1 h | 3.6 Wh（电池 5%） | 1.4 Wh（2%） | 不适用（要冷启动） |
| 过夜 12 h | 43 Wh（59%） | 17 Wh（23%） | **2.4 Wh（3%）** |

⇒ S3 只在"既要省电又要秒回"的短时场景有意义，而那种场景下现状的 3.6 Wh **本来就无所谓**；真正费电的过夜场景，关机永远比 S3 更省。**所以即使 S3 修好，也只是把一个不痛的数字变小。**

### 19.10 ★★ 勘误（11-24 10:46，用户「你确定？」后复核）：`ECRG=0` 这一步是错的

§19.5 的因果链建立在「macOS 不调 `_REG` ⇒ `ECRG=0`」上，**这一步有两处硬错**：

| 错误 | 事实 |
|---|---|
| 「`_REG` 依赖 region 名，本机叫 `ERAM`/`ECRM` 而非 `ECOR`，所以不调」 | **`_REG` 的第一个参数是地址空间 ID，不是 region 名**。`DSDT:27002 Method(_REG,2){ If(Arg0==0x03){ ECRG=Arg1 … } }` 中 `0x03` = EmbeddedControl 空间；同空间内 region 叫什么名字与 `_REG` 触发**无关**。ACPI 规范口径：`_REG(AddressSpace, Function)`。 |
| 「`ECRG=0`（09-29 v8 实测）」 | **`ECRG=1` 在稳态被反证**：`Method(GBAP)` 只在 `If(ECRG)` 内执行 `NBAP = BATP`（EC 的电池剩余量）；而电池实读 **5636 / 5736 mAh、12.74 V、`pmset` 100%**。若 `ECRG=0`，`NBAP` 恒 0 ⇒ 电量必显示 0% ⇒ **`ECRG` 必为 1（≥85%）**。旁证：`KFCL/KSFS`（风扇 PWM 写）同样被 `If(ECRG)` 包着，EC 字段读写通路是通的。 |

⇒ **`_WAK`→`HWAK` 里恢复 EC 的 `EC0.ACPI=One` / `OST` 实际是会执行的**，S3 唤醒失败**不是**"恢复代码被跳过"。

**仍然成立的部分（逐行核对过）**：`_PTS`→`HPTS(3)` 只发 `ODGW(0x5403)`（SMI `0xB2`，handler 在 BIOS 内），`EC0.ACPI=Zero` **只在 `Arg0==4||Arg0==5` 执行**，S3 分支对 EC **零动作**。

**修正后的归因（~70%，仍属推断）**：EC 从未被通知进入 S3，S3 期间平台掉电/复位后 EC 停在未定义态，唤醒时 `OBF` 恒 1 且不再清 ⇒ `AppleACPIEC` 超时连绵 ⇒ panic。「EC 未进入 S3」这句 11-20 的原始措辞反而更准。

**由此重新开放（但价值低）的一条实验**：因 `ECRG=1`，EC 字段**可写**（`KFCL` 就是 ACPI 写 EC 的例子），所以可以：
1. `ACPI/Patch` 把 `_PTS` 改名 `XPTS`（当前 config 无此补丁，已核）；
2. 加一张 SSDT：`Method(_PTS,1){ XPTS(Arg0); If(_OSI("Darwin") && Arg0==3){ EC0.ACMI(...) /* 置 ACPI=Zero */ } }`，即照抄固件对 S4/S5 的做法补到 S3；
3. 撤掉 `SSDT-DeepIdle`（或 `\SB.LPS0`）让系统真走 S3，测一次睡眠。

代价：改 EFI + 一次重启 + 一次 S3 测试；失败表现 = 回到 09-17 的唤醒 panic（重启可恢复）。**成功率估 25~40%**（EC 的 S3 进入很可能不止 `ACPI=Zero` 一位，BIOS SMI 里可能还有私有序列）。即便成功，收益只落在"省电 + 秒回"的短时场景（1 h：3.6→1.4 Wh），过夜场景关机仍然更优（2.4 Wh）。

## §20 驱动完整度盘点（2026-11-24 10:50，全部来自实测 ioreg / system_profiler / VideoToolbox）

### 20.1 工作正常，无需干预

| 子系统 | 驱动 | 实测证据 |
|---|---|---|
| iGPU UHD630 | `AppleIntelCFLGraphicsFramebuffer` + `AppleIntelKBLGraphics` + WEG 1.7.2 | Metal 3；内屏 1080p + HDMI 外接 PHL 241B8Q 双在线；亮度 PNLF+BrightnessKeys 可调 |
| 视频硬解 | 系统 VD | `VTIsHardwareDecodeSupported`：H.264 **True**、HEVC **True**；VP9/AV1 **False**（UHD630 无 AV1，VP9 macOS 不外露）|
| 有线网卡 I219-LM | `IntelMausi 1.0.9` | 千兆 active，可拿 DHCP |
| NVMe WD SN570 1TB | `IONVMeFamily` + `NVMeFix 1.1.4` | `TRIM Support: Yes` |
| 声卡 | `AppleALC 1.9.9`（layout-id **7**）+ `SimpleHDA` + `TGLDmic 0.6.4` | 内建麦克风（num-internal-mics=1）、内建输出、4 个 IOAudioEngine 在线 |
| 触摸板 | `VoodooI2C 2.9.1` + `VoodooI2CHID` + `VoodooInput` | 走到 `AppleMultitouchTrackpadHIDEventDriver`（原生多点触控栈）|
| 键盘 | `VoodooPS2 2.3.8` | PS2 控制器 + 键盘驱动均 active |
| 电池 | `SMCBatteryManager 1.3.9` + `ECEnabler 1.0.6` | 5636/5736 mAh、12.74 V、循环 138 次 |
| 摄像头 | UVC 免驱 | `HP HD Camera` idVendor 0x30c9 / idProduct 0x10 |
| 蓝牙 | `IntelBluetoothFirmware 2.5.3`(fork) + `BlueToolFixup 2.7.2` + `BTLEAdvFixup 0.9.4` | Intel AX201（USB `idProduct 0x26`），State On，支持 HFP/A2DP/HID/LEA |

### 20.2 不完美清单（按严重度）

| # | 缺口 | 实测证据 | 能否修 |
|---|---|---|---|
| 1 | **睡眠 3.6 W 地板**（S0ix 不成立）| 见 §16–§19 | 不能（固件 AOAC + macOS 无 PEP）|
| 2 | **`/usr/sbin/bluetoothd` 文件损坏**，唤醒后约半数概率 SIGBUS | 2885 页中 4 页坏（827/889/1036/1296），`codesign --verify` invalid | 需 12 GB 安装器 + unseal 根卷，~75% |
| 3 | **雷雳 3 完全不可用** | `system_profiler SPThunderboltDataType`：**No drivers are loaded**；`pci8086,15e8`(TB NHI) **无驱动**；`15e9` 只能跑 USB（AppleUSBXHCITR）| 可行但代价大（TB 需完整 NHI+PCIe 热插拔栈，iGPU 无 TB 支持）|
| 4 | **HDMI/DP 音频不出声** | HDEF 下 `IOHDACodecDevice@1F,3,2`（数字音频 codec）**!registered, !matched**；音频设备列表里只有内建输出 + Oray 虚拟声卡，无 PHL 241B8Q | 需给数字 codec 做 AppleHDA patch / 改 layout，社区对 CML 移动 HDMI 音频支持不稳 |
| 5 | **Wi-Fi 只到 802.11ac** | `Supported PHY Modes: a/b/g/n/ac`（无 ax），而网卡是 AX201；`Firmware itlwm 2.4.1_forbidden` | 取决于上游 itlwm 是否实现 ax（目前没有）|
| 6 | **VP9 / AV1 无硬解** | VT 实测 False/False | 硬件/系统层面无解 |
| 7 | **风扇转速与温度读不到** | 全树无 `F0Ac`/`TC0P`；`SMCSuperIO 1.3.9` 已加载但本机 EC 不在其支持表 | 需写 EC 直读（风扇仍由固件自动控，读不到≠不转）|
| 8 | **AirDrop/Handoff 存疑** | `awdl0` 接口存在、系统报 AirDrop Supported；但 itlwm 系对 AWDL 实现一向不完整 | 需实测（发一张图试试）|
| 9 | **无指纹 / 无读卡器** | USB 主机设备仅 **2 个**（摄像头 + 蓝牙）；PCI 无 SD 主机控制器（无 class 0805）| 硬件层面就没有/未枚举，不是驱动缺失 |
| 10 | **dGPU 不存在** | 无 `pci10de`，`SSDT-dGPU-PowerOff-Darwin` 已生效 | 设计如此（Power G7 该配置无独显或已断电）|

### 20.3 两个"定时炸弹"：MaxKernel 卡在 25.99.99

| kext | 限制 | 后果 |
|---|---|---|
| `SimpleHDA.kext` | Min 25.0.0 / **Max 25.99.99** | 当前 macOS 26 = Darwin 25 ⇒ 正常加载；升到 **macOS 27（Darwin 26）会静默不加载**，音频链路少一环 |
| `ForbiddenItlwm.kext` | Min 25.0.0 / **Max 25.99.99** | 同上 ⇒ 升级后 **Wi-Fi 直接没有** |

⇒ 任何 macOS 大版本升级前必须复核这两项（>95% 会出问题）。

### 20.4 结论

驱动层没有"坏掉的"，只有"到不了"的：所有能在这套硬件上工作的子系统都在工作（显卡/硬解/网卡/NVMe/声卡/触摸板/键盘/电池/摄像头/蓝牙）。不完美的四项是**结构性**的：睡眠（固件）、雷雳（NHI 无栈）、HDMI 音频（数字 codec 未匹配）、Wi-Fi 6（上游未实现）。剩下两个是"本机没有这个硬件"（指纹/读卡器）和一个"文件损坏"（bluetoothd）。
