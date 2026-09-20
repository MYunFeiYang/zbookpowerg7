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

> **★★ 同形先例**：Windows 侧"强行让 OS 走 S3"的结果 = **睡下去醒不来**；我们在 macOS 侧做的（撤 `LPS0`）结果 = **只能强制关机 / `WakeTime` 159 s / EC 罢工**。
>
> ⚠️ **2026-09-18 17:0x 修正（A.6 推翻了这里的一句推论）**：初版写的是"**两条完全独立的路径**，同一个结果 ⇒ 指向固件层没有 S3 的物理路径"。**这个推论是错的**——这两条**不是独立的**，它们是**同一层（OS 声明层）**的两次实验，本来就该得到同一个结果。真正独立的实验必须在**固件层**做。而且 `powercfg /a` 的实测（A.6）**证明固件层是有 `_S3` 声明的**⇒ **"固件没有 S3"这个假设不成立。**

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
| **①** | 管理员 CMD：`powercfg /a` | ✅ 纯只读 | **✅ 已于 2026-09-18 17:0x 执行 —— 结果见 A.6**。落点是**三态里的中间态**（"固件声明了 S3、但被 AOAC 策略压住"），**不是**初版判据里的二分（"有 S3 可用" / "固件根本没有"）⇒ ① 的原判据不完整，已按三态重写 |
| **②** | **仅当 ① 显示有 S3**：`reg add …PlatformAoAcOverride /t REG_DWORD /d 0` → 重启 → 睡一次 | ⚠️ 中（醒不回来就强制关机，与既有 S3 实测同形） | **隔离「固件不支持」vs「只有 macOS 不支持」** —— 用厂商自己的 OS + 驱动 + 固件路径测 S3，是最终裁决 |
| **③** | 无论结果都 `reg delete …PlatformAoAcOverride /f` 还原 | — | 别把 Windows 也搞成"睡下去醒不来" |
| **④** | 只有 ① 有 S3 **且** ② 能正常唤醒 ⇒ 才值得评估 ⑤ | — | — |
| **⑤** | UEFI Shell 写隐藏 setup 变量（`setup_var_cv` 思路） | 🔴 **高** | 唯一能改到**固件层**的软件路径；**HP 无先例** |

> ⚠️ **2026-09-18 17:0x 更正**：上面这句"② 若醒不回来 ⇒ 固件层没有 S3 物理路径"**不成立**（A.3 已修正、A.6 已证伪）。② 与 macOS 撤 `LPS0` 属**同一层**，无论醒来/醒不来都**推不出**固件层结论。**封板的真判据已换成 ③a（HP 官方只读查询，见 A.6）：厂商自己的工具里到底有没有这个开关项。**

---

### A.6 ★★ 2026-09-18 17:0x 实测判定（用户带图回报）—— 落点是「三态」的中间态

> 用户提供两份一手材料：**① BIOS `Power Management Options` 菜单实拍**；**② Windows 管理员 CMD 的 `powercfg /a` 原始输出**。

#### (1) BIOS 实拍 —— ② 菜单层无解，从"官网表"升级为"实拍"

实拍可见 4 项：`[✓] Runtime Power Management`｜`[✓] Extended Idle Power States`｜`[✓] Power Control`｜`Battery Health Manager`（下拉）。**通篇仍无 `Modern Standby` / `S0ix` / `Sleep State` / `Low Power S0 Idle`** ⇒ A.1 的 ② 判定**由实拍直接坐实**（不再只是"依据 HP 官网文档表"）。

#### (2) ★ `powercfg /a` —— 关键在于这份输出的**内部对照**

```
此系统上有以下睡眠状态:
    待机 (S0 低电量待机) 连接的网络
    休眠
    快速启动

此系统上没有以下睡眠状态:
    待机 (S1)
        系统固件不支持此待机状态。              ← ①原因
        当支持 S0 低电量待机时，禁用此待机状态。    ← ②原因
    待机 (S2)
        系统固件不支持此待机状态。              ← ①原因
        当支持 S0 低电量待机时，禁用此待机状态。    ← ②原因
    待机 (S3)
        当支持 S0 低电量待机时，禁用此待机状态。    ← 只有 ②原因 ！
    混合睡眠
        待机 (S3) 不可用。
        虚拟机监控程序不支持此待机状态。
```

