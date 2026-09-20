# 睡眠档位调优测试记录

> 🏗️🏗️ **2026-09-20 09:1x【§七十七 · 最新】—— 用户给「BIOS 实拍（图 2）+ 一篇知乎『改注册表开 S3』文章」⇒ 拿到 **HP 自研 Setup 变量名表**（新一手证据），同时**更正我自己一处记录错误****
> **① ★ 新一手证据（D.2）**：HpSetup 模块（`171 0147`，body 1,327,374 B）里，**UTF-16 UI 文本之外还有一张 ASCII Setup 变量名表**（@1,282,343–1,288,343，~100 个标识符）。节选：`CpuPwrMgmt | ★DeepS3 | ★DeepS3Support | WakeOnUSB | ★HpModernStandbyConfigurations | ★PowerControl | MiscMobileKBCBatteryMgmt | SetupMemFlags | FactoryConfigFlags …` ⇒ **`Deep Sleep` 与 `Modern Standby` 是平级的两个命名 Setup 变量** ⇒ 「互斥」是**固件作者的设计**，不是 OS 驱动出来的现象。⇒ **"不赌"的理由升级**：不是我方配置没调对，而是**厂商按 AOAC-only 出厂**（与上游口径 *"Systems that support Modern Standby do not use S1-S3"* 完全一致）。
> **② 实拍（图 2）的解读（D.1）**：与 §七十四 **同一屏**（4 项），**无新增结构**。但做了交叉验证 —— 固件字符串池顺序 `Runtime Power Management → Extended Idle Power States → **Deep sleep(+3 个 wake 源)** → **Modern Standby** → Power Control → Battery Health Manager` 对照实拍 = **首 2 项 + 后 2 项 4/4 吻合，中间两整组完全不存在**。⇒ 关键：**HP 会把"灰掉"的项照常显示**（同固件例：`Hyperthreading … grayed out because Deep sleep is set to On`）⇒ 故 `Deep sleep`/`Modern Standby` **是"隐藏"而非"灰化"**（强推断；最终仍需 `DisplayInUI` 字段确认）。
> **③ ⚠️ 记录更正（D.4）**：我一直写的 **"OS 声明层已关过且无效"只对一半成立** —— **macOS `\_SB.LPS0` 真跑过**（转 S3 ⇒ EC 罢工）；**Windows `PlatformAoAcOverride=0` 从未设过**（hive 字节级 0 命中，正向对照通过）⇒ 那条"睡一次"的**裁决性测试至今是"未做"，不是"做过无效"**。**优先级提到最高。**
> **④ 知乎文章评估（D.3）**：属已标注的**「仅方向」**类，方法 = `PlatformAoAcOverride=0`，**是 Windows 侧开关，帮不到 macOS 睡眠**。但它的"改之前" `powercfg -a` 输出**与本机 §七十四 逐条同形** ⇒ 说明我们卡在"固件是否真给 S3"这个前提上；MS 问答区同案例结果是**"点击睡眠后无法唤醒"**（与 macOS 侧同形，先验胜率不高，但本机未测）。
> **⑤ 路径更正（D.5）**：HpSetup 真实位置 = 卷 `3 5473C07A-…` → `0 9E21FD93-…` → **LZMA 段** → Volume image → 卷 `0 A881D567-…` → `171 0147`。附录 C.1 写的「卷 `11 B73FE497…` / 模块 `151 081E`」**两处都错**。另：**`UEFIFind` 跑在原始 ROM 上会全 0 命中**（目标在 LZMA 段内）—— 今天靠正向对照才发现。
> **⑥ History.txt 四条旁证（D.6）**：01.23.00 内含 **EC 固件 34.31.00**｜HP 官方用词 **"MSC(Modern Standby)"**｜**"Battery Health Manager … by BCU"** = HP 承认 **BCU 可按设置名写入**｜24 个修订里 **S3 相关修复 = 0 条**。
> **⑦ BIOS 层找开关（§七十六 C.6 第 1 条）正式划掉** —— 用户已翻完，界面里没有。
> **下一步（重排）**：**②a** 进 Windows `reg add …PlatformAoAcOverride=0` → 重启 → **只看** `powercfg /a`（**零风险，不睡眠**；仍无 S3 ⇒ 彻底封板）→ **②b** 仅当出现 S3 才睡一次（⚠️裁决"固件不支持"vs"只有 macOS 不支持"；若 Windows 能正常 S3 ⇒ ★ 必须推翻"卡点在 EC 固件"）→ **②c** `reg delete … /f` 还原；**③a′** WMI 只读关键词扩到 `Modern Standby`/`DeepS3`/`PowerControl`。
> 完整 → `docs/sleep-tests/tier-ladder-why.md` **附录 D**
>
> 🧰🧰 **2026-09-18 18:1x【§七十六】—— 用户选 **B-β**（离线拆固件卷）⇒ **执行完毕：一半成功、一半是明确否定**
> **✅ 核心成果**：`Modern Standby` 是固件里的**正式 Setup 项**（**Enable/Disable**，且有 **en-US / da-DK / es-ES 三语 UI**）—— 它的 help 文本**自曝互斥**：*"Deep Sleep has been gray out because Modern Standby is set to On."* ⇒ 这就是固件自己写的"AOAC 开着 ⇒ Deep Sleep 不可用"。
> **❌ 明确否定**：**该固件没有 IFR**（三条判据：`UEFIExtract` section 统计 **HII=0**；全 dump 15,718 文件搜 HII 包结束指纹 `06 00 00 00 DF 00` **0 命中**；PE32 内严格 HII 包链扫描 **0 段**）⇒ **B.6 里"提 IFR 拿变量偏移"这条路本身不成立，本条划掉**。HP 是**自研 Setup 引擎**（UI 文本是裸宽字符串常量池，非 SIBT/无 string ID）。
> **⚠️ 真因纠正**：上轮"裸扫 0 命中"**不是**"大部分模块被压缩"这么简单 —— 更直接的原因是 **UI 文本以 UTF-16LE 存储，且全在压缩段内**。解包后 `Modern Standby` 立刻 **9 个文件**命中。
> **✅ 顺带交付**：含隐藏项的完整 Power 菜单字符串清单 → `docs/backups/bios-teardown-2026-09-18/hp-setup-power-strings.txt`
> **下一步（仍不建议赌）**：① BIOS 里**主动找一次 `Modern Standby`**（它紧邻 `Deep sleep`/`Runtime Power Management`，且其后紧跟分类名 `Power Control`；已知**不在** `Power Management Options` 那张实拍图里）；② 进 Windows 跑附录 A ③a 那条 WMI 只读，**搜 `Modern Standby`**（现在有准确名字了）。
> 完整 → `docs/sleep-tests/tier-ladder-why.md` **附录 C**
>
> 🧲🧲 **2026-09-18 17:2x【§七十五】—— 用户问「不能直接读固件」⇒ 分两种"读"：**① 运行时读（macOS **做不到**）／② **离线拆包（已跑通）**。结论**推翻了「HP 没做这个开关」**
> **① 运行时读不到（三条一手证据）**：`nvram -p` **0 条** `Setup`/`HII` 类变量；`DSDT.dsl` 命中 **3 处 `_WDG`**（含标准 ACPI-WMI 接口 GUID）⇒ HP 设置走 **ACPI-WMI(PNP0C14)**，消费方是 **Windows 的 `AcpiWmi.sys` + HP WMI provider**；macOS 无此栈，**OpenCore 也不能执行 ACPI 方法** ⇒ 这条路上没有绕法。
> **② 离线读已跑通（不需要 Windows / 不需要 UEFI Shell / 零硬件风险）**：HP 安全公告 HPSBHF04043 公布 `ZBook Power G7 BIOS` = **SP154814** → 下载 22.58 MB → PE overlay 内**真 CAB @331,559**（v1.3/17 files；`MSCF`@216064 是巧合）→ `bsdtar -xf`（**macOS 自带，不需要 7z**）→ **`T75_01180100.bin` 32,315,326 B**，内含 **`_FVH` × 34**（34 个固件卷）。⚠️ 包内 `History.txt`= **01.18.01**，本机 **01.24.02 ⇒ 落后 6 个修订**，结论按此打折。
> **③ ★ 关键发现（推翻了上一轮的封板理由）**：固件里**确实有 Modern Standby 配置段** —— **`HpModernStandbyConfigurations`**，且它是 **`HpCommonSetup`** 这个 Setup 变量的**子结构**（同级还有 `PlatformMiscDeviceConfigurations`/`SystemAudioDeviceConfigFlags`/`UsbPortsFactoryConfigFlags` 等）；另有 **`S3MemoryVariable`**、**`FspS3Notify`** ⇒ 固件里有 **S3 代码路径**，与 §2 的 L1（`SS3=One`）互印。⇒ **附录 A 里"③ 固件隐藏层＝无源之水""HP 根本没做这个开关"退回**；③ 升级为"**有实锤结构 + 有已知访问路径**"。
> **④ ⚠️ 方法论自曝**：本次裸扫字符串时**正向对照全部 0 命中**（连实拍图里确有的 `Runtime Power Management` 都搜不到）—— 真因是 **32 MB 镜像绝大部分模块被压缩** ⇒ **本次只把"搜到了"当证据，绝不把"没搜到"当"不存在"**。要拿完整清单必须先解那 34 个 FV（`uefi_firmware` 试解返回 `unknown`，HP 是自研多组件容器）。
> **⑤ 但"不赌"的结论不变**：仍不知道该项是否**可写**、写完是否真能关 AOAC、关了是否真能救回**已实测坏掉**的 S3。本轮只是把"未知"缩小了一圈。
> **下一步（二选一，均零风险）**：**B-α** 进 Windows 跑 §七十四 那条 WMI 查询（若表里出现该项 ⇒ 直接锁定，且可按名写入）；**B-β** 解 34 个 FV 提 `HpCommonSetup` 的 **IFR**（完全不碰 Windows，需工具链）。
> 完整 → `docs/sleep-tests/tier-ladder-why.md` **附录 B**
>
> 🧭🧭 **2026-09-18 17:0x【§七十四】—— 「关 AOAC」实测判定：`powercfg /a` 落点＝中间态（S3 **声明存在**、被策略压住）＋ ★ 找到 HP 官方**零风险只读**入口**
> **① BIOS 实拍坐实菜单层无解**：4 项（`Runtime Power Management`/`Extended Idle Power States`/`Power Control`/`Battery Health Manager`）——**无任何 `Modern Standby`/`S0ix`/`Sleep State`** ⇒ §七十三 ② 由"官网文档表"升级为**实拍**。
> **② `powercfg /a` 的关键＝同一份输出的内部对照**：S1/S2 都带「**系统固件不支持此待机状态**」，**唯独 S3 没有** ⇒ S3 不是"固件没有"，而是"**固件声明了、被 AOAC 策略压住**"。
> **③ ⇒ 修正 §七十三 两条推论**：④「两条**独立**路径、同一结果」**错** —— 撤 `LPS0`(macOS) 与 `PlatformAoAcOverride=0`(Win) 属**同一层**（OS 声明层），本来就该同结果，**推不出固件层结论**；⑥ 的二分判据（"没 S3 ⇒ 封板"）**不完整**，实测落在**中间态**。⇒ **"固件没有 S3"这个假设不成立**（第四重互印：FADT bit21 ＋ DSDT `SS3=One` ＋ macOS 撤 `LPS0` 后确实转 S3 ＋ 本次 `powercfg`）。
> **④ ★ 但 ③ 仍不该赌**：`powercfg /a` **区分不出**"救得回的 AOAC 平台（Dell 那种）"与"救不回的（本机）"—— Dell 改之前大概率也是这个输出 ⇒ 只把 ③ 从"无源之水"提到"有理论依据"，**没给出值得赌的证据**；赌注不对称**未变**。
> **⑤ ★★ 本轮最大产出＝新路径 ③a（HP 官方零风险只读）**：HP 商用机（含 **Z Workstation**）把 BIOS 设置**全部**（含 BIOS 界面不显示的隐藏项 —— `HP_BIOSSetting` vs 只含常用项的 `HP_BIOSEnumeration`）经 `root/HP/InstrumentedBIOS` WMI 暴露给 Windows，并带 `DisplayInUI`（1=显示/0=隐藏）字段 ⇒ **"固件隐藏层到底有没有 AOAC 开关"现在能用一条纯只读命令回答**（管理员 PowerShell）：
> `Get-WmiObject -Namespace root/HP/InstrumentedBIOS -Class HP_BIOSSetting | Select-Object Name,Value,DisplayInUI,IsReadOnly | Export-Csv C:\HPBIOS-all.csv -NoTypeInformation`
> **判据**：有 sleep/standby 类项（尤其 `DisplayInUI=0`）⇒ **③a 打通**，可用**按设置名写入**（**无"偏移写错"风险**）；全表搜不到 ⇒ **③ 彻底封板**（证据升级为"厂商自己的工具里也没有"）。⇒ A.5 的 ②（改注册表睡一次）**降级为"仅当 ③a 发现该项时才做"**。
> 完整 → `docs/sleep-tests/tier-ladder-why.md` **附录 A · A.6**
>
> 🔌🔌 **2026-09-18 16:4x【§七十三】（⚠️ 其中 ④「两条独立路径」与 ⑥「只报 S0 即封板」的推论已被 §七十四 修正）—— 用户「不能关闭AOAC？」⇒ 三层开关：**OS 层已关过（无效）／固件菜单层 HP 没有／固件隐藏变量层从未试且无先例****
> **① OS 声明层 = 唯一能碰的一层，且已实测关过**：撤 `\_SB.LPS0`（`SSDT-DeepIdle=false`）⇒ `IOPMDeepIdleSupported` Yes→No、系统**确实转去走 S3** ⇒ **EC 罢工**。⇒「关 AOAC」在能关的那层**关了、没用**。
> **② 固件菜单层 = HP 没有**：HP 官方《Power Management Options》全表 7 项（`Runtime Power Management`/`Extended Idle Power States`/`S5 Maximum Power Savings`/`SATA Power Management`/`Deep Sleep`/`PCI Express Power Management`/`PCIe Speed Power Policy`）**通篇无 `Modern Standby`/`S0ix`/`Sleep State`/`Low Power S0 Idle`**；唯一名字像的 `Extended Idle Power States` 官方定义是 **C-state 空闲省电**，同族 ZBook 用户实测原文 *"was indeed a dud"*。
> **③ ★ 本轮新增一手证据（Windows 分区直读）**：`/Volumes/TZBOOK/Windows/System32/config/**system**`（⚠️ **必须小写**，大写 `SYSTEM` 会 `No such file` —— 这就是当初"读注册表失败"的真因）字节级检索：`PlatformAoAcOverride` **0 命中**（= 本机 Windows **从未设置过**；正向对照 `HiberbootEnabled`/`PowerSettings` 均命中 ⇒ 方法有效）；命中 `ConnectedStandbyPlatform`/`StandbyActivationEnergy`/`*ModernStandbyWoLMagicPacket` ⇒ **Windows 确实跑 Modern Standby**，与 **FADT bit21 AOAC=1** + **`SleepStudy/`（今天 14:05 仍在写）** 三重独立互印。
> **④ ★ 上游同形先例（微软侧）**：MS 问答区《WIN11 修改注册表为S3睡眠模式后无法唤醒》—— 用户 `PlatformAoAcOverride=0` 关现代待机后 **"点击睡眠后无法唤醒"**；答复原文 *"**S0 低电量待机是硬件级功能，它和 S3 不可共存**，除非厂商提供开关"*；MS 文档口径 *"Systems that support Modern Standby do not use S1-S3"*。⇒ 与 macOS 侧"只能强制关机"**同形**（两条独立路径、同一结果）。⚠️ 分级：MS 问答区=方向强；那批"改注册表就能切 S3"的博客=**仅方向**。
> **⑤ 赌注不对称（不建议赌的理由）**：代价 = 放弃**唯一可用**的 Deep Idle；目标 = **已实测坏的** S3；赌输 = **两头空**。上游把「禁止 S3」列为 AOAC 平台**标准解** ⇒ 我们现状**就是**标准解。
> **⑥ 建议零风险探底**：Windows 管理员 CMD `powercfg /a` —— 出现 `Standby (S3)` ⇒ 固件给了、才值得谈；只报 `S0 Low Power Idle` ⇒ **彻底封板**。完整 → `docs/sleep-tests/tier-ladder-why.md` **附录 A**。
>
> ---
>
> 🪜🪜 **2026-09-18 16:2x【§七十二】—— 用户「为什么只能 deep idle？不能更进一档？」⇒ 一页纸固化：**声明层 ✅ / 选择层 ✅ / 执行层 ❌，卡点 = EC 固件（非 OpenCore 变量）****
> **① 前两层都通（本轮一手直读）**：`docs/SysReport/ACPI/FACP-1.aml` `FLAGS@0x70 = A5 84 23 00` ⇒ **`LOW_POWER_S0_IDLE_CAPABLE`(bit21)=1**（平台自报 AOAC）+ `HW_REDUCED_ACPI`(bit20)=0（**完整 ACPI 与 AOAC 并存** ⇒ 这正是 `_S3` 还在菜单上的原因）；`DSDT.dsl:38257` `If (SS3) Name (_S3, …)` / `:38268` `If (SS4) Name (_S4, …)` + `:5708-5709` `SS3=One`/`SS4=One` + `:31312` `Local0 |= (SS3 << 0x03)`（固件**主动上报** OS）⇒ **"固件没实现 S3"是错的**。选择层：`SSDT-DeepIdle.dsl` 全文仅 **94 B**（`_SB.LPS0` + `_GPE.LXEN`，均 `_OSI("Darwin")` 门控），且这两个名字在**原厂 DSDT 里 0 命中**（= 我们补的）；**撤掉它 `IOPMDeepIdleSupported` 就从 Yes 翻 No ⇒ macOS 真会去选 S3**。
> **② 断在 L3 执行层**：`EC OBF=1 poll timed out` = **S3 独有**（34/120 vs 噪声基线 1、Deep Idle 0/0）；`WakeTime` 2.4→**159.3 s（65×）**、PS2 457 ms→**157,735 ms（342×）**、本机历史**唯一**一次 panic。RTC 三件套被机制排除（坏的是 EC 的 I/O `0x62/0x66`，与 RTC 的 `0x70/0x71` **不相交**）。
> **③ 再深一档（S4）更远**：30 条准入条件里**唯一真·结构性缺口 = `#28` RTC 断电期保持**（固件职责）；5 次武装休眠**全在恢复侧失败**、3 次 POST 005；AOAC 家族 **0 先例**（全球跑通的 4 台**全为 Legacy S3 世代**）。
> **④ "半档"三项全排除**：`mode 3` 电气形态与 S3 同级（只是每次多写 8–16 GB 镜像）｜`standby` 的终点就是 S4（故 **`standby 0` = "不撞墙"，不是"省电没开"**）｜C-state 属 S0 内部维度（且本机 PMU 读数不可靠）。
> **⑤ 新读数（含义待确认，★ 不作判据）**：`IOPMrootDomain` 的 `SystemPowerProfileOverrideDict`（Battery/UPS/AC 三份）里 `"Hibernate Mode"=3 / "Standby Enabled"=1 / "Standby Delay"=10800`（= 3 h），与**现役生效值** `0 / No` 并存 ⇒ 疑似 macOS 为该 SMBIOS 机型准备的**模板默认**。
> **⑥ 本轮零改动零实测**（纯只读）。⚠️ 顺手再踩一次已固化坑：`grep "SS3\|SS4"` 在 BSD grep 下**静默 0 命中**（`\|` 不支持），必须 `grep -E`。完整 → **`docs/sleep-tests/tier-ladder-why.md`**。
>
> ---
>
> 🧪🧪 **2026-09-18 16:2x【§七十一】—— 用户「回到主线：优化睡眠功耗」⇒ 复核后定调：配置层已无牌，缺的是"真值" ⇒ 交付测量工具 + 三臂协议（**零配置改动**）**
> **① 配置层复核（16:1x 实读）**：`pmset -g custom` 里 `powernap/tcpkeepalive/womp/proximitywake/standby/hibernatemode/networkoversleep` **全部已在省电侧**，`lowpowermode` 电池=1；⇒ **没有"把某开关改一下就能省电"的项了**。
> **② 唤醒源普查（全量日志 / 17 段睡眠）**：10 次唤醒事件**全部用户触发**（`PWRB/UserActivity` ×5、`LPCB XDCI/Lid Open` ×2、`PWRB/Lid Open` ×1、`XDCI/UserActivity` ×1），**非用户唤醒 = 0**；10 段里 9 段 DarkWake = 0，唯一 1 段（`09-17 11:29:41`，`DarkWake from Normal Sleep` + `WakeTime 159.3 s`）落在**当天 S3 实测窗口**内 ⇒ 与既有 S3 结论自洽，**非新问题**。
> **③ 一个只写观测不写成因的发现**：昨夜 11.0 h 连睡的 `Wake Requests` 里被选中项是 `*powerd request=CSPNEvaluation wakeAt=23:52:20`，但**日志里 23:52 没有任何 DarkWake**；今天 `pmset -g sched` 也挂着 3 条 `user-invisible` 计划唤醒 ⇒ 观测层面 **RTC 计划唤醒在本机没真把机器叫起来**（对功耗是好事）。
> **④ 为什么还要测**：现有唯一本机实测 round3（50 min）有两个缺陷 —— **(a) 样本短**：前 ~10 min 是维护期，若按"10 min@20 W + 40 min@4 W"算出的平均正是 7.2 W，**与实测逐位吻合** ⇒ 11.2 %/h 很可能是瞬态均值，**稳态可能只有 ~4 W(≈5–6 %/h)**；**(b) 两口径矛盾**：同一次睡眠 `pmset Charge: 100→95%`(6 %/h) vs `ioreg mAh 520/5536`(11.2 %/h)，**差近 2×** ⇒ 真值应表述为 **6–11 %/h（≈4–7.5 W）区间**。
> **⑤ 交付**：`tools/sleep-power-measure.sh`（`status` / `arm <标签>` / `report [--save]`）—— 自动出「时长 / 睡眠形态 / 唤醒原因 / DarkWake 数 / WakeTime / ΔmAh→%/h→W」，**并列 ioreg 与 pmset 双口径**，带 AC 守卫（AC 段直接标"数字无物理意义"）。数据落 `docs/sleep-tests/power-samples/arms.jsonl`。
> **⑥ 三臂协议**：**A（必做）** 拔 AC + ≥4 h 裸机 + WiFi/BT 开 → 分离瞬态/稳态（判据：稳态 ≤6 %/h ⇒ 收手）；**B（可选·仅诊断）** 同 A 但关 WiFi/BT → 给已否决的大杠杆标价，**不作为策略采纳**；**C（可选）** 接 HDMI 外屏 + USB 鼠标睡 → 定价 desk 场景外设杠杆。⚠️ **不用 `pmset schedule wake`**（RTC 写 → HP POST 005 风险）。
> **⑦ 杠杆账（收口）**：S4 已判死｜Wi-Fi/BT 已否决｜外设未测｜ASPM 已撞墙｜配置层无牌｜唤醒源已归零 ⇒ **可改项用尽，剩下只有"量准"**。完整记录 → `docs/sleep-tests/round4-power-measurement.md`。
>
> ---
>
> ✅✅ **2026-09-18 11:3x【§七十】—— 用户答「关」⇒ A-1 续：关闭 `/Volumes/Common` 的索引（**工作区所在盘**，用户明确要求）**
> **已执行**：`mdutil -i off /Volumes/Common` ⇒ `.Spotlight-V100` **298 M → 512 K**、`mdutil -s` = disabled、卷可用空间 **112 → 113 Gi**、`mdfind -onlyin /Volumes/Common` **已搜不到**（直接路径 / git / IDE 搜索不受影响）。卷 = `disk0s5` ExFAT / UUID `C132AD3D-…`。
> **⚠️ 本次刻意不做「卸载 → 重挂」验证**：`/Volumes/Common` 就是**工作区所在盘**，而本轮已实测 **`diskutil mount` 需 root、裸跑会失败** ⇒ 一旦卸载后挂不回来，工作区当场不可用 ⇒ **风险不对等，主动降级为"只读核对 + 重启后复核"**（已列入待办）。
> **★ 机制查证，并更正我上一轮的错误推断**：禁用状态**不在**被改卷的 `VolumeConfiguration.plist` 里（两个卷关闭后 `Options` 仍 `Default`、`Stores` 记录仍在，只改 mtime 与 `ConfigurationModificationVersion`）。我上轮据此推断"记在 `/System/Volumes/Data/.Spotlight-V100/`（按卷 UUID）"，随之实测 **grep 两个 UUID 均 NO_MATCH**，而 `/var/db/Spotlight`、`/var/db/Spotlight-V100` **即使 root 也 `Permission denied`**（系统保护）⇒ **存储位置未查明，就写"未查明"**。判据只写实证两条：**ESP 经"卸载→重挂"仍 disabled** ＋ **长期 disabled 的 NTFS 卷根本没有 `.Spotlight-V100` 目录** ⇒ **跨挂载持久、不依赖卷上文件**。
> **回滚**：`sudo mdutil -i on /Volumes/Common`。完整记录 → `docs/system-overhead-audit.md` **§9**。
>
> ---
>
> ✅✅ **2026-09-18 11:2x【§六十九】—— 用户答「A」⇒ 执行 A-1：关闭 ESP 的 Spotlight 索引**
> **已执行并验证**：`osascript … "mdutil -i off /Volumes/ESP" with administrator privileges` ⇒ `.Spotlight-V100` **4.1 M → 20 K**（`Store-V2` 被清空）、`mdutil -s` = **disabled**。**持久性验证通过**：`unmount → 重挂` 后仍 disabled、`Store-V2` 未被重建 ⇒ 是真关闭，不是"暂时不扫"；同期复核 ESP 内容与工作区 **sha256 一致**（`config.plist` / `OpenCore.efi`）、ACPI 20 / Drivers 6 / Kexts 27 全等。
> **⚠️ 两条操作要点（已入文档 §8.4）**：① **别删 `/Volumes/ESP/.Spotlight-V100`**（剩的 20 K 是 Spotlight 读**卷级配置**的锚点，删了会回落默认→重新索引）；② **`diskutil mount disk0s1` 必须提权**（裸跑报 `failed to mount … try the "readOnly" option`）⇒ 手工卸载 ESP 前先确认手上有 root 手段能挂回来，否则同步目标消失。
> **顺带订正 §2.3 的表述**：重扫的真凶**不是** `com.oc.mountesp`（`RunAtLoad=true`、无 `WatchPaths`/`KeepAlive`/`StartInterval` ⇒ 只在开机挂载一次），而是 **RealTimeSync 常驻（PID 3663/3672）** → `FreeFileSync /Volumes/Common/FreeFileSync/BatchRun.ffs_batch`（`Delay: 3`）。同步范围实读 = `EFI/oc → /Volumes/ESP/EFI/oc`，**不含 ESP 根**。
> **回滚**：`sudo mdutil -i on /Volumes/ESP`。**`/Volumes/Common`（298 MB）保持 enabled 未动**；常驻软件重叠（B 组）未动。完整记录 → `docs/system-overhead-audit.md` **§8**。
>
> ---
>
> 📊📊 **2026-09-18 09:2x【§六十八】—— 用户问「还有优化的空间吗？」⇒ **换维度**：睡眠档位确实到头了，但**日常系统开销 + 内存**两处有实打实的空间，且此前六轮从没查过 → `docs/system-overhead-audit.md`**
> **① 常驻**：第三方系统服务 **22 个** + LaunchAgents **15 个**；**功能重叠成对存在** —— 远程控制 **ToDesk(3 进程) + 向日葵 awesun(2)**、清理工具 **腾讯柠檬(3) + CleanMyMac5**。**② `/Volumes/ESP` 被 Spotlight 索引＝纯浪费**（铁证 `.Spotlight-V100` 4.1 MB、`mdutil -as` = enabled）：`com.oc.mountesp` 让它常挂载而它又是 FreeFileSync 镜像目标 ⇒ **每轮同步都触发重扫** ⇒ 修法 `sudo mdutil -i off /Volumes/ESP`。**③ 内存 16 GB 已吃紧**：`swap used 1426/2048 M = 70%`、free ≈136 MB、压缩页 626 万、wired 4.2 GB（⚠️ 开机 17 min 读数，待连续采样）；**HP 官方 QuickSpecs 明写 2×DDR4 SODIMM / 客户可更换 / 上限 64 GB** ⇒ `system_profiler` 的 `Upgradeable Memory: No` **是 OC 注入的假字段**。**④ CPU 告警锚点**：`WindowServer`(21:33) 与 `apfsd`(21:40) 于 09-17 **各触发一次 50% CPU × 180 s 超限**（`ThermalPressure -> 0`，非热问题）。**⑤ 不可动**：Sangfor 全家桶 10+ 进程，含 **`endpoint_security` 系统扩展**（公司软件）。
> **顺带更正两处过期记录**：boot-args 里的 **`-wegnoegpu` 已移除**（`ebf6d5c` 09-17 17:29 连同 aspm 注入一并删，改由 `SSDT-dGPU-PowerOff-Darwin.aml` 调 `PEGP._OFF` 断电）｜**`rtcfx_exclude` 实为 `0E-FF`**（非旧记的 `80-FF`，`config` 与 `nvram` 两边一致）。
>
> ---
>
> 🏁🏁 **2026-09-18 08:5x【§六十七】—— 用户问「结论呢」⇒ 给出 S4 整条线最终结论 = **不追（收手）****
> **三条腿全断**：**先例**（同机型报告只到 "Sleep"＝我们已有的 Deep Idle，全文零字提 S4；同代 `HPZBook-Fury-G7-Hackintosh` 跑 macOS 26 也只有 "Sleep/wake ✅" 靠 `igfxonln=1`，无 hibernation；**AOAC 家族 0 先例**；全球跑通 S4 的仅 4 台 —— T530 / Fujitsu Q958 / X250 / Yoga Duet 7 13IML05，**全为 Legacy S3 世代**。Dortania 原文 *"avoid the black magic that is S4"*）｜**配方**（唯一公开配方 T530 三件套对本机 **0/3 适用**）｜**机制**（真·没法满足仅 `#28` 一条，全在固件侧；唯一开口"刷 BIOS"已被 §六十六 的本机读数关掉）。
> **剩余唯一未做实测 = B-1（`hibernatemode 3` 验写镜像），期望值判负 ⇒ 建议不做**：通过也只证"镜像能写"、后面仍撞 `#28` 固件墙；不通过只把"未验证"改写成"实测否定" —— **两条都不改变结论，却要再赌一次 RTC 写入 / HP POST 005**（§二十四 已证"四层防护全开仍 005"）。除非要"证据闭合"标签，否则不值。
> **收手态＝现状零改动**：`hibernatemode 0` + `standby 0`。**新增昨夜实证**：`2026-09-17 21:51:50 → 2026-09-18 08:52:16` = **39,626 s ≈ 11.0 h 连睡、中途零唤醒**，`WakeTime 2.428 s`、`ApplePS2Controller SetState 2 = 451 ms`（对照 S3 的 **157,735 ms ⇒ 342×**）。
>
> ---
>
> 🔍🔍 **2026-09-17 21:3x【§六十六】—— 用户问「有办法读取 BIOS 给你自己分析吗？」⇒ **能，已读到** → 全清单 `bios-facts.md`**
> **★ 本机真实 BIOS = `T75 Ver. 01.24.02`，发布日期 `2026-05-11`**（⏹️ 旧文档写的 `S71` **是错的**，实际平台代码 = **`T75`**）。机型 `HP ZBook Power G7 Mobile Workstation`、SKU `10J83AV`、EC/KBC 固件 `KBC Version 34.31.00`。
> **读法（P1，零重启零风险）**：挂载 Windows 分区（只读）→ 读 `Windows/System32/config/**system**`（注意小写）hive 里 `\ControlSet001\Control\SystemInformation\BIOSVersion` / `FirmwareReleaseDate`。**交叉印证**：ESP 的 `EFI/HP/DEVFW/Firmware.BIN`（31.2 MB）头 `0x04d760` 处 `54 37 35`(="T75") + `ea 07 05 00 0b 00`(=`2026-05-11`) **与注册表日期逐位吻合** ⇒ 该文件就是当前 BIOS 镜像。
> **✗ 已证伪的四条路**：① macOS `system_profiler`/`ioreg` 的 SMBIOS（OC `UpdateSMBIOSMode=Custom` 换成 **Acidanthera 默认值**，`AppleSMBIOS` 的 `SMBIOS` 属性 Type 0 vendor 串就是 **"Acidanthera"**）｜② `nvram -p` 找 HP/Setup 变量（**只有 10 键、零个 HP/Setup** ⇒ macOS 侧看不到真实 UEFI 变量空间）｜③ ACPI 表头（DSDT `OEMID = 87EC` **正是 OC `NormalizeHeaders` 签名** ⇒ 已被洗掉）｜④ 从 `Firmware.BIN` 找明文版本号（版本号不是明文）。
> **⚠️ 这次读数改变了一个关键判断**：上一轮我说"`#28` 虽改不出来、但 HP 官方说刷 BIOS 可能解决"—— **本机 BIOS 是 2026-05-11 的 `01.24.02`，比 HP 2026-03 安全公告里的 `01.22.00`（SP161800）还新，而 S4 照旧失败** ⇒ "固件老旧导致缺陷"的假设**在本机基本不成立**，刷 BIOS 期望值**大幅下降**。（未 100% 判死：HP 驱动页有反爬、未拿到 2026-06 后列表 ⇒ "再核一次官网当前 BIOS"仍未结清。）
> **引导类型**：`setupact.log` 三条独立证据 `FirmwareType 2` + `Is UEFI` + **`Not a PCAT machine`** ⇒ **UEFI 引导、无 legacy PCAT 支持** ⇒ `#4`（UEFI-only + CSM disabled）**极可能已满足**（但 `CSM` 本身仍读不到 —— 唯一路径是 **UEFI Shell `dmpstore -all`**）。
> **附带发现**：`ESP/EFI/HP/DEVFW/` 有 6 个固件文件（`Firmware.BIN` 31.2MB / `MePending.bin` 10.3MB / **`TBT.BIN` 408KB** / `Camera.bin` / `ClickPad.bin` / `CCG5C.bin`）。⚠️ `TBT.BIN` 与"本机无 Thunderbolt 控制器（ioreg 零节点）"有张力 ⇒ **线索，非结论**（固件包按机型族打包，不等于本机装了 TB 硬件）。
>
> ---
>
> 🎯🎯 **2026-09-17 21:3x【§六十五】—— 用户追问「是暂时没满足还是没法满足？」⇒ 重核时间线与证据，`#27`/`#30` 两处判定不成立，账目修正**
> **一句话答**：**真正的"没法满足"只有 1 条**（`#28` RTC 在 S4 断电期保持有效），**其余 9 条全是"暂时"** —— 4 条是纯开关、2 条只是没去判、1 条是我判错、1 条未测、1 条是失败点落在恢复侧。
> **修正后账目：30 条 = 19 满足 · 2 不适用 · 5 待验证 · 5 不满足**（原"6 不满足 / 4 待验证"作废）。
> **★ 更正 ① `#30` 原判 ❌ 是方法学错误** —— 我用「`/var/vm` 空、VM 卷无 `sleepimage`」当"镜像写不出来"的证据，**但当时档位是 `hibernatemode 0`，而 mode 0 的语义就是"永不写镜像"** ⇒ **"看不到"是该档位的预期行为，不构成任何证据**。史实：`sleepimage` 只见过 **1 GiB**（macOS 自建、尺寸异常小）与 **16 GiB 全零**（人工 `mkfile` 造、非真镜像）两种形态，**"macOS 自己写出合格镜像"从未被专门测过** ⇒ 准确判定 = **未验证**，只有 T2 能判。⇒ **通用教训：判"某能力不满足"前先问"这个观测在当前档位下本来就是预期行为吗？"**
> **★ 更正 ② `#27` 必须拆两半** —— 五次失败形态是 **"睡下即断气"**（`Wake from` 全无、`pmset` 时长栏为空、机器确实断电）⇒ **固件执行了 S4 的断电动作（`#27a` ✅ 已实测发生）**，失败在**恢复侧（`#27b` ❌）**。原判"固件没实现 S4"说过头。
> **★ 证据基础比文档里写的窄（`git log -S` 对齐）**：`HibernationFixup` 是 09-16 **10:42:10**（`85888f6`）装入、**commit message 明写 "Will need one reboot"**，而**首次**武装休眠是 **11:16:24**（距装入仅 34 分钟）⇒ **11:16 / 12:04 / 13:11 三次的桥状态存疑**（文档里没有 10:42→11:16 的重启记录）⇒ **可判定的干净证据只有 `18:09` / `19:29` 两次**，而非原先说的"6 次全失败"（`14:39` 那次更早已被剔除：`standby 0` 致 `hibernatemode 25` 空转、根本没进休眠）。而那两次仍带 **2 个从未核过的变量**：`#4` BIOS UEFI-only/CSM、`#7` `MmioWhitelist`。
> **★ 连唯一的"没法满足"也有 HP 官方给的解法**：HP 支持文档 `ish_2843606-2359609-16` 有一节标题原文 **「退出休眠状态后，系统时钟显示的时间不正确。……更新 BIOS 应该可能会解决该问题。」** ⇒ HP 自己定性为**可由固件更新修复**；HP 对 ZBook Power G7 已更新到 **01.20.00（SP157074）**，而**本机 BIOS 版本从未核过**（macOS 侧读到的 `2094.80.5.0.0` 是 OC 注入的假 SMBIOS）。⚠️ **别与 §二十八"BIOS 路线证伪"混淆**——那指"BIOS 菜单无 `Low Power S0 Idle` 开关"，与"刷新版 BIOS 修 RTC 缺陷"是两件独立的事。⚠️ 代价：01.20.00 是安全增强版、**HP 不允许降级** ⇒ 不可逆固件写入。
> 完整分类表：`s4-requirements-audit.md` **§6**（含 6.1 两处更正 / 6.2 时间线对齐 / 6.3 最终分类 / 6.4 HP 官方解法 / 6.5 一句话答）。
>
> ---
>
> 📋📋 **2026-09-17 21:0x【§六十四】—— 用户问「S4 需要哪些条件？都确定一下，能满足吗？」⇒ 全清单落盘 → `s4-requirements-audit.md`（30 条 · 六层 · 逐条判定）**
> **结论：30 条中 18 条已满足 · 2 条不适用 · 4 条待验证 · 6 条不满足。** ⚠️ **本行数字已被 §六十五 修正为 19/2/5/5（`#27` 拆半、`#30` 改判"未验证"）**，见上。6 条不满足 = **3 条纯开关**（`hibernatemode` 0→3/25、`standby` 0→1、`HibernationFixup` 加回 `Kernel/Add`）+ **3 条结构性**（固件是否真实现 S4 断电恢复 / RTC 断电期是否保持 / 镜像能否写出）⇒ **能凑到约 90%，凑不齐的 10% 全在固件侧、改配置改不出来**。
> **★ 本轮最重要的更正**：`rtcfx_exclude` 覆盖 `0x80–0xAB` **不是"自锁"**。RTCMemoryFixup README 那句 *"you can exclude it, but **hibernation won't work**"* 只描述**没有 HibernationFixup 的原生路径**；T530 **原始回复线程**里 jozew321 原文：*"with `rtcfx_exclude=80-AB` you are **disabling the hibernation using the RTC memory that just causes a lot of trouble**. And with `HibernateMode` set to **NVRAM** you are only using NVRAM to do the hibernation, that is **way more stable than the old RTC stuff**."* ⇒ **排除 `0x80–0xAB` ≡ 关掉烂 RTC bank、key 全走 NVRAM，这是 T530 的设计**（本机 `4ceea3a` commit message 当初就是这么写的）。**本机现况 = 方式已配对、桥不在**（`HibernateMode=NVRAM` ✅ / `WriteFlash=true` ✅ / `AppleRtcRam=true` + `rtc-blacklist 0x0E–0x73` 不含休眠区 ✅ / **`HibernationFixup` 引用数 = 0 ❌**）。
> **★ 本轮新查出的 3 条前置条件（此前文档从未记过）**：① **BIOS 必须 UEFI-only + CSM disabled**（T530 原始线程明文，**本机从未核过**，零风险 6 分钟）｜② `DevirtualiseMmio=true` 且 **`MmioWhitelist` 0 条**——OC 官方 L1549-1552 明文把该 quirk 与 *"proper NVRAM **and hibernation** functionality"* 挂钩 ⇒ **待验证**（本机 `Misc/Debug/Target=0`，无日志可判）｜③ `NVRAM/WriteFlash=true` 是 `HibernationFixup` 写 NVRAM 的前提（本机已具备）。
> **★ 分层实测补充**（本轮直接读二进制/运行时，非转述）：`FACP-1.aml` `FLAGS@0x70 = 0x002384A5` ⇒ **`RTC_S4`(bit15)=1 ✅**、`HW_REDUCED_ACPI`(bit20)=0、**AOAC(bit21)=1**、`S4BIOS_F`(bit6)=0（不适用）｜`DSDT.dsl:38268-38277` `If(SS4) Name(_S4,…)` + `:5709` `SS4=One` ✅｜RAM = **16 GiB**、`Hibernate File Min` = 8 GiB、VM 卷可用 **182 GiB** ✅｜`fdesetup` = **FileVault Off** ✅｜**`/System/Volumes/VM` 无 sleepimage**（`/var/vm` 空是假象——现代 macOS 的 swapfile/sleepimage 在**独立 VM 卷 `disk1s6`**，实见 6 个 swapfile = `vm.swapusage` 的 6144 M）｜⚠️ **内存压力偏高**（swap 已用 5.1/6 GiB）⇒ 跑 B-1 前建议重启清内存。
> **⇒ 验证链**：**T1 零风险**（进 BIOS 核 UEFI/CSM/Secure Boot + A 案电源项）→ **T2 低风险**（`mode 3` 验写镜像，**5 分钟定生死**）→ T2 通了才谈 **T3**（`HibernationFixup` + `mode 25`，中高风险）→ 可选 **T4**（开 OC 日志核 MMIO）。**判死线 = T2 不过 ⇒ S4 判死**（连镜像都写不出，与配方无关）。**回滚** = `sudo pmset -c hibernatemode 0`。
>
> ---
>
> 🔬🔬 **2026-09-17 20:3x【§六十】—— 用户选「B（S4 完整配方 T3）」⇒ 按铁律先查证，结果：三件套对本机 0 条适用，原 T3 作废，改走 B-1**
> 逐条对上游一手文档查证：① `RebuildAppleMemoryMap` `True→False` = **逆推荐**（**Dortania Comet Lake 页推荐 `YES`**，其注释限定"**早期启动失败才禁用**"，本机启动正常）｜② `ReservedMemory` 照搬 T530 那一条 = **平台不符**（**Dortania 原文**：*"mainly relevant for **Sandy Bridge iGPUs** or systems with faulty memory"*；OC 官方举例 = *"第二个 256MB 被 **Intel HD 3000** 破坏"*；T530=Ivy Bridge+HD4000，本机=Comet Lake UHD630）｜③ `DiscardHibernateMap` `False→True` = **因果错位**（**OC 官方 Note 原文**限定 *"older, rare legacy hardware … **Ivy Bridge laptops with Insyde firmware**"*；**issue #48 原文**限定 *"to fix a black screen **after hibernating and waking once and then try to hibernate again**"* = **第二次休眠黑屏**，而本机**第一次就从未成功**）。
> **本机日志实证（本轮实读 `pmset -g log`）**：5 次武装休眠（09-16 `11:16:24`/`12:04:17`/`13:11:46`/`18:09:57`/`19:29:44`）**每条只有 `Entering Sleep` + `Using AC (Charge:100%)`，无 secs、无 `Wake from`、无 `Entering Hibernate`、无 `Entering Standby`**；同期 4 次普通睡眠（`10:09`/`14:39`/`19:58`/`20:13`）**全部有** `Wake from Deep Idle` + 时长 ⇒ **失败点是"写镜像/固件断电"，不是"唤醒后内存映射对不上"** ⇒ ③ 打不到靶。另：`HibernationFixup` 已在 `a3cd5f7` 移出 `Kernel/Add`（config 引用数=0）⇒ 恢复侧写端为空。
> **顺带基线**：`/var/vm/` **空**（无 sleepimage）｜`Hibernate File Min` = **8 GiB**｜★ `SystemPowerProfileOverrideDict` 显示 **AC/电池两侧机型原生 `Hibernate Mode = 3`** ⇒ 用 3 是"回默认"不是新发明｜`HibernateMode=NVRAM` ✅ / `HibernateSkipsPicker=true` ✅ / `EnableWriteUnprotector=false` ✅（后两项与 T530 配方本就一致且自洽）。
> **⇒ 改走 B-1（零重启、低风险、5 分钟）**：`sudo pmset -c hibernatemode 3` → 插电手动 `pmset sleepnow` 睡 ~30 s → 唤醒 → 查 **`ls -l /var/vm/sleepimage` 是否变 ≥8 GiB**。**通** ⇒ 才值得把 `HibernationFixup` 加回并试 mode 25（B-2，中高风险）；**不通** ⇒ S4 当场判死，省掉一次固件赌注。**回滚**：`sudo pmset -c hibernatemode 0`。**不可逆风险**：写镜像必写 RTC RAM `0x80–0xAB`，**有再次 HP POST 005 的概率**，且 §二十四 已证"RTC 四层全开仍 005" ⇒ 不指望兜住。完整见 `round2-tierB-result.md` **§六十**。
>
> **❓ 追问「同机型有先例吗？」（20:5x 补查）** —— **① 严格同机型有 1 份成功报告**：installhackintosh.com（2024-05）**HP ZBook Power G7**，`i7-10750H / 32G / UHD 630 / Quadro P620 / AX201 / ALC236 / ELAN073D` 与本机逐项对得上，`What's Working` 里含 **"Restart, Sleep and Shutdown"** —— ⚠️ **但全文零字提 hibernation / S4 / hibernatemode**，且是 Sonoma 14.4.1 + OC 1.0.0。**② GitHub 36 个 ZBook 黑苹果仓库里零个 Power G7**；同代 **`kilianbalaguer/HPZBook-Fury-G7-Hackintosh`（Fury 15 G7，macOS 26 Tahoe）** 只列 **"Sleep/wake ✅"**，睡眠修复 = **`igfxonln=1`（本机 boot-args 已有）**，**全文无 hibernation**。**③ 权威指南立场** → **Dortania《Fixing Sleep》原文**：`Misc -> Boot -> HibernateMode -> None`，*"We're gonna **avoid the black magic that is S4** for this guide"*。**④ 有 S4 成功先例的 4 台** = Lenovo T530（Ivy 2012，T3 配方唯一出处）／Fujitsu Esprimo Q958（同作者第二台，配方含 **`standby 1`：*"required for hibernation to actually work"***）／Lenovo X250（Broadwell，**每次重启报 BIOS Checksum Error 未解决**）／**Lenovo Yoga Duet 7 13IML05（Ice Lake 2020，仍在"Fixing Hibernate Mode 25"排错章节）**。
> ⇒ **"普通睡眠"有先例；"真休眠(S4)"零先例**，且**成功的 4 台没有一台是 AOAC 机型**（全是 Legacy S3 世代）⇒ 这正是 T3"0 条适用"的更深层原因。先例既不支持"赌"，也不构成判死 —— **B-1 照做，代价最低且能定向**。
>
> ---
>
> 📄 **2026-09-17 19:4x【§五十九】—— 拆解「ASPM 一动、睡醒易不稳」**（用户质问："你都说了几次了，到底什么情况"）⇒ **结论：那是我的错误归因。** `7b0ab03` message 原文＝**「fix: 回退 NVMe APST 注入项 / 移除 NVMe 设备的 `ps-max-latency-us` 注入，避免该配置导致的异常」** ⇒ 归因对象是 **`ps-max-latency-us`（NVMe APST）**，**不是 ASPM**；`pci-aspm-default` 只因同处一个设备 dict 而被**顺手注释**、次日 `04d3b60` 被**直接删除**（非恢复）。真正症状链（`e9e012e`/`04d3b60` message 原文）：**「睡眠/唤醒后 APFS 压缩页 hash mismatch → 应用 SIGBUS」**（`ps-max-latency-us=0` 想禁 APST → 出异常；改 `100000` 限深 → 稳定；与 NVMeFix README「Some SSDs misbehave when **APST** is on」「默认上限 100000 µs / 设 0 则完全禁用 APST」完全对上）。⇒ **PCIe ASPM（链路态 L0s/L1）≠ NVMe APST（控制器自主功耗态），不能互相归因**。社区对"ASPM L1 害睡醒"**只有内容农场级来源、不可当判据**。★ **通用教训：引用 commit 当判据前必读 message + 完整 diff ——「谁改的」≠「谁的锅」。** 本机真正保睡醒稳定的 `ps-max-latency-us=100000`（两块 SSD 各一条，实际生效 1 条）**完整保留、未动**。已同步更正 技能文件 3 处 + README 2 处。
>
> ---
>
> 📄 **2026-09-17 19:3x【§五十七】—— ASPM 注入审计**（答复「ASPM 现在不是全被禁用了吗？」+「确定？」）⇒ 26 条已删注入**逐条映射到 ioreg 实测**：**23 条天生无效**（15 条注在 ASPM 字段=0 的内建/私有链路设备，8 条注在不存在的设备：`1C` 深链 6 + `1D` 2）⇒ 真受影响**仅 3 条**（`PEG0`/`RP17`/`pci-bridge@1C`）；**SSD 本体在删除前那版里已无 ASPM**（⚠️ 历史更正：更早 2025-07→2026-07-09 曾被注入过，07-08 注释、07-09 删除；其省电走 NVMeFix APST，另一层机制）。**全机能做 ASPM 的 PCIe 链路只有 4 条**。⚠️ 别用「XHC 还带 `enable-l1-aspm`」反驳"全禁用"——XHC 无 PCIe 链路，该属性是装饰性的。★ 新通用验证法：**属性名回 ioreg 反查 = 注入有没有落地**（现存 8 条中 `1C/0,0` 的 `built-in`、`1D/0,0` 的 `ps-max-latency-us` 实测**惰性**）。边界：`ioreg` 只给 Capabilities、读不到 Control ⇒ 实时开关只有 **Hackintool → PCIe 页**。完整见 **`aspm-audit.md`**。
>
> ---
>
> ⚠️ **2026-09-17 17:0x【§四十八 · 更正 §四十五】—— 用户一句「有独显」推翻"无独显"结论**：本机**确有独显**；`-wegnoegpu` 只屏蔽驱动、硬件仍在，必须靠 `SSDT-dGPU-PowerOff-Darwin.aml` 调 `PEGP._OFF()` 断电。**§四十五 把它当「无独显纯 no-op」删掉是误判，已从 git 恢复（commit `0db9c05`），ACPI 回 14 张。** 正判据：`boot-args` 含 `-wegnoegpu`（**自证有独显**）+ ACPI 命名空间 `PEG0@10000→PEGP@0` 真实在线 + DSDT `Device(PEGP)`/`Method(_OFF)`。余 5 张（TPD3×2 / TB3HP×2 / OCLT-S3Fix）原 Disabled 无副作用，维持删除。
>
> ---
>
> 🧹 **2026-09-17 16:2x【§四十五】—— 用户要求「删减一下无效的acpi」⇒ 按铁律先查证再删：删 6 张（5 张已禁用 no-op/无TB + 1 张 dGPU-PowerOff，**该条已作废，见 §四十八**），保留 thunderbolt-disable（掩死 RP01 仍生效）；ACPI 表 19 → 13 张（**后被 §四十八 修正为 14 张**），plutil OK、无残留引用、git 可逆**
>
> ---

