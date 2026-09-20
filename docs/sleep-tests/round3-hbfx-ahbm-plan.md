# Round 3 · `hbfx-ahbm` 自动休眠实测执行单

> **2026-09-20 16:5x 建立。** 这是「§7.10 发现的那条从未测过的路」的**首次上机实测**。
> 权威分析见 `s4-requirements-audit.md` §7.10；真相的判据在本文 §5。
> **本轮是自 2026-09-16 封板以来第一次真正动 EFI + pmset。** 回滚点见 §6。

---

## 🚀 17:2x **测试已发起** —— 环境核验全绿（重启后实测，一手）

重启时间 `kern.boottime = Sun Sep 20 17:19:08 2026`。五项核验：

| # | 项 | 实测值 | 判定 |
|---|---|---|---|
| 1 | boot-args 进内核（`nvram` ＋ `sysctl kern.bootargs` 双查） | `… rtcfx_exclude=0E-FF -rtcfxdbg hbfx-ahbm=1 -hbfxdbg` | ✅ |
| 2 | pmset | `hibernatemode 3` / `standby 1` / `standbydelaylow 86400` / `standbydelayhigh 604800` | ✅ |
| 3 | gate 属性（`IOPMrootDomain`） | `"Standby Enabled" = Yes`、`"Standby Delay" = 86400` | ✅ |
| 4 | ★ **kext 真实效**（铁律①：`IOKitDiagnostics→Classes` **实例计数**，不用 `ioreg -c`） | **`HibernationFixup = 1`**、`RTCMemoryFixup = 1`、`Lilu = 1`、`AppleRTC = 1`；**hook 目标** `X86PlatformPlugin = 1`、`X86PlatformShim = 1` | ✅ |
| 5 | 内存压力（§7.10f 担心的「8 GiB 镜像写入慢」前置） | **`swap = 0.00M`**（重启自动清零） | ✅ 前置解除 |

**基线（唤醒后据此对齐）**：`kern.hibernatecount = 0`｜`/System/Volumes/VM/` **无 `sleepimage`**（仅 `kernelcore`）｜`nvram -p` **无 `hibernat*` 变量**｜时间戳 `17:22:46`。
（这三条基线 = 与 09-16 那 5 次失败后的签名**完全一致** ⇒ 上次确实从未写盘。）

**断言现状**：`PreventSystemSleep = 0`（关键 —— `pmset sleepnow` 不会被它拦）；`PreventUserIdleSystemSleep = 1` 的持有者是 **`Electron`（WorkBuddy 自身）** ⇒ 只挡 idle sleep，不挡显式命令；`Idle sleep preventers: IODisplayWrangler`（正常）。

**触发方式**：`pmset sleepnow`（显式命令）。因实测 **`AppleClamshellCausesSleep = No`**，本轮**不需要物理合盖**。
**唤醒后核验**：`bash docs/sleep-tests/round3-verify.sh`（只读，9 项判据 —— 含"是否出现 `Entering Hibernate`"这条核心判据）。

### ⚠️ 17:25 **首次触发的实际结果：被「观察者效应」打断 ⇒ 无效测试（非失败）**

`pmset sleepnow` 于 **17:25:08** 发出（发出前实测确认 `hibernatemode 3` / `standby 1`）。`pmset -g log` 实录：

```
17:25:07  Notification   Display is turned off                                  ← ★ 睡眠流程第一步已执行
17:25:07  powerd Created InternalPreventSleep "…darkwakelinger" 00:00:00       ← 15s linger 期开始
17:25:14  ← 我执行 round3-verify.sh                                             ✗ 打断
17:25:22  powerd TimedOut InternalPreventSleep "…darkwakelinger" 00:00:15
17:25:26  ← 我执行断言诊断                                                       ✗ 打断
17:28:30  Notification   Display is turned on                                   ← 系统被活动吵醒
```

**三条独立判据一致**：

| 判据 | 实测 | 含义 |
|---|---|---|
| `kern.boottime` | 仍 = `17:19:08` | **没有重启、没有成功休眠** |
| pmset log 有无 `Entering Sleep` / `Entering Hibernate` | **两者皆无** | 睡眠**从未完成** |
| 有无 `Display is turned off` ＋ `darkwakelinger` | **两者皆有** | 睡眠流程**确实启动过** |

⇒ **这是无效测试，不是失败。** 原因 = 我在 `pmset sleepnow` 后**仅 6 秒**就跑诊断命令，而 powerd 的 `darkwakelinger` 有 **15 秒 linger 期** —— 期间任何进程活动都被判为"系统仍在使用"，从而**中止睡眠协商**。