**同一份输出里，S1/S2 都带「系统固件不支持此待机状态」，唯独 S3 没有。** 这排除了"工具漏打/版本差异"的可能。两句话的语义（三来源口径一致）：

| 措辞 | 语义 |
|---|---|
| `系统固件不支持此待机状态` | **BIOS/UEFI 没有把该睡眠模式提供给 OS**（ACPI 命名空间里无该 `_Sx`） |
| `当支持 S0 低电量待机时，禁用此待机状态` | **被 Modern Standby 策略阻塞** —— 平台偏好 S0ix，Windows 把 S3 压住 |

> 来源：MS 文档措辞经 techbloat / geekchamp / positioniseverything **三站口径一致**；techbloat 原文 *"the second **may mean S3 could become available only if Modern Standby is disabled** through supported firmware or Windows configuration"*。（分级：三家均为博客 ⇒ **仅方向**；但与本机**同一份输出的内部对照**互证，结论仍成立。）

⇒ **结论：S3 不是"固件没有"，而是"固件声明了、被 AOAC 策略压住"。**

**第四重互印**（前三条见正文 §三层判据）：

| # | 证据 | 看到的 |
|---|---|---|
| 1 | `FACP FLAGS@0x70 = 0x002384A5` | bit21 AOAC=1 + bit20 `HW_REDUCED_ACPI`=0 ⇒ **完整 ACPI 与 AOAC 并存** |
| 2 | `DSDT.dsl`：`If (SS3) Name (_S3,…)`、`SS3=One` | `_S3` 对象**存在且已启用** |
| 3 | macOS 撤 `LPS0`（实测） | `IOPMDeepIdleSupported` Yes→No ⇒ macOS **确实看到 `_S3` 并转了过去** |
| 4 | **Windows `powercfg /a`（本轮）** | S3 栏**无"固件不支持"字样** ⇒ 固件把 S3 交给了 OS |

> 附注（旁证，与本议题无关）：`混合睡眠` 那栏写着"**虚拟机监控程序不支持此待机状态**" ⇒ 这台 Windows 开着 **VBS/Hyper-V 虚拟化**（与 `休眠`/`快速启动` 同时可用一致，`hiberfil.sys` 在）。

#### (3) ③ 的画像因此要改 —— 但仍**不是**"该赌"

| | 旧画像（A.4） | 修正后 |
|---|---|---|
| ③ 的理论依据 | 隐含"固件可能根本没 S3" ⇒ **无源之水** | **S3 的固件声明确实存在**（第四重证据）综上 ⇒ 依据成立；Dell 5410 的成功案例与本机在 `powercfg` 层面**形态完全相同**（同为 AOAC 平台、S3 同被策略压住） |
| 风险 | 🔴 高（UEFI Shell 裸写隐藏变量） | **分化**：**只读探测 = ✅ 零风险**（见 (4)）；**写入**仍 🔴 高 |
| 赌注不对称 | 成立 | **仍成立（未变）** |

> ⚠️ **一条必须说清的负向修正**：`powercfg /a` 这个观测**不能区分**"救得回来的 AOAC 平台（Dell 那种）"与"救不回来的（本机）"—— **Dell 在改之前，`powercfg /a` 大概率也是这个输出。** ⇒ 它只把 ③ 从"无源之水"提到"有理论依据"，**没有给出任何"值得赌"的证据**。

#### (4) ★★ 本轮最大产出：HP 的**零风险只读**官方入口（新路径 ③a）

**HP 商用机（含 Z 系列 Workstation）把 BIOS 设置"全部"通过 `root/HP/InstrumentedBIOS` WMI 暴露给 Windows** —— HP 官方支持的接口，**不需要 UEFI Shell、不需要 USB 启动、不支持概率性写裸变量**。

