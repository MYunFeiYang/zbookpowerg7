# zbookpowerg7

面向 **HP ZBook Power G7**（**Intel Comet Lake** / 10 代移动平台）的 **OpenCore** Hackintosh EFI。仓库内为当前在用的 **`EFI/oc/`** 配置：含 **`config.plist`**、**ACPI SSDT**（含 `.dsl`）、**Kernel 扩展**及 **`EFI/scripts/`** 合盖关机相关脚本；**`EFI/SysReport/`** 为同机型 ACPI 导出，便于对照修改。

*OpenCore EFI for **HP ZBook Power G7**, Comet Lake, SMBIOS **MacBookPro16,4**. iGPU + **WhateverGreen**; dGPU suppressed (**`-wegnoegpu`**). Wi‑Fi **Intel AX201** via **AirportItlwm** (Sonoma/Sequoia) and **itlwm** (Darwin 25+); Ethernet **I219-LM** + **IntelMausi**. Trackpad **ELAN** on I²C + **VoodooI2C** / **VoodooI2CHID**, **`-vi2c-force-polling`**. Sleep: **SSDT-DeepIdle** + AOAC helpers; optional lid shutdown scripts. **Thunderbolt JHL7540** not fully tested.*

## 与本项目配置对应的事实

以下与当前 **`EFI/oc/config.plist`** 及 ACPI 目录一致，便于他人检索「同机型 / 同芯片组」时命中本仓库。

| 项目 | 本项目中的情况 |
|------|----------------|
| 机型 | HP ZBook Power G7（移动工作站） |
| 平台 | Intel **Comet Lake** PCH（配置内设备属性与 SSDT 注释一致） |
| SMBIOS | **MacBookPro16,4**（`PlatformInfo` → `SystemProductName`） |
| 核显 | Intel UHD，`WhateverGreen` + 定制 **DeviceProperties**（含 `ig-platform-id` 等） |
| 独显 | NVIDIA 禁用（**`-wegnoegpu`** 等引导参数；**`SSDT-dGPU-PowerOff-Darwin`**） |
| 有线网 | **Intel Ethernet I219-LM** → **`IntelMausi.kext`** |
| 无线网 | **Intel Wi‑Fi 6 AX201** → **`AirportItlwm`**（按 **Sonoma / Sequoia** 分内核启用）+ 面向 **Darwin 25+** 的 **`itlwm.kext`**（以 `MinKernel`/`MaxKernel` 为准，勿重复启用冲突版本） |
| 蓝牙 | **IntelBluetoothFirmware** + **BlueToolFixup** + **IntelBTPatcher** |
| 声卡 | **AppleALC** + **Realtek ALC236**（`layout-id` **`55`** + **`alctcsel=1`**；见 `config.plist` → `Pci(0x1F,0x3)`） |
| 内置麦克风 | **不支持**（Intel SST/SoundWire **数字麦**；macOS 已实测无输入电平；详见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md)） |
| 触控板 | **ELAN073D**（ACPI 中 **TPD3**；**`SSDT-TPD3-CRS` / `SSDT-TPD3-INI`**、**`SSDT-I2C0-GNVS`** 等）+ **VoodooI2C** 系 |
| USB | **USBToolBox** + **UTBMap** |
| 风扇转速 | **可读**（EC 自主控速，macOS 不干预）。`SMCSuperIO` EC 模式：`Pci(0x1F,0x0)` 注入 `ec-device=generic` + `fan0-addr=0x2E`（DSDT `FRDC` 寄存器，参数同 ZBook 17 G5），监控软件（如 Stats）可显示 RPM |
| 雷电 | **Intel JHL7540**（Titan Ridge）**已启用**：`SSDT-TB3HP-TITAN` 开、`SSDT-thunderbolt-disable`/`SSDT-RP01` 关；NHI 驱动已挂载，USB-C 口可用；详见「已知限制 → 雷电」 |
| 验证存储 | **西数 WD Blue SN570**；换盘或升级系统后请自行回归测试 |

## 睡眠与节能（配置级说明）

macOS 辅助脚本统一入口：**`sh EFI/scripts/oc-setup.sh`**（`install-all` / `status` / 各子命令）。

- 启用 **Deep Idle** 路径：**`SSDT-DeepIdle`**、**`SSDT-PCI0.LPCB-Wake-AOAC`**，并与 **`SSDT-OCLT-S3Fix`**、**`SSDT-GPRW`** 等协同；**无传统 S3**，空闲仍可能有约 **5W** 级功耗（视外设与 `pmset` 而定）。  
- **`HibernationFixup`** 与当前策略一致。推荐一次执行 **`oc-setup.sh install-all`**（含 pmset 收紧、耳麦自动切换、睡眠 hook）；系统更新后 **`oc-setup.sh pmset`** 可重跑。  
- 合盖即关机（可选）：**`oc-setup.sh lid install`**。

## 目录与安装

