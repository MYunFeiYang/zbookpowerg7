# zbookpowerg7

面向 **HP ZBook Power G7**（**Intel Comet Lake** / 10 代移动平台）的 **OpenCore** Hackintosh EFI。仓库内为当前在用的 **`EFI/oc/`** 配置：含 **`config.plist`**、**ACPI SSDT**（仅 `.aml`）、**Kernel 扩展**及 **`EFI/scripts/`** 合盖关机相关脚本；**`docs/SysReport/`** 为本机 ACPI 表导出（2026-09 从 `EFI/` 外迁），便于对照修改。

*OpenCore EFI for **HP ZBook Power G7**, Comet Lake, SMBIOS **MacBookPro16,4**, macOS 26 (Darwin 25). iGPU + **WhateverGreen** (`igfxonln=1`); dGPU 由 **`SSDT-dGPU-PowerOff-Darwin`** 在 Darwin 下断电（**不依赖 `-wegnoegpu`**）。音频 **AppleALC 1.9.9 + SimpleHDA 1.0.0**（OC 注入 AppleHDA 600.2，**不再使用 OCLP root patch**，系统卷保持 `Sealed: Yes`）；Wi‑Fi **Intel AX201** 走 **AirportItlwm-Tahoe**（`MinKernel 25.0.0`）；Ethernet **I219-LM** + **IntelMausi**。Trackpad **ELAN** on I²C + **VoodooI2C** / **VoodooI2CHID**，走 **GPIO 中断**（`SSDT-TPD3-PIN2` 提供 `TPNM`，`gpioPin = 258`），**不是 polling**。Sleep: **SSDT-DeepIdle** + AOAC helpers; **`oc-setup.sh`** pmset / 耳麦 / 雷电档位 / 合盖关机等。雷电 **JHL7540** 当前「放控制器 + 屏蔽 TB 驱动栈」档（USB-C 保留 USB3）；`off` / `on` / `lite` 变体见下文。*

## 与本项目配置对应的事实

以下与当前 **`EFI/oc/config.plist`** 及 ACPI 目录一致，便于他人检索「同机型 / 同芯片组」时命中本仓库。

