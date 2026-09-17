# 睡眠档位调优测试记录

> 🟢 **2026-09-17 10:4x【最新 · §三十一】—— 重启已验证：第 1 步通过 ✅ `IOPMDeepIdleSupported` 从 `Yes` 变为"属性完全不存在"**
> 判据链：AppleACPIPlatform 仅在 `\_SB.LPS0` 返回 **Integer 1** 时才 `setProperty("IOPMDeepIdleSupported")` ⇒ 属性**整个消失**（比 `= No` 更彻底）= LPS0 未提供 = **macOS 不再认为平台是 Deep Idle**。同一变量（SSDT 开关）的两次对照观测，前后互证。
> ⚠️ **两条旁证已否掉（别再踩）**：`ioreg -p IOACPIPlane -l -w0` **输出 0 行、连必然存在的 `PCI0` 都搜不到 ⇒ 该 plane 在本机不可读**（`LPS0`/`_S3` 搜不到是**此路不通**，不是对象不存在）｜OpenCore 日志 = `Misc/Debug/Target = 0`，**无输出**。
> ★ **"某个 SSDT 到底加载了没有"的可靠判据**：① **行为判据最强**（该 SSDT 的**唯一副作用**是否在系统里出现/消失 —— 本例 `SSDT-DeepIdle` 的唯一副作用就是那个属性）② 配置 + **重启前后对照** ③ DSDT 归属分析 ④ ❌ 别用 IOACPIPlane / OpenCore 日志。
> ▶️ **第 2 步（待执行，唯一直接判据）**：`pmset sleepnow`（手动、**不合盖**）→ 醒来查 `pmset -g log | grep -iE "Entering Sleep|Wake from"`：出现 **`Wake from S3`** = L2+L3 双确认；仍是 `Wake from Deep Idle` = 未被选中。顺带验 Fn 键/亮度/电池指示（黑苹果走 S3 有"EC query 失效"先例）。**不写 RTC/镜像 ⇒ 无 005**。

> 🔴 **2026-09-17 10:2x【§三十】—— 用户再问「s3睡眠？你确认？」⇒ 补两条硬证，结论仍是"只确认声明层，不确认能睡"**
> **新证 A（决定性）**：`SSDT-OCLT-S3Fix.aml` 是**空转**的 —— `Enabled=False`；且其 ASL 只在**非 Darwin** 下定义 `_S3`（Darwin 分支为空），而它赖以自洽的 `_S3→XS3` 改名在 `ACPI/Patch` 里**根本不存在**（config 只有 2 条 patch：PNLF→XNLF、GNUMGPDI→TPNMGPDI）⇒ **`_S3` / `SS3=One` 100% 来自 HP 固件原生，"补丁论"在任何开关组合下都不成立**。
> **新证 B（对首测有利）**：`SSDT-PCI0.LPCB-Wake-AOAC.aml`（`Enabled=True`）的 `_DSW` **只在 `Arg0 == 0x03` 时动作** —— `0x03` 就是 **S3** ⇒ **唤醒侧配置本来就是按 S3 准备的**，它与 `SSDT-DeepIdle` 是**替代关系而非叠加**。
> **准确答法（三层，只确认第一层）**：
> **L1 声明层＝✅确认**（`_S3`@`DSDT.dsl:38257-38266`、`SS3=One` 常量@`5706-5709`、S3Fix 空转、FADT `HW_REDUCED_ACPI=0`、日志 `ACPI: sleep states S0 S3 S4 S5`）；
> **L2 macOS 选不选 S3＝❌不确认**（现测 `IOPMDeepIdleSupported = Yes`，从未出现 `Wake from S3`）；
> **L3 硬件真按 S3 断电＝❌不确认且**有反例（Surface IceLake 同构、HP 企业实测 `PlatformAoAcOverride=0` 无果、本机 EC 固件 `SLP_S3/4/5` 与 `PCH_SLP_S0IX#` 两套并存）。
> ⇒ **"没被隐藏" ≠ "能用"**：`SS3=One` 只是**必要条件**（证明固件没隐藏 S3），**推不出** PCH 会用 `SLP_S3` 真断电。
> ⚠️ **风险升级**：`SSDT-DeepIdle` 是**唯一**把 macOS 推向 S0ix 的东西（`DSDT` 里 `LPS0`/`LXEN` 计数 = **0**）⇒ 关掉后 macOS **会去试 S3**，若处于"代码路径在、PCH 不通"的**半通**状态，可能**睡下去醒不来 / 唤醒黑屏** —— **这正是 DELL E7480 当初引入 `SSDT-DeepIdle` 要规避的症状**。
> **★「没法确定？」⇒ 穷举全部只读通道，结论：零条**（09-17 10:3x 追加）：macOS `IORegistry`（`ioreg -l -w0 | grep -i "sleep states"` ⇒ **空**、`AppleACPIPlatformExpert` 节点**不存在**）｜`sysctl -a`（只有 `kern.hibernatefile/sleeptime` 等路径与计数器）｜`pmset -g cap`（只列**可设项**，不含睡眠态）｜`Supported Features` 字典（**无 S3**）｜HP QuickSpecs（**通篇无 S3 字样**）｜Windows `powercfg /a`（读**同一份 ACPI** ⇒ **非独立判据**，上轮"权威交叉验证"说法**已更正**）⇒ **唯一直接判据 = 实际睡一次（L2+L3）**。
> **原理**：`能不能睡进 S3` 的最后一环是**硬件行为**（PCH 是否真拉低 `SLP_S3` 并维持 `VccRAM`）。`_S3` 对象＝**菜单上印了这道菜**；`_PTS/_WAK` 的 `0x03` 分支＝**厨房还留着这套灶**；EC 的 `SLP_S3/4/5`＝**燃气管还在墙上**。**"灶还在" ≠ "火能点着"** —— 本机 EC 固件 `SLP_S3/4/5` 与 `PCH_SLP_S0IX#` **两套并存**，正合"AOAC 把物理 S 信号重定向"的格局。
> **首测纪律**：① 先存全部工作 → ② `pmset sleepnow` **手动触发、不合盖** → ③ **30 s 不醒长按电源 10 s**。**不写 RTC、不写镜像 ⇒ 无 005**；回滚 = `Enabled` 改回 `true`。完整取证：`round2-tierB-result.md` **§三十**。