| 事实 | 依据（原文） | 分级 |
|---|---|---|
| 暴露的是 **"全部"** 设置（不限于 BIOS 菜单里显示的） | *"`HP_BIOSSetting` … is used to return a list of **all BIOS settings** on a device"*（对照：`HP_BIOSEnumeration` 只返回 *"commonly configurable"* 的） | 与 HP Wolf **官方文档** *"**The BIOS exposes all its configuration or settings through the acpi-wmi driver in Windows**"* 一致 ⇒ **可当判据** |
| 有字段直接标"是否显示在 BIOS UI" | `HP_BIOSSetting` 输出含 `DisplayInUI`（1=显示，0=隐藏）、`IsReadOnly`、`RequiresPhysicalPresence` | 字段语义自解释 |
| 适用机型含 **Z Workstation** | 前置条件原文 *"An HP Business-class computer (EliteDesk, ProDesk, ProBook, EliteBook, **Z-Workstation**)"* | **本机 = ZBook Power G7 ⇒ 在支持范围内** |
| 官方工具同样支持全量导出 | *"`BiosConfigUtility64.exe /get:my-settings.txt`"*；`/dumpall` 可取各设置上下界 | **HP Wolf 官方文档（可当判据）** |

⇒ **"③ 固件隐藏层到底有没有 AOAC 开关"这个问题，现在能用一条纯只读命令回答，不必赌。**

**A 步（✅ 零风险 · 纯读）** —— Windows **管理员 PowerShell**：

```powershell
# 1) 全量导出（含隐藏项），落盘到 Windows 盘根目录，macOS 侧可直接读
Get-WmiObject -Namespace root/HP/InstrumentedBIOS -Class HP_BIOSSetting |
  Select-Object Name, Value, DisplayInUI, IsReadOnly, RequiresPhysicalPresence |
  Sort-Object Name | Export-Csv C:\HPBIOS-all.csv -NoTypeInformation

# 2) 直接筛相关项
Get-WmiObject -Namespace root/HP/InstrumentedBIOS -Class HP_BIOSSetting |
  Where-Object { $_.Name -match 'sleep|standby|s3|s0|idle|aoac|power' } |
  Select-Object Name, Value, DisplayInUI | Format-Table -AutoSize
```

> WMI 类若不存在（HP 驱动未装/被禁用），退回官方工具：`BiosConfigUtility64.exe /get:C:\BIOSConfig.txt`（HP BCU，见 A.6 依据行）。

**判据**（结果落在 `C:\HPBIOS-all.csv`；`/Volumes/TZBOOK` 在 macOS 下可直读 ⇒ **文件放那即可，我来看**）：

| 看到什么 | 判定 |
|---|---|
| 有 `Sleep State` / `Modern Standby` / `Low Power S0 Idle` 一类项（尤其 `DisplayInUI=0` 的隐藏项） | ⇒ **③a 打通**：再用同一接口按**设置名**写入（单元语义化、可回滚、**没有"偏移写错"这种风险**），比裸写变量安全一个数量级 |
| 全表搜不到任何 sleep/standby 相关项 | ⇒ **固件确实不暴露该开关 ⇒ ③ 彻底封板**（证据级别从"没试过"升到"**厂商自己的工具里也没有**"） |

> **为什么这条要排在 A.5 的 ② 之前**：② 必须真的睡一次（可能醒不回来、要强关），而 ③a 是**纯查询**。⇒ **② 降级为"仅当 ③a 发现该项时才做"**。

---

## 附录 B · 「不能直接读固件？」—— 离线拆官方 BIOS 包实测（2026-09-18 17:1x）

> 起因：用户问「**不能直接读固件**」。此题必须拆成两种"读"：**① 调用固件运行时接口**（macOS 做不到）／**② 离线拆固件包**（**不需要任何 OS**）。

### B.1 ① 运行时读 —— macOS 侧做不到（三条一手证据）

| # | 检查 | 结果 |
|---|---|---|
| 1 | `nvram -p` 全量 | **0 条** `Setup`/`HII`/`BIOS` 类变量 ⇒ 固件没把它暴露给用户态 NVRAM 白名单 |
| 2 | `DSDT.dsl` 的 `_WDG`（WMI GUID 列表） | 命中 **3 处**，含标准 ACPI-WMI 接口 GUID ⇒ HP 的 BIOS 设置走 **ACPI-WMI（PNP0C14）** 机制 |
| 3 | 机制 | ACPI-WMI 的消费方是 **Windows 的 `AcpiWmi.sys` + HP WMI provider**；macOS 无此驱动栈，**OpenCore 也不能执行 ACPI 方法**（它只做表注入/补丁） |

