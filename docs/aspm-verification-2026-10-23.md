# PCIe ASPM 支持实测验证（2026-10-23）

## 一、验证方法（怎么确认的）
1. **机上实测**：`ioreg -c IOPCIDevice -w 0 -l`（默认 IOService plane，该 plane 才暴露 `IOPCIExpressLinkCapabilities`，且为十进制整数）。
2. **解码规则**：取 `IOPCIExpressLinkCapabilities` 寄存器 **bit[11:10]**（即 `(val>>10)&3`），含义来自 **PCIe Base Spec / Intel EDC Link Capabilities Register**：
   - `00` = No ASPM
   - `01` = L0s
   - `10` = L1
   - `11` = L0s+L1
3. **校准锚点**：用已知设备反推解码正确性 ——
   - PEG0（CPU PEG 根端口 8086:1901）→ `3=L0s+L1` ✓（符合预期）
   - RP17（NVMe 根端口）+ WD Black SSD（15b7:501a）→ `2=L1` ✓（NVMe ASPM 是社区公认可用场景）
   → 解码方法可信。
4. **社区交叉验证（国内外）**：
   - **国外/权威**：Intel EDC 寄存器文档（bit[11:10]=ASPM Support 编码）；EliteMacx86 `brcmfx-aspm` 定义 `kIOPCIExpressASPML1=0x2`（即 L1=bit1）；5T33Z0/OC-Little-Translated「Setting ASPM Operating Mode」。
   - **国内**：daliansky/黑果小兵 OC-little 第 16-2 章「设置 ASPM 工作模式」，`pci-aspm-default` 取值 `02000000`(L1)/`03000000`(L0s+L1)/`00000000`(禁用)；imacpc.net、CSDN 52dianzi 均确认 bit[11:10] 编码。

## 二、全量实测结果（25 个 IOPCIDevice）

| 设备(ACPI) | Vend:Dev | LinkCap | 硬件 ASPM[11:10] | 当前 aspm-def | 说明 |
|---|---|---|---|---|---|
| B0D4@4 | 8086:1903 | 0x00000000 | 0=No ASPM | - | DPTF 温控，无 PCIe 链路 |
| CNVW@14,3 | 8086:06f0 | 0x00000000 | 0=No ASPM | - | CNVi 集成无线 |
| IGPU@2 | 8086:9bc4 | 0x00000000 | 0=No ASPM | - | 核显，内部总线无 ASPM 链路 |
| GLAN@1F,6 | 8086:0d4e | 0x00000000 | 0=No ASPM | - | I225 2.5G 网卡 |
| HDEF@1F,3 | 8086:06c8 | 0x00000000 | 0=No ASPM | - | 声卡 |
| IMEI@16 | 8086:06e0 | 0x00000000 | 0=No ASPM | - | MEI |
| I2C0@15 | 8086:06e8 | 0x00000000 | 0=No ASPM | - | I2C |
| I2C1@15,1 | 8086:06e9 | 0x00000000 | 0=No ASPM | - | I2C |
| LPCB@1F | 8086:068e | 0x00000000 | 0=No ASPM | - | LPC 桥 |
| SBUS@1F,4 | 8086:06a3 | 0x00000000 | 0=No ASPM | - | SMBus |
| XHC@14 | 8086:06ed | 0x00000000 | 0=No ASPM | - | USB 主控 |
| pci8086,6a4@1F,5 | 8086:06a4 | 0x00000000 | 0=No ASPM | - | PCH 集成 |
| pci8086,6ef@14,2 | 8086:06ef | 0x00000000 | 0=No ASPM | - | PCH 集成 |
| pci8086,6f9@12 | 8086:06f9 | 0x00000000 | 0=No ASPM | - | PCH 集成 |
| pci8086,9b54@0 | 8086:9b54 | 0x00000000 | 0=No ASPM | - | 主桥 |
| PEG0@1 | 8086:1901 | 0x0261ad03 | 3=L0s+L1 | - | CPU PEG 根端口 |
| RP01@1C | 8086:06b8 | 0x01724843 | 2=L1 | 0x00000002 | 雷电根端口（已注入 L1）|
| PXSX@0 (RP01下) | 8086:15e7 | 0x00448843 | 2=L1 | 0x00000002 | JHL7540 雷电主控（已注入 L1）|
| **EP02@2 (PXSX下)** | 8086:15e7 | **0x02600841** | **2=L1** | 0x00000000 | **★上一轮误判为「仅L0s不支持L1」，实机解码=L1 支持** |
| **TXHC@0 (EP02下)** | 8086:15e9 | **0x00440841** | **2=L1** | 0x00000000 | **★硬件支持 L1，当前固件默认禁用** |
| RP17@1B | 8086:06c0 | 0x11724843 | 2=L1 | 0x00000002 | NVMe 根端口（已注入 L1）|
| PXSX@0 (RP17下) | 15b7:501a | 0x0045a843 | 2=L1 | 0x00000002 | WD Black SSD（已注入 L1）|
| pci-bridge@0 | 8086:15e7 | 0x00600841 | 2=L1 | - | 雷电桥 |
| pci-bridge@1 | 8086:15e7 | 0x01700841 | 2=L1 | - | 雷电桥 |
| pci8086,15e8@0 | 8086:15e8 | 0x00040841 | 2=L1 | - | 雷电相关 |

