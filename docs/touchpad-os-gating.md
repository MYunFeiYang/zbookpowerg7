# 触控板补丁的 OS 门控缺口 —— Windows 侧触控板失灵的根因与修复

> 日期：2026-09-18　状态：**已修（待同步 ESP + Windows 侧实机验证）**
> 触发：用户报告「macOS 上触控板修好，Windows 上触控板用不了了」

---

## 1. 结论（先行）

**`SSDT-TPD3-PIN.aml` 是全 EFI 唯一没有做 `_OSI("Darwin")` 门控的补丁表，而它改的正是触控板的中断引脚。**
OpenCore 的 `ACPI/Patch` 与 `ACPI/Add` **不区分操作系统**，所以：

- macOS：`TPD3._INI` 里 `INT1 = TPNM(GPDI)` → **258 (GPP_E2)** ← 我们需要这个
- Windows：同样 `INT1 = TPNM(GPDI)` → **也被强制成 258**，而原厂固件给的是 `GNUM(GPDI)` ← **Windows 因此拿不到它原本的中断引脚**

修法：让 `TPNM` 按 `_OSI("Darwin")` 分岔 —— macOS 返回 258，其它系统**回落 `\_SB.GNUM(Arg0)`（= 原厂逐字节行为）**。配置侧一行不用动。

---

## 2. 证据链

### 2.1 门控缺口是唯一的

对 `EFI/oc/ACPI/` 下 14 张表逐个 `strings | grep Darwin`：

| 表 | 门控 |
|---|---|
| SSDT-AWAC / DeepIdle / EC / I2C0-GNVS / LID-G7 / PCI0.LPCB-Wake-AOAC / PLUG / PMC / PNLF / SNDW-off / USBX / dGPU-PowerOff-Darwin / thunderbolt-disable | ✅ 有 |
| **SSDT-TPD3-PIN** | ⚠️ **无** |

⇒ 项目里"补丁一律 `_OSI("Darwin")` 门控"是既有约定，**只有触控板这张漏了**。

### 2.2 项目自己的归档早就标了这个雷

`docs/memory-archive-2026-09.md:31`：

> 触控板（已解决 `e941e48`）：…⚠️ **未 OS 门控 → Win 侧 INT1 也变 258。**

即：风险已知、未堵；本次是它落地成故障。

### 2.3 为什么 `INT1` 正是 Windows 的命门（一手固件代码）

`docs/SysReport/ACPI/DSDT.dsl`（原厂未改 DSDT，2026-08-05 dump）：

```asl
Scope (_SB.PCI0.I2C0) {
  Device (TPD3) {
    Name (SBFB, ResourceTemplate () { I2cSerialBusV2 (0x002C, ...) })        // I2C 从地址
    Name (SBFG, ResourceTemplate () { GpioInt (Level, ActiveLow, ExclusiveAndWake, ...)
                                      { 0x0000 } })                          // GPIO 中断
    Name (SBFI, ResourceTemplate () { Interrupt (..., Level, ActiveLow, ...) { 0x00000000 } })

    CreateWordField (SBFG, 0x17, INT1)                                       // ← 中断引脚字段
    CreateDWordField (SBFI, ... , INT2)                                      // ← APIC IRQ 字段

    Method (_INI, 0) {
        If ((OSYS < 0x07DC)) { SRXO (GPDI, One) }
        INT1 = GNUM (GPDI)        // ★ 被我们的 ACPI/Patch 改写成 TPNM (GPDI)
        INT2 = INUM (GPDI)        //   未改动
        If ((SDM1 == Zero)) { SHPO (GPDI, One) }
    }

    Method (_CRS, 0) {
        If ((OSYS < 0x07DC)) { Return (SBFI) }                  // 老系统/默认 OSYS：只有 APIC IRQ
        If ((SDM1 == Zero))  { Return (SBFB + SBFG) }           // ★ 走这条 ⇒ 用 INT1
        Return (SBFB + SBFI)
    }
  }
}
```

`GNUM` 定义在 `\_SB`（DSDT.dsl:10432）：

```asl
Method (GNUM, 1) { Local0 = GNMB (Arg0);      // Arg0 & 0xFFFF        → 偏移
                   Local1 = GGRP (Arg0);      // (Arg0 >> 16) & 0xFF  → 组号
                   Return (GINF (Local1, 0x06) + Local0) }   // 查表基址 + 偏移
```

### 2.4 判据：`SDM1 == 0`（决定 `_CRS` 走哪条分支）

实时 IORegistry（`ioreg -l -w0`，节点 `VoodooI2CHIDDevice`）：

