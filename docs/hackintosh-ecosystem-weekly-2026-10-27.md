# 黑苹果生态跟踪简报 · 2026-10-27

窗口 2026-10-26 09:07 → 2026-10-27 09:02（约 24h）｜基准机：HP ZBook Power G7 / macOS 26.7.1 (25G241) / OC REL-109-2026-10-11 MOD

**一句话判断：有实质推进，但不在"驱动"上——OTA 侧 26.7.2 已发布，且本机首次看到 1.27 GiB 增量包（seal 恢复后 delta 真的回来了）。未驱动项 1–7 全部无进展。**

## 0. NullMoth 专项（P620 唯一可能转机）

| 版本 | 发布日期 | 变更要点（读 release body 原文） | 对本机 |
|---|---|---|---|
| v2.6.0 | 2026-10-26T07:15Z | 更新后只需重启一次；安装器由"允许扩展后再重启一次"改为"一次足够"（实测每个扩展均批准、无被扣） | 无用，纯安装器/授权流程 |
| v2.6.1 | 2026-10-26T08:45Z | 同一驱动，配 1401 Mac/Win 新版 App | 无用 |
| v2.6.2 | 2026-10-26T10:34Z | 同一驱动，修 1401 App | 无用 |

`#229`（Pascal / GTX 10xx / Quadro P100–P600）：仍 **closed / completed**，评论 **1**（2026-10-21T22:56Z 起未增），label 无变化，**无维护者新回应**。全库搜 Pascal/P620/GP107 共 31 条，**无新开 Pascal 议题**。README 主轴未变 `Supported cards are Turing and newer`（Quadro 仅 RTX / T 系列）⇒ 三个版本无一给 Pascal 加支持。

## 0.5 SimpleHDA 专项（本机音频唯一依赖）

**无新 release，当前仍 v1.0.0（2026-10-14T17:27Z）**，末次 commit `7517b04`（2026-10-14）。依赖未变：`OSBundleLibraries` 只有 `as.vit9696.Lilu 1.7.1` + 4 个 `com.apple.kpi.*`，**不声明 IOAudioFamily 依赖** ⇒ 小版本更新不会因版本失配被拒；`keepsyms=1` 仍必需（`nvram boot-args` 实测在）。issue **#6 于 2026-10-24T14:45Z closed（completed，3 评）**：报告机（Dell 7430 / ALC289 / 26.7.1 25G241）改用 **VoodooHDA 3.6.5** 后内建数字麦（pin 0x12）可用、扬声器正常、无空闲发热；维护者定性 "SimpleHDA is just to restore AppleHDA"，codec 级问题不在其范围。**对本机不适用**——该机自述 `plain HDA (not SoundWire)`，我们的真麦是 AE30 SoundWire，VoodooHDA 同样接不上。

## 1–7 项状态

| # | 项目 | 本期 | 证据 | 对本机判断 |
|---|---|---|---|---|
| 1 | P620 Metal | 无进展 | nullmoth v2.6.0–2.6.2（10-26）；#229 closed | 维持封板，无需动作 |
| 2 | HDMI/DP 音频 | 无变化 | CloverHackyColor/VoodooHDA 最新仍 v3.7.1-alpha(10-23)，无新 release | 维持无解（GFXHDA 的 IOPCIMatch 不含 0x9B3E） |
| 3 | 内建麦 | 无利好 | SimpleHDA #6 是 HDA 引脚麦，非 SoundWire | 维持无解，继续 TRRS/USB/蓝牙麦 |
| 4 | AirDrop/awdl | 无变化 | laobamac/itlwm 最新 commit 仍 `738d4c6`(10-18)；上游 main 仍 `53c51c2`(2024-06-09) | 无 |
| 5 | 触摸板唤醒 | 无变化 | VoodooI2C v2.9.1(2024-11-06) = 本机版本 | 无 |
| 6 | 风扇控速 | 无变化 | 无新上游项目 | 无 |
| 7 | 睡眠功耗 | **关注点关闭** | 本机 HDEF 实测 `AFGLowPowerState=<000000000000>` = **0**，非 #6 触发的 3 | #6 的"6.6W vs 3.7W 中断风暴"前提不成立；3.885 W 结论不变，不必再跑 powermetrics |
| 8 | OTA delta | **★唯一实质利好** | 见下节 | 值得动手 |

## 8. OTA：26.7.2 已出，delta 恢复

本机 `softwareupdate --list` 实测（2026-10-27 09:08）：`macOS Tahoe 26.7.2-25G332`，Size **1,326,635 KiB ≈ 1.27 GiB**，Recommended、需重启；另 `Safari 27.2` 250,130 KiB 为独立条目，与系统包无关。对照 root patch 时期那 4 条 `_full_` 记录是 12 GB 级 ⇒ **1.27 GiB 属增量档**，决定性因素是 seal，**SIP 全关并未挡住 delta**（修正"必须 SIP 全开才给增量"的通用说法）。反向也证一条：gdmf `PublicAssetSets` 已有 `27.2 (26B123)`（PostingDate 2026-10-26），但 `softwareupdate --list` 未把 27.x 推给本机 ⇒ 上期"`revpatch=sbvmm` 可能把 27 塞进来"的推断作废。风险评估：SimpleHDA 不依赖 IOAudioFamily（见 0.5），OC 与 kext 版本均不需动 ⇒ 致静音概率低，唯一不可预知项是 26.7.2 是否改动 IOAudioFamily 740.1 行为。

**建议：升。** 升级前记基线 `kmutil showloaded --list-only | grep -E 'IOAudioFamily|SimpleHDA'`；升后复验三点：内建输出出声、音量键可用、系统卷仍 `Sealed: Yes`。静音时回滚点 = 恢复升级前拍的 `EFI/OC`（本次无需改 EFI）。

## 基线核对（本期实测）· 未变项合并

`sw_vers`=26.7.1/25G241；`csr-active-config=%ff%0f%00%00`；boot-args 含 `revpatch=sbvmm`/`keepsyms=1`/`igfxrpsc=1`。HDEF：`layout-id=7`（非任务书的 55）、`Codec="ALC236 for HP-240G8 by 8DireZ3"`、`num-internal-mics=0`（上期记 1）、`AFGLowPowerState=0`。`/S/L/E/AppleHDA.kext` 不存在；`kmutil` 仅见 `com.apple.iokit.IOAudioFamily (740.1)`，无 AppleHDA 类。
acidanthera 六件套官方 release 全部仍低于本机（OC 1.0.8 / Lilu 1.7.2 / VirtualSMC 1.3.8 / WEG 1.7.1 / AppleALC 1.9.8 / RestrictEvents 1.1.6）⇒ 按降权规则不计新鲜。
**结论：** 该升——26.7.2 只给 1.27 GiB 增量，说明 seal 恢复后 delta 能力已实质回归（SIP 全关也不影响），这是本期唯一真利好；P620、HDMI 音频、内建麦、AirDrop、触摸板唤醒、风扇控速、睡眠功耗七项全部零进展，其中第 7 项因本机 `AFGLowPowerState=0` 可正式结案、不必再折腾；nullmoth 连发三版全是安装器体验，Pascal 依旧封板。
