# S4（真休眠）准入条件全清单 · 逐条判定

> **时间**：2026-09-17 21:0x｜**性质**：只读取证，EFI/pmset **零改动**
> **触发**：用户问「S4 需要哪些条件呢？都确定一下，能满足吗？」
> **依据分级**：`可当判据` = OC 官方 `Configuration.tex`（acidanthera/OpenCorePkg master 原文）／RTCMemoryFixup 官方 README／HibernationFixup 官方 README／5T33Z0 Lenovo-T530 issue #48 **原始回复线程**／本机二进制与运行时实测；`仅方向` = 单篇博客。

---

## 0. 一句话结论

> ⚠️ **本节已于 2026-09-17 21:3x 修正**（用户追问「是暂时没满足还是没法满足？」⇒ 重核时间线与证据后，§1 的 #27 / #30 两处判定不成立）。**修正后的账在 §6。**

**30 条准入条件：19 条已满足 · 2 条对本机不适用 · 5 条待验证 · 5 条不满足。**

- 5 条不满足里，**4 条是开关**（`hibernatemode`、`standby`、把 `HibernationFixup` 加回来、内存压力重启即解）⇒ 能凑；
- **只有 1 条真正结构性**：`#28` RTC 在 S4 断电期保持有效 ⇒ **改配置改不出来**，但 **HP 官方文档说"更新 BIOS 应该可能会解决该问题"** ⇒ 它也不是绝对判死。

⇒ **"条件能不能凑齐" = 能凑到约 97%，凑不齐的那 3% 只有 1 条，且 HP 官方给了可能解法（刷 BIOS，代价是不可回退）。**

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
| 14 | `UEFI/ProtocolOverrides/AppleRtcRam` 开 + `rtc-blacklist` **不含** `0x80–0xAB` | OC 官方 L9062-9071：builtin 版会 *"filter out I/O attempts to certain RTC memory addresses … specified in `rtc-blacklist`"* | `AppleRtcRam = true`；`rtc-blacklist` = **`0x0E–0x73`**（不含休眠区） | ✅ |
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
| 27 | 固件真的实现 S4 的"断电 + 冷启动恢复" | 无文档可查，**只能实测** | **6 次武装休眠全失败**，其中 **3 次触发 HP POST 005** | ❌ **仅一半成立（21:3x 修正）** ⇒ **必须拆两半**：**27a「断电动作」✅ 已实测发生**（5 次全是"睡下即断气"、`Wake from` 全无、时长栏为空）；**27b「冷启动恢复」❌ 失败**。⇒ **失败点在恢复侧，不是"固件没有 S4"** |
| 28 | RTC/CMOS 在 S4 断电期间保持有效 | — | `README.md:179`：*"三层软件防护（`rtcfx_exclude=0E-FF` ＋ `AppleRtcRam=true` ＋ `rtc-blacklist` 242 B）**全开仍报 005**，本就不矛盾 —— **掉电不是"写"**"* | ❌ **HP 固件不保证** ← ★ **但 HP 官方文档说"更新 BIOS 应该可能会解决"（见 §6）** |
| 29 | EC 在 S4 进出时正常 | — | 未单独测；但同一 EC 在 S3 恢复后已证 `EC OBF=1 poll timed out` 连绵 | ⚠️ **未测** |
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
| **T2** | `sudo pmset -c hibernatemode 3` → 插电 `pmset sleepnow` 睡 ~30 s → 唤醒 → 查 sleepimage | `/System/Volumes/VM/sleepimage`（或 `/var/vm/sleepimage`）是否变成 **≥8 GiB** | **低**（mode 3 不断电） |
| **T3** | `HibernationFixup` 加回 `Kernel/Add` + `mode 25` | `Entering Hibernate` 出现 + 能醒回来 | **中高**（写 RTC `0x80–0xAB`，有再触发 POST 005 的概率） |
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