⇒ **"会调 ACPI-WMI 的 OS"是必要条件**：Windows 有、Linux 有（`acpi_call`）、**macOS 没有**。这条路上没有绕法。

### B.2 ② 离线读 —— **已跑通**（不需要 Windows、不需要 UEFI Shell、零硬件风险）

| 步 | 动作 | 结果 |
|---|---|---|
| 1 | 定位 SoftPaq：HP 安全公告 **HPSBHF04043** 公布 `HP ZBook Power G7 BIOS` = **SP154814** | ✅ 已下载 **22,581,536 B**（`ftp.hp.com`，HTTP 200） |
| 2 | PE 结构探测 | 尾部 overlay **22.27 MB**，内含真 **CAB**（`MSCF`@216064 是巧合；**真 CAB @331,559**，v1.3 / 1 folder / **17 files**） |
| 3 | `bsdtar -xf`（macOS 自带，**不需要 7z**） | ✅ 解出 17 个文件 |
| 4 | 固件镜像 | **`T75_01180100.bin` 32,315,326 B** ⇒ 内含 **`_FVH` × 34**（34 个 UEFI 固件卷） |
| 5 | 版本核对 | 包内 `History.txt` = **01.18.01**（2024-09-09）；⚠️ **本机 01.24.02 ⇒ 落后 6 个修订，结论须按此打折** |

同包副产品（**均未执行**）：`BCUsignature32/64.dll`（**HP BCU 的签名库**）、`HpqPswd.exe`、`HpFirmwareUpdRec64.exe`、`History.txt`（含 EC `34.2F.00`／GOP `9.0.1107`／ME `14.1.74.2355`／TB `62.0.1.2.1`／USB-C PD `CCG5 0.7.0` 各子固件版本）。

### B.3 ★ 关键发现：**固件里存在 Modern Standby 配置结构**

```
HpCommonSetup                        ← HP 的 Setup 配置变量名
├─ HpModernStandbyConfigurations     ← ★ 目标：Modern Standby 配置段
├─ PlatformMiscDeviceConfigurations
├─ SystemAudioDeviceConfigFlags
├─ UsbPortsFactoryConfigFlags
├─ CommonBuiltinDeviceConfigFlags
├─ WirelessDevFactoryConfigFlags
├─ MiscMobileKBCBuiltInConfig
├─ MemoryConfig
└─ FactoryConfig / FactoryConfigFlags
```
另命中：`S3MemoryVariable`、`FspS3Notify`、`$DeviceIdleEnabled`、`$DefaultIdleState`、`DefaultIdleTimeout`、`DeviceIdleIgnoreWakeEnable`、`PCH_SLP_S0IX#`。

⇒ **两条硬结论**：
1. **固件里确实有 Modern Standby 配置段**（`HpModernStandbyConfigurations`），且是 `HpCommonSetup` 这个 Setup 变量的**子结构** ⇒ 正是"隐藏设置项"的典型形态。
2. **固件里有 S3 的代码/数据路径**（`FspS3Notify`、`S3MemoryVariable`）⇒ 与 §2 的 L1（`SS3=One`）互印，**"固件没实现 S3"彻底不成立**。

### B.4 ⚠️ 方法论自曝（不写这条就会误判）

本次做字符串扫描时，**正向对照全部 0 命中** —— 连 BIOS 实拍图里确凿存在的 `Runtime Power Management`、`Extended Idle Power States` 都搜不到。真因：**32 MB 镜像里绝大部分模块是压缩的**（裸扫只覆盖未压缩区，共提取 1,472 条 UTF-16 串 + 101,387 条 ASCII 串）。

⇒ **铁律复用：本次只把"搜到了"当证据，绝不把"没搜到"当"不存在"。** 要拿**完整**清单必须先解那 34 个 FV（`uefi_firmware` 试解返回 `unknown` —— HP 是自研多组件容器，需 UEFITool 类工具或自写 FV 解析）。

### B.5 这一步改了什么、没改什么

