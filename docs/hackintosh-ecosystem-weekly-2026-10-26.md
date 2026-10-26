# 黑苹果生态跟踪简报 · 2026-10-26

窗口 10-23 09:01 → 10-26 08:49 ｜ 基线 macOS 26.7.1 (25G241) / MacBookPro16,4 / OC REL-109 MOD

**一句话：1–8 项无一项推进到「能用」；唯一实质变化是 macOS 27 确认不支持 Intel —— 26.x 成为终点线，第 8 项的「26→27 兼容性」跟踪点作废。**

## 0. NullMoth 专项（P620 唯一可能转机，每版必报）

| 版本 | 发布日期 | 变更要点 | 对本机有用？ |
|---|---|---|---|
| v2.5.4 | 2026-10-24 07:12Z | 独显单卡机不再黑屏循环（WindowServer 每次 `Failed to create MetalDevice` 后改走固件 framebuffer 兜底）；Discord 经 ANGLE 获 Metal (#348)；沙盒应用改走系统解码服务 (#349)；安装器 ACL/kext 诊断增强 | 无。Pascal 无 GSP 固件，驱动根本不认卡 |
| v2.5.5 | 2026-10-25 21:08Z | 修 2.5.4 的 Discord 解码回归；远程桌面 H.264/HEVC 关键帧标记修复 (#388/#358)；屏幕共享不再黑屏；Brave/Edge 经 ANGLE 获 Metal (PR #381)；小 BAR1 卡 NVAccel 日志降噪 (#387) | 无。同上 |

**#229 状态**：closed / completed，评论数 1（未增），2026-10-21T22:56Z 后无任何新动静、无 label 变化。维护者 nullmoth(OWNER) 原话：Pascal 无 GSP 固件，本驱动运行 NVIDIA 开放内核模块，需要 GSP ⇒ Pascal 不可能被支持。
**判定：P620 零 Metal 已永久封板，不再作为「待观察」变量。**

## 0.5 SimpleHDA 专项（本机音频唯一依赖）

- **无新 release，当前 v1.0.0（2026-10-14T17:27Z）**。repo `pushed_at` 同为 10-14，代码零变动，`archived=false`。内嵌 AppleHDA 版本、`MinKernel/MaxKernel`、加载顺序、`keepsyms=1` 依赖**全部未变**，音频无需重新验证。
- **新 issue #6（closed 2026-10-24T14:45Z）值得注意**：Dell 7430 / ALC289 / layout 93 + SimpleHDA 1.0.0，空闲时 HDEF 中断 4300–4500/s、kernel_task 440–465 ms/s、整机 6.6W（关音频 3.7W）、风扇吵。报告者定位 `AFGLowPowerState=3` 来自 **AppleALC 的 layout 数据**（DeviceProperties 注入 0 被覆盖）；laobamac 回复「SimpleHDA 只是恢复 AppleHDA，原版若有问题我无能为力」⇒ **不打算修**。
- **本机实测**：HDEF `AFGLowPowerState = 03000000`，HDAConfigDefault「ALC236 for HP-240G8」亦为 3 ⇒ **触发条件具备**。但当前 15min load=27.35（duetexpertd / mds_stores 尖峰），**无法判定本机是否存在同款中断风暴**（powermetrics 需 root，本自动化无 sudo 密码）。手动复测命令：
  `sudo powermetrics --samplers interrupts,tasks -i 5000 -n 3 | grep -iE 'HDEF|kernel_task'`
- 顺带纠错（实测）：本机 HDEF `layout-id = 7`（HDAConfigDefault LayoutID=7，匹配 "ALC236 for HP-240G8 by 8DireZ3"），任务书写 55 与实测不符，不影响出声。

## 逐项判定（1–8）

| # | 项目 | 本周变化 | 证据 | 对本机判断 |
|---|---|---|---|---|
| 1 | P620 独显 | 无变化 | #229 closed（10-21），0 新评论；v2.5.4/2.5.5 均不涉 Pascal | 不动，永久零 Metal |
| 2 | HDMI/DP 音频 | **根因更正** | `/S/L/E/AppleGFXHDA.kext`(550.1) 的 `OSBundleLibraries` 不含 AppleHDA；`IOPCIMatch` 仅 0x9DC88086 / 0xA3488086 / 0x38C88086 / 0x9D718086 / 0x34C88086，本机 IGPU device-id=**0x9B54** | 与 SimpleHDA 无关；要动只能伪造 device-id 到 0x9DC8，会连累现役 framebuffer ⇒ **封板** |
| 3 | 内建麦 | 无变化 | 检索无 Intel SST / SoundWire 的 macOS 驱动方案 | 维持 3.5mm / USB / 蓝牙替代 |
| 4 | AirDrop·Sidecar·连续互通 | 无变化（根因首次有实证） | itlwm **#1062**（open，09-14，40 评）：Tahoe 26.5+/26.6 下 Intel 网卡 `ifconfig awdl0` → "does not exist"，标准 OCLP 与 OCLP-Mod 3.1.9 皆同 | 系统级缺失，非本机配置问题；无修复 PR |
| 5 | 触摸板唤醒 | 无变化 | VoodooI2C v2.9.1（2024-11-06）无新版 | 不动 |
| 6 | 风扇控速 | 无变化 | HP EC 锁死，无新项目 | 不动 |
| 7 | 睡眠功耗 | **新线索** | SimpleHDA #6：6.6W → 3.7W（差 2.9W，纯音频空转） | 待复测；若成立，3.885W 中或有 2–3W 属音频空转 |
| 8 | OTA / 更新 | 跟踪点②作废 | macOS 27 不支持 Intel（support.apple.com/127255） | 26.x 即终点，无需再防 27 兼容；本机 `softwareupdate --list` 当前「无服务器响应」，delta 未验证 |

## 全局变化：macOS 27 只支持 Apple silicon

- macOS 27 Golden Gate **27.0（2026-09-14）/ 27.0.1（2026-09-28）**已出现在 Apple 公开资产表（gdmf `PublicAssetSets`）与官方兼容页：列表**只有 Apple silicon**，Intel 全系止于 26 Tahoe；多家独立追踪一致称 Intel 安全更新约延续到 2028。
- 对本机：① 26.x = 最后一条线，macOS 侧剩余维护窗口约 2 年，长期投入产出比进一步下降；② 第 8 项「26→27 时 SimpleHDA 内嵌 AppleHDA 600.2 是否匹配」永久无需考虑；③ **新风险（推断，未实测）**：`revpatch=sbvmm` 的作用是让不支持机型也能看到 OTA，若软件更新里冒出 27.x，装上即无法启动 —— 下次更新先确认版本号必须是 **26.x**。

## 其余源

| 源 | 最新官方 | 本机版本 | 判定 |
|---|---|---|---|
| OpenCorePkg / Lilu / WEG / VirtualSMC / AppleALC / RestrictEvents | 1.0.8(09-27) / 1.7.2 / 1.7.1 / 1.3.8 / 1.9.8 / 1.1.6 | REL-109 MOD / 1.7.3 / 1.7.2 / 1.3.9 / 1.9.9 / 1.1.7 | 无一追平，无变化 |
| itlwm | laobamac 分支 v2.4.0-alpha(10-11)，最新 commit 738d4c6(10-18)；上游 v2.3.0(2024-06-09) | 2.4.0-alpha @738d4c6 | 无变化 |
| OCLP | 3.0.0-rc.3(10-08, prerelease) | 已整体卸载 | 无变化，不在推荐路线 |

**结论：P620 与 HDMI 音频本周正式封板、无实质利好；唯一值得动手的是按上面命令手动验一次本机音频空闲中断（若成立可解释 3.885W 里 2–3W 的空转）；另须记住 macOS 27 起根治性地不支持 Intel，26.x 就是这条线的终点。**