> ✅ **2026-09-17 16:0x【§四十三 · 收口】** —— 用户刚做了 §42.5「15 秒裁决实验」（15:53 合盖 → 15:58 开盖），**结果 = ③ 通路正常，推翻 §42 假说**：
> ✅ **合盖睡眠本机可用**，由 `Clamshell.app`（`whenClamshellIsClosed=sleep`，pid 2024）以**显式** `Software Sleep` 发起 ⇒ 不经 idle 路径 ⇒ **不受 WorkBuddy `NoIdleSleepAssertion` 阻挡**（§四一、§四二 两归因均作废）。
> 🔬 **铁证**：`PMRD: clamshell closed 1, disabled 0/0, desktopMode 1, ac 1` ⇒ 内核**感知到合盖**且 `clamshellSleepDisabled=0`；`darkwakelinger` 链启动；`kIOMessageSystemWillSleep[134] to pid 2024 Clamshell`；`15:58:03 Wake from Deep Idle due to Lid Open`、`WakeTime 2.406 sec`、PS2 仅 458 ms。
> 🔑 **12:14 / 13:18 两次失败 = Clamshell.app 时机性偶发**（非 EFI / 非 LID 补丁 / 非系统配置）⇒ **仍别动 `SSDT-LID-G7`**。**要合盖即睡：直接合盖（Clamshell 接管）；偶发不睡用「苹果菜单 → 睡眠」兜底。** 完整见 **§四十三**。
>
> ---
>
> 🛑 **2026-09-17 14:1x【§四十】—— 用户问「今天中午合盖了没睡眠」⇒ **不是故障**：`AppleClamshellCausesSleep=No` ⇒ 合盖不触发睡眠，叠加 AC `sleep 0` 无兜底 = **永远不睡**；文档 §八.4 早有记录**
> **① 日志实证**：`pmset -g log` 今日 `Display is turned off` **12:14:49**（合盖）→ `turned on` **12:34:21**（开盖），**中间 20 分钟零 `Sleep`/`Wake` 记录**；今日最后一条睡眠是 **11:34:32**。
> **② 直接原因**：`ioreg -r -c IOPMrootDomain` → **`AppleClamshellCausesSleep = No`**（正常 Mac 为 `Yes`）⇒ **合盖不引起睡眠**；且 AC 下 `sleep 0`（空闲计时器关）⇒ **无兜底**。`SleepDisabled=No` ⇒ 不是被 `disablesleep` 禁的。此现象 `docs/macos-sleep-power-verification.md` **§八.4** 早有记录（「合盖不直接睡，靠空闲计时器兜底」，标注"收益小，未修"）。
> **③ 成因两候选（待 10 秒实测裁决）**：**A** 外接显示器 `PHL 241B8Q` 接着 ⇒ `desktopMode 1`（clamshell）；**B** §八.4 说的"双 LID 设备 / `SSDT-LID-G7` 恒返回 1"。⚠️ **A/B 证据有张力**：历史日志 `PMRD: Clamshell closed **1**` 表明 powerd **能读到合盖** ⇒ B 的"恒返回 1"**存疑**。**裁决法**：保持外接屏接着，合盖 10 秒读 `AppleClamshellState` —— 变 `Yes` = A 成立；仍 `No` = B 成立。（旁证：`SSDT-LID-G7.aml Enabled=True`，符号表含 `Device LIDG7`/`_HID PNP0C0D`/`_LID`/`EC0.LIDS`，确为**第二只 LID 设备**；本机无 `iasl`，未反汇编。）
> **④ 好消息**：中午那 20 分钟机器跑的是 **S3 模式**，**正因合盖没触发睡眠，才没踩 S3「卡死 160 s + panic」的雷**。
> **⑤ 想合盖就睡**：**苹果菜单 → 睡眠**（推荐，当前 Deep Idle 安全）；或合盖前拔 HDMI。**不建议**动 `SSDT-LID-G7`（其存在目的可能就是防"唤醒后误判合盖又立刻睡"）。完整见 **§四十**。
>
> ---

