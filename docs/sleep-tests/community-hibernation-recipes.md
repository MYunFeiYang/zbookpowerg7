# 社区是怎么进入休眠的？—— 四条路线、证据分级、与本机的差异矩阵

> 建档：2026-09-21｜触发问题：用户问「社区别人是怎么进入休眠的？都确认了吗？」
> 方法：按既定查证纪律执行 —— ① 上游仓库 README/文档逐字 ② 平台汇总仓库 issue ③ 症状原话搜论坛。
> **本文只归档"别人怎么做"和"证据强度"，不构成本机可用的结论。**

---

## §0 一句话

**主流社区根本不做休眠 —— Dortania 官方明写「avoid the black magic that is S4」。**
真正进去的分四类人，**三类都要先有一台 S3 正常的机器**；最像我们（AOAC/S0ix 固件）的那一类（Surface IceLake 组）靠**在 DSDT 里把 `SS3` 从 Zero 改成 One** 解锁 S3 声明 —— **而这个状态我们的机器出厂就有**（DSDT:5708 `Name (SS3, One)`）。
⇒ 结论：**"(5 种成功配方里) 与我们的差别"不在 S3 声明，而在两处我们从未试过的地方**（见 §5）。

---

## §1 四条路线（按"证据强度"由高到低）＋ 确切配置

### 路线 0 ★ 最主流：**不做**（Dortania 官方立场）

`dortania.github.io/OpenCore-Post-Install/universal/sleep.html` 逐字原文：

```text
sudo pmset autopoweroff 0
sudo pmset powernap 0
sudo pmset standby 0
sudo pmset proximitywake 0
sudo pmset tcpkeepalive 0
```
> 1. Disables autopoweroff: **This is a form of hibernation**
> 3. Disables standby: **Used as a time period between sleep and going into hibernation**

```text
*   `Misc -> Boot -> HibernateMode -> None`
    *   We're gonna avoid the black magic that is S4 for this guide
```

> **这是"社区是怎么进入休眠的"最诚实的答案**：绝大多数人不进 —— 官方指南的第一动作是**把通往休眠的三条通道（autopoweroff / standby / HibernateMode）逐一关掉**。
> 本机曾经的基线（`hibernatemode 0 / standby 0 / standbydelay 10800·86400`）**就是路线 0 的产物**。

---

### 路线 1 ★★ **解锁 S3 声明 + HibernateMode=NVRAM**（**唯一的 AOAC 机型成功组**）

`github.com/balopez83/Surface-Pro-7-Hackintosh/issues/7`（标题原文：*Fix for Hibernation (hibernatemode 25) on IceLake Surface devices*）

**已确认机型 / 版本（作者自报）**：
- Surface Pro 7（i5）— macOS 13.6.7 Ventura ✅
- Surface Laptop 3 15"（i7）— macOS 14.5 Sonoma ✅
- Surface Laptop Go 1（i5）— macOS 13.6.7 Ventura ✅
- Surface Book 3 — "very likely（untested）"

**关键补丁（作者原话 "The key to the fix is to enable ACPI S3 Sleep in the DSDT"）**：

| 位置 | 内容 |
|---|---|
| `ACPI → Patch` | Comment: `Rename Name (SS3, Zero) to One - Enable S3 Sleep`｜Find: `5353335F00`｜Replace: `5353335F01` |

补丁前后内核日志（作者逐字给出）：
```
补丁前：(AppleACPIPlatform) ACPI: sleep states S4 S5
补丁后：(AppleACPIPlatform) ACPI: sleep states S3 S4 S5
```
> 作者同时明说：**"ACPI S3 Sleep (hibernatemode 0) is still broken, though"** ——
> ⇒ **休眠能用 ≠ S3 能用。这两个状态是解耦的。**

**其余配置**：`UEFI/NVRAM → ReservedMemory`（Address `569344` / Size `4096` / Type `RuntimeCode`，治唤醒黑屏；注明来自 Tyler Nguyen 的 x1c6-hackintosh）｜`Booter→Quirks→DiscardHibernateMap=true`（SL3 上治唤醒 KP）｜`Misc→Boot→HibernateMode=NVRAM`｜`HibernateSkipsPicker=true`｜`SSDT-GPRW.aml` + `GPRW`→`XPRW` 改名（SP7 / Laptop Go 1 需要，治秒醒）｜`pmset -a hibernatemode 25`。

---

### 路线 2 ★★ **HibernateMode=NVRAM + ReservedMemory + 关 RTC 补丁**（S3 本来就好的机器）

