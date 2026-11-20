/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-TPD3-PIN2.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00000059 (89)
 *     Revision         0x02
 *     Checksum         0x62
 *     OEM ID           "HPTPD3"
 *     OEM Table ID     "PINfix"
 *     OEM Revision     0x00000003 (3)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "HPTPD3", "PINfix", 0x00000003)
{
    External (_SB_.GNUM, MethodObj)    // 1 Arguments

    Method (TPNM, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            Return (0x0102)
        }

        Return (\_SB.GNUM (Arg0))
    }
}