```
"IOName"                 = "ELAN073D"
"Interrupt Mode"         = "GPIO"          ← macOS 正在用 GPIO 中断，不是 APIC IRQ
"gpioPin"                = 258             ← 正是 TPNM 返回的 0x0102
"IOInterruptControllers" = ("io-apic-0")
"IOInterruptSpecifiers"  = (<3d00000003000000>)   // 0x3D = 61 = INT2 = INUM(GPDI)
```

- macOS 拿到 GPIO 模式 ⇒ `_CRS` 走的是 `SBFB + SBFG` 分支 ⇒ **`SDM1 == 0` 成立**
- 该分支**不区分 OS**（`OSYS` 那层已被 `SSDT-I2C0-GNVS` 顶到 `0x07DF` 绕开）
  ⇒ **Windows 走的是同一条分支、消费同一个 `INT1`**
- `gpioPin = 258` 与 `TPNM` 的返回值逐位吻合 ⇒ `CreateWordField (SBFG, 0x17, INT1)` 确实是引脚字段，链路闭环

**⇒ 我们的改名补丁必然改变 Windows 看到的中断引脚。这是唯一同时"漏门控 + 触控板相关"的改动。**

### 2.5 macOS 侧不受影响（不需要动）

同一份 IORegistry 显示 macOS 触控板**当前完全正常**：`VoodooI2CHIDDevice` +
`VoodooI2CPrecisionTouchpadHIDEventDriver` + `VoodooI2CNativeEngine` + `AppleMultitouchDevice`
全部在载、`DeviceOpenedByEventSystem` 已置位。**修 Windows 不能反过来碰 Darwin 分支。**

---

## 3. 修复内容

`EFI/oc/ACPI/SSDT-TPD3-PIN.dsl`（→ `.aml`，47 B → **89 B**，`iasl` 0 Errors / 0 Warnings）：

```asl
DefinitionBlock ("", "SSDT", 2, "HPTPD3", "PINfix", 0x00000003)
{
    External (_SB_.GNUM, MethodObj)    // 1 Arguments

    Method (TPNM, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            Return (0x0102)            /* 258 = GPP_E2，VoodooI2C 需要 */
        }

        Return (\_SB.GNUM (Arg0))      /* 非 Darwin：回落原厂 GNUM 结果，Windows 零影响 */
    }
}
```

**为什么用 `GNUM(Arg0)` 而不是写死数字**：原厂值是 `GNUM(GPDI)` 的运行期结果（依赖 BIOS 填的
GNVS 字段 `GPDI`），写死任何常数都会重新引入"用一个猜出来的值替换固件值"的风险。回落调用
在语义上保证 **Windows 与未改固件逐字节等价**。

`config.plist` **零改动**：改名条目本身是对的，且作用域已经被限得很紧 ——
`TableSignature = DSDT`、`Count = 1`、全库仅 1 处 `GNUMGPDI`（实测确认，见 §5）。

---

## 4. 验证步骤与实测结果

### 4.0 实测结果 —— ✅ 双侧通过（2026-09-18）

| 侧 | 证据 | 来源 |
|---|---|---|
| **macOS** | 重启后实时 ioreg：`"Interrupt Mode" = "GPIO"`、`"gpioPin" = 258`（与 `TPNM` Darwin 分支 `0x0102` 逐位吻合）；`VoodooI2CDeviceNub` / `VoodooI2CHIDDevice` / `VoodooI2CPrecisionTouchpadHIDEventDriver` / `AppleMultitouchDevice` 全载；`DeviceOpenedByEventSystem = Yes`；无 `isPolling` 强制轮询标志 | **本机 ioreg 实测** |
| **Windows** | 触控板恢复可用 | **用户实机确认**（用户在 Windows 侧操作后回报「两边都 ok 了」） |

流程时序：14:01 从 Windows 关机 → 14:05 重启回 macOS（`last reboot` 实读）。

⚠️ 口径说明：Windows 侧结论来自用户实机体验，**不是 AI 自采数据**（macOS 侧读不到 Windows 的 PCI/ACPI 状态）。但两侧结论一致且与 §2/§3 的机制推断完全吻合 ⇒「回落式修法正确」成立。

与 §4 验证清单的对应：第 1~3 步（同步 + 哈希 + macOS 回归）全部通过（哈希 `61077ccb…`，工作区/ESP 一致）；第 4 步 Windows 侧通过；第 5 步（失败分支排查）未触发。

---

### 4.1 验证清单（供后续同类改动复用）

1. 工作区 → ESP 同步（FreeFileSync 镜像 `EFI/oc` → ESP，**手动点「开始」**；自动触发会滞后）
2. 同步后核对两边 `shasum -a 256 EFI/oc/ACPI/SSDT-TPD3-PIN.aml` 一致
3. macOS 侧回归：重启后 `ioreg -l -w0 | grep -A3 TPD3` 应仍为
   `"Interrupt Mode" = "GPIO"`、`"gpioPin" = 258`，触控板功能不变
