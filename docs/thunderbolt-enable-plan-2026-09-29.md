# 雷电 3 启用可行性方案 — ZBook Power G7 / i7-10750H / macOS 26.7

> 生成于 2026-09-29。本文是**可行性评估 + 执行草案**，未改动任何 EFI 文件。
> 改动前请以 `docs/backups/` 为回滚点、按"git 备份 → 最小改动 → plutil 校验 → 手工同步 ESP → 两侧 sha256 一致"流程执行。

---

## 一、当前为什么没有雷电（根因，已实读确认）

四项叠加，全是"主动禁用/缺配置"，**非硬件缺陷**：

| # | 现状（实读 config） | 影响 |
|---|---|---|
| 1 | `Kernel/Quirks.DisableIoMapper = True` | macOS 下 VT-d（AppleVTD）被关闭 |
| 2 | `ACPI/Delete` 含 `DMAR` 表删除条目（signature=DMAR） | DMAR 表在 macOS 下被摘 |
| 3 | `SSDT-thunderbolt-disable.aml` 禁的是 `_SB.PCI0.RP01` 的 `_STA` | **端口错位**——雷电控制器挂在 RP17/18/19 一带（见 §二证据），RP01 不是雷电端口 |
| 4 | 无 `SSDT-TB3`/`SSDT-TB4` 注入、无 `ThunderboltReset.kext` | 控制器即使被枚举也缺 device-id/compatible 属性，macOS 不认 |

雷电 NHI 控制器在 macOS 下工作**必需** AppleVTD + DMAR 表 + 正确注入。`#1+#2+#3+#4` 同时成立 ⇒ 系统报告 "Thunderbolt/USB4: No hardware was found" 是必然结果。

> 补充：当年那次 `ThunderboltFamily null pointer` panic，根因极可能就是"控制器被枚举但缺注入/VT-d 错配"导致的空指针解引用——正确注入 + VT-d 应可规避，但需在启用后实测验证。

---

## 二、可行性证据（关键：同机型已成功）

- **硬件确认有真雷电 3**：HP 官方 QuickSpecs 写明 "USB Type-C® with Thunderbolt™"；规格源确认 = Thunderbolt 3（40Gbps、DP 1.2、USB 3.1 Gen2）。
- **DSDT 雷电抽象层存在**：`THBA` MMIO 基地址 `0xFE200000`（Titan/Alpine Ridge 类）、`RTBT`/`TBTS` 符号、`RP17/18/19` 为独立 PCIe root port 设备节点。
- **同机型黑苹果成功案例**（installhackintosh）：
  - macOS Sonoma 14.4.1，**i7-10750H（与本机完全一致）**，雷电 3 `Yes`，列在 Working 项。
  - macOS Sequoia 15.7.1，i9-10885H，雷电 3 `Yes`，列在 Working 项。
  - ⇒ 本机硬件在黑苹果下**驱动雷电 3 是可行的**，且已有可对照的配置先例。

---

## 三、标准启用方案（6 步）

> ⚠️ **本节基于「标准 SSDT-TB3 注入」假设，经 DSDT 实读已证不适用**——本机是 BIOS 托管雷电、ACPI 无 NHI 节点。正确路线见下方 **§三(重要修正)**。

> 顺序很重要：先定位端口 → 写注入 → 加 kext → 恢复 VT-d/DMAR → 去错位禁用 → BIOS/Windows 授权。

**Step 1 — 定位雷电控制器端口路径（先决条件，必须在 Windows/Linux 下做）**
- Windows 下用 RWEverything 看 ACPI 表，找 `UPSB`/`DSB0`/`NHI0` 设备，记下它挂在哪个 `_SB.PCI0.RPxx`；或用 Linux live USB 跑 `lspci -tvnn` 看 JHL 控制器归属的 PCI 路径（如 `PciRoot(0x0)/Pci(0x1B,0x0)`）。
- 同时记下控制器的 VID/DID（Titan Ridge 常见 `0x15e8`/`0x15da` 一类），用于注入 device-id。
- **这一步我无法在当前 macOS 下完成**（已被禁用），需要你提供 Windows 侧或 Linux 侧的输出。

**Step 2 — 写 `SSDT-TB3`（或 SSDT-TB4）注入**
- 在 Step 1 定位到的 `RPxx` 上用 `_DSM` 注入：`device-id`、`compatible`（如 `pci8086,15e8`）、`model`（"Thunderbolt 3 Controller"）。
- **必须 `_OSI("Darwin")` 门控**（本机铁律：所有 ACPI 改动须门控，否则作用到 Windows）。
- 参考 Dortania Thunderbolt 指南 + Hackindrom SSDT-TB3 模板改写。

