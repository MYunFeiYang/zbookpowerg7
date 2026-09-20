# 固件与平台事实台账（zbookpowerg7）

> **建立 2026-09-20 10:0x**。起因：用户问「我的固件等信息你都完全确认了？」
> **用途**：把「我声称知道的事」按**证据等级**分档，标明**能否当场复验**、**最近复验时间**。
> **纪律**：凡不是一手实测的，只能留在这里，**不许出现在结论里当已确认事实**。复验命令全部只读、零风险。
> 相关：`docs/sleep-tests/tier-ladder-why.md`（睡眠档位，附录 A–E）｜`docs/tooling-gotchas.md`（工具坑）

---

## 0 · 一句话结论

**「不是全部确认。」** 今天把 **4 项**从二手记录升为一手实测，纠了 **3 处记录错误**，同时明确列出 **3 项我确实拿不到**的东西 —— 而不是含糊带过。

---

## 1 · 一级：本机一手实测（可当场复验）

### 1.1 ★ 真实 BIOS 版本 = `T75 Ver. 01.24.02`（`T75_01240200`）—— **四个独立来源**

| # | 来源 | 读数 | 命令 / 文件 |
|---|---|---|---|
| ① | **EFI System Table**（macOS 侧，**新方法**） | `firmware-revision = <00021801>` | `ioreg -p IODeviceTree -n efi -r -d 1 -w0` |
| ② | Windows SYSTEM hive `BIOSVersion` | `T75 Ver. 01.24.02` | `/Volumes/TZBOOK/Windows/System32/config/system` |
| ③ | 同 hive `SystemBiosVersion`（REG_MULTI_SZ） | `HPQOEM - 0` ⟂ `T75 Ver. 01.24.02` ⟂ `HP - 1180200` | 同上 |
| ④ | HP 自己的固件包 `.inf` | `DriverVer = 05/11/2026,1.24.2.0` ＋ `FirmwareVersion = 0x01180200` | DriverStore 里的 `T75_01240200.inf` |

**编码已闭环（不再靠猜）**：`0xMM mm PP 00`，每个字段是**原始字节值**（十进制语义、按十六进制书写）。
本机 `0x01180200` → 主 `0x01`=1、次 `0x18`=**24**、补丁 `0x02`=2、保留 `00` ⇒ **1.24.2.0** ⇒ 与 ④ 的 `DriverVer` 逐字段吻合。
文件名 `T75_01240200` 用的是**十进制数字串**（01 24 02 00），DWORD 用的是**字节值** —— 同一版本的两种写法，别混。
（旁证即可自洽：`01.18.01`→文件名 `01180100`、DWORD `0x01120100`；`01.23.00`→`01230000`、`0x01170000`。）

### 1.2 其余一手项

| 事实 | 值 | 判据 |
|---|---|---|
| BIOS 发布日期 | `05/11/2026` | hive `BIOSReleaseDate` |
| **本机实跑固件镜像（已拿到）** | `T75_01240200.bin`，32,315,326 B，sha256 `f89292026932be691d59904311cb50b4fbc55379aa554f89479665e04ae6970b` | `/Volumes/TZBOOK/Windows/System32/DriverStore/FileRepository/t75_01240200.inf_amd64_42ecb2ad108e0833/` |
| 固件厂商（EFI System Table） | `HP`（`firmware-vendor = <480050000000>`） | `ioreg`（`SpoofVendor=True` 也没改掉它 ⇒ 是真值） |
| 平台标识 | `SystemFamily=103C_5336AN HP ZBook`／`SystemProductName=HP ZBook Power G7 Mobile Workstation`／`SystemSKU=10J83AV`／`BaseBoardProduct=87EC`／`SystemVersion=SBKPFV3` | hive `SystemInformation` |
| OS / 内存 | macOS **26.6.2 (25G83)**；内存 **16 GB** | `sw_vers`／`sysctl hw.memsize` |
| 引导侧配置 | ACPI `Add` **14 条全启用**／`Patch` **2 条**／`Kernel/Add` **30 条全启用**／`DeviceProperties` **8**／`SecureBootModel=Disabled`／`ScanPolicy=0`／`csr-active-config=0x0FFF` | `plistlib` 读 `EFI/OC/config.plist` |
| 实跑 boot-args | `-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1  -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=0E-FF -rtcfxdbg` | **NVRAM 与 config 一致**（`nvram -p`） |
| SSDT 的 OS 门控 | 14 张**全部**含 `_OSI` + `Darwin` | 逐文件 `strings -a` |
| 部署一致性 | 工作区 vs ESP `config.plist` sha256 **相同** `a9c01104…` | `shasum -a 256` |
| Windows 侧 `PlatformAoAcOverride` | **不存在**（0 命中；正向对照 `BIOSVersion` 命中 ⇒ 方法有效） | hive 字节级检索 |
| 本机 CPU 是否 6 核 | 是（`system_profiler`：6-Core i7），**型号被 OC 伪装，读不到真型号** | — |

