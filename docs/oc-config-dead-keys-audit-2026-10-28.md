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

---

## 7. ACPI 专项补审（15:20 追加）

用户追问「ACPI 呢」。上一轮只验证了 ACPI 文件是否**存在**，本节补做逐条有效性验证。

### 7.1 ACPI/Patch —— 4 条启用的全部命中原始表

验证方法：拿 `docs/SysReport/ACPI/*.aml`（45 个原始表、共 478,060 B，8-05 从固件导出，
且 Replace 串在原表中出现 **0 次** ⇒ 确认是 patch **之前**的表），用 Python 二进制搜索每条 `Find` 序列。

| # | 用途 | Find（hex） | 命中 | 结论 |
|---|---|---|---|---|
| 0 | PNLF → XNLF 改名（让 macOS 忽略固件背光设备，改用注入的 SSDT-PNLF） | `504e4c46` | **DSDT ×2** | ✅ 有效 |
| 1 | TPD3 `GNUM`→`TPNM`（触控板 GPIO pin） | `474e554d47504449` | **DSDT ×1** | ✅ 有效（Count=1 精确只改这一处；`GNUM` 全表出现 17 次未被误伤） |
| 2 | GPRW → XPRW 全局改名 | `47505257` | — | ⏸ **已禁用（RETIRED 2026-10-27）** |
| 3 | XHC `_PRW` 最低睡眠态 `0x03`→`0x00` | `700a0388600100` | **DSDT ×1** | ✅ 有效 |
| 4 | XDCI `_PRW` 最低睡眠态 `0x04`→`0x00`（阻止重新武装 GPE 0x6D） | `7200…0a6d0a04`(30B) | **DSDT ×1** | ✅ 有效 |

关键资源名交叉验证：`XNLF` / `TPNM` / `XPRW` 在原表出现 **0 次**，`PNLF`×2 / `GPRW`×69 → 与上表自洽。

**⚠️ 耦合约束（重要）**：Patch[1] 与 `SSDT-TPD3-PIN2.aml` 是**一对**，不能单独删任一个。
SSDT 内容为 `Method (TPNM,1){ If(_OSI("Darwin")) Return(0x0102); Return(\_SB.GNUM(Arg0)) }`
（0x0102 = GPIO pin 258 = GPP_E2）。Patch 负责把固件 `TPD3._INI` 里的调用改名，SSDT 负责提供新实现。
删 Patch ⇒ SSDT 的 TPNM 无人调用；删 SSDT ⇒ TPD3._INI 调用未定义的 TPNM ⇒ 触控板 GPIO 断。

### 7.2 ACPI/Add —— 14 个启用 SSDT 全部生效

判据：Scope 目标必须存在于活命名空间（`ioreg -p IOACPIPlane`，175 个节点），
且 SSDT 声明的 Device 必须已注册。

| SSDT | Scope 目标 | 实测 | 提供的设备 |
|---|---|---|---|
| SSDT-EC | `\_SB.PCI0.LPCB` | ✅ LPCB 在 | Device **(EC)** ✅ 已注册 |
| SSDT-PMC | `\_SB.PCI0.LPCB` | ✅ | Device **(PMCR)** ✅ 已注册 |
| SSDT-PCI0.LPCB-Wake-AOAC | `\_SB.PCI0.LPCB` | ✅ | — |
| SSDT-PLUG | `\_SB.PR00` | ✅ PR00 在 | — |
| SSDT-SNDW-off | `\_SB.PCI0.HDAS.SNDW` | ✅ HDAS/SNDW 均在 | — |
| SSDT-I2C0-GNVS | `\_SB.PCI0.I2C0` | ✅ I2C0 在 | — |
| SSDT-thunderbolt-nhi-disable | `\_SB.PCI0.RP01.PXSX` | ✅ RP01/PXSX 均在 | — |
| SSDT-USBX | `\_SB` | ✅ | Device **(USBX)** ✅ 已注册 |
| SSDT-AWAC | `\_SB` | ✅ | 效果：**AWAC 已从命名空间消失、RTC 在位** ⇒ 生效 |
| SSDT-PNLF | （无 Scope，直接建 Device） | ✅ | Device **(PNLF)** ✅ 已注册 |
| SSDT-dGPU-PowerOff-Darwin | （无 Scope） | ✅ | Device **(DGPU)** ✅ 已注册 |
| SSDT-DeepIdle | `_SB` + `_GPE` | ✅（`_GPE` 是纯命名空间节点，ioreg 本就不显示） | `LPS0`/`LXEN` 返回 One（S3 深度空闲） |
| SSDT-LID-G7 | `_GPE` | ✅ | Device LID / S5 / EC0 均在 |
| SSDT-TPD3-PIN2 | （无 Scope，定义 Method） | ✅ | `Method(TPNM)`，配 Patch[1] |

