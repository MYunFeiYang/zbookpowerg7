# 黑苹果生态周报 · 2026-10-30 09:06

窗口 2026-10-29 09:11 → 10-30 09:06｜本机 26.7.2 (25G332)、seal Yes、SIP 0xFFF、hibernatemode 0
**判断：八项未驱动清单零解决。唯一实质新信息是 #4 冒出一条 Intel 网卡 AWDL 路线（AirPlay/镜像可用，AirDrop 明确不在范围），但前置要重开 root patch —— 对本机不值得。**

## 0. NullMoth 专项（P620 唯一希望，逐版必报）
| 版本 | 日期 | 变更要点 | 对本机 |
|---|---|---|---|
| v2.6.4 | 2026-10-29T02:08Z | WebGL2 sampler 数组各元素拿到独立状态（three.js 双阴影灯不再丢 context，#426）；纹理数组下标修正（此前恒读第 0 个）；识别旧 Metal 工具链直写 sampler 的 shader（Machinarium） | 无 —— 全为 Turing+ 图形栈 |

- README 支持面仍 `Turing and newer: GTX 16 / RTX 20/30/40/50 / TITAN RTX / Quadro RTX / T-series`，内核驱动仍 GSP 615.78.08。
- `#229` 仍 **closed / completed**、评论 1、`updated_at` 停在 2026-10-21T22:56Z（**9 天零动**）、无 label 变化；维护者结论不变：Pascal 无 GSP 固件 ⇒ 本驱动不支持。
- 全库 Pascal 搜索 total=2（#229 + 无关的 #56），`GP107` / `P620` 命中 0；GTX10 相关只剩 #14(open/2 评)、#1(open/5 评)，均无维护者回应（末条为用户 10-22 / 10-15 留言）。open_issues 253。
⇒ P620 **无任何新利好**，封板判定维持。

## 0.5 SimpleHDA 专项（本机音频唯一依赖）
- **无新 release，当前 v1.0.0（2026-10-14T17:27Z）**；无新 commit（最新 `7517b04b` 10-14）；open issues = 0，沉默 16 天。
- 本机实测在载 `cn.laobamac.SimpleHDA (1.0.0)`，IOAudioFamily 仍 **740.1**（未跨版本变动），AppleALC 1.9.9 / Lilu 1.7.3 正常 ⇒ 无 `keepsyms=1` 依赖变化、无重新验证需求。

## ★ 本期唯一新发现：#4 出现 Intel 网卡 AWDL 路线
`kgp-macPro/AirportItlwm-Tahoe`（与 laobamac 分支不同的独立项目，bundle 同为 `com.zxystd.AirportItlwm`）
| 项 | 事实 |
|---|---|
| release | v1.0.0（2026-09-14，非 prerelease）；v1.1.0-beta.1（2026-10-20T23:33Z，prerelease）；仓库今日 10-30T01:06Z 仍有 commit（BE200 alpha 公告，与本机无关） |
| 已证实能力 | `awdl0` 活跃 + `IO80211P2PInterface` + **双向 AirPlay / 屏幕镜像**；物理合格机仅 **AX210 (8086:2725)**，Tahoe 26.6.2 双配置过 release gate，26.7 只算"额外范围性 PASS" |
| 明确**不**含 | README 原文：does **not** claim to restore **AirDrop、Continuity Camera、Personal Hotspot**，列为 "future development gates" |
| 前置硬条件 | 需 `kgp-macPro/OCLP-CustoMac 3.0.3` + 其 Skywalk 替换 + AMFIPass.kext（`-amfipassbeta`）⇒ **必须重开 root patch**；AX201 仅列在 beta 对照组，10-22 已撤回其 DMA 模式指引（"does not establish general AX201 mapped-mode support"） |
| 本机现状 | `ifconfig awdl0` = does not exist（复核）；现用 laobamac 2.4.0 |
| 判断 | **不动**。收益只有 AirPlay/镜像，我们关注的 AirDrop / Sidecar / 通用控制 / 连续互通相机四项一个都没解决；代价是 seal 破坏 ⇒ full 更新回来、拉回已卸载的 OCLP 工具链。 |
## 八项清单状态
| # | 项目 | 本期 |
|---|---|---|
| 1 | P620 Metal | 封板（#229 零动，v2.6.4 无 Pascal） |
| 4 | AirDrop/Sidecar/UC/相机 | awdl0 可修但不解决这四项，见上表 |
| 8 | OTA delta | 无变化：gdmf 仍 26.7.2 / 25G332（PostingDate 10-26），`softwareupdate --list` = No new software，无新版可验 |
| 2 / 3 / 5 / 6 / 7 | HDMI 音频 / 内建麦 / 触摸板唤醒 / 风扇 / 睡眠功耗 | **无变化**：AppleGFXHDA 550.1 且 IOPCIMatch 仍无 0x06C8；VoodooHDA 仍 v3.7.1-alpha(10-23)、未加回 IOGraphicsFamily 管道激活；VoodooI2C 最新 commit 仍 `6be653a2`(10-25)、tag 仍 v2.9.1(2024-11-06)；AE30 SoundWire 无新项目；3.885 W 基线不变 |
- acidanthera 六件套官方仍全部低于本机（OC 1.0.8 / Lilu 1.7.2 / VSM C 1.3.8 / WEG 1.7.1 / ALC 1.9.8 / RestrictEvents 1.1.6，后者 commits 最新仍 2025-07-13）⇒ 一律记无变化；itlwm 官方 2.3.0(2024-06-09)、laobamac 最新 `738d4c61`(10-18) 未动。
- 本机状态（非跟踪项）：`hibernatemode` 已回到 **0**、boot-args 无 `-hbfxforce` ⇒ 上期在跑的 S4 实验已回退，BIOS POST 005 风险解除。

**结论：** 八项全无实质推进，P620、HDMI 音频、内建麦维持封板；本期唯一新信息是 Intel 网卡可换到带 `awdl0` + AirPlay/镜像的 `kgp-macPro/AirportItlwm-Tahoe`，但它不修 AirDrop/Sidecar/通用控制/连续互通相机，且要重开 root patch、拿 seal 与 delta 更新能力去换，不值得动 —— 本机维持现状。
