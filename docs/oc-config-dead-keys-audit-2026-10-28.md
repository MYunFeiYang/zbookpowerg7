# OpenCore config 死配置审计（2026-10-28）

对 `EFI/OC/config.plist` 做「只删不可能起作用的东西」的审计。改动 3 个值，未增删任何键。

## 1. 判定口径

一条配置算「无效」必须满足：**取值在本机当前状态下不可能产生任何作用**，且能指到证据之一。

| 级别 | 证据类型 | 本次用到的 |
|---|---|---|
| ① 源码 | 上游 `OcAppleKernelLib/*.c` 版本门控 | SetApfsTrimTimeout |
| ② 文档原文 | `Docs/Configuration.tex` 逐字 | ThirdPartyDrives / SetApfsTrimTimeout |
| ③ 本机事实 | 硬件、kext、运行时实测 | 无 AHCI 设备 / 47 个空日志 |
| ④ 社区实测 | tonymacx86 / 手册译注 | ThirdPartyDrives / Trim |

「依赖未来状态」的一律不删，只标注。

## 2. 证据来源

| 来源 | 取法 | 用途 |
|---|---|---|
| `Configuration.tex`（481,558 B） | `raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Docs/Configuration.tex` | 333 个官方选项定义、Failsafe 值、Note 原文 |
| `CommonPatches.c`（88,047 B） | `.../Library/OcAppleKernelLib/CommonPatches.c` | `PatchSetApfsTrimTimeout` 版本门控 |
| `Sample.plist`（58,101 B） | `.../Docs/Sample.plist` | 区分「我们改过」与「上游就这样」 |
| 本机 OC | `nvram 4D1FDA02-…:opencore-version` | `REL-109-2026-10-11 \| MOD` ⇒ 1.0.9 dev 线，故取 master 分支 |
| 全量比对 | `oc_failsafe_diff.py` | 333 官方项 ⇒ 64 条非出厂值 |

## 3. 已清理（3 项）

### 3.1 `Kernel/Quirks/SetApfsTrimTimeout`：`9999999` → `-1`

- **为什么无效**：源码 `PatchSetApfsTrimTimeout()`（CommonPatches.c:2926）最后一道分支是
  `if (KernelVersion < KERNEL_VERSION_MONTEREY_MIN) { …apply… }`，否则直接
  `DEBUG(("OCAK: Skipping SetApfsTrimTimeout on macOS 12.0+")); return EFI_SUCCESS;`。
  本机 Darwin 25.x / macOS 26.7.2 ⇒ 永远走跳过分支，`9999999` 从未被写入 apfs.kext。
- **证据**：① 源码行 2961/2972；② 官方 Note 2 原文 *"On macOS 12.0 and above, it is no longer
  possible to specify trim timeout. However, trim can be disabled by setting 0."*；
  ④ `oc.skk.moe` 中文手册译注同义。
- **为什么取 `-1` 而不是 `0`**：`0` 走的是门控**之前**的 `ApfsDisableTrim` 分支，会**真正关掉 TRIM**
  （掉性能/加速磨损）；`-1` 是官方 Failsafe，含义是「不应用该 patch，apfs.kext 保持原样」。
  本机盘为 **WD Blue SN570（NVMe）**，TRIM 由 macOS 原生支持，不需要任何 trim quirk。
- **删了不会出事**：等价于「从没设过这个键」，开机 TRIM 行为回到 macOS 默认。

### 3.2 `Kernel/Quirks/ThirdPartyDrives`：`true` → `false`

- **为什么无效**：该 quirk 唯一作用对象是 `com.apple.iokit.IOAHCIBlockStorage`（CommonPatches.c
  `[KernelQuirkThirdPartyDrives] = { "com.apple.iokit.IOAHCIBlockStorage", PatchThirdPartyDriveSupport }`）。
  本机 `system_profiler SPSerialATADataType` **输出 0 行**、`kextstat | grep IOAHCIBlockStorage` **= 0**，
  唯一内置盘是 NVMe。patch 目标连加载都没加载。
- **证据**：② 文档 *"Note: This option may be avoided on user preference. **NVMe SSDs are compatible
  without the change.**"*；③ 无 AHCI 设备 + kext 未加载；
  ④ tonymacx86 实测贴（rafale77, 2022-01-22）：YES/NO 对 boot time 与系统报告 **均无差别**。
- **删了不会出事**：NVMe 走 `IONVMeFamily`，与 AHCI 路径完全不相交。

### 3.3 `Misc/Debug/Target`：`69 (0x45)` → `5 (0x05)`

- **为什么无效**：去掉的是 `0x40`（bit 6，**写文件日志到 ESP**）。实测 ESP 根目录
  **47 个 `opencore-*.txt`，每个恰好 262144 B，其中 44 个非零字节数为 0**；余下 3 个仅 57/142/142 B，
  内容是 10-22/10-23 已修复的历史报错（`Failed to find SSDT-DeepIdle.aml`、`SSDT-TPD3-PIN.aml` 为 0 字节），
  即该位在本机只产出空壳。
- **保留了什么**：`0x01`（启用日志）+ `0x04`（Data Hub）——这正是本项目取证通路
  （`ioreg -lw0 -p IODeviceTree | grep boot-log | ... | xxd -r -p`）。