**★ 教训（须记牢）**：**触发睡眠后，在 linger 期内（≥30 秒）不得执行任何命令**，否则测试必被自己打断。
**★ 附带收益**：本次拿到一个**比 `Entering Sleep` 更早的阶段判据** —— `Display is turned off` ＋ `darkwakelinger` 证明 `pmset sleepnow` 的请求**成功进入了睡眠协商**（09-16 那批连这个都没有）。已加进 `round3-verify.sh` §[1b]。

### ✅ 修正后的触发方式（避免观察者效应）

**由用户在独立终端手动触发，触发后立刻停手** —— 不碰键盘、不碰鼠标、不操作 WorkBuddy：

```bash
sudo pmset sleepnow
```

- ⛔ **不要在 WorkBuddy 里让我触发**：我的诊断命令会在 linger 期内打断睡眠（本轮实测代价）
- ⛔ 触发后**至少 60 秒内不要有任何输入**（含动鼠标、切窗口）
- ✅ 睡下去后，**按一下电源键或键盘**唤醒
- ✅ 唤醒回来后说一声，我再跑核验（此时已远离 linger 期，安全）


---

## ⚠️ 17:0x 修正：`hbfx-ahbm` 取值 **3 → 1**（去掉 bit1「只在合盖时」）

**原因（实测一手证据）**：

```
ioreg -rn IOPMrootDomain -d 1
  "AppleClamshellCausesSleep" = No      ← 本机合盖【不会】触发睡眠
  "AppleClamshellState"        = No
```

本机是靠 **`Clamshell.app`**（`com.kovrazhkin.Clamshell` 2.3）**显式发 `Software Sleep`** 来睡的，**盖子始终是开的**。

而源码里 bit1 的判断是：

```cpp
bool lidIsOpen = OSDynamicCast(OSBoolean, getPMRootDomain()->getProperty(kAppleClamshellStateKey)) != kOSBooleanTrue;
if (!forceHibernate && whenLidIsClosed && lidIsOpen) { ...; break; }   // 开盖 ⇒ 不改写
```

⇒ **`hbfx-ahbm=3` 在本机的日常入口上是 100% 不会触发的**（盖子开着 ⇒ `lidIsOpen = true` ⇒ `break`）。

**为什么改用 `1` 反而更安全**：既然合盖**不触发睡眠**（`CausesSleep = No`），那 `1` 的"任何睡眠都改写"
实际只落在**显式睡眠命令**上（`pmset sleepnow` / Clamshell.app），**完全可控** —— 不存在"合盖不小心撞上"的风险。
同时这也意味着 **§3 的第 4–5 步（物理合盖）作废**，本轮改为**显式触发睡眠**。

**未采用的两条替代路**（记录在此，避免后人重走）：

- 开 `Clamshell.app` 的「合盖睡眠」再用 `3` ⇒ 改用户工具设置、多一个变量，且失败时会影响用户日常
- 用 `3` 但物理合盖后再想办法触发 ⇒ 合盖后无法操作

**§2.1 与 §3 的 `hbfx-ahbm=3` / 「物理合盖」表述以本节为准。**

---

## 1. 假设与目的

**假设**：`hbfx-ahbm` 能让 macOS 在**睡眠策略选择阶段**就把 `sleepType` 改写成 Hibernate，
从而**绕开"必须先走一段 S3 语义睡眠"**这个本机 S3 坏掉导致的卡点。

**与 09-16 那 5 次的本质区别**：

| | 09-16 那 5 次 | 本轮 |
|---|---|---|
| 触发方式 | `pmset sleepnow` / 到点 → 内核**先做常规睡眠**，再由 standby 转 | `hbfx-ahbm` 在**策略阶段直接改写** `params->sleepType` |
| 是否过 S3 语义 | 要 | **不要**（这是假设的核心） |
| `hibernatemode` | **25** ⇒ `pmset_default_mode = false` | **3** ⇒ `= true` |
| 是否开 ahbm | ❌ 从没开过 | ✅ **首次开** |

---

## 2. 本轮配置（已落地）

### 2.1 EFI（工作区 `EFI/oc/config.plist`，已自动同步到 ESP）

