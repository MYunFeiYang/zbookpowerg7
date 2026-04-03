# zbookpowerg7

面向 **HP ZBook Power G7**（**Intel Comet Lake** / 10 代移动平台）的 **OpenCore** Hackintosh EFI。仓库内为当前在用的 **`EFI/oc/`** 配置：含 **`config.plist`**、**ACPI SSDT**（含 `.dsl`）、**Kernel 扩展**及 **`EFI/scripts/`** 合盖关机相关脚本；**`EFI/SysReport/`** 为同机型 ACPI 导出，便于对照修改。

*OpenCore EFI for **HP ZBook Power G7**, Comet Lake, SMBIOS **MacBookPro16,1**. iGPU + **WhateverGreen**; dGPU suppressed (**`-wegnoegpu`**). Wi‑Fi **Intel AX201** via **AirportItlwm** (Sonoma/Sequoia) and **itlwm** (Darwin 25+); Ethernet **I219-LM** + **IntelMausi**. Trackpad **ELAN** on I²C + **VoodooI2C** / **VoodooI2CHID**, **`-vi2c-force-polling`**. Sleep: **SSDT-DeepIdle** + AOAC helpers; optional lid shutdown scripts. **Thunderbolt JHL7540** not fully tested.*

## 与本项目配置对应的事实

以下与当前 **`EFI/oc/config.plist`** 及 ACPI 目录一致，便于他人检索「同机型 / 同芯片组」时命中本仓库。

| 项目 | 本项目中的情况 |
|------|----------------|
| 机型 | HP ZBook Power G7（移动工作站） |
| 平台 | Intel **Comet Lake** PCH（配置内设备属性与 SSDT 注释一致） |
| SMBIOS | **MacBookPro16,1**（`PlatformInfo` → `SystemProductName`） |
| 核显 | Intel UHD，`WhateverGreen` + 定制 **DeviceProperties**（含 `ig-platform-id` 等） |
| 独显 | NVIDIA 禁用（**`-wegnoegpu`** 等引导参数；**`SSDT-dGPU-PowerOff-Darwin`**） |
| 有线网 | **Intel Ethernet I219-LM** → **`IntelMausi.kext`** |
| 无线网 | **Intel Wi‑Fi 6 AX201** → **`AirportItlwm`**（按 **Sonoma / Sequoia** 分内核启用）+ 面向 **Darwin 25+** 的 **`itlwm.kext`**（以 `MinKernel`/`MaxKernel` 为准，勿重复启用冲突版本） |
| 蓝牙 | **IntelBluetoothFirmware** + **BlueToolFixup** + **IntelBTPatcher** |
| 声卡 | **AppleALC**（本机 **layout-id `55`** 等在 `config.plist` 的 `DeviceProperties` 中） |
| 触控板 | **ELAN073D**（ACPI 中 **TPD3**；**`SSDT-TPD3-CRS` / `SSDT-TPD3-INI`**、**`SSDT-I2C0-GNVS`** 等）+ **VoodooI2C** 系 |
| USB | **USBToolBox** + **UTBMap** |
| 雷电 | 设备属性中含 **Intel JHL7540**（Titan Ridge）；**`SSDT-TB3HP-TITAN`**、**`SSDT-thunderbolt-disable`**、**`SSDT-RP01`** 在配置中为 **关闭**，需自行评估后开启 |
| 验证存储 | **西数 WD Blue SN570**；换盘或升级系统后请自行回归测试 |

## 睡眠与节能（配置级说明）

- 启用 **Deep Idle** 路径：**`SSDT-DeepIdle`**、**`SSDT-PCI0.LPCB-Wake-AOAC`**，并与 **`SSDT-OCLT-S3Fix`**、**`SSDT-GPRW`** 等协同；**无传统 S3**，空闲仍可能有约 **5W** 级功耗（视外设与 `pmset` 而定）。  
- **`HibernationFixup`**、**`hibernatemode=0`** 等与当前策略一致。  
- 合盖即关机：**`EFI/scripts/`**（**`install-lid-shutdown.sh`** / **`uninstall-lid-shutdown.sh`**、**`lid-close-shutdown.sh`**、**`pmset-reduce-wake.sh`**、**`com.oc.lidshutdown.plist`**），按需部署。

## 目录与安装

| 路径 | 说明 |
|------|------|
| `EFI/oc/` | OpenCore **`OpenCore.efi`**、**Drivers**、**Kexts**、**`config.plist`**、**`ACPI/`**（`.aml` 与部分 **`.dsl`** 源码） |
| `EFI/boot/` | 引导相关文件 |
| `EFI/SysReport/` | 本机 ACPI 表导出 |
| `EFI/scripts/` | 合盖关机、**`pmset`** 辅助脚本；**`install-mount-esp.sh`** 安装后可在开机时自动挂载本机 ESP（**`com.oc.mountesp`**） |

将整个 **`EFI`** 复制到 **ESP 分区根目录**（与 **`EFI/oc`** 同级），按 OpenCore 常规流程使用。

## 已知限制

- **独显**：NVIDIA 无 Apple 官方驱动，仅使用核显。  
- **雷电**：硬件为 **JHL7540** 类 Titan Ridge，**本仓库未做完整外设与扩展坞验证**。  
- **系统升级**：大版本升级后请核对 **AirportItlwm / itlwm** 与 **IOSkywalkFamily** 等是否需替换或调整启用范围（以 **`config.plist` → `Kernel` → `Add`** 为准）。

## 常见问题

**安装时要拷什么？**  
复制整个 **`EFI`** 到 ESP 根目录；有效配置在 **`EFI/oc/`**。

**无线用哪个驱动？**  
本机 **AX201**：主要为 **AirportItlwm**（按 **macOS 14 / 15** 选择对应条目）及新系统下的 **itlwm**；具体以当前 **`config.plist`** 里各 kext 的 **`Enabled`** 与内核版本范围为准。

**触控板为什么能工作？**  
**I²C ELAN** + **VoodooI2C** / **VoodooI2CHID**，配合 **TPD3** 相关 **SSDT**；引导参数含 **`-vi2c-force-polling`**（见 **`boot-args`**）。

**雷电扩展坞能用吗？**  
未完整验证；若调试 TB，需结合 **`ACPI/`** 中可选表与 **`config.plist`** 中 **`ACPI` → `Add`** 的开关谨慎调整。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