> 🟢 **2026-09-17 09:5x【§二十九】—— 用户追问「确认我的硬件支持 S3？」⇒ 分两层答：声明层=确认；执行层=未验证**
> **① 声明层已定案（6 条只读硬证）**：
> `\_S3` 存在（`DSDT.dsl:38257-38266`，`SLP_TYPa=0x05`，根作用域）｜**★ `SS3` 是常量 `One`**（`:5706-5709`，全库无赋值 ⇒ `If (SS3)` 恒真）⇒ **本机是"原生声明 S3"，不是补丁改的**｜
> FADT `FLAGS=0x002384A5`（`HW_REDUCED_ACPI=0` ＋ `RTC_S4=1` ＋ `LOW_POWER_S0_IDLE_CAPABLE=1` ⇒ **AOAC 与 S3 并存**）｜
> `_PTS:30144` / `_WAK:30233,30241` 有 `Arg0==0x03` 分支（含 `SSMI 0xEA91`）⇒ **固件写了 S3 流程**｜
> EC 固件有 `SLP_S3/S4/S5`、`PrepareToEnterS0` ⇒ **EC 也有 S3 状态机**｜
> 本机内核日志实测 `ACPI: sleep states S0 S3 S4 S5`，**且与 DSDT 里实际存在的 `_Sx`（SS1=SS2=0 ⇒ 只有 S0/S3/S4/S5）逐一对应**。
> **② 执行层未验证**：所有历史睡眠的唤醒行都是 `Wake from Deep Idle`，**无一次 `Wake from S3`**，`IOPMDeepIdleSupported` 仍 `Yes`；
> 反例仍在（Surface IceLake 是 `SS3=0` 靠补丁补出来的 S3，**与本机"原生 One"不同，只能当风险提示**）。
> **③ 现状推进**：工作区与 ESP 的 `config.plist` **哈希已一致**（`d8da91f2…`）⇒ §二十八 的 `SSDT-DeepIdle=false` **已在 ESP**，**只差重启**。
> **④ 判据不变**：重启 → `ioreg -c IOPMrootDomain -r -d 1 | grep -i deepidle` 变 `No` ⇒ 再睡，看 `Wake from S3`（目标 5 W → ≈0.5–1 W）。
> ⚠️ **S3 不写 RTC、不写镜像 ⇒ 该实验不会引发 005**；起不来就长按电源。完整取证：`round2-tierB-result.md` **§二十九**。