**Step 3 — 加 `ThunderboltReset.kext`（acidanthera）**
- 自动重置控制器，解决"冷启动不识别 / 热插拔失效"。放到 `Kernel/Add`，顺序在 Lilu/VirtualSMC 之后。

**Step 4 — 恢复 VT-d / DMAR（最 tricky 的一步）**
- 改 `DisableIoMapper = False`。
- 移除 `ACPI/Delete` 里的 `DMAR` 条目（保留系统 DMAR 表）。
- 但**恢复 VT-d 可能与本机现有设备冲突**（这正是当年关掉它的可能原因）——需逐设备验证 WiFi/以太网/USB 仍正常。
- 折中选项：用较新的 `DisableIoMapperMapping = True`（限制 IOMMU 映射范围但**不完全关 VT-d**），可能既能保住其它设备又够雷电用，但需实测。
- 若冲突，按 OC 惯例用 `DMAR.aml`（保留原表、加 `Reserved Memory` 区域或剔除无关 IOMMU 域）精细修复。

**Step 5 — 移除错位禁用**
- 删除 `SSDT-thunderbolt-disable.aml` 的加载项（它禁的是 RP01，本就不是雷电端口；保留反而可能误伤其它挂 RP01 的设备）。

**Step 6 — BIOS + Windows 授权（你来做）**
- 进 BIOS：雷电安全设为 **No Security**（或开启 PCIe tunneling）；HP BIOS 选项命名可能特殊，需你进 BIOS 实际确认。
- **关键痛点**：必须在 **Windows 下先热插拔一次 TB 设备**完成固件授权，再回 macOS——这是黑苹果雷电的通用死穴，绕不过。

---

## 四、最大风险点（诚实告知）

1. **VT-d 恢复冲突**：本机现有设备（AX201 网卡、I219 以太网、USB 控制器）当年可能因 VT-d 出问题才被关掉。恢复后需逐设备回归测试，失败则回退到 `DisableIoMapper=True` 或 `DisableIoMapperMapping=True`。**这是整件事唯一的高风险变量。**
2. **HP BIOS 雷电授权机制**：不像消费级主板有清晰的 Security 选项，HP 的实现可能特殊，需你进 BIOS 实测确认有无可设项。
3. **当年 null pointer panic 根因**：假设是缺注入/VT-d 错配，正确方案应可解；但属"推断级"，需启用后实测坐实。
4. **收益上限**：即使成功，通常是"热插拔 + 外接显示"可用；eGPU 支持弱，不要预期满血。

---

## 五、你需要配合的三件事

1. **进 BIOS 看雷电相关选项**（Security 级别 / PCIe tunneling），截图或告诉我有哪些可设项。
2. **Windows 下热插拔授权一次** TB 设备（这是 Step 6 的硬前提）。
3. **提供端口定位输出**：Windows RWEverything 的雷电设备路径，或 Linux `lspci -tvnn` 的 JHL 控制器路径 + VID/DID。

---

## 六、回滚

- 每步独立可回滚：`DisableIoMapper` 改回 `True`、`ACPI/Delete` 加回 `DMAR`、恢复 `SSDT-thunderbolt-disable`、移除 `ThunderboltReset.kext` 与 `SSDT-TB3`。
- 回滚点：`docs/backups/oc-2026-09-29-tpd-fix/`（已有的 config 备份）或新建 `docs/backups/oc-2026-09-29-tb/`。

---

## 七、结论

本机雷电 3 **在硬件层可行**（同机型同 CPU 已有黑苹果成功案例），当前"没有雷电"是四重主动禁用 + 缺注入叠加所致，不是硬件不行。标准启用方案（定位端口 → SSDT-TB3 注入 → ThunderboltReset.kext → 恢复 VT-d/DMAR → 去错位禁用 → BIOS/Windows 授权）在社区是成熟路线，但**唯一的高风险变量是"恢复 VT-d 可能与本机现有设备冲突"**，需逐设备回归验证。能否推进，取决于你能否提供 BIOS 雷电选项信息 + Windows 侧端口定位输出——这两样齐了，我就能写出可执行的 SSDT-TB3 草案并分步验证。

---

## §二(补) 同机型成功案例已坐实（带可查证 URL）

