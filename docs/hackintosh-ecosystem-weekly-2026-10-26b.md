# 黑苹果生态跟踪简报 · 2026-10-26 09:07（同日复跑·增量版）
窗口 10-23 09:01 → 10-26 09:07 ｜ 基线 macOS 26.7.1 (25G241) / MacBookPro16,4 / OC REL-109 MOD ｜ 08:49 已出一期，本期补漏跟的 **VoodooHDA** 线
**一句话：nullmoth / SimpleHDA / acidanthera / itlwm 四源零变动，1–8 项无一项推进到「能用」；唯一新事实是 VoodooHDA —— 它给 #2 HDMI 音频首次提供一条能实装的路，但能纯 OC 注入的分支恰好砍掉了 HDMI 管道激活，净结果仍不可用。**

## 0. NullMoth 专项
- **本周无新 release**，最新 **v2.5.5（2026-10-25T21:08Z）**，repo `pushed_at` 同刻；v2.5.4/v2.5.5 均 Turing+ 编解码/远控/ANGLE，不涉 Pascal（上期已展开）。
- **#229**：closed / completed，comments **1（未增）**，updated **2026-10-21T22:56:52Z**，labels 空，无新维护者回应。全库检索 `pascal` 仅 #229+无关 #56，`Quadro` 命中 #229/#133/#132/#78 ⇒ 无重开、无同类新 issue。

## 0.5 SimpleHDA 专项
- **无新 release**：v1.0.0（2026-10-14T17:27Z），`pushed_at` 同为 10-14，`archived=false`；`keepsyms=1` 依赖、`MinKernel/MaxKernel`、加载顺序、内嵌 AppleHDA 版本**全部未变** ⇒ 音频无需重验。
- **#6 closed（2026-10-24T14:45Z）两条新硬料**：① 改 AppleALC Info.plist 中该 layout 的 `AFGLowPowerState`→`<00000000>` 可把 HDEF 中断 4300/s 打到 **0/s**、kernel_task 465→15 ms/s、6.6W→3.7W，但 DAC/引脚卡在 D3、无声、输入引擎消失 ⇒ 不可用；② laobamac 表态「SimpleHDA 只是恢复 AppleHDA，原版有问题我无能为力」，报告者最终换 VoodooHDA 3.6.5 收场。

## 新增跟踪线：CloverHackyColor/VoodooHDA（此前漏跟）
| 版本 | 日期 | 要点 | 对本机 |
|---|---|---|---|
| v3.7.1-alpha | 2026-10-23T16:32Z | 把 Apple IOAudioFamily 740.1 源码编进 kext，依赖只剩 IOPCIFamily+KPI ⇒ **可纯 OC 注入、SIP 全开可用**（README 实测 Tahoe 26.7.1 / OC 1.0.7 / csr=00000000）；changelog「repair AMD HDMI」「resolve Intel HDMI problem by DeeVeeDee」 | 否。README「Known limits」明写 **HDMI pipe auto-activation 不在 3.7.0x**，与 changelog 冲突，未实测不定论 |
| Release368 (3.6.8) | 2026-09-18 | 「Patch the connection list for intel hdmi codecs」by Zenith432 | 理论对口，但只能 `/Library/Extensions` |
| Release366 (3.6.6) | 2026-08-30 | 「Added support for Intel HDMI audio on HD630 and up」by Zenith432 | 同上 |

**判定：HDMI 音频实装窗口在 3.6.6–3.6.8**（保留 IOGraphicsFamily 依赖 ⇒ 保留管道激活），装法 `/L/E` + SIP 降 0xA85 + 用户批准 + 辅助 KC 重建（不动系统卷，seal 不受影响）。**但不值得动**：① `IOProbeScore=99000` 确定性抢 HDEF，README 要求卸掉 AppleALC 等全部音频 kext ⇒ 现役 SimpleHDA+AppleALC（layout 7 / ALC236 HP-240G8）全套作废；② ALC236 在 VoodooHDA 属 codec 彩票，仓库内无 ALC236+HP 成功案例；③ HDMI 视频通路本身未证实（P620 已禁，若 HDMI 口接独显则连画面都没有）；④ 3.7.1 自标「需硬件验证后才能日用」。

## 逐项判定（1–8）
| # | 变化 | 证据 | 判断 |
|---|---|---|---|
| 1 P620 | 无变化 | #229 closed 10-21，0 新评论；v2.5.4/2.5.5 不涉 Pascal | 不动，永久零 Metal |
| 2 HDMI/DP 音频 | **首次出现替代路线** | VoodooHDA 3.6.6/3.6.8；AppleGFXHDA 550.1 `IOPCIMatch` 仍仅 0x9DC8/0xA348/0x38C8/0x9D71/0x34C8，本机 IGPU 实测 **device-id=0x9B3E**、`kmutil` 确认未加载 | 仍不建议动；**基线更正**：上期写的 0x9B54 实为 `PCI0@0` Host Bridge（`pci8086,9b54`，class 060000）的 ID，IGPU 是 0x9B3E（`device-id=9b3e0000`），两者都不在匹配表 |
| 3 内建麦 | 无变化 | SoundWire AE30 需 Intel SST；VoodooHDA 同为 HDA 驱动，碰不到 `HDAS.SNDW` | 无解，维持 3.5mm/USB/蓝牙 |
| 4 AirDrop 族 | 无变化 | itlwm #1062（open，09-14）Tahoe 无 awdl0 | 系统级缺失 |
| 5 触摸板唤醒 | 无变化 | VoodooI2C v2.9.1（2024-11-06） | 不动 |
| 6 风扇控速 | 无变化 | HP EC 锁死 | 不动 |
| 7 睡眠功耗 | **本轮无法判定** | HDEF `AFGLowPowerState=03000000` 条件具备；但 kernel_task 50–53% 伴 WindowServer 81%、压缩内存 5.3G、load 7.5 ⇒ 负载来源非音频，代理指标失效 | 仍需人工 `powermetrics` |
| 8 OTA | 无变化 | gdmf `PublicAssetSets[macOS]` 最新仍 26.7.1/25G241/PostingDate 2026-09-28，无 26.7.2；27.0.1(26A434) 在列但不支持 Intel | 下次更新先看包体大小 |
| 其余源 | 无变化 | OC/Lilu/WEG/VSMC/AppleALC/RestrictEvents 官方 1.0.8/1.7.2/1.7.1/1.3.8/1.9.8/1.1.6 无一追平本机；itlwm 仍 738d4c6(10-18)；OCLP 3.0.0-rc.3(10-08,pre) 已卸载 | 无需动作 |

## 顺带发现：本机当前负载异常（与音频无关）
WindowServer 持续 80–81% CPU（累计 11h23m）、PhysMem 16G 用尽（压缩 5.32G、剩余 74–104MB）、load 7.2–7.5。污染第 7 项与整机功耗判断，建议单独排一次。

**结论：本周四源零变动，P620 与 HDMI 音频均无可用进展 —— VoodooHDA 3.6.6+ 是 #2 的第一条真实路线，但代价是废掉现役音频栈、且 HDMI 画面通路未证实，判定不装；更该先处理的是 WindowServer 81% + 内存吃满这一独立异常。**