`github.com/5T33Z0/Lenovo-T530-Hackintosh-OpenCore/issues/48`（ThinkPad T530，Ivy Bridge）

作者原话（**"reliable so far"，Catalina + Sonoma 双版本**）：

```text
To fix hibernation you will the kexts HibernationFixup and RTCMemoryFixup
- Add rtcfx_exclude=80-AB to boot-args
- Set HibernateMode to NVRAM in Misc/Boot
- Set RebuildAppleMemoryMap to False in Booter/Quirks
- Use the following ReservedMemory entry  (ReservedMemory.plist.zip)
- Optionally set HibernateSkipsPicker in Misc/Boot to true
To fix a black screen that happens after hibernating and waking once and then try to hibernate again
- Enable the DiscardHibernateMap Booter quirk
- Reset NVRAM
```
后续自测更新：**"I don't need RTCMemoryFixup"**（`HibernateMode=NVRAM` + ReservedMemory + `DiscardHibernateMap` 三项就够）。

同帖另一位（jozews321，ThinkPad T430）把**运行时序**逐字写清楚了 —— 这段是本文最有价值的一条：

```text
In hibernationmode=3 it's normal that the laptop darkwakes up when the time in standbydelayhigh
elapses, in this moment it does the logic if it should enter hibernation or not, the main
requirement to make a hibernation in this darkwake is to have the boot-arg hbfx-ahbm set to at
least 1 if it's not set it's never going into hibernation and the laptop will just sleep again.
I have personally set hbfx-ahbm to 5 and both standbydelay to 10800 so it wakes up after 3 hours
and only enters hibernation when it's disconnected from AC
...
Turn out the fault was the Disable RTC wake scheduling kernel patch that was preventing the RTC
to wake the laptop in the scheduled time. I enabled the patch a long time ago ... So you should
disable that kernel patch too, i see that you have that kernel patch enabled in your config too.
```

⇒ **hibernatemode 3 的用时序**：① 睡下 → ② `standbydelay` 到点，**由 RTC 闹钟 dark wake** → ③ 在 dark wake 里做"要不要休眠"的判定（**必须 `hbfx-ahbm ≥ 1`**，否则它只是又睡回去）→ ④ 满足条件才写镜像 + 断 RAM。
⇒ **掐掉 RTC 唤醒调度补丁 = 第 ② 步永远不发生 = 永远到不了第 ③ 步。**

---

### 路线 3 ★★★ **有实测时间戳的完整证据**（Dell Latitude 5300 2-in-1）

`github.com/AppleBreak1/Dell-Latitude-5300-2-in-1-Hackintosh` —— 标题原文 **"Standby / Hibernatemode (Works)"**，并附**电源事件日志**（这是全社区我见过最硬的一手证据）：

**hibernatemode 3 + standbydelay 7200**：
```
00:23:11  合盖 → 普通睡眠（S3/S0ix）
02:23:33  2 小时后 RTC 闹钟 dark wake（这 2 小时耗电 ≈ 3%）
02:23:38  从普通睡眠转入 standby
07:59:38  用户唤醒（这 5 小时 standby 耗电 = 0%）
```
**hibernatemode 25**：
```
11:41:15  空闲睡眠 → 立即进 standby
18:02:35  6 小时后用户唤醒（耗电 = 0%）
```

配置清单（逐字）：
> `Hibernatemode 3` → `pmset hibernatemode 3` + `pmset standby 1`｜`Misc -> Boot -> Hibernatemode -> NVRAM`｜`Misc -> Boot -> HibernateSkipsPicker -> Yes`｜**`Do not apply AppleRTC kernel patch if applied (patch to disable RTC wake scheduling)`**｜`Inject HibernationFixup.kext`｜`Add boot-arg -> hbfx-ahbm=5`｜`pmset -a standbydelay 7200`

同源另见：`github.com/jlempen/Yoga-Duet-7-13IML05-OpenCore`、`Surface-Laptop-3-OpenCore`（"Disabling Sleep and enabling Hibernate … as we still haven't found a solution for the Sleep/Wake issues"）。
⚠️ 后者附了一条**重要的负面细节**：
> *"once the Surface Laptop 3 hibernates, you need to let it hibernate for a couple of minutes before waking it up. Failing to do so will disrupt hibernation and the device will hang. You'll have to turn it off forcefully by pressing on the power button for 10 seconds."*
> —— 与本机 R3b 的"睡下后内核停摆、需强制断电"**形态上同款**，但那是**唤醒太早**造成的，不是必然失败。

