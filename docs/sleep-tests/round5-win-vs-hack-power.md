# Round 5 · **为什么 Windows 和黑苹果的 Deep Idle 功耗差这么多？**（2026-09-20 14:2x）

> 触发：用户问「**deep idle 呢？为什么 window 和 hackintosh 功耗差异这么大？**」
> 本轮**零配置 / 零 EFI / 零固件写入**；只读取证 + 机制查证，**不代表本轮已实测 Windows 功耗**。

---

## 0. 结论先行（三句话）

1. **前提只有一半数据**：macOS 侧实测 **6–11 %/h（≈4–7.5 W）**；**Windows 侧功耗从未测过** ⇒ "差多少"目前是**未知数**。
2. **结构上最可能的主因是「档位差」，不是「同一模式下的效率差」** —— Windows 有 **S4（休眠）** 兜底且 **Adaptive Hibernate 默认开着**（12 h 内掉电 ≥5% ⇒ 自动进 S4 ≈ 0 W）；macOS 侧 `standby 0` + `hibernatemode 0` ⇒ **只有 S0ix 一档，永远 5 W**。
3. **顺带推翻一个我们自己的老假设**：外部实测显示 **Windows 在 S0ix 下保持 WiFi/BT 连接时仍只有 ~0.3 W** ⇒ macOS 那 5 W **不是"WiFi 没关"能解释的**，而是**平台没进最深状态**。

---

## 1. 事实层：两边"Deep Idle"各是什么

### 1.1 🟢 本机 Windows 侧 `powercfg /a` 一手原文（2026-09-20 12:0x 采集）

```
此系统上有以下睡眠状态:
    待机 (S0 低电量待机) 连接的网络      ← Modern Standby = S0ix = "Deep Idle"
    休眠                                ← ★ S4 可用
    快速启动

此系统上没有以下睡眠状态:
    待机 (S1)   系统固件不支持此待机状态 / 当支持 S0 低电量待机时，禁用此待机状态
    待机 (S2)   系统固件不支持此待机状态 / 当支持 S0 低电量待机时，禁用此待机状态
    待机 (S3)   当支持 S0 低电量待机时，禁用此待机状态
    混合睡眠    待机(S3)不可用 / 虚拟机监控程序不支持此待机状态
```

### 1.2 两边档位对照

| 档位 | macOS（本机） | Windows（本机） |
|---|---|---|
| **S0ix / Deep Idle** | ✅ **唯一可用**（靠 `SSDT-DeepIdle` 伪造 `LPS0`/`LXEN` 声明） | ✅ 可用（**厂商设计路径** = Modern Standby） |
| **S3** | ❌ **实测坏**（真进 S3 ⇒ `EC OBF=1 poll timed out` ⇒ USB 栈 panic） | ❌ 被 AOAC 压住（固件无此项、无写入入口） |
| **S4** | ⚠️ **进得去、出不来**（"睡下即断气"，失败在**恢复侧**） | ✅ **可用** |
| **快速启动** | — | ✅ |
| 实测掉电 | **6–11 %/h（≈4–7.5 W）** | **🔴 未测** |

> ⚠️ **措辞澄清**（与 MEMORY 的"S3/S4 均判死"有张力）：
> 按 `s4-requirements-audit.md` **§6** 的重核，S4 的准确判定是 —— **固件执行了断电动作（#27a ✅），失败在恢复链（#27b ❌）**；
> 而**唯一的"改配置改不出来"（#28 RTC 断电期保持）有 HP 官方解法**（支持文档 `ish_2843606-2359609-16`：*"退出休眠状态后，系统时钟显示的时间不正确……**更新 BIOS 应该可能会解决该问题**"*）。
> ⇒ S4 是「**不追**」，不是「固件没实现」。**这个区别正是本节第 2 条猜想的入口。**

---

## 2. ★ 差异的三个结构性来源（按确定性排序）

### 2.1 🟢🟡 **① 档位差：Windows 会自己"换到更省的一档"，macOS 换不了**

**Microsoft 官方（`Display, sleep, and hibernate idle timers`）原文：**

> *"Although Modern Standby systems support Hibernate (S4) state, **it is not entered automatically after a fixed amount of time in sleep**. Instead, Windows manages Hibernate intelligently, only using it when required to preserve user's battery life."*

**Microsoft 官方（`Adaptive Hibernate Overview`）原文 —— 这才是关键：**

| 触发器 | 默认值 | 语义 |
|---|---|---|
| `StandbyBudgetPercent` | **5%** | 一次刷新周期内允许掉的电 |
| `StandbyBudgetRefreshInterval` | **12 小时** | 刷新周期长度 |
| `StandbyBudgetRefreshCount` | 4 次 | 未超预算时可续期次数 |
| （grace period） | 15 分钟 | 避免刚睡就休眠 |