4. **Windows 侧验证**：重启进 Windows → 触控板应有反应
   - 仍无反应 → 设备管理器看「人体学输入设备 / I2C HID 设备」状态码
   - 再做一次**彻底断电冷启动**（不是重启）：I2C/GPIO 控制器状态会被复位
5. 若 Windows 侧仍失败 ⇒ **根因不是这条补丁**，改查：Windows 驱动（Intel Serial IO I2C +
   I2C HID）、触控板开关（Fn 组合键 / 设置 → 蓝牙和设备 → 触控板）、或是否被禁用

---

## 5. 附带核实的旁证（本轮一并做掉）

| 项 | 结论 |
|---|---|
| `PNLF → XNLF` 改名 | 无 `TableSignature` 限制 ⇒ **也作用于 Windows**；但 DSDT 里 `PNLF` 只是 GNVS 的 16 位字段名（`DSDT.dsl:9815`，唯一引用 `17924`），两处同步改名 ⇒ 自洽、功能中性。**非触控板问题** |
| `ACPI > Patch` GNUM 条目 | `TableSignature=DSDT`、`Count=1`；`GNUMGPDI` 全库仅 DSDT 1 处 ⇒ 作用面精确，**不用改 config** |
| `ACPI > Delete` = DMAR | 无 `TableSignature` 限 OS ⇒ Windows 也丢 DMAR（VT-d）。**与触控板无关**，但属跨 OS 项，记录在案 |
| 其余 13 张表 | 全部 `_OSI("Darwin")` 门控 ⇒ Windows 侧无副作用 |

---

## 6. 回滚

```bash
git revert <本次提交>          # 恢复 SSDT-TPD3-PIN 的无门控版本（Windows 触控板会再次失灵）
```

原件备份：`/tmp/tpd3fix/SSDT-TPD3-PIN.{dsl,aml}.orig`（临时目录，非长期保存；
权威回滚点是 git 历史里的 `e941e48` 版本）。

> ⚠️ 注意：**不要**用 `iasl -d` 在本目录反编译 `SSDT-TPD3-PIN.aml` —— 会把反汇编结果写回
> 同名 `.dsl`，覆盖掉带注释的源文件（.dsl 与 .aml 同名同目录）。

---

## 7. 2026-10-23 触控板再次失效 —— 不是配置问题，是 ESP 上该 AML 的 FAT 目录项损坏

### 7.1 现象

重启后 macOS 触控板完全无响应（不是手势缺失，是连指针都不动）。实时探针：

| 判据 | 实测 | 良好态（§2.4） |
|---|---|---|
| `VoodooI2CHIDDevice` 实例 | **0** | ≥1 |
| `gpioPin` | **0** | **258** |
| `Interrupt Mode` | `GPIO` | `GPIO` |
| `VoodooI2CDeviceNub`（TPD3 节点） | 1（在） | 1 |
| `VoodooI2CHID` kext | 在载（refs=0，无实例） | 在载 |

关键读法：`Interrupt Mode = "GPIO"` 说明 `_CRS` **已走** `SBFB + SBFG` 分支（`OSYS≥0x07DC` 且
`SDM1==0` 都成立 ⇒ `SSDT-I2C0-GNVS` 正常），但 `SBFG` 里的 GpioInt Pin 仍是 DSDT 原值 `0x0000`。
即 **`TPD3._INI` 里 `INT1 = TPNM(GPDI)` 没有算出 258**。

### 7.2 根因（OpenCore 启动日志实证，非推断）

`ioreg -lw0 -p IODeviceTree | grep -i 'boot-log'` → hex 解出的原文：

```
00:000 00:000 OCA: Inserted ACPI table is only 0 bytes, ignoring
00:004 00:004 OC: Failed to add ACPI SSDT-TPD3-PIN.aml - Invalid Parameter
```

`SSDT-TPD3-PIN.aml` **根本没被 OC 加载** ⇒ `TPNM` 不存在 ⇒ `TPD3._INI` 里那个 MethodInvocation
求值失败 ⇒ `INT1` 保持 0 ⇒ `gpioPin = 0` ⇒ VoodooI2C 把中断装在 pin 0（不存在的 pad）上。

为什么 `sha256` 校验一直是"通过"的：**ESP 是 FAT32，该文件在目录层存在两条 entry。**

```
$ ls -lai /Volumes/ESP/EFI/OC/ACPI/ | grep -i tpd3
   46 -rwx------ 1 thinkway staff   89 2026-09-18 13:00 SSDT-TPD3-PIN.aml   ← macOS 命中这条
   46 -rwx------ 1 thinkway staff   89 2026-09-18 13:00 SSDT-TPD3-PIN.aml   ← 重复条目
```