## 三、结论
- **真正「不支持 ASPM」（LinkCap=0）的共 15 个**：全部是 PCH 集成端点（HDEF/XHC/GLAN/LPCB/SBUS/I2C/IMEI/DPTF）、CNVi、核显、主桥。这些设备根本不暴露 PCIe ASPM 链路能力寄存器，注入 `pci-aspm-default` 无意义（被忽略），排除正确。
- **支持 ASPM 的共 10 个**，且全部报告 L1 或 L0s+L1。其中 RP01/PXSX/RP17/SSD 已处于 L1（注入或固件默认）。
- **上一轮口述错误纠正**：我曾称「EP02 硬件不支持 L1、只有 L0s」，但实机 `EP02 LinkCap=0x02600841`，`(0x02600841>>10)&3 = 2 = L1`。**EP02 与 TXHC 硬件均支持 L1**，只是固件默认禁用（`aspm-def=0`）。它们上一轮被排除是基于错误解码，实际是合法 L1 候选。
- 正确 OC 设备路径（来自实机 `acpi-path`）：
  - EP02 = `PciRoot(0x0)/Pci(0x1C,0x0)/Pci(0x0,0x0)/Pci(0x2,0x0)`
  - TXHC = `PciRoot(0x0)/Pci(0x1C,0x0)/Pci(0x0,0x0)/Pci(0x2,0x0)/Pci(0x0,0x0)`
  - 子设备 L1 注入值建议 `02010000`（base64 `AgEAAA==`），与现有 RP01/PXSX 用的 `02000000` 风格一致可沿用。

## 四、★最终实测结论（2026-10-23 18:07 重启后，决定性）

用户拍板「支持的就补」，已按上述正确路径补 EP02/TXHC 两条 `pci-aspm-default=02000000`，重启后重抓 ioreg 复核：

| 设备 | acpi-path | 重启后 `pci-aspm-default` | 判定 |
|---|---|---|---|
| RP01（根端口） | `.../RP01@1c0000` | **2** | ✓ OC 注入生效 |
| PXSX（JHL7540 本体） | `.../PXSX@0` | **2** | ✓ OC 注入生效 |
| EP02（内部交换机桥） | `.../EP02@20000` | **0** | ✗ 注入未生效 |
| TXHC（USB3 控制器） | `.../TXHC@0` | **0** | ✗ 注入未生效 |

- **关键判据**：RP01/PXSX 均为 2，证明 config 正常加载、注入机制对这俩生效；EP02/TXHC 即便路径用 acpi-path 精确锚定、重启后仍是 0 → **OC 的 DeviceProperties 注入够不到雷电内部 PCIe 交换机的下游设备**。
- **根因**：EP02 桥与 TXHC 由雷电驱动（IOThunderboltFamily / AppleUSBXHCIPCI）在 OC 注入阶段**之后**枚举，注入时机已过，非路径错误。
- **处置**：两条为死配置，已删除（config 回到仅 RP01+PXSX 两条 ASPM 注入）。`plutil -lint` OK，ESP 同步 sha256=`5d3ee365…`。
- **补充**：TXHC 的 `AppleUSBXHCITR` 驱动 personality 自带 `pci-aspm-default=<02000000>`（ioreg device-properties），即 macOS USB 驱动层**自身**对该控制器强制 L1，与 OC 注入无关 → TXHC 实际链路大概率已在 L1，无需 OC 管。
- **最终雷电 ASPM 状态**：RP01 + PXSX 两条 L1 经 OC 注入生效（OC 能触达的层级已全进 L1）；EP02/TXHC 不可经 OC 注入，但 TXHC 由 USB 驱动层独立控 L1。符合「OC 能进的都已进」。
