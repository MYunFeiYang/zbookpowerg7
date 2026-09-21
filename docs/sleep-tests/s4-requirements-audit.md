# S4（真休眠）准入条件全清单 · 逐条判定

> **时间**：2026-09-17 21:0x｜**性质**：只读取证，EFI/pmset **零改动**
> **触发**：用户问「S4 需要哪些条件呢？都确定一下，能满足吗？」
> **依据分级**：`可当判据` = OC 官方 `Configuration.tex`（acidanthera/OpenCorePkg master 原文）／RTCMemoryFixup 官方 README／HibernationFixup 官方 README／5T33Z0 Lenovo-T530 issue #48 **原始回复线程**／本机二进制与运行时实测；`仅方向` = 单篇博客。

---

## 0. 一句话结论

> ⚠️ **本节已于 2026-09-17 21:3x 修正**（用户追问「是暂时没满足还是没法满足？」⇒ 重核时间线与证据后，§1 的 #27 / #30 两处判定不成立）。**修正后的账在 §6。**
>
> ⚠️⚠️ **2026-09-20 15:3x 二次修正** —— §7.7 的 Q1 得到答复（**用户一手：Windows/Linux 休眠都正常，问题只在 macOS/OpenCore 侧**）⇒ **#27 / #28 / #29 三条从「❌ 不满足 / ⚠️ 未测」改判为「✅ 平台级已证成」**（跨 OS 对照，详见 **§7.8**）。
> **⇒ 「结构性不满足」这一档目前为空；失败点收敛到 macOS 侧的「睡眠 → 休眠」换档。**

**30 条准入条件（2026-09-20 15:3x 重算）：21 条已满足 · 2 条对本机不适用 · 4 条待验证 · 3 条不满足。**
（原始口径为 19 / 2 / 5 / 5。）原「5 条不满足」里的两条结构性项（#27、#28）已改判为 ✅。

- 3 条不满足里：**#17 / #18 是纯开关**（`hibernatemode`、`standby`）；**#12 `HibernationFixup` 未在 `Kernel/Add`** —— 但它**已被实测排除为主因**（§7.8d 台账：2026-09-16 桥在场时同样失败）。
- **结构性不满足 = 0 条。** ⇒ 本机 macOS 休眠的问题**不再是"某个条件永远凑不齐"，而是"凑齐了也过不去某一层"**（该层在 macOS 侧，见 §7.8）。

⇒ **"条件能不能凑齐" = 能凑齐**（结构性障碍归零）；**但 2026-09-16 的实测已证：条件凑齐（桥在场）仍失败** ⇒ **瓶颈不在清单的满足率上，而在 macOS 侧的换档那一层**（§7.8）。**⇒ 结论从"条件凑不齐"改为"条件不是瓶颈"，行动仍然是"不改"。**

---

## 1. 全清单（30 条 · 六层）

### L0 · 固件 / ACPI 声明层

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 1 | FADT `RTC_S4`(bit15) = 1（RTC 可从 S4 唤醒） | ACPI 规范 | **直接解 `docs/SysReport/ACPI/FACP-1.aml`**：`FLAGS@0x70 = 0x002384A5` ⇒ bit15 = **1** | ✅ |
| 2 | DSDT 有 `_S4` 对象 且 由 `SS4` 门控为真 | ACPI 规范 | `DSDT.dsl:38268-38277` `If (SS4) Name(_S4, Package(){0x06,0,0,0})`；`DSDT.dsl:5709` `Name(SS4, One)` | ✅ |
| 3 | FADT `S4BIOS_F`(bit6) | ACPI 规范 | bit6 = **0**（`S4BIOS_REQ@0x35 = 0xF1` 有值但能力位关） | ⚪ 不适用（`S4BIOS` 与 `RTC_S4` 是两套机制；休眠唤醒走 RTC，不走 S4BIOS） |
| 4 | **BIOS：UEFI only + CSM disabled** | **T530 原始线程明文**：*"the bios mode needs to be set to UEFI only, CSM disabled for hibernation to work"*（jozews321） | **从未进 BIOS 核过** | ⚠️ **未核** |

### L1 · OpenCore 引导层

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 5 | `Misc/Boot/HibernateMode` = `NVRAM` / `Auto` | OC 官方 §HibernateMode | `NVRAM` | ✅ |
| 6 | `Booter/Quirks/AllowRelocationBlock` = false | OC 官方 L1498：*"**Hibernation is not supported** when booting with a relocation block"* | `false` | ✅ |
| 7 | `DevirtualiseMmio` 不得吞掉 NVRAM/休眠所需 MMIO；如该固件需要，必须配 `MmioWhitelist` | OC 官方 L1549-1552：*"On certain firmware, a list of addresses that need **virtual addresses for proper NVRAM and hibernation functionality** may be required. Use the `MmioWhitelist` section for this."* | `DevirtualiseMmio = true`，`MmioWhitelist` **0 条**；且 `Misc/Debug/Target = 0` ⇒ **无 OC 日志可判** | ⚠️ **未验证** |
| 8 | `Booter/Quirks/DiscardHibernateMap` | OC 官方 L1595-1597 Note 限定：*"**older, rare legacy hardware** … **Ivy Bridge laptops with Insyde firmware** such as the Acer V3-571G"* | `false` | ✅ 对本平台正确（不该抄 True） |
| 9 | `Booter/Quirks/RebuildAppleMemoryMap` | Dortania《Comet Lake》推荐 `YES` | `true` | ✅ |
| 10 | `HibernateSkipsPicker` + `PollAppleHotKeys` 配套 | OC 官方 L1499：*"Highly recommended to pair this option with `PollAppleHotKeys`"* | `true` / `true` | ✅ |
| 11 | `ForceBooterSignature` | OC 官方 L1686-1689：仅用于 *"Mac EFI firmware"* 的休眠唤醒签名校验 | `false` | ⚪ 不适用（非 Mac EFI） |

### L2 · NVRAM / RTC 协议层 ★ 本轮新查清的一层

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 12 | **`HibernationFixup.kext` 必须加载**（把 `IOHibernateRTCVariables` 从 registry 写进 NVRAM，让 `boot.efi` 能读到） | HibernationFixup README 原文：*"Somehow this value has to be written into RTC (or SMC) in order the boot.efi could read it. But in case if you have to limit your RTC memory to 1 bank (128 bytes), **it doesn't work** … Fortunately, **boot.efi can read key `IOHibernateRTCVariables` from NVRAM**"* | `Kexts/HibernationFixup.kext` **在**，但 `Kernel/Add` **引用数 = 0**（`a3cd5f7` 移出） | ❌ **缺失** |
| 13 | `NVRAM/WriteFlash` = true（否则写不进） | OC 官方 §WriteFlash | `true` | ✅ |
| 14 | `UEFI/ProtocolOverrides/AppleRtcRam` 开 ＋ `NVRAM/Add/4D1FDA02-…/rtc-blacklist` 覆盖 `0x80–0xAB` | OC 官方 L9062-9071：builtin 版会 *"filter out I/O attempts to certain RTC memory addresses … specified in `rtc-blacklist`"* | `AppleRtcRam = true`；**实测 `rtc-blacklist` = `<data 242B>`，逐字节展开第 1 字节 = `0x0E`、长度 242 ⇒ 覆盖 `0x0E–0xFF`（0x0E + 242 = 0x100）⇒ ★ 含休眠区** | ✅ **但理由与旧记录相反（2026-09-20 15:3x 更正）**：旧记录写"`0x0E–0x73`（不含休眠区）"是 **102 B 的过期值**。真相 = **两级都挡了休眠区**（内核 `rtcfx_exclude=0E-FF` ＋ 固件 `rtc-blacklist=0E-FF`）⇒ **RTC 路线彻底关闭，NVRAM 路线是唯一路线**（= T530 设计，但依据不是"没挡"） |
| 15 | `rtcfx_exclude` 与休眠区（`0x80–0xAB`）的关系 | 见 **§2 更正** | `rtcfx_exclude=0E-FF`（⊃ `80-AB`）+ `HibernateMode=NVRAM` | ✅ **条件式**（须与 #12 打包） |
| 16 | 无 SMC 后备时必须走 NVRAM | HibernationFixup README：*"there are no any variables in SMC/NVRAM/RTC (actually FakeSMC)"* | `AppleSmcIo = false` + `HibernateMode = NVRAM` | ✅（与 #12 同属一个包） |

### L3 · macOS / pmset 层

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 17 | `hibernatemode` = 3（验证写镜像）/ 25（真休眠） | — | **`0`** | ❌（纯开关） |
| 18 | `standby` = 1 | Q958 配方原文：*"required for hibernation to actually work"*；T530 成功机 `standby 1` | **`0`** | ❌（纯开关；仅 mode 3 要真断电时必需，mode 25 不需要，但两台成功机都开着） |
| 19 | `hibernatefile` 路径可写 | — | `/var/vm/sleepimage`（现代 macOS 实际落在独立 VM 卷 `/System/Volumes/VM`） | ✅ |
| 20 | 卷可用空间 ≥ `Hibernate File Min` | `ioreg`：`Hibernate File Min = 8589934592`（8 GiB） | VM 卷 **182 GiB 可用** | ✅ |
| 21 | `SleepDisabled` = 0 | — | `No` | ✅ |
| 22 | `DestroyFVKeyOnStandby` = No（且 FileVault 侧无坑） | — | `No`；`fdesetup status` = **FileVault is Off** | ✅ |
| 23 | 无强阻塞级电源断言 | — | 仅 `com.apple.pci.hostBridge.preventSleep`（**Level 0**，不阻断）+ USB 255 两条 | ✅ |