---

### 路线 4 ★ 台式机 / Chromebook

| 来源 | 机型 | 配方 | 自评 |
|---|---|---|---|
| `insanelymac.com/forum/topic/355419` | Intel HD 630 纯核显**台式机** | 删 `SSDT-SBUS-MCHC.aml` + `hibernatemode 25` + `HibernateMode=NVRAM` | **"90% Solved"** —— 首屏蓝屏 glitch，需等屏灭再唤醒；有人照抄到 ThinkCentre M700 ✅ |
| `docs.chrultrabook.com/docs/installing/macos-hibernation` | Chromebook（coreboot） | `Booter/Quirks/DevirtualiseMmio` **关**｜`HibernateMode=Auto`｜`HibernationSkipsPicker=True`｜`UEFI/ReservedMemory` 569344+4096 `RuntimeCode` | 有正式文档页；并记录一个**前置条件**：硬盘未被标记 `built-in` ⇒ macOS 不进休眠（"macOS enters S3 sleep instead of shutting down"） |
| `github.com/cattyhouse/oc-guide/wiki` | 笔记本通用 | 标题原文 **"休眠修复(不好用,建议直接关闭休眠)"**；测试法 = `standbydelaylow/high 0` + `autopoweroffdelay 0` | 中文圈**罕见**的老实话 |

---

## §2 「都确认了吗」—— 逐条证据分级

| # | 说法 | 等级 | 依据 | 独立复现 | 最高验证版本 |
|---|---|---|---|---|---|
| 1 | Dortania 官方：**不做休眠**，`HibernateMode=None`+关 standby/autopoweroff | 🟢 **判据** | 指南原文逐字 | 全社区默认 | 现行 |
| 2 | `HibernateMode = NVRAM` 是成功配方的**共同项** | 🟢 **判据** | 4 个独立来源全用它（Surface / T530 / Latitude 5300 / HD630） | ✅ 4 处 | — |
| 3 | `hbfx-ahbm ≥ 1` 是 mode 3 自动休眠的**必要条件** | 🟢 **判据** | T530 帖 + Latitude 5300 帖 + 上游 README 位定义 | ✅ 2 处 | Sonoma |
| 4 | **别装「Disable RTC wake scheduling」补丁** | 🟢 **判据** | T530 帖（"the fault was…"）+ Latitude 5300 帖（"Do not apply AppleRTC kernel patch"）**两独立来源** | ✅ 2 处 | Sonoma |
| 5 | `UEFI/ReservedMemory` 569344+4096 `RuntimeCode` 治唤醒黑屏 | 🟡→🟢 | chrultrabook 正式页 + Surface 帖 + T530 帖 | ✅ 3 处 | Sonoma |
| 6 | `DiscardHibernateMap=true` 治"第二次休眠后黑屏/KP" | 🟡 | T530 帖 + Surface 帖；上游文档只说它"reuse original hibernate memory map"，**用途是给 Windows 的** | ⚠️ 2 处但用途与文档不符 | Sonoma |
| 7 | `RebuildAppleMemoryMap=False` | 🟡 | 仅 T530 一处；上游文档把它定位为"boot 失败才需要" | ❌ 单点 | Sonoma |
| 8 | `DevirtualiseMmio` 必须关（否则休眠坏） | 🟡 | chrultrabook 正式页；**上游文档侧证**：*"a list of addresses that need virtual addresses for proper NVRAM and **hibernation functionality** may be required. Use the MmioWhitelist section"* | ⚠️ 与上游方向一致、非逐字要求 | — |
| 9 | Surface 组"解锁 `SS3`⇒S3 声明"是 AOAC 机型休眠的关键 | 🟡 | 单帖、作者自述、补丁前后内核日志对比 | ❌ 单点（但形态可复现） | Sonoma |
| 10 | `hibernatemode 25` 在笔记本上普遍可用 | 🔴 **不成立** | Dell Precision 5550 自述：同样配方 **Monterey 完美、Ventura 彻底失败**；Surface 组作者亦仅到 Sonoma | ❌ | — |

### ★ 三条硬边界（"确认"的边界在哪）

1. **没有任何一条是在 macOS 15 / 26 上复测的。** 最高 = Sonoma 14.5 / Ventura 13.6.7（2024 年）。**本机跑 26.6.2** —— 整整两个大版本之后，全部成功案例都属"过期未复测"。
2. **没有任何一条是在"EC 不响应 S3"的机器上成功的**（第 9 条是唯一候选，但它让 S3 只"被声明"，不要求"能用"）。
3. **没有任何一条给出"保存侧"的失败诊断** —— 全部假设"OS 会自己进 hibernate"。本机的失败恰恰在保存侧（`Entering Sleep` 5/5、`Entering Hibernate` 0/5）。

