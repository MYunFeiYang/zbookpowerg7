# 黑苹果生态周报 · 2026-10-23（09:01）
窗口 10-22 09:12 → 10-23 09:01 ｜ 基线 HP ZBook Power G7 · macOS 26.7.1 (25G241) · OC REL-109 MOD

**判断：未驱动清单里有 1 项出现实质利好 —— #2 原生 AppleHDA 出现免 root patch 的第三条路（10-14 发布，上期漏报，本次回溯补报）；其余 7 项无实质推进，P620 维持封板。**

## 0 · NullMoth 专项（P620 唯一指望，每版必报）
| 版本 | 发布(CST) | 变更要点（读 release 原文） | 对本机 |
|---|---|---|---|
| v2.5.3 | 10-22 19:36 | 修 `nvregdwords=` 在 2.5.0–2.5.2 引起的内核 panic；**明确写「macOS 26 移除了 AppleHDA，本包在 26 上不单独提供显示音频」** | 无用；但正面坐实 #3 无解 |
| v2.5.2 | 10-22 09:22 | HDMI/DP 音频：把显示→codec 链路交给 AppleHDA（PR #284/#313）；笔记本 bring-up >40s 不再丢桌面（PR #317） | 无用（Pascal 无驱动 + 26 无 AppleHDA） |

`#229`：**closed / completed**（2026-10-21T22:56:52Z），comments=1，labels 空，窗口内 0 新评论、**0 维护者回应** ⇒ 无一级信号。repo README 仍写 "Supported cards are Turing and newer"；`#125` 另有 CONTRIBUTOR 于 10-14 二次确认 Pascal 无法加入。**P620 零 Metal，无转机。**

## 1 · 未驱动清单逐项（1–8）
| # | 项 | 状态 | 证据 | 对本机结论 |
|---|---|---|---|---|
| 1 | P620 Metal | 无变化·封板 | 见 §0 | 不值得再投入，Windows 侧装 DCH 驱动即可用 |
| 2 | 原生 AppleHDA | **利好（新路径）** | `laobamac/SimpleHDA` v1.0.0（2026-10-14T17:27Z）：Lilu 插件，OC 注入原版 AppleHDA，**不改系统卷、不重建 KC、无需关 SIP**，与 AppleALC 共用 layout-id | **值得动**：可摘掉已归档的 ModernAudio root patch，音频不再随系统更新失效；前置见 §3 |
| 3 | HDMI 音频 | 无解 | nullmoth v2.5.3 原文；InsanelyMac 实测 SimpleHDA 下 "USB-C HDMI does not work (yet)" | 不折腾 |
| 4 | AirDrop/Sidecar | 无变化 | `laobamac/itlwm` main 仍 `738d4c6`(10-18)，无新提交；v2.4.0-alpha(10-11) 未动 | 无 awdl0，维持不通 |
| 5 | 触摸板唤醒 | 无变化 | `VoodooI2C` 最新 v2.9.1（2024-11-06） | 硬件层已断，继续外接 |
| 6 | 风扇软件控速 | 无变化 | 未发现新的 HP EC 方案 | 维持不控 |
| 7 | 睡眠功耗 | 无变化 | 无相关提交/release | 维持 5.2–5.6 %/h |
| 8 | OTA 增量更新 | 无变化 | 仍 `revpatch=sbvmm`+`SecureBootModel=Disabled` | 维持；注意 §2 的 API 关停 |

## 2 · 顺带查实（影响判据，非本周版本变化）
- **`laobamac/OCLP-Mod` 已 `archived: true`**（`pushed_at` 2026-06-14，repo `updated_at` 2026-10-22T12:37Z；README 自述「2026.06.13 起归档、不再更新、API 节点逐步关闭」）⇒ 本机音频依赖的补丁器已死，**这是 #2 必须换路的直接理由**。建议在 OCLP-Mod 设置内关闭 SimpleHacAPI，避免 KDK 查询卡住。
- 官方 OCLP 最新仍 3.0.0-rc.3（10-08），最后提交 10-11；**PR #1176 / #1177 已于 2026-10-03 双双 closed/unmerged 结案** ⇒ 官方无 KDKless 音频路径，不必再等。
- acidanthera 四件套（OC 1.0.8 / Lilu 1.7.2 / WEG 1.7.1 / VirtualSMC 1.3.8）**无一追平本机版本 ⇒ 无价值**；macOS 公开最新仍 26.7.1 (25G241)、与本机同版。

## 3 · 本机基线纠错（本次实测，与任务书基线不符）
`kmutil showloaded` + config.plist 实读：**AppleHDA 600.2 已加载**、AppleALC 1.9.9、`/S/L/E/AppleHDA.kext` 在、**全盘无 VoodooHDA**、`SecureBootModel=Disabled`、boot-args 无 `keepsyms`。⇒ 任务书「VoodooHDA_BL 出声、无 AppleHDA」已过期；本机实际走 OCLP-Mod ModernAudio root patch，故换 SimpleHDA 的收益更高。

前置（均有出处）：① 先 unpatch ModernAudio，禁止双栈；② `Kernel→Add` 顺序 **Lilu → AppleALC → SimpleHDA**（顺序错会 panic，issue #3）；③ 必加 `keepsyms=1`；④ 保留 layout-id 55；⑤ `SecureBootModel` 须为 Disabled（issue #4 实测启用时卡 `#[EB|LOG:EXITBS:START]`，本机已满足）。回滚点：删 `SimpleHDA.kext` + 重打 root patch。

**结论：#2 原生 AppleHDA 是本周唯一实质利好 —— SimpleHDA v1.0.0 可免 root patch 恢复 AppleHDA，叠加 OCLP-Mod 已归档的事实，建议下个维护窗口就切过去（先 unpatch、加 keepsyms=1、顺序 Lilu→AppleALC→SimpleHDA），失败可原路回滚；P620、HDMI 音频、AirDrop、触摸板唤醒、风扇、睡眠、OTA 七项本周均无进展，不必再花时间。**