> 🟢🟢🟢 **2026-09-17 09:2x【§二十八】—— BIOS 路线作废；真正的扳手 = 关掉 `SSDT-DeepIdle`（源码级铁证）**
> **① 撤回（重要）**：§二十七 让你"去 F10 找 BIOS 关 AOAC"**是猜的**。核实结论：HP《Power Management Options》官方菜单全表里**没有**任何 `Modern Standby` / `S0ix` / `Sleep State` 条目；
> 唯一真实存在的 `Extended Idle Power States`，HP 官方定义是 **C-state 空闲省电**（*"decrease the processor's power consumption when the processor is idle"*），**不是 S0ix 选择器**；
> 同族 HP ZBook 实测原话 *"[x] Extended Idle Power States setting was indeed a dud … did absolutely nothing to this issue"*。BIOS 已是最新 ⇒ **§二十七 的 ②③ 两条全部作废**。
> **② 源码级铁证（新的首选路线）**：反汇编 `AppleACPIPlatform.kext` 可见它**字面求值 `\_SB.LPS0`**，且**只有返回 Integer 1** 才 `setProperty("IOPMDeepIdleSupported")` 到 `IOPMrootDomain`（随后同样处理 `\_GPE.LXEN`）。
> 而 `\_SB.LPS0` **只由我们 EFI 的 `SSDT-DeepIdle.aml` 提供**（DSDT 里两者皆无）⇒ **关掉它 = 强制 macOS 回落 DSDT 的 `_S3`（SLP_TYP 0x05）**。
> **③ 现状实测**：`ioreg -c IOPMrootDomain` ⇒ **`"IOPMDeepIdleSupported" = Yes`**（读出来的，不是推的）。
> **④ 已落盘（工作区，1 个布尔值）**：`SSDT-DeepIdle.aml` → `Enabled=false`；`SSDT-PCI0.LPCB-Wake-AOAC` **保持启用**（它的 `_DSW` 只在 S3 时动作）；`hibernatemode 0` / `standby 0` **不动**。
> **⑤ 判据不用睡觉就能读 ⇒ 零 RTC 风险**：同步 + 重启后跑
> `ioreg -c IOPMrootDomain | grep IOPMDeepIdleSupported` → 变 `No` = 让路成功（**再**去睡，看是否出现 `Wake from S3`，目标 5 W → ≈0.5–1 W）；仍 `Yes` = 此路不通，**零损失，直接回滚**。
> ⚠️ **风险**：那套三件套在来源机型（Dell Latitude E7480）上**正是为规避"S3 唤醒黑屏"而引入**的 ⇒ 有重现黑屏的可能；但只改 1 个布尔值、不碰 NVRAM/休眠/Windows 引导 ⇒ 可无损回滚。
> 完整取证：`round2-tierB-result.md` **§二十八**。

> 🔵 **2026-09-17 09:0x【§二十七】—— 根因收敛：AOAC 与 S4 结构性冲突**（其 ②③ 两条已由 §二十八 作废）
> 差分铁证：今天 **9 次睡眠 = 5 次武装休眠（全死）＋ 4 次普通睡眠（全活，含连睡 12.6 h 无 005）** ⇒ 「RTC 电池弱」「RTC 被写坏」**整类排除**。
> 代价模型修正：**S3（≈0.5–1 W）远优于 Deep Idle（≈5 W）** ⇒ 换 S3 是**首选**，不是"本末倒置"。
> 完整取证：`round2-tierB-result.md` **§二十七**。

> 🔵🔵 **2026-09-16 20:0x【§二十六】—— HP 官方文档印证：这是固件问题，解法 = 更新 BIOS**
> 用户现场观察「**只有睡眠唤醒后才报那个错**」＋ wtmp 证据（今日 5 次正常关机/重启时钟**全对**）
> ⇒ **"RTC 电池弱 / 时间因素"降级**（弱电池不会专挑"睡过"那次丢时间）。
> HP 支持文档 `ish_2843606-2359609-16` **原文有一节标题就是**：
> > **退出休眠状态后，系统时钟显示的时间不正确。**
> > **在某些电脑上，系统时钟在退出休眠状态后可能停止或重置。更新 BIOS 应该可能会解决该问题。**
> ⇒ 本机 BIOS 大概率是老旧版本；HP 对 ZBook Power G7 已更新到 **01.20.00（SP157074）**。
> ⇒ **下一步只有一个**：核对 BIOS 版本（F10 → Main，或 Windows `fn+Esc` / `wmic bios get smbiosbiosversion`）→ 低于最新则更新后复测。
> ⚠️ 01.20.00 属"安全性增强"版，**刷上去不能回退**；安全垫已核（ESP `\EFI\BOOT\BOOTX64.efi` 存在、ACPI 快照可 diff）。
> 完整取证：`round2-tierB-result.md` **§二十六**。