| 项 | 变动 | 说明 |
|---|---|---|
| `Kernel/Add` | **加回 `HibernationFixup.kext`**（idx 1，紧跟 Lilu） | 文件本就在 `EFI/oc/Kexts/`；**V1.5.4 = Latest，release note 原文 "Added constants for macOS 26 support"（2025-07-07）** |
| `boot-args` | **追加 `hbfx-ahbm=3 -hbfxdbg`** | `3` = bit0(启用自动休眠) + bit1(只在合盖时)；`-hbfxdbg` 为取证 |
| `rtcfx_exclude=0E-FF` | **保留** | 休眠密钥走 NVRAM，不依赖 RTC 放行；禁写 RTC 仍是防 005 的主防线 |
| `Misc/Boot/HibernateMode` | **保留 `NVRAM`** | 恢复侧设定，与保存侧不冲突 |

**为什么用 `hbfx-ahbm=3` 而不是 `1`**：
上游 README 原文 —— *"If this flag is set, system will hibernate instead of regular sleep (**flags below can be used to limit this behavior**)"*、
*"`WhenLidIsClosed` = 2: Auto hibernation can happen when lid is closed"*。
⇒ `1` = **每次**常规睡眠都改写成休眠（一旦失败，连现在唯一可用的 Deep Idle 都没了）；
⇒ `3` = **只在合盖时**改写 ⇒ `pmset sleepnow`（开盖）仍是常规 Deep Idle ⇒ **保留安全网**。

**为什么没加 `DoNotOverrideWakeUpTime`（bit6=64）**：源码里它会
`if (setupHibernate && doNotOverrideWakeUpTime && !forceHibernate) { if (vars->standbyTimer != 0) return result; }`
⇒ **取消休眠**，与目的相冲。（代价：会走一次 `setMaintenanceWakeCalendar`，见 §7 风险。）

### 2.2 pmset（**已设**）

```
sudo pmset -a hibernatemode 3 standby 1 standbydelaylow 86400 standbydelayhigh 604800
```

**★ 这两个 gate 是硬性前置，缺一个 ahbm 就 100% 假阴性。** 三条独立证据：

| # | 来源 | 原文 / 实测 |
|---|---|---|
| ① | **上游源码** `kern_hbfx.cpp:1197` `isStandbyEnabled()` | `pmset_default_mode = (latestHibernateMode == (kIOHibernateModeOn \| kIOHibernateModeSleep))` ⇒ **必须 == 3**；`standbyEnabled = deepSleepEnabled \|\| autoPowerOffEnabled` |
| ② | **本机现场 ioreg**（设之前） | `"Standby Enabled" = No`；且 **`AutoPowerOff` 属性根本不存在** ⇒ `standbyEnabled = false \|\| false = FALSE` ⇒ ahbm 代码块的 `while` **一次都不进** |
| ③ | **本机历史脚本** `EFI/scripts/pmset-hibernate.sh` 注释 | 「`hibernatemode` 单独设了不管用，必须同时给 `standby`」；「真正**不受支持**的只有 `autopoweroff`/`autopoweroffdelay`」|

设后的验证（实测）：

```
hibernatemode 3 · standby 1 · standbydelaylow 86400 · standbydelayhigh 604800
ioreg "Standby Enabled" = Yes      ← 已从 No 翻转
```

**为什么把 `standbydelay` 调大**：`standby` 启用后，睡满 `standbydelay` 会转入 standby（写镜像 + 断内存电）
—— 那正是**已知会挂**的路径。调大后 `standby` 只当"闸门"用，不会因超时误触发。

---

## 3. 测试步骤（需要人做）

1. **保存所有工作**（后面可能需要长按电源键强制关机）。
2. **重启**（kext 必须开机加载）。
3. **重启后先做 §4 的四项前置核验**（我来跑）。
4. **物理合盖**。
5. **等 40–60 秒。**
   - 观察：风扇是否停 / 键盘灯是否灭 ⇒ **断电 = 进了休眠**；风扇仍转 = 还在 Deep Idle。
6. **开盖**，等屏幕亮起。
7. **我取证**（§5）。

> ⚠️ 测试期间**保持插电**（电量 > 50% ⇒ 走 `standbydelayhigh`，不会超时触发 standby）。
> ⚠️ 不必先退出 WorkBuddy：`NoIdleSleepAssertion` 只挡**空闲自动睡**，不挡合盖。

---

## 4. 重启后的四项前置核验（缺一不可，否则测试无效）

