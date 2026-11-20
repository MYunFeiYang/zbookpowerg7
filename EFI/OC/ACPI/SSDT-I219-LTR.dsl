/*
 * SSDT-I219-LTR.dsl — I219-V (GLAN@1F,6) LTR 修复
 *
 * 背景（2026-11-17 deepidle 排查，docs/deepidle-power-audit-2026-11-12.md §38）：
 *   睡眠期 Package 卡 C3（C6-C10=0），机制=PMC 聚合各设备 LTR（可容忍延迟）决定
 *   包级 C-state 上限。I219 的 LTR 经 MMIO LTRV 寄存器（BAR0+0xF8）以 IOSF-SB
 *   sideband 消息发给 PMC（Linux e1000e e1000_platform_pm_pch_lpt 同款机制）。
 *   Linux/Windows 均会动态重写 LTRV；macOS IntelMausi 从不写 → PMC 拿到的永远是
 *   BIOS 开机旧值（推断 ≤75µs，恰卡 PC3(60µs)/PC8(80µs) 边界）→ 包级锁 C3。
 *
 * 本表：在 GLAN._INI（PCI 枚举、BAR 已解码之后）向 LTRV 写入宽松 LTR：
 *   snoop = nosnoop = value 0x3FF / scale 2 = 1023µs ≈ 1ms（> PC10 退出 315µs）
 *   编码字 16bit = 0x3FF | (2<<10) = 0x0BFF
 *   dword = 0x0BFF | 0x0BFF<<16 | REQ(bit15) | REQ(bit31) | SEND(bit30) = 0xCBFF8BFF
 *   （与 Linux e1000_platform_pm_pch_lpt 的 reg 构造一致）
 *
 * 回滚：从 EFI/OC/ACPI 移除本 .aml 并从 config.plist ACPI>Add 删除条目，重启即恢复
 *       BIOS 原值（LTRV 为易失寄存器，无持久状态）。
 * 风险：若 PMC 把 LTR 钳到平台 capability（config 0xA8/0xAA，实测 ≥75µs），效果退化
 *       为 capability 值，不会比现状差；清醒期 XCPM 仍有 75µs ILTR override 主导，
 *       行为不变。
 */

DefinitionBlock ("", "SSDT", 2, "HACK", "I219LTR", 0x00001000)
{
    External (_SB_.PCI0.GLAN, DeviceObj)

    Scope (\_SB.PCI0.GLAN)
    {
        /* I219 MAC MMIO: LTRV @ BAR0+0xF8，BAR0 = 0xE9100000（ioreg 实测） */
        OperationRegion (LTRM, SystemMemory, 0xE91000F8, 0x04)
        Field (LTRM, DWordAcc, NoLock, Preserve)
        {
            LTVW,   32
        }

        Method (_INI, 0, NotSerialized)
        {
            /* Linux 语义: reg = lat | lat<<16 | link<<REQ | link<<(REQ+16) | SEND
             * lat = 0x0BFF (scale 2, value 0x3FF = 1023µs)，link=1 → REQ 两位置位 */
            LTVW = 0xCBFF8BFF
        }
    }
}