| | 变化 |
|---|---|
| **撤回** | 附录 A 里"③ 固件隐藏层 = **无源之水**"、"HP 根本没做这个开关" —— **错**，固件里有 `HpModernStandbyConfigurations` |
| **升级** | ③ 从"零先例的空想"升为"**有实锤结构 + 有已知访问路径**（`HpCommonSetup` 变量 / HP WMI / BCU）" |
| **不变** | **"不赌"的结论不变** —— 仍不知道该项是否**可写**、写完是否真能关 AOAC、关了是否真能救回**已实测坏掉**的 S3。本轮只是把"未知"缩小了一圈 |

### B.6 下一步（二选一，均零硬件风险）

- **B-α（推荐 · 最省事）**：进 Windows 跑附录 A 的 `Get-WmiObject … HP_BIOSSetting`。表里若出现 `HpModernStandbyConfigurations` 一类项 ⇒ **直接锁定，且可按设置名写入**（可回滚、无偏移写错风险）。
- **B-β（完全不碰 Windows）**：解那 34 个 FV（需引入 UEFITool / 自写 FV 解析）→ 提 `HpCommonSetup` 模块的 **IFR** → 得到含隐藏项的**完整清单 + 每项在变量里的偏移**。成本：需工具链；且应换成本机对应的 **01.24.02** 包（SP154814 只有 01.18.01）。

> 本轮**零配置 / 零 EFI 改动**。固件包与解包产物仅落在 `/tmp/biosprobe/`（临时目录，未入库、未进工作区）。**其中所有 .exe 均已明确不执行。**

---

## 附录 C · B-β 执行结果：离线拆固件卷（2026-09-18 18:1x）

> 用户选 **B-β**（完全不碰 Windows）。**执行完毕：一半成功、一半是明确的否定结论。**
> **✅ 拿到了含隐藏项的完整设置项清单，并坐实 `Modern Standby` 是固件里的正式 Setup 项（多语言 UI）。**
> **❌ 但 B.6 里定的目标「提 `HpCommonSetup` 的 IFR、拿每项在变量里的偏移」本身不成立 —— 该固件没有 IFR。**

### C.1 执行链条（全在 macOS，零 Windows、零硬件风险，`.exe` 一个都没执行）

| # | 步骤 | 手段 | 产物 / 关键读数 |
|---|---|---|---|
| ① | 找**更新版本**的包 | HP 公告 `HPSBHF04087`（Intel 处理器固件 2026-02） | **`SP169002` = ZBook Power G7 BIOS 01.23.00 Rev2**（2026-08-27 更新）；旧包 `SP154814` = 01.18.01 留作对照 |
| ② | 下载 | `curl` | 两个包：22,581,536 B / 23,033,544 B |
| ③ | 找内嵌真 CAB | **按头部字段校验**（`vmaj∈1..3`、`cFolders≤32`、`cbCabinet` 不越界） | `sp154814` → **CAB@331,559**；`sp169002` → **CAB@330,678**。两包的 `MSCF@216,064` 都是**巧合命中**（v0.110 / 101 folders ⇒ 字段乱），靠校验剔掉 |
| ④ | 解 CAB | `bsdtar -xf`（macOS 自带 libarchive，**不需要 7z/cabextract**） | `T75_01230000.bin` **32,315,326 B**（01.23.00）+ `History.txt` |
| ⑤ | 解固件卷 | 下载 **UEFIExtract NE A75 universal_mac**（1.5 MB，`xattr -dr com.apple.quarantine` 后可直接跑） | `T75_01230000.bin.dump/` **302 MB / 15,718 个文件**；`_FVH` × 34，其中 **16 个合理 FV**（占镜像 49.8%） |
| ⑥ | 定位目标模块 | `UEFIFind` 搜 body（**解压后**内容） | `HpModernStandbyConfigurations` + `HpSetup` **同属模块 `A0A3FEC9-FE9D-4CE7-8DB4-9C54F3F19E5A`** = 卷 `11 B73FE497…` / File **`171 0147`**，DXE driver，1.33 MB |

**版本口径**：本机 **01.24.02**（BIOS 日期 2026-05-11）比手上最新的 **01.23.00 还要新一个修订**，HP 尚未在公告里列出对应 SoftPaq。两版镜像**同为 32,315,326 B、布局固定、42% 字节不同** ⇒ 结构跨版本稳定，用 01.23.00 的结构做判断是安全的（但不等于逐项等价）。

### C.2 ★ 核心成果：`Modern Standby` 是固件里的**正式 Setup 项**

