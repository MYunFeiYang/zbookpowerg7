# 黑苹果生态周报 · 2026-10-21（窗口 10-14 → 10-21，09:45 修订）
**一句话判断**：#1–#8 无实质突破。NullMoth 一周连发 8 版，Pascal 依旧零支持且已被判为结构性不可行；唯一有变化的是 Wi-Fi 驱动同 tag 重构建，但逐行核实后与本机关联度很低。

## 0. NullMoth 专项（repo: nullmoth/nvidia-macos-driver）
**#229 状态：open｜评论 0（无增减）｜无 label｜updated 2026-10-16（= 创建日）｜无维护者回应 → 不构成一级信号。**

| 版本 | 日期 | 变更要点（读 body） | 对本机 |
|---|---|---|---|
| v2.3.4 | 10-17 | 早测预发布：帧同步等待改 1 个刷新周期、Turing 登录黑屏、混合显卡不再拷贝他卡显存 | 无用 |
| v2.3.5 | 10-17 | 登录界面黑屏 60 秒修复 | 无用 |
| v2.3.6 | 10-18 | 拖窗/鼠标不再阻塞合成器、Chrome 默认走 ANGLE Metal、Dock 徽标渲染 | 无用 |
| v2.3.7 | 10-18 | 安全版：H.264/HEVC conformance window 越界、framebuffer 泄漏内核地址、固件目录提权 | 无用 |
| v2.4 | 10-19 | 预发布，已被 2.4.1 取代（更新后黑屏） | 跳过 |
| v2.4.1 | 10-19 | RTX 20/30 硬件编码、Tahoe 图标与 Liquid Glass 修复；自身黑屏 → 被 2.4.2 取代 | 跳过 |
| v2.4.2 | 10-19 | 修 2.4/2.4.1 黑屏与启动卡 verbose | 无用 |
| v2.4.3 | 10-20 | 修 #295「thread_call group 'high' reached max thread cap」冻结+panic；PR #294 着色器哈希复用 | 无用 |

- 支持范围（v2.4.3 时点）：README「Supported cards are Turing and newer: GTX 16, RTX 20/30/40/50」。结构性死因（两条独立证据）：内核侧跑 NVIDIA open kernel modules r610（本仓 README 明写），而 NVIDIA open-gpu-kernel-modules README 明写「Turing or later」；#125 评论（TararaDotJoshua，CONTRIBUTOR，2026-10-14）原话："needs the GSP firmware processor that only Turing (GTX 16 / RTX 20) and newer cards have. Pascal doesn't have one, so the driver has nothing to run on."
- 判定：**P620 封板维持**——不是"还没做"，是"缺硬件前提（GSP）"。
## 1–8 清单（只列变化）
| # | 项 | 本周状态 | 证据 |
|---|---|---|---|
| 1 | Pascal 独显 | 无解（结构性） | 同上；#229 零回应 |
| 2 | AppleHDA/AppleALC | 无进展 | OCLP PR #1176（draft，补丁本体未含）closed 未合并 2026-10-03；3.0.0-rc.3（10-08）变更日志无音频项 |
| 3 | HDMI 音频 | 无变化 | WEG 官方仍 1.7.1（2026-09-27） |
| 4 | AirDrop/Sidecar 等 | 无变化 | itlwm 官方 v2.3.0（2024-06-09）未动 |
| 5 | 触摸板唤醒 | 无变化 | VoodooI2C 2.9.1（2024-11-06），项目停更 |
| 6 | 风扇控速 | 无变化 | 无上游相关提交 |
| 7 | 睡眠功耗 | 无变化 | 无上游相关提交 |
| 8 | OTA | 机制无变化；26.7.2 仍在 RC3（25G330，2026-10-19），纯安全更新 | 当前公开版仍是 26.7.1 (25G241) |

acidanthera 系：OpenCorePkg 1.0.8 / Lilu 1.7.2 / WEG 1.7.1 / VirtualSMC 1.3.8 均未追平本机版本 → 按规则全部归"无变化"。

