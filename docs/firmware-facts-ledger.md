# 固件与平台事实台账（zbookpowerg7）

> **建立 2026-09-20 10:0x**。起因：用户问「我的固件等信息你都完全确认了？」
> **用途**：把「我声称知道的事」按**证据等级**分档，标明**能否当场复验**、**最近复验时间**。
> **纪律**：凡不是一手实测的，只能留在这里，**不许出现在结论里当已确认事实**。复验命令全部只读、零风险。
> 相关：`docs/sleep-tests/tier-ladder-why.md`（睡眠档位，附录 A–E）｜`docs/tooling-gotchas.md`（工具坑）

---

## 0 · 一句话结论

**「不是全部确认。」** 10:0x 已把 **4 项**从二手记录升为一手实测、纠了 **3 处记录错误**。

**★ 12:0x 更新（Windows 侧只读取证跑完，见 §8）**：§3 原来列的 3 项「拿不到」**补上 2 项**（EC 版本、`DisplayInUI`），只剩 **OpenCore 版本串**仍拿不到；「`PlatformAoAcOverride` 不存在」从 hive 字节级推断升为**直接查询**；并纠正一处 Windows 侧报告的 **EC 版本误读（52.49 → 34.31.00）**。⇒ **对「关 AOAC」这条线：正式封板。**

---

## 1 · 一级：本机一手实测（可当场复验）

### 1.1 ★ 真实 BIOS 版本 = `T75 Ver. 01.24.02`（`T75_01240200`）—— **五个独立来源**

| # | 来源 | 读数 | 命令 / 文件 |
|---|---|---|---|
| ① | **EFI System Table**（macOS 侧，**新方法**） | `firmware-revision = <00021801>` | `ioreg -p IODeviceTree -n efi -r -d 1 -w0` |
| ② | Windows SYSTEM hive `BIOSVersion` | `T75 Ver. 01.24.02` | `/Volumes/TZBOOK/Windows/System32/config/system` |
| ③ | 同 hive `SystemBiosVersion`（REG_MULTI_SZ） | `HPQOEM - 0` ⟂ `T75 Ver. 01.24.02` ⟂ `HP - 1180200` | 同上 |
| ④ | HP 自己的固件包 `.inf` | `DriverVer = 05/11/2026,1.24.2.0` ＋ `FirmwareVersion = 0x01180200` | DriverStore 里的 `T75_01240200.inf` |
| ⑤ | **Windows WMI**（HP 自带，12:0x 新增） | `System BIOS Version = T75 Ver. 01.24.02  05/11/2026` | `root/hp/InstrumentedBIOS` → `HP_BIOSSetting` |

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
| Windows 侧 `PlatformAoAcOverride` | **不存在**（12:0x 起为**直接查询**：`reg query` 报「系统找不到指定的注册表项或值」） | `reg query`；原 hive 字节级检索降为旁证 |
| **★ EC / KBC 固件版本（本机实跑值）** | **`34.31.00`** | **三来源**：① WMI `Embedded Controller Firmware Version = 34.31.00`；② `BaseBoardVersion = KBC Version 34.31.00`；③ SMBIOS Type 0 `ECFirmwareMajorRelease/Minor = 0x34/0x31` ⇒ **BCD 读法 = 34.31**。⚠️ `Win32_BIOS` 报 `52/49` 是把 BCD 当十进制读的**显示产物**，不是另一个版本（详见 §8.2） |
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
| ~~EC 固件版本（本机实跑值）~~ | — | ✅ **12:0x 已补上 = `34.31.00`**（§1.2 / §8.2）。原判"镜像里没有、WMI 未试"已过时：WMI 一条就能读到 |
| **OpenCore 版本串** | `nvram 4D1FDA02-…:opencore-version` **不存在**（`nvram -p` 正向对照通过）＋ `OpenCore.efi` 内只有**构建占位符** `REL-XXX-YYYY-MM-DD` ⇒ 本机**无权威来源** | 打开 `Misc/Debug` 文件日志后从 OC 启动日志读 |
| ~~`HpModernStandbyConfigurations` 的 `DisplayInUI`（藏没藏）~~ | — | ✅ **12:0x 已补上 = `0`（隐藏）＋ `IsReadOnly=1`（只读）**，见 §8.1 / §8.3 |