模块 `171 0147` 只有 5 个段：**DXE dependency / Raw(120 B) / PE32(1,327,104 B) / UI / Version**。全部 UI 文本都在 **PE32 内的 UTF-16 宽字符串常量池**里。

**正向对照（必须先跑，否则证据无效）** —— 用 BIOS 实拍图里**确凿存在**的项验证检索方法：

| 对照项（实拍菜单里确有不疑） | 命中 |
|---|---|
| `Runtime Power Management` | ✅ 7 文件（UTF-16） |
| `Extended Idle Power States` | ✅ 7 |
| `Power Management Options` | ✅ 7 |
| `Power On When AC Detected` | ✅ 7 |

**目标项命中**：`Modern Standby` 在 HpSetup 里出现 **5 次**，跨 **3 种语言**：

| 偏移 | 语言 | 上下文 |
|---|---|---|
| 48,261 | **en-US** | `… Enable / Disable / `**`Modern Standby`**` / Deep Sleep has been gray out because Modern Standby is set to On. / Power Control …` |
| 48,366 | en-US | help 文本里再次引用 |
| 129,775 | **da-DK** | `Aktiv` / `Deaktiv` |
| 317,368 | **es-ES** | `Habilitar` / `Deshabilitar` |
| 317,545 | es-ES | 同上 |

⇒ **三项坐实**：
1. **它是一个 Enable/Disable 二元设置项**（不是只读状态位）；
2. **它是正式本地化项**（HP 为它准备了多语言 UI，不是遗留字符串）；
3. **它的 help 自曝互斥关系**：*"**Deep Sleep has been gray out because Modern Standby is set to On.**"* —— 这正是"AOAC 开着则 S3/Deep Sleep 不可用"在**固件自己的 UI 文本里**的表述。

它在字符串池里的物理位置**紧邻** Power 菜单核心项：

```
… Runtime Power Management | Enables Runtime Power Management.
  | Extended Idle Power States | Increases the OS's Idle Power Savings.
  | Deep sleep | Wake when Lid is Opened | Wake When AC is Detected | Wake on USB
  | (Warning!! Due to Deep Sleep is Enabled, …) | Enable | Disable
  | ★ Modern Standby | Deep Sleep has been gray out because Modern Standby is set to On.
  | Power Control | Battery Management | Battery Health Manager …
```

### C.3 ❌ 明确否定：该固件**没有 IFR**（三条独立判据）

| # | 判据 | 结果 |
|---|---|---|
| 1 | `UEFIExtract report` 的 section 类型统计 | **HII section = 0**（968 UI / 929 PE32 / 768 Version / 392 Raw / 377 DXE dep / 260 MM dep / 240 PEI dep / 26 Compressed / 24 TE / 5 GUID defined / 1 Volume image） |
| 2 |全 dump **15,718 文件**搜 `EFI_HII_PACKAGE_END` 指纹 `06 00 00 00 DF 00` | **0 命中** |
| 3 | 该 PE32 内**严格 HII 包链扫描**（≥3 包、且以 `END(0xDF)` 收尾） | **0 段** |

两条旁证：
- 字符串池里 `Runtime Power Management`（47,539，24 字符 = 50 B）**与它的说明文本（47,590）字节直接相邻** ⇒ **没有 SIBT 结构、没有 string ID** ⇒ 是**编译器生成的宽字符串常量池**，不是 HII STRINGS 包。
- `HII_DATABASE_PROTOCOL` GUID 确实出现在 **12+ 个模块**里 ⇒ **EDK2 的 HII 框架代码在**，但**没有任何模块安装 HII 包**（框架被保留、Setup 不走它）。

⇒ **HP 的 Setup 是自研引擎**，设置项定义与显示逻辑都在 PE32 代码里，**没有 IFR 可解**。

⚠️ 一次自我纠错：中途我的"IFR 检测器"在 `151 081E` 报过"首 op = `0x24`(VARSTORE)"，dump 出来却是 `f3 a5`(rep movsd) / `c3`(ret) / `cc`(int3) —— **那是 x86 机器码的假阳性**（0x24 后跟合理长度在代码里很常见）。凡"走链检测"类启发式，**必须回读落点字节**才算数。

### C.4 顺带拿到的东西

