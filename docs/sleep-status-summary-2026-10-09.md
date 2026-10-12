# 睡眠问题现状总览（2026-10-09 17:0x）

> 本文是 20 余轮排查后的**收敛快照**：只写当前站得住的结论，每条后面标证据等级。
> 等级：**实测** = 本机跑出来的原始输出；**实读** = 直接读文件/表；**推断** = 有依据但未坐实。

---

## 0. 一句话

**这是一台 AOAC（伪 S0ix）机器。点"睡眠"后它进入睡眠流程，但从未真正睡成功——停在半路，心跳/日志冻结，电源键无响应。**
本轮的收敛判断是：**`SSDT-DeepIdle` 在跑、S3 没禁、唤醒侧缺 `_PS0`/`_PS3`** —— 正是 OC-Little 点名的冲突组合。三件已按标准补齐并落盘，**待重启生效**。

---

## 1. 症状指纹（实测）

| 观察 | 值 | 等级 |
|---|---|---|
| 触发方式 | 全部是 `Software Sleep pid=X`（点菜单/`pmset sleepnow`），**不是合盖** | 实测（`pmset -g log`） |
| 今日 3 次 | 12:03:16 / 12:42:07 / 15:25:48 入睡 → 全部睡死 → 12:37 / 12:45 / 15:29 强关 | 实测 |
| 唤醒记录 | **零 `Wake from`、零 `DarkWake`** | 实测 |
| 按电源键 | **完全无响应**（长按才断电） | 用户实况 |
| panic | **零 `.panic`**（`DiagnosticReports`） | 实测 |
| 与 OC-Little 原文 | 「睡眠后无法被唤醒，呈现死机状态，只能强制关机……本质是机器**一直停滞在睡眠过程，始终没有睡眠成功**」 | 逐字吻合 |

---

## 2. 时间线（实读）

| 时间 | 事件 |
|---|---|
| 2026-08-24 | `SSDT-thunderbolt-disable` 加入（禁 RP01） |
| **2026-09-21 ~ 09-28** | **睡眠正常窗口**（⚠️ 体验级证据：powerlog 原始数据已滚动删除，最早只剩 9-28 08:51） |
| **2026-09-29 12:13** | **首次睡死** |
| 2026-09-29 19:59 | 升 **26.7.1** |
| 2026-09-29 20:31 / 21:01 | KDK / OCLP root patch（`Sealed: Broken`） |
| 2026-09-30 12:05 | OCAT 换 **OC-Mod**（`93ba284`） |
| 2026-10-09 | 3 次睡死；EFI 全栈回滚 + AOAC 补齐 |

**两个不同的"刀"要分开**：

- **第一刀**发生在 **26.7**（9-20 19:34 装）上，9-29 12:13；
- **26.7.1**（9-29 19:59）晚 8 小时，**不是第一刀元凶，但可能是"之后一路坏"的维持因素**。
- 9 月有 **3 次**系统更新（9-08 / 9-20 / 9-29），每次都换掉 sealed 快照、使既有 OCLP 根补丁失效。

---

## 3. 底座（实读）

| 项 | 值 |
|---|---|
| 平台形态 | AOAC 伪 S0ix：`IOPMDeepIdleSupported=Yes`、`IOPMSleepType=7`、**无 S3** |
| 电源设置 | `hibernatemode=0` / `standby=0` / `powernap=0` / `womp=0` / `tcpkeepalive=0` |
| 当前系统 | **macOS 26.7.1 (25G241)**（记忆里写的 26.5.2 已过时） |
| 系统卷 | `Sealed: Broken`（OCLP root patch） |
| 电池 | 79.7%（5716/7170）、132 循环 |
| `PowerTimeoutKernelPanic` | `True`，却零 panic |

---

## 4. 已排除（附判据）