| 项目 | 本项目中的情况 |
|------|----------------|
| 机型 | HP ZBook Power G7（移动工作站） |
| 平台 | Intel **Comet Lake** PCH（配置内设备属性与 SSDT 注释一致） |
| SMBIOS | **MacBookPro16,4**（`PlatformInfo` → `SystemProductName`） |
| 核显 | Intel UHD，`WhateverGreen` + 定制 **DeviceProperties**；**`igfxonln=1`** 缓解睡眠/唤醒时 IGPU panic |
| 独显 | **Quadro P620（Pascal）未上电**：Darwin 下由 **`SSDT-dGPU-PowerOff-Darwin`** 执行 `_OFF` 断电，**不依赖 `-wegnoegpu`**（`boot-args` 里并没有它）。实测 `PEG0@1` 根端口在、二级总线为空 |
| 有线网 | **Intel Ethernet I219-LM** → **`IntelMausi.kext`** |
| 无线网 | **Intel Wi‑Fi 6 AX201**（`8086:06F0`）→ **`AirportItlwm-Tahoe` 2.4.0**（laobamac 的 Tahoe 分支，`MinKernel` 25.0.0 / `MaxKernel` 25.99.99）。**不再需要 `IOSkywalkFamily` / `IO80211FamilyLegacy`** —— 那是旧 Sequoia 方案的 OCLP 注入组件，已不在 `Kernel/Add` 中。实测可正常读出 SSID / BSSID |
| 蓝牙 | **IntelBluetoothFirmware** + **`BlueToolFixup_Mod`**（`MinKernel 21.0.0`）+ **IntelBTPatcher**（`MinKernel 21.0.0`） |
| 声卡 | **Realtek ALC236**（Codec 实测是 **ALC236，不是 ALC285**）→ **AppleALC 1.9.9** + **SimpleHDA 1.0.0**；`PciRoot(0x0)/Pci(0x1F,0x3)` 只注入 **`layout-id=55`** + **`hda-gfx=onboard-1`**（**没有 `alctcsel`**）。`layout 55` = `ALC236 for HP-240G8 by 8DireZ3`，外放/耳机实测正常 |
| 内置麦克风 | **不支持且不可修**：真麦挂 **Intel SoundWire**（`HDAS.SNDW`），macOS 无 Intel SST 驱动。本机 **`SSDT-SNDW-off.aml` 已在 Darwin 下把 `SNDW` 的 `_STA` 置 0**（`_OSI("Darwin")` 分支）⇒ 系统信息里那个「内置麦克风」是 layout 造的空壳，录制样本**全 0**。详见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md) |
| 触控板 | **ELAN073D**（ACPI 中 **TPD3**）；只靠 **`SSDT-TPD3-PIN2`**（提供 `TPNM`，`gpioPin = 258`）+ **`SSDT-I2C0-GNVS`** + **VoodooI2C** / **VoodooI2CHID**。**没有 `SSDT-TPD3-CRS` / `SSDT-TPD3-INI`** —— 那是旧方案残留，已不在 `ACPI/Add` 中 |
| USB | **`USBToolBox_Mod`** + **`UTBMap_tahoe`**（`MinKernel 25.0.0`，对应 macOS 26 的端口图） |
| 风扇转速 | **可读**（EC 自主控速，macOS 不干预）。`SMCSuperIO` EC 模式：`Pci(0x1F,0x0)` 注入 `ec-device=generic` + `fan0-addr=0x2E`（DSDT `FRDC` 寄存器，参数同 ZBook 17 G5），监控软件（如 Stats）可显示 RPM |
| 雷电 | **Intel JHL7540**（Titan Ridge）挂 **`_SB.PCI0.RP01.PXSX`**；三档：**`tb off` / `tb on` / `tb lite`**；**当前档位 = 放控制器 + 屏蔽 TB 驱动栈**（详见下文「雷电」节）；BIOS 安全级别 = **SL1**（2026-09-29 复核：只暴露 4 档、**无 SL0/No Security**）|
| 验证存储 | **西数 WD Blue SN570**；换盘或升级系统后请自行回归测试 |

## 睡眠与节能（配置级说明）

macOS 辅助脚本统一入口：**`sh EFI/scripts/oc-setup.sh`**（`install-all` / `status` / 各子命令）。

- 启用 **Deep Idle** 路径：**`SSDT-DeepIdle`** + **`SSDT-PCI0.LPCB-Wake-AOAC`**（**当前 `ACPI/Add` 里没有 `SSDT-OCLT-S3Fix`**，那是旧条目）；**无传统 S3**，睡眠期实测约 **5.5–5.6 %/h ≈ 3.7–3.8 W**（未用墙插功率计校准，±30%）。
- **没有 `HibernationFixup`**（`Kernel/Add` 里查不到该条目）；休眠/睡眠策略由 **`oc-setup.sh pmset`**（→ `pmset-hibernate.sh`）直接写 `pmset` 参数实现。推荐一次执行 **`oc-setup.sh install-all`**（含 pmset 收紧、耳麦自动切换）；系统更新后 **`oc-setup.sh pmset`** 可重跑。
- ⚠️ **查睡眠记录必须用 `powerlog` 的 `PLSleepWakeAgent_EventForward_PowerState`** —— `pmset -g log` 只保留当前 boot。测掉电必须**拔电**睡（AC 睡眠的掉电率没有物理意义）。  
- **雷电档位**（改 `config.plist` 后须同步 ESP 并重启）：
  - **`tb off`** — **`SSDT-thunderbolt-disable`**：最省电，macOS 不加载 TB 栈；
  - **`tb on`** — **`SSDT-TB3HP-ZBook`**：`force-power`，功能最全、空口功耗最高；
  - **`tb lite`** — **`SSDT-TB3HP-ZBook-lite`**：无 `force-power`，保留唤醒 `_DSW`；若睡眠/唤醒不稳请改 **`tb off`** 或 **`tb on`**。
  - ⚠️ **`on` / `lite` 的 `.aml` 已于 2026-09-14 / 09-17 清理中删除**（当时它们在 `off` 档下本就是禁用残留）。要重试先取回：`git show ad8fcd2^:EFI/OC/ACPI/SSDT-TB3HP-ZBook-lite.aml > EFI/oc/ACPI/SSDT-TB3HP-ZBook-lite.aml`（`on` 同法，把 `-lite` 去掉）。
