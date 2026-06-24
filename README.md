# zbookpowerg7

面向 **HP ZBook Power G7**（**Intel Comet Lake** / 10 代移动平台）的 **OpenCore** Hackintosh EFI。仓库内为当前在用的 **`EFI/oc/`** 配置：含 **`config.plist`**、**ACPI SSDT**（含 `.dsl`）、**Kernel 扩展**及 **`EFI/scripts/`** 合盖关机相关脚本；**`EFI/SysReport/`** 为同机型 ACPI 导出，便于对照修改。

*OpenCore EFI for **HP ZBook Power G7**, Comet Lake, SMBIOS **MacBookPro16,4**. iGPU + **WhateverGreen** (`igfxonln=1`); dGPU suppressed (**`-wegnoegpu`**). Wi‑Fi **Intel AX201** via **AirportItlwm** (Sonoma/Sequoia) and **itlwm** (Darwin 25+); Ethernet **I219-LM** + **IntelMausi**. Trackpad **ELAN** on I²C + **VoodooI2C** / **VoodooI2CHID**, **`-vi2c-force-polling`**. Sleep: **SSDT-DeepIdle** + AOAC helpers; **`oc-setup.sh`** pmset / 耳麦 / 雷电档位 / 合盖关机等。雷电 **JHL7540** 默认 **lite** 实验档（见下）。*

## 与本项目配置对应的事实

以下与当前 **`EFI/oc/config.plist`** 及 ACPI 目录一致，便于他人检索「同机型 / 同芯片组」时命中本仓库。

| 项目 | 本项目中的情况 |
|------|----------------|
| 机型 | HP ZBook Power G7（移动工作站） |
| 平台 | Intel **Comet Lake** PCH（配置内设备属性与 SSDT 注释一致） |
| SMBIOS | **MacBookPro16,4**（`PlatformInfo` → `SystemProductName`） |
| 核显 | Intel UHD，`WhateverGreen` + 定制 **DeviceProperties**；**`igfxonln=1`** 缓解睡眠/唤醒时 IGPU panic |
| 独显 | NVIDIA 禁用（**`-wegnoegpu`** 等引导参数；**`SSDT-dGPU-PowerOff-Darwin`**） |
| 有线网 | **Intel Ethernet I219-LM** → **`IntelMausi.kext`** |
| 无线网 | **Intel Wi‑Fi 6 AX201** → **`AirportItlwm`**（按 **Sonoma / Sequoia** 分内核启用）+ 面向 **Darwin 25+** 的 **`itlwm.kext`**（以 `MinKernel`/`MaxKernel` 为准，勿重复启用冲突版本） |
| 蓝牙 | **IntelBluetoothFirmware** + **BlueToolFixup** + **IntelBTPatcher** |
| 声卡 | **AppleALC** + **Realtek ALC236**（`layout-id` **`55`** + **`alctcsel=1`**；见 `config.plist` → `Pci(0x1F,0x3)`） |
| 内置麦克风 | **不支持**（Intel SST/SoundWire **数字麦**；macOS 已实测无输入电平；详见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md)） |
| 触控板 | **ELAN073D**（ACPI 中 **TPD3**；**`SSDT-TPD3-CRS` / `SSDT-TPD3-INI`**、**`SSDT-I2C0-GNVS`** 等）+ **VoodooI2C** 系 |
| USB | **USBToolBox** + **UTBMap** |
| 风扇转速 | **可读**（EC 自主控速，macOS 不干预）。`SMCSuperIO` EC 模式：`Pci(0x1F,0x0)` 注入 `ec-device=generic` + `fan0-addr=0x2E`（DSDT `FRDC` 寄存器，参数同 ZBook 17 G5），监控软件（如 Stats）可显示 RPM |
| 雷电 | **Intel JHL7540**（Titan Ridge）；三档：**`tb off` / `tb on` / `tb lite`**（见「睡眠与节能」「已知限制 → 雷电」）；仓库默认 **lite** |
| 验证存储 | **西数 WD Blue SN570**；换盘或升级系统后请自行回归测试 |

## 睡眠与节能（配置级说明）

macOS 辅助脚本统一入口：**`sh EFI/scripts/oc-setup.sh`**（`install-all` / `status` / 各子命令）。

- 启用 **Deep Idle** 路径：**`SSDT-DeepIdle`**、**`SSDT-PCI0.LPCB-Wake-AOAC`**，并与 **`SSDT-OCLT-S3Fix`** 等协同；**无传统 S3**，空闲仍可能有约 **5W** 级功耗（视外设、雷电档位与 `pmset` 而定）。  
- **`HibernationFixup`** 与当前策略一致。推荐一次执行 **`oc-setup.sh install-all`**（含 pmset 收紧、耳麦自动切换）；系统更新后 **`oc-setup.sh pmset`** 可重跑。  
- **雷电档位**（改 `config.plist` 后须同步 ESP 并重启）：
  - **`tb off`** — **`SSDT-thunderbolt-disable`**：最省电，macOS 不加载 TB 栈；
  - **`tb on`** — **`SSDT-TB3HP-ZBook`**：`force-power`，功能最全、空口功耗最高；
  - **`tb lite`** — **`SSDT-TB3HP-ZBook-lite`**（**当前默认**）：无 `force-power`，保留唤醒 `_DSW`，实验降功耗；若睡眠/唤醒不稳请改 **`tb off`** 或 **`tb on`**。
- 合盖即关机（可选）：**`oc-setup.sh lid install`**。

## 目录与安装

