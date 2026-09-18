# 本机固件（BIOS）事实清单 · 读取方法与实证

> **时间**：2026-09-17 21:3x｜**性质**：只读取证，EFI/pmset **零改动**（临时挂载了 Windows 分区，只读）
> **触发**：用户问「有办法读取 BIOS 给你自己分析吗？」
> **目的**：把"必须人肉进 BIOS 拍照"这件事，降级为"AI 自己就能读"。

---

## 0. 一句话结论

**能读，而且已经读到了 —— 零重启、零风险。** 本机真实 BIOS = **`T75 Ver. 01.24.02`，发布日期 `2026-05-11`**。

⚠️ **一个必须更正的旧记录**：此前文档（`round2-tierB-result.md` §二十六等）写本机 BIOS family 是 **`S71`** —— **错了，实际是 `T75`**。

---

## 1. ★ 已读到的全部事实（全部有出处，非推断）

| 项目 | 值 | 来源（可复核） |
|---|---|---|
| **固件厂商** | **HP** | `ioreg -l -p IODeviceTree` → `/efi` 节点 `"firmware-vendor" = <480050000000>`（UTF-16LE 解出 "HP"。来自 **UEFI System Table**，OpenCore 不改它 ⇒ **真实**） |
| **BIOS 版本** | **`T75 Ver. 01.24.02`** | Windows 注册表 `system` hive → `\ControlSet001\Control\SystemInformation\BIOSVersion` |
| **BIOS 发布日期** | **`05/11/2026`** | 同上 → `FirmwareReleaseDate` |
| **机型** | `HP ZBook Power G7 Mobile Workstation` | 同上 → `OEMModelNumber` |
| **SKU** | `10J83AV` | 同上 → `OEMModelSKU` |
| **产品家族** | `103C_5336AN HP ZBook` | 同上 → `OEMModelSystemFamily` |
| **KBC / EC 固件** | `KBC Version 34.31.00` | 同上 → `OEMModelBaseBoardVersion` |
| **OS 架构标识** | `AMD64` | 同上 → `OSArchitecture` |
| **固件 ABI** | `EFI64` | `ioreg` → `/efi` 节点 `"firmware-abi"` |
| **引导固件类型** | **UEFI**（非 Legacy） | Windows `Windows/Panther/setupact.log`：`Callback_BootEnvironmentDetect:FirmwareType 2`、`Is UEFI`、`IBSLIB ModifyBootEntriesLegacy: **Not a PCAT machine**` |

### 1.1 与 `Firmware.BIN` 的交叉印证

`/Volumes/ESP/EFI/HP/DEVFW/Firmware.BIN`（**31.2 MB**，mtime 2026-07-16 18:29）头部偏移 `0x04d760` 处：

```
04d750  40 01 00 00 34 02 00 00 02 00 00 00 00 00 00 00
04d760  54 37 35 00 ...                    ← "T75"（平台标识）
04d770  ea 07 00 00 05 00 0b 00 18 00 ...
```

- `ea 07` = **2026**、`05 00` = **5 月**、`0b 00` = **11 日**
- ⇒ **与注册表里的发布日期 `05/11/2026` 逐位吻合** ⇒ 该文件 **就是本机当前 BIOS 版本的镜像**（不是"待刷的更新版"）

> ⏹️ 解读到此为止：HP 的 BIOS 版本号（`01.24.02`）**不是明文串**存在镜像里，要从二进制头反推只能确认"平台 + 日期"，**别硬编版本号**。

### 1.2 顺带发现：`DEVFW/` 里共有 6 个固件文件

| 文件 | 大小 | 是什么 |
|---|---|---|
| `Firmware.BIN` | 31.2 MB | 当前 BIOS 镜像（已交叉印证） |
| `MePending.bin` | 10.3 MB | Intel ME 固件 |
| `Camera.bin` | 1.7 MB | 摄像头固件 |
| `TBT.BIN` | 408 KB | **Thunderbolt 固件** |
| `ClickPad.bin` | 189 KB | 触摸板固件 |
| `CCG5C.bin` | 128 KB | Cypress CCG5C USB-C 控制器固件 |

> ⚠️ **`TBT.BIN` 的存在与本机"无 Thunderbolt 控制器（ioreg 零节点）"的旧结论有张力** —— 它可能只是 HP 预置的通用固件包（固件包按机型族打包，不等于本机装配了 TB 硬件）。**定级：线索，不是结论。**

---

## 2. ★ 读取路径盘点（按代价从低到高）

| # | 方法 | 能读到什么 | 代价 | 状态 |
|---|---|---|---|---|
| **P1** | **Windows `SYSTEM` hive + `setupact.log`** | **BIOS 版本 / 日期 / 机型 / SKU / EC 固件 / 引导类型** —— **最全**，一次全拿到 | 磁盘上得有 Windows；挂载 NTFS（只读）+ 解二进制 | ✅ **本次已用，成功** |
| **P2** | `ioreg -l -p IODeviceTree` 的 `/efi` 节点 | 固件厂商、固件 ABI、firmware-revision（数字） | 零 | ✅ 已用（拿到 `HP` / `EFI64`） |
| **P3** | **OC `Misc/Security/ExposeSensitiveData` = `2` → `6`** | vendor / **version** / release-date / 机型 等，全部进 NVRAM `4D1FDA02-…` GUID | **改 1 个数字 + 重启 + 同步 ESP** | ⚠️ 未用（本机 bit2 没开，所以 `nvram` 里查不到） |
| **P4** | **UEFI Shell（OC 的 `OpenShell.efi`）** | `smbiosview -t 0` 看 BIOS 表；**`dmpstore -all` dump 全部 UEFI 变量** ← **唯一能读 BIOS 设置项的路** | 重启 + 手工敲命令 | ⚠️ 未用 |
| **P5** | Linux Live USB | `dmidecode` + `/sys/class/dmi/id/` | 做 U 盘 + 启动 | ⚠️ 未用 |