- 合盖即关机（可选）：**`oc-setup.sh lid install`**。

### 已查证但**决定不改**的项（2026-10-23，防重复讨论）

| 项 | 现值 | 查证结论 | 为什么不动 |
|---|---|---|---|
| 雷电根端口 ASPM（`Pci(0x1C,0x0)`） | 未设 | **加配置也没用**。`pci-aspm-default` 只是「默认值」：真正生效要有人调 `IOPlatformDeviceASPMEnable`，而 `IOPCI2PCIBridge::setDeviceASPMState` 是按 `state & 上游caps & 下游caps` 取交集后**把结果写回**同名属性。实测：NVMe 链路 `RP17@1B` + `PXSX@0` 均 =`2`（L1 已生效）；USB-C 链路 `pci-bridge@2` + `pci8086,15e9@0` 均 =`0`（成对出现 = 走的是 disable 分支，或两端 caps 交集为空） | 两种可能都指向「注入无效」；且插电状态下收益无法量化 |
| `Misc/Security/ScanPolicy` | `0` | 官方位表（三处来源一致）；本机若要收紧 = **`0x2A0D03`** = FS_LOCK(0x1)+DEV_LOCK(0x2)+APFS(0x100)+ESP(0x400)+NTFS(0x800)+SASEX(0x20000)+NVME(0x80000)+USB(0x200000) | 收益只有开机扫描的几十~几百毫秒；文档自己写明「协议隧道可能让设备被识别成别的类型」⇒ 万一 NVMe 被误判，picker 会一个启动项都没有 |
| `csr-active-config` | `0x0FFF`（SIP 全关） | 原本是 OCLP **Modern Audio root patch** 的必需品。**2026-10-23 改用 SimpleHDA 后 root patch 已不存在**，系统卷回到 `Sealed: Yes`（原 `Broken`），理论上有条件恢复 SIP。社区经验（esafeddie 单例）认为「SIP 需 fully enabled 才给 delta 更新」 | 拿 full 包的**主因是 seal 被 root patch 破坏，已随 Revert 消除**，SIP 只是次要因素；且当时**无 macOS 更新可验证** ⇒ 先保持现状。**下次系统更新看包体大小**：3–5 GB = delta 已恢复、不必动；仍是 12 GB 再改 `00000000`。⚠️ Safari/浏览器 200–300 MB 的更新**不能**当 macOS delta 的证据 |
| boot-args 的 `-lilubetaall` | 有 | Lilu **1.7.1 起**「Allow loading on macOS 26 without `-lilubetaall`」（本机 1.7.3）⇒ 该参数已是**惰性** | 删掉不省电不提速；反而丢了「某插件在当前系统本不该加载」的提示，还要拿一次重启去换 |

其余 boot-args 保留依据（**当前实际值**：`-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall revpatch=sbvmm rtcfx_exclude=0E-FF keepsyms=1`）：

- `-igfxblt` —— WEG 官方表：KBL/CFL 上 macOS 13.4+ 的背光寄存器替代修法；
- `-igfxhdmidivs` —— SKL/KBL/CFL 高像素时钟 HDMI 死循环；
- `igfxrpsc=1` —— WEG `rps-control`（本机 IGPU #967 freeze-panic 的缓解项）；
- `revpatch=sbvmm` —— RestrictEvents README 原文 *"allowing OTA updates for unsupported models"*，**只负责「让更新出现」，不决定 full/delta**（曾误归因过一次）；
- `keepsyms=1` —— **SimpleHDA 1.0.0 迁移时一并加入**，保留内核符号名便于定位音频栈问题；
- `-amfipassbeta` / `rtcfx_exclude=0E-FF` —— **未查到决定性依据，按「不确定就不动」处理**。

