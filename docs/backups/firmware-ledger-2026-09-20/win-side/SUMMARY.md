# Windows 侧只读取证报告 · HP ZBook Power G7

- 执行时间：2026-09-20 11:5x（GMT+8）
- 执行环境：**Windows PowerShell 5.1.26100.9278（Desktop 版）**，**非管理员权限**
- 边界遵守：全程只读。未写注册表、未改 BIOS、未改电源计划、未装/卸任何驱动或工具、未重启、未睡眠、未触碰 ESP/EFI 分区、未运行任何 `sp*.exe` 或固件刷新程序。
- 产物落盘：`D:\workplace\zbookpowerg7\docs\backups\firmware-ledger-2026-09-20\win-side\`
  （D: 即 exFAT 共享盘「Common」，macOS 侧挂在 `/Volumes/Common`）

---

## 结论先行

| # | 问题 | 结论 |
|---|---|---|
| Q1 | `root/hp/instrumentedBIOS` 命名空间 / `HP_BIOSSetting` 类存在吗？多少项？ | **存在**。`HP_BIOSSetting` 共 **258 项**（含隐藏项）。另有 `HP_BIOSEnumeration` 157 项 |
| Q2 | 有名字含 `Standby`/`Sleep`/`S3`/`AOAC`/`Modern`/`Deep` 的项吗？ | **有 3 条**。核心是 `Modern Standby`，**当前值 = Enable**，且 `DisplayInUI=0`、`IsReadOnly=1`。**完全不存在** `Deep Sleep` / `Sleep State` / `S3` / `AOAC` 项 |
| Q3 | `powercfg /a` 报什么？ | 可用：**S0 低电量待机（Modern Standby）**、休眠、快速启动。**S3 不可用**，原因原文：「当支持 S0 低电量待机时，禁用此待机状态」 |
| Q4 | `PlatformAoAcOverride` 存在吗？值多少？ | **不存在**（默认状态，从未被设过） |
| Q5 | BIOS / EC 版本读得到吗？ | **两者都读得到**。BIOS `T75 Ver. 01.24.02`；EC 固件 **52.49**，KBC **34.31.00** |

**一句话**：这台机器的固件把 **Modern Standby 打开着（Enable）且从 Windows 侧只读**，Windows 因此只给 S0ix、明确不给 S3。要验证「固件到底给不给传统 S3」，`PlatformAoAcOverride` 是唯一软件路径——而它当前不存在。

---

## Q1 · 命名空间与类（原文证据）

`root` 下的直接子命名空间里 HP 相关的是 `HP`（大写）：

```
NS: HP
ALL_NS: subscription | DEFAULT | CIMV2 | msdtc | Cli | Intel_ME | SECURITY | HyperVCluster | SecurityCenter2 |
        RSOP | PEH | HP | StandardCimv2 | WMI | directory | Policy | virtualization | Interop | Hardware |
        ServiceModel | SecurityCenter | Microsoft | Appv
