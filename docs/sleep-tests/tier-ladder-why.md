# 为什么只有 Deep Idle —— 睡眠档位阶梯与「下一档」的卡点

> **时间**：2026-09-18 16:2x｜**触发**：用户问「为什么只能 deep idle？不能更进一档？」
> **性质**：★ **只读**。零配置改动、零新实测。证据 = FACP/DSDT **二进制直读** + 历史实测记录 + 上游原文。
> **上游**：`README.md` §二十八/§三十四/§三十五/§三十七｜`round2-tierB-result.md` §34/§35｜`s4-requirements-audit.md`

---

## 0. 一句话

> **卡点不在 OpenCore 变量层，在 EC（嵌入式控制器）固件。**
> 声明层（固件说自己有 S3）✅、选择层（macOS 真会去选 S3）✅、**执行层（硬件真按 S3 断电后恢复）❌** ——
> 这是 AOAC 世代机型与 legacy S3 的**结构性相斥**，不是"哪个布尔值配错了"。

---

## 1. 档位阶梯（本机实测定位）

| 档 | 名称 | 语义 | 本机状态 | 卡点 |
|---|---|---|---|---|
| S0 | 工作 | 全速 | ✅ | — |
| **S0ix** | **Deep Idle**（现役） | 现代待机：SoC 进低功耗，部分域保活 | ✅ **唯一可用**｜唤醒 2.4 s｜实测 ~4 W / 6 %/h | — |
| S3 | 传统睡眠 | Suspend to RAM | ❌ **实测不可用**（2 轮） | **L3 执行层**：EC 恢复后不再回话 |
| S4 | 真休眠 | Suspend to Disk（断电） | ❌ **实测不可用**（5 次武装休眠） | **#28 RTC 断电期保持**（固件职责）+ 恢复侧失败 |
| S5 | 关机 | 断电冷启动 | 可用（就是关机） | — |

⚠️ **"更浅"不是问题**：`displaysleep 15`（电池 15 min 关屏）本来就在用；`sleep 15` 也在。
**问题只在"更深"这一侧。**

---

## 2. ★ 三层判据：前两层都通，断在第三层

判"能不能到下一档"，必须分三层问。**只用前两层会得出错误结论**（本机历史上就吃过这个亏）。

### L1 · 声明层 —— 固件说它有 → ✅

| 证据 | 值 | 含义 |
|---|---|---|
| `docs/SysReport/ACPI/FACP-1.aml` **`FLAGS@0x70`** | `0x002384A5` | **`LOW_POWER_S0_IDLE_CAPABLE`(bit21)=1** ⇒ 平台**自报 AOAC**；`HW_REDUCED_ACPI`(bit20)=0 ⇒ 是**完整 ACPI + AOAC 并存**（正因如此 `_S3`/`_S4` 还留在菜单上）；RTC 唤醒能力位=1 |
| `FACP-1.aml` `RTC_S4` 能力位 | 1 | RTC 可从 S4 唤醒（S4 的必要条件 #1 ✅） |
| `DSDT.dsl:38257-38266` | `If (SS3) Name (_S3, Package(0x04){0x05,…})` | S3 对象在 |
| `DSDT.dsl:38268-38277` | `If (SS4) Name (_S4, Package(0x04){0x06,…})` | S4 对象在 |
| `DSDT.dsl:5708-5709` | `Name (SS3, One)` / `Name (SS4, One)` | 门控常量**都为真** ⇒ 上两个对象**实际存在** |
| `DSDT.dsl:31312-31313` | `Local0 \|= (SS3 << 0x03)` / `(SS4 << 0x04)` | 固件**主动把"S3/S4 支持"上报给 OS** |

> 📌 **所以"固件没实现 S3"是错的**。菜单上印了这道菜。

### L2 · 选择层 —— macOS 真会去选 → ✅

