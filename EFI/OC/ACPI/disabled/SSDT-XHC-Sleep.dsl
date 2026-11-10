/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of SSDT-XHC-Sleep.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x0000013A (314)
 *     Revision         0x02
 *     Checksum         0xD3
 *     OEM ID           "OCLT"
 *     OEM Table ID     "XHCNSLP"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "XHCNSLP", 0x00000000)
{
    External (_SB_.PCI0.CNVW, DeviceObj)
    External (_SB_.PCI0.XHC_, DeviceObj)
    External (ZPTS, MethodObj)    // 1 Arguments
    External (ZWAK, MethodObj)    // 1 Arguments

    Scope (_SB.PCI0.XHC)
    {
        Name (XHSF, Zero)
        Method (_STA, 0, NotSerialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                If (XHSF)
                {
                    Return (Zero)
                }

                Return (0x0F)
            }

            Return (0x0F)
        }
    }

    Scope (_SB.PCI0.CNVW)
    {
        Name (CNVF, Zero)
        Method (_STA, 0, NotSerialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                If (CNVF)
                {
                    Return (Zero)
                }

                Return (0x0F)
            }

            Return (0x0F)
        }
    }

    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
    {
        \_SB.PCI0.XHC.XHSF = One
        \_SB.PCI0.CNVW.CNVF = One
        ZPTS (Arg0)
    }

    Method (_WAK, 1, NotSerialized)  // _WAK: Wake
    {
        \_SB.PCI0.XHC.XHSF = Zero
        \_SB.PCI0.CNVW.CNVF = Zero
        Return (ZWAK (Arg0))
    }
}