```

`root/hp` 与 `root/HP` 下均有一个子命名空间 `InstrumentedBIOS`（WMI 命名空间大小写不敏感，两种写法都能进）。

实例计数（`Get-WmiObject`，PS 5.1）：

```
HP_BIOSSetting COUNT: 258
HP_BIOSEnumeration COUNT: 157
HP_BIOSString COUNT: 82
HP_BIOSInteger COUNT: 11
HP_BIOSOrderedList COUNT: 6
HP_BIOSPassword COUNT: 2
HP_BIOSUserInterface ERR: 拒绝访问
HP_BIOSSettingInterface COUNT: 1
```

- **`HP_BIOSSetting` = 258 项，全量导出成功。** 这份是全表（不只 BIOS 界面可见项）。
- 唯一读不到的是 `HP_BIOSUserInterface`（拒绝访问），**不影响本次任何结论**——它是 UI 描述类，不是设置本身。
- `HP_BIOSSettingInterface`（就是写接口 `SetBIOSSetting` 所在的那个类）**没有被调用过**，只做了存在性探测。

`Get-WmiObject` 工作正常，**无需退回 `Get-CimInstance`**，也**无需安装 `HPCMSL`**。

---

## Q2 · 睡眠/待机相关项（核心产出）

### 2.1 全表关键词筛选（`standby|sleep|deep|s3|s0|s0ix|idle|aoac|modern|power|wake|thermal|battery`，共 25 条命中）

其中与「睡眠状态」直接相关的全文如下（格式：`Name = Value, DisplayInUI, IsReadOnly`）：

| Name | Value（`*` 标记当前值） | **当前值** | DisplayInUI | IsReadOnly |
|---|---|---|---|---|
| **Modern Standby** | `Disable,*Enable` | **Enable** | **0** | **1** |
| Extended Idle Power States | `*Disable,Enable` | Disable | 1 | 0 |
| Runtime Power Management | `Disable,*Enable` | Enable | 1 | 0 |
| Power Control | `Disable,*Enable` | Enable | 1 | 0 |
| Power button delay to avoid accidental activation for system sleep or power down | `Disable,*Enable` | Enable | 1 | 0 |
| Disable Charging Port in sleep/off if battery below (%): | `10` | 10 | 1 | 0 |
| Battery Health Manager | `Maximize…,*Let HP Manage My Battery Health,…` | Let HP Manage | 1 | 0 |
| Battery Safety Mode | `*Disable,Enable` | Disable | 1 | 1 |

> `thermal` 关键词 **0 条命中**（这台 SKU 的 WMI 表里没有 Thermostat/散热策略项）。

### 2.2 精确点名探测（照抄名字，大小写/空格原样）

```
【命中】Modern Standby = 'Disable,*Enable'  DisplayInUI=0 IsReadOnly=1 ReqPhys=0
【无此名】Deep Sleep
【无此名】Sleep State
【命中】Runtime Power Management = 'Disable,*Enable'  DisplayInUI=1 IsReadOnly=0 ReqPhys=0
【命中】Extended Idle Power States = '*Disable,Enable'  DisplayInUI=1 IsReadOnly=0 ReqPhys=0
【命中】Power Control = 'Disable,*Enable'  DisplayInUI=1 IsReadOnly=0 ReqPhys=0
【命中】Battery Health Manager = 'Maximize…,*Let HP Manage My Battery Health,…'  DisplayInUI=1 IsReadOnly=0 ReqPhys=0
【无此名】Wake On USB
【无此名】USB Wake
【无此名】S3
【无此名】Low Power S0 Idle
```

**明确结论：`Deep Sleep` / `Sleep State` / `S3` / `AOAC` / `Low Power S0 Idle` / `Wake On USB` 在 Windows WMI 全表（258 项）里一条都没有。**

### 2.3 星号语义已做交叉验证（不是猜的）

HP 的 `Value` 字符串用 `*` 前缀标记**当前值**，`PossibleValues` 是无星号的纯取值域。证据（同一项在两个类里的形态）：

```
[Modern Standby]                 Value='Disable,*Enable'                              PossibleValues='Disable ~ Enable'
[Extended Idle Power States]     Value='*Disable,Enable'                              PossibleValues='Disable ~ Enable'
[Runtime Power Management]       Value='Disable,*Enable'                              PossibleValues='Disable ~ Enable'
[Power Control]                  Value='Disable,*Enable'                              PossibleValues='Disable ~ Enable'
[Wake On LAN]                    Value='*Disabled,Boot to Network,…'                  PossibleValues='Disabled ~ …'
[Battery Health Manager]         Value='Maximize…,*Let HP Manage My Battery Health,…'  PossibleValues='Maximize… ~ …'
```

**独立旁证**：`Secure Boot` 该项的 WMI 值为 `*Disable,Enable` ⇒ 当前 = **Disable**。这台机器是 OpenCore 双系统机，Secure Boot 本来就应该是关的 —— 与实际状态吻合。（`Confirm-SecureBootUEFI` 因非管理员被拒，未能从 OS 侧二次核对，故此项为「旁证」而非「铁证」。）另一旁证：`Virtualization Technology (VTx) = Disable,*Enable` ⇒ Enable，同样符合黑苹果实际配置。

### 2.4 与 macOS 侧固件证据的呼应（重要）

- macOS 侧固件字符串显示：`Deep Sleep has been gray out because Modern Standby is set to On.`
- Windows 侧实测：**`Modern Standby` = Enable**，且 **`Deep Sleep` 这项在 258 项全表里根本不存在**。
- 两者**内部一致**：Modern Standby 开着 ⇒ Deep Sleep 被灰掉/不呈现。这不是巧合，是同一逻辑的两侧视图。

**一个必须点出的张力（不建议现在就下结论）**：
- 固件里存在 `Modern Standby` 的正式 Setup 项与 en/da/es 三语 UI 文本；
- 但 Windows WMI 报 **`DisplayInUI=0`（不在 UI 显示）+ `IsReadOnly=1`（只读）**。

两种读法：(a) 该 SKU 上此项确实被隐藏；(b) HP 的 `DisplayInUI` 在此处反映的是「不可改」而非「不显示」。**判定方法是肉眼进一次 F10 BIOS Setup（System Configuration / Built-In Device Options / Power 相关页）看有没有这一项**——这需要用户手工操作，Windows 侧只能读到这里。

同时也要注意：**Windows 侧改不了它**。`IsReadOnly=1` 意味着 `SetBIOSSetting` 也写不动；而本机 `HP.ClientManagement` 模块**不存在**、BCU **不存在**（见下），所以既没有官方工具路径，也不该去绕。

---

## Q3 · `powercfg /a` 原文与解读

```
此系统上有以下睡眠状态:
    待机 (S0 低电量待机) 连接的网络
    休眠
    快速启动

