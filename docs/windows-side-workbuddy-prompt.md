# 任务：在这台 HP ZBook Power G7 的 Windows 侧做一次「只读取证」

你现在的运行环境是这台机器的 **Windows**。这是一台**双系统**机器（macOS 是主力系统，Windows 是次系统）。
我（另一个 AI，跑在 macOS 侧）需要你在这边跑几条**只读**命令，把结果写到一块两边都能读的盘上，我稍后取。

**这一轮的默认动作是：只读、只报告、不改任何设置。** 看到「Phase C」之前不要做任何写操作。

---

## 一、背景（直接采信，不要重新调查）

- 机器：HP ZBook Power G7，i7-10750H，16 GB，BIOS `T75 Ver. 01.24.02`（2026-05-11）。
- 我已在 macOS 侧**离线拆开了这台机器正在跑的那一版 BIOS 镜像**（`T75_01240200.bin`，32,315,326 B，sha256 `f8929202…`，取自本机 Windows 卷的 DriverStore），确认了几件事（有字节级证据，不是猜的）：
  - 固件里存在一个**正式的 Setup 项 `Modern Standby`**（Enable/Disable 二元项，en/da/es 三种语言的 UI 文本），它的帮助文本自己写着：`Deep Sleep has been gray out because Modern Standby is set to On.`
  - 固件里的内部 Setup 变量名包括：`HpModernStandbyConfigurations`、`DeepS3`、`DeepS3Support`、`PowerControl`、`CpuPwrMgmt`、`WakeOnUSB`。
  - 该固件**没有 IFR**（HII section 计数 = 0，HII 包结束指纹 0 命中）⇒ HP 用的是自研 Setup 引擎，**没有「变量偏移」这种简单结构可读**。
- **我不知道的**（就是这轮要查的）：
  1. 这些项在 Windows 侧能不能被 HP 的 WMI 接口读到？名字叫什么？
  2. `powercfg /a` 在这台机器上到底报哪几个睡眠状态？
  3. 注册表里 `PlatformAoAcOverride` 当前有没有被设过？
  4. BIOS / EC 固件版本能不能在 Windows 侧读到？
- 这些答案只影响一台**已经稳定运行的机器**的「要不要再折腾」的决策。**任何写操作都可能影响 macOS 主系统**，所以默认全只读。

---

## 二、硬边界（违反即任务失败）

1. **Phase A / B 全程只读**：不写注册表、不改 BIOS、不改电源计划、不装/卸驱动、不重启、不睡眠。
2. **严禁修改 BIOS 设置**：不要调用 `HP_BIOSSettingInterface` 的 `SetBIOSSetting`，不要运行 HP BCU 的 `/set`，不要进 BIOS 界面改任何东西。
3. **严禁运行任何固件刷新程序**：`sp*.exe`、HP Image Assistant、HP SoftPaq、`HPBIOSUPDREC`、`BiosFlash` 一律不许跑。**刷固件不可回退，会把机器变砖。**
4. **严禁碰 EFI 分区和 EFI 目录**：不要向 ESP（EFI 系统分区）或 `X:\workplace\zbookpowerg7\EFI\` 或 `Z:\EFI\` 写任何东西，不要挂载/修改引导分区。macOS 的引导配置在那里，改坏 = 开不了机。
5. **不许进入睡眠 / 休眠 / 合盖测试**。Phase C 里也只是读 `powercfg /a`，**绝不真的去睡一次**。
6. **不要重启**，除非用户明确授权执行 Phase C（Phase C 里才需要重启）。
7. 不要为了完成任务去安装第三方工具（HWiNFO / RWEverything / 各种"BIOS 解锁"工具一律不要）。唯一允许的可选安装是 HP 官方的 `HPCMSL` 模块，且**只在 WMI 路径失败时**考虑，并先告诉用户要装什么。
8. 遇到需要**管理员权限**的命令：请用户用管理员身份重开 PowerShell，或你自己用提权方式跑，但**不要**用任何绕过 UAC 的技巧。

---

## 三、Phase A · 环境确认（只读）

PowerShell **必须以管理员身份**运行。先跑：

```powershell
$PSVersionTable.PSVersion
(Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate,Version) | Format-List
(Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,SystemFamily,TotalPhysicalMemory) | Format-List
```

> 注意：`Get-WmiObject` **只在 Windows PowerShell 5.1 里存在**，PowerShell 7（`pwsh`）里没有。
> 如果当前是 PS7，请改用 `powershell.exe -NoProfile -Command "..."` 起 5.1，或把下面的 `Get-WmiObject -Namespace X -Class Y` 换成 `Get-CimInstance -Namespace X -ClassName Y`。

---

## 四、Phase B · 只读取证（这是主体）

### B1 · 命名空间是否存在

```powershell
Get-CimInstance -Namespace root -ClassName __NAMESPACE |
  Where-Object { $_.Name -match 'hp|instrument|bios' } | Select-Object Name