| # | 排除项 | 判据 |
|---|---|---|
| 1 | **config 各版本** | `docs/backups/` 里 **29 份快照（9-20~10-09）架构恒定**：DeepIdle ON + Wake-AOAC ON + S3 补丁缺；而 9-21~28 能睡 |
| 2 | **EFI 全栈回滚** | 15:17 开机跑的确实是 9-18 版 OpenCore + `config ec401834`（双侧 sha 已核），15:25 睡 → **仍睡死** |
| 3 | **拔电变量** | 成功窗口本身就是插电的（用户纠正） |
| 4 | **深信服** | 无关（用户确认 + 已排除） |
| 5 | **PowerNap / Wake-on-LAN** | `powernap=0` / `womp=0` |
| 6 | **kext 电源超时层** | `PowerTimeoutKernelPanic=True` 却零 panic ⇒ 看门狗没被触发 |
| 7 | **LID / GPE 路径** | 今日 3 次全是 `Software Sleep`，**不是合盖** ⇒ 该路径未被走到 |
| 8 | **雷电（BIOS + ACPI + Kernel/Block）** | 三处好/坏窗口**完全一致**；今天 17:0x 实测 ACPI 禁用仍生效（`IODeviceTree` 无 `RP01`、无 `TXHC`、无 `IOThunderbolt*`） |
| 9 | **RTC 补丁** | `rtcfx_exclude=0E-FF` 自 9-16 13:52 未变 ⇒ 非好/坏窗口的区分变量 |
| 10 | **ACPI `_STA` 门控缺陷** | 见 `docs/acpi-darwin-gating-audit-2026-10-09.md`：15 张表只 1 张结构有误，且经 `acpiexec` 实测**无实际后果**，与睡眠无关 |

---

## 5. 当前根因假设（推断）

```
AOAC 机器
  + SSDT-DeepIdle 在跑          ← 让它能进"深度空闲"
  + S3 没有禁                    ← OC-Little：DeepIdle 与 S3 严重冲突
  + 唤醒侧缺 _PS0 / _PS3         ← 唤醒链没有"重置唤醒状态"的收尾
  ⇒ 睡进去、唤不醒，停在半路
```

**为什么"中间一大段"能睡**（这条要打折扣）：配置从来不是开关，差别在**平台状态**。OC-Little 原话是 DeepIdle 会让唤醒「**困难**」—— 是**概率退化**，不是必然失败。`_PS0` 缺失是**隐性缺陷**：平时不发作，只在唤醒链别的环节先坏掉时才显形。

**诚实边界**：死机瞬间无 panic / 无 stall / 无 `Wake from`，logd 缓冲随强关销毁 ⇒ **"好窗口→坏窗口"的切换变量至今仍未被证据锁定**。

---

## 6. 已落地、待重启生效（全部双侧 sha 一致）

| 改动 | 内容 | sha256(前16) | 对睡眠 |
|---|---|---|---|
| `SSDT-PCI0.LPCB-Wake-AOAC.aml` | 追加 `_PS0`(`\_WAK(0x03)`) / `_PS3`（OC-Little 原版写法，`If(_OSI("Darwin"))` 包裹）；**176 → 219 B** | `a8d963cc2399c4c8` | ✅ 主刀 |
| `SSDT-NameS3-disable.aml` | 新增，OC-Little Name 变体禁 S3；**75 B** | `677303c54ab49a48` | ✅ 主刀 |
| `config.plist` | `ACPI/Patch` +1（`Find 5F53335F → Replace 5853335F`，`DSDT`，`Count=0`）；`ACPI/Add` +1 | `76f3823cd8eb5d0b` | ✅ 主刀 |
| `SSDT-thunderbolt-disable.aml` | `_STA` 补 else + 删模块级死代码；**184 → 164 B** | `ca539c04caccc169` | ○ 无关（质量改进） |
| MFC `smcwrite` 守护进程 | plist 已删 + 已 `bootout`，**helper 惰性残留** | — | ○ 待清 |

**校验**：`plutil -lint` OK；补丁在真 DSDL 上模拟通过（`_S3_` 1→0、`XS3` 1、补丁后 `iasl` exit=0）；工作区 == ESP。
**回滚点**：`docs/backups/pre-fix-20261009-1455/`、`pre-aoac-wakefix-20261009-1555/`、`tb-sta-fix-20261009-1700/`。

---

## 7. 悬案

