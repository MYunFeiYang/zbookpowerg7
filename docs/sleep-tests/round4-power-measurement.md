# Round 4 · 睡眠功耗：把「真值」变成可重复测量（2026-09-18）

> 用户指令：「回到主线吧——优化睡眠功耗」。
> 本轮**不改任何配置**（理由见下），交付两样东西：**① 配置层复核证据 ② 可重复的测量工具 + 实验协议**。

---

## 1. 结论先行

| 问题 | 本轮答案 |
|---|---|
| 配置/EFI 层还有可调的省电项吗？ | **没有**。本轮逐条复核：`powernap/tcpkeepalive/womp/proximitywake/standby/hibernatemode/networkoversleep` 全部已是"关或最优"（§2.1） |
| 有"被隐藏的唤醒"在偷偷耗电吗？ | **没有**。日志普查 17 段睡眠 / 10 次唤醒事件，**全部由用户动作触发**，非用户唤醒 = 0（§2.2） |
| 那还缺什么？ | **缺一个可信的掉电率真值**。现有唯一的本机实测是 round3 的**单次 50 min**，而它有两个缺陷（§3） |
| 所以本轮动作 | 写 `tools/sleep-power-measure.sh`（打点/结算/DarkWake 计数/双口径对照），并给出 3 臂实验协议（§4）。**不动配置**——无真值就改配置属盲调 |

---

## 2. 配置层复核（2026-09-18 16:1x 实读，非转述）

### 2.1 `pmset -g custom` —— 所有已知省电开关都已在省电侧

| 键 | 电池 | AC | 判定 |
|---|---|---|---|
| `powernap` | 0 | 0 | ✅ 已关（否则睡眠中会周期性暗唤醒做备份/邮件） |
| `tcpkeepalive` | 0 | 0 | ✅ 已关（否则睡眠中保 TCP = 持续联网耗电） |
| `womp`（Wake on LAN） | — | 0 | ✅ 已关 |
| `proximitywake` | 0 | 0 | ✅ 已关（否则蓝牙设备靠近即唤醒） |
| `standby` / `standbydelay*` | 0 / 86400 / 10800 | 同 | ✅ 已关（否则会走 S4 休眠路径 → 本机已判死） |
| `hibernatemode` | 0 | 0 | ✅ 纯内存睡眠 |
| `networkoversleep` | — | 0 | ✅ |
| `disksleep` | 10 | 0 | ✅ 电池下盘 10 min 空闲即睡（APFS 时代意义有限，但方向正确） |
| `lowpowermode` | 1 | 0 | ✅ 电池自动低功耗 |
| `sleep` | 15 | 0 | ⚠️ 见 §5.2（AC 上永不自动睡是 Apple 笔记本默认值，非配置错误） |

**⇒ 结论：这一层已无"把某开关从 A 改成 B 就能省电"的项。**

### 2.2 唤醒源普查 —— 零非用户唤醒

`pmset -g log` 全量（覆盖 09-16 09:04 起、共 17 段睡眠）：

| 唤醒原因 | 次数 | 性质 |
|---|---|---|
| `PWRB/UserActivity Assertion` | 5 | 用户 |
| `LPCB XDCI/Lid Open` | 2 | 用户开盖 |
| `PWRB/Lid Open` | 1 | 用户开盖 |
| `LPCB XDCI/UserActivity Assertion` | 1 | 用户 |
| `XDCI/`（DarkWake from **Normal Sleep**） | 1 | **异常项，已归因** |