> ⚠️ 原三条里已补齐两条；剩下的那条（OC 版本串）**不影响任何结论**（尤其"不赌 AOAC"）。列出来只是为了**不让它装作已确认**。
> ✅ **副产品**：「WMI 只读」这个入口已实测可行 —— **非管理员即可、无需装 HPCMSL、无需重启**（12:0x 实测）。以后凡"某 BIOS 设置是什么值/藏没藏"，直接用 `docs/windows-side-workbuddy-prompt.md` 那套走一遍即可。

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

## 5 · 本次修订（6 处：前 3 处是我的记录错，后 3 处为 12:0x 追加）

| # | 旧记录 | 实测 | 影响 |
|---|---|---|---|
| **1** | `MEMORY.md` 第 16 行 boot-args 写作 `… igfxrpsc=1 -wegnoegpu -amfipassbeta … rtcfx_exclude=80-FF …` | 实跑（NVRAM 与 config **一致**）**没有 `-wegnoegpu`**，且是 `rtcfx_exclude=0E-FF` | 与同文件第 19 行「RTC 四层防护 = `0E-FF`」**自相矛盾** ⇒ 已改 16 行 |
| **2** | 「`HpModernStandbyConfigurations` … 属 `HpCommonSetup` Setup 变量」 | 精确归属见 §1.4；是 **PEI 模块内标识符** | 不改结论，但**证据表述必须精确** |
| **3** | 隐含假设「BIOS 版本只能从 Win hive 拿」 | macOS `ioreg` 可直接读（§4.1） | 核版本**不必再进 Windows** |
| **4**（12:0x 追加） | 隐含「EC 版本拿不到」 | **拿得到**：WMI 一条即得 `34.31.00`（§1.2）；不是缺入口，是**没试那个入口** | 删掉 §3 那条"拿不到" |
| **5**（12:0x 追加） | 「刷固件**不可回退**」 | **`BIOS Rollback Policy = Unrestricted Rollback` ＋ `Minimum BIOS Version = 00.00.00` ⇒ 策略上允许回退** | 不刷的真实理由 = **没收益＋变砖风险**，不是"回不去" |
| **6**（12:0x 追加） | Windows 侧报告称 "EC = 52.49" | 那是 **BCD 当十进制读**的显示产物；真值 `34.31.00`（§8.2） | 别让这个假数字进任何结论 |

---

## 6 · 证据存证

| 文件 | 内容 |
|---|---|
| `docs/backups/firmware-ledger-2026-09-20/01-ioreg-efi-node.txt` | `/efi` 节点真实属性（firmware-vendor / revision）＋ `system_profiler` 假值对照 |
| `docs/backups/firmware-ledger-2026-09-20/02-win-hive-systeminformation.txt` | hive `SystemInformation` 解码块 + 固件包 `.inf` |
| `docs/backups/firmware-ledger-2026-09-20/03-hp-setup-varnames-01.24.02.txt` | 本机 01.24.02 的 Setup 变量名表 + UI 邻接 + 三语互斥文案 |
| `docs/backups/firmware-ledger-2026-09-20/04-firmware-image-sha256.txt` | 镜像存证（sha256 / 大小 / 出处） |
| `docs/backups/firmware-ledger-2026-09-20/README.txt` | 复验命令清单 + 来源分级 |
| `docs/backups/firmware-ledger-2026-09-20/win-side/` | **12:0x Windows 侧取证产物**（原始证据，未加工） |
| ├ `HPBIOS-all.csv` | `HP_BIOSSetting` **全量 258 项**（Name/Value/DisplayInUI/IsReadOnly/RequiresPhysicalPresence） |
| ├ `HPBIOS-enum.csv` | `HP_BIOSEnumeration` 157 项（带 `PossibleValues`） |
| ├ `powercfg-a.txt` / `powercfg-avail.txt` | `powercfg /a` 原文（两者逐字相同） |
| ├ `reg-platformaoac.txt` / `reg-hardware-bios.txt` | 注册表原始查询输出 |
| ├ `win-side-evidence.txt` | 环境、权限、BIOS/EC 摘要、固件镜像 sha256 交叉验证 |
| └ `SUMMARY.md` | 对侧 agent 的报告（⚠️ 其中「EC 52.49」为误读，已由本台账 §8.2 纠正） |

> 本轮**零配置 / 零 EFI 改动**。固件镜像与解包产物只在 `/tmp/bios12402/`（未进工作区）。

---