- **案例 A**：installhackintosh — HP Zbook Power G7 / **i7-10750H**（与本机完全一致）/ macOS Sonoma 14.4.1 / OpenCore r1.0.0 / **Thunderbolt 3: Yes**（Working 列表）。规格与本机几乎一致：32GB DDR4、UHD630、AX201、ALC236、ELAN 触控板。URL: https://www.installhackintosh.com/mac/about-hackintosh?catid=8&id=2043
- **案例 B**：installhackintosh — HP Zbook Power G7 / i9-10885H / macOS Sequoia 15.7.1 / OpenCore r1.0.6 / **Thunderbolt: Yes**（Working 列表）。URL: https://installhackintosh.com/mac/instalasi-hackintosh/success-hackintosh-macos-sequoia-15-7-1-build-24g231-in-hp-zbook-power-g7-mobile-workstation
- 两案例**未公开具体 EFI/SSDT 做法**，但作为「本机硬件在黑苹果下驱动雷电 3 可行」的铁证成立；具体实现需进一步从其 EFI 或社区帖求证。

## §三(重要修正) 本机是「BIOS 托管雷电」，标准 SSDT-TB3 路线不适用

**证据（已实读 DSDT + 全部 OEM SSDT，反编译于 /tmp 未污染 EFI）**：
- 整个 DSDT 及所有 SSDT（含 SSDT-16/17）**均无标准雷电 NHI 节点**（`UPSB`/`DSB0`/`NHI0`/`Titan`/`Ridge`/`JHL` 全零命中）。
- 雷电完全由 BIOS 的 OEM SSDT（`SSDT-17`）管理：含 `TBTS`/`RTBT`/`RPS0`/`RPS1` 状态标志 + `THDR`/`TINI`/`_L24`(GPE 唤醒) 一整套固件交互逻辑；`_L24` 据 RPS0/RPS1 决定 Notify 哪个 RP（RP01–RP20）。
- `PCI_TBT1/TBT2` 字符串仅出现在 `\_SB.PCI0.I2C4` 针脚设备的 `_DSM` 里，是机箱丝印标签名，非 ACPI 设备节点。
- `THBA@0xFE200000` 是 BIOS 辅助方法（读写 NHI MMIO），不属于某 Device 的 OperationRegion。

**结论**：本机雷电控制器在 ACPI 命名空间里**不被暴露为可注入的 NHI 对象**，因此 OC-Little 标准 `SSDT-TB3`（依赖在 `UPSB/DSB0/NHI0` 上做 `_DSM` 注入）**在本机无目标节点、无法套用**。上一轮「写 SSDT-TB3 注入」的假设作废。

**修正后的启用路线（BIOS 托管路径）**：
1. BIOS 设 `Thunderbolt Security Level = No Security`（或 `User Authorization`）+ `Thunderbolt Mode = On` + 关闭 `Require BIOS PW to change TBT SL`（如有）。
2. 删掉 `SSDT-thunderbolt-disable.aml`（禁 RP01 是错位的；本机由 BIOS 管理，macOS 下靠原生驱动认 BIOS 暴露的控制器）。
3. 恢复 AppleVTD：`DisableIoMapper = False`；并恢复/保留 `DMAR` 表（移除 `ACPI/Delete` 里的 DMAR 条目）—— NHI 原生驱动需要 VT-d + DMAR。
4. 加 `ThunderboltReset.kext`（acidanthera，自动扫描并复位 NHI，无需手填地址）。
5. 在 Windows（或 Linux）下用雷电设备热插拔授权一次（安全机制硬要求，HP SL0 可免，但预启动连接仍需）。
6. 重启进 macOS，由原生 `AppleThunderboltNHI` 枚举 BIOS 暴露的控制器。

**局限（诚实告知）**：HP BIOS 托管机型通常「能识别、可直连」，但热插拔/预启动连接行为弱于真 Mac；同案例也仅标 `Thunderbolt: Yes`，未证热插拔完美。恢复 VT-d 是否引爆现有设备（AX201/以太网/USB）需逐设备回归。

## §四 我能自取 vs 必须你做（回应「你自己不能获取吗」）