> *"If the device drains less than the StandbyBudgetPercent over the StandbyBudgetRefreshInterval, it is allowed to stay in standby. **Otherwise, the device will hibernate.**"*
> ⚠️ **只在 DC（电池）下生效**，AC 下无影响。

**🟢 独立社区确认**（Framework 社区帖 *Is Framework 13 AMD s2idle efficient enough?*，2024-09）：

> *"I prefer S0 network disconnected. It will suspend with no network, and then **after using 5% of the battery hibernate automatically**."*

**⇒ 推演（🔴 推断，但形态明确）**：若 Windows 侧也只有 ~7 %/h，则**约 45 分钟就掉到 5% ⇒ 自动进 S4 ⇒ 之后 ≈ 0 W**。

| 睡 10 小时 | 形态 | 总掉电 |
|---|---|---|
| **Windows**（若成立） | 45 min @ ~5 W **+** ~9 h @ ≈0 W（S4） | **≈ 4%** |
| **macOS**（已实测） | 10 h @ ~5 W（**全程 S0ix**） | **≈ 50–70%** |

⇒ **差的不是"效率"，是"有没有第二档"。** 这一条若要坐实，只需在 Windows 的 SleepStudy 报告里找有没有 **Hibernate 段**（§4）。

**为什么 macOS 没这一档**：`powernap 0` + `standby 0` + `hibernatemode 0` + `HibernationFixup` 已移除（kext 列表 30 个中无它）
⇒ macOS **本来的** `standby`/`standbydelay` 机制（睡够时间转 S4）被我们**主动关掉**了，因为**本机 S4 进得去出不来**（§1.2）。

### 2.2 🟢 **② 平台级协调器：Windows 有，macOS 没有**

| | Windows Modern Standby | macOS 的睡眠 |
|---|---|---|
| **平台协调** | **Intel PEP**（`intelpep.sys`）+ DPTF —— 把设备按进 D3/RTD3，再让 SoC 进 DRIPS | **无等价物** |
| **应用冻结** | **DAM**（Desktop Activity Moderator）冻结非豁免 Win32 | 进程冻结（但在 S0ix 下 ≠ 设备下电） |
| **网络** | **"连接待机"** —— 无需求时进低功耗 + **协议卸载（ARP/NS offload）+ WoLAN** | **断开式**（PowerNap / tcpkeepalive / womp / networkoversleep 全关） |
| **诊断工具** | `powercfg /sleepstudy`：**DRIPS 直方图 + Top offenders** | **无等价物** |
| **第二档** | **S4（Adaptive Hibernate）** | 无（已关） |

**Microsoft 官方点出的 PEP 语义**（`modern-standby-sleepstudy-common-problem-examples`）：

> *"A common reason for a modern standby session to have **zero percent software and hardware DRIPS** is that **a critical driver is not loaded** on the system. … the value for **PEP PRE-VETO COUNT is extremely high** (it should nominally be zero)."*

⇒ PEP 是"**设备是否有权否决进入低功耗**"的仲裁者。**macOS 侧没有这个角色。**

### 2.3 🟢 **③ macOS 是在"别人家的省电模式"里跑**

- macOS 在**真 Intel Mac 上从不使用 S0ix**（走 S3）。本机是**被 AOAC 压住 S3 之后被迫落在 S0ix**。
- 我们的 `SSDT-DeepIdle.dsl`（94 B）全文只有两个方法：
  ```asl
  Scope (_SB)  { Method (LPS0, 0) { If (_OSI("Darwin")) { Return (One) } } }
  Scope (_GPE) { Method (LXEN, 0) { If (_OSI("Darwin")) { Return (One) } } }
  ```
  ⇒ 它做的是「**对 macOS 声明"本平台支持低功耗 S0 空闲"**」，**不改变任何设备的下电行为**。
- ⇒ 结论：**macOS 在这个模式下没有为它优化的理由，也就没有优化它。**

---

## 3. ★ 反直觉证据：**不是 WiFi 的锅**

### 3.1 外部实测数字（🟢 社区一手）

| 平台 | S0ix 实测 | 条件 | 来源 |
|---|---|---|---|
| Windows 11（Lakefield / X1 Fold） | **0.5–0.6 %/h** | **disconnected**（无 WiFi 活动） | HN / Framework 帖 |
| Windows 12 代（Framework 13） | **280–340 mW** | **WiFi/BT 保持连接** | Framework 社区帖 |
| Fedora 36（同机） | ~0.4 %/h | 同上 | 同帖 |
| **本机 macOS** | **6–11 %/h（≈4–7.5 W）** | WiFi/BT 开 | 本机实测 |

> 原帖原话：*"Windows **leaves BT connected** while sleeping. Also means the **WiFi card is still powered** and not disconnected."* —— 却仍只有 ~0.3 W。

### 3.2 ⇒ 这推翻了什么

- 社区那个"**关 WiFi/BT ⇒ 0.66 %/h**"的署名案例（OC-Little 引用）**不能直接照搬到本机**：
  Windows 保持连接也才 0.3 W，说明 **5 W 的成因不在无线网卡本身，而在"平台整体没进最深状态"**。