- **每段睡眠内的 DarkWake 数：10 段里 9 段 = 0**，唯一 1 段（09-17 11:29:41）落在**当天的 S3 实测窗口**内 —— 形态是 `DarkWake from Normal Sleep`（不是 Deep Idle）、`WakeTime 159.3 s`（Deep Idle 基准 2.4–2.8 s）。⇒ 与 09-17 的 S3 结论（EC 不响应 → 慢唤醒/panic）自洽，**不是新增问题**。
- 昨夜 11.0 h 连睡（`09-17 21:51:50 → 09-18 08:52:16`，39,626 s）：**中途零唤醒**，`WakeTime 2.4 s`。
- ⚠️ **一个值得记录的观察**：入睡时 `Wake Requests` 里有 `*process=powerd request=CSPNEvaluation wakeAt=23:52:20`（被选中的那个），但那一夜**日志里没有 23:52 的 DarkWake**；今天 `pmset -g sched` 也挂着 3 条 `user-invisible` 计划唤醒（`GaugingMitigationActions`、`calaccessd.travelEngine` ×2）。⇒ 观测层面 **RTC 计划唤醒在本机没有真的把机器叫起来**（对睡眠功耗是好事）。**未验证是"被 RTC 防护挡住"还是"这类 user-invisible 唤醒本就不在 Deep Idle 下执行"——按纪律只写观测，不写成因。**

---

## 3. 为什么"真值"仍是缺口：round3 那两个缺陷

round3（09-17 18:09→18:59，电池、裸机、WiFi/BT 开）给出 **11.2 %/h ≈ 7.2 W**，但：

1. **样本太短（50 min）**：入睡后前 ~10 min 是维护期（日志里那次 `mDNSResponder:maintenance`、`apsd`/`bluetooth.sleep` 回调都在这段时间），功率显著高于稳态。
   *自洽检验*：若前 10 min 按 20 W、其余 40 min 按 4 W → 合计 6.0 Wh ÷ 0.836 h = **7.2 W（正好等于实测）**。⇒ **11.2 %/h 很可能是"瞬态+稳态"的平均值，而稳态可能只有 ~4 W(≈5–6 %/h)**。这个差值决定"出差前合盖睡一晚会不会没电"，必须测出来。
2. **两个口径不一致（本机特有）**：同一次睡眠，`pmset` 记 `Charge: 100% → 95%`（= 6 %/h），而 `ioreg` 的 mAh 记 520/5536（= 9.4 % → 11.2 %/h）—— **差近 2×**。
   本机电池是 `SMCBattery` 仿真读数 ⇒ **绝对值的可信区间应写成 6–11 %/h（≈4–7.5 W）**，而不是单点 11.2 %/h。

⇒ 这两个缺陷不是靠"再改一个参数"能解的，只能靠**更长的样本 + 双口径并列**。

---

## 4. 交付：`tools/sleep-power-measure.sh` + 三臂协议

### 4.1 工具

```bash
tools/sleep-power-measure.sh status          # 现况：电源/电池/断言/计划唤醒
tools/sleep-power-measure.sh arm <标签>      # 睡前打点（精确 mAh + 电压 + 时刻 → power-samples/arms.jsonl）
tools/sleep-power-measure.sh report [--save] # 醒后结算：时长 / 睡眠形态 / 唤醒原因 / DarkWake 数 / WakeTime
                                             #            ΔmAh → %/h → W，并并列 pmset Charge 口径
```

设计要点（都是被上面的坑教出来的）：
- **AC 守卫**：入睡行若含 `Using AC` 直接标"数字无物理意义"（AC 下不放电）。
- **双口径并列**：`ioreg mAh` 与 `pmset Charge%` 同时给，偏差 >1.5× 时显式告警。
- **结构与功率同时出**：一次 `report` 同时给出 `Deep Idle / Normal Sleep`、唤醒原因、区间内 DarkWake 数、`WakeTime` —— 避免"只看瓦数不问机制"。
- **ΔmAh 为负 / 唤醒早于入睡**（还在睡）都会拦住。
- 只读，不改任何系统设置；数据落 `docs/sleep-tests/power-samples/arms.jsonl`。

### 4.2 三臂实验（按优先级）

