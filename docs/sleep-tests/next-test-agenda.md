# 下一批测什么 · 测试议程（2026-09-20 18:4x）

> **触发**：用户问「**那我们这几次再测什么？**」
> **本轮零配置改动**（纯只读核查：`pmset -g custom` / `man pmset` / `ioreg IOPMrootDomain` / `plistlib` 读 config / `strings` 读 kext 二进制 / 上游源码 `IOPM.cpp` + `hbfx2.cpp`）。
> **本文是"还剩什么可测"的唯一入口。** 已判死的项在 §3，不必再翻别处。

---

## 0. 一句话

> ### 🟣 2026-09-21 10:5x 更新（社区调研）→ `community-hibernation-recipes.md`
> **⚠️ 修正本文与 README 的「已试过的配置空间扩到最大」：该表述只对 OS 侧成立。**
> - **OS 侧（`pmset`）**：基本到顶 —— `mode 25` ×5 ＋ `mode 3 + standbydelay 0`（硬失败）＋ `mode 3 + standbydelay 86400·604800`。
> - **引导器侧（`config.plist`）**：**4 项从未入账** —— `UEFI/ReservedMemory`（0 条）｜`DiscardHibernateMap`（False）｜`RebuildAppleMemoryMap`（True）｜`DevirtualiseMmio`（True，且 `MmioWhitelist` 0 条）。而社区成功配方里这些是**常备项**。
> - **★★ 更关键**：两个独立来源（github T530 帖 + Latitude 5300 帖）都指名 **`Disable RTC wake scheduling` 内核补丁会掐掉 RTC 闹钟 ⇒ dark wake 不发生 ⇒ 永远到不了休眠判定**；**本机该补丁正开着**（`Kernel/Patch` / `com.apple.driver.AppleRTC`）⇒ **R3「仍 Deep Idle」很可能不是平台的错**，且那次 `standbydelay` = **86400 s（24 h）**，参数本身测不出结果。
> ⇒ **新增候选议程 ⑤（唯一有社区先例、本机从未测过的一项）**：`关 RTC 唤醒补丁 + hbfx-ahbm=1 + standbydelay 7200 + mode 3`。**判据/回滚/风险定价见 `community-hibernation-recipes.md` §6。⚠️ 未执行，等你拍板。**

> ### 🔴 2026-09-21 更新：**① 已执行完毕 ⇒ 判「不通」**（`r3b-result.md`）
> 09-20 19:01:12 上机 → 19:02:41 睡下 → **内核停摆 5.7 min** → 19:08:23 已是新 boot ⇒ **未写镜像、未正常唤醒、需强制断电**（09-16 同档）。判据 **8/8 未达标**。**`hbfx-ahbm` 这条路到此为止。**
> ⇒ **下面"只剩 3 件事"应读作"只剩 ②③④"**，且**没有一件能解锁 S4**。
> ✅ **09-21 10:20 收口**：用户确认 **BIOS 报 POST 005**（＋ 本轮新证据：`/var/run/utmpx` 原始 int64 = `2019-01-01 08:00:44`，四源同值）⇒ **RTC 被写坏坐实**，写坏的是 **21:03 那次合盖睡眠**（即看门狗失效的连带后果）。
> ⚠️ **代价模型变了**：**武装休眠 ⇒ 写坏 RTC 现为 4/4（09-16 三次 ＋ R3b 一次）= 既定代价，不是概率**。⇒ 剩余 ②③④ **全都不碰 RTC / 不写睡眠镜像**，这是它们现在唯一的"低风险"依据；**任何新增的"真休眠"实验都必须按"会 POST 005 + 时钟回 2019"定价**。

**只剩 3 件事可测**，其中**只有 ① 能解锁 S4**；②③ 是"核账"和"量准"，与"S4 能不能实现"无关；④ 是顺手捎带且**门后是死路**。

---

## 1. 议程表（按 信息价值 ÷ 代价×风险 排序）

