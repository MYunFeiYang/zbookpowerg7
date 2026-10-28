# 黑苹果生态跟踪简报 · 2026-10-28

窗口 2026-10-27 09:02 → 2026-10-28 09:15｜基准机 HP ZBook Power G7 / **macOS 26.7.2 (25G332)**（本期已升级）/ OC REL-109-2026-10-11 MOD

**一句话判断：未驱动项 1–7 全部无实质推进；唯一实事是第 8 项——本机已于 10-27 11:55 升到 26.7.2，`fullReplacement: NO` 实证走的是增量包，且升级后音频栈完好、系统卷仍 `Sealed: Yes`，该项闭环。**

## 0. NullMoth 专项（P620 唯一可能转机）

**本周无新 release。** 当前最新仍 **v2.6.2（2026-10-26T10:34:37Z）**，body 原文 `The same driver as 2.6.0, released with fixes to the 1401 apps for Mac and Windows.` —— 纯 App 修复，无 GPU 支持变化。

| 项 | 状态（2026-10-28 实测） |
|---|---|
| `#229` Pascal（GTX 10xx / Quadro P100–P600） | **closed / completed 不变**；评论 **1** 条、`updated_at` 仍 **2026-10-21T22:56:52Z**（7 天零变动）；**无维护者新回应** |
| 全库 Pascal 相关议题 | `search pascal` = 8 条，无新开；`GP107` = 0、`P620` = 0 命中 |
| 新增议题 `#416` `[Feature] Add older macOS support` | open，2026-10-27T11:42Z，1 评；提者 RTX 4060 Ti，想要 Big Sur/Monterey 分支 ⇒ **与 Pascal 无关，不改变判定** |

## 0.5 SimpleHDA 专项（本机音频唯一依赖）

**无新 release，当前仍 v1.0.0（2026-10-14T17:27:32Z）**；repo `pushed_at` 仍 10-14、`open_issues_count = 0`、6 个 issue 全 closed。
本期新增硬证据：**SimpleHDA 1.0.0 在 26.7.2 上实测正常**——`IOAudioFamily` 跨版本仍是 **740.1**，`keepsyms=1` 仍在 boot-args，OC `MinKernel 25.0.0 / MaxKernel 25.99.99` 覆盖当前 Darwin 25.6.0，**加载顺序与依赖无需改动**（`OSBundleLibraries` 仍只 `as.vit9696.Lilu 1.7.1` + 4 个 kpi）。

## 1–8 项状态

| # | 项目 | 本期 | 证据 | 对本机判断 |
|---|---|---|---|---|
| 1 | P620 Metal | 无进展 | nullmoth 最新 v2.6.2(10-26)；#229 closed/1 评 | 维持封板，不动 |
| 2 | HDMI/DP 音频 | 无变化 | 26.7.2 里 `AppleGFXHDA` 仍 **550.1**，`IOPCIMatch` 仍只有 `9DC8/A348/38C8/9D71/34C8`，无 `0x06C8`；VoodooHDA 最新仍 v3.7.1-alpha(10-23) | 维持无解 |
| 3 | 内建麦克风 | 无利好 | 升级后 `SPAudio` 只剩 2 设备（内建输出/内建线路输入），**"内建麦克风"已不在列表** | 维持无解，走 TRRS/USB/蓝牙麦 |
| 4 | AirDrop/awdl | 无变化 | 本机 `ifconfig awdl0` = `does not exist`；itlwm `#1062` open/40 评/**upd 2026-09-14** 未动；laobamac/itlwm 最新 commit 仍 `738d4c6`(10-18) | 无 |
| 5 | 触摸板唤醒 | 无变化 | VoodooI2C v2.9.1(2024-11-06) = 本机版本 | 无 |
| 6 | 风扇控速 | 无变化 | 无新上游项目 | 无 |
| 7 | 睡眠功耗 | 已结案 | HDEF `AFGLowPowerState` 仍 `<000000000000>` = 0 | 不必再跟 |
| 8 | OTA delta | **★闭环（唯一利好）** | 见下节 | 已落地，无需动作 |

## 8. 26.7.2 升级复验（本期核心）

决定性证据来自 `/var/log/install.log` 的 `SUMacControllerDescriptor`：`productBuildVersion 25G332`、`prerequisiteBuild 25G241`、**`fullReplacement: NO`**、`originalUpdateType: Minor`、`downloadSize 1358475023`（≈1.27 GiB），资产路径 `updates.cdn-apple.com/2026FallSeed/patches/142-28282/…`。
`softwareupdate --history`：`macOS Tahoe 26.7.2  2026/10/27 11:55:00`。

| 复验项 | 结果 |
|---|---|
| 音频加载 | SimpleHDA **1.0.0** / AppleALC **1.9.9** / Lilu **1.7.3** 均 in-kernel；`IOAudioFamily 740.1` 未变 |
| 出声 | `SPAudio` 内建输出（默认+默认系统输出，源"耳机"）+ 内建线路输入在；`get volume settings` → `output volume:19, output muted:false` |
| 系统卷 | `Sealed: Yes`，新快照 `9D1CC6EA-6E9B-472C-B1B6-F8F9068D91FB`；`/S/L/E/AppleHDA.kext` 仍不存在 |
| 后续更新 | `softwareupdate --list` → `No new software available`（23 s）；gdmf `PublicAssetSets` macOS 最新 = 26.7.2 / 25G332，`27.2 (26B123)` 存在但**未推给本机** |

acidanthera 六件套官方 release 仍全部低于本机（OC 1.0.8 / Lilu 1.7.2 / VSM 1.3.8 / WEG 1.7.1 / AppleALC 1.9.8 / RestrictEvents 1.1.6）⇒ 按降权规则不计新鲜。

**结论：** 未驱动项 1–7 本期零推进，P620 的 `#229` 已 closed 满 7 天无任何维护者回应、nullmoth 无新版本可看，这条线事实上终止；唯一变化是本机已完成 26.7.2 升级，`fullReplacement: NO` 实证 delta 能力永久恢复且升级后音频与密封状态全部无损，第 8 项可以不再跟踪、下次更新照常直接装。