---

## §3 ⚠️ 不可采信的来源（中文搜索结果里占多数）

用户搜中文时最容易被这些淹没，**逐一点名，避免下次再被误导**：

| 站点 | 症状 | 处置 |
|---|---|---|
| `ufcn.cn/it/1313xxx`、`blog.csdn.net/gitblog_*`、`yoozai.com`、`heipg.cn/qa` | 同一篇"5 步彻底解决休眠"的模板化改写；**术语自相矛盾**：把 `hibernatemode 0` 说成"S3 睡眠"、把 `25` 说成"S0iX 浅睡眠"（真值：0=禁用休眠 / 3=混合 / 25=立即休眠）；凭空发明 "`hibernatemode=29`"；把 `HibernationFixup` 描述成"绕过主板错误的 ACPI_PRW 检查""唤醒失败时自动 fallback"（README 里**没有**这些功能） | 🚫 **不可当判据，不可引用** |
| 同上 | "必须安装 `OS-X-EAPD-Codec-Commander.kext`"（2015 年前的 Clover 时代残留，OpenCore 下已由 AppleALC 取代） | 🚫 同上 |

⇒ 判定口诀沿用既定纪律：**github（含 acidanthera 全部仓库）／远景／tonymacx86 = 判据；单篇博客／QuickSpecs = 方向；内容农场 = 不可用**。

---

## §4 本机 vs 三个成功组 —— 差异矩阵（含刚取到的一手实锤）

| 项 | **本机** | Surface 组（AOAC） | T530 / Latitude 5300（有 S3） | chrultrabook |
|---|---|---|---|---|
| 固件形态 | AOAC：`FADT FLAGS@0x70 bit21 = 1` ＋ `LPIT` 在 | AOAC/S0ix | S3 原生 | coreboot |
| **`SS3` 状态** | ✅ **`Name (SS3, One)`（DSDT:5708）** | ❌ 出厂 Zero ⇒ **需打补丁** | 无关 | 无关 |
| **内核睡眠状态** | ✅ **`ACPI: sleep states S0 S3 S4 S5`** | 补丁前 `S4 S5`，补丁后 `S3 S4 S5` | `S0 S3 S4 S5` | — |
| `HibernateMode` | ✅ **NVRAM**（已同） | NVRAM | NVRAM | Auto |
| `HibernateSkipsPicker` | ✅ **True**（已同） | True | 可选 True | True |
| `HibernationFixup.kext` | ⚠️ **配置里已移除**（文件仍在 `EFI/oc/Kexts/`） | ✅ 装 | ✅ 装 | ✅ 装 |
| `hbfx-ahbm` | ❌ 无（09-21 回滚时清掉） | — | **5** | — |
| **`Disable RTC wake scheduling` 补丁** | ❌ **已启用**（`Kernel/Patch` / `com.apple.driver.AppleRTC`） | 未提 | **明确要求关掉** | 未提 |
| `standbydelay` | 基线 10800·86400 | — | **7200 / 10800** | — |
| `UEFI/ReservedMemory` | ❌ **0 条** | ✅ 569344/4096 | ✅ 有 | ✅ 569344/4096 |
| `DiscardHibernateMap` | ❌ False | ✅ True | ✅ True | — |
| `RebuildAppleMemoryMap` | ❌ True | 未提 | **False** | — |
| `DevirtualiseMmio` | ❌ True | 未提 | 未提 | **必须关** |
| `MmioWhitelist` | ❌ **0 条** | — | — | — |
| `rtcfx_exclude` / `rtc-blacklist` | `0E-FF` / `0E–0xFF`（**都覆盖 0x80–0xAB**） | 未提 | `80-AB` 且仍能通 | — |

**本机 `SS3=One` 这条不能含糊** —— 它意味着：
> Surface 组**必须先打补丁才能达到**的状态，**我们出厂就有**；本机内核一直在报 `S0 S3 S4 S5`。
> ⇒ **"解锁 S3 声明"这个杠杆对本机等于已经拉满**，路线 1 的核心不构成我们的缺口。

---

## §5 ★ 三个修正（对既往结论的收紧）

### 修正 ①：「已试过的配置空间扩到最大」**只对 OS 侧成立**

