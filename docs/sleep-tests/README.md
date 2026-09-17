# 睡眠档位调优测试记录

> 📚📚 **2026-09-17 12:3x【最新 · §三十六】—— 用户追问「全部只能测试？变量太多？不确定的点先在社区确认过吗？」⇒ 去社区查证，一查就命中全部结论**
> **① ★★★ 决定性原文**：OC-Little《01-关于AOAC》—— *"由于 **AOAC 和 S3 本身相矛盾**，采用了 AOAC 技术的机器不具有 S3 睡眠功能……一旦进入 S3 睡眠就会**睡眠失败**……主要表现为：**睡眠后无法被唤醒，呈现死机状态，只能强制关机**"* + *"**禁止 S3 睡眠** 可以解决睡眠失败问题"* + *"电池……大约每小时耗电 **5%–10%**"* ⇒ **用户症状逐字命中（"只能强制关机"）；本机实测 5 W ≈ 7%/h 落在社区区间；而我做的回滚 = 社区标准解。**
> **② ★★ Ice Lake 汇总仓库：AOAC 机型只有三条路，本机三条全不可用** —— ① daliansky/SSDT 补丁（*"不稳定：电池寿命低，有些机器即使用这些补丁也唤不醒"*）= **本机原状态**；② BIOS 关 AOAC（*"最难但最稳定"*）= **本机 BIOS 无此项**（§二十八）；③ SSDT+rename 开 S3（*"**for some of Dells**"*）= **本机是 HP，不在范围**。
> **③ 自我批评**：§二十八 关 `SSDT-DeepIdle` 上 S3 时，**我只读了 OC-Little 的子页 `01-4-AOAC唤醒方法`，没读父页 `01-关于AOAC`** —— 而父页第一段就写着"AOAC 和 S3 相矛盾"。**读了就能省掉两次实测 + 那次 panic。**
> **④ 变量清点**：整轮动过 **6 个**（4 项 RTC 防护 + 2 个 ACPI 开关），**睡眠相关 2 个已全部回滚 ⇒ 现为 0**；4 项 RTC 只碰 I/O `0x70/0x71`、与 EC（`0x62/0x66`）端口不相交（§三十五）且**必须保留**（防 005）。
> **⑤ 结论**：本轮**零实测**。社区已把"AOAC 机型强上 S3"定性为极可能失败；实测只把它从"极可能"变成"本机确认"。**本机（HP Comet Lake + 原生 `_S3`）这个具体组合，社区无先例** —— 三条路都不覆盖，这解释了为什么每个方向都得自己试。完整见 `round2-tierB-result.md` **§三十六**。
>
> 🔍🔍 **2026-09-17 12:0x【§三十五】—— 用户追问「有没有可能是你配置有问题？」⇒ 定位到 **EC（嵌入式控制器）在 S3 恢复后停止响应****
> **① ★★★ 新证据**：S3 恢复窗口里 `(AppleACPIEC) EC OBF=1 poll timed out` **每 ~2.2 秒一次连绵不断** —— EC 的 Output Buffer Full 恒为 1 ⇒ **EC 从不响应**（`AppleACPIEC` 轮询 I/O `0x66` 永远等不到清位）。
> **② ★★★ 对照（`EC OBF=1` 计数）**：09-15 普通运行 **1**（噪声）/ 09-16 20:00 Deep Idle 唤醒 **0** / 09-17 08:52 Deep Idle 唤醒 **0** ‖ **09-17 10:48 S3 第一次 34** / **11:33 S3 第二次 120** / 11:46 回滚后运行 **0** ⇒ **分界干净，S3 独有**。
> **③ 一次解释所有慢数字**：`ApplePS2Controller(SetState to 2)` 457–466 ms → **157,735 ms**、`SMCSMBusController(SetState to 1)` 不上榜 → **11,064 ms** —— **PS2/KBC 与 SMC 都经 EC 访问** ⇒ 死等 ⇒ 唤醒拖到 160 s ⇒ USB/蓝牙/摄像头重新枚举失败 ⇒ panic 落 USB 栈。
> **④ 诚实交代混淆变量（用户这一半是对的）**：09-17 只有 10:39/10:52/11:16/11:42 四次重启，最后一次"已知良好"的 Deep Idle 唤醒是 **08:52**；而 **10:39 那次重启同时生效了 4 项** = `DeepIdle=false` + `AppleRtcRam=false→true` + `rtcfx_exclude 80-FF→0E-FF` + 新增 `rtc-blacklist 242B` ⇒ **没有一次 S3 实测跑在干净配置上**。
> **⑤ 但 RTC 三件套在机制上被排除**：其作用域只有 **RTC RAM（I/O `0x70/0x71`）**，而坏的是 **EC（I/O `0x62/0x66`、驱动 `AppleACPIEC`）** ⇒ **两条路径硬件上完全不相交**。**拦 RTC 写不可能让 EC 停止回话。**
> **⑥ 真 A/B**：`SSDT-PCI0.LPCB-Wake-AOAC` 开（34 次）也失败、关（120 次）也失败 ⇒ 不是决定因素。
> **⑦ 结论**：`SSDT-DeepIdle=false` **不是"配错了值"**，而是打开了一条**这台固件没有完整实现的状态转换**。EC 的 ACPI 声明干净（DSDT `Device(EC0)`@`27116` `_HID=PNP0C09`、`_REG`@`27196`；`SSDT-EC.aml` 仅 125 B 假 EC，不改名不隐藏；`ACPI/Patch` 仅 2 条且不碰 EC），**同一套 EC 握手代码每次开机都跑通** ⇒ 是 S3 后固件把 EC 留在不接受 legacy 初始化的状态，与 §二十七「AOAC 与 S4 冲突」**同族**。
> **⑧ 唯一剩余实验（建议不做）**：单独回退 RTC 三件套 + 保留 `DeepIdle=false` 再测。收益仍只是"也许能修好唤醒"（确定收益 5 W→1 W），且回退会重开 005 风险窗口。
> **⑨ ⚠️ 当前状态**：`boottime`=11:42:02、`IOPMDeepIdleSupported` **仍不存在** ⇒ **本轮系统还在 S3 模式**；工作区/ESP 已哈希一致（`f7261b16…`）且两 SSDT 均 `True` ⇒ **磁盘已是稳定态，只差重启**。
> 完整取证：`round2-tierB-result.md` **§三十五**。
>
> ---
>
> **【以下为 §三十四 · 已成历史条目】** 🛑🛑🛑 **2026-09-17 11:45 —— ★★★ 结论：S3 路线收手回滚。不是"触发源"问题，是「唤醒通路」本身坏了**
> **触发**：用户反馈 **"又只能强制关机才正常"**（第二次 S3 实测，且 `SSDT-DeepIdle` + `SSDT-PCI0.LPCB-Wake-AOAC` 均已 `false`、工作区/ESP 哈希一致 `77d88978…`）。
> **① 本机有史以来唯一一次内核 panic**：`Kernel-2026-09-17-114214.panic` —— `NMIPI for unresponsive processor: TLB flush timeout`，backtrace 落在 `IOUSBHostFamily` / `AppleUSBXHCI` / `AppleUSBXHCIPCI` / `com.zxystd.IntelBluetoothFirmware`。`ls Kernel-*.panic | wc -l` = **1**（历史仅此一次）。
> **② ★★★ 决定性同机 A/B**：`WakeTime` 全历史 5 条 —— 前 4 条（Deep Idle，09-16~09-17）**2.617 / 2.430 / 2.436 / 2.442 s**；S3 那次 **159.336 s**（**65×**）。同一驱动的 `Kernel Client Acks`：`ApplePS2Controller(msg: SetState to 2)` 历史 4 次 **457/462/461/466 ms** → S3 **157,735 ms**（**342×**）。两个独立数字互证 ⇒ **唤醒真的花了近 160 秒**。
> **③ 上一条假设只对了一半**：唤醒原因由 `LPCB XDCI` 退成 `XDCI` ⇒ LPCB 那条 SSDT **确实有效但只是"多出来的一个"**；XDCI 原生就有 `_PRW`，仍在叫醒机器。**但 XDCI 唤醒是无辜的** —— Deep Idle 时代的唤醒原因里**同样有 `LPCB XDCI`**，那时只要 2.4 s。**⇒ §三十三 的"元凶"定性降级为"次要贡献者"。**
> **④ 方案 B 作废**：GPRW 补丁只能去掉**触发源**，改不了**坏掉的唤醒通路**（PS2 挂 157 s、SMC SMBus 11 s、framebuffer 报错、USB/BT 栈 panic）⇒ 第一次正常唤醒照样撞上。
> **⑤ 已回滚（工作区，`plutil -lint` 通过）**：`SSDT-DeepIdle.aml` 与 `SSDT-PCI0.LPCB-Wake-AOAC.aml` 双双 `Enabled=true`，Comment 追加回滚说明 ⇒ 恢复 **已知稳定态：Deep Idle / 唤醒 2.4 s / 历史连睡 12.6 h 无异常**。
> **▶️ 待用户**：同步 ESP → 重启。**之后不必再测睡眠。** 出远门直接关机。
> **⑥ 三层判据最终定分**：L1 声明层 ✅确认 / L2 选择层 ✅确认会选 / **L3 执行层 ❌确认不能用**。⇒ 本机（AOAC 固件）**不能安全使用 S3**，属 AOAC 与 legacy S3 的**结构性不兼容**（与 §二十七 的 S4 同族）。