| # | 测什么 | 代价 | 风险 | 能定什么 | 关闭条件 |
|---|---|---|---|---|---|
| **①** | ~~**`standbydelaylow/high = 0`**（Round 3b）~~ ✅ **已执行完（09-21 收账）** | **2 条 `pmset`，不用重启、不用碰 EFI** | 🔴 **高**：走到 `sleepType 4/5` ⇒ `IOPM.cpp:5743` 关掉 Sleep 位 = **强制真休眠** = 09-16「睡下即断气」同一档 | ~~**`hbfx-ahbm` 这条路到底通不通**（唯一未测的杠杆）~~ ⇒ **已定：不通**（硬失败，`r3b-result.md`） | ✅ **已关闭**：通 ⇒ S4 有戏；不通 ⇒ **"已试过的配置空间"扩到最大**（已达成） |
| **②** | 开 OC 日志（`Misc/Debug/Target≠0`）核 `DevirtualiseMmio` / `MmioWhitelist` | EFI 改 1 位 + 重启 + 复测 | 🟢 低（git 可回退） | OC 官方明文把该 quirk 与 *"proper NVRAM **and hibernation** functionality"* 挂钩，是**唯一被上游点名 hibernation 且本机从未核**的项 | 拿到日志 ⇒ 判"`MmioWhitelist` 0 条是否够" |
| **③** | **Windows 侧功耗量准**（`powercfg /sleepstudy`） | 重启进 Win + 静置数小时 | 🟢 零 | "两侧功耗差"到底值多少 —— 现有 **macOS 6–11 %/h**，**Win 从未测过** ⇒ 目前是未知数 | 拿到 %/h，与 macOS 对比出"档位差"的绝对值 |
| **④** | UEFI Shell `dmpstore -all`：查 `Modern Standby` 变量、`CSM` 状态 | 需重启进 OC Shell 敲命令 | 🟢 只读零风险 | CSM 的真实状态；`Modern Standby` UEFI 变量是否可写 | ⚠️ **但门后是 S3，而本机 S3 已判死**（§3.4）⇒ 价值≈0，**降级为"顺手做"，别专门为它重启** |

**⚠️ 成本最低、收益最高的是 ①。** ①②③ 应**串行**做（每次只动一个变量），不要并行。

---

## 2. ① 详版：Round 3b = `standbydelay 0`

### 2.1 前置条件已全部就位（本轮实读，不是记忆）

| 项 | 实测值 | 出处 |
|---|---|---|
| `hibernatemode` | **3** ✅（HBFX 的 `pmset_default_mode` 要求 == 3，不是 25） | `pmset -g custom` |
| `standby` | **1** ✅ | 同上 |
| `standbydelaylow / high` | 86400 / 604800 ← **唯一要改的两个值** | 同上 |
| `HibernationFixup.kext` | **在 `Kernel/Add` 里** ✅（1.5.4） | `plistlib` 读 config |
| `boot-args` | `… hbfx-ahbm=1 -hbfxdbg` ✅（config 与 `nvram boot-args` 一致） | 两处实读 |
| `NVRAM/WriteFlash` | **true** ✅（HBFX 写 NVRAM 的前提） | 同上 |

⇒ **R3b 不需要动 EFI、不需要重启**，只要两条 `pmset`。

### 2.2 ★ 源码级预测（比上轮更硬：细化到行号，逐 phase 可对号）

上一轮我说"钩子把 `wakeCalendarSet` 置真"。**本轮把机制读到了行号，发现更直白 —— 是 HBFX 自己在下一次 phase 里把自己关掉的**：

`hbfx2.cpp:437-438`（**同一函数的入口段**）：
```cpp
if (callbackHBFX->sleepPhase > kIOPMSleepPhase0) {
    if (standby_delay != 0 && !forceHibernate && !callbackHBFX->wakeCalendarSet && !callbackHBFX->sleepServiceWake)
        callbackHBFX->explicitlyCallSetMaintenanceWakeCalendar();   // ← 自己把 wakeCalendarSet 置 true
}
```
紧接着**同一个调用里**：
- `hbfx2.cpp:449`：`setupHibernate = (forceHibernate || !wakeCalendarSet || sleepServiceWake || standby_delay == 0)` ⇒ 因上一步刚把 `wakeCalendarSet` 置真 ⇒ **`setupHibernate = false`**
- `hbfx2.cpp:468`：`if (sleepPhase < kIOPMSleepPhase2 && setupHibernate)` ⇒ **不成立 ⇒ 不覆盖 `params->sleepType`** ⇒ 平台原值 `deepidle(7)` 胜出