## 7 · ★ 未确认项的下一步：Windows 侧只读取证提示词（2026-09-20）

台账里 §3 那三项（EC 版本 / `DisplayInUI` 可见性 / OC 版本串）**本机 macOS 侧拿不到**，最短路径是进 Windows 跑一次 HP 官方 WMI 只读。

已写好一份**可直接粘贴给 Windows 侧 WorkBuddy 的自包含提示词**：

```
docs/windows-side-workbuddy-prompt.md
```

| 项 | 说明 |
|---|---|
| 目标 | `root/hp/instrumentedBIOS` 的 `HP_BIOSSetting`（**含隐藏项**，带 `DisplayInUI` / `IsReadOnly`）/ `HP_BIOSEnumeration`（带 `PossibleValues`）全量导出 + `powercfg /a` + `PlatformAoAcOverride` 现状 |
| 接口依据 | HP 官方：`HP_BIOSSetting` 返回 *all BIOS settings*（对照 `HP_BIOSEnumeration` 只返 *commonly configurable*）⇒ **可当判据**；`DisplayInUI` 直接回答「藏没藏」 |
| 产物回传路径 | **exFAT 共享卷**（macOS = `/Volumes/Common`，Windows = 某盘符）⇒ `X:\workplace\zbookpowerg7\docs\backups\firmware-ledger-2026-09-20\win-side\`；兜底 `C:\Users\Public\`（macOS 经 `/Volumes/TZBOOK/Users/Public/` 只读可读） |
| 默认权限 | **Phase A/B 全只读**；Phase C（`PlatformAoAcOverride=0` + 重启 + **只看 `powercfg /a` 不睡** + 立刻回滚）**须用户明确授权** |
| 边界 | 不许刷固件、不许改 BIOS 设置、不许碰 ESP/`EFI/`、不许睡眠/休眠、不许装第三方工具 |

> 立场未变：这一步买到的是**「确定」**，不是**新能力**。看到 S3 出现也只是弱阳性——真判据仍是「睡下去能不能活着回来」。

---

## 8 · ★★ Windows 侧只读取证**结果**（2026-09-20 12:0x，用户执行完毕）

执行方式：把 `docs/windows-side-workbuddy-prompt.md` 交给 Windows 侧 WorkBuddy。**全程非管理员、全程只读**（未写注册表、未改 BIOS、未装任何东西、未重启、未睡眠）。
产物：`docs/backups/firmware-ledger-2026-09-20/win-side/`（258 项全表 CSV ＋ 原始输出）。

### 8.1 三条硬结论（我从 CSV 自己复算过，不是照抄报告）

| # | 事实 | 判据 |
|---|---|---|
| ① | **`Modern Standby` 当前 = `Enable`**，且 **`DisplayInUI=0`（隐藏）＋ `IsReadOnly=1`（只读）** | `HPBIOS-all.csv`（258 项）＋ **HP 官方定义**（见 8.1a） |
| ② | **`Deep Sleep` / `S3` / `S0ix` / `AOAC` / `Sleep State` 一条都不存在** | 全表 258 项逐名扫；正则 `standby\|sleep\|s3\|aoac\|modern\|deep` 作正向对照，仅命中 **3 项**（`Modern Standby`、`Disable Charging Port in sleep/off…`、`Power button delay… system sleep or power down`）—— **均非睡眠状态项** |
| ③ | **`PlatformAoAcOverride` 不存在**（从未设过） | `reg query` 原文：「系统找不到指定的注册表项或值」 |

#### 8.1a ★ 三个字段的**官方语义**（此前是我按惯例读的，现已查到 HP 原文坐实）

来源（**可当判据**）：HP 开发者站 `dev.hp.com/hp-client-management/doc/understanding-hp-bios-settings`
（`Understanding HP BIOS Settings`，含 `HP_BIOSSetting` 的 **MOF 定义**与逐属性说明）。原文引用：

| 字段 | HP 官方原文 | 对我们的意义 |
|---|---|---|
| **`IsReadOnly`** | "Value indicating **if this setting is supported by the interface method `HP_BIOSSettingInterface.SetBIOSSetting()`**. A value of **1 indicates that this particular setting instance cannot be changed**, otherwise the property is 0." | ★★ **"写不进去"由官方措辞直接坐实**（此前只是我的推断） |
| **`DisplayInUI`** | "Flag indicating this component **should be visible within a BIOS configuration user interface application**. This property field is used by some utilities to filter elements that are **not applicable to a given platform**." | 它就是**界面可见性**标志 ⇒ 官方层面也证明**与"能不能写"无关**（否掉"另解"） |
| **`Value` 里的 `*`** | "Enumeration selections are designated by the **presence of an asterisk** character (ex: `"*Enable, Disable"` denotes a setting is enabled)" | `Disable,*Enable` ⇒ **当前值 = Enable**，官方定义，不是我的约定解读 |
| **`RequiresPhysicalPresence`** | "A value of 1 indicates that attempts to modify this setting will require interactive acknowledgement during the next system startup." | 本机 `Modern Standby` 该项 = **0** ⇒ **不是**"物理在场"在挡，就是 `IsReadOnly` 在挡 |

`SetBIOSSetting` 的官方返回码（MOF `ValueMap`）：`0 Success`｜`1 Not Supported`｜`2 Unspecified Error`｜`3 Timeout`｜`4 Failed`｜`5 Invalid Parameter`｜`6 Access Denied`
⇒ ⚠️ **注意：没有"只读"专属返回码**，只读项大概率落 `1 Not Supported`（**这一句仍是推断**；我们**没有真去写**，因为写固件设置会改变持久状态）。

#### 8.1b ★ 顺手纠正一个我差点犯的错：`HP_BIOSEnumeration` **不是"可写清单"**

我一度以为 `HP_BIOSEnumeration`（157 项）＝"可配置项集合"，若 `Modern Standby` **不在**里面就是独立证据。
**实测反了**：`Modern Standby` **在** 157 项表里（`PossibleValues = Disable ~ Enable`）。

按官方 MOF，真相是：`HP_BIOSEnumeration` 是 `HP_BIOSSetting` 的**子类**（"Extension of HP_BIOSSetting to support … **enumerations are collections of possible values**"）
⇒ 它按 **取值域类型**（枚举型 vs 字符串/整数型）划分子类，**与可写性无关**。
旁证：258 项里没进 157 表的 101 项，正是 `Serial Number`、`Batt_LTemp`（值 `01 00` 十六进制）、`Touch Controller Firmware`（值空）这类**非枚举型**字段。

⇒ **教训**：`HP_BIOSEnumeration` 只能告诉你"这项的取值是个固定清单"，**不能**用来判"能不能改"。判可写**只认 `IsReadOnly`**。

`powercfg /a` **一手原文**：

```
此系统上有以下睡眠状态:
    待机 (S0 低电量待机) 连接的网络 ／ 休眠 ／ 快速启动