`_GPE` 不在 ioreg 的 175 个节点里属**正常**：它是 ACPI 命名空间作用域，不产生 IORegistryEntry 对象。

### 7.3 ACPI/Quirks —— 7 条逐条定性

| 键 | 值 | 定性 |
|---|---|---|
| `FadtEnableReset` | `true` | 文档 *"Not recommended unless required"*，但它**确实改 FADT**（补 reset register）⇒ 属「可能起作用」非「不可能起作用」。本机重启/关机正常 ⇒ 冗余；收益为零、误判代价是关机异常 ⇒ **保留** |
| `ResetHwSig` | `true` | **跨 OS 必需**：清 FACS `HardwareSignature`。macOS `hibernatemode=0` 用不到，但 **Windows 快速启动 = S4 混合休眠**依赖该签名一致性，归零后 `0==0` 恒匹配 ⇒ 对 Windows **有利** ⇒ 保留 |
| `RebaseRegions` | `true` | 文档 *"Not recommended"*，但作用是 heuristic 重定位 `OperationRegion` 地址 ⇒ 有实际作用。本机无已知 region 偏移症状，属**可能冗余**；无 A/B 证据不敢动 ⇒ 保留 |
| `NormalizeHeaders` | `false` | 等于 Failsafe |
| `ResetLogoStatus` | `false` | 等于 Failsafe（清 BGRT 的 Displayed 位，影响 Win8+ boot logo） |
| `SyncTableIds` | `false` | 等于 Failsafe；只对**老 Windows 的 SLIC 授权**有意义，本机 Win11 无关 |
| `EnableForAll` | `false` | MOD 专有键，False ⇒ 行为等同官方 |

### 7.4 ACPI/Delete —— 删 DMAR 表

`DMAR-1.aml`（200 B）确实存在于原始表 ⇒ 该 Delete 条目**有作用对象、有效**，不是死配置。

它与 `Kernel/Quirks/DisableIoMapper=true` 目的相近但**层次不同**：前者在固件表层面移除 DMAR
（macOS 看不到 DMA Remapping 信息），后者在内核层让 VT-d 不启用。两者叠加是本项目现有配置，
机器启动/睡眠/唤醒均正常 ⇒ **保留**。要验证「是否冗余」只能 A/B 重启，收益为零，不做。

### 7.5 ACPI 结论

**ACPI 段没有任何「不可能起作用」的项**：4 条启用 Patch 全部命中原始 DSDT、
14 个启用 SSDT 的 Scope 目标与 Device 全部在活命名空间、7 条 Quirks 均有作用或属跨 OS 必需、1 条 Delete 有实际对象。

唯一属「历史残留」的是 **4 个已禁用条目**，删掉零风险但也**零收益**，且回滚时需要重写：

- `ACPI/Add`：`SSDT-thunderbolt-disable.aml`（雷电全量隐藏 fallback）、`SSDT-disable-empty-ports.aml`、`SSDT-GPRW.aml`
- `ACPI/Patch`：`GPRW → XPRW`（注释已标 RETIRED 2026-10-27）

⇒ **建议保持现状不动**。ACPI 是本套配置里质量最高的一段：每条都有明确目的、且都能指到实测证据。

### 7.6 附带查实

- `acpidump` 在 macOS 上不可用（那是 Linux 版，读 `/sys/firmware/acpi/tables`，实测报
  `Cannot open directory`）。本机 `iasl`/`acpidump` 在 `/usr/local/bin`，验证改用
  **`docs/SysReport/ACPI/*.aml` 原始表 + Python 二进制搜索**，比 acpidump 更可靠（不依赖运行时）。