**我能从本机/公开资料自取（已完成）**：
- 硬件有真 TB3：HP 官方 QuickSpecs + DSDT `THBA@0xFE200000` MMIO + SSDT-17 完整 TB 固件逻辑 + 两个同机型案例 URL（§二补）。
- 当前无雷电根因：四重主动禁用叠加（DisableIoMapper=True / 删 DMAR / 错位 disable SSDT / 无注入）。
- **BIOS 雷电选项名与路径（HP 白皮书实锤）**：`Advanced → Port Options → Thunderbolt Security Level`（四级：No Security / User Authorization / Secure Connect / DisplayPort only）；另有 `Thunderbolt Mode`、`Require BIOS PW to change TBT SL`、`DMA Protection`(System Options)。
- 本机架构判定：BIOS 托管、DSDT 无 NHI 节点、标准 SSDT-TB3 不适用。

**必须你做的（物理上无法远程执行）**：
- 进 BIOS（F10）把 `Thunderbolt Security Level` 设为 `No Security`（或 User Authorization）+ `Thunderbolt Mode = On`；
- 在 Windows/Linux 下用雷电设备热插拔授权一次（雷电安全机制硬要求，任何方案都绕不过）。

**上轮我多要的「Windows lspci 端口/VID-DID」已撤回**：那是假定走标准 SSDT-TB3 路线的需求，本机 BIOS 托管路线下 macOS 原生驱动会自动枚举 NHI，无需先拿 VID/DID。上轮多此一举，抱歉。

---

## §五 BIOS 配置确定性复核（回应"确定 BIOS 有对应配置吗"）

**上轮不足**：此前称"HP 白皮书实锤"引的是 ZHP Technical White Paper（4AA7-5807ENW，通用于 2016–2019 带 TB 的 EliteBook/ZBook），**未针对本机型**。本轮补两级对口证据：

1. **本机型手册（ZBook Power G7 User Guide, pdf_10842067）**：故障排查表 Table 6-44 "Thunderbolt device not working" 明确写"Update to the latest BIOS and **choose appropriate TB Port settings**" → 证明**本机 BIOS 确有 Thunderbolt 端口设置项**。
2. **HP 官方支持文档（support.hp.com，cn-zh/tw-zh 双语）**：路径为 `Advanced → Thunderbolt Options → Thunderbolt Security Level`（下拉菜单）；另有 `Advanced → Port Options → Thunderbolt 安全保护级别`（SL0–SL4）。文档适用对象明确含"HP 商用笔记本/移动工作站（EliteBook、ZBook、ProBook）"。
3. **HP 用户指南（kaas.hpcloud pdf_10842067）**：列出 `高级 → 端口选项 → Thunderbolt 安全保护级别`，SL0=无安全 / SL1=用户授权 / SL2=安全连接 / SL3=仅 DP+USB / SL4=TB alt 模式（仅第5代支持）。

**置信度：高（非 100%）**。依据：① QuickSpecs 确认本机硬件有 TB3；② 本机手册明写 BIOS 有 TB Port settings；③ HP 官方文档给出 ZBook 的精确菜单位置。三者交叉，足以认定 BIOS 含 `Thunderbolt Security Level` 设置。

**诚实边界（必须说明）**：我**没有亲眼看到这台机器的 F10 实屏**。HP 在部分低配 BIOS 构建里可能隐藏该下拉（例如仅在 `Thunderbolt Mode=On` 后才出现，或某些 SKU 仅暴露 On/Off 不暴露 SL 级别）。因此：
- **最可能的确认方式**：你进 F10 看一眼（5 秒），路径按上述两种之一找。
- **若确实有** → 我的启用路线成立（SL0/No Security + ThunderboltReset + 恢复 VT-d/DMAR）。
- **若只有 On/Off 无 SL 级别** → 退而求其次：设 `Thunderbolt Mode=On`，靠 macOS 原生驱动在**预启动已连接**设备时枚举（热插拔授权能力弱，但仍可直连单设备）。
- **若完全无 Thunderbolt 项** → 说明 BIOS 未暴露，需走"USB4/原生 NHI 自动识别"路线或放弃（概率最低）。


---

## §五(补) BIOS 实拍证据（2026-09-29 16:44，用户进 F10 实拍两张）

### 图 1 — `Advanced → Thunderbolt Options`

| 项 | 实拍 | Windows 侧 BIOS 台账对照（`docs/backups/firmware-ledger-2026-09-20/win-side/HPBIOS-all.csv`） | 判定 |
|---|---|---|---|
| Thunderbolt Mode | ☑ 勾选 | L228 `"Thunderbolt Mode","Disable,*Enable"` | ✅ 一致 |
| Require BIOS PW to change Thunderbolt Security Level | ☑ 勾选 | L184 `"Require BIOS PW to change TBT SL","Disable,*Enable"` | ✅ 一致 |
| Thunderbolt Security Level | 下拉展开，**恰好 4 项**：PCIe and DisplayPort - User Authorization / - Secure Connect / DisplayPort and USB / Daisy Chaining Disabled | L229 `"Thunderbolt Security Level","*PCIe and DisplayPort - User Authorization,PCIe and DisplayPort - Secure Connect,DisplayPort and USB,Daisy Chaining Disabled"` | ✅ 一致（**无第 5 项**） |