- **证据**：③ 47 个文件逐个 `tr -d '\0' | wc -c` 实测。

## 4. 看过但不删

| 键 | 现值 | 不删的理由 |
|---|---|---|
| `Misc/Boot/HibernateMode` | `NVRAM` | 条件当前为假：`hibernatemode=0`、`sleepimage` 0 字节、`standby=0` ⇒ 本机不做休眠镜像。属「依赖某功能可用」，非死配置 |
| `Misc/Boot/HibernateSkipsPicker` | `true` | 同上，仅对 hibernation 唤醒有意义 |
| **`ACPI/Quirks/ResetHwSig`** | `true` | **跨 OS 陷阱**：它清 FACS `HardwareSignature`。Windows 侧**快速启动（S4 混合休眠）开着**，该签名一致性正是 S4 恢复的判据；归零后「0==0」恒匹配，对 Windows 快速启动是**正面**作用 ⇒ 不能按「macOS 不 hibernation」判死 |
| `ACPI/Quirks/FadtEnableReset` | `true` | 文档写 *"Not recommended unless required"*，但它**确实会改 FADT**，属「可能产生作用」而非「不可能起作用」。本机重启/关机正常，理论上可关，但收益为零、误判代价是关机异常 ⇒ 保留 |
| `UEFI/Audio/*` | 多项 | `AudioDxe.efi` **文件在 `EFI/OC/Drivers/` 但驱动项 Enabled=false** ⇒ 后端未激活。属「依赖缺失」而非死配置；启用驱动即生效 |
| `ACPI/Quirks/EnableForAll`<br>`Booter/Quirks/EnableForAll`<br>`Misc/Boot/SkipCustomEntryCheck` | 全 `False` | MOD 构建专有键，官方文档无此名；全 False ⇒ 行为等同官方。删掉会让 MOD 回滚时缺键 ⇒ 保留 |
| `Misc/Debug/DisplayLevel` | `0x80000242` | 曾疑为死配置（Target 无 `0x02` console 位），但它同时是 EDK2 全局 `DebugPrint` 级别过滤器，**影响写入 Data Hub 的内容** ⇒ 有作用 |
| `Misc/Security/ExposeSensitiveData` | `2` | 与 Failsafe `0x6` 差 `0x04`（picker 标题显示版本）= 显示偏好，且 `nvram …:opencore-version` 实测可读 ⇒ 生效中 |
| `Misc/Boot/PickerVariant` | `Acidanthera\thinkway` | 曾被疑为 OCAT 误写的用户名，实测 `Resources/Image/Acidanthera/thinkway/` **存在且含 69 个图标** ⇒ 有效主题 |
| 禁用条目（3 ACPI Add + 1 ACPI Patch + 1 Kernel Patch + AudioDxe） | `Enabled=false` | 零开销，保留便于回滚（雷电 fallback、GPRW 旧方案等） |

`PickerAttributes=129 (0x81)`、`UIScale=0`（自动缩放）、`ScanPolicy=0`、`Vault=Optional`、
`SecureBootModel=Disabled`、`TakeoffDelay=500`、`Booter/Quirks` 六项、`Kernel/Quirks` 其余——
均为有明确作用或 Dortania 平台必需，属 C 桶。

## 5. 顺带查实

1. **当前 ACPI / kext 零缺失**：14 个启用 SSDT + 29 个 kext 全部文件在位且大小非零，无 0 字节或缺失项。
2. **ESP 上 7 个 `panic-*.txt` 是 `ApplePanic=true` 的真实崩溃现场**（10-16 六个、10-23 一个，共 60 KB，
   **10-28 无新增**）。其中 **10-23 那次 backtrace 为 `com.apple.iokit.IOThunderboltFamily(9.3.3)`**
   ⇒ 雷电屏蔽这套改动（SSDT 藏 PXSX + Kernel/Block + Patch）堵住的是一条**真实发生过**的崩溃路径。
   10-16 那批为 `apfs` kext 的 kalloc 崩溃与内核 page fault。
3. **ESP 日志清理**：删除 47 个 `opencore-*.txt`（12,320,768 B ≈ 11 MB），其中 44 个纯粹空壳。
   因 `Target` 已去除 `0x40`，后续不再生成。

## 6. 变更记录

| 项 | 值 |
|---|---|
| 备份 | `docs/backups/deadkeys-20261028-1512/config.plist.before` |
| 改前 SHA-256 | `a3a4c7844006cebc34863ec18b39d81a6ba1646aedcb5de977aee46562acec43` |
| 改后 SHA-256 | `5e7a943616cb30162868a1785217db638448e7e08bd57156f4edf7ab77cc658e` |
| ESP 侧 SHA-256 | `5e7a9436…` **与工作区一致** |
| `plutil -lint` | OK |
| 文本 diff | 3 处（3 删 3 加），无格式重排 |
| plistlib 深递归 diff | **3 项，全为值变更，无键增删** |
| ESP 日志 | 删除 47 个，`opencore-*.txt` 剩余 0 |
| 生效条件 | **需重启**；预期行为与改前一致（TRIM 走系统默认、AHCI patch 本就不加载、日志写入 ESP 停止） |

回滚：`cp docs/backups/deadkeys-20261028-1512/config.plist.before EFI/OC/config.plist`（会镜像到 ESP）。
