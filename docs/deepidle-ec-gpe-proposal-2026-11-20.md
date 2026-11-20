# DeepIdle 再尝试：EC 降噪 GPE（SLPT=0x06）方案 —— 取证与提案

> 日期 2026-11-20。状态：**方案设计完成，待用户拍板**。本轮全程只读：未改 EFI/config/ESP、未写 EC/NVRAM、未重启、未睡眠。
> 用户诉求："deepidle 再尝试优化"。本文记录唯一一条"机制最对症 + 从未落地 + 风险远低于已否决路线"的候选，供 C 级决策。

## 一、为什么是这条（而非重复已封死的实验）

盘点结论（详见 `deepidle-power-audit-2026-11-12.md` §34/§37–§54）：

- 已封死：设备 LTR 三手段（写 LTRV / 写 LTRcap / 注入 pci-max-latency）、cstate 表 flag（CStatePatch）、LTR_IGNORE（PMCDump）、L1.2 注入、0xE2、maxbusdelay、PEP/D0ix、S3/S4、固件。`xcpm_assert` 曾把系统搞挂，绝不重试。
- 根因（>85%，排除法 + 同硬件 Windows 正常 + linux-pm 一手）：**macOS 缺 S0ix 平台编排，卡 Package C3 地板 3.6W**。瓶颈在平台/PCH 侧，核心侧（全核 C6/C7）与核显（RC6 83%）已用 powerlog 铁证排除（§54）。
- **唯一未落地、且正对"平台侧"根因的具体动作 = EC 降噪 GPE**。Windows 靠它、macOS 从不触发。§35.5 曾提出但因"需 kext + 睡眠配合"搁置；**本方案用纯 SSDT 替代 kext，去掉了高风险项**。

## 二、机制（本轮只读坐实，>95%）

Windows S0ix 进入流程（`intelpep.sys` → `PEPD._DSM` func3，`SSDT-16.dsl`）：

- `_DSM func3`（"MS Enter"，line 6886-6895）→ `ECNT(One)`（line 6963）。
- `ECNT Case(One)` 核心动作（line 7029）：`\_SB.PCI0.LPCB.EC0.SLPT = 0x06`。
- `ECNT Case(Zero)`（"MS Exit"，line 7003）：`SLPT = 0`。
- 语义（FreeBSD journal 一手，§35.1）：引导 EC 在进入 S0ix 后**降低 noisy GPE 频率**（如电池 GPE 从每秒一次降到每分钟一次），避免 CPU 被反复拉出 idle、维持 S0i3 → 达成 Package C10。

本机现场（`DSDT.dsl`）：

- `EC0` 设备完整存在（line 26931，`_HID=PNP0C09`），`OperationRegion ERAM, EmbeddedControl`（line 27060），`SLPT, 4` 字段位于 **offset 0x81 高 4 位**（line 27088-27091：`ESID,8 / 保留4 / SLPT,4`）。
- `ECUP = One`（line 29450，唯一初值，无其他赋值点）⇒ DSDT `_PTS`（line 29722-29725）里的 `If (ECUP == Zero) { ECNT(Zero) }` 是**死代码，永不执行**。
- ⇒ **macOS 入睡时 SLPT 从不被写**，EC 维持默认 GPE 频率。与"卡 C3、CC7 长期 0%"自洽。

## 三、方案（纯 SSDT，无 kext / 无寄存器 / 无 NVRAM）

新增一张 SSDT（如 `SSDT-EC-GPE.dsl/.aml`），做两件事：

1. `Scope (\_SB.PCI0.LPCB)` 内加方法，在入睡时写 `EC0.SLPT = 0x06`，唤醒时写回 `0`。
2. 触发点用 macOS 睡眠必然调用的 `_PTS`（Prepare To Sleep）/ `_WAK`（Wake）hook。**需先解决同名方法冲突**：DSDT 已定义 `\_PTS`/`\_WAK`，OC 加载的 SSDT 若定义同名，需按 OpenCore 惯例用 `_PTS`→`ZPTS` 重命名（config ACPI>Rename）+ SSDT 里 `External(ZPTS)` 转调，保留原逻辑。或用更轻的 `_TTS`（现有 SSDT-DeepIdle 已占用，可合并进去）。

**关键取舍（为何比 §35.5 的 kext 安全）**：
- 不写内核内存、不写 PMC/P2SB MMIO、不加 kext、不碰 boot-args ⇒ 无变砖风险，无 `-xcpm_assert` 类 panic 前科路径。
- SLPT 是 EC RAM 的标准 ACPI 字段（OEM 表自带定义），写入值 0x06 来自 OEM 原始代码，非猜测。
- 完全可逆：删 1 个 config 条目 + 删 SSDT 文件，重启即恢复。

## 四、风险与未知（诚实标注）