### L4 · 存储 / 内存层

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 24 | RAM 规模 vs 镜像尺寸可写出 | — | RAM **16 GiB**；VM 卷余量 182 GiB | ✅ |
| 25 | 内存压力可控（镜像要在干净内存上写） | — | `vm.swapusage` = **total 6144 M / used 5130 M**；`/System/Volumes/VM` 有 **6 个 swapfile**（今日 17:43→20:37 陆续生成） | ⚠️ **偏高**（不阻塞，但跑 T2 前建议重启清内存） |
| 26 | APFS / 非 RAID / 卷可写 | — | APFS 单卷，VM 卷独立挂载可写 | ✅ |

### L5 · 硬件 / 固件结构层 ← **唯一"改配置改不出来"的那一条在这里**

| # | 条件 | 依据 | 本机实测 | 判定 |
|---|---|---|---|---|
| 27 | 固件真的实现 S4 的"断电 + 冷启动恢复" | 无文档可查，**只能实测** | **6 次武装休眠全失败**，其中 **3 次触发 HP POST 005** | ❌ **→ ★ 2026-09-20 15:3x 改判：✅ 平台级已证成** —— 同机同固件 **Windows/Linux 休眠-恢复正常**（§7.8）⇒ **固件确实实现 S4**；失败在 **macOS 那一侧**。（原拆分的"27a 断电 ✅ / 27b 冷启动恢复 ❌"只描述 **macOS 尝试**的结果，不再是固件判据） |
| 28 | RTC/CMOS 在 S4 断电期间保持有效 | — | `README.md:179`：*"三层软件防护（`rtcfx_exclude=0E-FF` ＋ `AppleRtcRam=true` ＋ `rtc-blacklist` 242 B）**全开仍报 005**，本就不矛盾 —— **掉电不是"写"**"* | ❌ **HP 固件不保证** ← ★ **但 HP 官方文档说"更新 BIOS 应该可能会解决"（见 §6）** ⇒ ⚪ **→ ★ 2026-09-20 15:3x 改判：✅ 平台保证，那 3 次 005 是 macOS 自己写坏的** —— Windows 休眠周期**无 005、时钟正确** ⇒ 真正原因是 `AppleRTC` 在休眠时写 **CMOS `0x80–0xAB`（休眠密钥）＋ `0x58/0x59`（校验和）**（见 7.2），而该区域同时是 HP 放设置项与校验和的地方 ⇒ **与固件无关，是"两家抢同一块 CMOS"** |
| 29 | EC 在 S4 进出时正常 | — | 未单独测；但同一 EC 在 S3 恢复后已证 `EC OBF=1 poll timed out` 连绵 | ✅ **2026-09-20 15:3x 在 S4 场景已证成**：Windows 休眠-恢复成功 ⇒ **EC 能安然穿过 S4 断电-上电**；⚠️ 但 **S3 恢复**场景仍是坏的 ⇒ **S3 与 S4 的 EC 行为不可互推**（此前用 S3 的 EC 结论去推 S4 是越界） |
| 30 | **镜像能写出来**（S4 的第一道门） | — | ⚠️ **原判据作废（21:3x 修正）**：`/var/vm/` 空、`/System/Volumes/VM` 无 sleepimage 是在 **`hibernatemode = 0`** 下核的 —— **mode 0 本来就不写镜像，"看不到"是档位的预期行为，不构成任何证据**。史实：`sleepimage` 只见过两种形态 —— **1 GiB（macOS 自建，尺寸异常小）** 与 **16 GiB 全零（人工 `mkfile` 造的，非真镜像）**；**macOS 自己写出合格镜像的场面从未出现，但也从未被专门测过** | ⚠️ **未验证**（原判 ❌ 是方法学错误；只有 **T2（mode 3）** 能判） |

---

## 2. ★ 更正：`rtcfx_exclude` 覆盖休眠区，**不是"自锁"，而是 T530 的有意设计**

上一轮读到 RTCMemoryFixup README 那句 *"If any offset in this range causes a conflict, you can exclude it, **but hibernation won't work**"*，很容易得出"本机自己把自己锁死了"。**这个理解只对一半。** 本轮把 T530 的**原始回复线程**读全，同一线程里 jozew321 的原文是：

> *"with `rtcfx_exclude=80-AB` you are **disabling the hibernation using the RTC memory that just causes a lot of trouble**. And with `HibernateMode` set to **NVRAM** you are only using **NVRAM to do the hibernation**, that is **way more stable than the old RTC stuff**."*

⇒ 两条 README/回复合起来才是完整规则：

| 场景 | 结果 |
|---|---|
| 排除 `0x80–0xAB`，**没有** `HibernationFixup` | ❌ 休眠**必然**不工作（README 那句说的就是这个场景） |
| 排除 `0x80–0xAB`，**有** `HibernationFixup` + `HibernateMode=NVRAM` | ✅ **这是设计**——烂掉的 RTC bank 关掉，key 全走 NVRAM，比老的 RTC 那套更稳（T530 就是这么修好的） |

**本机现状**：`rtcfx_exclude=0E-FF`（⊃ `80-AB`）+ `HibernateMode = NVRAM` + `WriteFlash = true` —— **方式已经配对，唯独桥（`HibernationFixup`）不在 `Kernel/Add` 里**。

> 📌 附带一条本机设计意图的实证：`4ceea3a`（2026-09-16）commit message 原文就是 *"装 RTCMemoryFixup 1.0.7 + boot-arg `rtcfx_exclude=80-FF`（**禁写 RTC 第二 bank，休眠变量改走 NVRAM 由 HibernationFixup 顶上**）"* ⇒ 当初就是这么设计的，后来 `0E-FF` 是在 S3 防护升级时**顺手放宽的**（覆盖范围只增不减，不影响本结论）。

---

## 3. 本轮**新发现**的必要条件（此前任何文档都没记过）

1. **BIOS：UEFI only + CSM disabled** —— 来自 T530 **原始线程**（不是 T3 配方本身）。本机从未核过，**零风险 5 分钟可核**。
2. **`MmioWhitelist` 不能空着就开始赌** —— OC 官方明文把 `DevirtualiseMmio` 与"proper NVRAM **and hibernation** functionality"挂了钩。本机 `DevirtualiseMmio=true` + 白名单 0 条 + 无 OC 日志 ⇒ **可判但未判**。
3. **`NVRAM/WriteFlash = true` 是 `HibernationFixup` 能写 NVRAM 的前提**（本机 ✅ 已具备，但之前没意识到它是休眠前置条件，只当成普通 NVRAM 设置）。

---

## 4. 最小验证链（按代价排序）

| 阶段 | 做什么 | 判据 | 风险 |
|---|---|---|---|
| **T1** | 进 BIOS(F10) → Boot Options / Power Management：核 **Legacy CSM 是否关**、**UEFI Boot 是否唯一**、Secure Boot 状态、以及 A 案那几项电源项 | 拍照留证 | **零风险**，6 分钟 |
| **T2** | ~~`sudo pmset -c hibernatemode 3` → 插电 `pmset sleepnow` 睡 ~30 s → 唤醒 → 查 sleepimage 是否 ≥8 GiB~~ | ⛔ **2026-09-20 15:3x 判定 T2 设计本身有误 ⇒ 作废**：**`hibernatemode 3` 不在入睡时写镜像** —— `round1-tierA-result.md` 实测（mode 3 ＋ `standbydelay 300`、睡 338 s）：`sleepimage` mtime **未变（❌ 未执行）**。mode 3 的镜像是**进 standby 时**才写，而 `standby` 的四个前提在本机 AC ＋ 外接屏下天然不满足 ⇒ **按原设计跑必然得出"没写"，是假阴性**（详见 §7.8e-2）。**⇒ 本机已不存在"低风险的能否写镜像"判据。** | ⚠️ 原判"低"仍对，但**跑不出结论** | ⛔ **作废，不要跑** |
| **T3** | ★ **16:3x 改判（见 §7.10c）**：`HibernationFixup` 加回 `Kernel/Add` ＋ **`hbfx-ahbm=1`**（"**hibernate instead of regular sleep**" ⇒ 绕开常规睡眠那一步）＋ 保留 `rtcfx_exclude=0E-FF` | `Entering Hibernate` 出现 + 能醒回来 | **中**（休眠密钥改走 NVRAM ⇒ 理论上避开 CMOS `0x80–0xAB`）｜⚠️ 旧文写的"`mode 25`"是**旧方案**，且 **`ahbm` 从未测过** |
| **T4**（可选） | `Misc/Debug/Target=0x43` 开一次 OC 日志，核 MMIO 有没有被 devirtualise | 日志里 `Devirtualised MMIO regions` 列表 | 低（需同步 ESP + 重启） |