| 证据 | 说明 |
|---|---|
| 判据**不用睡觉就能读出**：关掉 `SSDT-DeepIdle.aml` → `IOPMDeepIdleSupported` 从 `Yes` **翻 `No`** ⇒ 系统转去走 S3 | 已在 §二十八 实测过 |
| `SSDT-DeepIdle.dsl` 全文只有 94 B：`_SB.LPS0` + `_GPE.LXEN`，**都 `_OSI("Darwin")` 门控**、返回 `One` | 它**就是**那个"让 macOS 知道有 S0ix"的开关 |
| `LPS0`/`LXEN` 在**原厂 DSDT 里根本不存在**（`grep -E "LPS0\|LXEN" DSDT.dsl` = 0 命中） | ⇒ 这两条是**我们补的**；补上→Deep Idle，撤掉→S3 |
| 现役读数（2026-09-18 16:2x 实读） | `IOPMDeepIdleSupported = Yes`、`IOSleepSupported = Yes` |

> 📌 **所以"是不是你配置没配上"也不是答案** —— 配置**能**把它切到 S3，切过去就是坏。

### L3 · 执行层 —— 硬件真按 S3 断电、且能恢复 → ❌

**这一层才是墙。** 详见 §3。

---

## 3. S3 的失败形态：判据是"计数差"，不是感觉

| 观测 | Deep Idle | **S3 实测** | 倍数 |
|---|---|---|---|
| `(AppleACPIEC) EC OBF=1 poll timed out` | **0**（09-16 20:00 / 09-17 08:52 / 回滚后 11:46 各 0） | **34**（10:48）/ **120**（11:33） | S3 独有 |
| `WakeTime` | 2.430 / 2.548 / 2.617 / 2.4 s | **159.336 s** | **65×** |
| PS2 控制器恢复耗时 | 457–466 ms | **157,735 ms** | **342×** |
| 内核 panic | 0 | **1**（`NMIPI / TLB flush timeout`，栈过 `IOUSBHostFamily`/`AppleUSBXHCI`/`IntelBluetoothFirmware`） | 本机历史唯一 |
| 用户侧症状 | 正常 | **"只能强制关机"** | — |

**分界干净**：噪声基线（09-15 普通运行）= **1** 次，Deep Idle 唤醒 = **0** 次，S3 = 34/120 次。
**机制**：`EC OBF`（Output Buffer Full）恒为 1 ⇒ `AppleACPIEC` 轮询 I/O `0x66` 永远等不到清位 ⇒ **EC 从不回话** ⇒ PS2/SMBus 死等 ⇒ USB 栈超时 panic。
**排除项**：RTC 三件套被机制排除（其作用域 = RTC RAM I/O `0x70/0x71`；坏的是 EC 的 `0x62/0x66` —— **两条路径硬件上不相交**，拦 RTC 写不可能让 EC 停止回话）。

---

## 4. 为什么 EC 会不响应：AOAC 与 S3 结构性相斥（上游原文）

OC-Little 父页《01-关于AOAC》（★ 我为漏读它付出过一次 panic 的代价）：

> *"由于 **AOAC 和 S3 本身相矛盾**，采用了 AOAC 技术的机器不具有 S3 睡眠功能……一旦进入 S3 睡眠就会**睡眠失败**……主要表现为：**睡眠后无法被唤醒，呈现死机状态，只能强制关机**"*
> *"**禁止 S3 睡眠** 可以解决睡眠失败问题"*
> *"电池……大约每小时耗电 **5%–10%**"*

⇒ 用户症状**逐字命中**（"只能强制关机"）；本机实测 5 W ≈ 7 %/h **落在社区区间**；而我做的回滚 = **社区标准解**。

**本机独立旁证**：EC 固件里 `SLP_S3/4/5` 与 `PCH_SLP_S0IX#` **两套并存** ⇒ 正合"AOAC 把物理 S 信号重定向"的格局。

**同平台三条路全不可用**（Ice Lake 汇总仓库 `icelake-hackintosh` Sleep issues 表）：

| 路 | 上游定性 | 本机 |
|---|---|---|
| ① daliansky/SSDT 补丁 | *"不稳定：电池寿命低，有些机器即使用这些补丁也唤不醒"* | = **本机原状态** |
| ② BIOS 关 AOAC | *"最难但最稳定"* | **HP BIOS 菜单无此项**（HP 官方《Power Management Options》全表无 `Modern Standby`/`S0ix`/`Sleep State`） |
| ③ SSDT+rename 开 S3 | *"**for some of Dells**"* | **本机是 HP，不在范围** |

> 📌 **EC 是固件的一部分，它的 S3 路径 HP 从没验证过 —— 改 OpenCore 变量改不动固件。**