- **因果层仍 <80%**：睡眠是黑盒，无法实测 SLPT 写入后 GPE 频率是否真下降、是否真解锁包级 C6。§35.6 已标注。本方案是"补回 Windows 有、macOS 缺的动作"，成功率无社区先例可判读。
- **副作用不确定**：`ECNT(One)` 除写 SLPT 外还做若干 GPIO 翻转（`G05A/G094/SPC0`）和 `SGOV(0x0302000E)`。本方案**只写 SLPT、跳过 GPIO**，可能不足以完整复现 Windows 的 EC 状态（<80%）。若首版无效，需评估是否补 GPIO 动作。
- **_PTS hook 风险**：重命名 `_PTS` 若出错可能影响睡眠/唤醒。缓解：保留原逻辑转调、单变量、备好回滚 config。
- **需用户配合**：改 config + 重启 + 睡眠一次 + 读 `deep_idle_last_stats`。用户规则"配合优先级最低"，本轮是用户主动要求"再尝试"才提出。

## 五、判读矩阵（上机后）

预期观测：睡眠后 `sysctl machdep.xcpm.deep_idle_last_stats`。
- ① 出现 `C6-C10 > 0`（哪怕 C6）⇒ SLPT/GPE 是门之一，**突破**；继续优化值。
- ② 仍 `C3:99% C6-C10:0` 且 ioreg/AML 确认 SLPT=0x06 已写入 ⇒ EC 降噪 GPE 路线**阴性**，与 §44 平台侧结论合并，DeepIdle 3.6W 地板终局坐死。
- ③ 睡眠/唤醒异常（睡不醒、花屏）⇒ 立即回滚，不做第二次。

回滚：`git checkout HEAD -- EFI/OC/config.plist` + 拷 ESP 双写 + `plutil -lint`；删 SSDT 文件。SLPT 是 EC RAM 易失字段，写入 0（唤醒动作）或断电即恢复。

## 六、当前基线（准备上机时核对）

- workspace config sha：`851f0d9879bfd6554cad05dd8819bd7136989125c1a89674dc82a8d0e6969e90`（本轮读到）。
- 当前无 I219LTR.kext / CStatePatch.kext / SSDT-I219-LTR（实验已清）；`pci-max-latency` 仍保留（CNVW，§50 决定暂留作证据）。
- 目标：在此基础上**只加 1 张 SSDT + 可能的 1 条 _PTS 重命名**，单变量。

---

## 七、v1 上机判决（失败）与 v2 修复

**v1 实测（2026-11-20 14:14:47 boot，config fd7e64a8）**：

- SSDT 已入表：`SSDT 0x0000000077ADA000 0000BE (v02 ECGP ECGPE 00001000 INTL 20251212)`。
- 但 `14:14:47.512464 (AppleACPIPlatform) (SSDT:  ECGPE) while loading table` + 同刻 `AE_ALREADY_EXISTS` 连发 ⇒ **加载失败，SLPT 从未写入**。本轮睡眠测试无效（未做睡眠，先查日志）。

**根因（>95%）**：v1 把两条 rename 放在 `ACPI/Rename` —— **OpenCore 无此键**（rename 属于 `ACPI/Patch`，Clover 才叫 Rename）。OC 运行时静默忽略未知键 ⇒ DSDT 未改名 ⇒ SSDT 的 `_PTS`/`_WAK` 与 DSDT 同名 ⇒ AE_ALREADY_EXISTS，整表拒绝加载。

证据链：① 同文件 `ACPI/Patch` 内 7 条既有 rename（含 `_S3→XS3`）全部生效，同一 OC 版本 ⇒ Patch 通道可用；② plist 结构核对时 `ACPI` 键集合为 `Add/Delete/Patch/Quirks/Rename`，Rename 为多余键；③ 日志错误点与本表加载时刻同一毫秒级。

**v2 修复（已部署，待重启验证）**：

1. 两条 rename 迁入 `ACPI/Patch`（Find `_PTS\x01` / `_WAK\x09`；二进制统计 DSDT 各命中 **1 次**；`grep` 确认 DSDT 内部无 `_PTS`/`_WAK` 调用者，改名无副作用）。
2. 加 `Debug` 标记：`ECGP_PTS arg=0x1` / `ECGP_SLPT_set6` / `ECGP_SLPT_clear` ⇒ 内核日志可判读 hook 是否真被调用（无需靠结果反推）。
3. 冗余触发：`SSDT-DeepIdle._TTS` 内写同一变量（`IDLE_TTS=0xN` 标记）。理由：S0ix 睡眠是否触发 `_PTS` 未知（<80%），`_TTS` 是已证被 macOS 睡眠调用的钩子（DeepIdle 本身就靠它）。两个钩子写同一字段同一值，不改变单变量性质，标记可区分。
4. 部署：workspace 与 ESP 双写，sha 一致 —— config `ffebc913…`、SSDT-EC-GPE.aml `66204ada…`、SSDT-DeepIdle.aml `4e557da6…`。