- **★OCLP 也救不了 P620（2026-10-23 定论，四层证据）**：OCLP README 致谢里的补丁集分类写得很清楚 —— **Pascal（含 P620）只挂在 `non-Metal patch set`**（`moraea/non-metal-frameworks`），Metal 侧只有 **`3802 Metal patch set` + `MetallibSupportPkg`，覆盖范围是 Kepler（以及 Intel 3/4 代），不含 Pascal** ⇒ **Pascal 从来没有 Metal 补丁集**。叠加限制：① Apple 自 Monterey 起移除 NVIDIA 驱动，Pascal 最后可用是 **10.13.6 Web Driver**；② non-Metal 补丁只剩 OpenCL、**无 Metal**（elitemacx86 口径）；③ `JeoJay127/OCLP-X` 2.6.0 release note 明写「不支持 macOS Tahoe 26 … 开普勒 N 卡、Non-Metal 显卡」⇒ 本机 26.x 上连 non-Metal 线都被明确屏蔽。代价还要毁 seal + 丢 delta + 整套重装 OCLP，**不值得**。
- **P620 确认没上电**：`PEG0@1` 根端口存在（`pcidebug=0:1:0(2:2)`）但**二级总线上没有任何设备**，全树 `"vendor-id" = <de100000>` 命中 **0** ⇒ 链路没起来，不是「被 macOS 忽略」而是「根本没枚举」。
- ⚠️ 判据提醒：`ioreg` 属性是 **little-endian**，`ioreg | grep 10de` **恒为 0**（假阴性，Intel 会打成 `<86800000>`）。查 NVIDIA 必须 `grep '"vendor-id" = <de100000>'`。

## 目录与安装

| 路径 | 说明 |
|------|------|
| `docs/macos-mic-troubleshooting.md` | **内置麦最终结论**（硬件拓扑、macOS 验证、停止排查说明） |
| `docs/simplehda-migration-2026-10-23.md` | **音频迁移记录**：SimpleHDA 落地配置、OCLP Revert 真实机制、auto-patch 坑、实测表、回滚路径 |
| `EFI/oc/` | OpenCore **`OpenCore.efi`**、**Drivers**（**9 个**：`AudioDxe` / `OpenCanopy` / `OpenRuntime` / `HfsPlus` / `OpenLinuxBoot` / `ext4_x64` / `ResetNvramEntry` / `ToggleSipEntry` / `FirmwareSettingsEntry`）、**Kexts**（25 个 bundle）、**`config.plist`**、**`ACPI/`**（仅 `.aml` 编译产物）、**Tools**（`OpenShell.efi`） |
| `EFI/boot/` | 引导相关文件 |
| `docs/SysReport/` | 本机 ACPI 表导出（`ACPI/` 下 `DSDT` / `APIC` / `DMAR` 等） |
| `EFI/scripts/` | **`oc-setup.sh`** 统一入口；含 pmset、耳麦切换、**雷电档位**（`tb-thunderbolt-profile.sh`）、合盖关机、ESP 挂载等 |

将整个 **`EFI`** 复制到 **ESP 分区根目录**（与 **`EFI/oc`** 同级），按 OpenCore 常规流程使用。

## 引导器与 kext 版本（含来源，2026-10-23 复核）