### 1.3 ★ 本机 **01.24.02** 固件复核（把 01.23.00 的旧结论坐实到本机版本）

> 附录 C/D 的所有固件结论原本取自 **01.23.00（SP169002）**，与实跑版本**差一版**。现已用**本机 01.24.02 镜像**复核如下 —— **全部一致**。

| 项 | 本机 01.24.02 | 01.23.00 对照 |
|---|---|---|
| HpSetup 模块位置 | `3 5473C07A-…/0 9E21FD93-…/0 EE4E5898-…/1 Volume image section/0 A881D567-…/**172 0147**` | `…/**171 0147**` |
| 模块 GUID / 体积 | `A0A3FEC9-FE9D-4CE7-8DB4-9C54F3F19E5A`，body **1,328,398 B** | 同 GUID，body 1,327,374 B |
| `HpModernStandbyConfigurations` | ASCII @**1,286,143** | ASCII @1,282,343 |
| `DeepS3` / `DeepS3Support` | ASCII @**1,285,954 / 1,285,983** | 同 |
| `PowerControl` / `CpuPwrMgmt` / `WakeOnUSB` | ASCII @**1,286,195 / 1,285,921 / 1,286,111** | 同 |
| `Modern Standby` | UTF-16 **×5**：en @48,501 / 48,606、da @130,765、es @318,364 / 318,541 | ×5 |
| 互斥文案（**三语自曝**） | en：`Deep Sleep has been gray out because Modern Standby is set to On.`<br>da：`Dyb søvn er blevet slået fra og nedtonet, fordi Modern Standby er indstillet til On.`<br>es：`La función de suspensión profunda se ha deshabilitado y sombreado porque Modern Standby está activado.` | 同 |
| UI 邻接顺序 | `Runtime Power Management → Extended Idle Power States → Deep sleep(+Wake when Lid/AC/USB) → **Modern Standby** → Power Control → Battery Management → Battery Health Manager` | 同 |
| **无 HII / IFR** | report section 直方图 = 969 UI / 930 PE32 / 768 Version / 96 Raw…，**HII = 0**；全报告字符串 `HII` 出现 **0 次**（正向对照：`PE32 image`=932、`Volume image`=2） | 同（三判据） |

**本机 01.24.02 的 Setup 变量名表（Power/设备块，共 42 个标识符，ASCII @1,285,600–1,287,400）**：
`…DisableBatteryOnNextBoot | CpuPwrMgmt | DeepS3 | DeepS3Support | WakeOnUSB | HpModernStandbyConfigurations | PowerControl | MiscMobileKBCBatteryMgmt | IntelOptaneOptions | TpmOptions | MeOptions | ElectronicLabel | HpHBMAPriorityList | HP_UsbControlOptions…`
⇒ **`Deep Sleep` 与 `Modern Standby` 是平级的两个命名 Setup 变量**，这不是 OS 驱动出来的现象，是固件作者写进变量结构的设计。

### 1.4 ★ 明文标识符的**精确归属**（新，纠正旧记录）

在**原始镜像**（未解压）里这些标识符就是**明文 UTF-16** —— 说明它们落在**未压缩区**。用 `.report.txt` 的 Base/Size 区间反查，可精确到「卷 / 模块 / 段」：