- Data Hub 的 `boot-log` 属性在本机**取不到**（`ioreg -lw0 -p IODeviceTree | grep -c boot-log` = 0，
  转出的 `/tmp/oc-bootlog.txt` 为 0 字节）⇒ 本项目长期用于 ACPI 取证的通路目前**不可用**，
  待下次重启后再验证（可能与 Target 已改为 0x05 无关，是 RELEASE 构建下 boot-log 未写入）。

---

## 8. 删除全部禁用条目（15:20 追加）

上一节结论是「4 个已禁用条目可删但零收益、建议保留」。用户决定**不留回滚包袱**，要求清空。
实测全配置共 **6 个 `Enabled=false` 条目**（不止 4 个，另 2 个在 Kernel/UEFI 段），本次全部删除。

### 8.1 删除清单（6 项）

| 段 | 条目 | 删除理由 |
|---|---|---|
| `ACPI/Add` | `SSDT-thunderbolt-disable.aml` | [FALLBACK] 全量隐藏 RP01（会连带杀掉 USB-C）。现行方案走 nhi-disable + Kernel/Block，此路仅作回滚，未启用 |
| `ACPI/Add` | `SSDT-disable-empty-ports.aml` | 注释自述「PROVEN INEFFECTIVE: `_STA=0` cannot remove PCI functions」 |
| `ACPI/Add` | `SSDT-GPRW.aml` | RETIRED 2026-10-27：GPE 0x6D 改由 DSDT 定向 patch（XDCI `_PRW`）处理 |
| `ACPI/Patch` | `GPRW → XPRW` 全局改名 | RETIRED 2026-10-27，同上；全局改名会破坏合盖唤醒 |
| `Kernel/Patch` | `Bypass firmware check (for TB on/lite profiles)` | 只服务已废除的 `tb on`/`tb lite` 档位（依赖的 `SSDT-TB3HP-ZBook(.lite).aml` 早已不在） |
| `UEFI/Drivers` | `AudioDxe.efi` | 开机音的驱动项，未启用 |

### 8.2 校验

- `plutil -lint` → **OK**
- 文本 diff：**删 114 行、增 0 行**（= 8+16+40+36+14，逐块精确吻合，无重排）
- 结构化比对（plistlib）：4 个目标数组 `ACPI/Add 17→14`、`ACPI/Patch 5→4`、`Kernel/Patch 2→1`、`UEFI/Drivers 9→8`，
  **其余全树零差异**；各数组内剩余条目**顺序完全保持**；删除 6 项、新增 0 项
- 全配置 `Enabled=false` 计数：**0**
- 完整性复查：14 个 ACPI 全部在位且非零、29 个 kext 全启用、8 个 UEFI 驱动全部在位
- 工作区与 ESP `config.plist` SHA-256 一致：`688fbd93…`

### 8.3 连带影响（重要）

`EFI/scripts/tb-thunderbolt-profile.sh` 的档位切换**彻底失效**：
它按 `ACPI/Add[].Path` 匹配 `AML_OFF/AML_ON/AML_LITE` 三个文件名来 `PlistBuddy Set :Enabled`。
其中 `SSDT-TB3HP-ZBook.aml` / `SSDT-TB3HP-ZBook-lite.aml` **文件早已不存在**，`SSDT-thunderbolt-disable.aml`
的**配置条目本次已删** ⇒ 三个档位全部无对象。`status` 子命令同理查不到任何一条。
`oc-setup.sh` 已无 `tb` 子命令转发。⇒ 该脚本整份作废。

`README.md` 的「雷电档位」小节已同步改写为**当前状态**（固定屏蔽 + 判据命令 + 限制），
不再提 `tb off/on/lite` 档位（符合本项目「文档只写现状」的约定）。

### 8.4 回滚

`docs/backups/disabled-purge-20261028-1520/config.plist.before`（SHA-256 `5e7a9436…`），
或 `git revert` 本次提交。3 个已删配置项的 `.aml/.dsl` 源文件与 `AudioDxe.efi` **仍保留在仓库与 ESP 上**
（本次只删配置条目，未删文件），需要恢复时把条目加回、`Enabled` 置 `false` 即可。