**运行中的引导器版本以 NVRAM 为权威读数**（文件大小 / 文档标题都可能过时）：

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version
# → REL-109-2026-10-11 | MOD   （第三方 MOD 构建；原串末尾带作者联系方式，此处已隐去）
```

> ⚠️ **MOD 版的二进制里读不到版本号**：`strings EFI/OC/OpenCore.efi | grep REL-` 只会得到占位符
> `REL-XXX-YYYY-MM-DD | MOD -`。**唯一可靠来源是上面这条 NVRAM 变量**（它由 OpenCore 运行时写入）。
> 曾据此误判过一次「OC 退回 REL-108」—— 实际是 `89aaceb` 升级到 REL-109 MOD。

| 组件 | 运行版本 | 官方最新**正式版** | 判定 |
|------|----------|--------------------|------|
| **OpenCore 核心** | `REL-109-2026-10-11 \| MOD` | **1.0.8**（2026-09-27） | ℹ️ 本机是 **1.0.9 线开发版 + MOD 分支**，超前官方正式版一个 minor；**官方 1.0.9 尚未发布**（`releases/latest` 仍是 `1.0.8`，`6fe4d15`） |
| **RTCMemoryFixup** | **1.0.8** | **1.0.7**（2020-10-05） | ⚠️ 本地是**开发版构建**；官方正式版自 2020-10 后就没再发过，停在 `1.0.7` |

版本沿革：`8e41e23`→`REL-108`，`db40819`(10-19) 回退到 09-18 基线，`89aaceb` 再升到 **REL-109-2026-10-11 MOD**（现行）。

- ⚠️ **版本号陷阱（2026-10-23 更正）**：**官方 1.0.8 已经是正式发布版**（2026-09-27，`6fe4d15`），此前文档里「官方从无 1.0.8」的说法是**错的**。当前真正"超前"的是 **1.0.9 线**：官方尚未发 1.0.9，本机 `REL-109` 来自 master / 开发版构建（Dortania [`build-repo`](https://github.com/dortania/build-repo) 每日构建，构建时间与 `REL-<n>-<date>` 的日期可对上），并叠加 MOD 第三方分支。因此凡涉及「某问题是否已在 1.0.9 修掉」的判断，**必须落到具体 commit / changelog 条目**，不可拿版本号当正式版比对。
- ⚠️ OC 1.0.8 changelog 里的 hibernation 条目原文是 *"Fixed unresolved ATAPI device paths on **NVMe Macs** during hibernation"* —— **针对真 Mac**，与本机的 S4（真休眠）无关，**勿据此认为本机 S4 有救**（见 [`docs/sleep-forensics/`](docs/sleep-forensics/)）。
- 本批二进制于 2026-09-16/17 由机主手动升级，自 `eeac312` 起纳入版本控制 —— 此前长期处于 **工作区 == ESP ≠ HEAD** 的漂移态，任何 `git checkout -- EFI/` 都会**静默把 OC 核心换回旧版**。
- ⚠️ **`EFI/oc/` 下不要放非必需的 plist**：`oldConfig.plist` 这类文件会被同步任务**一并镜像进 ESP**（已实测 `/Volumes/ESP/EFI/OC/oldConfig.plist` 存在）。备份请放到 `EFI/` 之外。
- ℹ️ **ESP 上会出现 `.dsl`**（同步任务不区分扩展名，而 OC 只用 `.aml`）。**这与故障无关，不必清理**：
  FAT 短名是「8 字节名 + 3 字节扩展名」，`SSDT-TPD3-PIN.aml` / `.dsl` 的短名分别是 `SSDT-T~1.AML` / `SSDT-T~1.DSL`，
  扩展名不同 ⇒ 短名必然不同 ⇒ **不构成 8.3 冲突**。实测 6 对并存已存在 24–79 天，从未引发问题。
- ⚠️ **真正要记的是 2026-10-23 那次故障本身**：`SSDT-TPD3-PIN.aml` 在 ESP 目录层出现两条 entry、其中一条
  `FileSize=0`，OC 自带 FAT 驱动读到 0 字节 ⇒ 表不加载 ⇒ `TPNM` 不存在 ⇒ 中断引脚退化为 0 ⇒ 触控板整条失效。
  **触发条件未取证**（写入中断 / 并发写 / msdosfs 写入均有可能），**唯一可用的防护是重启前跑 preflight 检出**。
  两条硬教训：① **`shasum` 一致不能证明 OC 读得到**（macOS 只命中好的那条）；② 判据看 `gpioPin`，
  258=正常、0=表没加载。详见 [`docs/touchpad-os-gating.md`](docs/touchpad-os-gating.md) §7。

## 已知限制

- **内置麦克风**：**不支持且不可修**（Intel **SoundWire**，`HDAS.SNDW` 下的 AE30 阵列；2026-06-11 已验证录制样本全 0）。本机 `SSDT-SNDW-off.aml` 已在 Darwin 下把 `SNDW._STA` 置 0 ⇒ 系统里那个「内置麦克风」是空壳，**别为它轮 layout、也别加 ACPI**。**Windows 侧驱动齐全，麦是好的。**  
- **耳机孔麦克风**：**可用**（`layout 55`）。**自动切换**：`sh EFI/scripts/oc-setup.sh mic install`（优先级：**蓝牙 > 有线 > 内置麦**）；或手动选输入设备。  
- **独显**：**不支持，且无解**。Quadro P620 是 **Pascal**，NVIDIA 驱动止步于 macOS 10.13.6（Web Driver）；目前由 **`SSDT-dGPU-PowerOff-Darwin`** 在 Darwin 下 `_OFF` 断电（**不需要 `-wegnoegpu`**），已验证 IOReg 全树 `"vendor-id" = <de100000>` 命中 0（即未枚举）。**OCLP 也无法改变这条结论**：OCLP 的 Metal 补丁集（`3802`）只覆盖 **Kepler**，Pascal 只挂在 `non-Metal patch set` 上且**无 Metal**，而 `OCLP-X` 2.6.0 已明确不支持 Tahoe 26 的 Non-Metal 显卡。仅使用核显是最优状态，**勿再尝试驱动**。  
- **雷电**：**Intel JHL7540** 于 **`_SB.PCI0.RP01.PXSX`**。三档由 **`sh EFI/scripts/oc-setup.sh tb off|on|lite`** 切换（亦可用 **`tb-thunderbolt-profile.sh`**）：
  - **off** — `SSDT-thunderbolt-disable.aml`：Darwin 下隐藏 RP01（**就是雷电总开关**），USB-C 退化为 USB2，**空口功耗最低**；
  - **on** — `SSDT-TB3HP-ZBook`：热插拔 + **`force-power`** + 唤醒 **`_DSW`**；**勿** `power-save=1`（会破坏 Deep Idle 唤醒）；
  - **lite** — `SSDT-TB3HP-ZBook-lite`：保留热插拔与 **`_DSW`**，**不注入 `force-power`**，用于在「省电」与「可用 TB」之间试探；**稳定性待验证**（`.aml` 现状见上「睡眠与节能」）。
  - **★当前档位 = 「放控制器 + 屏蔽 TB 驱动栈」**（`SSDT-thunderbolt-disable` 关 = RP01 可见；`Kernel/Block` 双条
    `AppleThunderboltNHI` + `IOThunderboltFamily`，`Strategy=Disable`）：**USB-C 拿回 USB3**，雷电控制器仍被枚举但**零驱动实例**。
    2026-09-29 `c980425` 首次落地并实测封板（`AppleUSBXHCITR` 含 `SS01`、`IOThunderboltController`=0、零 panic）；
    2026-10-19 `db40819` 整体回退到 09-18 基线时被连带扫掉，2026-10-22 复现并在本机重新实测通过。
    ⚠️ Hackintool 的 PCI 列表仍会列出 `00:1d.0~1d.5` 六行——**Block 只拦驱动、不动硬件**。

    **★判据（必须按 `<class XXX,` 精确匹配，2026-10-23 修正）**：

    ```
    # 雷电驱动实例 —— 期望 0（三个类都不应出现）
    ioreg -lw0 | grep -oE '<class (IOThunderboltController|AppleThunderboltNHIType3|AppleThunderboltHAL),' | sort | uniq -c
    # USB-C 控制器 —— 期望 1
    ioreg -lw0 | grep -c '<class AppleUSBXHCITR,'
    # USB-C 的 4 个端口 —— 期望 2×USB30 + 2×USB20
    ioreg -lw0 | grep -A120 'AppleUSBXHCITR@' | grep -oE 'AppleUSB(20|30)XHCIPort' | sort | uniq -c
    ```

    ⚠️ 两个**会误判**的旧写法，别再用：① `ioreg -lw0 | grep -c IOThunderboltController` —— 会命中
    `IOKitDiagnostics` 的 `Classes` 字典（类名清单），实例为 0 时也可能报 1；② `ioreg -c AppleUSBXHCITR` ——
    本机 `-c` 不生效，只回 `Root`，看着像"实例 0"，实际控制器活得好好的。也可看系统信息 →「雷雳/USB4」
    显示 `No drivers are loaded.`。**「关闭卡」永远不要点**（历史 100% panic）。
    切换/回滚：`tools/tb-block-toggle.sh status|off|on`（`tools/` 按约定不入库；脚本不在时，手动把上面两条 `Enabled` 改 `false` 即回滚）。
    **睡眠实测**：2026-10-23 过夜 10.9 h（单 Block 版）——DarkWake **0**、WakeTime **2.41 s**、零 panic，
    唤醒后 `AppleUSBXHCITR` 与 4 端口（**2×USB3 + 2×USB2**）全部 `matched` ⇒ Dortania 提示的「USB-C 睡眠后中断」本机未发生。
    ⚠️ 该夜=**AC 睡眠**，掉电率无物理意义 ⇒ **功耗仍未量化**（`off` 档与「放控制器」两版都没有拔电过夜数据）。
  2026-06-12 曾验证 USB-C（TXHC）可用（**`DisableIoMapper=true` 下即成立 ⇒ VT-d 不是本机雷电的前提**）；2026-06-17 曾出现 `IOThunderboltFamily` 唤醒 panic（`on` 档）；2026-08-24 另一次 `IOThunderboltFamily` NULL panic 由 ExpressCard 幻影槽「关闭卡」触发。**无 TB 设备长期使用时建议 `tb off`**。拿到 TB 设备可先 **`tb on`** 或保持 **lite** 实测睡眠/唤醒与热插拔。回退：**`tb off`**。同类参考：[ZBook 17 G5](https://github.com/theroadw/Zbook-G5-17-WX-4170)。  
- **睡眠/唤醒**：核显在 Deep Idle 唤醒时曾触发 **IGPU SafeForceWake** panic；已加 boot-arg **`igfxonln=1`**，另用 **`igfxrpsc=1`** 缓解 IGPU #967 freeze-panic。蓝牙/Wi‑Fi 睡眠 hook 已移除，交由 macOS 与 **`pmset-reduce-wake.sh`** 管理。
  **当前基线（实测）**：常态 **DarkWake = 0**、`WakeTime ≈ 2.4 s`、无 panic、约 **5.5–5.6 %/h ≈ 3.7–3.8 W**。入睡慢主要在 `AppleIntelFramebuffer … SetState to 1`（≈1.6 s）与企业管控的 `aTrustAgent timed out(30000ms)`；唤醒慢在 `SetState to 2`（≈2.2 s）。
  ℹ️ 两个判读坑：① 夜间那一觉在 `powerlog` 里是 **Software Sleep**，不是关机；② 唤醒后若见负载尖峰，多因 DarkWake = 0 让维护唤醒积压一次性释放，不是异常。
- **系统升级**：大版本升级前先核 **`config.plist` → `Kernel` → `Add`** 里每个 kext 的 `MinKernel` / `MaxKernel`。当前有**两条硬约束**：
  ① **`AirportItlwm-Tahoe`**（laobamac 的 Tahoe 分支）`MaxKernel = 25.99.99` ⇒ 升 **macOS 27** 前必须先拿到支持 Darwin 26 的版本并改内核范围，**否则升级后无 Wi‑Fi**；
  ② **`SimpleHDA`** 的 `MinKernel / MaxKernel = 25.0.0 / 25.99.99`，它把 **AppleHDA 600.2 整套静态编进 kext**（运行时解压注册、不写系统卷）⇒ 大版本若 AppleHDA 主版本跨代，需等 SimpleHDA 跟进。
  好消息：**SimpleHDA 不依赖 root patch，升级不会像 OCLP 那样把系统卷 seal 弄坏**。迁移细节见 [`docs/simplehda-migration-2026-10-23.md`](docs/simplehda-migration-2026-10-23.md)。

## 常见问题

**安装时要拷什么？**  
复制整个 **`EFI`** 到 ESP 根目录；有效配置在 **`EFI/oc/`**。

**无线用哪个驱动？**  
本机 **AX201**（`8086:06F0`，CNVi 走 **iwx** 分支）：macOS 26 下用 **`AirportItlwm-Tahoe` 2.4.0**（laobamac 的 Tahoe 分支，`MinKernel 25.0.0` / `MaxKernel 25.99.99`），**单 kext 即可**，**不需要** `IOSkywalkFamily` / `IO80211FamilyLegacy`（那套是旧 Sequoia 的 OCLP 注入方案，已从 `Kernel/Add` 移除）。实测能正常读出 SSID / BSSID。具体以当前 **`config.plist`** 里各 kext 的 `Enabled` 与内核范围为准。

**触控板为什么能工作？**  
**I²C ELAN073D**（ACPI 中 **TPD3**）+ **VoodooI2C** / **VoodooI2CHID**，配合 **`SSDT-TPD3-PIN2`** + **`SSDT-I2C0-GNVS`**（**没有** `SSDT-TPD3-CRS` / `SSDT-TPD3-INI`，旧方案残留已删），走 **GPIO 中断**（`SSDT-TPD3-PIN2` 提供 `TPNM`，实际 `gpioPin = 258`）——**不是 polling**，`boot-args` 里也**没有** `-vi2c-force-polling`。排障只看 `gpioPin`：**258 = 正常**，**0 = 中断引脚表没加载**（触控板整条失效）。详见 [`docs/touchpad-os-gating.md`](docs/touchpad-os-gating.md)。

**雷电扩展坞能用吗？**  
取决于 **`tb`** 档位：**`off`** 时 macOS 不加载 TB；**`lite` / `on`** 时控制器与 NHI 可挂载。2026-06-12 曾验证 USB-C（TXHC）；PCIe 隧道/热插拔**尚无扩展坞长期实测**。建议：**`tb on`** 或 **lite** → 开机前插好 → 再试热插拔与睡眠唤醒；不稳则 **`tb off`** 或退回 **`tb on`**。见「已知限制 → 雷电」。

**睡眠唤醒卡死 / 重启？**  
先查 **`/Library/Logs/DiagnosticReports/Kernel-*.panic`**。本机曾见：**IGPU SafeForceWake**（已加 **`igfxonln=1`**）与 **`IOThunderboltFamily`**（与雷电 **`on`** 档相关）。雷电实验请优先观察 **lite** 是否稳定，不行用 **`tb off`**。

**内置麦克风为什么不能用？**  
内置麦是 **Intel SoundWire 数字麦**（`HDAS.SNDW` 下的 Intel AE30 阵列），不是 Realtek ALC236 的模拟麦；macOS 没有 Intel SST 驱动 ⇒ **Hackintosh 上无解**，已实测录制样本全 0。本机 **`SSDT-SNDW-off.aml` 在 Darwin 下把 `SNDW._STA` 置 0**，所以系统信息里那个「内置麦克风」只是 layout 造的空壳 —— **别为它轮 layout、也别加 ACPI**。替代方案：**3.5mm TRRS 耳麦**（选「线路输入」，`layout 55` 有电平）/ USB 麦 / 蓝牙麦。**Windows 侧驱动齐全，麦是好的。** 完整说明见 [`docs/macos-mic-troubleshooting.md`](docs/macos-mic-troubleshooting.md)。

**以前用 OCLP root patch，现在还需要吗？**  
**不需要了**（2026-10-23 起）。音频改由 OC 注入 **`SimpleHDA 1.0.0`**（`MinKernel 25.0.0`）在运行时提供 AppleHDA 类，系统卷 `/S/L/E/AppleHDA.kext` 已不存在、`Sealed: Yes`、`kextstat | grep -c AppleHDA` = 0（零重名冲突）。OCLP 应用与三个 LaunchAgent/Daemon 已整体卸载 —— 其中 `auto-patch`（`RunAtLoad` + `--auto_patch`）登录即跑，实测日志确认会把 Modern Audio 打回去，**不摘掉整套切换就白干**。详见 [`docs/simplehda-migration-2026-10-23.md`](docs/simplehda-migration-2026-10-23.md)。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