此系统上没有以下睡眠状态:
    待机 (S1)   系统固件不支持此待机状态。 ＋ 当支持 S0 低电量待机时，禁用此待机状态。
    待机 (S2)   同上两条
    待机 (S3)   ← 只有「当支持 S0 低电量待机时，禁用此待机状态。」
```

⇒ **S3 的不可用理由里没有「固件不支持」，而 S1/S2 有** ⇒ S3 = 「固件声明了、但被 AOAC 压住」。**这条以前只是记录，现在升为本机一手实测。**

### 8.2 ★ 纠正：Windows 侧报告的「EC 固件 52.49」是**误读**，正确 = `34.31.00`

`Win32_BIOS` 报 `EmbeddedControllerMajorVersion=52 / Minor=49`；但**同一台机上**：

| 来源 | 值 |
|---|---|
| WMI 设置项 `Embedded Controller Firmware Version` | **`34.31.00`** |
| 注册表 `BaseBoardVersion` | **`KBC Version 34.31.00`** |
| 注册表原始字节 `ECFirmwareMajorRelease/Minor` | `0x34` / `0x31` ⇒ **BCD 读法 = 34.31** |

`0x34` 的十进制是 `52`、`0x31` 是 `49` —— **52.49 与 34.31 是同一对字节的两种读法**，不是两个版本。
⇒ 正确值 = **`34.31.00`**（本仓 `docs/sleep-tests/bios-facts.md` 2026-09-17 记的 `KBC Version 34.31.00` 本来就是对的）。
类比：`BiosMajorRelease = 0x18` 若按 BCD 读是 18、按十进制读是 **24** —— **BIOS 字段用十进制（24 正确）**，**EC 字段用 BCD（34 正确）**，同一张表里两种编码并存。⚠️ 遇到这种字段**必须先数出两种读法、再用独立来源裁决**，不能直接采信 OS 报的数字。

**★ 派生出一条新决策规则**：01.23.00 包内记录同样是 `34.31.00` ⇒ **从 01.23.00 到 01.24.02，EC 固件没有变**。而 L3 卡点正在 EC ⇒ **将来 HP 若出新 BIOS 包，先比 EC 号：EC 号不变 ⇒ S3 不会好，不必折腾。**（⚠️ 该对比的记录源文件随 `/tmp` 清理已消失，属"记录级证据"；本机侧 EC = 34.31.00 是一手。）

### 8.3 ★ `DisplayInUI` 的含义被数据自己钉死（否掉"另解"）

Windows 报告提过一个替代读法：「`DisplayInUI=0` 也许只表示"不可改"，而非"不显示"」。**同一份 CSV 自己否掉了它**：

| 统计项 | 数 |
|---|---|
| 全表 | **258** 项 |
| `DisplayInUI=0`（隐藏） | **7** 项，且**全部** `IsReadOnly=1` |
| `IsReadOnly=1`（只读） | **82** 项 —— 其中 **75 项 `DisplayInUI=1`（照常显示）** |

⇒ 若 `DisplayInUI` 只是 `IsReadOnly` 的镜像，那 82 个只读项应**全部**隐藏；实际只有 7 个 ⇒ **`DisplayInUI=0` 是独立的"隐藏"标志**。
⇒ 且与**固件侧的独立方法**吻合：字符串池邻接分析预测「`Modern Standby` 被隐藏」⇔ WMI 给 `DisplayInUI=0`（同屏另 4 项 4/4 吻合）。

### 8.4 对「关 AOAC」这条线的影响 ⇒ **正式封板**

| 层 | 12:0x 之前 | 12:0x 之后 |
|---|---|---|
| ① macOS 侧声明（撤 `LPS0`） | 已实测：转 S3 ⇒ EC 罢工 | 不变 |
| ① Win 侧声明（`PlatformAoAcOverride`） | "从未设过"（hive 推断） | **确认从未设过**（直接查询）。仍可试，但**对 macOS 零帮助** |
| ② 固件**菜单**层 | "没找到"（实拍 ＋ 字符串池推断） | **`DisplayInUI=0` 坐实：菜单里根本没有** |
| ③ 固件**设置**层写入 | "不知能不能写" | **`IsReadOnly=1` ⇒ HP 官方写入路径（WMI `SetBIOSSetting` / BCU）自己也标它只读** ⇒ **"拿到名字就能按名写"这条假设作废**（⚠️ 这是 HP 自己的标志，非我们实测写入过） |

⇒ **「厂商按 AOAC-only 出厂」现在有三次独立确认**：① 固件帮助文案自曝互斥；② 变量名表里 `DeepS3`/`HpModernStandbyConfigurations`/`PowerControl` 平级；③ WMI 报隐藏＋只读。
⇒ 唯一剩下的软件动作只有 **Phase C（Windows 的 `PlatformAoAcOverride=0`）**：它**不碰固件**，只是让 Windows 忽略 AOAC。但 ① 它对 macOS 零帮助；② 它只能回答"固件留没留 S3 后门"；③ 即使答案=「有」，macOS 也走不了（"声明 ≠ 可用"已在 macOS 半场证过）。
⇒ **建议：不做，此线封板。** 真做也无害（改的是 Windows 的键、可 `reg delete` 回滚、只看 `powercfg /a`、不睡）—— 只是期望值是"零新能力、只买到一句确定"。

### 8.5 白拿的资产

- **`HPBIOS-all.csv`（258 项全表）**＝ 一份可随时 grep 的本机固件设置清单（含 7 个隐藏项）；`HPBIOS-enum.csv` 另带 `PossibleValues`。
- 顺带读到的只读版本号：`ME Firmware 14.1.79.2540`｜`Thunderbolt Controller 62.0.1.2.1`｜`USB Type-C CCG5 : 0.7.0`｜`Video BIOS Intel GOP`｜`Camera Controller 0004`｜`BIOS Build 0002`｜`Touch Controller Firmware`（**隐藏＋只读**）｜`Thunderbolt Controller Version`。
- 两个安全项现值（旁证"没人乱动过"）：`Automatic BIOS Update Setting = Disable`、`BIOS Rollback Policy = Unrestricted Rollback`、`Lock BIOS Version = Disable`、`Minimum BIOS Version = 00.00.00`。
  ⚠️ **顺带更正**：旧记录写"刷固件不可回退"不准确 —— **回退策略本身是允许的**（`Unrestricted Rollback`）。不刷的真实理由是"没有收益 ＋ 变砖风险"，不是"回不去"。

### 8.6 顺带核实 boot-args（第三次独立确认）

本次 `shutdownStall` 的 spindump 内**原样记录了 `_bootArgs`**：

```
-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=0E-FF -rtcfxdbg
```

⇒ **确实没有 `-wegnoegpu`、是 `rtcfx_exclude=0E-FF`**（与 `nvram -p`、`config.plist` 三方一致）⇒ §5 那处纠错再获一份独立证据。

### 8.7 ★ 存证已脱敏（入库前，2026-09-20）

本工作区**同步到公开 GitHub 仓库**（`github.com/MYunFeiYang/zbookpowerg7`）⇒ 回传产物入库前已把**与睡眠结论无关的真机身份字段**遮蔽：

- `HPBIOS-all.csv` / `SUMMARY.md` 里的 `Serial Number`、`System Board CT Number`、两个 `UUID` 字段、引导路径中的 `NVMe(0x1,…)` EUI64 与 `GPT` 分区 GUID ⇒ 统一替换为 `<REDACTED-…>`（明细见 `docs/backups/firmware-ledger-2026-09-20/win-side/REDACTION.md`）。
- **没有删行**：`Name` / `DisplayInUI` / `IsReadOnly` / `RequiresPhysicalPresence` 全保留 ⇒ §8.1 两条硬结论不受影响。
- **未脱敏（属目标证据）**：BIOS `01.24.02`、EC `34.31.00`、机型 / SKU、`Modern Standby` 等设置项本身。
- **历史清白**：`git log --all -S "<序列号>"` = 空 ⇒ 真机标识**从未进入 git 历史**；公开快照 `origin/main`（停在 2026-09-08）`git grep` 亦 0 命中。
- **防复发**：脱敏步骤已写进 `docs/windows-side-workbuddy-prompt.md`（「落盘后必做」一节），下次在采集端处理。
- ℹ️ 顺带记一条：本地 `main` **领先 `origin/main` 99 个 commit**（远端最后推到 09-08）⇒ 这 12 天的工作**都还没公开**；要 push 时注意先确认脱敏已生效。

### 8.8 ★★ BIOS 层（含**魔改**）路径尽调（2026-09-20 14:0x，触发：用户问「有没有 BIOS 支持的？包括魔改的？」）

> 目的：把「BIOS 层面还有没有路」**穷举**，含魔改。**本轮仍零配置 / 零 EFI / 零固件写入。**

#### (a) ★ 本机一手新事实：Sure Start 家族的真实状态（同一份 `HPBIOS-all.csv`，258 项里查出 6 项）

| 设置项 | 值（`*` = 当前） | UI | 只读 | 需物理在场 |
|---|---|---|---|---|
| `SureStart Production Mode` | `Disable,*Enable` ⇒ **Enable** | 1 | **1** | 0 |
| `Verify Boot Block on every boot` | `*Disable,Enable` ⇒ **Disable** | 1 | 0 | 0 |
| `Dynamic Runtime Scanning of Boot Block` | `*Disable,Enable` ⇒ **Disable** | 1 | 0 | 0 |
| `Sure Start BIOS Settings Protection` | `*Disable,Enable` ⇒ **Disable** | 1 | 0 | **1** |
| `Sure Start Secure Boot Keys Protection` | `*Disable,Enable` ⇒ **Disable** | 1 | 0 | **1** |
| `HP Sure Run Current State` | `Permanently Disabled` | 1 | 1 | 0 |
| `Enhanced HP Firmware Runtime Intrusion Prevention and Detection` | `*Disable,Enable` ⇒ Disable | 1 | 0 | 1 |

**读法（关键）**：**固件本体有保护，设置项级别的保护是关的。**
- `SureStart Production Mode = Enable` 且**只读** ⇒ Sure Start **在跑、且关不掉**（= 固件完整性检测生效）。
- `Sure Start BIOS Settings Protection = Disable` ⇒ **没有**"设置被改就从备份恢复"这一层（HP 官方手册定义：*"Protects critical BIOS Settings by saving a backup copy and restoring them if altered."*）⇒ **保护不是挡魔改的门**。
- `Verify Boot Block on every boot = Disable` 的真实语义（**HP 官方手册表 14，别凭字面猜**）：未勾选 ≠ 不校验 —— 官方原文 *"When not checked, HP Sure Start verifies the integrity of HP firmware … **before resume from Sleep, Hibernate, or Off**"*；勾选才**额外**覆盖 warm reset。⇒ **当前仍在 S3/S4/关机恢复前校验**（只是频率低一档）。
- `BIOS Data Recovery Policy = Automatic`（默认）⇒ 一旦校验失败会**自动修复**。

#### (b) 外部来源（按判据分级）

| 来源 | 关键内容 | 分级 |
|---|---|---|
| HP 官方《PC Commercial BIOS (UEFI) Setup》手册（ZBook Studio G5 表 14，同代商用机） | Sure Start 菜单逐项定义（见上）；`Sure Start BIOS Settings Protection` 默认 Unchecked | **可当判据** |
| coreboot 文档 `doc.coreboot.org/mainboard/hp/hp_sure_start.html` | Sure Start = 芯片组/处理器无关的固件入侵检测 + 自动修复；2013 起装机。**private flash**（2 MB，挂 EC，OS 不可访问）存 `POLI` 策略头 / IFD 副本 / GbE 副本 / MUD / 三者哈希 / bootblock+**PEI**+microcode 副本；改 IFD ⇒ EC 恢复 IFD；**bootblock/PEI/microcode 用数字签名校验**；private flash 无有效副本且 PEI 被改 ⇒ **拒启动 + CapsLock 闪烁** | **可当判据**（但明确标注"method may no longer be applicable to more recent boards"，2013 案例） |
| Win-Raid `[Solved] How to Unlock HP Insyde BIOSes` | 老 HP 的解锁**工具链依赖 IFR**（`Universal IFR Extractor` 读 ROM → 改隐藏项可见性）；且 *"many of these bios have an **RSA signature which makes changes impossible**"*；老机（HP 630）2011–2013 早期版本**无 RSA 可 mod**，F.19 起有 RSA | **可当判据**（含"工具依赖 IFR"这条关键限定） |
| Win-Raid `HP Insyde RSA signed UEFI mod?` | 版主原话：*"this BIOS needs to be modified like a usual BIOS mod to unhide stuff, **but that brings into question RSA**"*；发帖人 *"changed a **jnz to jmp**"* 绕过检查；**"The newer HPs aren't hackable I think **from 2013 and onwards**"**；且 *"my BIOS **doesn't seem to be the standard InsydeH2O** because my BIOS has a full GUI with mouse support"*（**与本机同形**） | **可当判据** |
| HP 支持社区员工回复（两例，InsydeH20） | *"there is **no supported method** to unlock hidden Advanced menus … HP does not provide an option, key combination, or supported procedure"* | **方向强**（官方口径） |
| 网传"U 盘解锁 BIOS 高级选项"（B 站 / 各类短文） | 手法 = UEFI Shell 改 `setuphide` 变量为 `01` ⇒ 显示所有隐藏项。**这是 AMI BIOS 的专有变量**；且视频自曝 *"有些电脑BIOS有保护 … 重启电脑时BIOS就会把 setuphide 改回默认的 00"* | **不可当判据**（机型错配） |

#### (c) 「BIOS 支持」的四层穷举 —— 哪层还活着

| 层 | 现状 | 判据 |
|---|---|---|
| **① 菜单层**（BIOS 里点） | ❌ **无这一项** | BIOS 实拍 + HP 官方菜单全表 + 258 项 WMI 全表三证一致 |
| **② 官方接口层**（WMI / BCU / CMSL） | ❌ **有名字但写不进** | `Modern Standby` = `IsReadOnly=1`；HP 官方原文 *"cannot be changed"* |
| **③ UEFI 变量层**（`setup_var` / `RU.EFI` 直改变量） | ❌ **前提不成立** | 三层理由见下 |
| **④ 固件本体层**（改镜像 + 刷回 = 真·魔改） | ⚠️ **唯一还开着的门**，但要过三道闸（见 d） | Win-Raid + coreboot + 本机保护状态 |

**③ 为什么前提不成立（三层，逐层独立）**：
1. **`setup_var` 依赖 IFR 的 `VarStore` 定义**（告诉工具"写到哪个变量的哪个偏移"）→ **本机固件无 IFR**（三判据全 0，已在两版独立复验）⇒ **连"写到哪里"都不知道**。
2. **网传 `setuphide` 那招是 AMI 专有** → 本机是 HP 自研 Setup 引擎（全 GUI / 鼠标支持，与 Win-Raid 那个"非标准 InsydeH2O"案例同形）⇒ **变量名根本不存在**。
3. **本机 NVRAM 实测**（`nvram -p`）：**仅 10 个变量，全是 macOS/OpenCore 自己的，0 个 HP/Setup 项**。
   ⚠️ **这条是弱证据**（macOS 的 `nvram` 只覆盖它可见的命名空间，第三方厂商变量通常不可见）⇒ **要一锤定音必须在 UEFI Shell 跑 `dmpstore -all`**（只读，零风险，尚未做）。
   ➕ 旁证：HP 官方《Statement of memory volatility》把 **"Permanent system BIOS settings"** 与 **"System boot ROM (BIOS)"** 分成两行 ⇒ 设置存**独立的 16 KB 非易失区**（≈16 MB 固件之外的专属区域），本就不走通用 UEFI 变量机制。

#### (d) ④ 的**三道闸**（真·魔改的代价）

1. **改什么 —— 没有"改可见性"这种便宜事。** 老 HP 那套（IFR Extractor 改隐藏位）**因本机无 IFR 而失效** ⇒ 只剩**逆向 PE32 机器码**去 patch 逻辑分支（Win-Raid 那位改的是 `jnz→jmp`）。本机 `HpSetup` = `172 0147`，PE32 **1.33 MB**，纯手工逆向。
2. **签名 —— HP 自 2013 起对 BIOS 启用 RSA 签名校验。** 改过的镜像**官方刷新工具拒收**（软件路径堵死）。
3. **刷回去 —— 只能物理 SPI 编程。** 拆机 + 编程器（CH341A / RT809F 等）夹/焊 SPI 芯片；且：
   - `SureStart Production Mode = Enable`（**只读，关不掉**）⇒ 完整性检测在位；
   - `BIOS Data Recovery Policy = Automatic` ⇒ 校验失败**自动修复**（= 你的 mod 可能被自动回滚）；
   - coreboot 记录 **private flash**（挂 EC、OS 不可访问）存 bootblock/**PEI**/microcode 副本与哈希 ⇒ **PEI 段被改会从副本恢复；无副本则拒启动**。
   - ⚠️ 未定项（🔴 **推断，不许当结论**）：`HpSetup` 是 **DXE** 模块，而 coreboot 明确点名的签名保护是 **bootblock/PEI/microcode** ⇒ **DXE 是否在 Sure Start 的校验范围内，本机无法确定**。（同代 G8 的维修 dump 为"32 MB + 32 MB"双芯片，与本机是否同构亦未查。）

#### (e) ★★ 决定项：**即便三道闸全打通，终点仍是坏的**

「关 AOAC ⇒ 拿到 S3 ⇒ 睡眠变好」这条链，**中间那段在本机已被实测否证**：

| 环节 | 状态 |
|---|---|
| 拿到 S3 | 三道闸（逆向/签名/物理刷）—— 🔴 未验证，但**理论上**存在 |
| **S3 之后会怎样** | 🟢 **已实测：EC 罢工** —— 撤 `\SB.LPS0` ⇒ `IOPMDeepIdleSupported` Yes→No ⇒ 系统**确实转 S3** ⇒ `AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ USB 栈 panic（本机唯一 panic） |

⇒ **用「拆机 + 物理刷写 + 变砖风险（本机是唯一在用的生产力机 + 已调好的黑苹果）」去赌一个「已实测是坏」的目标** —— **赌注比之前更差，不是更好。**

#### (f) 结论

- **BIOS 层（含魔改）没有一条能改变结局的路。** ① ② ③ 已各自有硬判据；④ 技术上存在但要过三闸、且终点已判死。
- **本轮唯一"未做且零风险"的收口动作**：进 UEFI Shell 跑 `dmpstore` 列全部 UEFI 变量（只读）⇒ 可把 ③ 从"弱证据"升级为"实测"。**但注意：即便 ③ 被证实"设置根本不在 UEFI 变量里"，也不改变结论**（决定的支柱是 (e)）。
- **默认动作 = 不改。**