此系统上没有以下睡眠状态:
    待机 (S1)
	系统固件不支持此待机状态。
	当支持 S0 低电量待机时，禁用此待机状态。

    待机 (S2)
	系统固件不支持此待机状态。
	当支持 S0 低电量待机时，禁用此待机状态。

    待机 (S3)
	当支持 S0 低电量待机时，禁用此待机状态。

    混合睡眠
	待机(S3)不可用。
	虚拟机监控程序不支持此待机状态。
```

`powercfg /availablesleepstates` 输出**逐字相同**（同一份数据源）。

**一句解读**：这是一台标准 Modern Standby 机器 —— 可用的是 **S0 低电量待机（S0ix，且带「连接的网络」，即 DRIPS/AOAC 生效）**；**S3 的不可用原因不是「固件不支持」，而是「因为支持 S0 低电量待机而被禁用」**。这个措辞是关键：固件很可能两条路都留了，只是当前被 Modern Standby 挡住了。另外「混合睡眠」还额外多一条「虚拟机监控程序不支持」（Hyper-V/VBS 在跑）。

**严格遵守边界：只读了 `powercfg /a`，没有执行任何睡眠/休眠/合盖动作。**

---

## Q4 · `PlatformAoAcOverride`

```
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride
```
原始输出：
```
reg : 错误: 系统找不到指定的注册表项或值。
```

同键下几个相关值（`Get-ItemProperty`）：

| 值名 | 结果 |
|---|---|
| `PlatformAoAcOverride` | **不存在** |
| `CsEnabled` | 不存在 |
| `HibernateEnabled` | 不存在 |
| `AwayModeEnabled` | 不存在 |
| `PowerSettingProfile` | 不存在 |
| `HiberFileSizePercent` | `0` |

**结论：`PlatformAoAcOverride` 不存在 = 从未被人为设过（默认状态）。** 因此 Phase C 的回滚动作就是 `reg delete`（删掉即回到当前状态），不需要记原值。

---

## Q5 · BIOS / EC 版本

### `HKLM\HARDWARE\DESCRIPTION\System\BIOS` 原文

```
BiosMajorRelease            REG_DWORD    0x18
BiosMinorRelease            REG_DWORD    0x2
ECFirmwareMajorRelease      REG_DWORD    0x34
ECFirmwareMinorRelease      REG_DWORD    0x31
EnclosureType               REG_DWORD    0xa
BaseBoardManufacturer       REG_SZ       HP
BaseBoardProduct            REG_SZ       87EC
BaseBoardVersion            REG_SZ       KBC Version 34.31.00
BIOSReleaseDate             REG_SZ       05/11/2026
BIOSVendor                  REG_SZ       HP
BIOSVersion                 REG_SZ       T75 Ver. 01.24.02
SystemFamily                REG_SZ       103C_5336AN HP ZBook
SystemManufacturer          REG_SZ       HP
SystemProductName           REG_SZ       HP ZBook Power G7 Mobile Workstation
SystemSKU                   REG_SZ       10J83AV
SystemVersion               REG_SZ       SBKPFV3
```

### `Win32_BIOS` 补充字段（EC 就在这里，**读得到，不用肉眼看 BIOS 页**）

| 字段 | 值 |
|---|---|
| `SMBIOSBIOSVersion` | `T75 Ver. 01.24.02` |
| `BIOSVersion`（数组） | `{HPQOEM - 0, T75 Ver. 01.24.02, HP - 1180200}` |
| `SystemBiosMajorVersion` / `Minor` | `24` / `2` |
| `ReleaseDate` | `2026/5/11 8:00:00` |
| **`EmbeddedControllerMajorVersion`** | **52** |
| **`EmbeddedControllerMinorVersion`** | **49** |
| `SerialNumber` | `<REDACTED-SERIAL>` |
| `SMBIOSMajorVersion` / `Minor` | `3` / `2` |
| `CurrentLanguage` | `enUS` |
| `InstallableLanguages` | `15` |
| `BaseBoard` | `87EC`，主板序列号 `<REDACTED-BOARD-CT>` |

`root\wmi:MS_SystemInformation` 交叉一致（同样是 EC 52 / 49、BIOS 24 / 2）。

**结论：BIOS 与 EC 版本 Windows 侧都能读到，EC = 52.49（KBC 34.31.00）。不需要进 BIOS 肉眼看。**

---

## B6 · 官方工具存在性（只探测，未安装任何东西）

```
Get-Module -ListAvailable -Name HP.ClientManagement   -> NOT_FOUND
Test-Path 'C:\Program Files (x86)\HP\BIOS Configuration Utility\BiosConfigUtility64.exe'  -> False
C:\SWSetup -> sp173774
```

- `HPCMSL`（`HP.ClientManagement`）**不存在** —— 但**不需要**，因为原生 WMI 路径已经全部走通。
- BCU（`BiosConfigUtility64.exe`）**不存在**。
- `C:\SWSetup\sp173774` 经查看是 **HP Support Assistant 的安装包**（`InstallHPSA.exe` / `HPSA9x\*.appxbundle` / Fusion 服务 DLL），**不是 BIOS 刷写器**。全程未执行其中任何程序。

### 额外收获：固件镜像交叉验证（两侧核对的是同一份文件）

```
FILE: C:\Windows\System32\DriverStore\FileRepository\t75_01240200.inf_amd64_42ecb2ad108e0833\T75_01240200.bin
Size  : 32315326  (与 macOS 侧 32,315,326 B 一致)
SHA256: F89292026932BE691D59904311CB50B4FBC55379AA554F89479665E04AE6970B
```

与 macOS 侧给出的 `f8929202…` **一致**。⇒ 两侧分析的**确实是同一版 BIOS 镜像**，后续基于固件字节得出的结论可以互相信任。

---

## 产物落盘清单

路径：`D:\workplace\zbookpowerg7\docs\backups\firmware-ledger-2026-09-20\win-side\`

| 文件 | 内容 |
|---|---|
| `HPBIOS-all.csv` | `HP_BIOSSetting` 全量 258 项（Name / Value / DisplayInUI / IsReadOnly / RequiresPhysicalPresence） |
| `HPBIOS-enum.csv` | `HP_BIOSEnumeration` 157 项（Name / Value / PossibleValues，已把 `String[]` 展开成可读文本） |
| `powercfg-a.txt` | `powercfg /a` 原文 |
| `powercfg-avail.txt` | `powercfg /availablesleepstates` 原文 |
| `reg-platformaoac.txt` | `PlatformAoAcOverride` 原始查询输出 + 结论 |
| `reg-hardware-bios.txt` | `HKLM\HARDWARE\DESCRIPTION\System\BIOS` 原样 dump |
| `win-side-evidence.txt` | 环境、权限、BIOS/EC 摘要、固件镜像 sha256 交叉验证 |
| `SUMMARY.md` | 本报告 |

（用的是 exFAT 共享盘，**未使用 `C:\Users\Public` 兜底路径**。）

---

## 未做 / 不能做

- **未执行 Phase C**，未写任何注册表，未重启。等用户明确授权。
- **未运行任何 `sp*.exe` / HPIA / SoftPaq / BIOS 刷新程序**（`C:\SWSetup\sp173774` 只列了目录）。
- **未触碰 ESP / EFI 分区**，未挂载或修改引导分区。
- **未安装** HWiNFO / RWEverything / 任何 BIOS 解锁工具；也未安装 HPCMSL（不必要）。
- `HP_BIOSUserInterface` 读报「拒绝访问」（非管理员），已原样记录；`Confirm-SecureBootUEFI` 同样因非管理员被拒，故星号语义只给了「旁证 + 内部一致性」而没给「OS 侧铁证」。

## 给 macOS 侧的一句话交接

固件层面的 `Modern Standby` 在 Windows 侧**读得到、名叫 `Modern Standby`、当前 = Enable、且只读**；`Deep Sleep` 在 Windows 侧**不存在**（与固件「被灰掉」的说法自洽）；Windows 因此只给 S0ix 不给 S3，且 `PlatformAoAcOverride` 从未被设过。**唯一还没被排除的软件路径就是 Phase C 那个键**——而它需要用户授权 + 一次重启。