- `shasum` / `wc -c` / `xxd` 读的是 89 B 那条 ⇒ **内容校验全绿，反而掩盖了问题**
- OpenCore 自带 FAT 驱动命中另一条（`FileSize = 0`）⇒ `only 0 bytes` + `Invalid Parameter`
- 随后 `rm` 该文件返回 `Operation not permitted`，删掉 89 B 那条后残留条目 `inode = 18446744073709551577`（无效值）、`size = 0` —— 坏条目坐实

### 7.3 修法（已实施）

**换名绕行**，不动损坏的目录项：

```bash
git mv EFI/OC/ACPI/SSDT-TPD3-PIN.aml EFI/OC/ACPI/SSDT-TPD3-PIN2.aml
git mv EFI/OC/ACPI/SSDT-TPD3-PIN.dsl EFI/OC/ACPI/SSDT-TPD3-PIN2.dsl
# config.plist: ACPI/Add[7].Path -> SSDT-TPD3-PIN2.aml（AML 内容不变，sha 仍 61077ccb…）
```

随后同步镜像跑完一轮，坏条目被自动清除：ESP 文件数 `342 → 341`，与仓库一致，全量
`shasum` 0 差异。

### 7.4 判据补充（以后查触控板，先看这三行，别先怀疑 config）

```bash
ioreg -lw0 | grep -c '<class VoodooI2CHIDDevice,'          # 期望 ≥1
ioreg -lw0 | grep -o '"gpioPin" = [0-9]*'                  # 期望 258
ioreg -lw0 -p IODeviceTree | grep -i 'boot-log'            # 有 "Failed to add ACPI" 就是加载失败
```

- `gpioPin = 0` 而 `Interrupt Mode = GPIO` ⇒ **ACPI 分支对、`TPNM` 没生效** ⇒ 先查表有没有加载
- `gpioPin = 0` 且 `Interrupt Mode ≠ GPIO` ⇒ `_CRS` 走了 `SBFI` ⇒ 查 `SSDT-I2C0-GNVS` / `OSYS` / `SDM1`
- **`shasum` 一致不能证明 OC 读得到**：FAT 目录项损坏时两条 entry 内容可以不同，而 macOS 只命中好的那条

### 7.5 顺带确认与本案无关的

- `Kernel/Block`（雷电驱动屏蔽）与本故障**无机制通路**：依赖链零交集、`I2C0@15`(0:21.0) 与
  `RP01@1C`(0:28.0) 拓扑不共用、Block 只作用于 `kmod start` 不碰 ACPI。Block 关闭后故障依旧，
  双向都不支持"Block 导致触控板失效"。
- `SSDT-TPD3-PIN.aml` 的 AML 内容（sha `61077ccb…`）与 09-18 修复版逐字节一致 ⇒ 表本身没被改坏。

### 7.6 修复后实测 —— ✅ 已恢复（2026-10-23 10:29 重启，boot `10:29:11`）

| 判据 | 故障时（boot 10:01） | 修复后（boot 10:29） |
|---|---|---|
| `<class VoodooI2CHIDDevice,` | 0 | **1** |
| `"gpioPin"` | 0 | **258** |
| `<class AppleMultitouchDevice,` | 0 | **2** |
| `<class VoodooInput,` | 0（整个 kext 未加载） | **1** |
| `VoodooI2CPrecisionTouchpadHIDEventDriver` | 0 | **1** |
| `Interrupt Mode` | GPIO | GPIO |

**为什么 `gpioPin = 258` 是决定性证据，而不只是"看起来好了"**：

- DSDT 原本 `TPD3._INI` 里是 `INT1 = GNUM(GPDI)`，本机 `GNUM` 解析为 **333**（GPP_I13，没接触控板）
- `ACPI/Patch[1]` 把 DSDT 里这处调用改写成 `TPNM(GPDI)`（`Count=1`，仅此一处）
- `SSDT-TPD3-PIN2` 提供 `TPNM`，**Darwin 分支返回 `0x0102` = 258**，非 Darwin 分支转调 `\_SB.GNUM` 保持原样
- ⇒ **258 这个数只能由 `TPNM` 求值产生**。`TPNM` 不存在时 `_INI` 赋值失败、pin 保持 0（已实测）。所以 258 出现 = 表已加载 + Patch 已生效 + `_OSI("Darwin")` 分支正确，三者同时成立

**一个无效判据（已排除，别再用）**：`ioreg -lw0 | grep TPNM` 恒为 0。`ioreg` 只导出设备属性，不导出 ACPI 命名空间里的方法，搜方法名永远是 0，**不能当反证**。

**复发风险**：ESP 上仍有 `SSDT-TPD3-PIN2.dsl`（2727 B）与同名 `.aml` 并存，形态与本次出事时相同（`.dsl` 与 `.aml` 只差扩展名，挤在同一 8.3 短名空间）。要彻底断根需让同步任务排除 `*.dsl`，属待办，未实施。