**这正好解释 R3 的日志为什么是"phase0 成功、1.58 s 后被翻"：**

| phase | `sleepPhase > 0`? | `:437` 是否自我推迟 | `setupHibernate` | 结果 |
|---|---|---|---|---|
| **phase 0** | ❌ 否（门槛挡住） | 不执行 | **true** | `:472-473` ⇒ **`type 5, flags 0x1`**（= R3 日志看到的） |
| **phase 1** | ✅ 是 | **执行 ⇒ `wakeCalendarSet = true`** | **false** | 不覆盖 ⇒ 平台 `type 7` 胜出（= R3 日志看到的） |
| phase 2 | ✅ 是 | 已 true，不再重复 | false | 不覆盖 ⇒ `deepidle` 定案 |

**⇒ `standbydelay == 0` 时：**
- `:437` 的 `standby_delay != 0` **不成立** ⇒ **不自我推迟** ⇒ `wakeCalendarSet` 保持 **false**
- `:449` ⇒ `setupHibernate = true`（且 `|| standby_delay == 0` 这条也独立命中，**双重满足**）
- `:468` ⇒ **phase 1 覆盖成功 ⇒ `type 5, flags 0x1` 保持住**
- `:477-484` ⇒ **phase 2 改成 `params->sleepType = kIOPMSleepTypeHibernate`（type 4）+ `flags 0x1`**（日志原文 "hibernate now"）

### 2.3 判据（★ 其中一条是我上轮写错的，必须改）

`type 5` 的属性位 = `kIOPMSleepAttributeHibernateSetup | kIOPMSleepAttributeHibernateSleep`（`IOPM.cpp:5305-5312` 的属性表，本轮逐条读过）
⇒ ① `hibernateDisabled` 不会被置真；② `IOPM.cpp:5743` 会 `gIOHibernateMode &= ~kIOHibernateMode_Sleep`（**关 Sleep 位 = 强制真休眠**）。

| # | 判据 | 期望（成功） | R3 时实测 |
|---|---|---|---|
| ① | `PMRD: sleep params v2, **type 5, flags 0x1**` | **phase 1 也保持 5** ← **本轮新增的最硬判据** | phase1 变 7 ❌ |
| ② | `phase 2` 的 type | **4（Hibernate）** | 7 ❌ |
| ③ | `PMRD: hibernateMode` | **0x3** | 0x0 ❌ |
| ④ | **`sysctl kern.hibernatemode`** | **3** ← **本轮新增：比翻日志方便的实时判据** | **0** ❌ |
| ⑤ | **`/var/vm/sleepimage` 的 `mtime`** | 落在**睡眠时刻** | 见下方纠错 ❌ |
| ⑥ | `kern.hibernatecount` | **> 0** | 0 ❌ |
| ⑦ | NVRAM 出现休眠变量（`IOHibernateRTCVariables` 等） | 有 | 无 ❌ |
| ⑧ | `pmset -g log` | `Entering Hibernate` | 只有 `Entering Sleep` ❌ |

> ⚠️ **判据 ⑤ 的纠错（我上轮写错了）**：`/var/vm/sleepimage` **一直存在** —— 本轮实读 `-rw------T 1 root wheel 1073741824 2026-09-20 17:19`，**1 GiB、`mtime` = 启动时刻 17:19** ⇒ 那是**开机建的占位文件**。
> ⇒ **"有没有 sleepimage"是无效判据**（恒为"有"）；必须改看 **`mtime` 是否等于本次睡眠时刻** + 判据 ⑥④。
> （这与既有记载一致：历史上真见过合格镜像的次数 = 0，"1 GiB"就是 macOS 自建的占位形态。）

### 2.4 风险（说清楚，不美化）