### 2.1 ✗ 已证伪的路径（别再试）

| 路径 | 为什么不行 |
|---|---|
| macOS `system_profiler` / `ioreg` 的 SMBIOS | OC `UpdateSMBIOSMode=Custom` 把 SMBIOS 整个换成 **Acidanthera 默认值**。解 `AppleSMBIOS` 的 `SMBIOS` 属性：Type 0 的 vendor 串 = **"Acidanthera"** ⇒ **假数据**。`system_profiler` 报的 `2094.80.5.0.0` 是 `MacBookPro16,4` 的版本 ⇒ **假** |
| macOS `nvram -p` 找 HP / Setup 变量 | 只有 **10 个键**，**零个 HP/Setup 变量** ⇒ macOS 侧**看不到真实 UEFI 变量空间** |
| ACPI 表头（DSDT / FACP 的 `OEMID` / `OEM Table ID` / `OEM Revision`） | DSDT 的 `OEMID = 87EC` **正是 OC `ACPI/Quirks/NormalizeHeaders` 的签名** ⇒ 原始固件表头**已被洗掉** |
| WD 的 `Firmware.BIN` 找明文版本号 | 二进制头只有"平台+日期"，**版本号不是明文** |

---

## 3. ★★ 这次读数**改变了一个关键判断**

| 项 | 我上一轮文档里的写法 | 实测真相 |
|---|---|---|
| 本机 BIOS 版本 | "大概率是老旧版本"（未核） | **`01.24.02`，2026-05-11** |
| 对比基准 | "HP 最新 = `01.20.00`（SP157074）" | HP **2026-03** 安全公告（`ish_14446337-14447793-16`）里 ZBook Power G7 的 BIOS **Minimum Version = `01.22.00`（SP161800）** |
| 平台代码 | `S71` | **`T75`** |

**⇒ 本机 BIOS（`01.24.02` / 2026-05-11）比 HP 2026-03 公告的版本更新。**

**对 S4 结论的影响（重要）**：

- 上一轮我说"`#28`（RTC 在断电期保持）虽然改配置改不出来，**但 HP 官方说刷 BIOS 可能解决**，所以不算绝对判死"。
- **现在这条要打折**：本机已经运行在**相当新**的固件上（4 个月前发布），**而 S4 照旧失败** ⇒ "固件老旧导致缺陷"这个假设**在本机基本不成立**，刷 BIOS 的期望值大幅下降。
- ⚠️ 但**不能 100% 判死**：HP 可能在 2026-06 之后又发过更新的版本（本次只查到 2026-03 公告，未拿到 HP 驱动页的实时列表 —— 该页有反爬，WebFetch 只返回标题）⇒ **"再核一次 HP 官网当前 BIOS 列表"仍是一个未结清的动作**。

---

## 4. 复现命令（下次直接用）

```bash
# P2：固件厂商 / ABI（零风险）
ioreg -l -p IODeviceTree | grep -A6 '\+-o efi\b' | grep -E 'firmware-'

# P1：读取 Windows 侧 BIOS 事实（先挂载 NTFS 分区，只读）
diskutil mount disk0s3                     # 本机 = TZBOOK
python3 - <<'PY'
import re
b=open('/Volumes/TZBOOK/Windows/System32/config/system','rb').read()   # 注意是小写 system
i=b.find('T75 Ver.'.encode('utf-16-le'))                                # 或换成 'Ver. 0'
seg=b[i-700:i+2300].decode('utf-16-le','replace')
out=[];cur=''
for c in seg:
    if c.isprintable() and ord(c)>=32: cur+=c
    else:
        if len(cur)>=4: out.append(cur)
        cur=''
for t in out: print(' ',t)
PY

# 引导是否 UEFI（间接判 CSM）
grep -iE 'FirmwareType|Is UEFI|PCAT' /Volumes/TZBOOK/Windows/Panther/setupact.log
```

**坑**：
- `config/` 里 **`system` / `software` 是小写**（`SYSTEM` / `SOFTWARE` 会报"不存在"）—— 别被 `SAM` / `SECURITY` / `DEFAULT` 是大写这件事带偏。
- 注册表字符串可能**奇字节对齐** ⇒ 直接 `find` + 固定偏移解码会出乱码（本次第一轮就踩了）；**先找锚点串（如 `T75 Ver.`）再定偏移**，或两种对齐都试。
- 挂载 NTFS 是**只读**的，安全；用完 `diskutil unmount disk0s3`。

---

## 5. 尚未解决的

| 待办 | 唯一可行的路径 |
|---|---|
| **BIOS 设置项：`CSM` 是否 disabled / `Legacy Support` 状态** | **P4（UEFI Shell `dmpstore -all`）** 或 人肉进 BIOS。macOS/Windows 注册表**都读不到**。（间接证据：`Not a PCAT machine` + `FirmwareType 2` ⇒ UEFI-only 极可能已满足） |
| HP 当前 BIOS 最新版（是否 > `01.24.02`） | HP 驱动页有反爬 ⇒ 需人工查 `support.hp.com` 的 ZBook Power G7 驱动列表 |
