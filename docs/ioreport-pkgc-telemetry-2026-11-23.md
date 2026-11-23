# IOReport pmtelemetry：macOS 自带的封装 C-state 否决点取证（2026-11-23）

> 目的：给「PC6 到不了」这条结论补上**直接观测**，且不引入 Linux / U 盘 / 重启。
> 结论先行版见文末「判读」；数值全部来自本机实测，采样时刻 2026-11-23 19:10~19:25，开机时刻 18:45:04。

## §1 为什么之前没有这个数据

历史排查用的两个口子都够不到「PCU 为什么不肯进 PC6」：

| 口子 | 能看到什么 | 缺什么 |
|---|---|---|
| `sysctl machdep.xcpm.deep_idle_stats` | 包级 C3/C6–C10 驻留百分比 | **不报 Core C6**，且无「为什么不进」的原因 |
| `powerlog PLMacCPUGPUAgent_...PackageEnergyCState` | PC2/3/6/7/8/9/10 驻留（事后重建） | 同样只有结果，没有否决原因；且只能事后读 |

`turbostat` / `powertop` / Intel S0iX Selftest **全部只能跑 Linux**；macOS 侧长期被认为"没有等价物"。
**这个判断是错的**：macOS 的 IOReport 里有一组 Apple 自己的 PM 遥测通道，非 root 可读，实时。

## §2 工具（本机自写，零依赖）

`~/automation-workspace/pmc-probe.c` → `pmc-probe`，dlopen `/usr/lib/libIOReport.dylib`，三种模式：

```sh
./pmc-probe list                     # 列出全部 group 与通道数
./pmc-probe dump  <group子串>         # 打印该 group 全部通道当前值
./pmc-probe delta <group子串> <秒>    # 采样两次，只打印增量 != 0 的通道
```

发现的相关 group（总共 1533 个通道）：

| group | 通道数 | 内容 |
|---|---|---|
| `pmtelemetry_cpu / cstate_counter` | 74 | **封装 C-state 进入计数、break cause、BCLK 降级原因** |
| `pmtelemetry_cpu / msr` | 102 | PKG/CORE 驻留、RAPL 能量、MPERF/APERF 类计数器 |
| `pmtelemetry_cpu / msr limits` | 32 | IA/GT 的限频原因位图 |
| `pmtelemetry_ltr` | 78 | **每个 PCH IP 的 LTR（延迟容忍）寄存器值 + ignore 位索引** |

## §3 实测数据一：封装 C-state 进入次数（自开机累计）

| 通道 | 值 | 含义 |
|---|---|---|
| `PKGC_C0_ENTRANCE_COUNTER` | 33,685 | 进 C0（即被唤醒）次数 |
| `PKGC_C2_ENTRANCE_COUNTER` | 34,417 | 进 C2 及更深次数 |
| `PKGC_C3_ENTRANCE_COUNTER` | **732** | 进 C3 及更深次数 |
| `PKGC_C6_ENTRANCE_COUNTER` | **0** | — |
| `PKGC_C7 / C8 / C9 / C10_ENTRANCE_COUNTER` | **0 / 0 / 0 / 0** | — |
| `PKGC_RING_C7_ENTRY_COUNTER` | **0** | 环形互连进 C7 次数，同样为 0 |

对应的 MSR 驻留（同一时刻，单位按通道原样）：

| MSR | 值 |
|---|---|
| `MSR_IA32_PKG_C2_RESIDENCY` | 71,632,099,760 |
| `MSR_IA32_PKG_C3_RESIDENCY` | 420,062,032 |
| `MSR_IA32_PKG_C6 / C7 / C8 / C9 / C10_RESIDENCY` | **全 0** |
| `MSR_IA32_CORE_C6_RESIDENCY 0..5` | 非 0（核心确实在 C6） |
| `MSR_IA32_CORE_C7_RESIDENCY 1..5` | 非 0（~1.36e9 量级，远小于 C6） |

⇒ 与 11-23 早先的 powerlog 结论完全一致：**核心在 C6、封装只到 C3**。这次是三方独立来源（sysctl / powerlog / IOReport MSR 直读）。

## §4 实测数据二：★ 封装为什么不往下走（本次核心发现）

`cstate_counter` 里有一组 **BCLK 降级原因** 计数器。BCLK 关断是 PC3→PC6 的必经动作：