---

## 5. 再深一档（S4）：比 S3 更远，缺口更硬

| 维度 | 结论 | 依据 |
|---|---|---|
| 断电动作（27a） | ✅ **确实发生** | 5 次武装休眠全部"睡下即断气"、`Wake from` 全无 |
| 冷启动恢复（27b） | ❌ **失败** | 5 次全失败，其中 **3 次触发 HP POST 005** |
| 唯一真·结构性缺口 | **`#28` RTC/CMOS 在 S4 断电期保持有效** | 30 条准入条件里**只有这 1 条改配置改不出来**（其余 9 条 = 4 开关 / 2 未判 / 1 我判错 / 1 未测 / 1 失败点落恢复侧） |
| 先例 | **AOAC 家族 0 先例** | 全球跑通 S4 的仅 4 台（T530 / Fujitsu Q958 / X250 / Yoga Duet 7 13IML05）—— **全为 Legacy S3 世代** |
| 上游态度 | Dortania 原文 *"avoid the black magic that is S4"* | — |
| 唯一开口 | HP 支持文档 `ish_2843606-2359609-16`：*"退出休眠状态后…系统时钟显示的时间不正确…**更新 BIOS 应该可能会解决该问题**"* | ⚠️ 但本机真实 BIOS = `T75 01.24.02`（比 HP 该机型基线 `01.22.00` **还新**）⇒ "固件老旧缺陷"假设基本不成立；且刷固件**不可回退** ⇒ **不建议赌** |

---

## 6. 「有没有半档可走？」—— 三个候选，逐条排除

| 候选 | 它是什么 | 为什么**不算**"更深一档" |
|---|---|---|
| `hibernatemode 3`（SAFE sleep） | 写镜像 + **RAM 保持供电** | 它的**电气形态与 S3 同级**（RAM 保持 = 挂起）。它是 **S4 链条的第一道门**（"镜像能不能写出来"），不是"比 Deep Idle 深一点的睡眠"。本机开了也仍走 Deep Idle，唯一差别 = 每次睡**多写 8–16 GB** |
| `standby 1` + `standbydelay*` | "睡够 N 分钟后转休眠"的**计时器** | 转的终点是 **S4**，不是中间态 ⇒ **`standby 0` 不是"省电没开"，是不让它去撞那道墙** |
| 更深 C-state / package C-state | S0 **内部**的 CPU 省电档 | 属"醒着但闲着"，**不是系统睡眠档**；且本机黑苹果 PMU 读 `C-state 0.00 %` 不可靠 ⇒ 连测都测不准 |

### 🔎 本轮新读数（含义待确认，**不作判据**）

`ioreg -r -c IOPMrootDomain` 里同时存在两组值：

| 字段 | 值 |
|---|---|
| 实际生效：`"Hibernate Mode"` / `"Standby Enabled"` | **0** / **No** |
| `SystemPowerProfileOverrideDict` 内（Battery/UPS/AC 三份）：`"Hibernate Mode"` / `"Standby Enabled"` / `"Standby Delay"` | **3** / **1** / **10800**（= 3 h） |

前者=我们主动压掉的现役值；后者看起来是 **macOS 为该 SMBIOS 机型准备的模板默认**（"睡够 3 h 就转 standby"）。
⇒ 解读为"**苹果本来打算让这台机往更深的档位走**"，作为"再深一档的开关本来是开着的"之旁证；**字段确切语义未查证，标为待确认**。

---

## 7. 结论

| 问题 | 答复 |
|---|---|
| 为什么只能 Deep Idle？ | 因为**下一档 S3 在这台机器的固件上真的坏**：S3 恢复后 EC 完全不回话（`EC OBF=1` 连绵），连锁 65× 唤醒延迟 + 342× PS2 延迟 + 本机唯一一次 panic |
| 是配置没配上吗？ | **不是。** L1 声明层 ✅（FADT bit21 AOAC=1 + `_S3`/`_S4` 对象 + `SS3/SS4=One`）、L2 选择层 ✅（撤掉 94 B 的 `SSDT-DeepIdle` 就会转 S3）—— **两层都通，败在 L3 执行层** |
| 再深一档（S4）呢？ | 更远。唯一结构性缺口 `#28` 落在固件手里；5 次武装休眠全在恢复侧失败、3 次 POST 005；AOAC 家族 0 先例 |
| 有半档吗？ | 没有。`mode 3` 电气上仍是挂起（只是多写镜像）、`standby` 的终点就是 S4、C-state 属另一维度 |
| 那还剩什么？ | **量准现役档位**（`tools/sleep-power-measure.sh`）。配置层确实无牌可打 —— 本轮结论与 round4 自洽 |