**★ 关键结论（双源交叉，置信度=高）**

1. **该 CSV 里 `*` 前缀 = 当前值**——本轮拿到两处独立互证：`Thunderbolt Mode=*Enable` ↔ 实拍已勾选；`Require BIOS PW…=*Enable` ↔ 实拍已勾选。⇒ L229 的 `*` 落在 `User Authorization` ⇒ **本机当前 Security Level = SL1（User Authorization）**。
2. 实拍下拉框**顶边与选项行齐平、上方无溢出**，若存在 SL0 必向上溢出 ⇒ **该下拉就是全部 4 项，没有隐藏项**。
3. ⇒ **本机 BIOS 不提供 Security Level 0（No Security）**。HP 通用文档（HP PC Commercial BIOS Setup, 2020-07；ZBook User Guide pdf_10842067）列的是 SL0–SL4 五档，但**本机型这版 BIOS 只暴露 4 档**——所以 §三(重要修正) 第 1 步"设 No Security"**不是没找到，是不存在**。
4. 台账同批另给三项值（在别的页，本次未拍）：L230 `Thunderbolt Type-C Ports = *Enable`、L227 `Thunderbolt Controller Version = 62.0.1.2.1`、L43 `DMA Protection = *Disable`。

### 图 2 — `Advanced → Power Management Options`

- `Runtime Power Management` ☑｜`Extended Idle Power States` ☑｜`Power Control` ☑ ⇒ 这三项正是 **AOAC（Deep Idle / 仿 S0ix）** 的固件前提，**已全开，别动**（关掉等于砍掉 Deep Idle 能力，直接影响本机睡眠路线）。
- `Battery Health Manager`：当前值被弹层挡住（只见 "Le…"，推测 `Let HP manage my battery charging`）。它是 **EC/固件级**设置，**OS 无关（macOS 也吃）**；若被设成 `Maximize my battery health` 会把充电上限压到 ~80%。**建议顺手记下实际值**。
- **但本机问题不是充电上限**：实测 `ioreg -r -c AppleSmartBattery` → `MaxCapacity=5705` / `DesignCapacity=7170` = **79.6% 健康度**，`CycleCount=132`，`StateOfCharge=96%`，`ExternalConnected=Yes`，`IsCharging=No`。⇒ 旧记"电池 77%"是**电池健康度**（真实衰减），不是 BHM 限充。

---

## §六 对我上一轮报告的纠错（三处；以本仓库 git 历史 + 实测为准）

| # | 上轮 doc 的说法 | 事实与证据 | 影响 |
|---|---|---|---|
| 1 | §一 #3：「`SSDT-thunderbolt-disable` 禁 RP01 是**端口错位**，雷电悬挂在 RP17/18/19」 | **错。雷电就是 `_SB.PCI0.RP01.PXSX` 上的 JHL7540（Titan Ridge）**。证据四重：① README L77 明写「**Intel JHL7540** 于 **`_SB.PCI0.RP01.PXSX`**」；② config 注释 L75「Hide RP01 on Darwin - rollback if TB panic: enable this, disable SSDT-TB3HP-ZBook」；③ `bc660ef` 实测 PCI 拓扑：PXSX@0 下 device0=pci-bridge@0→`pci8086,15e8`(NHI)、device2=EP02@2→`TXHC@0`(`15e9` XHCI)；④ `2af04ad` 实测「NHI 8086:15e8 挂载 AppleThunderboltNHI、TXHC USB-C 口可用」 | 该 SSDT **正是雷电总开关**，谈不上"误伤"；上轮"错位"判断作废 |
| 2 | §三(重要修正)：「本机 BIOS 托管、标准 SSDT-TB3 不适用 ⇒ 需**新写** SSDT-TB3 注入」 | **错/冗余。本机早有自研件**：`SSDT-TB3HP-TITAN.aml`（6-12 首版）→ `SSDT-TB3HP-ZBook.aml` / `-lite.aml`（6-17 / 6-24）→ `SSDT-TB3NHI-ZBook.aml`（9-14 补设备树，已证否），并由 `EFI/scripts/tb-thunderbolt-profile.sh` 做 `off/on/lite` 三档切换。这些 `.aml` 已在 9-14 / 9-17 清理中删除，**可从 git 取回**：`git show ad8fcd2^:EFI/OC/ACPI/SSDT-TB3HP-ZBook-lite.aml > EFI/oc/ACPI/SSDT-TB3HP-ZBook-lite.aml` | 不需要从零写 |
| 3 | §三 第 3 步：「NHI 原生驱动**必需** AppleVTD ⇒ 必须 `DisableIoMapper=False` + 恢复 DMAR；并把此列为"整件事唯一的高风险变量"」 | **推论不成立**。雷电实验全程四个提交（`2ae4799` / `f76a982` / `0fcd63b` / `49cde16`）**`DisableIoMapper` 恒为 `true`**，而 6-12 实测 NHI 挂载成功、TXHC 可用 ⇒ **VT-d/AppleVTD 不是本机雷电枚举的前提** | 上轮标为最高风险的"恢复 VT-d"**不用做**，风险面直接缩小 |

