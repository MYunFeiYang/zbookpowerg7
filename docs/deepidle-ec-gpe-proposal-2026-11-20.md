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