**判死线**：**T2 不过 ⇒ S4 直接判死**。连镜像都写不出来，说明卡在固件/OS 边界，与"配方抄没抄对"无关，T3 不必赌。

**回滚点**：`sudo pmset -c hibernatemode 0`（一条命令回到现役 Deep Idle）。T3 的 EFI 改动 git 可逆。

---

## 5. 结论

| 问题 | 答复 |
|---|---|
| S4 需要哪些条件？ | 30 条，分 6 层（固件声明 / OpenCore / NVRAM-RTC / pmset / 存储 / 硬件结构），已在上表逐条列出并给出上游原文依据 |
| 都确定了吗？ | **24 条已定**（18 满足 + 2 不适用 + 4 明确"未验证"并写明怎么验）；**6 条不满足已定性**，其中 3 条是纯开关、3 条是结构性的 |
| 能满足吗？ | **开关那 3 条 + 待验证那 4 条都能处理；结构性那 3 条（#27/#28/#30）改配置改不出来** —— 它们取决于 HP 固件是否真的实现 S4 断电恢复、以及 RTC 在断电期能否保持。**6 次实测已经在说"不能"。** |

⇒ **建议顺序**：先 T1（零风险，还有一条从没核过的必要条件）→ 再 T2（5 分钟定生死）→ T2 通了才谈 T3。

> ⚠️ **本节末行已被 §6 取代** —— 上面"能满足吗"那一栏是 **21:0x 的判读**，21:3x 重核后已修正。

---

## 6. ★ 修正与最终分类：**"暂时"还是"没法"**（2026-09-17 21:3x）

> 触发：用户追问 **「是暂时没满足还是没法满足？」** ⇒ 回头重核时间线与证据，发现 §1 有 **2 处判定不成立**。

### 6.1 两处必须更正

**更正 ① `#30` 原判 ❌ 是方法学错误。** 我用 `/var/vm` 空、VM 卷无 `sleepimage` 当"镜像写不出来"的证据 —— 但**当时的档位是 `hibernatemode 0`，而 mode 0 的语义就是"永不写镜像"**。「看不到」是**该档位的预期行为**，不构成任何证据。

> 📌 通用教训：**判"某能力不满足"前先问一句 —— 这个观测在当前档位下，本来就是预期行为吗？** 拿"当前配置的正常产物"去证明"能力缺失"，是**把档位差异当成硬件缺失**。
> 史实（`round2-tierB-result.md` §七/§十二）：`sleepimage` 只见过 **1 GiB**（macOS 自建、尺寸异常小）与 **16 GiB 全零**（人工 `mkfile` 造的，非真镜像）两种形态。**"macOS 自己写出合格镜像"从未被专门测过** ⇒ 准确判定 = **未验证**，只有 **T2（mode 3）** 能判。

**更正 ② `#27` 必须拆两半，原判"固件没实现 S4"说过头。** 五次失败的形态是**"睡下即断气"** —— `Wake from` 全无、`pmset` 时长栏为空、机器确实断电了。⇒ **固件执行了 S4 的断电动作（27a ✅）**，失败在**恢复侧（27b ❌）**。这两件事的后续含义完全不同：前者判死，后者是"恢复链上有环节不通"。

### 6.2 ★ 证据基础比文档里写的要窄

`git log -S "HibernationFixup" -- EFI/OC/config.plist` 给出的时间线：

| 时刻 | 事件 |
|---|---|
| 09-16 **10:42:10** | `85888f6` 装入 `HibernationFixup 1.5.4`，commit message 明写 **"Will need one reboot"** |
| 09-16 **11:16:24** | **首次**武装休眠失败 ← 距装入仅 **34 分钟** |
| 09-16 12:04 / 13:11 | 第 2、3 次失败 |
| 09-16 13:39 | `4ceea3a` 才装 `RTCMemoryFixup` |
| 09-16 **18:09 / 19:29** | 第 4、5 次武装休眠失败（**确定在桥到位之后**：中间已多次冷启动；且 `standby 1` 在位） |
| 09-17 **16:44** | `a3cd5f7` 把它移出 `Kernel/Add` ⇒ 现在引用数 = 0 |

⚠️ **11:16 / 12:04 / 13:11 这三次，`HibernationFixup` 是否已生效存疑** —— 文档里**没有** 10:42→11:16 之间的重启记录，而它必须重启才加载。
⇒ **可用于判定的干净证据只有 `18:09` / `19:29` 两次**（不是文档原先写的"6 次全失败"）。
⇒ 而那两次仍带着 **2 个从未核过的变量**：`#4`（BIOS 是否 UEFI-only + CSM disabled）、`#7`（`MmioWhitelist` 是否为 0 条就够）。

> 📌 通用教训：**引用"N 次实测全失败"当判据前，先按 `git log -S <键>` 对齐每次测试时的配置是否真的齐备** —— 缺桥、缺计时器、档位没生效的测试，是**无效测试**，不能计入"N 次"。
> 本次连"6 次"这个数本身都要打折：`14:39` 那次（§二十二）是 **`standby 0` 导致 `hibernatemode 25` 空转**，根本没进休眠 ⇒ 早在 09-17 就被剔除；真正武装休眠的是 **5 次**。

### 6.3 最终分类表

| 类别 | 条数 | 条目 | 能不能满足 |
|---|---|---|---|
| **A. 纯开关 —— 一条命令级** | 4 | `#12` `HibernationFixup` 加回 `Kernel/Add`（+ 重启）｜`#17` `hibernatemode` 0→3/25｜`#18` `standby` 0→1｜`#25` 内存压力（重启即解） | ✅ **暂时**，随时可凑 |
| **B. 可判未判 —— 结果可能是"本就满足"** | 2 | `#4` BIOS UEFI-only + CSM disabled（**T1，零风险**）｜`#7` `MmioWhitelist`（**T4，需开 OC 日志**） | ⚠️ **暂时**，判完大概率"本就没事"，也可能"补一条就好" |
| **C. 我上轮判错** | 1 | `#30` 镜像能否写出（原判 ❌ 依据无效，见 6.1） | ⚠️ **未验证**，T2 可判 |
| **D. 未测** | 1 | `#29` EC 在 S4 进出时的行为 | ⚠️ **未测**（注意：**不能**由 S3 的结果外推 —— S4 是断电冷启动，EC 由固件重新初始化，与 S3 的"恢复后 EC 不响应"不是同一场景） |
| **E. 真正的"没法满足"** | **1** | `#28` RTC/CMOS 在 S4 断电期保持有效 | ❌ **改配置改不出来** —— 但见 6.4 |
| **F. 实测失败，但失败点在恢复** | 1 | `#27b` 冷启动恢复（`#27a` 断电 ✅ 已发生） | ❌ 失败 |

### 6.4 ★ 连唯一的"没法满足"也有 HP 官方给出的可能解法

`#28` 不是"改配置改不出来"就到底了。**HP 支持文档 `ish_2843606-2359609-16` 有一节标题原文就是：**

> **退出休眠状态后，系统时钟显示的时间不正确。**
> **在某些电脑上，系统时钟在退出休眠状态后可能停止或重置。更新 BIOS 应该可能会解决该问题。**

⇒ HP 自己把这个问题定性为**可由固件更新修复**的缺陷，并且 HP 对 ZBook Power G7 已更新到 **01.20.00（SP157074）**；而**本机 BIOS 版本从未核过**（macOS 侧读到的 `2094.80.5.0.0` 是 OpenCore 注入的假 SMBIOS，不是真实版本；真值只能 F10→Main 或 Windows `wmic bios get smbiosbiosversion`）。

⚠️ **别与 §二十八 的"BIOS 路线证伪"混淆** —— 那指的是 **"BIOS 菜单里没有 `Low Power S0 Idle` 开关"**（想关 AOAC 换 S3 的路）。**"刷新版 BIOS 修 RTC/休眠缺陷"是另一件独立的事，从未证伪。**
⚠️ 代价：01.20.00 是**安全性增强版，HP 不允许降级** ⇒ 这是一次**不可逆的固件写入**。

### 6.5 ⇒ 一句话回答用户

> **真正的"没法满足"只有 1 条**（`#28` RTC 断电期保持），**其余 9 条全是"暂时"** —— 4 条是开关、2 条只是没去判、1 条是我判错（镜像那条）、1 条未测、1 条是失败点落在恢复侧。
> **而且连那 1 条也未必是终点**：HP 官方说刷 BIOS 可能修，只是本机版本从未核过，且刷固件不可回退。

---

## 7. ★ 为什么 Windows/Linux 能休眠、macOS 不能（2026-09-20 15:2x）

> 触发：用户问「**window侧休眠是可以用的，之前安装 Linux 时也可以使用休眠，为什么之前 macOS 试过休眠就没法正常唤醒？**」
> 本轮**零配置 / 零 EFI / 零固件写入**。新增内容 = 重读既有实测 + 补两份官方原文 + 本机 DSDT 复核 + 一次现场核对。