**v2 判读（重启后）**：先查 `(SSDT: ECGPE)` 是否仍报 AE_ALREADY_EXISTS（无错 = rename 生效、钩子已装）；再睡眠读 `deep_idle_last_stats` + 日志标记。仍全 C3 ⇒ EC 降噪路线阴性（§五 ②）。

## 八、v2 上机判决：阴性（2026-11-20 14:39–14:46）

**上机前提已证**：14:30:00 boot 的表集含 `SSDT … ECGP ECGPE 00002000` 与 `OCLT IDLE 00001001`，**无** `(SSDT: ECGPE) while loading table`、无伴随 `AE_ALREADY_EXISTS` ⇒ 两条 rename 生效、`_PTS`/`_WAK` 钩子已进命名空间（>95%，撞名必然报错故"无错"即证）。

**取样**：powerd 14:39:19 入睡（`Software Sleep pid=218`）→ 14:45:53 唤醒（`Wake from Deep Idle [CDNVA] due to PWRB/User`），共 6m34s；`deep_idle_count: 1`，`last_stats = 0:05:38 CC7:0% C2:0% C3:99% C6:0% C7:0% C8:0% C9:0% C10:0%`。

**判决（≥85% 阴性）**：与注入前基线逐字段一致（C3:99%、C6–C10 全零）。机制上的必要性论证更强于结果本身：`C3:99%` 意味着包级**稳定停在 C3**、切换开销仅 1%，即失效模式是「**许可上限**（LTR permit 只到 C3）」而非「GPE 噪声反复拉出低功耗态」。SLPT=0x06 的作用恰恰是**降噪**；无噪声可降 ⇒ 结构上不可能抬高 C3 天花板。故即使钩子未执行，结论也不会翻为阳性。

**唯一未坐实项（<80%，未知）**：钩子是否真的执行过。`Debug` 标记在日志中为空——ACPICA 的 AML `Debug` 输出受 `AcpiDbgLayer` 门控，默认关闭，因此"无标记"**不能**推断"未执行"（也**不能**推断已执行）。若要坐实需再加一次「故意触发 AE_NOT_FOUND 的探针 + 重启 + 睡眠」，收益仅把 85% 抬到 95%，对已机制性否决的路线不值得（用户"配合优先级最低"原则）。

**副产品证据**：本次为 AC 供电睡眠；`kIOMessageSystemWillPowerOn` 明确派发到 `com.apple.driver.AppleACPIPlatform`（唤醒侧 ACPI 栈参与），与"macOS Deep Idle 走 AppleACPIPlatform"自洽；睡眠窗口内仍有 130 行日志（Deep Idle 非全冻结），但 `deep_idle` 统计保持 C3 连续。

**结论**：EC 降噪 GPE 路线**阴性收束**，与 §54（平台/PCH 侧）结论合并。DeepIdle 用户态 + ACPI 侧候选至此全部试尽，3.6W 地板=最终接受态（>90%）；重启条件维持：macOS 大版本 PM 改动 / 社区 CML-H 包级 C6 数据 / IGPU #967 修复。

## 九、勘误（14:50 复查）：§八 的"阴性"判决作废 —— v2 样本无效，原因是 _WAK 在 _PTS 后 19ms 就把 SLPT 清零

**触发**：用户要求"再看下"。复读 14:39–14:46 全窗口日志，命中两条此前漏看的 AppleACPIPlatform 自有日志：

```
14:40:12.762518  (AppleACPIPlatform) ACPI SLEEP
14:40:12.781448  (AppleACPIPlatform) ACPI S0 WAKE
14:40:12.782530  (AppleACPIPlatform) AppleACPIPlatformPower Wake reason: PWRB (User)
14:39:21.736287  PMRD: kIOMessageSystemWillSleep[3] to com.apple.driver.AppleACPIPlatform
```

**推算（精确到毫秒）**：

| 事件 | 时间 | 差 |
|---|---|---|
| powerd 决定睡眠 | 14:39:19.673 | — |
| AppleACPIPlatform 收到 WillSleep | 14:39:21.736 | +2.06s |
| `ACPI SLEEP`（_PTS 求值） | 14:40:12.762518 | +53.09s |
| `ACPI S0 WAKE`（_WAK 求值） | 14:40:12.781448 | **+18.9ms** |
| 真实唤醒 | 14:45:50.999780 | +5m38.2s |

`deep_idle_last_stats = 0:05:38` 与 14:40:12.762 → 14:45:50.999 的 **5m38.2s** 完全吻合 ⇒ 被统计的整段空闲窗口，起点就在 `_WAK` 之后 19ms。