| # | 检查 | 命令 | 期望 |
|---|---|---|---|
| 1 | boot-arg 是否真传到内核 | `nvram boot-args` | 含 `hbfx-ahbm=3` |
| 2 | **kext 是否真加载**（铁律①：用 IOKitDiagnostics 实例计数，不用 `ioreg -c`） | `ioreg -d 0 -l -w0 \| grep -c HibernationFixup` | **≥ 1** |
| 3 | pmset 是否还在（重启不重置，但要确认） | `pmset -g \| grep -E "hibernatemode\|^ standby"` | `3` / `1` |
| 4 | gate 属性 | `ioreg -rn IOPMrootDomain -d 1 \| grep "Standby Enabled"` | `Yes` |

---

## 5. 预期形态与判据

### ✅ 成功
- 合盖后 **10–30 s** 断电（风扇停）
- 开盖后从镜像恢复（比 Deep Idle 唤醒慢，屏亮约 10–20 s），桌面与时间正常
- `pmset -g log` 出现 **`Entering Hibernate`**
- `-hbfxdbg` 日志出现 `Auto hibernate: ... set hibernate values` / `hibernate now`

### ❌ 失败 A —— 同 09-16 签名（进休眠前硬断电）
- 合盖后直接断气；开盖**无任何反应**；`pmset -g log` 里这次会话**没有** `Wake from`
- 处理：**长按电源键**强制关机

### ❌ 失败 B —— POST 005
- 重启后 HP 屏报 `Real-Time Clock Power Loss (005)`，时间回到 `2019-01-01 08:00`
- 处理：**进 BIOS 重设时间 → F10 保存**（非永久损坏）
- 含义：本机在断内存电时 RTC 也丢电（与 §二十五 定论一致）

### ❌ 失败 C —— ahbm 没生效（仍走 Deep Idle）
- 合盖后正常深睡，功耗仍是 ~5 W，**无 `Entering Hibernate`**
- `-hbfxdbg` 日志显示以下任一条：
  - `Auto hibernate: clamshell is open, do not force to hibernate` ⇒ **合盖状态没被识别**（`Clamshell.app` 假合盖？）
  - `Auto hibernate: setupHibernate 0` ⇒ `standbyTimer` 等条件没满足
  - **完全没有 `HBFX` 日志** ⇒ kext 没加载 / boot-arg 没传进去
- ⇒ 说明是**配置问题而非平台问题**，可继续调（例如改用 `hbfx-ahbm=1` 去掉合盖限制）

**取证命令**（我来跑）：
```bash
pmset -g log | grep -E "Entering (Sleep|Hibernate)|Wake from" | tail -25
log show --last 20m --predicate 'process == "kernel"' 2>/dev/null | grep -i HBFX | tail -40
```

---

## 6. 回滚（一条命令）

```bash
# pmset 侧（立即生效）
sudo pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400

# EFI 侧（二选一）
cp docs/backups/hbfx-ahbm-2026-09-20/config.plist.before EFI/oc/config.plist   # 快照回滚
git revert <本轮 commit>                                                        # git 回滚
```
改完 EFI 后 **RealTimeSync 会在 3 秒内自动同步到 ESP**（方向：工作区 → ESP，单向）。

---

## 7. 风险（实测前已声明）

| 风险 | 量级 | 可否逆 |
|---|---|---|
| 写 8 GiB `sleepimage` | 磁盘占用 + SSD 磨损 | ✅ 可删 |
| 断电期间 RTC 丢电 ⇒ **POST 005** | 中等（09-16 为 3/5） | ✅ 进 BIOS 改时间 |
| 失败后需长按电源键 | — | ⚠️ 可能丢未保存数据 ⇒ **测试前保存** |
| 会走一次 `setMaintenanceWakeCalendar`（写 RTC 闹钟寄存器 `0x01/0x03/0x05`） | 低 | ① 不在 `rtcfx_exclude` 区间内，也不在休眠密钥区 `0x80–0xAB`；② 按 §二十五，005 的根因是"断电期 RTC 掉电"而非"写了某寄存器" |
| 固件 / SPI 写入 | **0** | — |

---

## 8. 台账（变动前值，供回滚核对）

| 项 | 变动前 | 变动后 |
|---|---|---|
| `pmset hibernatemode` | `0` | `3` |
| `pmset standby` | `0` | `1` |
| `pmset standbydelaylow` | `10800` | `86400` |
| `pmset standbydelayhigh` | `86400` | `604800` |
| `ioreg "Standby Enabled"` | `No` | `Yes` |
| `Kernel/Add` 数量 | 30 | **31** |
| `boot-args` | `…rtcfx_exclude=0E-FF -rtcfxdbg` | `…rtcfx_exclude=0E-FF -rtcfxdbg hbfx-ahbm=3 -hbfxdbg` |
| config.plist sha256（改前） | `a9c01104d146…` | `9051c778b67e…` |