| 臂 | 条件 | 目标 | 判读 |
|---|---|---|---|
| **A（必做）** | 拔 AC、**≥4 h**、裸机/包内、Wi-Fi/BT 开 | 分离"入睡瞬态" vs "稳态" | 稳态 ≤6 %/h ⇒ 已到地板，收手；>8 %/h ⇒ 才有必要谈"漏电" |
| B（可选，仅诊断） | 同 A 但 **Wi-Fi+BT 关** | 给"已否决的大杠杆"标价 | 只做一次、只看差值；**不作为策略采纳**（用户 09-17 已明确"别动WiFi蓝牙"） |
| C（可选） | 同 A 但**接着 HDMI 外屏 + USB 鼠标**睡 | 定价 desk 场景的外设杠杆 | 仅对"插着外设睡"的日常场景有意义 |

**执行方式**：`arm A` → 拔电源 → 合盖 → 醒来后 `report --save`。
⚠️ 不要用 `pmset schedule wake` 自动唤醒（RTC 写 → HP POST 005 风险，与本机既有铁律冲突），靠手动开盖。

已跑通的格式示例（今天 16:07 那段 54 s，仅证明链路可跑）：

```
入睡: 2026-09-18 16:07:02   [Software Sleep pid=1948]
唤醒: 2026-09-18 16:07:56   [Deep Idle / due to PWRB/UserActivity Assertion]
时长: 54s ≈ 0.9 min   区间内 DarkWake 数: 0   WakeTime: 2.452s
供电: AC   pmset Charge: 100% → 100%   ⇒ ⚠️ AC 睡眠，数字无物理意义
```

---

## 5. 剩余杠杆清单（诚实版）

| # | 杠杆 | 预期收益 | 风险 | 状态 |
|---|---|---|---|---|
| 1 | S4 / `standby` 休眠（RAM 断电） | **极大**（7 %/h → ~1 %/h） | 高：本机实测恢复侧失败、RTC 墙 | **已判死（30 条审计）**，`standby 0` 是刻意关闭 |
| 2 | 睡眠关 Wi-Fi/BT | 大（社区署名 0.66 %/h） | 零 | **用户已否决**（仅保留 B 臂一次性诊断） |
| 3 | 睡前拔外设（HDMI/USB） | 小–中（仅 desk 场景） | 零 | 未测 ⇒ C 臂 |
| 4 | ASPM / NVMe APST 再压 | 未知 | 中（`7b0ab03` 注入 1.5 h 即回退） | 已撞墙 |
| 5 | 配置层其它开关 | ~0 | — | **本轮复核：无牌** |
| 6 | 唤醒源治理 | 0 | — | 已归零（本机非用户唤醒 = 0） |

**一句话**：本机睡眠档位的**可改项已经用尽**，剩下的是①结构性漏电（DRAM 自刷新 + SoC 保持电路，改不动）②被否决的 Wi-Fi/BT ③外设。**唯一还值得花时间的不是"改"，而是"量准"** —— 量准之后大概率结论是"稳态已在 5–7 %/h，属 AOAC 未压降基线，收手"。

### 5.2 顺带观察（不属睡眠，但属功耗）

- AC 上 `sleep 0` ⇒ 插电离开时**系统永不自动睡**（只关屏），叠加 WorkBuddy/Electron 的 `NoIdleSleepAssertion`，机器会以 ~25 W 空载一直烧到用户回来。**这是 Apple 笔记本的默认值，不是配置错误**；对策是离开时合盖（Clamshell 走显式 Software Sleep，不受断言阻挡）。
- 电池 `lowpowermode 1` 已开；`CycleCount 131 / MaxCapacity 5953 mAh（Design 7170）` ⇒ 容量 83%，属正常老化。

---

## 6. 复现命令

```bash
pmset -g custom                      # §2.1
pmset -g log > /tmp/pmlog.txt        # §2.2（无需 sudo）
awk '/Entering Sleep state/{t=$1" "$2} /from (Deep Idle|Normal Sleep)/{print t" → "$1" "$2}' /tmp/pmlog.txt
tools/sleep-power-measure.sh status
```