---

## §七 裁决：雷电一线维持 `off`（附唯一还有意义的窄口实验）

**本轮 BIOS 实拍把最后一条外部依赖也关掉了**：SL0 不存在；而 SL1（User Authorization）恰恰是本机唯一"保留 PCIe 隧道且不需密钥"的档位（SL2 需设备端证书/密钥做挑战-应答；SL3 = 仅 DP+USB，砍 PCIe；SL4 = 禁菊花链）。HP BIOS 参考对 SL1 的定义是「**用户先前选过 Always Connect 的设备，后续插入时自动接入 PCIe 总线**」——授权记录在控制器/固件侧，**理论跨 OS 生效**（可"Windows 授权一次 → 回 macOS 直连"）。**但这条路的硬前提是"手上要有一个雷电设备"**，而 `0fcd63b` 已记录「用户无雷电设备」。

**收益/代价当前量化（来自仓库实测，非推断）**

| 档位 | USB-C 能力 | 已知风险 |
|---|---|---|
| `off`（当前） | **USB2 only**（USB2 走主板 XHC 的 `HS05`，不进 RP01；USB3 走雷电 TXHC 的 `SS01`，随 RP01 一起消失） | ExpressCard 幻影槽不加载 ⇒ 无 panic；功耗最低 |
| `on` / `lite` | **恢复 USB 3.x**（6-12 实测 TXHC 可用） | ① 8-24 `IOThunderboltFamily` NULL panic（ExpressCard 幻影槽"关闭卡"触发，`Kernel-2026-08-24-120649.panic`）；② 6-17 唤醒期 `IOThunderboltFamily`；③ 9-14 半初始化（`IOThunderboltController` LocalNode/Port 恒 `!registered/!matched`）。**且 TB 设备本身仍不可用**（9-14 补设备树 SSDT 已判否） |

**若真要动，只剩一个窄口实验**——「**只放控制器、屏蔽 TB 驱动栈**」：

> RP01 恢复可见（让 `15e9` XHCI 上电枚举）＋ `Kernel/Block` 屏蔽 `com.apple.driver.AppleThunderboltNHI`（掐掉 ExpressCard 幻影槽与 `IOThunderboltFamily` 依赖链）＋ **不加** force-power / 不加设备树 SSDT。
> **依据**：`15e9`(XHCI) 与 `15e8`(NHI) 是控制器下**并列**的两个下游设备，XHCI 不依赖 NHI kext；`UTBMap_tahoe.kext` 里**已有 `TXHC` personality + `SS01` 端口**（当年 TB 期做的映射，现成可用）。
> **判据**：重启后 `ioreg -c AppleUSBXHCITR` ≥1 实例且含 `SS01`；`ioreg -c IOThunderboltController` 与 `pgrep -lf ExpressCard` 均为 0；插 USB-C 设备实测速率 >480 Mbps。
> **回滚**：`sh EFI/scripts/oc-setup.sh tb off`（一条命令回到今天状态）。
> ⚠️ **未验证点（自曝）**：屏蔽 NHI 是否能真正消除 ExpressCard 幻影槽，属**推断**（依据=该槽随 TB 栈出现/消失）；若不成立，panic 面仍在——但它是**用户点菜单才触发**，非自动崩。

**推荐**：**维持 `off`**。仅当你确实有 USB-C 硬盘/扩展坞被 480 Mbps 卡住时，才值得做上面这个窄口实验。