`man pmset` 本轮原文（**新证据**）：
> `standbydelayhigh and standbydelaylow specify the delay, in seconds, before **writing the hibernation image to disk and powering off memory for Standby**.`

⇒ **`0` = 睡眠后立即写镜像 + 断内存电。** 所以 ① 的"成功"与"是否断气"**不是两个赌注，是同一件事的两种结果**：

- 若 HBFX 的休眠事务**能走通** ⇒ 这就是我们要的 S4（真休眠、≈0 W），**且顺带给出 `#29`（EC 在 S4 进出）的第一个数据点**
- 若卡点其实在 S4 事务本身（不是配置）⇒ **重现 09-16 的「睡下即断气 + POST 005」**

⚠️ **地雷**：`standbydelay 0` 生效期间，**之后每一次睡眠都会立即走"写镜像 + 断内存电"**。而本机 `Clamshell.app` 让**合盖睡眠可行** ⇒ **万一忘了回滚，下次合盖就炸**。⇒ **必须"测完立刻回滚"，别留过夜。**

### 2.5 执行 / 回滚

```bash
# 改（唯一变量：standbydelay）
sudo pmset -a standbydelaylow 0 standbydelayhigh 0
pmset -g custom | grep -i standbydelay        # ★ 先读回：确认没被钳位（0 仍是 0）

# 睡 ≥3 分钟（等 phase2 真正发生），然后唤醒，查 §2.3 的 8 条判据

# 立刻回滚
sudo pmset -a standbydelaylow 10800 standbydelayhigh 86400
pmset -g custom | grep -i standbydelay        # 复核
```

**两个已知梗**：① `pmset` 二进制里**没有任何 standbydelay 范围校验串**（本轮 `strings` 实查）⇒ 校验在 IOPM 侧，是否接受 `0` **只能读回验证**；② 读日志仍需 `osascript … with administrator privileges`（沙箱跑不了 `log`），且要带 `--info --debug`。

### 2.6 刻意**不**并入 R3b 的第二变量

**`-hbfxdbg` 是无效的（本轮定论）**：`strings` 查 `HibernationFixup.kext/Contents/MacOS/HibernationFixup`，`"Auto hibernate"` 串 **0 条**、`"HBFX"` 只有 1 条（仅作 syslog 前缀）⇒ **装的是 RELEASE 版，`DBGLOG` 被编译掉了** ⇒ 这就是 R3 日志里 HBFX 段全空的原因（上一轮标 🟡 待定，现结案）。
⇒ 想要 HBFX 侧的 `setupHibernate / wakeCalendarSet / standby_delay` 逐 phase 轨迹（`hbfx2.cpp:465-466` 那一行），**必须换 DEBUG 版 kext**（= EFI 改动 + 重启）。
⇒ **但它不并入 R3b** —— 一次只动一个变量。R3b 用 XNU 侧判据（§2.3）已足够判定；若 R3b 结果**模棱两可**，再单独做"DEBUG kext"这一步。

---

## 3. 已排除 · 不必再测（含本轮新增的 2 条源码级排除）

### 3.1 ★【本轮新增】`hbfx-ahbm=65`（bit 64 `DoNotOverrideWakeUpTime`）——**我本来以为是捷径，源码级否掉**
- **动机**：`hbfx2.cpp:678` `size_t size = arrsize(requests) - (doNotOverrideWakeUpTime ? 1 : 0);` ⇒ 置 bit64 时 HBFX **根本不安装** `setMaintenanceWakeCalendar` 钩子（`explicitlyCallSetMaintenanceWakeCalendar()` 也在 `:1218` 直接 early-return）⇒ 理论上 `wakeCalendarSet` 永远为 false ⇒ "不用改 `standbydelay` 也能解锁"。
- **否掉的原因**：`hbfx2.cpp:450-463`：
  ```cpp
  if (setupHibernate && doNotOverrideWakeUpTime && !forceHibernate) {
      if (vars->standbyTimer != 0) { DBGLOG(… "cancel hibernate"); return result; }   // ← 主动取消
      else                        { DBGLOG(… "enable hibernate"); }
  }
  ```
  ⇒ 只要 `standbyTimer != 0`（`standbydelay ≠ 0` 时就是它）**HBFX 会主动取消休眠** ⇒ **净效果与不置 bit64 完全相同**。
