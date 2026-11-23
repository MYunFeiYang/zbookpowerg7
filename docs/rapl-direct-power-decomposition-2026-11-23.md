# RAPL 直接功耗分解通道发现（2026-11-23 14:4x）

## 背景：用户"接受不了"触发的论证链回头审

十几轮一直把「卡包级 C3 = 3.6W 功耗地板」当基石，但 deepidle-power-audit §15 自己写过：
> C3 与 3.6W 的直接量化仍未做功耗对比，故不回到 >95%。

即**这个因果前提从未被直接测量过**。唯一的 C-state 判据 `CC7` 经历三次语义翻烧饼（§2.4→§33.1→§33.2），最后承认只是"退出 deep idle 的那个逻辑核的单核样本，未必代表 12 核"。用一个单核读数搭起的理论不该宣判"无解"。本轮目标：**直接测 3.6W 花在哪个部件**。

## 突破：本机 IOReport 暴露完整 RAPL + C-state + LTR 遥测（非 root，>95%）

此前文档反复称"macOS 侧无工具可达 / powerlog IOReport 空表 / LTR 用户态读不到"。**这是错的**——那是针对 powerlog 里另一子系统。本机 `libIOReport.dylib`（非 root 可加载）实际暴露：

- **组 `pmtelemetry_cpu` 子组 `msr`**（209 通道）：
  - 能量：`MSR_IA32_PKG_ENERGY_STATUS`（CPU 封装累计 J）、`PP0`（core）、`PP1`（GT/核显）、`DDR_ENERGY_STATUS`（内存）
  - 换算：`MSR_IA32_PKG_POWER_SKU_UNIT` 的 **bits 12:8 = ESU**，本机 =14 ⇒ 单位 1/2^14 J = **61.035 µJ/tick**（与 Linux 一手 0.000061035 系数逐位吻合）
  - C-state residency：`PKG_C2/C3/C6/C7/C10_RESIDENCY`(ns) + **每核** `CORE_C6/C7_RESIDENCY 0..5`
  - break cause：数十个 `PKGC_BREAK_CAUSE_*` 计数器（谁把包从深态打断）
- **组 `pmtelemetry_ltr`**（78 通道）：每 IP 的 Raw/Snoop/NoSnoop/Ignored LTR 值（GBE/XHCI/ME/CNV/SPE...）——即十几轮"读不到"的 LTR，IOReport 已遥测出来
- 组 `pmtelemetry_uncore`、`GPU C-States`、`Display`、`Battery`（后者只有 cycle count，电量仍需 pmset）

## 工具（本地 APFS，非 git）

- `~/automation-workspace/energy-enum.c` — 枚举全部 1876 通道
- `~/automation-workspace/pmdump.c`（/tmp/pmdump）— dump 各 pmtelemetry 组当前值
- `~/automation-workspace/energy-probe.c` — 双采样增量（清醒态自测用）
- `~/automation-workspace/energy-snap.c` — **单快照**（供睡前后各一次）

## 清醒态自校准（15s 增量，14:41 实测，全部自洽）

| 部件 | delta ticks | 功率(E SU=14) |
|---|---|---|
| PKG 封装 | 3,415,723 | 13.90 W |
| PP0 core | 2,238,145 | 9.11 W |
| PP1 GT | 563,714 | 2.29 W |
| DDR | 392,017 | 1.60 W |

PKG ≈ PP0+PP1+DDR+uncore，自洽；空闲 i7-10750H 数值合理 ⇒ 换算与读数确认（>95%）。

## 关键约束 / 待验证

1. **RAPL 32 位计数器**：约 0.976ms 更新、约 60s 重负载可溢出（Linux 一手）。本机 3.6W×8h ≈ 1.7G ticks < 2^32，**8h 睡眠不溢出**；短睡更安全。
2. **S0ix 期间 RAPL 是否继续累计**：国外一手（PCU 每 0.976ms 更新、与 C-state residency 同属 PCU 遥测）倾向会，但无直接先例。**这是唯一剩余不确定**。C-state residency 睡眠期累计已被 deep_idle_stats 反证成立。
3. 若睡眠期 RAPL 冻结 ⇒ delta=0，则本工具对该问题无效，需退回 PMIC/电池库仑计路线。

## 一次睡眠配合即可判决（预期结果 + 退路）

睡前后各跑 `./energy-snap <label>`，配合 `pmset -g batt` 电量。判决：
- **CPU PKG 增量 << 电池掉电总量**（如 PKG 只占 0.5W 而电池掉 3.6W）⇒ 「卡 C3=3.6W」被直接证伪，3.1W 在 CPU 之外（PCH/外设/屏/EC），**方向彻底翻转**，去查真正的耗电件（LTR 表已能读，配合定位）。
- **CPU PKG 增量 ≈ 电池掉电总量** ⇒ 卡 C3 坐实（首次直接量化），维持接受态但依据升级。
- **RAPL delta=0 / 异常** ⇒ 计数器睡眠冻结，工具对本问题无效，如实记档。