| 路径 | 说明 |
|------|------|
| `docs/macos-mic-troubleshooting.md` | **内置麦最终结论**（硬件拓扑、macOS 验证、停止排查说明） |
| `EFI/oc/` | OpenCore **`OpenCore.efi`**、**Drivers**、**Kexts**、**`config.plist`**、**`ACPI/`**（`.aml` 与部分 **`.dsl`** 源码） |
| `EFI/boot/` | 引导相关文件 |
| `EFI/SysReport/` | 本机 ACPI 表导出 |
| `EFI/scripts/` | **`oc-setup.sh`** 统一入口；含 pmset、耳麦切换、**雷电档位**（`tb-thunderbolt-profile.sh`）、合盖关机、ESP 挂载等 |

将整个 **`EFI`** 复制到 **ESP 分区根目录**（与 **`EFI/oc`** 同级），按 OpenCore 常规流程使用。

## 已知限制

- **内置麦克风**：**不支持**（Intel SST / SoundWire 数字麦；2026-06-11 已验证无电平）。**勿再**为内置麦改 layout。  
- **耳机孔麦克风**：**可用**（`layout 55`）。**自动切换**：`sh EFI/scripts/oc-setup.sh mic install`（优先级：**蓝牙 > 有线 > 内置麦**）；或手动选输入设备。  
- **独显**：**不支持，且无解**。Quadro P620（Pascal）的 NVIDIA 驱动止步于 macOS 10.13；当前经 `-wegnoegpu` + `SSDT-dGPU-PowerOff-Darwin` 屏蔽并断电（已验证 IOReg 中无 NVIDIA 设备），仅使用核显。这是最优状态，勿再尝试驱动。  
- **雷电**：**Intel JHL7540** 于 **`_SB.PCI0.RP01.PXSX`**。三档由 **`sh EFI/scripts/oc-setup.sh tb off|on|lite`** 切换（亦可用 **`tb-thunderbolt-profile.sh`**）：
  - **off** — `SSDT-thunderbolt-disable.aml`：Darwin 下隐藏 RP01，**空口功耗最低**；
  - **on** — `SSDT-TB3HP-ZBook`：热插拔 + **`force-power`** + 唤醒 **`_DSW`**；**勿** `power-save=1`（会破坏 Deep Idle 唤醒）；
  - **lite**（**当前默认**）— `SSDT-TB3HP-ZBook-lite`：保留热插拔与 **`_DSW`**，**不注入 `force-power`**，用于在「省电」与「可用 TB」之间试探；**稳定性待验证**。
  2026-06-12 曾验证 USB-C（TXHC）可用；2026-06-17 曾出现 `IOThunderboltFamily` 唤醒 panic（`on` 档）。**无 TB 设备长期使用时建议 `tb off`**。拿到 TB 设备可先 **`tb on`** 或保持 **lite** 实测睡眠/唤醒与热插拔。回退：**`tb off`**。同类参考：[ZBook 17 G5](https://github.com/theroadw/Zbook-G5-17-WX-4170)。  
- **睡眠/唤醒**：核显在 Deep Idle 唤醒时曾触发 **IGPU SafeForceWake** panic；已加 boot-arg **`igfxonln=1`**。蓝牙/Wi‑Fi 睡眠 hook 已移除，交由 macOS 与 **`pmset-reduce-wake.sh`** 管理。  
- **系统升级**：大版本升级后请核对 **AirportItlwm / itlwm** 与 **IOSkywalkFamily** 等是否需替换或调整启用范围（以 **`config.plist` → `Kernel` → `Add`** 为准）。**注意**：当前 Wi‑Fi 相关 kext 的 `MaxKernel` 均为 `25.99.99`（即 macOS 26.x）；**升级 macOS 27 前必须先取得支持 Darwin 26 的版本并调整内核范围，否则升级后无 Wi‑Fi**。

## 常见问题

**安装时要拷什么？**  
复制整个 **`EFI`** 到 ESP 根目录；有效配置在 **`EFI/oc/`**。

**无线用哪个驱动？**  
本机 **AX201**：主要为 **AirportItlwm**（按 **macOS 14 / 15** 选择对应条目）及新系统下的 **itlwm**；具体以当前 **`config.plist`** 里各 kext 的 **`Enabled`** 与内核版本范围为准。

**触控板为什么能工作？**  
**I²C ELAN** + **VoodooI2C** / **VoodooI2CHID**，配合 **TPD3** 相关 **SSDT**；引导参数含 **`-vi2c-force-polling`**（见 **`boot-args`**）。

**雷电扩展坞能用吗？**  
取决于 **`tb`** 档位：**`off`** 时 macOS 不加载 TB；**`lite` / `on`** 时控制器与 NHI 可挂载。2026-06-12 曾验证 USB-C（TXHC）；PCIe 隧道/热插拔**尚无扩展坞长期实测**。建议：**`tb on`** 或 **lite** → 开机前插好 → 再试热插拔与睡眠唤醒；不稳则 **`tb off`** 或退回 **`tb on`**。见「已知限制 → 雷电」。

**睡眠唤醒卡死 / 重启？**  
先查 **`/Library/Logs/DiagnosticReports/Kernel-*.panic`**。本机曾见：**IGPU SafeForceWake**（已加 **`igfxonln=1`**）与 **`IOThunderboltFamily`**（与雷电 **`on`** 档相关）。雷电实验请优先观察 **lite** 是否稳定，不行用 **`tb off`**。

**内置麦克风为什么不能用？**  
内置麦是 **Intel 数字麦克风**（SoundWire），不是 Realtek ALC236 模拟麦；Hackintosh 上 **无驱动**，已实测无效。扬声器/耳机仍由 **AppleALC** 驱动。完整说明见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md)。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
