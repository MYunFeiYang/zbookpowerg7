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

## 4. 验证步骤

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