### 7.1 前提必须先纠正：三种系统的"休眠"**不是同一种契约**

| | 镜像放哪 | 谁负责恢复 | 固件被要求做什么 |
|---|---|---|---|
| **Windows** | `hiberfil.sys`（系统卷根目录；本机现场 = **6.14 GiB**，`mtime 2026-09-20 11:47`） | **Windows Boot Manager 自己读** | 只需「关机」＋「正常冷启动」 |
| **Linux** | swap 分区 / swapfile 头 | **initramfs 的 `resume=` 钩子**（内核自己） | 同上 |
| **macOS** | `sleepimage`（VM 卷） | **`boot.efi`** —— 但它必须先**被告知「这次是从休眠镜像回来的」** | 同上 **＋ 提供"休眠状态"的交接通道** |

Microsoft 官方原文（`learn.microsoft.com/en-us/windows/win32/power/system-power-states`，**🟢 判据**）：

> *"A resume from hibernation starts with a **system POST that's similar to an S5 shutdown**. **The OS boot manager determines that a resume from hibernation is required by detecting a valid hibernation file.** Then it directs the system to resume, restoring the contents of memory and all architectural registers."*

⇒ **一句话**：Windows/Linux 的休眠是「**OS ↔ 自家引导器**」的契约，固件只是个电源开关；macOS 的休眠是「**OS ↔ 固件(BootROM)**」的契约。
⇒ 所以「**Windows 能 ⇒ macOS 也应该能**」这个推理**不成立** —— 它把两个契约当成了一个。

### 7.2 本机专属加难项 ①：macOS 被逼上"必须碰 CMOS"的那条路

本机 DSDT 实读（`docs/SysReport/ACPI/DSDT.dsl`），**互补对**：

```asl
Device (AWAC) {                                    // 9386
    Name (_HID, "ACPI000E" /* Time and Alarm Device */)
    Method (_STA) { If ((STAS == Zero)) { Return (0x0F) } Else { Return (Zero) } }   // 9396-9406
}
Device (RTC) {                                     // 29670
    Name (_HID, EisaId ("PNP0B00") /* AT Real-Time Clock */)
    Method (_STA) { If ((STAS == One)) { Return (0x0F) } Else { Return (Zero) } }    // 29684-29694
}
```

我们的 `SSDT-AWAC.aml`（73 B 全文）：`Scope (\_SB) { If (_OSI("Darwin")) { STAS = One } }`

| 系统 | `STAS` | AWAC(ACPI000E) | RTC(PNP0B00) |
|---|---|---|---|
| **macOS** | **One**（我们强制） | `_STA` → **Zero（隐藏）** | `_STA` → **0x0F（启用）** |
| **Windows** | 固件默认 ⚠️ | 0x0F（启用） | Zero（隐藏） |

⚠️ **限定**：Windows 侧的 `STAS` 默认值**未直接实测**（标 🟡）—— 我们只在 `_OSI("Darwin")` 下改它。但机制上必然落在 AWAC 侧，否则这个 SSDT 就没有存在意义。

**为什么必须这么改**（Dortania 官方《Getting Started With ACPI · Fixing System Clocks》，🟢）：

> *"macOS **does not include native support for AWAC clocks** and expects to find a legacy RTC device with Hardware ID **PNP0B00** for system time management."*

**而 macOS 的休眠密钥正好就写在 CMOS 里**（本机 `AppleRTC.kext 2.0.1` 反汇编实证，🟢）：

| 常量（`AppleRtc.h`） | 值 |
|---|---|
| `APPLE_RTC_HIBERNATION_KEY_ADDR` | **`0x80`**，LENGTH `0x2C`(44) ← `IOHibernateRTCVariables` |
| `setHibernateState(len)` | `rtcWriteBytes(data, len, **0x80**)` → 再 `updateChecksum()`（对 `0x0E–0xFF` 算，写入 `0x58/0x59`） |

⇒ **macOS 是三者里唯一"必须碰 CMOS 才能休眠"的系统；Windows 的休眠一点都不碰 CMOS。**
⇒ 而 CMOS 的 `0x80–0xFF` 恰好也是 **HP 固件自己放设置项 + 校验和**的地方 —— 这正是我们后来必须**写保护**它（`rtcfx_exclude=0E-FF` ＋ `rtc-blacklist` 242 B ＋ `AppleRtcRam`）才止住 POST 005 风暴的原因。**同一个区域，两家的东西抢着用。**

### 7.3 本机专属加难项 ②：AOAC 与 S3/S4 结构性冲突（同代同配平台的公开结论）

| 来源 | 原文 | 分级 |
|---|---|---|
| Dell Latitude 5410 EFI 仓库（i5-10310U ＋ AX201 ＋ `MacBookPro16,3`，**同代同配**） | *"The default value of **Low Power S0 Idle** is enabled, it **conflicts S3 Sleep wake up and S4 Sleep**. … by disabling Low Power S0 Idle capability by: `setup_var_cv Setup 0x14 0x1 0x0`"* | 🟢 |
| ThinkPad X1C6 `SSDT-Sleep.dsl`（tylernguyen） | *"**S0-DeepIdle has a much higher power draw on sleep as S3**"* | 🟢 |
| **本机** | `FADT FLAGS@0x70 = 0x002384A5` ⇒ **bit21 `LOW_POWER_S0_IDLE_CAPABLE` = 1** ＋ 存在 **`LPIT-1.aml`**（双证在冲突侧） | 🟢 实测 |
| **本机** | HP 把 AOAC 的**行为**做在 SMM/固件里，ACPI 侧只留**只读镜像 `S0ID`**（两处引用都是空 `if`）⇒ **不能像 Lenovo 那样用 SSDT 关掉** | 🟢 反汇编 |

⇒ **社区对"AOAC 与 S4 冲突"的标准处方就是「关掉 AOAC」（Dell 先例的 `setup_var`）—— 而那正是 HP 在固件层封死的门**（见 **附录 F/G**：`Modern Standby` 隐藏＋只读、无 IFR、无 UEFI 变量入口）。
⇒ 形成一个闭环：**唯一被验证有效的修法是关 AOAC；本机 AOAC 关不掉；所以"修好 macOS 休眠"的修法在本机不存在。**

> ⚠️ **★ 本条的适用范围已在 §7.8 缩小（2026-09-20 15:3x）**：**同一台机器**的 Windows/Linux 休眠-恢复**实测正常** ⇒ **AOAC 并没有阻断"平台级 S4"**，它压住的是 **S3／传统睡眠语义**（以及 macOS 那条"先睡一次、再转 S4"的路）。
> ⇒ 上面这个闭环**只对 macOS 的换档路径成立**；**不要**再把它当作"关掉 AOAC 就能修好休眠"的理由（那条门本来也关不上）。

### 7.4 ★ 但实测的失败点，比上面这些理由还要"早"

（必须讲清楚，否则就是拿结构理由去解释一个更早期的现象。）

5 次武装休眠的签名（`pmset -g log` 实读，🟢）：

| 观测 | 值 |
|---|---|
| `Entering Sleep state due to 'Software Sleep'` | ✅ **5/5 有** |
| `Entering Hibernate` | ❌ **0/5** |
| `Wake from` / 时长（`secs`） | ❌ **0/5**，栏目**空** |
| `kern.hibernatecount` | **`0`** ⇒ 从未完成一次休眠事务 |
| 失败后 `nvram -p \| grep -i hiber` | **空** ⇒ **`HibernationFixup` 根本没轮到执行** |
| 断电时点 | `Entering Sleep` 之后 **≈0.2 s**（最后一条日志 `19:29:44.169436`，随后连续 **3 分钟 0 行**，再冷启动） |
| `ShutdownCause` / panic | ❌ 都没有 ⇒ **不是正常关机、也不是内核崩溃** |
| HP POST 005（RTC 掉电） | **3/5**（11:16 / 18:09 / 19:29） |

⇒ **准确表述：不是"睡下去醒不回来"，是"还没走到休眠那一步就被硬切断电"。**
⇒ 日志"戛然而止"是**硬断电**的签名（软件崩溃会留 panic，或至少留下不规律的日志衰减）。

### 7.5 ★ 决定性对照：把"硬件不行"整类排除

同一天 **9 次睡眠**（`pmset -g log` 全量）：

| 档位 | 次数 | 结果 |
|---|---|---|
| **武装休眠**（`hibernatemode 25` ＋ `standby 1`） | 5（11:16 / 12:04 / 13:11 / 18:09 / 19:29） | ❌ **全失败、0 唤醒、3 次 005** |
| **普通睡眠**（Deep Idle） | 4（10:09 / 14:39 / 19:58 / 20:13） | ✅ **全正常唤醒**（含**连睡 12.6 h**，RTC 无恙、无 005、时间正确） |