备份：`docs/backups/hbfx-ahbm-2026-09-20/config.plist.before`

---

## 9. 待办（结果出来后）

- [ ] 更新 `EFI/scripts/pmset-hibernate.sh` 的**硬闸与结案注释** —— 它现在写着「本机真休眠已证伪，不要再用 auto/on/test」，
      而本轮正是要推翻它。硬闸是 `FORCE_HIBERNATE=1`，**不拦直接 `pmset -a`**（所以本轮能set上）。
- [ ] 若成功 ⇒ `s4-requirements-audit.md` §7.10(c) 由 🟡 升为 🟢，并改写"出远门关机"的默认结论。
- [ ] 若失败 ⇒ 「所有已知手段均已试过」，**"没解"才算真正闭环**。

---

# 🔬 10. 结果（2026-09-20 17:5x）—— **`hbfx-ahbm` 生效了，但被我设的参数自毁**

> 完整因果链（含内核日志与源码引用）→ **`round3-kernel-trace.md`**

## 10.1 先纠正一条上一轮的错误结论

**上一轮说的「17:25 那次被观察者效应打断、是无效测试」——错了。那次真的睡着了。**

| | 上一轮（错） | 实测 |
|---|---|---|
| 17:25:08 `pmset sleepnow` | 被打断 | ✅ 17:25:37 入睡 → 17:28:32 用户按电源键唤醒（175 s） |
| 17:34 那次（用户手动） | — | ✅ 17:34:48 入睡 → 17:36:29 唤醒（101 s） |
| 「没有 `Entering Sleep`」 | 当作没睡成的证据 | ⚠️ **假阴性** |

**两个叠加的错因**：
1. **读日志太早**：`pmset` 请求 → 真正入睡之间隔 **≈30 s**（显示器关 → `darkwakelinger` 15 s → 协商）。我在 17:25:14 就读了。
2. **`pmset -g log | tail` 是陷阱**：该命令**尾部是「当前断言摘要」块**，不是最新电源事件。必须按时间/关键字过滤（`grep "2026-09-20 17:2"`），不能用 `tail`。

## 10.2 实际发生了什么（内核日志一手）

```
17:25:37.396 PMRD: sleep params v2, type 5, flags 0x1   ← ★ HBFX 生效！type5=standby + 休眠标志
17:25:38.9xx （维护唤醒日历被设 ⇒ HBFX 钩子把它推迟 +86400 s ⇒ wakeCalendarSet 置真）
17:25:38.972 PMRD: sleep params v2, type 7, flags 0x0   ← ★ 打回 type7=deepidle（HBFX 不再覆盖）
17:25:39.609 PMRD: hibernateMode 0x0                    ← ★★★ 总闸：hibernatemode 被清零
17:25:39.841 PMRD: phase 2, ..., type 7                 ← 最终 = Deep Idle
```

**终局判据**：`kern.hibernatecount = 0`｜**无 `sleepimage`**｜`nvram` 无休眠变量｜`lastSleepType = 0x7/'Deep Idle'`｜唤醒 2 s。

## 10.3 病灶（源码级）

- XNU `IOPMrootDomain.cpp:5656-5669`：早评估(phase 1)拿到的 `sleepType` **属性位不含 `HibernateSetup`** ⇒ **`hibernateDisabled = true`**
- XNU `:5763`：`if (hibernateDisabled) *hibernateModePtr = 0;` ⇒ 就是日志那句 `hibernateMode 0x0`，**镜像一个字节都不写**
- `deepidle`（索引 7）的属性正是 `0`；`standby`（索引 5）才是 `HibernateSetup|HibernateSleep`
- HBFX `kern_hbfx.cpp:449`：`setupHibernate = (forceHibernate || !wakeCalendarSet || sleepServiceWake || standby_delay == 0)`
- HBFX 的 `IOPMrootDomain_setMaintenanceWakeCalendar` 钩子会用 **`standby_delay`** 推迟维护唤醒，并置 **`wakeCalendarSet = true`** ⇒ 反过来让 `setupHibernate = false`

**⇒ 我 `standbydelay` 设成 86400 s 之所以致命，不是"数值太大"，而是"不等于 0"** —— 只要 `standby_delay ≠ 0`，HBFX 的推迟钩子必然把 `wakeCalendarSet` 置真，`setupHibernate` 就翻成 false，它当场撤回自己的改写。**这次不是"救不了"，是"被参数挡死了"。**