| 悬案 | 卡在哪 |
|---|---|
| **好/坏窗口的切换变量** | 9-28 有三件新东西：MFC `smcwrite`（仍在）/ 自研 `FanControlKExt`（已删）/ 首次改 EFI（已回滚）⇒ 三件里唯一直写 EC/SMC 的是 `smcwrite` |
| `TBTS` 实值（`0x77B30007`） | `/dev/mem` 本机不存在 |
| SMC 温度/风扇键全缺 | 三个 SMC kext 已加载但键不暴露 ⇒ 装 dump 工具验证是"键不存在"还是"读取被拦" |
| 两个 root 文件 | `sudo rm -f /Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite /Library/LaunchAgents/com.dortania.opencore-legacy-patcher.auto-patch.plist`（系统策略拦截，AI 删不掉） |
| `SSDT-LID-G7` 两处悬空引用 | `\EC0.LIDS`、`\S5.S5SL`（全 DSDT 0 命中）；源码可从 `29dff82` 取回 |

---

## 8. 下一步

**已重启（10-09 17:12:01，26.7.1），配置已加载、待实测。**

1. **插电 → 点睡眠（或合盖）睡一次**。判据放宽 —— 以下**都算成功**：
   - 能睡能醒 ✅
   - 点了睡眠**不再真入睡、也不死机** ✅（说明 DeepIdle 冲突已解）
   - 仅"照旧睡死" = 失败
2. 顺手：进 Windows 时确认 USB-C 的 USB3 是否在（验证 `_STA` 修正的后效）。

**不要做的**（已明确撤回）：动 BIOS（关 Thunderbolt Mode / 改 SL 档 / 关 AOAC 相关项）—— 成功窗口里这些设置本来就一样。

---

### ★ 更正（10-09 17:3x）：**停用 `SSDT-DeepIdle` 是错误方向，不可做**

上一版把"单独停用 `SSDT-DeepIdle`"列为失败后的下一杠杆，**该结论错误，已撤回**。铁证（`docs/firmware-facts-ledger.md` §S3 + `MEMORY.md` 系列，均为实测）：

| 事实 | 证据 |
|---|---|
| `SSDT-DeepIdle` 的全部内容 | 注入 `\_SB.LPS0` + `\_GPE.LXEN`（Darwin 下 `Return(One)`）；本机 DSDT 原厂 **0 命中**（复核：只有标准 `_S0`）⇒ 这两个对象**唯一来源就是这张 SSDT** |
| 它的作用 | 给 macOS 一条**平台声明**，`AppleACPIPlatform` 据此把 `IOPMDeepIdleSupported` 置 **Yes** |
| **撤掉它会怎样** | `IOPMDeepIdleSupported` **Yes→No** ⇒ 系统**确实转 S3** |
| 而本机固件 | **AOAC-only**（`Modern Standby` 与 S3 **互斥设计**）⇒ 转 S3 后 **EC 固件罢工**：`AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ **USB 栈 panic** |
| 实测代价（2026-09-17 强制 S3 实验） | 唤醒 **159.336 s vs 2.430–2.617 s（65×）**；PS2 恢复 **157735 ms vs 457–466 ms（342×）**；panic **1**（本机唯一，NMIPI TLB flush timeout） |

**三档终局**：**Deep Idle (S0ix) ✅ 唯一可用** ｜ **S3 ❌ 实测坏** ｜ **S4** 不追。**"半档不存在"。**

⇒ `SSDT-DeepIdle` 是**必须保留**的底座，不是可停用的杠杆。我们的 AOAC 修复（**保留 DeepIdle + 禁 S3 + 补 `_PS0`/`_PS3`**）恰是在**消除**这对冲突，与"停 DeepIdle"方向**正好相反**。

**失败后的真·下一杠杆（候选，按确定性排序）：**
1. **修 `SSDT-LID-G7` 的两处悬空引用**（`\EC0.LIDS` → `\_SB.PCI0.LPCB.EC0.LIDS`；`\S5.S5SL` 全 DSDT 0 命中）—— 唯一**已确证存在**的技术缺陷，且落在唤醒路径上。
2. `ACPI/Patch` 把 `_PTS` 里的 `Reset(WFEV)` 就地 Noop（`0xA2`→`0xA3`）—— 可验但优先级低。
3. 逐个二分停用**非 DeepIdle** 的 SSDT。