> 🔎 **2026-09-17 14:1x【§三十九】—— 用户问「一定得拔电池测？理论可优化的不能先做？」⇒ 翻本机 git 历史：**理论项全都做过**，当前值是收敛结果；「拔电池测」对插电场景无决策价值**
> **① ★ 决定性发现（本机 git 实证，非推断）**：`ASPM 3→2` **不是空白机会** —— `92af1f5`(2025-07-01)「ASPM优化」已注 27 条 `pci-aspm-default` + `enable-l1-aspm`；`e9e012e`(2026-07-08 15:19) 加 `ps-max-latency-us` → **`7b0ab03`（同日 16:49，仅 1.5 h 后）回退**（把 `pci-aspm-default` 注释掉 + 删 `ps-max-latency-us`）→ `04d3b60`(07-09)「**限制 NVMe APST 以提升睡醒稳定**」改回。⇒ 这条线是**试过、并撞过墙**的，不是没做。（另更正 §三十八：`enable-l1-aspm`/`ps-max-latency-us` **各有明确 commit 出处**，不是"无出处遗留"。）
>
> **⛔ 归因更正（2026-09-17 拆解，见 §五十九）**：`7b0ab03` message 原文归因的是 **`ps-max-latency-us`（NVMe APST）**，**不是 ASPM** —— `pci-aspm-default` 只是同一设备 dict 里被**顺手注释**、次日 `04d3b60` 更被**直接删除**（不是恢复）。真正症状链写在 `e9e012e`/`04d3b60` message 里 = **「睡眠/唤醒后 APFS 压缩页 hash mismatch → 应用 SIGBUS」**（APST 进太深）。⇒ **"撞墙"的是 APST 深度这条线，不是 ASPM；此后不得再说"ASPM 一动、睡醒易不稳"。**
> **② 「拔电池测」正面回答**：**测了也不能优化** —— 唯一可改的「睡眠中唤醒源」实测已是 **0 次 / 12.6 h**，剩下是结构性漏电（改不动）；且插电场景下「5 W = 墙插功率 ≠ 电池掉电率」，代价只是合盖温热 ≈26 元/年 ⇒ **不必测**（要评估出差续航时再说）。**上轮把它列为「②必做」是不该提的。**
> **③ 顺手排除**：`ioreg` 全表 **无 Thunderbolt 控制器**（零节点）⇒ 「TB 漏电」嫌疑**排除**。
> **④ ★ 新纪律**：提议任何「新优化」前先 `git log -S "<键名>" --text -- EFI/OC/config.plist` 查本机有没有试过 —— 本轮正是这步翻出「已回退的失败」。**工具坑**：APFS 大小写不敏感但 **git 索引敏感** ⇒ `EFI/oc/…` 会误报「未追踪」（实际是 `EFI/OC/…`）。
> **⑤ 唯一还剩**：睡 30 秒验证 Deep Idle 醒得回来（判据 `WakeTime ≈2.4 s`、无 `AppleACPIEC` 超时）。完整见 `round2-tierB-result.md` **§三十九**。
>
> ---