> ⚠️⚠️ **2026-09-16 19:5x【总修正】—— 已被 §二十六 细化，主结论仍有效**
> **HP 005 的官方语义是「RTC 掉电」，不是「CMOS 被写花」**（HP 原文 *"…a loss in **battery power** … you might need to **replace the CMOS or RTC battery**"*）。
> ⇒ 三层软件防护（内核 `rtcfx_exclude=0E-FF` ＋ 协议层 `AppleRtcRam=true` ＋ `rtc-blacklist` 242 B）**全开仍报 005，本就不矛盾** —— 掉电不是"写"。
> ⇒ 「保 CMOS 与保休眠互斥」「出差改用关机」两条**均降级 / 暂缓**。
> 完整论证：`round2-tierB-result.md` **§二十五**。

> ⚠️ **2026-09-16 复查：`round1` 的"档 A 判死"结论已撤回。**
> 真因是**测试条件不成立**（`standby` 要求电池供电，而测试在插电下进行），
> 且 EFI 缺 `HibernationFixup.kext`。详见 `round1-tierA-result.md` 顶部撤回声明
> 与 `round2-plan.md`。

---

## ⛔ 2026-09-16 18:30 结案（⚠️ 已由 §二十五 修正）：**"真休眠"路线 6 次尝试全部失败，测试终止**

- **6 次真休眠尝试（11:16 / 12:04 / 13:11 / 14:39 / 18:09 / 19:29）全部失败**，其中 **3 次把 RTC 写坏** ——
  重启后 POST 报 **HP 005 `Real-Time Clock Power Loss`** ＋ 系统时钟回落 `2019-01-01`。
- **`RTCMemoryFixup` 装对了也没挡住**（`rtcfx_exclude=80-FF` 语法经上游 README 核对**正确**，类实例计数 = 1）。
- **`HibernationFixup` 的 NVRAM 兜底从未触发**（失败后 `nvram -p` 无任何休眠变量）⇒ 机器死在"进入 hibernate 电源态"**之前**。
- ★ 上游 `RTCMemoryFixup` README 原文：`0x80–0xAB` 存放 `IOHibernateRTCVariables`，
  「**If any offset in this range causes a conflict, you can exclude it, but hibernation won't work.**」
  ⇒ ~~保 CMOS 与 保休眠互斥~~ —— **⚠️ §二十五 已把此"判死"降级为「未证实」**（推理链本身仍成立，但它已不是 005 的解释）。
- ⇒ 脚本 `pmset-hibernate.sh` 的 `auto / test / on / instant` **已加硬闸**（需 `FORCE_HIBERNATE=1`；另有 `rtcprobe` 诊断档）。
- 完整取证：`round2-tierB-result.md` **§二十三**（＋ §二十四 / §二十五）。

### 🔁 2026-09-16 19:0x 复炉 → **19:29 已出结果：照样 005**

逐行核对上游源码后确认：**前 5 次测量是在「RTC 防护有缺口」的条件下做的** ——
Apple 校验和区间从 `0x0E` 起算，`0x0E–0x7F` **从未被任何一层拦过**；协议层（boot.efi）更是**零防护**
（`AppleRtcRam=false`、无 `rtc-blacklist`）。
⇒ 已改工作区 EFI **4 项**：`rtcfx_exclude=80-FF→0E-FF`、`AppleRtcRam=true`、
新增 `4D1FDA02-…:rtc-blacklist`(242 字节 `0E–FF`)、`NVRAM/Delete` 补该项
（19:16 同步 ESP，19:19 实测四项运行期**全部生效**）。
**结果（19:29）＝照样 005** ⇒ **「软件写 RTC 把 CMOS 写花」整类成立性证伪**（源码级复核：黑名单写只落内存，
协议层写路径还被 `SyncRtcRead` 的 bug 额外短路 = 双重保险）。
⚠️ **但这不等于解释了"休眠失败" —— 两者可能是独立问题，见 §二十五。**
详见 `round2-tierB-result.md` **§二十四**（含硬事实出处、执行步骤、回滚）。