| 层 | 到没到顶 | 依据 |
|---|---|---|
| **OS 侧**（`pmset`） | ✅ 基本到顶 | `mode 25` ×5（09-16）｜`mode 3 + standby 1 + standbydelay 0` 👉 硬失败（R3b）｜`mode 3 + standby 1 + standbydelay 86400·604800`（R3） |
| **引导器侧**（`config.plist`） | ❌ **从未测过 4 项** | `UEFI/ReservedMemory`（0 条）｜`DiscardHibernateMap`｜`RebuildAppleMemoryMap`｜`DevirtualiseMmio` + `MmioWhitelist`（0 条） |
| **kext 侧** | ⚠️ 只在 R3/R3b 出现过一次 | `HibernationFixup` 09-20 17:05 加入、**五组失败里只覆盖了后两组**；09-21 已从 config 移除（文件保留） |

⇒ 准确表述：**"OS 侧配置空间到顶；引导器侧这 4 项从来没进过实验台账"**。

### 修正 ② ★★ R3（mode 3 + `standbydelay≠0`）的"仍 Deep Idle"→ **很可能不是平台的错**

- 我们记录的 R3 形态：`mode 3 / standby 1 / standbydelay 86400·604800` ⇒ **实测仍 Deep Idle，没进入休眠**。
- 两个**独立**社区来源（T530 帖 + Latitude 5300 帖）都指名同一个凶手：**`Disable RTC wake scheduling` 内核补丁把 RTC 闹钟掐了 ⇒ dark wake 不发生 ⇒ 永远走不到休眠判定**。
- **本机这个补丁是开着的**（`Kernel/Patch`, `com.apple.driver.AppleRTC`, `Enabled=True`）。
- 且 R3 的参数**本身就测不出结果**：`standbydelay = 86400 s = 24 小时`（另一档 604800 = 7 天）—— 社区用的是 **7200~10800 s**。

⇒ 两个因素叠加 ⇒ **"mode 3 路线"在本机从未被公平测过**：
一次延迟设成 24 h（窗口内不可能触发），一次延迟设成 0（`R3b` 绕过了整个 standby 阶段、走的是另一条代码路径）。
⇒ **"社区成功配方的这 3 项（`HibernateMode=NVRAM` ✅ + `hbfx-ahbm≥1` + `standbydelay 7200~10800` + 不装 RTC 唤醒补丁）从未同时在本机成立过。**

### 修正 ③ 证据等级自曝

| 判断 | 等级 | 说明 |
|---|---|---|
| 「RTC 唤醒调度补丁 = R3 失败的真因」 | 🟡→🟢 | 2 个独立 github 级来源 + 机理自洽（我们自己的 `hbfx2.cpp:437` 读法也指向"判定发生在 dark wake"）+ **我们观测形态逐字吻合**；但**本机没做对照实验**（关补丁再测）⇒ 不能写成"已定" |
| 「引导器侧 4 项会不会解掉保存侧失败」 | 🔵 **未知** | 上游只对 `DevirtualiseMmio` 明说它影响 "hibernation functionality"；其余三项的文案都在**唤醒侧**。**禁止当结论用** |
| 「`rtc-blacklist 0E-FF` 覆盖 0x80–0xAB ⇒ 挡了休眠密钥写 RTC」 | 🔵 **未知（有两个反向证据）** | 上游 `RTCMemoryFixup` README 逐字：*"Offsets from **0x80 to 0xAB** are used to store some hibernation information (IOHibernateRTCVariables). If any offset in this range causes a conflict, you can exclude it, **but hibernation won't work**."* —— 但 T530（`rtcfx_exclude=80-AB`）用 `HibernateMode=NVRAM` 照样通 ⇒ **这条警告只作用于 RTC 路径**，我们走的正是 NVRAM 路径 |

---

## §6 若要继续：唯一一个"有社区先例、且本机从未测过"的最小实验

> ⚠️ **先看风险定价再谈值不值。** 本机代价模型：**"武装休眠 ⇒ 写坏 CMOS + 开机 POST 005" = 4/4，既定而非概率**（09-16 三次 + R3b 一次）。
> ⚠️ **必须人守着、测完手动回滚**（R3b 的教训：自建 LaunchDaemon 看门狗被外部删除，配置裸奔一夜并多烧一次 CMOS）。
> ⚠️ 本机不允许 `pmset schedule wake`（RTC 写 → 005）；`standbydelay≠0` 会让 macOS 自己写 RTC 闹钟，**同属该风险面**。