> 🛑 **2026-09-17 12:5x【§三十八】—— 用户裁决「别动WiFi蓝牙」⇒ 7 条压降清单逐条实测 = 已基本用尽；同时推翻 §三十七 的两处自查（本节取代 §三十七 的 ③④）**
> **① 用户裁决**：`别动WiFi蓝牙` ⇒ §三十七 的"最大可压点 ①（睡眠前关 Wi-Fi/BT）"**作废**，不再提。
> **② ★ 7 条清单逐条实测（只读取证，非推断）**：✅ **已满足 5 条** = 禁 S3 ｜ **电源空闲管理＝本机正在跑的 `SSDT-DeepIdle` 本身**（`01-3-电源空闲管理/` 目录**唯一文件**即 `SSDT-DeepIdle.dsl`，README 正文写"***SSDT-DeepIdle*** ——电源空闲管理补丁"；§三十七 把它标成"❓待查"，是**把已经做完的事当成了漏项**）｜SSD 已是 TLC（`pci15b7,501a`）｜NVMeFix 已加载（`ioreg -d 0 -l -w0` → `"NVMeFix"=1`）｜ASPM 27 条全 `3`＝**L0s/L1 已允许**。➖ **不适用 1 条** = 关闭独显供电（`system_profiler SPDisplaysDataType` 仅 UHD 630；ioreg 无 `pci10de`/`pci1002`）。⚠️ **只剩边角 1 条** = ASPM `3→2`。❌ **被否 1 条** = 关 Wi-Fi/BT。
> **③ ★ ASPM 原文（章节 16-2《设置ASPM工作模式》，此前误记为 `01-5`；`01-5` 是"睡眠自动关闭蓝牙WIFI"）**：父设备 L0s/L1=`03000000`、**L1=`02000000`**、禁止=`00000000`；**子设备** `03010000`/`02010000`；原文示例是**父设备与子设备两条路径都注入**。⇒ 本机 `3` 意味着原文要解决的"ASPM 被禁"**根本不存在**；`3→2` 只是"禁掉 L0s"（收益不明；⚠️ "NVMe 在 L1 掉盘"**仅内容农场级来源、不可当判据**）⇒ **默认不动**。
> **④ ★ 定位纠错（省掉 Hackintool）**：`ioreg -t -c IOPCIDevice -w0` 的 **`"acpi-path"` 属性**可把 PCI 地址反查成 ACPI 名 —— `RP17@1b0000` + `RP17@1b0000/PXSX@0` ⇒ **SSD 在 `PciRoot(0x0)/Pci(0x1B,0x0)`**（§三十七"`0x1B`/`0x1D` 都带 `ps-max-latency-us`、不睡眠无法区分"的僵局由此解开）。`Pci(0x14,0x3)` = CNVi 网卡（原文点名可改，**已被用户否决**）。
> **⑤ ★ 推翻 §三十七 的"顺带可压小项"**：`pmset -g custom` 实测 **`powernap 0`／`tcpkeepalive 0`／`womp 0`／`proximitywake 0`／`standby 0`／`hibernatemode 0`／电池 `lowpowermode 1` = 已是全机最省态**；**09-16 20:13 → 09-17 08:52 连睡 12.6 h、中间唤醒 0 次** ⇒ `calaccessd.travelEngine` 那两条定时唤醒**不值得动**（§三十七 把它列为"可压项"，是**没先数一次唤醒次数**）。
> **⑥ 本轮唯一新发现的漏电点**：`pid 666 = /Applications/WorkBuddy.app/Contents/MacOS/Electron` 持 `NoIdleSleepAssertion`（>1 h）⇒ 电池下挡住"空闲自动睡眠"（**不影响合盖/手动睡眠**；AC 下 `sleep 0` 本来也不空闲睡）。
> **⑦ 结论（可对外收口）**：不动 Wi-Fi/BT ⇒ **Deep Idle ≈5 W ≈7%/h 就是本机地板**；剩下的只有"**纯电池基线测量**"这一步（先量再谈改）。完整见 `round2-tierB-result.md` **§三十八**。
>
> ---
>
> 🚀 **2026-09-17 12:4x【§三十七 · 其 ③④ 已被 §三十八 修正】—— 用户追问「Deep Idle 的功耗可以压吗？」⇒ 能压；社区有一整节 7 条压降清单，我上轮又一次漏读了它**
> **① ★★★ 决定性原文**：OC-Little《01-关于AOAC》→ **「AOAC解决方案」**（就在我上轮引用的"AOAC 和 S3 相矛盾"**下面一节**）：*"禁止 S3 睡眠 / 关闭独显的供电电源 / 电源空闲管理 / 选择品质较好的 SSD：SLC>MLC>TLC>QLC / 可能的话更新 SSD 固件 / 使用 NVMeFix.kext 开启 SSD 的 APST / **启用 ASPM（BIOS 高级选项启用ASPM、补丁启用 L1）**"* + 配套 7 条补丁（含 **`管控蓝牙WIFI`，署名 @i5 ex900 `0.66%/h` 华星 OC Dreamn**）。
> **② 三个数字定基线**：社区 **5%–10%/h**（未压降）｜本机实测 **≈7%/h（5 W）落在区间内 ⇒ 本机是"未压降基线"**｜社区压降后案例 **0.66%/h**。
> **③ ★ 本机现状（7 条逐条实测）**：✅ 已做 = 禁 S3（§三十四回滚）/ NVMeFix 1.1.4 已启用；➖ 不适用 = 无独显、SSD 是 TLC（换不了）；❓ 待查 = 电源空闲管理、SSD 固件；⚠️ **可压 = ASPM：27 条 `DeviceProperties` 全是 `pci-aspm-default = 3`（= L0s/L1），社区推荐 L1（= 2）**；❌ **最大可压点 = 睡眠关 BT/WiFi（未做）**。
> **④ 三个可压点（收益/风险排序）**：① **睡眠前关 Wi-Fi（+蓝牙）** —— 依据 `01-6` + **0.66%/h** 署名案例，**收益高、风险零**（用户态脚本）｜② **ASPM `3→2`（纯 L1）** —— 依据 `01-5` 原文点名"**无线网卡、SSD**"，收益中、**风险中**（NVMe 有掉盘先例，原文自承"异常请恢复"；且 `Pci(0x1B,0x0)` 与 `Pci(0x1D,0x0)` 两个候选路径**不睡眠无法区分**，须先用 Hackintool 确认）｜③ 清理定时唤醒（实测 `calaccessd.travelEngine` 2 条）+ 拔外接鼠标，收益低、风险零。
> **⑤ 诚实边界**：0.66%/h 是**别人机器**的数字，HP 本机无先例；"5 W 里多少是平台结构性压不动的"**必须实测一次睡眠掉电率才有数**。判据仍用**同机前后对照**。完整见 `round2-tierB-result.md` **§三十七**。
> **⑥ 顺带更正**：记忆/技能里"**Tahoe 上 AirportItlwm 不工作**"**已过期** —— 本轮实测 `en1` 正常、`IO80211 Family 12.0`、`Wake On Wireless: Supported`，**Wi-Fi 是原生接口且工作正常**。
>
> 📚📚 **2026-09-17 12:3x【§三十六】—— 用户追问「全部只能测试？变量太多？不确定的点先在社区确认过吗？」⇒ 去社区查证，一查就命中全部结论**
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