| 标识符 | 偏移 | 所属卷 | 所属模块 | 所在段 |
|---|---|---|---|---|
| `FspS3Notify` | @0xA62B40、@0xDD4B40 | `1B5C27FE-F01C-4FBC-AEAE-341B2E992A17` | PEI 模块 `EA7F0916-B5C8-493F-A006-565CC2041044` | **UI section**（= 模块名本身） |
| `HpCommonSetup` | @0xB3B188 | `B73FE497-B92E-416E-8326-45AD0D270091` | PEI 模块 `0556A9E4-C473-4524-BEA2-A609057A2959`（0303） | PE32 image |
| `HpModernStandbyConfigurations` | @0xB659D0 | `B73FE497-…` | PEI 模块 `CBABDE7E-B367-649A-8FFA-1167E08422C3`（0A0D） | PE32 image |
| `S3MemoryVariable` | @0xB76470、@0xB7A844 | `B73FE497-…` | PEI 模块 `EEEE611D-F78F-4FB9-B868-55907F169280`（0812）／`9FAAD0FF-0E0C-4885-A738-BAB4E4FA1E66`（081C） | PE32 image |

⇒ **旧记录写成「属 `HpCommonSetup` Setup 变量」不准确**：它们是 **PEI 阶段模块代码里的标识符**；`FspS3Notify` 干脆**就是一个 PEI 模块的名字**。⇒ 这**加强了**"平台在固件层确实有 S3 相关路径"的读法，但**它们是"固件组件名"，不是"可写的 NVRAM 设置项名"** —— 别混着用。

---

## 2 · 二级：有来源、但本机**未实测**（不可当已确认）

| 事实 | 来源 | 为什么不算一手 |
|---|---|---|
| CPU 型号 i7-10750H | 用户/记录 | `PlatformInfo/Generic/SystemProductName=MacBookPro16,4` + `SpoofVendor=True` ⇒ macOS 侧读不到真型号 |
| 内存可更换、上限 64 GB | HP QuickSpecs | 厂商文档，非本机实测（`system_profiler` 的 `Upgradeable Memory: No` 是 OC 注入的假字段） |
| HP 是否已发布 ≥01.24.02 的 SoftPaq | 已知 SoftPaq：SP154814=01.18.01、SP169002=01.23.00 | **未查**截至今日是否更高；01.24.02 本机是经 **Windows Update 固件驱动**下发的 |
| OpenCore 版本 `1.0.8-dev REL-108-2026-09-16` | 历史记录 | 本机**无法复验**（见 §3） |
| BIOS 01.23.00 内含 EC 固件 34.31.00 | SP169002 `HpFirmwareUpdRec.txt` | 那是 **01.23.00 的** EC 版本，**不是本机 01.24.02 的** |

---

## 3 · 三级：**拿不到**（明确列出，不许含糊）

| 项 | 为什么拿不到（已穷尽尝试） | 唯一可能入口 |
|---|---|---|
| **EC 固件版本（本机实跑值）** | 镜像里没有它（EC 版本是运行时读的）。已查且**全部 0 命中**：7 个 Padding 区 body.bin、`software` hive（正向对照 `HP ZBook Power G7` 命中 ⇒ 方法有效）、`ProgramData/HP/**` 日志目录、Windows 卷上无 `HpFirmwareUpdRec.txt` | ① BIOS Setup → System Information 页（零风险，直接看）；② Windows `root/HP/InstrumentedBIOS` WMI |
| **OpenCore 版本串** | `nvram 4D1FDA02-…:opencore-version` **不存在**（`nvram -p` 正向对照通过）＋ `OpenCore.efi` 内只有**构建占位符** `REL-XXX-YYYY-MM-DD` ⇒ 本机**无权威来源** | 打开 `Misc/Debug` 文件日志后从 OC 启动日志读 |
| **`HpModernStandbyConfigurations` 的 `DisplayInUI`（藏没藏）** | 该固件**没有 IFR**（三判据全零）⇒ 可见性标志在 HP 自研结构数组里，**未逆向** | WMI `HP_BIOSSetting` 的 `DisplayInUI` 字段（只读） |