## Wi-Fi：同 tag 重构建（laobamac/itlwm v2.4.0-alpha，10-18 tip=738d4c6）——逐行核实后仅部分相关
- `bbe368e`（10-14，#22）改 `itlwm/hal_iwm/`（rs.cpp / rs.h / mac80211.cpp / ItlIwm.hpp），只作用 **iwm 卡**（7260/7265/8260/8265/9260/9560）；本机 AX201 走 **iwx**（hal_iwx）⇒ **与我们无关**。
- `738d4c6`（10-18）改 `itlwm/hal_iwx/ItlIwx.cpp` 的 `iwx_tvqm_enable_txq()`，仅 1 行 2 符号：`fwqid <= IWX_QID_MGMT` → `fwqid <= sc->first_data_qid`（TX 队列使能边界校验，无新功能）⇒ 落在本机代码路径上，但属常量语义替换。
- 本机实测：`ioreg` IOKitDiagnostics ⇒ ItlIwx=1 / ItlIwm=0；`system_profiler` 驱动自报 **`itlwm: 2.4.0_d695c97 fw: 68.01d30b0c.0`**；Connected、802.11ac 5GHz ch44 20MHz、Tx 173Mbps MCS8；uptime 1d13h；DiagnosticReports 无 AirportItlwm 相关 panic。
- 未取到：`first_data_qid` 赋值与 `IWX_QID_MGMT` 数值（源文件 483KB/300KB，抓取被截断）⇒ 该行是否等价 no-op **未证实**，不推测。判断：**不必特意换**，下次因他故动 EFI 时顺手替换即可。

**结论**：本周对 P620、音频、AirDrop、触摸板唤醒、风扇、睡眠、OTA 七项全无利好；Wi-Fi 那个"更新"拆开看只与本机擦到 1 行无功能性的队列校验，不构成换驱动的理由——本轮唯一真实产出是把上一轮"值得换"修正为"不换"。

## 事后修订（2026-10-22）——两处更正 + 已换驱动

1. **更正：issue #22 与本机无关。** 原记录只写了"#22 是 rate-control 死锁"，没查报告人硬件。实查 `laobamac/itlwm#22` 标题
   `Intel 8260 panics on boot due to holding a spinlock when associating`，报告人 zearp、网卡 **8260**、macOS 26.7.1、kext 由 **d695c97** 构建。
   panic 栈完整落在 iwm 分支：`rs_drv_rate_init` ← `iwl_mvm_rs_rate_init` ← `ItlIwm::iwm_auth` ← `ItlIwm::iwm_newstate_task`（符号全为 `iwl_mvm_*` / `ItlIwm`）。
   本机 AX201 走 `ItlIwx`（`ioreg` 实测 ItlIwx=1 / ItlIwm=0）⇒ **该 panic 我们遇不到**。此前"本机 d695c97 正是 #22 受害版"的说法**作废**。
   （另注：`OpenIntelWireless/itlwm#22` 是同名不同库的另一件事——`Won't connect to wifi`，AC 3165，连接失败，与 panic 无关。）
2. **更正：`738d4c6` 的实质。** 只改 `itlwm/hal_iwx/ItlIwx.cpp` 1 行：`iwx_tvqm_enable_txq()` 里
   `fwqid <= IWX_QID_MGMT` → `fwqid <= sc->first_data_qid`，即 TX 队列使能边界校验收紧（越界直接 `-EIO`）。落在本机代码路径，但**无新功能、无接口变化**。
3. **已执行**（commit `c743a6d`）：换装 `AirportItlwm-Tahoe-v2.4.0-RELEASE-alpha-738d4c6.zip`
   （sha256 `25680aa39ddd79b205141875b261bdcc28bea150d13f27787b3c215555daa00f`，15,097,966 B）。
   二进制 sha256 `7afa4b14` → `259bac94`（+3016 B），`Info.plist` 逐字节相同、两侧均 RELEASE。
   理由不是"修 panic"（见 1），而是顺手把 iwx 路径上那行边界校验补齐；代价为零（config 只改 Comment）。