> 🔥🔥🔥 **【§三十三 · 已降级为"次要贡献者"】** `SSDT-PCI0.LPCB-Wake-AOAC` 是 DeepIdle 的配套件，上一轮漏关。它原本的 Comment 字面写着 **`pair with DeepIdle`** ⇒ 配套件成了孤儿却仍在生效。它是 **LPCB 唯一的 `_PRW` 来源**（DSDT `Device(LPCB)` @`11574-11607` 内 `_PRW`/`_DSW` 计数均为 **0**），`_PRW` 返回 `Package{0x6D, 0x04}`；`_DSW` 被 `Arg0==0x03(S3)` 门控并写 IO `0x1800/0x1801`（FADT 实测 `PM1a_EVT_BLK=0x00001800` ⇒ `PM1_STS`，`AOEN` = `PWRBTN_STS`）。⚠️ OC-Little 官方同名文件内容是 `_PS0`/`_PS3`，本机却是 `_DSW`/`_PRW` ⇒ **同名不同物**。**最终结论见 §三十四：它有效但不是根因。**

> 🟢🟢 **2026-09-17 10:5x【§三十二】—— ★ 第一次 S3 实测：L2 切换成功（已走 S3），L3 半通（能睡、10 s 后被 USB 叫醒）**
> **★★ 两条前后对照铁证**：① `(AppleACPIPlatform) ACPI: sleep states` 由 **`S0 S3 S4 S5`**（历史 8 次记录全含 S0）变为 **`S3 S4 S5`** —— **S0ix 条目消失**；② `lastSleepType`（airportd）由 **`0x00000007`/`'Deep Idle'`** 变为 **`0x00000002`/`'Normal Sleep'`**。⇒ **macOS 睡眠态模型只剩 `S3/S4/S5`，实际走的就是 S3**（`_S4` 要写镜像而 `hibernatemode=0`、`_S5` 是关机）。⚠️ 诚实标注：**没有**出现正面标签 `Wake from S3`（因为唤醒中途断了）。
> **时间线**：`10:48:53 PMRD: phase 2`（真睡下去了）→ **`10:49:03 Wake reason: LPCB XDCI`（只睡 ~10 s 就被叫醒）** → `10:50:20 DarkWake`（`lastSleepType 0x02`、`wakereason['LPCB XDCI XHC']`）→ `10:50:28 (AppleIntelCFLGraphicsFramebuffer) [IGFB][ERROR] setAttribute called when FB0 is in a sleep state`（**显示未恢复**）→ `10:52:39` 重启（`SMC shutdown cause: 5` 软关机）。
> ⇒ **L3 判定：不是"PCH 完全不通"**（确实睡到 phase 2、且能被唤醒）**，而是"能睡、被 USB-C 立即打断、唤醒后显示未恢复"。**
> ▶️ **下一步**：① **拔掉所有 USB / Type-C 外设**（现挂着外接 `USB Optical Mouse`）再 `pmset sleepnow` → 看能否睡住 >1 min 并出现 `Wake from S3`；② **下次屏幕黑先按键盘 / 触摸板 / 电源键**（DarkWake 本就不点屏，**别当死机直接重启**）。
> ⚠️ **高度可疑对象**：`SSDT-PCI0.LPCB-Wake-AOAC.aml`（`Enabled=True`）的 `_PRW` 在 Darwin 下返回 **`0x6D, 0x04`** ⇒ **主动给 LPCB 启用了 GPE 0x6D 唤醒**，而本次唤醒源正是 **`LPCB XDCI`** ⇒ 若拔外设后仍被叫醒，可试临时关掉它（回滚一个布尔值）。

> 🟢 **2026-09-17 10:4x【§三十一】—— 重启已验证：第 1 步通过 ✅ `IOPMDeepIdleSupported` 从 `Yes` 变为"属性完全不存在"**
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