| 通道 | 值 |
|---|---|
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` | **732** |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_ACCORDING_TO_TARGET` | 0 |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_FLOWPEND` | 0 |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_NOT_ENOUGH_TIME` | 0 |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_PCU_NOT_DRAINED` | 0 |
| `PKGC_BCLK_RESOLVE_CAUSE_*`（10 个全项） | 全 0 |

**`732` 与 `PKGC_C3_ENTRANCE_COUNTER` 的 `732` 完全相同**，而其余所有降级/解析原因全为 0。
⇒ 自开机以来，封装**每一次**尝试关 BCLK 都被同一个原因打回：**IOSF 未 block**，退回到 C3。
没有第二条原因参与，也没有一次成功。

## §5 实测数据三：120 秒活体增量（证明不是开机锁存值）

`./pmc-probe delta pmtelemetry 120`（清醒空闲，非睡眠）：

| 通道 | 120s 增量 |
|---|---|
| `PKGC_C0_ENTRANCE_COUNTER` | +135 |
| `PKGC_C2_ENTRANCE_COUNTER` | +135 |
| `PKGC_C3_ENTRANCE_COUNTER` | **+0** |
| `PKGC_C6_ENTRANCE_COUNTER` | +0 |
| `PKGC_BREAK_CAUSE_SNOOP_TIMER_NONZERO` | +1,624 |
| `pmtelemetry_ltr / CNV Raw` | −32,131,130（WiFi 的 LTR 在动 ⇒ 表是活的） |

⇒ 计数器确实是活的；清醒态下封装在 C0↔C2 之间抖动，**连 C3 都不进**，主要打断原因是 `SNOOP_TIMER_NONZERO`（缓存一致性 snoop 计时器非零）。

## §6 实测数据四：LTR 表（每 IP 延迟容忍）

只列非 0 的 IP，其余（SPA/SPB/SATA/SPC/HDA/LPSS/SPD/ESPI/SCC/ISH/EMMC/UFS/PEG0-2）全 0：

| IP | Raw | Snoop | NoSnoop | Ignore 位索引 |
|---|---|---|---|---|
| GBE（千兆网） | 2,293,860,537 | 189,440 | 189,440 | 3 |
| SPE（音频 DSP） | 2,286,258,245 | 70,656 | 70,656 | 13 |
| CNV（WiFi） | 2,323,090,039 | 646,144 | 646,144 | 10 |
| ME（管理引擎） | 134,219,776 | 0 | 0 | 6 |
| **XHCI（USB）** | **34,976** | 163,840 | 0 | **4** |

- 三张大值（GBE/SPE/CNV）在 2.29e9 量级且 CNV 会随负载变动 ⇒ 是活值，量级上属"接近无约束"。
- **XHCI 是唯一"紧"的**：34,976，比其余小 4~5 个数量级。
- `Ign` 列不是状态而是**该 IP 在 LTR_IGNORE 寄存器里的位号**（0..19，本机实测 120s 内不变）⇒ 若要走"忽略某个 IP 的 LTR"这条路，位号已经拿到（等价 Linux `pmc_core` 的 `ltr_ignore`）。

## §7 判读

| 结论 | 把握度 | 依据 |
|---|---|---|
| 睡眠期封装停在 C3、PC6/C7 从未进入 | **>95%** | powerlog 驻留 + IOReport 进入计数 + MSR 驻留，三方一致 |
| 卡点不在"核心不够深"（核心确实在 C6） | **>95%** | `MSR_IA32_CORE_C6_RESIDENCY` 非 0 且持续增长 |
| PC3→PC6 的否决点是 **BCLK 关断被拒**，原因是 **PCH 侧 IOSF 未 block** | **~85%** | 732 次降级全部单一原因、与 C3 进入次数完全相等；扣分项是"两个数相等"也可能是同一事件的两种记法，尚无第二种实验分离 |
| 否决方在 **PCH 挂载 IP 侧**，不在 CPU 核心侧 | **~85%** | IOSF block 是 PCH 汇总侧带信号，核心侧已满足 Intel 三条件中的两条 |
| 具体是哪个 IP 在拖住 IOSF | **<80% 未知** | LTR 表只能给出"XHCI 约束最紧"这一嫌疑，但 IOSF block 与 LTR 是两套机制，不能直接等同 |
| LTR 的数值单位/量纲 | **<80% 未知** | 只能做相对比较（XHCI 比其余紧 4~5 个数量级），未拿到 PCH 寄存器手册逐位核对 |

## §8 下一步可做的实验（都不需要 Linux、不需要重启）

1. **合盖睡眠前后各读一次**：看睡眠期 `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` 是否也 +1、`PKGC_C3_ENTRANCE_COUNTER` 是否同步 +1。成本 = 用户照常合盖一次。
2. **逐个断设备**（WiFi / 蓝牙 / 有线网 / USB 外设）后看 C3 进入次数与 BCLK 降级原因是否变化，逐步收窄到具体 IP。成本 = 点几次菜单，仪器是即时的。
3. 若定位到某 IP，用 kext 写 PCH `LTR_IGNORE`（位号已在 §6 拿到）做 A/B。成本 = 一次 kext 注入 + 重启（本项目已有成熟流程）。

## §9 与历史结论的关系

- 「PC6 从未发生」由排除法（~90%）升为**直接观测（>95%）**，且这次给出的是 **Apple 自己的原因寄存器**，不是推断。
- 「卡点 = PC3→PC6 的 BCLK 关断 + VR 降压，由固件/PCU 把着」这条（11-23 早先 ~90%）**方向正确、细节修正**：PCU 明确尝试过关 BCLK，是被 PCH 的 IOSF 侧挡回来的，不是"根本没尝试"。这对"能不能解"影响很大——**问题不在 PCU 策略，而在某个 PCH IP 不肯 block**，这在原理上是可以通过让该 IP 进 D3/忽略其 LTR 来改变的。
- 因此「3.6W 是无解地板」这句要降级：地板仍在，但**理由从"固件不让"改成"某个 PCH 挂载 IP 不放手"**，后者有明确的下一步实验路径。

## §10 ★ 跨睡眠验证（2026-11-23 19:18:45 → 19:20:58，一次真实睡眠）

§8 的第 1 条实验已由用户实际入睡完成（`Software Sleep`，AC，pmset 记录 133 secs）。睡前快照 19:15（`/tmp/pmc-full.txt`）、睡后快照 19:21（归档于 `~/automation-workspace/pmc-sleep-window-2026-11-23-1921/`）。

### 10.1 计数器对照

| 通道（`pmtelemetry_cpu/cstate_counter`） | 睡前 19:15 | 睡后 19:21 | 增量 |
|---|---|---|---|
| `PKGC_C3_ENTRANCE_COUNTER` | 732 | **60,801** | **+60,069** |
| `PKGC_BCLK_MODE_DEMOTE_CAUSE_IOSF_NOT_BLOCKED` | 732 | **60,801** | **+60,069** |
| `PKGC_C6/C7/C8/C9/C10_ENTRANCE_COUNTER` | 0 | **0** | **0** |
| `PKGC_RING_C7_ENTRY_COUNTER` | 0 | 0 | 0 |
| `MSR_IA32_PKG_C6_RESIDENCY` | 0 | **0** | **0** |
| 其余 4 个 BCLK 降级原因 + 10 个 `RESOLVE_CAUSE` | 0 | **0** | **0** |

### 10.2 三条判读

1. **睡眠期与清醒期是同一套否决机制，且 1:1 绑定**：C3 进入次数与 IOSF 降级原因在睡醒之后**仍然严格相等**（60,801 = 60,801）。这不是巧合能解释的——每一次封装落到 C3，都对应一次"想关 BCLK → 被 PCH 的 IOSF 未 block 打回"。
2. **睡眠期尝试速率极高**：60,069 次 / 133 s ≈ **452 次/秒**。也就是说整个睡眠期间 PCU 每 2 毫秒就在敲一次封装 C6 的门，全部被挡回，一次也没进去。
3. **清醒期几乎不发生**：同日 45 秒清醒空闲增量对比 —— `C3_ENTRANCE +0`、`IOSF_NOT_BLOCKED +0`，只有 `C0 +304` / `C2 +304`。⇒ C3/BCLK 这一层只在**睡眠期**大量发生，与"睡眠 3.6W"这条主线的场景完全对应。

### 10.3 附带交叉验证（PC3 驻留时间）

`MSR_IA32_PKG_C3_RESIDENCY` 睡后 303,808,136,996。按 TSC 2.592 GHz 折算 ≈ **117.2 s**，占 133 s 睡眠的 **88%** —— 与 RAPL 侧独立算出的 PkgC3 占比（长睡眠段 94.8%）、powerlog 驻留（99%）同量级。三条互不依赖的方法指向同一件事。

> 扣分项（<80%，标未知）：睡前那次读到 `MSR_IA32_PKG_C3_RESIDENCY` = 420,062,032（折算 0.16 s），与睡后的 303.8e9 不在同一量级，且同批 `PKGC_C0_ENTRANCE` 33883→33875、`PKGC_C2_ENTRANCE` 34615→29140 出现小幅**下降**。计数器不应倒退，说明这批 PMT 通道在 S0ix 唤醒后存在**重载/分段**行为，或睡前那次读到了截断值。故"88%"只作同量级交叉参考，不作精确值；"C3 与 IOSF 严格 1:1"这条不受影响（两端取的是同一批同子组通道，且比值在三次独立采样中一致）。

### 10.4 对结论的净影响

- 「睡眠期 PC6 从未进入」：powerlog/IOReport/MSR 三方 + 本次跨睡眠 → **>95%**。
- 「否决点 = BCLK 关断被 PCH 的 IOSF 未 block 挡回」：由清醒期单点样本（~85%）升为**清醒 + 睡眠两态一致、且跨唤醒后 1:1 保持** → **~90%**。
- 「具体哪个 PCH IP」：仍 **<80% 未知**。下一步就是 §8 第 2 条——逐个断设备看 60,801 这个数涨不涨。