- ⇒ bit64 只有在 `standbyTimer == 0`（= `standbydelay 0`）时才"enable hibernate" —— **那正是 ①**。**⇒ 无增量，不用测。**

### 3.2 `autopoweroff` / `autopoweroffdelay`
`pmset -g custom` 本轮实读**根本没有这两项**（`pmset -g cap` 同样无）⇒ **机型级不支持** ⇒ 这个杠杆在本机不存在。
（它本是"AC 侧的深睡计时器"，`man pmset` 有定义，但本机固件/SMC 未提供 ⇒ AC 上没有深睡计时器，这也是"插电只能靠 ①"的由来。）

### 3.3 `hibernatemode 25`（真休眠-立即断电）
09-16 实测 **5 次全部失败**（`睡下即断气` + POST 005），且源码层 `pmset_default_mode` 要求 `hibernatemode == 3`、`25` 会让 HBFX 的 `while` 循环**一次都不进** ⇒ 双重判死。

### 3.4 S3 与"关 AOAC"
- **S3 已判死（实测）**：撤 `\_SB.LPS0`（macOS 声明层）**真跑过** ⇒ 确实转 S3 ⇒ **EC 罢工**（`EC OBF=1 poll timed out` 连绵 ⇒ USB 栈 panic）。
- **关 AOAC 四层全无入口**：macOS 声明层 ✗ / Win 声明层（`PlatformAoAcOverride` 不存在）✗ / 固件菜单层（WMI `IsReadOnly=1` + `DisplayInUI=0`）✗ / 魔改层（无 IFR ⇒ `setup_var` 无偏移）✗。
- **★ 本轮合成的一条判断（新）**：**就算 ④ 的 `dmpstore` 证明 `Modern Standby` 变量可写、AOAC 真能关掉，落点也是那条已经坏掉的 S3。** ⇒ **"关 AOAC"这条整链的终点是死的** ⇒ ④ 的价值从"待探的门"降到"顺手捎带"。

### 3.5 其他
`撤 SSDT-DeepIdle`（⇒ S3 ⇒ EC 罢工，实测过）｜ASPM 注入（已撞墙）｜`pmset schedule wake`（**禁令**：写 RTC ⇒ POST 005）｜`SSDT-AWAC` 撤除（Dortania 明文：老式 RTC 正是 macOS 需要的，撤掉是反方向）。

---

## 4. ②③④ 的补充说明

### ② T4 · OC 日志核 MMIO（本轮实读：配置形态**已就位**，缺的只是"证据"）
| 项 | 实测值 | 说明 |
|---|---|---|
| `Booter/Quirks.DevirtualiseMmio` | **true** ✅ | 已是 OC 推荐形态 |
| `Booter/MmioWhitelist` | **0 条** ✅ | 未知的是**"0 条是否够"** |
| `Misc/Debug/Target` | **0** ❌ | ⇒ **没有任何 OC 日志可判**，这是唯一的缺口 |

⇒ 只要把 `Target` 置为 `1`（或 `0x2` 带 DATA）、重启、复测，就能看到 MMIO 是否真被 devirtualise。**它是 ① 失败后的下一步，不与 ① 并行。**

### ③ 功耗量准（与 S4 无关，独立价值）
现状：macOS 侧**实测 6–11 %/h（≈4–7.5 W）**；**Windows 侧从未测过**。而 `powercfg /a` 实测 Win **有 S4 + Adaptive Hibernate** ⇒ 若 Win 也是 ~7 %/h，说明**两侧其实是同一档**、"档位差"假设要修正；若 Win 明显更低，才坐实"macOS 少一档"。工具是 Win 独有的 `powercfg /sleepstudy`。

### ④ 建议怎么顺手做
下次**因为别的原因**进 Windows / OC Shell 时捎带：`dmpstore -all`（只读）dump 后搜 `Modern Standby` / `Setup` / `CSM`。**不要专门为它重启。**

