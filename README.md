# zbookpowerg7

面向 **HP ZBook Power G7**（Intel Comet Lake / 10 代移动平台）的 **OpenCore** Hackintosh EFI。仓库内为当前在用的 **`EFI/oc/`** 配置：含 **`config.plist`**、编译后的 **ACPI SSDT**（`.aml`）、**Kernel 扩展**及 **`EFI/scripts/`** 脚本；**`docs/SysReport/`** 为本机 ACPI 表导出。

*OpenCore EFI for HP ZBook Power G7, Comet Lake, SMBIOS MacBookPro16,4, macOS 26 (Darwin 25). iGPU + WhateverGreen (igfxonln=1); dGPU 由 SSDT-dGPU-PowerOff-Darwin 在 Darwin 下断电。音频 AppleALC 1.9.9 + SimpleHDA 1.0.0（不写系统卷，Sealed: Yes）；Wi‑Fi Intel AX201 走 AirportItlwm-Tahoe；Ethernet I219-LM + IntelMausi。Trackpad ELAN on I²C + VoodooI2C/VoodooI2CHID，走 GPIO 中断。Sleep via SSDT-DeepIdle + AOAC helpers；oc-setup.sh 管理 pmset / 耳麦 / 雷电档位 / 合盖关机。雷电 JHL7540 当前「放控制器 + 屏蔽 TB 驱动栈」档（USB-C 保留 USB3）。*

## 当前配置事实

| 项目 | 本项目中的情况 |
|------|----------------|
| 机型 | HP ZBook Power G7（移动工作站） |
| 平台 | Intel Comet Lake PCH |
| SMBIOS | MacBookPro16,4 |
| 核显 | Intel UHD，WhateverGreen + 定制 DeviceProperties；`igfxonln=1` 缓解睡眠/唤醒 IGPU panic |
| 独显 | Quadro P620（Pascal）Darwin 下由 `SSDT-dGPU-PowerOff-Darwin` 执行 `_OFF` 断电；实测 `PEG0@1` 根端口在、二级总线为空、全树 NVIDIA `vendor-id` 命中 0（未枚举），仅用核显 |
| 有线网 | Intel Ethernet I219-LM → `IntelMausi.kext` |
| 无线网 | Intel Wi‑Fi 6 AX201（`8086:06F0`）→ `AirportItlwm-Tahoe` 2.4.0（`MinKernel` 25.0.0 / `MaxKernel` 25.99.99），实测可正常读出 SSID / BSSID |
| 蓝牙 | `IntelBluetoothFirmware` + `BlueToolFixup_Mod`（`MinKernel 21.0.0`）+ `IntelBTPatcher`（`MinKernel 21.0.0`） |
| 声卡 | Realtek ALC236（Codec 实测为 ALC236，非 ALC285）→ `AppleALC 1.9.9` + `SimpleHDA 1.0.0`；`PciRoot(0x0)/Pci(0x1F,0x3)` 注入 `layout-id=55` + `hda-gfx=onboard-1`。`layout 55` = ALC236 for HP-240G8 by 8DireZ3，外放/耳机实测正常 |
| 内置麦克风 | 不支持：真麦挂 Intel SoundWire（`HDAS.SNDW`），macOS 无 Intel SST 驱动；`SSDT-SNDW-off.aml` 在 Darwin 下把 `SNDW._STA` 置 0，系统信息里那个「内置麦克风」是 layout 造的空壳。耳机孔麦可用（layout 55） |
| 触控板 | ELAN073D（ACPI `TPD3`）+ `SSDT-TPD3-PIN2`（提供 `TPNM`，`gpioPin = 258`）+ `SSDT-I2C0-GNVS` + `VoodooI2C` / `VoodooI2CHID`，走 GPIO 中断 |
| USB | `USBToolBox_Mod` + `UTBMap_tahoe`（`MinKernel 25.0.0`） |
| 风扇转速 | 可读：`SMCSuperIO` EC 模式，`Pci(0x1F,0x0)` 注入 `ec-device=generic` + `fan0-addr=0x2E`，监控软件（如 Stats）可显示 RPM |
| 雷电 | Intel JHL7540（Titan Ridge）@ `_SB.PCI0.RP01.PXSX`；当前档位 = 放控制器 + 屏蔽 TB 驱动栈（详见「已知限制 → 雷电」）；BIOS 安全级别 = SL1 |
| 存储 | 西数 WD Blue SN570；换盘或升级系统后请自行回归测试 |
| 安全启动 / SIP | `csr-active-config` = `0x0FFF`（SIP 全关） |

## 引导参数（boot-args）

当前实际值：`-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall revpatch=sbvmm rtcfx_exclude=0E-FF keepsyms=1`