- 同时也说明「**被用户否决的关 WiFi/BT 这条大杠杆，可能本来就没那么大**」—— 这条 ⚠️ 需要实测（三臂协议 A/B）。

### 3.3 macOS 侧"已用尽"清单（🟢 本机逐条实测，`round2-tierB-result.md` §38.2）

| 社区 7 条压降清单 | 本机状态 |
|---|---|
| 禁止 S3 睡眠 | ✅ 已满足（`SSDT-DeepIdle` 在跑） |
| 关闭独显供电 | ➖ **不适用**（`SSDT-dGPU-PowerOff-Darwin` 已 `_OFF`；显示栈只有 Intel UHD 630） |
| 电源空闲管理 | ✅ 已满足（= `SSDT-DeepIdle` 本身） |
| SSD 品质 SLC>MLC>TLC | ✅ WD SN570 = TLC（硬件换不了） |
| 更新 SSD 固件 | ⚠️ 未做（工具只有 Windows 版，无收益先例） |
| NVMeFix 开 APST | ✅ 已满足（`IOKitDiagnostics` 计数 = 1） |
| 启用 ASPM（L1） | ✅ 已满足（`DeviceProperties` 已含 L1；且 `aspm-audit.md` 已证**与睡眠掉电无关**） |
| **睡眠前关 Wi-Fi/BT** | ⛔ **被用户否决**（且按 §3.1 可能本就不是大头） |

⇒ **`Deep Idle ≈5 W ≈7 %/h 就是本机地板`**（不动 WiFi/BT 前提下）。

---

## 4. ★ 一锤定音：用 Windows 的工具诊断 macOS 的问题

**这是本轮最有价值的产出。** macOS **没有**能"点名阻止进入深睡的设备"的工具；Windows **有**。

`powercfg /sleepstudy`（管理员 + **必须电池供电真的睡一次**）会给出：

| 输出 | 回答什么问题 |
|---|---|
| 每次待机的**掉电率 %/h** | **"差异到底多大"** |
| **DRIPS 直方图**（各深度停留时间占比） | **"它到底睡到多深"** —— 若全是浅层，§2.2 成立 |
| **Top offenders**（设备/驱动/进程 + Active Time %） | **"谁在阻止"** ← **macOS 永远拿不到的东西** |
| 有没有 **Hibernate 段** | 验证 §2.1 那个"档位差"猜想 |
| **PEP PRE-VETO COUNT** | 高 ⇒ 说明**有驱动没加载**（对照 §2.2） |
| `powercfg /batteryreport` | 交叉核对时间窗与总容量 |

**为什么这招对 macOS 有效**：**两边硬件完全相同**。Windows 报告点出的 offender（比如某个 USB 控制器 / NVMe / 无线网卡），**就是 macOS 也在耗的同一个设备**。

⚠️ **前提**：SleepStudy 只统计 **DC（电池）** 的待机会话 ⇒ 必须拔掉电源真睡一晚。

---

## 5. 未验证项（如实列出，不许当结论）

| 说法 | 等级 |
|---|---|
| "Windows 侧功耗比 macOS 低" | 🔴 **没有任何本机数据** —— 用户观察的差异来源未知 |
| "Windows 实际触发了 Adaptive Hibernate" | 🟡 **机制确定、本机未验**（SleepStudy 一查即知） |
| "5 W 主要来自平台没进最深 DRIPS" | 🟡 **与外部数据吻合**，但本机缺 DRIPS 证据 |
| "Windows 也会驱动 EC 正常、所以 S4 恢复链是通的" | 🔴 推断（但 `powercfg /a` 列出"休眠"= 至少**声明可用**） |
| "macOS 打开 `standby 1` 就能拿到 S4 那档" | 🔴 推断 —— 本机 S4 **恢复侧**失败（`s4-requirements-audit.md` #27b），**开了也醒不回来** |

---

## 6. 结论与默认动作

- **不加新配置、不改 EFI、不写固件。** 本轮是**取证 + 机制查证**。
- **用户的问题答案是分层的**：
  1. **"Windows 侧 Deep Idle 是什么"** → 🟢 `powercfg /a`：S0 低电量待机（连接的网络），且**另有 S4 可用**。
  2. **"为什么差异大"** → 🟡 **最可能是档位差**（Windows 有 S4 兜底，45 min 就换档；macOS 只有 S0ix 一档），**不是同一模式下的效率差**。
  3. **"差多少"** → 🔴 **未知**，只有 macOS 半边数据；Windows 半边需一次 SleepStudy。
- **唯一零风险的下一步**：Windows 侧跑 `powercfg /sleepstudy` + `powercfg /q SCHEME_CURRENT SUB_PRESENCE`
  （提示词见 `docs/windows-side-power-prompt.md`；**只读，不需要改任何设置**）。
- **「出远门直接关机」不变。**
