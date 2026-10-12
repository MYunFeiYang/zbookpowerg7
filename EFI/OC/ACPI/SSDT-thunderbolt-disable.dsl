/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of /Volumes/Common/workplace/zbookpowerg7/EFI/oc/ACPI/SSDT-thunderbolt-disable.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000B8 (184)
 *     Revision         0x02
 *     Checksum         0xB2
 *     OEM ID           "OCLT"
 *     OEM Table ID     "noRPxx"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200925 (538970405)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "noRPxx", 0x00000000)
{
    External (_SB_.PCI0.RP01, DeviceObj)

    /*
     * Fix 2026-10-09: 原先在本位置还有一段**模块级(方法外)**的还原分支:
     *     If ((!Arg2 || !_OSI ("Darwin"))) { Return (Buffer (One) { 0x03 }) }
     * 它不在任何 Method 内 ⇒ `Arg2` 无意义、`Return` 在模块级无定义 ⇒ 非 Darwin 保护**完全失效**;
     * 而 Method(_STA) 只有 "If(_OSI("Darwin")){Return(Zero)}"、没有 else ⇒ 非 Darwin 下隐式返回
     * 0 (Zero) = 设备不存在。DSDT 里 RP01 原本**没有 _STA**(默认 0x0F 存在且启用), 于是 Windows
     * 侧 RP01 及其下游 JHL7540 一并被隐藏。已把该分支移入 _STA 作为 else(返回值按原语义取 0x0F)。
     */
    Scope (_SB.PCI0.RP01)
    {
        OperationRegion (DE01, PCI_Config, 0x50, One)
        Field (DE01, AnyAcc, NoLock, Preserve)
        {
                ,   4, 
            DDDD,   1
        }

        Method (_STA, 0, Serialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }

            Return (0x0F)   // 非 Darwin: 还原「DSDT 未定义 _STA」的原语义 = 存在+启用+可见+正常
        }
    }

    Scope (\)
    {
        If (_OSI ("Darwin"))
        {
            \_SB.PCI0.RP01.DDDD = One
        }
    }
}