且当日**所有正常关机/重启**（10:00 / 11:04 / 12:55 / 13:58 / 19:19）时钟**全对**。
⇒ **RTC 电池弱 / CMOS 被写花 / 固件普遍性问题 —— 整类排除。** **坏的只是"武装休眠"这一条路。**

➕ **现场补证（2026-09-20 15:2x）**：Windows 卷已挂载，`/Volumes/TZBOOK/hiberfil.sys` = **6,588,555,264 B（6.14 GiB）**，`mtime 2026-09-20 11:47`（= **今天**）。

- 16 GiB × 38.4% ≈ 微软文档的「**full 型 = 物理内存 40%**」⇒ **full 型、支持真休眠**（与 `powercfg /a` 说"休眠可用"一致；该页还写明 *"When a full hibernation file is used, the results state that hibernation is an available option"*）。
- ⚠️ **限定**：**Fast Startup 也写同一个文件**，所以 mtime 单独**不能**区分"真休眠"与"快速启动关机"。

### 7.6 结论 + 证据分级

| 说法 | 等级 | 判据 |
|---|---|---|
| Windows/Linux 的恢复链**不依赖固件**（自家引导器读磁盘文件） | 🟢 | Microsoft 官方 `system-power-states` 原文 |
| macOS **不支持 AWAC**，被逼回老式 CMOS RTC(PNP0B00) | 🟢 | Dortania 官方 ＋ **本机 DSDT 实读**（互补对） |
| macOS 的休眠密钥写在 **CMOS `0x80–0xAB`** | 🟢 | 本机 `AppleRTC.kext` 反汇编（`setHibernateState` → `rtcWriteBytes(...,0x80)`） |
| **AOAC 与 S3/S4 结构性冲突** | 🟢 | 同代同配先例（Dell 5410 / X1C6）＋ 本机 `FADT bit21`＋`LPIT` 双证 |
| 失败点在**休眠事务提交之前**（硬断电，非唤醒失败、非崩溃） | 🟢 | 5/5 日志签名 ＋ `hibernatecount=0` ＋ NVRAM 无变量 |
| Windows 侧实际走 AWAC | 🟡 | 机制推断（其 `STAS` 默认值未直接实测） |
| ~~"平台按 AOAC/S0ix 语义直接切电，而不执行 S4 的保存-交接流程"~~ | ⚪ **已撤回（§7.8）** | 反证：**同一台机器** Windows/Linux 休眠-恢复**正常** ⇒ 平台**会**执行 S4。原假设只是"与观测一致"，被跨 OS 对照**直接否掉** |
| RTC 电池弱 / CMOS 被写花 | ⚪ **已排除** | 7.5 的对照 |

⇒ **给用户的一句话**：
> Windows/Linux 的休眠**不向固件要任何东西**（镜像在磁盘上，自家引导器读回来），所以它们在**同一块固件**上能成；macOS 的休眠**必须经过固件**（密钥进 CMOS `0x80–0xAB`、由 `boot.efi` 读回），而这块固件是 **AOAC-only** 设计 —— 平台按"S0ix"的语义处理，直接切了电，macOS 连"进入休眠"那一步都没走到。**两者的差异不是"谁更省电 / 谁更兼容"，是"要不要跟固件握手"。**

### 7.7 还能查吗（两条，都不建议做）

| # | 动作 | 价值 | 风险 | 建议 |
|---|---|---|---|---|
| **T2** | `sudo pmset -c hibernatemode 3` → 手动 `pmset sleepnow` → 查 `sleepimage` 是否变 ≥8 GiB | 回答"macOS 到底能不能在本机写出合格镜像" | **重估为低**：按 §二十五（005 = **断电期间** RTC 掉电），**mode 3 不断电 ⇒ 不该 005**（旧记录的"高风险"是 §二十五 之前的判断） | ⚠️ **仍不建议** —— 它**不解锁任何东西**（即便镜像能写，mode 25 仍在切换点死），属"证据闭合"而非"打开新路" |
| **Q1** | 一句话问用户：**Windows 休眠→开机有没有出现过 POST 005 / 时间不对？** | **零成本、直接二分**：无 ⇒ 问题只在 macOS/OpenCore 侧；有 ⇒ 平台级 | 🟢 零 | ✅ **已问、已答（2026-09-20 15:3x）** ⇒ 答案 = **「问题只在 macOS/OpenCore 侧，Windows 和 Linux 都可以正常休眠」** ⇒ 见 **§7.8** |

**HP 那条"更新 BIOS 可能修"现在没有收益**：本机实录 BIOS = **`T75 Ver. 01.24.02`（2026-05-11）**，比 HP 文档时代的 `01.20.00` 新；且 AOAC 封板（附录 F/G）已把这条路覆盖。

---

## 7.8 ★ 定案：Q1 答复回来了 ⇒ **平台级整类排除**，三处结论修正（2026-09-20 15:3x）

> 触发 = §7.7 **Q1 的答复**（**用户一手回报**）：
> > 「**问题只在 macOS/OpenCore 侧，Windows 和 Linux 都可以正常休眠。**」
>
> 语义展开（🟢，用户一手）：Windows/Linux 的休眠**功能可用**（⇒ 无 POST 005、时钟正确；有这两样就不叫"正常"）。
> 本轮**零配置 / 零 EFI / 零固件写入**；新增内容 = 1 次现场核对（`config.plist` 六级实读）＋ 1 次 git 时间线对齐 ＋ 2 份官方手册原文 ＋ 1 处**旧记录纠错**。

### (a) L5（硬件/固件结构层）三条判据要改 —— 本节主要产出

| 判据 | 原判 | **改判** | 依据 |
|---|---|---|---|
| **#27** 固件真的实现 S4 的"断电＋冷启动恢复" | ❌（拆 27a/27b） | **✅ 平台级已证成** | 同机同固件：Windows/Linux 休眠-恢复**成功** |
| **#28** RTC/CMOS 在 S4 断电期间保持有效 | ❌「HP 固件不保证」 | **✅ 平台保证** | Windows 休眠周期**无 005、时钟正确** ⇒ **我们那 3/5 的 POST 005 是 macOS 自己写坏的**（`AppleRTC` 密钥 `0x80–0xAB` ＋ 校验和 `0x58/0x59`），**不是固件固有缺陷** —— 与 §7.2 的机制解释**自洽** |
| **#29** EC 在 S4 进出时正常 | ⚠️ 未测 | **✅（S4 场景）已证成** | 同上；⚠️ 但 **S3 恢复**仍是坏的 ⇒ **S3 的 EC 结论不能外推到 S4**（此前是越界） |

⇒ **"硬件不行"这条整类现在有跨 OS 对照背书，不再只是"同日 9 次睡眠"的间接推断。**
⇒ 同时**方向翻转**：`POST 005` 从"固件缺陷的证据"变成"**macOS 侧行为的证据**"（写坏 CMOS 的只有 macOS 一家）。

### (b) 【**部分**撤回 · 2026-09-20 16:3x 加限定，见 §7.10a】一条机制假设

| 原说法（§7.6 🟡 / §7.4） | 处置 |
|---|---|
| "**平台按 AOAC/S0ix 语义直接切电，而不执行 S4 的保存-交接流程**" | ⚠️ **只撤回一半**（16:3x 修正）：反证 = 同机 Windows/Linux **完成了 S4**，**但那只覆盖 `S0→S4` 直通** —— 两者都**不经过 S3 语义** ⇒ **「平台不支持 S4」❌ 已排除；「平台在 S3 语义下异常」⚠️ 仍可疑**（而 macOS 恰恰必须先走这段 S3 语义）|
| 连带：§7.3 那个"**唯一修法是关 AOAC ⇒ 关不掉 ⇒ 修法不存在**"的闭环 | **半塌**：只对 **macOS 的换档路径**成立。**AOAC 压的是 S3/传统睡眠语义，它没有阻断平台级 S4。** ⇒ ⛔ 不要为了让 macOS 休眠回头去关 AOAC（那条门本来也关不上） |

### (c) 但有一条差异**被这次对照提纯了**

本机 macOS 真正做不动的是**"睡眠 → 休眠"的换档**（5/5 有 `Entering Sleep`、0/5 有 `Entering Hibernate`）。对照两个系统的**休眠起点**：

| | 休眠从哪开始 | 是否要先走一段 S3 语义的睡眠 |
|---|---|---|
| **Windows** | **S0 直接 → S4**（Modern Standby 的 Adaptive Hibernate 也是 S0→S4） | ❌ 不需要 |
| **Linux** | 内核直接 `hibernate()` → S4（`pm_hibernation`） | ❌ 不需要 |
| **macOS `hibernatemode 25`** | **先做一次 `Software Sleep` 转换，再转 S4** | ✅ **需要**（这正是 5/5 有 `Entering Sleep` 的原因） |

> ⚠️ 分级：Windows/Linux 侧 = 🟢（机制明确）；**"macOS 必须先过一段 S3 语义"= 🟡 机制假设** —— 它解释了"平台被排除后为什么 Windows 能而 macOS 不能"，但**没有逐行源码/上游文档坐实**，不许当结论引用。