| 路径 | 说明 |
|------|------|
| `docs/macos-mic-troubleshooting.md` | **内置麦最终结论**（硬件拓扑、macOS 验证、停止排查说明） |
| `EFI/oc/` | OpenCore **`OpenCore.efi`**、**Drivers**、**Kexts**、**`config.plist`**、**`ACPI/`**（`.aml` 与部分 **`.dsl`** 源码） |
| `EFI/boot/` | 引导相关文件 |
| `EFI/SysReport/` | 本机 ACPI 表导出 |
| `EFI/scripts/` | **`oc-setup.sh`** 统一入口；含 pmset、耳麦切换、睡眠 hook、合盖关机、ESP 挂载等 |

将整个 **`EFI`** 复制到 **ESP 分区根目录**（与 **`EFI/oc`** 同级），按 OpenCore 常规流程使用。

## 已知限制

- **内置麦克风**：**不支持**（Intel SST / SoundWire 数字麦；2026-06-11 已验证无电平）。**勿再**为内置麦改 layout。  
- **耳机孔麦克风**：**可用**（`layout 55`）。**自动切换**：`sh EFI/scripts/oc-setup.sh mic install`（优先级：**蓝牙 > 有线 > 内置麦**）；或手动选输入设备。  
- **独显**：**不支持，且无解**。Quadro P620（Pascal）的 NVIDIA 驱动止步于 macOS 10.13；当前经 `-wegnoegpu` + `SSDT-dGPU-PowerOff-Darwin` 屏蔽并断电（已验证 IOReg 中无 NVIDIA 设备），仅使用核显。这是最优状态，勿再尝试驱动。  
- **雷电**：**已启用，部分验证**（2026-06-12）。当前 `SSDT-TB3HP-TITAN` 开启、`SSDT-thunderbolt-disable` 与 `SSDT-RP01` 关闭（后者的 `RP01._DSM` 与 TB3HP 冲突，二者**不可同开**）。实测：控制器枚举正常（`RP01/PXSX` 下 NHI `8086:15e8` 挂载 `AppleThunderboltNHI`，`IOThunderboltController` 活动），Titan Ridge 的 **USB-C 口（TXHC）可用**。系统信息显示「**未载入驱动程序**」为 **DROM 缺失**的表现（信息页读不到厂商描述块），**不代表驱动未挂载**，不影响 PCIe 隧道与 USB。**待验证**：真实 TB 设备的隧道与热插拔（暂无设备）。**勿加 `power-save=1`**：2026-06-12 实测在 `PciRoot(0x0)/Pci(0x1C,0x0)` 注入后**睡眠无法唤醒**（pmset 日志 `Failure during wake: IGPU(): Some drivers failed to handle setPowerState`），已移除。**回退 TB**：TB3HP 关、`thunderbolt-disable`/`RP01` 开。同类成功先例：[ZBook 17 G5](https://github.com/theroadw/Zbook-G5-17-WX-4170)（BIOS 安全级别 Legacy → No Security → Native + Low Power；本机 BIOS 未见这些选项，可在 Windows 用 HP BiosConfigUtility 查全量固件设置）。  
- **系统升级**：大版本升级后请核对 **AirportItlwm / itlwm** 与 **IOSkywalkFamily** 等是否需替换或调整启用范围（以 **`config.plist` → `Kernel` → `Add`** 为准）。**注意**：当前 Wi‑Fi 相关 kext 的 `MaxKernel` 均为 `25.99.99`（即 macOS 26.x）；**升级 macOS 27 前必须先取得支持 Darwin 26 的版本并调整内核范围，否则升级后无 Wi‑Fi**。

## 常见问题

**安装时要拷什么？**  
复制整个 **`EFI`** 到 ESP 根目录；有效配置在 **`EFI/oc/`**。

**无线用哪个驱动？**  
本机 **AX201**：主要为 **AirportItlwm**（按 **macOS 14 / 15** 选择对应条目）及新系统下的 **itlwm**；具体以当前 **`config.plist`** 里各 kext 的 **`Enabled`** 与内核版本范围为准。

**触控板为什么能工作？**  
**I²C ELAN** + **VoodooI2C** / **VoodooI2CHID**，配合 **TPD3** 相关 **SSDT**；引导参数含 **`-vi2c-force-polling`**（见 **`boot-args`**）。

**雷电扩展坞能用吗？**  
**未知，但基础已就绪**：TB 控制器与 NHI 驱动已挂载，USB-C 口已验证；PCIe 隧道/热插拔**尚无设备实测**（见「已知限制 → 雷电」）。拿到 TB 设备后建议先**开机前插好**测试，再试热插拔；不行再考虑 DROM 注入或 BIOS 安全级别（BiosConfigUtility）。

**内置麦克风为什么不能用？**  
内置麦是 **Intel 数字麦克风**（SoundWire），不是 Realtek ALC236 模拟麦；Hackintosh 上 **无驱动**，已实测无效。扬声器/耳机仍由 **AppleALC** 驱动。完整说明见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md)。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