- **完整 Power 菜单字符串清单**（含项名 + 说明 + 选项值）已存证 → **`docs/backups/bios-teardown-2026-09-18/hp-setup-power-strings.txt`**（12.6 KB）。里面能直接读到：`Energy Efficient Turbo` / `Ambient Light Sensor` / `Thunderbolt Options`（`Native + Lower Power Mode`）/ `Power On When AC Detected` / `Fan Always on while on AC Power` / `Backlit keyboard timeout`(5s–Never) / `Boost Converter` / `Wake on LAN in Battery Mode` / `Disable battery on next shut down`(Next shut down / Do not disable) / `Runtime Power Management` / `Extended Idle Power States` / `Deep sleep`(Wake on Lid/AC/USB) / **`Modern Standby`** / `Battery Health Manager`(三档) …
- 结构化事实：`HpCommonSetup` 是固件里的 **UTF-16 变量名字符串**（16 个文件命中），**不是** IFR 的 ASCII `VarStore` 名 —— 与 C.3 相互印证。

### C.5 这一轮改了什么 / 没改什么

| | 内容 |
|---|---|
| **升级** | 附录 B 的"固件里有 `HpModernStandbyConfigurations` 结构" → **升级为"有完整的多语言 UI 的正式 Setup 项"**（B 阶段只能算"有实锤结构"，C 阶段是"**确认可操作项 + 知道它的名字**"） |
| **升级** | **③a 路径的可操作性显著提高**：上一轮只能说"表里有 sleep 项就锁定"，现在**知道要搜的准确名字 = `Modern Standby`** |
| **否定** | **"解 IFR 拿变量偏移"不适用**（无 IFR）。要偏移只剩**逆向 PE32**（成本高，且 HP 的设置未必存 NVRAM 变量 —— 也可能是 EC/ROM）⇒ **本条从"待办"划掉，不再作为路径** |
| **不变** | **"不赌"不变**。仍然不知道：该项**能否写**、写完**能否真关掉 AOAC**、关掉后**能否救回已实测坏的 S3**；赌注仍不对称（代价＝唯一可用的 Deep Idle） |

### C.6 下一步（只剩两条，都零风险；仍不建议赌）

1. **BIOS 里主动找一次 `Modern Standby`** —— 它物理上紧邻 `Deep sleep` / `Runtime Power Management` / `Extended Idle Power States`，且字符串池里紧跟其后出现分类名 `Power Control`。已知它**不是**在 `Power Management Options` 那张实拍图里 ⇒ 优先看**其它分类/子菜单**（尤其含 `Power Control` 字样的地方），或菜单需要滚动的位置。**找到了 ⇒ 直接改，零风险、可回滚。**
2. **HP 官方只读入口（附录 A ③a）** —— 下次进 Windows 顺手跑那条 `Get-WmiObject … HP_BIOSSetting`，**搜 `Modern Standby`**（现在有准确名字了）。带 `DisplayInUI` 字段 ⇒ 一次就能回答"这机器到底把它藏没藏"。

⚠️ 即便 ①② 都指向"可以关"，**动手前仍应回到 A.4 的赌注账**：关 AOAC 的收益是**已实测坏掉的 S3**，代价是**唯一可用的 Deep Idle**。

### C.7 方法论自曝（三条，都已写进 `docs/tooling-gotchas.md`）

1. **UI 文本是 UTF-16LE**：用 ASCII 搜 → **0 命中**（本轮第一版就栽在这）。凡固件字符串检索，**必须双编码并跑**。
2. **必须先解包再搜**：未解包的 32 MB 镜像里，`Runtime Power Management` / `Modern Standby` / `Deep Sleep has been gray out` **全部 0 命中**（它们在压缩段内）；解包后 `Modern Standby` 立刻 9 个文件命中。⇒ **"0 命中"≠"不存在"，这一条本轮又被验证一次。**
3. **正向对照必须用"确凿存在"的锚点**：本次锚点 = BIOS 实拍图里看得见的 4 项。**没有对照的 0 命中不作数。**

> 本轮**零配置 / 零 EFI 改动**。固件包与 302 MB 解包产物**只在 `/tmp/biosprobe/`**（未进工作区）；入库的只有**结论文档 + 12.6 KB 字符串清单**。