⇒ 一句话：**不是平台不会 S4，是 macOS 要先走一段本机做不了的 S3 语义睡眠。**

### (d) 剩余嫌疑 —— **全部落在 macOS / OpenCore 侧**（按"文档强度 × 代价"排序）

| # | 嫌疑 | 上游依据 | 本机状态 | 代价 |
|---|---|---|---|---|
| **1** | `Booter/Quirks/DevirtualiseMmio = true` ＋ **`MmioWhitelist` 0 条**，而 `Misc/Debug/Target = 0` ⇒ 无 OC 日志 | OC 官方 L1549-1552 明文：*"a list of addresses that need virtual addresses for proper NVRAM **and hibernation** functionality may be required"* | ⚠️ **从未验证** —— 全清单里**唯一一条"官方点名 hibernation 而本机没验"**的项 | 开一次 OC 日志（`Target=0x43`＋重启）即可判，零功能改动 |
| 2 | macOS 休眠**镜像写盘路径**本身 | 无 | ⚠️ **从未单独测过**（原判 ❌ 是方法学错误；新造的 T2 也作废，见 §4） | **已无低风险判据**（唯一能测的入口就是那条会断电的路） |
| 3 | ~~L2 桥缺失（`HibernationFixup` / `HibernateMode=NVRAM`）~~ | — | **已实测排除**，见下方台账 ⇒ 不是"缺桥" | — |
| 4 | `Misc/Boot/HibernateMode` 取值是否合法 | OC 官方手册取值域 = **`None` / `Auto` / `RTC` / `NVRAM`**（🟢 已核原文） | `NVRAM` **合法** ✅；且失败发生在 **boot 侧检测之前**，与本项无关 | — |

#### 台账：为什么"缺桥"这条排除是硬的（git 时间线对齐，2026-09-20 15:3x）

| 时刻（09-16） | 提交 | 作用 |
|---|---|---|
| **09:03** | `2f5c047` | `HibernateMode` None → **`NVRAM`**（桥的**读侧**配对） |
| **10:42** | `85888f6` | **装入 `HibernationFixup` 1.5.4**，`Kernel/Add` 插在 Lilu 之后（桥 **在**） |
| **13:39** | `4ceea3a` | `RTCMemoryFixup` ＋ `rtcfx_exclude=80-FF`（桥的**写侧**配对） |
| **18:09 / 19:29** | ← 第 4、5 次武装休眠 | **桥已全副武装，仍同签名失败**（`hibernatecount=0`、`nvram` 无休眠变量） |
| 18:39 | `22b8d3f` | 定案「真休眠路线证伪并停用」＋ **拆地雷**（回滚 `hibernatemode 0` / `standby 0`） |
| **09-17 16:44** | `a3cd5f7` | 桥已无用，随"删减 3 个无效 kext"移除（理由 = "S3/S4 已判死") |

⇒ **结论成立的前提（桥在场）经 git 核对为真**，5 次失败**不是"缺件"造成的无效测试。**（这一条必须写下来 —— 否则下次又会有人怀疑"是不是没装 kext"。）

### (e) 顺带查出的两处**记录错误**（与休眠失败无因果，但会误导判断）

1. **`rtc-blacklist` 的实际范围写错了** —— 文档与 MEMORY 一直记 `0x0E–0x73`（102 B），**实测 = `<data 242B>` ⇒ `0x0E–0xFF`（含休眠区 `0x80–0xAB`）**。
   ⇒ 更正后结论**更强也换了个理由**：内核（`rtcfx_exclude=0E-FF`）与固件（`rtc-blacklist=0E-FF`）**两级都挡住了休眠区** ⇒ RTC 路线是**彻底关闭**的，**NVRAM 路线是唯一路线**（= T530 设计，但依据不是"固件层没挡"）。已改 §1 #14。
2. **T2 的判据设计错误** —— `hibernatemode 3` **不在入睡时写镜像**（`round1-tierA-result.md` 实测：mode 3 ＋ `standbydelay 300`，睡 338 s，`sleepimage` mtime **未变**）。mode 3 是在**进 standby 时**才写，而 `standby` 四前提在本机 AC ＋ 外接屏下天然不满足 ⇒ **按原设计跑必然得"没写"，是假阴性**。已把 §4 的 T2 标 **⛔ 作废**。

### (f) 结论

| 问题 | 答案 |
|---|---|
| 平台/固件/EC/RTC 能不能做 S4？ | **能**（Windows/Linux 实测，跨 OS 对照） |
| 那为什么 macOS 不行？ | 失败点在 **macOS 侧"睡眠→休眠"的换档**：5/5 有 `Entering Sleep`、**0/5 有 `Entering Hibernate`**，随后硬断电 ⇒ **病灶不在固件，在 macOS/OpenCore 这一侧** |
| 有没有新的修法？ | **没有。** 唯一"官方点名 hibernation 而本机未验"的是 `DevirtualiseMmio`/`MmioWhitelist`，但**即便验证了也改变不了"换档过不去"** |
| 默认动作 | **不改。** 出远门**关机**（0 W、零 RTC 风险、开机 30–40 s ≈ 休眠唤醒耗时）不变 |

## 7.9 ★ 再深一层：为什么**只有** macOS 要走这三道关（2026-09-20 16:1x）

用户就同一方向追问到第三次 ⇒ 说明 §7.1–§7.8 只回答了"差异**是什么**"，没回答"差异**为什么存在**"。本节补这一层，**不新增动作**。

### (a) 根因：引导器的**职责边界**不同 —— 不是"能力"不同

上游原文（`eclecticlight.co/2018/08/21/booting-the-mac-efi-firmware`，作者 Howard Oakley，macOS 引导流程的公开权威）：

> "**This phase also looks for any saved hibernation state**: if the Mac is to be restored to that state, **Hibernation Resume** will be initiated and will then override the rest of the boot process."

"This phase" = **boot.efi / EFI 阶段**。⇒ macOS 的休眠恢复由 `boot.efi` **在引导阶段**判断，而它的判断依据来自**平台留下的状态**。

| | 谁负责"认出这次是恢复" | 要不要问固件 |
|---|---|---|
| Windows | `winload.efi` 自己读 `hiberfil.sys` | ❌ |
| Linux | GRUB / initramfs 按 `resume=` 读 swap 头 | ❌ |
| macOS | `boot.efi` 找**平台留下的休眠状态** | ✅ |

**★ 自证（不需要外部资料）**：OpenCore 专门为 macOS 提供了 `Misc/Boot/HibernateMode`（`None`/`Auto`/`RTC`/`NVRAM`）与 `HibernationSkipsPicker` 两个选项 —— 上游 chrultrabook 文档原话：*"**By default, OpenCore will not look for hibernated images of macOS**"*。**OC 从不需要为 Windows / Linux 提供任何同类开关** ⇒ **配置项的存在 = 需求的存在**。

⚠️ **但这层是"恢复侧"的钥匙。** 本机的失败点在**保存侧**（换档过不去，镜像**根本没写**）⇒ `HibernateMode=NVRAM` 再正确也救不了。这解释了为什么 §1 表里 `HibernateMode=NVRAM ✅` 与"实测 5/5 失败"**并不矛盾** —— 两者管的是不同的半场。

### (b) 保存侧：macOS 独有的"必须先睡一次"

**🟢 实测（硬）**：§7.4 的 5 次签名 —— **每次都有 `Entering Sleep`，一次都没有 `Entering Hibernate`** ⇒ **macOS 的休眠路径上确实先发生了一次 Sleep 转换**（不是"直奔 S4 然后失败"）。

**🟡 设计解释（软，不作证据）**：`pmset` 对 `mode 25` 的表述是 "Hibernates instead of S3 sleep"，但从实测看它**并不是"跳过 S3"**。⚠️ 曾拟引上游 chrultrabook 的 *"macOS enters S3 sleep instead of shutting down"* 作证，**但该句有歧义**（语境更像"mode 25 失效时反而退化成 S3"）⇒ **降级为 🟡，结论方向不依赖它**。

- Windows：**S0 → S4 直通**
- Linux：内核直接 `hibernate()`
- macOS：**先做一次 S3 语义的 `Software Sleep` 转换**