**若拍板要做，建议只做一个变量、只跑一次：**

| 变量 | 现值 | 拟改 | 依据 |
|---|---|---|---|
| `Kernel/Patch` 的 `Disable RTC wake scheduling` | **Enabled** | **Enabled=False** | 2 个独立来源指名（§2 第 4 条） |
| `hbfx-ahbm` | 无 | **= 1** | 上游 README 位定义 + 2 处社区（§2 第 3 条） |
| `standbydelaylow/high` | 10800 / 86400 | **7200 / 7200** | Latitude 5300 实测用 7200（§1 路线 3） |
| `hibernatemode` / `standby` | 0 / 0 | **3 / 1** | 走"先睡后休"路线（比 mode 25 温和；mode 25 是已证硬断电档） |
| `HibernationFixup.kext` | 已移除 | **加回**（文件仍在） | 4 个成功组全装 |

**预注册的判据（不达标即判不通，不许"差不多"）**：
1. `sleepimage` 前 16 字节**非全 0** 且 mtime = 本次睡眠时刻
2. 内核日志出现 **`Entering Hibernate`**
3. `kern.hibernatecount` **≠ 0** 或 NVRAM 出现 `IOHibernate*`
4. 唤醒后 `last reboot` / `utmpx` **不出现 2019**

**回滚点**：`pmset -a hibernatemode 0 standby 0`；`config.plist` 用 `docs/backups/` 快照还原。
**不做也不亏**：本次调研没有找到任何"能绕开 EC/S0ix 卡点"的配方；现有可用档位（Deep Idle，~2.4 s 唤醒、~5 W）不受影响。

---

## §7 来源清单（按可信度分级）

**🟢 判据级（github 上游仓库 / 官方文档）**
- `docs.chrultrabook.com/docs/installing/macos-hibernation` — 唯一的"正式文档级"休眠教程
- `github.com/acidanthera/HibernationFixup` README（逐字已核）
- `github.com/acidanthera/RTCMemoryFixup` README（0x80–0xAB 警告，逐字已核）
- `github.com/balopez83/Surface-Pro-7-Hackintosh/issues/7` — **唯一的 AOAC 机型成功组**
- `github.com/5T33Z0/Lenovo-T530-Hackintosh-OpenCore/issues/48`
- `github.com/AppleBreak1/Dell-Latitude-5300-2-in-1-Hackintosh` — **唯一带时间戳实测日志**
- `dortania.github.io/OpenCore-Post-Install/universal/sleep.html`（逐字已核）
- `dortania.github.io/docs/latest/Configuration.html` + `dreamwhite.dev/OpenCorePkg-Documentation/docs/Booter/quirks.html`（`DevirtualiseMmio` / `DiscardHibernateMap` / `RebuildAppleMemoryMap` 逐字已核）

**🟡 方向级（单篇博客 / 个人教程）**
- `insanelymac.com/forum/topic/355419`（HD630 台式机）
- `github.com/jlempen/*-OpenCore`（Yoga Duet 7 / Surface Laptop 3）
- `heipg.cn/tutorial/enable-sleep-mode-for-hackintosh.html`、`blog.daliansky.net/From-Clover-To-OpenCore.html`、`github.com/cattyhouse/oc-guide/wiki`
- `eclecticlight.co`（`pmset` 字段释义）

**🚫 不可用（AI 内容农场，见 §3）**
- `ufcn.cn`、`blog.csdn.net/gitblog_*`、`yoozai.com`、`heipg.cn/qa/*`

---

## §8 与本机既有文档的关系

| 文档 | 本文补充了什么 |
|---|---|
| `s4-requirements-audit.md` §7.1–§7.11 | 首次给出**社区侧**的成功案例与配方；§7.9(d) 关于"关 ①（平台交接）"的表述不受影响 |
| `next-test-agenda.md` | 议程 ① 的关闭依据仍是"OS 侧到顶"；本文 §5 修正 ① 说明**引导器侧 4 项从未入账** |
| `r3b-result.md` §5.1（EFI 残留） | 那条回滚**同时清掉了 `HibernationFixup` 与 `hbfx-ahbm`** —— 本文 §4 显示这两项恰好是全部成功配方的共同项；文件保留在 `EFI/oc/Kexts/`，可随时加回 |
| `tier-ladder-why.md`（L1/L2/L3 三层） | 不冲突：本文的四条路线全部落在 **L2（OS 选择）** 与 **L1（固件声明）**，**没有任何一条解决 L3（EC 执行）** —— 而本机卡在 L3 |