> ⚠️ **修正（2026-09-20 18:1x，用户追问「确定当前配置会进 S4？」后复读源码）**：上一稿把机制写成"扳机被推到 24 h 之后"，**说法不准确**，并由此推出了错误的 §10.4 参数（120）。详见 `round3-kernel-trace.md` §1/§3.3/§4.2。

## 10.4 下一步（Round 3b，**只需 pmset，无需重启**）

> ⚠️ **参数已修正：`120` → `0`。** `standby_delay` 必须**等于 0** 才能走 `setupHibernate` 里那条不依赖 `wakeCalendarSet` 的分支；`120 ≠ 0`，命中同一条死路。

```bash
sudo pmset -a standbydelaylow 0 standbydelayhigh 0
pmset -g custom | grep -i standbydelay    # ★ 先读回，确认没被钳位
# 睡 ≥ 3 分钟；盯判据（完整 8 条 → next-test-agenda.md §2.3）：
#   PMRD: sleep params v2, type 5   ← **phase 1 也保持 5**（没被打回 7）← 最硬的一条
#   phase 2 的 type = 4（Hibernate，"hibernate now"）
#   PMRD: hibernateMode 0x3         ← hibernateDisabled 没被置真
#   sysctl kern.hibernatemode == 3  ← 现为 0；不必翻日志的实时判据
#   /var/vm/sleepimage 的 **mtime** 落在本次睡眠时刻 + kern.hibernatecount > 0
```

> ⚠️ **判据纠错（2026-09-20 18:4x）**：初稿写"`sleepimage` 出现"——**无效**。该文件**一直存在**（1 GiB，`mtime` = 开机时刻 17:19 的占位文件）⇒ 必须看 `mtime`。

**为什么 `0` 能行（源码级推断，非实测）**：`standby_delay == 0` ⇒ `setupHibernate` 无条件为真；且钩子的推迟分支要求 `standby_delay != 0` ⇒ `wakeCalendarSet` 保持 `false` ⇒ 两个条件同时满足。
**旁证**：17:25:37.396 那次 `standbyTimer = 0`（日志因子 `StandbyNoDelay`），HBFX **确实**设成了 `type 5` ⇒ "无待机延迟"状态在本机可达。

**★ 机制已细化到行号（18:4x）**：R3 的 `type5 → type7` 是 **HBFX 在 `phase > 0` 时自我推迟**（`hbfx2.cpp:437-438` 自己调 `explicitlyCallSetMaintenanceWakeCalendar()`），同一调用里 `:449` `setupHibernate` 即变 false ⇒ `:468` 不覆盖。**`phase 0` 反而成功，是因为 `:437` 有 `> kIOPMSleepPhase0` 门槛** ⇒ 这正好解释 R3 日志的"phase0 设成 5、1.58 s 后被翻回 7"。

⚠️ **两处待验坑**：
1. `pmset` 是否接受 `standbydelaylow 0`（`pmset` 二进制**无范围校验串**，只能读回验证；若被拒绝/钳位 ⇒ 此路封闭）。
2. 走到 `type 4/5` 后，XNU `IOPM.cpp:5743-5746` 会 `gIOHibernateMode &= ~kIOHibernateModeSleep`（**关掉 Sleep 位、强制真休眠**）⇒ 正是 09-16 硬断电那一步，**风险实打实**。

⚠️ **`0` 的语义 = "立即"**（`man pmset`：*"…before writing the hibernation image to disk and **powering off memory**"*）⇒ **睡后立刻断内存电**，且**生效期间每一次睡眠都这样**（合盖也走）⇒ **测完必须立刻回滚，别留过夜。**

**回滚（只回滚这一个变量）**：`sudo pmset -a standbydelaylow 86400 standbydelayhigh 604800`
（要**整体退出 R3 测试态**回基线是**另一次**独立改动：`sudo pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400` —— 别混在一起。）

> **★ 完整议程（还剩什么可测 / 什么已判死）→ `next-test-agenda.md`**（18:4x 新建；含 ①R3b ②T4(OC 日志核 MMIO) ③Win 功耗量准 ④`dmpstore` 顺带，以及本轮新增的 2 条源码级排除：`hbfx-ahbm=65` 无增量、`autopoweroff` 机型级不存在）。

## 10.5 本轮零配置改动

纯只读取证。EFI 与 pmset 仍为 R3 测试态。**两次睡眠后均无 POST 005、时钟正常。**
