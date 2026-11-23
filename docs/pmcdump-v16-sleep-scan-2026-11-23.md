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
