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