**都不需要"先睡一次"的，只有 macOS 需要。** 本机 S3 = ❌（AOAC 压住 ⇒ `AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ EC 恢复后不响应）⇒ 与 §7.4 实测签名（`Entering Sleep` **5/5**、`Entering Hibernate` **0/5**）**完全吻合**。

### (c) 备选通道：也被锁

即便绕开 S3 换档，macOS 还得有地方写"我要休眠"这个意图：

1. **首选 AWAC，但本机 DSDT 里 AWAC 与 RTC 是互补对**（本轮实读行号）：
   - `DSDT.dsl:6756` → `STAS, 8,`（变量声明）
   - `DSDT.dsl:9398` → `AWAC._STA` 内 `If ((STAS == Zero))` ⇒ Return `0x0F`
   - `DSDT.dsl:29686` → `RTC._STA` 内 `If ((STAS == One))` ⇒ Return `0x0F`
   - `SSDT-AWAC.aml` 对 **Darwin** 设 `STAS = One` ⇒ **macOS 只能用老式 CMOS RTC，AWAC 归 Windows**
2. **而 macOS 的休眠密钥恰恰写在 CMOS `0x80`–`0xAB`**（`AppleRTC.kext 2.0.1` 反汇编常量 `APPLE_RTC_HIBERNATION_KEY_ADDR = 0x80`、`LEN = 0x2C`）
3. 这段正是 **HP 固件设校验和的区** ⇒ **结构性冲突**
4. **Windows 走 AWAC，这段 CMOS 它一点都不碰** ⇒ 无冲突

⚠️ **极性坑（可纠正的旧表述）**：社区里 `STAS = One/Zero` 的写法**互相矛盾**（Dortania 与若干教程不一致）⇒ **判极性只能读本机 DSDT `_STA`**，不能照抄。本机实读结论如上。

### (d) 收口：一张表 + 一句话

| 层 | 关卡 | 谁有这个要求 | 本机状态 |
|---|---|---|---|
| 1 | 平台告知"本次是恢复"（恢复侧） | **仅 macOS** | 🚫 平台被 AOAC 锁在 Modern Standby |
| 2 | 入睡前先过 S3 语义转换（保存侧） | **仅 macOS**（`mode 25`） | 🚫 S3 实测坏 |
| 3 | 休眠密钥写 CMOS RTC | **仅 macOS**（被 `SSDT-AWAC` 逼去） | 🚫 该段归 HP 校验和管 |
| — | —— | Win / Linux：**零关** | ✅ |

> **不是 "macOS 不会休眠"，而是 macOS 的休眠设计上要求平台中途握一次手 —— 而本机的每一条握手通道，都恰好被另一套设计（HP 的 AOAC ＋ `SSDT-AWAC` ＋ RTC 校验和区）占用或封死。Windows / Linux 根本不需要那次握手。**

### (e) 证据分级 + 边界

- 🟢 **上游文档原文**：`boot.efi` 在 **EFI 阶段**查休眠状态并接管引导（eclecticlight）；OC **默认不找休眠镜像**（chrultrabook）
- 🟡 **机制解释**："`mode 25` 要先过 S3 语义"这句**只由歧义引用支撑**（见 (b)）⇒ **不作证据**；结论只依赖 🟢 实测签名（有 `Entering Sleep`、无 `Entering Hibernate`）
- 🟢 **本机实读**：DSDT 三处行号、`AppleRTC` 常量、`SSDT-AWAC` 对 Darwin 设 `STAS=One`
- 🟢 **自证**：OC 有 `HibernateMode` / `HibernationSkipsPicker`，而 Win/Linux 无任何同类开关
- 🟡 **机制推断**："Win/Linux 引导器各自扫盘"属通识，**未逐条找上游原文**（不影响结论方向）
- ⚪ 本节**不新增任何动作**、不改变"默认动作 = 不改"、**零配置 / 零 EFI / 零固件写入**

## 7.10 ★★ 追问「确定没解？」⇒ **不确定，改口三处**（2026-09-20 16:3x）

用户追问「确定没解？」⇒ 按「引用 N 次失败前先对齐当时配置」的纪律重核 ⇒ **发现上一轮有两处过度**，且**找出一条从未测过的路径**。本轮**零配置 / 零 EFI / 零固件写入**（只读核查）。

### (a) 【修正】上一轮的「撤回」撤过头了 —— AOAC 对 **S3 路径**的影响**未被排除**

§7.8(b) 以「同机 Win/Linux 完成了 S4」为反证，撤回了「平台按 AOAC/S0ix 语义直接切电」。**但那个反证只覆盖 `S0→S4` 直通** —— Windows 是 S0→S4 直通、Linux 内核直接 `hibernate()`，**两者都不经过 S3 语义**。

⇒ 「平台在 **S3 语义**下行为异常（异常切电）」**并没有被这个对照否定**；而 macOS 恰恰**必须**先走一段 S3 语义（§7.9b）。

⇒ 正确表述应是：**「平台不支持 S4」❌ 已排除；「平台在 S3 语义下异常」⚠️ 仍可疑。** §7.8(b) 需按此限定。

### (b) 【修正】`4ceea3a` **不是**"自相矛盾配置" —— 它的假设**成立**

本轮初查时曾怀疑：`4ceea3a` 用 `rtcfx_exclude=80-FF` **禁写 RTC 第二 bank**，而 macOS 休眠密钥正在 `0x80–0xAB` ⇒ 拟判第 4/5 次测试"自相矛盾、应剔除"。

**查 `HibernationFixup` 上游 README 后此怀疑被推翻**（原文）：

> *"An open source kernel extension providing **a sync between RTC variables and NVRAM**."*
> *"…**Somehow this value has to be written into RTC (or SMC) in order the boot.efi could read it. But in case if you have to limit your RTC memory to 1 bank (128 bytes), it doesn't work**… **Fortunately, boot.efi can read key `IOHibernateRTCVariables` from NVRAM!** This kext detects entering into "hibernate" power state, reads variable `IOHibernateRTCVariables` from the system registry and **writes it to NVRAM**."*

⇒ `HibernationFixup` **就是为"RTC 被限制在一个 bank"这个场景写的** —— 与本机「禁写第二 bank」**完全对应**。
⇒ 第 4/5 次的配置**逻辑自洽，是有效测试，不应剔除**。
⇒ **但它仍失败**，原因据 README 即可判定：它要 **"detects entering into 'hibernate' power state"** 才动手 ⇒ 而本机 **0/5 从未进入该状态** ⇒ **鸡生蛋** —— 它要救的正是那个从未发生的时刻。

### (c) ★★【新发现】一条**从未测过**的路径：`hbfx-ahbm`（休眠**代替**常规睡眠）

`HibernationFixup` 的 boot-arg 表（acidanthera README；OC-Little-Translated 的 boot-args 表同文）：

> **`hbfx-ahbm=1` → `EnableAutoHibernation`: "If this flag is set, system will hibernate instead of regular sleep"**

**★ 本机从未用过它**：09-16 那 5 次测试的 boot-args 里**都没有** `hbfx-ahbm`。历史里出现过 `-hbfx-patch=auto`（08-04），而 README 中**没有 `hbfx-patch` 这个参数**（只有 `hbfx-patch-pci`）⇒ 那是**无效参数**。

**为什么这条路值得试**：
- 本机卡点 = **"必须先过一段 S3 语义转换"**（§7.9b）⇒ `hbfx-ahbm` 的语义正是 **"hibernate **instead of** regular sleep"** ⇒ **绕开常规睡眠那一步**
- 且它把休眠密钥走 **NVRAM**（见 (b) 引文）⇒ 同时绕开 CMOS `0x80–0xAB` ⇒ 理论上**连 POST 005 也能避开**
- ⇒ **同时直击关②与关③**，是现存的**唯一**一条这样的手段

⚠️ **诚实标注**：
- 🟢 **文档语义**：acidanthera README ＋ OC-Little-Translated 表（两份互相印证）
- 🟡 **零实测记录**：本轮搜社区（`hbfx-ahbm` × 休眠）**没有找到成功或失败的实测反馈** ⇒ "能否真跳过 S3 转换"**只有文档语义支撑，未验证**
- ⚠️ **不能保证**：`ahbm` 走的仍是内核休眠事务；若平台在 hibernate 事务本身也有问题，同样会失败

### (d) 另外两个未测点（保留，优先级低）

| 项 | 依据 | 代价 |
|---|---|---|
| `DevirtualiseMmio = true` ＋ `MmioWhitelist` 空 | OC 官方明文 *"proper NVRAM **and hibernation** functionality"* | 需开 OC 日志 |
| **UEFI 变量层**查 `Modern Standby`（`dmpstore -all`） | WMI `IsReadOnly=1` **不等于** UEFI 变量只读 ⇒ 唯一没探过的"关 AOAC"的门 | **零成本（只读）** |

### (e) 结论：必须区分「已试空间」与「绝对」

| 命题 | 判定 |
|---|---|
| **在已试过的配置空间里，休眠没解** | ✅ **成立**（有效测试 3 批次：11:16 / 12:04「件齐 ＋ RTC 放行」、18:09 / 19:29「件齐 ＋ RTC 禁写 ＋ NVRAM 通路」，**全部失败**） |
| **绝对没解 / 已无手段可用** | ❌ **不成立** —— `hbfx-ahbm` **从未测过** |
| 撤 `SSDT-AWAC` 让 macOS 走 AWAC | ⛔ **不是出路**：Dortania 原文 *"SSDT-AWAC tries to **re-enable the old RTC clock that is compatible with macOS**"* ⇒ 老式 RTC 是 macOS **需要**的，撤掉是反方向 |
| 编程器改 SPI / 换主板 | 代价不可接受，**不算解** |

### (f) 建议（不急，需用户拍板）

**值得针对 `hbfx-ahbm` 做一次受控测试**：装回 `HibernationFixup`（1.5.4）＋ boot-arg `hbfx-ahbm=1`（或 `3` = 1＋2 合盖触发），**保留** `rtcfx_exclude=0E-FF`，观察 `pmset -g log` 是否出现 `Entering Hibernate`。

- 回滚点：移除 boot-arg ＋ kext（一条 git revert）
- ⚠️ 若仍失败，则"所有已知手段均已试过"，**"没解"才算真正闭环**
- ⚠️ 前置：内存压力（swap 75 %）下 8 GiB sleepimage 写入会很慢，测试前先腾内存

---

## 7.11 ★ 确定度审计：哪些是实锤、哪些只是推的（2026-09-21 10:4x）

> 触发：用户第 4 次就同一方向追问「**确定？还是只是猜测？**」
> 本轮**零配置 / 零 EFI / 零固件写入**；新增 = **三条外部引用逐字复核（带 URL）** ＋ **两条本机一手证据复验** ＋ **三处自曝「此前说得比证据硬」**。
> 目的：把 §7.1–§7.10 混在一个叙事里的三级证据拆开，**防止今后继续拔高**。

### (a) 外部引用逐字复核（2026-09-21 10:4x 实测 fetch）

| # | 来源 | 逐字原文 | 结论 |
|---|---|---|---|
| 1 | `learn.microsoft.com/en-us/windows/win32/power/system-power-states` | *"A resume from hibernation starts with a system POST that's similar to an S5 shutdown. **The OS boot manager determines that a resume from hibernation is required by detecting a valid hibernation file.** Then it directs the system to resume…"* | ✅ 逐字一致。恢复六步（POST → 解压恢复 → 设备初始化 → 驱动 → 服务 → 可登录）**完全没有固件交接** |
| 2 | `github.com/acidanthera/HibernationFixup` README | *"By design the mach kernel encrypts hibernate sleepimage and writes the encryption key to variable "IOHibernateRTCVariables" in the system registry (PMRootDomain). **Somehow this value has to be written into RTC (or SMC) in order the boot.efi could read it.**"* | ✅ 逐字一致 ← **三条里最硬的一条** |
| 3 | `eclecticlight.co/2018/08/21/booting-the-mac-efi-firmware` | *"**This phase** [EFI / boot.efi] **also looks for any saved hibernation state**: if the Mac is to be restored to that state, Hibernation Resume will be initiated…"* | ✅ 逐字一致 ⚠️ **但原文没说这个 state 存在哪里** |

### (b) ★★ 由 (a) 得到的一处**表述收紧**（此前说过头了）

| 说法 | 判定 |
|---|---|
| ~~"macOS 的休眠恢复**必须**由平台交接"~~ | ⚠️ **要收紧** —— 来源 3 只说 boot.efi **会去找**"saved hibernation state"，**没说它必须来自固件** |
| ✅ 准确表述 | **macOS 的休眠密钥（`IOHibernateRTCVariables`）设计上要落在 RTC/SMC，boot.efi 才能读到**（来源 2 逐字） |
| ✅ 而且**存在官方后备通道** | 同一篇 README 紧接着：*"**Fortunately, boot.efi can read key "IOHibernateRTCVariables" from NVRAM!**"* ⇒ **NVRAM 是被上游承认的替代通路，不是"三条路全死"** |

⇒ **对 §7.9(d)「三道关」表的修正**：关 ① 应读作「设计上**期望**在 RTC/SMC 留一个交接点（NVRAM 可替代）」——
**本机真正的死角不在"没有通道"，而在"从未走到需要交接的那一步"**（保存侧就没写出镜像，见 (c) 🟢#1）。
⇒ **这也解释了 `HibernationFixup` 装了为什么白装**：README 明说它 **"detects entering into 'hibernate' power state"** 才动手 ⇒ **鸡生蛋** —— 它要救的正是那个从未发生的时刻。

### (c) 三代证据分级（逐条，引用前照抄）

**🟢 实锤 · 一手实测（本机可当场复现）**

| # | 事实 | 来源 |
|---|---|---|
| 1 | **5 次武装休眠：`Entering Sleep` 5/5、`Entering Hibernate` 0/5、`Wake from` 0/5、`hibernatecount=0`、NVRAM 无变量** | `pmset -g log` 全量实读 |
| 2 | 同日 9 次睡眠：武装 5 次**全失败**（3 次 005）／普通 4 次**全正常**（含连睡 12.6 h） | 同上 |
| 3 | **S3 实测坏**：`EC OBF=1` 34/120 次（Deep Idle 为 **0**）；唤醒 **159.3 s** vs 2.4 s；PS2 恢复 **157,735 ms** vs 457 ms；1 次 panic | 同上 ＋ 内核日志 |
| 4 | `FACP-1.aml` `FLAGS@0x70 = 0x002384A5` ⇒ **bit21 AOAC = 1**、bit20 = 0；`LPIT-1.aml` 在 | **本轮复验**（二进制直读） |
| 5 | `SSDT-AWAC.aml` = **73 B**，`STAS`×2，**`_OSI("Darwin")` 门控在** | **本轮复验** |
| 6 | `AppleRTC.kext` 反汇编：`APPLE_RTC_HIBERNATION_KEY_ADDR = 0x80`、LEN `0x2C` | 反汇编（前轮） |
| 7 | DSDT `AWAC._STA`(`STAS==Zero`) 与 `RTC._STA`(`STAS==One`) 是**互补对** | DSDT 实读 |
| 8 | R3b：`standbydelay 0` ⇒ 睡下即内核停摆、`sleepimage` 前 16 B **全 0**、**POST 005** | 实读 ＋ 用户确认 |
| 9 | 内核日志 `type 5 → type 7 → hibernateMode 0x0` | `log show --info --debug` |
| 10 | Windows 侧休眠文件 **full 型 6.14 GiB** | `hiberfil.sys` 现场 |

**🟢 实锤 · 上游原文**：(a) 的来源 1/2/3 ＋ XNU 行号（`IOPMrootDomain.cpp:5656/5758`、`hbfx2.cpp:437/449`）＋ Dortania《Fixing System Clocks》＋ 自证（OC 有 `HibernateMode`/`HibernationSkipsPicker`，Win/Linux 无任何同类开关）。

**🟡 推断 · 有支撑但不是实锤（引用时必须标）**

| # | 说法 | 支撑 | 缺什么 |
|---|---|---|---|
| 1 | **「两套契约」这个框架本身** | 来源 1（Win 不问固件）＋ 来源 2（macOS 密钥要进 RTC）**两条 🟢 的合成** | ⚠️ **不是任何单一原文的直述** —— 是我把两条并起来讲的 |
| 2 | 「macOS 必须**先过一段 S3 语义**转换才会失败」 | 只有**歧义引用**；但"有 `Entering Sleep`、无 `Entering Hibernate`"是 🟢 | **因果那半未坐实** ⇒ 只报实测签名，别推因果 |
| 3 | 「关 ① 被 **AOAC** 锁在 Modern Standby」 | 关 ① 通道存在（来源 2/3 🟢）；"被 AOAC 锁"是机制推断 | 无逐行证据 |
| 4 | 「Win/Linux 引导器**各自扫盘**」 | 通识（来源 1 只覆盖 Windows） | **Linux 侧未找上游原文** |
| 5 | 「失败形态 = **硬断电**」 | 日志戛然而止 ＋ 无 panic ＋ 无正常关机记录 | 但 **POST 005 已是独立实锤**（BIOS 层 RTC 掉电）⇒ 本条实际够硬 |

**⚪ 未知 / 已撤回（不得再引用）**

| # | 内容 |
|---|---|
| 1 | ~~"平台按 AOAC/S0ix 语义直接切电、不执行 S4"~~ ⇒ **已撤回**（跨 OS 对照直接否掉） |
| 2 | **Linux 本机从未实测** —— "Linux 可以休眠"是**用户一手回报**，机器上无一手证据 |
| 3 | 「平台在 **S3 语义**下行为异常」⇒ ⚠️ **仍可疑、未被排除**（Win 是 S0→S4 直通、Linux 内核直接 `hibernate()`，**两者都不经过 S3 语义** ⇒ 跨 OS 对照覆盖不到这一条） |

### (d) 一句话回答「确定吗」

> **确定三件事**：① 本机**从未写出过休眠镜像**（保存侧就没过；10 条一手证据）② **S3 在本机实测坏**（EC 不回话）③ **Windows/Linux 的恢复不依赖固件**（微软原文逐字）。
> **不确定两件事**：「两套契约」这个**框架表述**、以及「**必须**先过 S3 语义」这个**因果** —— 是推断，引用必须标。
> **完全不知道一件事**：**Linux 在本机到底能不能休眠**（没测过）。

### (e) 本轮影响

- **不改变结论方向**：S4 判不通**不依赖** 🟡 那几条 —— 它只依赖 (c) 🟢#1/#2/#8（**保存侧从未成功**）。
- **一处收紧**：§7.9(d) 关 ① 的表述改为「设计上期望在 RTC/SMC 留交接点，NVRAM 为官方后备」。
- 零配置 / 零 EFI / 零固件写入；**默认动作仍为「不改」**。