**结论**：v2 的 `_PTS` 写入 `SLPT=0x06` 后，`_WAK` 在 19ms 内把它写回 0（Deep Idle 的目标态是 S0，S3 已被 rename 掉，所以 _WAK 紧跟 _PTS）。测量的 5m38s 全程 `SLPT=0` ⇒ **v2 样本对 SLPT 无任何信息量，§八 的"阴性"判决作废**。另：v2 的写入还挂在 `If (Arg0 == One)` 条件下，而 macOS 在 S0ix 路径传入的 Arg0 未文档化，是否曾写入亦不可判读。

**同时撤回的推理**：§八 用「`C3:99%` ⇒ 无 GPE 噪声 ⇒ SLPT 无意义」做机制性否决，该推理**不成立**：1Hz 的 EC GPE 每次退出只耗数百微秒，C3 占空比仍可保持 99%；而 PC6/C10 进入要求足够长的连续空闲窗口，1Hz 噪声足以卡住 PC6 却不会把 C3% 拉低。两种失效模式（许可上限 / 噪声卡门）在 C3 占空比上不可区分。

**v3（已部署，rev 00003000，sha `8ac3d719…`）**：

1. `_PTS` **无条件**写 `SLPT = 0x06`（去掉 Arg0 条件）。
2. `_WAK` **不写任何值**（只转调 ZWAK），使 SLPT 在整个空闲窗口保持 6。
3. `SSDT-DeepIdle` 回退原版（`0206720a…`），移除 `_TTS` 内的写入——`_TTS(0)` 同样会在唤醒瞬间清零，属同一陷阱。
4. 代价（明确接受）：唤醒后 SLPT 保持 6 直到重启，期间 EC 可能降低电池/AC 事件上报频率；EC RAM 易失，重启即归零。

**v3 判读**：睡眠后读 `deep_idle_last_stats`。C6–C10 非零 ⇒ 噪声门成立（突破）；仍全零 ⇒ 真正阴性（此时可确定 SLPT 确实被保持，结论有效）。

## 十、v3 有效样本与最终判决：阴性（15:11–15:29，电池 18m46s）

**样本有效性已核**：

| 事件 | 时间 | 备注 |
|---|---|---|
| powerd 入睡 | 15:11:05 | `Entering Sleep state due to 'Software Sleep pid=218' ... Using Batt (Charge:100%) 1126 secs` |
| `ACPI SLEEP`（`_PTS`） | 15:11:59.749363 | 与 `_WAK` 相距 19ms，同 v2 模式（S0ix 目标态=S0） |
| `ACPI S0 WAKE`（`_WAK`） | 15:11:59.768238 | v3 的 `_WAK` 不写 SLPT ⇒ 窗口内 SLPT 恒为 6 |
| 真实唤醒 | 15:29:51 | `Wake from Deep Idle [CDNVA] : due to PWRB/User Using BATT`，WakeTime 2.726s |

`deep_idle_last_stats = 0:17:50` 与 15:11:59.75→15:29:49.7 的 1070s 吻合，即整段被测窗口都在 `_WAK` 之后，v2 那个「19ms 自我清零」的陷阱已不存在。

**结果**：

```
0:17:50  CC7:0%  C2:21%  C3:78%  C6:0% C7:0% C8:0% C9:0% C10:0%
```

**判决**：主判据（C6–C10 非零）**未达成**，实测 C6 及以上全零（>95%，直接读数）。EC 静默模式 `SLPT=0x06` 无法打开包级 C6 门 ⇒ 与 §九 提出、§十 检验的「噪声卡门」假说相反：**降噪不是缺失的那一环**。与「许可上限（LTR 只到 C3）」结论（§54/§88 主结论）一致。

**副产品（把握度 ~65%，非结论）**：本样本出现 `C2:21%`，而此前三次基线全为 `C2:0% C3:98–100%`（11-16 电池 5m13s、11-20 14:39 AC 5m38s）。若这一偏移确由 `SLPT=6` 引起，则反过来是该写入**确实生效**的唯一正证（`Debug` 标记被 ACPICA 门控、无法直接观测）。但方向是**变浅**（C2 取代部分 C3），并非更深，即该写入要么无效、要么副作用为负。分歧因素仅样本长度（17:50 vs 5:13/5:38），无其它已知混杂。

**处置**：实验收束，EFI 回退 known-good 基线 —— `git checkout 24e7be2 -- EFI/OC`，删除 `SSDT-EC-GPE.dsl/.aml`（workspace 与 ESP 双侧），`SSDT-DeepIdle` 恢复原版。config sha 回到 `851f0d98`，DeepIdle `0206720a`，`plutil -lint` 双绿，ESP 无 ECGPE 残留，下次重启生效。保留实验记录于 git 历史（`bd7fb47`、`5f9f5f7`、`c4e7ba3`）。