---

## 附录 A · 「能不能关掉 AOAC？」（2026-09-18 16:4x 追查）

> 触发：用户问「不能关闭AOAC？」｜**性质**：本轮**只读**（零配置/零 EFI 改动），新增证据 = Window 分区 hive 直读 + 上游口径查证。

### A.1 三层开关 —— 只有一层是"我们能碰的"

| 层 | 开关 | 现状 | 结果 |
|---|---|---|---|
| **① OS 声明层**（各 OS 自己） | macOS：`\_SB.LPS0`（撤掉即转 S3）｜Windows：注册表 `PlatformAoAcOverride=0` | ✅ **能关，而且已经关过** —— `SSDT-DeepIdle=false` 实测：`IOPMDeepIdleSupported` Yes→No、系统**确实转去走 S3** | ❌ **关完 EC 罢工**（`EC OBF=1` 34/120 次、`WakeTime` 159 s、本机唯一 panic）⇒ **这一层关了也白关** |
| **② 固件菜单层** | BIOS 里的 `Modern Standby` / `S0ix` / `Sleep State` / `Low Power S0 Idle` | ❌ **HP 没有这一项** | — |
| **③ 固件隐藏变量层** | UEFI Shell 写隐藏 setup 变量（Dell 5410 先例：`setup_var_cv Setup 0x14 0x1 0x0`） | ⚠️ **从未尝试；对 HP 完全未验证**（是否存在该项 / 偏移 / GUID 均未知） | 🔴 高：写错可致不开机；**HP 侧零上游先例** |

**② 的依据（HP 官方文档原文级）**：HP《Power Management Options》菜单**全表逐项** = `Runtime Power Management` ｜ `Extended Idle Power States` ｜ `S5 Maximum Power Savings` ｜ `SATA Power Management` ｜ `Deep Sleep` ｜ `PCI Express Power Management` ｜ `PCIe Speed Power Policy` ⇒ **通篇没有任何 `Modern Standby` / `S0ix` / `Sleep State` / `Low Power S0 Idle` 条目**。

> ⚠️ **别被 `Extended Idle Power States` 骗到**：HP 官方定义为 *"Allows certain operating systems to decrease the processor's power consumption **when the processor is idle**"* ⇒ 是 **C-state 空闲省电**（Runtime Power Management 那一类），**不是 S0ix / S3 的选择器**。
> 同族 ZBook 用户实测原话（tenforums 2021）：*"**[x] Extended Idle Power States setting was indeed a dud.** It was supposed to control S3, but all settings in BIOS did absolutely nothing to this issue. … Spent dozens of hours experimenting."*

### A.2 ★ 本轮新增一手证据：Windows 分区直读（零风险）

`/Volumes/TZBOOK/Windows/System32/config/system`（⚠️ **文件名是小写**，`SYSTEM` 大写会 `No such file or directory` —— 这正是 §三十X 那次"读注册表失败"的真因）mtime = **2026-09-18 14:05** ⇒ 是你最近一次进 Windows 的写入。

| 检索项 | 结果 | 意义 |
|---|---|---|
| **正向对照**：`HiberbootEnabled` / `PowerSettings` | ✅ 均命中 | 检索方法有效（不是编码或工具问题） |
| **`PlatformAoAcOverride`** | **字节级 0 命中** | 本机 Windows **从未设置过**该 override ⇒ §二十八 引用的 drwindows 反例**与本机无关**，我们处在"从零开始"的位置 |
| `ConnectedStandbyPlatform` / `StandbyActivationEnergy` / `*ModernStandbyWoLMagicPacket` / `BthLEInputSuppressionModernStandbyOptIn` | ✅ 命中 | 这台 Windows **确实运行在 Modern Standby 策略下** |