```

### B2 · 全量导出（两个类都导，**含隐藏项**）

```powershell
$ns = 'root/hp/instrumentedBIOS'

# 全部设置（含 BIOS 界面不显示的隐藏项），带 DisplayInUI / IsReadOnly
Get-WmiObject -Namespace $ns -Class HP_BIOSSetting |
  Select-Object Name,Value,DisplayInUI,IsReadOnly,RequiresPhysicalPresence |
  Sort-Object Name | Export-Csv C:\HPBIOS-all.csv -NoTypeInformation -Encoding UTF8

# 常用设置（带 PossibleValues，能看出某个项允许哪些取值）
Get-WmiObject -Namespace $ns -Class HP_BIOSEnumeration |
  Select-Object Name,Value,PossibleValues |
  Sort-Object Name | Export-Csv C:\HPBIOS-enum.csv -NoTypeInformation -Encoding UTF8
```

如果 `Get-WmiObject` 报「类不存在 / 无效命名空间」，**先把原始报错记下来**，然后按顺序试：
1. `Get-CimInstance -Namespace 'root/hp/instrumentedBIOS' -ClassName HP_BIOSSetting`
2. 列命名空间下的所有类：`Get-CimClass -Namespace 'root/hp/instrumentedBIOS' | Select-Object CimClassName`
3. 检查 HP 的 WMI 驱动/服务是否存在：`Get-Service | Where-Object { $_.Name -match 'hp|hpcmi|hpc' }`

### B3 · 关键词筛选（核心产出）

```powershell
$ns = 'root/hp/instrumentedBIOS'
$kw = 'standby|sleep|deep|s3|s0|s0ix|idle|aoac|modern|power|wake|thermal|battery'
Get-WmiObject -Namespace $ns -Class HP_BIOSSetting |
  Where-Object { $_.Name -match $kw } |
  Select-Object Name,Value,DisplayInUI,IsReadOnly | Sort-Object Name |
  Format-Table -AutoSize -Wrap
```

**另外单独精确查这几个名字**（即使上面没筛出来也试一次，名字大小写和空格要照抄）：

```powershell
$ns = 'root/hp/instrumentedBIOS'
foreach ($n in 'Modern Standby','Deep Sleep','Sleep State','Runtime Power Management',
               'Extended Idle Power States','Power Control','Battery Health Manager',
               'Wake On USB','USB Wake','S3','Low Power S0 Idle') {
  $r = Get-WmiObject -Namespace $ns -Class HP_BIOSSetting -Filter "Name='$n'" -ErrorAction SilentlyContinue
  if ($r) { "【命中】{0} = '{1}'  DisplayInUI={2} IsReadOnly={3}" -f $n,$r.Value,$r.DisplayInUI,$r.IsReadOnly }
  else    { "【无此名】$n" }
}
```

### B4 · 系统睡眠状态（只读，关键证据）

```powershell
powercfg /a
powercfg /availablesleepstates
```

再把这两行也跑一下：

```powershell
# 当前 AOAC 覆盖键是否存在、值是多少（只读，不写）
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride
# 顺带看同一键下几个相关值
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue |
  Select-Object CsEnabled,PlatformAoAcOverride,HiberFileSizePercent
```

### B5 · BIOS / EC 版本（能读多少读多少）

```powershell
reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS"
Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' | Format-List *
```

**EC（嵌入式控制器）固件版本**：如果上面读不到，试这几条（都是只读；读不到就直接说读不到，不要硬凑）：

```powershell
Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation -ErrorAction SilentlyContinue
Get-CimClass -Namespace root\wmi | Where-Object { $_.CimClassName -match 'System|Firmware|EC' } |
  Select-Object CimClassName
Get-CimInstance Win32_BaseBoard | Format-List *
```

> 如果确实读不到 EC 版本，就在报告里明确写「WMI 读不到，需要进 BIOS 的 System Information 页肉眼看」。**不要用推测值糊弄。**

### B6 · 可选：如果系统里已有 HP 官方工具

先检查有没有，**有才用，没有不要装**：

```powershell
Get-Module -ListAvailable -Name HP.ClientManagement | Select-Object Name,Version
Test-Path 'C:\Program Files (x86)\HP\BIOS Configuration Utility\BiosConfigUtility64.exe'
Get-ChildItem 'C:\SWSetup' -ErrorAction SilentlyContinue | Select-Object Name
```

- 若 `HP.ClientManagement` 存在：
  ```powershell
  Import-Module HP.ClientManagement
  Get-HPBIOSSettingsList | Select-Object Name,Value | Sort-Object Name
  Get-HPBIOSSettingValue -Name "Modern Standby"
  Get-HPBIOSSettingValue -Name "Deep Sleep"
  Get-HPBIOSSetupPasswordIsSet
  ```
- 若 BCU 存在：
  ```powershell
  & 'C:\Program Files (x86)\HP\BIOS Configuration Utility\BiosConfigUtility64.exe' /get:C:\bcu-all.txt
  Get-Content C:\bcu-all.txt
  ```

### B7 · 把结果写到「两边都能读」的盘上

这台机器上有一块 **exFAT** 格式的共享盘（macOS 侧挂在 `/Volumes/Common`，Windows 侧是某个盘符）。先找到它：

```powershell
Get-Volume | Where-Object { $_.FileSystemType -eq 'exFAT' -and $_.DriveLetter } |
  Select-Object DriveLetter,FileSystemLabel,@{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}}