---

## 5. 建议（需用户拍板）

1. **先做 ①**（唯一的解锁性测试）。它是"`hbfx-ahbm` 这条路通不通"的最后一次实验；**无论成败，这一条做完，"已试过的配置空间"就扩到最大**：
   - **通** ⇒ S4 有戏，接着做 `#29`（EC 在 S4 进出）+ 装 DEBUG HBFX 拿轨迹
   - **不通** ⇒ **"没解"才算真正闭环**（而不是像现在这样"还差一个没测"）
2. ① 结束后按结果决定 ②；③ 可以独立排在任意空档。
3. **R3b 的账仍要记**：`pmset -a` 两条 + 回滚两条 + 日志抓取（`osascript` 提权）。
4. **不做的事**：不为 ④ 专门重启；不并行改第二个变量；`standbydelay 0` **不留过夜**。

---

## 6. 本文本轮新增的一手证据清单（证据分级）

| # | 证据 | 级 |
|---|---|---|
| 1 | `hbfx2.cpp:437-438` HBFX 在 phase>0 时**自伤**（自我推迟 ⇒ 同一调用内 `setupHibernate` 变 false）—— 比上轮"OS 调钩子"的表述更准确 | 🟢 上游源码原文 |
| 2 | `hbfx2.cpp:449/450-463/468/477-487`：phase0 → `type5`、phase2 → `type4`、bit64 会 cancel | 🟢 上游源码原文 |
| 3 | `hbfx2.cpp:678` + `:1218`：bit64 使钩子**不安装** ⇒ 但被 `:450` 抵消 | 🟢 上游源码原文 |
| 4 | `IOPM.cpp:5305-5312` 属性表逐条：`4/5/6` = `HibernateSetup\|HibernateSleep`；`3` = 仅 `Setup`；**`7` = 0** | 🟢 上游源码原文 |
| 5 | `IOPM.cpp:5743-5746` = 本轮定位的行号（此前只记 5743 这个起行） | 🟢 上游源码原文 |
| 6 | `man pmset`：`standbydelay` = "*…before writing the hibernation image to disk and powering off memory*" | 🟢 官方文档 |
| 7 | `pmset -g custom` 实读：`3 / 1 / 86400 / 604800`（Battery 与 AC 同值） | 🟢 本机一手 |
| 8 | `ioreg IOPMrootDomain`：`IOPMSystemSleepType=7`、`IOPMDeepIdleSupported=Yes`、`Hibernate Mode=3`、`Standby Delay=86400`、`Standby Timer=604800`、`IOHibernateState=<00000000>` | 🟢 本机一手 |
| 9 | `strings` 查 HBFX 二进制：`"Auto hibernate"` **0 命中** ⇒ **RELEASE 版，`-hbfxdbg` 无效** | 🟢 本机一手 |
| 10 | `/var/vm/sleepimage` **存在**（1 GiB、`mtime`=启动 17:19）⇒ **"有无 sleepimage"是无效判据**（纠正上轮） | 🟢 本机一手 |
| 11 | `sysctl kern.hibernatemode` = **0**（而 `pmset` 偏好 = 3）⇒ 实时判据 | 🟢 本机一手 |
| 12 | `autopoweroff` 不在 `pmset -g custom` ⇒ 机型级不支持 | 🟢 本机一手 |
| 13 | `DevirtualiseMmio=true` / `MmioWhitelist=0` / `Misc/Debug/Target=0` / `NVRAM/WriteFlash=true` / `HibernationFixup` 在 `Kernel/Add` / `boot-args` 含 `hbfx-ahbm=1 -hbfxdbg` | 🟢 本机一手 |
| 14 | "就算关掉 AOAC，落点也是坏掉的 S3" —— **合成判断**（由已实测的 S3 判死 + AOAC 链条推出） | 🟡 推断（标出） |
| 15 | "R3b 会保持 type5" —— 由 #1#2#4 推出的**预测**，**尚未实测** | 🟡 推断（标出） |

> ⚠️ **#14 #15 是推断，不是结论。** 本机尚无 `standbydelay 0` 的任何实测记录。