⇒ 与另两条**互相独立**的证据三重印证：**FADT bit21 `LOW_POWER_S0_IDLE_CAPABLE`=1** ｜ **`System32/SleepStudy/` 存在且今天 14:05 仍在写**（`SleepStudy` 是 Modern Standby 的**专属**诊断设施，S3 平台不会生成） ｜ **hive 里的 Modern Standby 策略串**。

### A.3 ★ 上游口径（微软侧）：AOAC 与 S3 **不可共存**，且必须**厂商**给开关

| 来源 | 原文 | 分级 |
|---|---|---|
| **MS 官方文档（System Power States）口径**，经 Microsoft 员工在问答区引用 | *"**Systems that support Modern Standby do not use S1-S3.**"* | **可当判据**（MS 文档口径） |
| **MS 问答区同一案例**（标题原文《WIN11 修改注册表为S3睡眠模式后无法唤醒》） | 用户执行 `reg add … PlatformAoAcOverride /t REG_DWORD /d 0` 关闭现代待机 ⇒ **"点击睡眠后无法唤醒"**；答复原文：*"**待机 (S0 低电量待机)是硬件级的功能，它和 S3 不可共存**，除非您的计算机厂商提供开关开启 S3 电源模式才能启用（同时 S0 会被关闭）"* | **方向强**（含 MSFT 员工回复、引官方文档） |
| 网上"改注册表就能切 S3"的一批博客（positioniseverything / techbloat / geekchamp / wintips 等） | 口径一致，但它们**自己都写着**"若固件不暴露 S3 则无效" | ⚠️ **仅方向，不可当判据** |

> **★★ 同形先例（本轮最有价值的一条）**：Windows 侧"强行让 OS 走 S3"的结果 = **睡下去醒不来**；我们在 macOS 侧做的（撤 `LPS0`）结果 = **只能强制关机 / `WakeTime` 159 s / EC 罢工**。**两条完全独立的路径，同一个结果** ⇒ 指向同一个原因：**固件层没有 S3 的物理路径**。

### A.4 ★ 为什么我不建议赌那一刀：**赌注不对称**

| | 内容 |
|---|---|
| **代价** | 关掉 AOAC ⇒ **放弃 Deep Idle** —— 本机**唯一可用**的睡眠档（实测 2.4 s 唤醒 / ~4 W） |
| **目标** | S3 —— 本机**已实测是坏的** |
| **赌输** | **两头空**：既没有 S3，也丢了 Deep Idle |
| **上游态度** | OC-Little 父页把「**禁止 S3 睡眠**」列为 AOAC 平台的**标准解** ⇒ 我们现在的状态**就是**那个标准解 |

### A.5 建议：先做零风险探底（都在 Windows，共约 5 分钟）

| 步 | 动作 | 风险 | 能定什么 |
|---|---|---|---|
| **①** | 管理员 CMD：`powercfg /a` | ✅ **纯只读** | **固件到底有没有把 S3 交给 OS**：出现 `Standby (S3)` ⇒ 有；只报 `Standby (S0 Low Power Idle)` 且注明 S3 不可用 ⇒ **没有 ⇒ 这一刀可彻底封板** |
| **②** | **仅当 ① 显示有 S3**：`reg add …PlatformAoAcOverride /t REG_DWORD /d 0` → 重启 → 睡一次 | ⚠️ 中（醒不回来就强制关机，与既有 S3 实测同形） | **隔离「固件不支持」vs「只有 macOS 不支持」** —— 用厂商自己的 OS + 驱动 + 固件路径测 S3，是最终裁决 |
| **③** | 无论结果都 `reg delete …PlatformAoAcOverride /f` 还原 | — | 别把 Windows 也搞成"睡下去醒不来" |
| **④** | 只有 ① 有 S3 **且** ② 能正常唤醒 ⇒ 才值得评估 ⑤ | — | — |
| **⑤** | UEFI Shell 写隐藏 setup 变量（`setup_var_cv` 思路） | 🔴 **高** | 唯一能改到**固件层**的软件路径；**HP 无先例** |

> **判据**：② 若 Windows 也醒不回来 ⇒ **固件层没有 S3 物理路径**，与 macOS 侧结论**互相封闭** ⇒ AOAC 这条线可**彻底封板**（不是"没试过"，而是**两套 OS 都测过**）。
