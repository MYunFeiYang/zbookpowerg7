# 黑苹果（OpenCore）生态周报 · 2026-10-29

窗口 2026-10-28 09:15 → 10-29 09:11 ｜ 本机 HP ZBook Power G7 / macOS 26.7.2 (25G332)

**判断：无实质推进。** 唯一新增是 nullmoth v2.6.3（10-28），变更全在 Turing 及以上图形栈；SimpleHDA 连续 15 天零提交；未驱动清单第 1–8 项无一有突破。

## 0. NullMoth 专项（P620 的唯一变量）

| release | 日期 | 变更要点（读 body 原文） | 对本机是否有用 |
|---|---|---|---|
| **v2.6.3** | 2026-10-28T04:02Z | 14 项 Turing+ 图形栈修复：Lanczos 着色器被拒致 Infuse 停摆(#405)、Geekbench GPU/ML 全项可跑(#377/PR #385)、Unity WebGL 缓冲传参(#406)、Chrome WebGL2 丢上下文(#419/PR #418)、DaVinci 在 GTX 1660 Ti 不再启动崩溃、llama.cpp 输出归零(#401)、256MB BAR1 拖窗卡顿(#368/#399)、Dock/控制中心模糊与拖窗流畅(NvGfx)、ANGLE 走 Metal(PR #404)、显示器旋转(PR #398)、多屏 HDMI/DP 音频跟随正确显示器(PR #366)、亮度跨重启保持(PR #312)、活动监视器显示 GPU 占用(PR #380) | **无用**。README 仍 `Turing and newer: GTX 16, RTX 20/30/40/50, TITAN RTX, Quadro RTX, T-series`，依赖 GSP 固件 615.78.08；P620 是 GP107 Pascal，既不在列表也无 GSP |

- **#229**：`closed`（2026-10-21T22:56:52Z）、comments = **1**、`updated_at` 仍 10-21T22:56:52Z（**8 天零动**）、labels 空。维护者仅一句："Pascal cards (GTX 10xx, Quadro P-series) have no GSP firmware ... cannot be supported by this driver"。
- 全库搜 `Pascal`：total = 2（#229、#56 均旧议题），**零新议题**；open_issues = 235，10-27~28 新增 #415–#429 全是 RTX 功耗、eDP 高刷、GPU-P 等 Turing+ 话题。

## 0.5 SimpleHDA 专项（本机音频唯一依赖）

**无新 release，当前 1.0.0**（2026-10-14T17:27:32Z）；**无新 commit**（最新 `7517b04b` 10-14，已沉默 15 天）；**open issues = 0**（#1–#6 全 closed，最后 #6 于 10-24 结案）。`keepsyms=1`、`Lilu ≥ 1.7.1`、`MinKernel 25.0.0 / MaxKernel 25.99.99`、加载顺序均未变，内嵌 AppleHDA 仍 600.2 ⇒ 本机无需动作，风险只在「下一个大版本改 IOAudioFamily」。

## 1–8 项状态（只列有变化的）

| # | 未驱动项 | 本期证据 | 结论 |
|---|---|---|---|
| 1 | P620 Metal | v2.6.3 无 Pascal 条目，见上 | 封板不变 |
| 2 | HDMI/DP 音频 | v2.6.3 的 PR #366 属 **NVIDIA 卡**显示音频，与本机 Intel iGPU 无关；无新 macOS 版本 ⇒ `AppleGFXHDA` 550.1、`IOPCIMatch` 仍 9DC8/A348/38C8/9D71/34C8（缺 0x9B3E/0x06C8） | 无变化 |
| 3 | 内建麦 | AE30 SoundWire 无 Intel SST 驱动；SimpleHDA 新 issue 零新增 | 无变化 |
| 4 | AWDL/隔空 | itlwm 官方仍 v2.3.0(2024-06-09)；`laobamac/itlwm` 最新 commit 仍 `738d4c61`(10-18)，本周零提交；#1062 open/40 评/upd 09-14 | 无变化 |
| 5 | 触摸板唤醒 | **VoodooI2C 10-25 合并 PR #586**（`6be653a2`，新增 Tiger/Alder/Raptor Lake I2C+GPIO、含 Alder Lake-S 恢复处理），2025-11 以来首次代码推进；但**未发新 release**（tag 仍 v2.9.1 / 2024-11-06），新增芯片组不含 Comet Lake | 无变化，不动 |
| 6 | 风扇控速 | 无相关项目更新，HP EC 仍锁死 | 无变化 |
| 7 | 睡眠功耗 | 已结案（AFG=0），本期无新证据 | 无变化 |
| 8 | OTA delta | gdmf `PublicAssetSets` 仍 26.7.2/25G332（PostingDate 10-26，无更新版本）；`softwareupdate --list` = `No new software available`；27.2 (26B123) 在表但 Intel 不支持 | 无变化 |

**其他源**：acidanthera 六件套全部仍低于本机（OC 1.0.8 09-27 / Lilu 1.7.2 03-20 / VirtualSMC 1.3.8 09-27 / WhateverGreen 1.7.1 09-27 / AppleALC 1.9.8 09-27 / RestrictEvents 1.1.6 2025-07-07），按降权规则不报；VoodooHDA 仍 `v3.7.1-alpha`(10-23)，3.7.x 依旧不含 HDMI 管道自动激活。

**本机注**（非跟踪项，仅证据提示）：今晨 09:05 刚重启，`hibernatemode=25` 且 `-hbfxforce hfile=/var/vm/sleepimage` 生效，对应提交 `e4d32d4 / 1ed084c / 7a5fc09`（10-28 18:21 ~ 10-29 09:01）——S4 实验在跑，与封板清单冲突，下一次空闲睡眠可能触发休眠写入。

**结论：** 本周无任何利好——P620 随 v2.6.3 继续只在 Turing+ 里修图形栈、#229 已 8 天零动且官方定性"Pascal 无 GSP 固件、不可能支持"，SimpleHDA、HDMI 音频、AWDL、触摸板唤醒、OTA delta 全部原地不动；这台机器在 macOS 26 上已无待补的软件缺口，剩余缺失项（Pascal Metal、Intel HDMI 音频、SoundWire 麦克风、AWDL）均已封板，继续跟生态只用于防「音频/更新链路」回归，不值得再为缺失功能动配置。