---

## 为什么必须先重启
`Misc/Boot/HibernateMode` 与 `Kernel/Add`（kext 清单）都是 **OpenCore 在启动时读取**的。
当前运行的会话由旧配置引导 —— 此时若休眠，OC 不认识休眠镜像 →
冷启动（会话丢失，系统不坏）。
故任何休眠测试前，必须先重启一次让 OC 加载新配置（`HibernateMode=NVRAM` + `HibernationFixup.kext`）。

## 关键前提（2026-09-16 两次修正）

| 计时器 | 生效条件 | 本机状态 |
|---|---|---|
| `standby` | 电池供电 + **无外接设备** + 无网络活动 + **无外接显示器** | AC 下未证实；**且本机常态接着外接显示器 + USB 鼠标，前提被破坏** |
| `autopoweroff` | 外部电源供电 + 无外接设备 + 无网络活动 | ❌ `pmset -g cap` **无此项** |

→ ✅ **2026-09-16 17:2x 已查明 —— 「AC 下走不通」撤回**：`pmset -g cap` 的 `-b` 与 `-c` 输出
**逐行完全相同** ⇒ 能力是**机型级**（说"AC 侧 cap 没有 X"这种框架本身就是错的）；cap **列出了
`standby`**，且 `pmset -g custom` 的 **AC 段可见 `standby`** ⇒ 按 man 判据
（"visible in `pmset -g` if the feature is supported"）**AC 侧 `standby` 受支持**。
真正不受支持的只有 `autopoweroff`/`autopoweroffdelay`（**机型级**）。详见 `round2-tierB-result.md` §二十二。
→ ★ **第 1 轮不触发的真实原因**：AC 侧当时 `standby = 0` 且 `standbydelay` 为默认 3h/24h
（10800/86400）⇒ **从未配置过触发条件**；而实测那次只睡了 **152 s**（距 10800 s 阈值**差 71 倍**）
⇒ **无效测试**，不构成"AC 走不通"的证据。
⚠️ 「外接显示器 / USB 鼠标破坏 standby 前提」那条是**社区总结** —— 本机 `man pmset` 的 standby 段
**通篇未提**外接设备条件 ⇒ 降级为**待验证假设**，不再当结论用。
→ ~~插电深睡**已配好**（§二十二 §4）：`hibernatemode 25 + standby 1`，长延迟 1 h / 2 h~~
→ ⛔ **已于 2026-09-16 18:27 撤回**：该配置在 18:09 的实测中与第 1–3 次**同型失败**
（入睡 → 断气 → 无 `Wake from` / 无 `Entering Hibernate` → 重启 POST 005 + 时钟回 2019）。
现两电源源均回 `hibernatemode 0 / standby 0`。**结论见文件顶部横幅。**

## 档位与安排

| 档 | 配置 | 睡眠行为 | 状态 |
|---|---|---|---|
| Deep Idle | `hibernatemode 0` `standby 0` | 永不落盘，内存全程带电（≈5 W 墙插） | ✅ **2026-09-16 18:27 起为现役档**（两电源源，`pmset-hibernate.sh off`） |
| ~~A 惰性深睡~~ | `hibernatemode 25` `standby 1` `standbydelay* 3600/7200` | 短睡内存秒醒 → 1~2 h 后落盘断电 | ⛔ **已证伪并停用**（18:09 实测：睡下即断气 + POST 005）；改成 `25/1/3600-7200` 也**没有改变结局** |
| ~~B 真休眠~~ | `hibernatemode 25` `standby 1` `standbydelay* 600/1800` | 短睡内存秒醒 → 10~30 min 后落盘断电 | ⛔ **已证伪并停用**；且**已拆掉地雷** —— 电池侧前提天然满足，留着它下次出门合盖必炸 |
| **C 传统 S3** | **只需关掉 `SSDT-DeepIdle`**（去掉 `\_SB.LPS0`）→ 重启。**不需要动 BIOS，也不需要关 `SSDT-PCI0.LPCB-Wake-AOAC`** | ★ **`hibernatemode 0`**：睡眠 **改为 S3**，功耗 **≈0.5–1 W**（vs Deep Idle 的 ≈5 W） | 🟢🟢🟢 **2026-09-17 定为首选（§二十八）** —— BIOS 路线已被证伪（HP 菜单无该选项 + 同族两例实测无效）；本行判据**不用睡觉就能读出**（`IOPMDeepIdleSupported` 是否翻 `No`） |