- `igfxonln=1` / `igfxrpsc=1` —— 缓解 IGPU 睡眠/唤醒 panic（#967 freeze-panic）
- `igfxblt` —— KBL/CFL 上 macOS 13.4+ 的背光寄存器替代修法
- `igfxhdmidivs` —— SKL/KBL/CFL 高像素时钟 HDMI 死循环规避
- `revpatch=sbvmm` —— 让不受支持机型也能收到 OTA 更新
- `keepsyms=1` —— 保留内核符号名，便于定位音频栈问题
- `-amfipassbeta` / `-lilubetaall` / `rtcfx_exclude=0E-FF` —— 当前保留项

## 睡眠与节能

统一入口：**`sh EFI/scripts/oc-setup.sh`**（`install-all` / `status` / `pmset` / `mic` / `lid` / `tb`）。

- Deep Idle 路径：`SSDT-DeepIdle` + `SSDT-PCI0.LPCB-Wake-AOAC`；无传统 S3，睡眠期实测约 **5.5–5.6 %/h ≈ 3.7–3.8 W**（未用墙插功率计校准，±30%）。
- 休眠/睡眠策略由 `oc-setup.sh pmset`（→ `pmset-hibernate.sh`）直接写 `pmset` 参数实现。推荐一次执行 `oc-setup.sh install-all`（含 pmset 收紧、耳麦自动切换）；系统更新后 `oc-setup.sh pmset` 可重跑。
- 查睡眠记录用 `powerlog` 的 `PLSleepWakeAgent_EventForward_PowerState`（`pmset -g log` 只保留当前 boot）。测掉电必须**拔电**睡（AC 睡眠的掉电率无物理意义）。

### 雷电（固定屏蔽，无档位切换）
两条机制叠加：
- **`ACPI/Add` → `SSDT-thunderbolt-nhi-disable.aml`**：只在 `Darwin` 下隐藏 NHI（`_SB.PCI0.RP01.PXSX`），
  保留 `TXHC` / `AppleUSBXHCITR`（走 MSI）⇒ USB-C 仍以 USB3 工作；
- **`Kernel/Block`** → `com.apple.iokit.IOThunderboltFamily` + `com.apple.driver.AppleThunderboltNHI`（`Strategy=Disable`）。

判据：`ioreg -c IOThunderboltController | grep -c IOThunderboltController` = **0**；
`kextstat | grep -ci AppleThunderboltNHI` = **0**；`ioreg -c AppleUSBXHCITR` ≥ **1**。

限制：雷电 PCIe 隧道不可用（扩展坞 / eGPU / 40Gbps 雷电盘）；C 口仅 USB 模式（≤10Gbps）。

合盖即关机（可选）：`oc-setup.sh lid install`。

## 目录与安装

| 路径 | 说明 |
|------|------|
| `docs/macos-mic-troubleshooting.md` | 内置麦结论（硬件拓扑、macOS 验证） |
| `docs/simplehda-migration-2026-10-23.md` | 音频迁移记录 |
| `EFI/oc/` | `OpenCore.efi`、`Drivers`（9 个：`AudioDxe` / `OpenCanopy` / `OpenRuntime` / `HfsPlus` / `OpenLinuxBoot` / `ext4_x64` / `ResetNvramEntry` / `ToggleSipEntry` / `FirmwareSettingsEntry`）、`Kexts`（25 个 bundle）、`config.plist`、`ACPI/`（`.aml`）、`Tools`（`OpenShell.efi`） |
| `EFI/boot/` | 引导相关文件 |
| `docs/SysReport/` | 本机 ACPI 表导出 |
| `EFI/scripts/` | `oc-setup.sh` 统一入口（pmset、耳麦切换、雷电档位、合盖关机、ESP 挂载等） |

将整个 **`EFI`** 复制到 ESP 分区根目录（与 `EFI/oc` 同级），按 OpenCore 常规流程使用。

⚠️ 注意事项：
- `EFI/oc/` 下不要放非必需 plist（如 `oldConfig.plist`），同步任务会一并镜像进 ESP。备份请放到 `EFI/` 之外。
- ESP 上可能出现 `.dsl`（同步不区分扩展名）；与 `.aml` 不构成 8.3 冲突，不影响启动，不必清理。
- `EFI/oc/` 已纳入版本控制，不要用 `git checkout -- EFI/` 还原，会静默把 OC 核心换回旧版。

## 引导器与 kext 版本