```

然后**逐个试**（假定找到的盘符是 `X:`）：

```powershell
Test-Path 'X:\workplace\zbookpowerg7'      # 应返回 True
```

若为 True，把所有产物写到这个目录（不存在就创建）：

```powershell
$out = 'X:\workplace\zbookpowerg7\docs\backups\firmware-ledger-2026-09-20\win-side'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Copy-Item C:\HPBIOS-all.csv,C:\HPBIOS-enum.csv -Destination $out -Force
powercfg /a                | Out-File (Join-Path $out 'powercfg-a.txt') -Encoding UTF8
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride |
                             Out-File (Join-Path $out 'reg-platformaoac.txt') -Encoding UTF8
reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" |
                             Out-File (Join-Path $out 'reg-hardware-bios.txt') -Encoding UTF8
Get-ChildItem $out
```

**兜底**：如果找不到那块 exFAT 盘或它不可写，就写到 `C:\Users\Public\`（macOS 侧也能以只读方式读到它），并在报告里说明用了兜底路径。

**另外写一份 `win-side\SUMMARY.md`**（中文），内容 = 你下面第五节那份报告。

---

## 五、输出要求（报告格式）

用**中文**，**结论先行**，多用表格。必须逐条回答这 5 个问题：

| # | 问题 | 期望的答案形态 |
|---|---|---|
| Q1 | `root/hp/instrumentedBIOS` 命名空间和 `HP_BIOSSetting` 类存在吗？一共列出多少项？ | 存在/不存在 + 项数 |
| Q2 | 全表里有没有名字含 `Standby` / `Sleep` / `S3` / `AOAC` / `Modern` / `Deep` 的项？ | 表格：Name / Value / DisplayInUI / IsReadOnly（**没有就明确写「0 条」**） |
| Q3 | `powercfg /a` 的原文输出是什么？哪些睡眠状态可用、哪些不可用？ | 原文引用 + 一句解读 |
| Q4 | `PlatformAoAcOverride` 当前存在吗？值是多少？ | 存在/不存在 + 值 |
| Q5 | BIOS 版本、EC 版本在 Windows 侧能读到吗？ | 读到的值 / 或明确写「读不到」 |

报告里请附上关键命令的**原始输出片段**（不要只给结论），并写清**产物落盘路径**。

**卡住了就直说**：如果 15 分钟内 Phase A/B 跑不通（没有管理员权限、命名空间不存在、类为空、没有 exFAT 盘…），**直接报告卡在哪一步、原始报错是什么**，不要绕路去装第三方工具，也不要"猜一个值"填上去。

---

## 六、Phase C · 需要用户**明确授权**才能做（默认不要做）

> **在用户亲口说「执行 Phase C」之前，读完 Phase A/B 就停下来报告。**
> Phase C 会**改一个注册表键并重启一次**。它是目前唯一能回答「这块固件到底给不给 Windows 传统 S3」的测试。
> **风险边界**：改的是 Windows 自己的一个键，**不碰 macOS**；最坏情况是 Windows 睡不醒（所以下面**不许真的睡**）。

若用户明确授权，按顺序执行：

```powershell
# C1 先记录回滚点（只读）
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride
#   不存在 = 默认状态，回滚动作就是 delete
#   存在     = 记下原值，回滚动作是 add 回原值

# C2 写入（等价于「用传统 S3 覆盖 AOAC/Modern Standby」）
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride /t REG_DWORD /d 0 /f

# C3 重启（这一步需要用户确认机器上没有未保存的东西）
shutdown /r /t 30

# C4 重启后【只看，不睡】—— 这是唯一要的观测
powercfg /a

# C5 无论看到什么，立刻回滚
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v PlatformAoAcOverride /f
#   （若 C1 显示原本就有值，改用：reg add ... /d <原值> /f）
# 回滚后也需要再重启一次才生效；告诉用户这件事。
```

**Phase C 的红线**：
- 不许执行 `powercfg /h off`、不许执行任何睡眠命令、不许合盖、不许拔电。
- C4 只要 `powercfg /a` 的输出。**看到 S3 出现也不要马上去睡** —— 是否真的能睡醒是另一场有准备的测试，由用户决定。
- 做完 C5 才结束；如果 C5 失败，原样报告。