> ⚠️ 「档 B = 每次睡眠立即写镜像 + 断电」这条**原表述已修正**：`hibernatemode 25` **单独设了不生效**，
> 必须配 `standby 1` 作为**触发计时器**（本机无 `autopoweroff` 可用）。缺了它 ⇒ 全程 Deep Idle（14:39 实测）。

## S1 / S2 的差别（一句话）

| | S1（含 S0） | S2 |
|---|---|---|
| 换什么 | **测试条件**（拔外设、拔电） | **机制**（装 kext + 换档 25） |
| 改什么 | 无，只动 pmset | EFI：`HibernationFixup.kext` |
| 要重启吗 | 不需要 | **需要**（OC 启动时读配置） |
| 风险 | 🟢 零（第 1 轮已证会话不丢） | 🟡 中（新 kext） |
| 验证哪一段 | **计时器**：到点会不会自动断电 | **写镜像 → 断电 → 恢复** 全链路 |
| 回滚 | `pmset-hibernate.sh off` | `git revert` + 重启 |

## 缺失的前置件

**~~`HibernationFixup.kext` 未安装~~ → ✅ 已于 2026-09-16 安装（commit `85888f6`）。**

它负责把内核的 `IOHibernateRTCVariables`（加密密钥）写进 NVRAM，
而 `HibernateMode=NVRAM` 让 OC 从 NVRAM 读 —— **只有读端、没有写端 = 空转**。
现在**写端已补齐**（1.5.4，`Kernel/Add` index 1 紧挂 Lilu，依赖 Lilu ≥1.2.4 / 本机 1.7.3）。
→ 在此之前，任何档位都不该期望成功；**现在可以真正开始测了**。

## 判据（醒来后立刻跑）

1. `sysctl kern.hibernatecount` → **从 0 变 1** = 真正落盘断电过（最硬证据）
   ⚠️ 但实测冷启动恒回 0 ⇒ **别拿它当唯一判据**，要配合下面几条。
2. `stat -f "%m" /var/vm/sleepimage`（或 `ls -la`）→ mtime **更新** = 镜像被写过
3. `pmset -g log | grep -E "Entering Standby|Entering Hibernate"` → 出现记录
4. `sysctl kern.sleeptime kern.waketime` → 两时间差 ≈ 睡眠时长
5. 体感：睡着后机器**变凉**（5W → 0.2W）

### ⛔ 失败判据（本机实测 5/5 都是这个样子，务必先认它）

| 症状 | 证据 |
|---|---|
| 入睡后几分钟内**直接断气**（风扇停、灯灭，但不是正常断电） | `pmset -g log` 里**只有** `Entering Sleep`，**没有** `Wake from` / `Entering Hibernate` / `ShutdownCause` |
| 重启后 **HP POST 005 `Real-Time Clock Power Loss`** | 屏幕 |
| 系统时钟回落到 `2019-01-01`（约 35 s 后网络对时自愈） | `who -b` = `Jan  1 08:07`；开机瞬间 `date` |
| `nvram -p` 里**没有**任何休眠变量 | `HibernationFixup` 从未触发 ⇒ 死在进入 hibernate 之前 |
| `kern.hibernatecount` = **0** | 冷启动重置 |

## 回滚

```
./EFI/scripts/pmset-hibernate.sh off        # 回纯 Deep Idle
```

失败（起不来）：长按电源 → 能进系统就跑 off；macOS 也起不来则
OpenCore 菜单 Enter → Reset NVRAM（逃生口 `AllowNvramReset=true` 已开）。

## 档案索引

- `baseline-2026-09-16.txt` —— 改动前的 pmset 快照
- `round1-tierA-result.md` —— 第 1 轮实测（含撤回声明）
- `round2-plan.md` —— 修正后的复测路线 S1~S4
- `../../EFI/scripts/rtc-protect-verify.sh` —— 只读核验「RTC 写保护四层」是否落地（§二十四 的执行前提）