零配置改动、零 EFI 改动、纯只读。工具已全部自检通过，一次成功率已尽可能拉高。

## 14:45 首次配合"失败"诊断 + 全自动方案（14:50）

- **首次配合无效**（用户 14:45:33 before / 14:45:55 after，仅 22s）：`pmset -g assertions` 显示 `PreventUserIdleSystemSleep`（sharingd Handoff + useractivityd BTLEAdvertisement）挡空闲睡眠，且用户未合盖 ⇒ 机器全程醒着。硬证据：C-state residency 增量**全 0**、`deep_idle` 仍是历史 `0:11:28` 未动、AC 100% 未变。那 22s 的 PKG 17.09W 只是清醒态（刚跑完命令），**不是睡眠数据，不可用于分解**。但副产物有价值：证明 RAPL delta/换算正确（PP0 14.2W+GT 0.5W+DDR 1.3W 自洽）。
- **不再让用户手动合盖/掐表/拔电**（用户"配合优先级最低"铁律）。改为一条命令全自动脚本 `~/automation-workspace/power-auto-test.sh`：自检（root/RAPL 可读/参数合法）→ `pmset schedule wake "<now+M>" RAPL-POWER-TEST` 排 RTC 硬件闹钟（本机 powerlog 证实 calaccessd 的同类 alarm 能唤醒 S0ix，>85%）→ 采 before → `pmset sleepnow` 强制睡眠（绕过 idle assertion）→ 自动醒 → 采 after + 分解。**用户只需 `sudo .../power-auto-test.sh 20`，输一次密码，睡 20 分钟自动醒自动出结果。**
- 静态自检通过：zsh -n OK、非 root 正确拦截、非法参数拦截、无误排唤醒。sandbox 禁止 sudo，故脚本必须由用户在自己终端运行。
- 前提：RAPL 睡眠期累计 ~85%（清醒态/换算已坐实）；若醒后 delta=0 则工具无效、如实记档。
- **更新（14:55）**：用户"别搞自动，容易出错"⇒ 已删除 power-auto-test.sh，回到手动 before/after 两命令方式。

## 15:00 脚本审查 → 根本性单位 bug：residency 是 TSC ticks 不是纳秒（已修）
用户"只看脚本本身"⇒ 逐行审计 energy-snap.c + power-sleep-test.sh，修 4 处：

1. **★★根本 bug（>95%）：C-state residency 用 ÷1e9 当秒，虚高 2.59 倍。** Intel SDM Vol3C 一手原文：PKG/CORE residency MSR "Count at the same frequency as the TSC"。本机 `machdep.tsc.frequency=2592000000`(2.592GHz, i7-10750H base)。交叉验证：PKG_C3 累计 1.855e12 / 2.592e9 = 715.9s vs deep_idle 报 688s（偏差 4%，采样起点不同），证实 TSC 换算正确；旧算法 ÷1e9 得 1855s 明显错误。**影响**：此前所有直接读 MSR residency 后 ÷1e9 的秒数/占比全部高估 2.59 倍（sysctl deep_idle 的百分比是内核算好的，不受影响）。修法：energy-snap.c 新增输出 `TSC_HZ=<sysctl machdep.tsc.frequency>`，分解脚本读它、用 ticks/tsc 换算。
2. **ESU 解析失败（已修）**：快照行 `ESU=14 UNIT_J=0.000061035156` 因行尾浮点，正则 `[A-Za-z0-9_ .]+)=(-?\d+)$` 匹配失败，一直用硬编码默认 14；本次恰好对，换机即错。已加独立 `ESU=(\d+)` 匹配；篡改快照 ESU=16 验证确实从文件读。
3. **每核 C6 占比 >100%**：即便用 TSC 换算，core5 C6 仍 +2.09s > 墙钟 2s，印证 IOReport `CORE_C6_RESIDENCY 0..5` 口径非单物理核（6核12线程，疑 per-core 聚合双线程）。已去掉占比列、保留"非单核、仅相对参考"说明。
4. **回绕位数（已修）**：能量计数器 32-bit（delta32 加 2^32）、residency 64-bit（delta64 不加），此前统一按 32 位。ESU=14 满量程 262144J，3.6W 睡眠 20.2h 才回绕，本机场景不触发但已修正。
- 回归验证（真实 2s 快照）：PKG C2 +0.36s/17.8%（旧 0.92s/46.1%）；核心能量分解（PKG 14.97W 等）不受影响（走 ESU，与 TSC 无关）。
- 结论：**脚本核心能量分解正确可信；单位/解析/回绕 4 处 bug 全修复回归通过**。数据"不像睡眠"非脚本问题（那几秒里 PKG_C3 residency 增量=0，机器确实没睡）。