> ⚠️ 三条都不影响任何现有结论（尤其"不赌 AOAC"）。列出来只是为了**不让它们装作已确认**。

---

## 4 · 今天新拿到的两条**只读**读取法（以后别再走弯路）

### 4.1 ★ macOS 侧直接读**真实** BIOS 版本 —— 不必进 Windows

```bash
ioreg -p IODeviceTree -n efi -r -d 1 -w0 | grep -aE 'firmware-(vendor|revision)'
# firmware-vendor   = <480050000000>          → UTF-16 "HP"
# firmware-revision = <00021801>              → 小端 UINT32 = 0x01180200 → 01.24.02
```

⚠️ **不要用 `system_profiler SPHardwareDataType` 的 `System Firmware Version`** —— 那是 **OpenCore 装的假值**（本机显示 `2094.80.5.0.0`，是 MacBookPro16,4 模板）。
config 依据（可自证）：`PlatformInfo/Automatic=True` + `UpdateSMBIOSMode=Custom` + `Generic/SpoofVendor=True` + `Generic/SystemProductName=MacBookPro16,4`。
⇒ **判据：要看真固件版本，读 `/efi` 节点的 `firmware-revision`；看 `system_profiler` 只会看到 Apple 的假身。**

### 4.2 ★ Windows 卷**平时就是只读挂载**的 ⇒ 当场复验，不必重启

```bash
mount | grep TZBOOK        # /dev/disk0s3 on /Volumes/TZBOOK (ntfs, …, read-only)
ls /Volumes/TZBOOK/Windows/System32/config/          # ⚠️ hive 文件名是小写：system / software
# 本机实跑固件镜像本体也在这里：
ls /Volumes/TZBOOK/Windows/System32/DriverStore/FileRepository/t75_01240200.inf_amd64_42ecb2ad108e0833/
```

⇒ 手上有 **01.24.02 的镜像本体**意味着：以后想核任何固件结构，**都能对着"本机正在跑的那一版"做**，不再有版本落差。

---

## 5 · 本次修订（3 处，均为我的记录错，已改）

| # | 旧记录 | 实测 | 影响 |
|---|---|---|---|
| **1** | `MEMORY.md` 第 16 行 boot-args 写作 `… igfxrpsc=1 -wegnoegpu -amfipassbeta … rtcfx_exclude=80-FF …` | 实跑（NVRAM 与 config **一致**）**没有 `-wegnoegpu`**，且是 `rtcfx_exclude=0E-FF` | 与同文件第 19 行「RTC 四层防护 = `0E-FF`」**自相矛盾** ⇒ 已改 16 行 |
| **2** | 「`HpModernStandbyConfigurations` … 属 `HpCommonSetup` Setup 变量」 | 精确归属见 §1.4；是 **PEI 模块内标识符** | 不改结论，但**证据表述必须精确** |
| **3** | 隐含假设「BIOS 版本只能从 Win hive 拿」 | macOS `ioreg` 可直接读（§4.1） | 核版本**不必再进 Windows** |

---

## 6 · 证据存证

| 文件 | 内容 |
|---|---|
| `docs/backups/firmware-ledger-2026-09-20/01-ioreg-efi-node.txt` | `/efi` 节点真实属性（firmware-vendor / revision）＋ `system_profiler` 假值对照 |
| `docs/backups/firmware-ledger-2026-09-20/02-win-hive-systeminformation.txt` | hive `SystemInformation` 解码块 + 固件包 `.inf` |
| `docs/backups/firmware-ledger-2026-09-20/03-hp-setup-varnames-01.24.02.txt` | 本机 01.24.02 的 Setup 变量名表 + UI 邻接 + 三语互斥文案 |
| `docs/backups/firmware-ledger-2026-09-20/04-firmware-image-sha256.txt` | 镜像存证（sha256 / 大小 / 出处） |
| `docs/backups/firmware-ledger-2026-09-20/README.txt` | 复验命令清单 + 来源分级 |

> 本轮**零配置 / 零 EFI 改动**。固件镜像与解包产物只在 `/tmp/bios12402/`（未进工作区）。