运行中的引导器版本以 NVRAM 为权威读数：

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version
# → REL-109-2026-10-11 | MOD
```

| 组件 | 运行版本 | 官方最新正式版 |
|------|----------|----------------|
| OpenCore 核心 | `REL-109-2026-10-11 \| MOD` | 1.0.8（1.0.9 尚未发布） |
| RTCMemoryFixup | 1.0.8 | 1.0.7 |

- OC 1.0.8 changelog 的 hibernation 条目针对真 Mac，与本机 S4 无关。
- 涉及「某问题是否已在某版本修掉」的判断，落到具体 commit / changelog 条目比对，不拿版本号当正式版比对。

## 已知限制

- **内置麦克风**：不支持（Intel SoundWire，macOS 无 SST 驱动）。耳机孔麦可用（layout 55）；或 3.5mm TRRS 耳麦 / USB 麦 / 蓝牙麦。**Windows 侧驱动齐全，麦是好的。**
- **独显**：不支持。Quadro P620 是 Pascal，NVIDIA 驱动止步于 macOS 10.13.6（Web Driver）；现由 `SSDT-dGPU-PowerOff-Darwin` 在 Darwin 下 `_OFF` 断电，仅用核显。
- **雷电**（Intel JHL7540 @ `_SB.PCI0.RP01.PXSX`）：三档由 `oc-setup.sh tb off|on|lite` 切换。当前档位见上文「睡眠与节能 → 雷电档位」。判据（精确匹配）：
  ```
  ioreg -lw0 | grep -oE '<class (IOThunderboltController|AppleThunderboltNHIType3|AppleThunderboltHAL),' | sort | uniq -c   # 期望 0
  ioreg -lw0 | grep -c '<class AppleUSBXHCITR,'   # 期望 1
  ```
  系统信息 →「雷雳/USB4」显示 `No drivers are loaded.`。「关闭卡」不要点（会 panic）。无 TB 设备长期使用时建议 `tb off`。
- **睡眠/唤醒**：IGPU 曾触发 SafeForceWake panic，已加 `igfxonln=1`，另用 `igfxrpsc=1` 缓解 IGPU #967 freeze-panic。当前基线：常态 **DarkWake = 0**、**WakeTime ≈ 2.4 s**、无 panic、约 **5.5–5.6 %/h ≈ 3.7–3.8 W**。夜间是 Software Sleep 不是关机；唤醒后负载尖峰多因 DarkWake = 0 让维护唤醒积压一次性释放，非异常。

## 常见问题

**安装时要拷什么？**  
复制整个 **`EFI`** 到 ESP 根目录；有效配置在 **`EFI/oc/`**。

**无线用哪个驱动？**  
本机 AX201（`8086:06F0`，CNVi 走 **iwx** 分支）：macOS 26 下用 **`AirportItlwm-Tahoe` 2.4.0**（单 kext）。具体以 `config.plist` 里各 kext 的 `Enabled` 与内核范围为准。

**触控板为什么能工作？**  
**I²C ELAN073D**（ACPI `TPD3`）+ **VoodooI2C** / **VoodooI2CHID**，配合 **`SSDT-TPD3-PIN2`** + **`SSDT-I2C0-GNVS`**，走 **GPIO 中断**（实际 `gpioPin = 258`）——不是 polling。排障只看 `gpioPin`：**258 = 正常**，**0 = 中断引脚表没加载**（触控板整条失效）。

**雷电扩展坞能用吗？**  
取决于 **`tb`** 档位：**`off`** 时 macOS 不加载 TB；**`lite` / `on`** 时控制器与 NHI 可挂载。建议：**`tb on`** 或 **lite** → 开机前插好 → 再试热插拔与睡眠唤醒；不稳则 **`tb off`**。

**睡眠唤醒卡死 / 重启？**  
先查 **`/Library/Logs/DiagnosticReports/Kernel-*.panic`**。本机曾见：**IGPU SafeForceWake**（已加 **`igfxonln=1`**）与 **`IOThunderboltFamily`**（与雷电 **`on`** 档相关）。雷电实验请优先观察 **lite** 是否稳定，不行用 **`tb off`**。

**内置麦克风为什么不能用？**  
内置麦是 **Intel SoundWire 数字麦**（`HDAS.SNDW`），macOS 没有 Intel SST 驱动 ⇒ 无解。替代方案：**3.5mm TRRS 耳麦**（选「线路输入」，layout 55 有电平）/ USB 麦 / 蓝牙麦。**Windows 侧驱动齐全，麦是好的。**

**系统升级注意什么？**  
升级前先核 **`config.plist` → `Kernel` → `Add`** 里每个 kext 的 `MinKernel` / `MaxKernel`：  
① **`AirportItlwm-Tahoe`** `MaxKernel = 25.99.99` ⇒ 升 **macOS 27** 前必须先拿到支持 Darwin 26 的版本并改内核范围，否则升级后无 Wi‑Fi；  
② **`SimpleHDA`** 把 **AppleHDA 600.2 整套静态编进 kext**（运行时解压注册、不写系统卷）⇒ 大版本若 AppleHDA 主版本跨代，需等 SimpleHDA 跟进。SimpleHDA 不依赖 root patch，升级不会把系统卷 seal 弄坏。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
