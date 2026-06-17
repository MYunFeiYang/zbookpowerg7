/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20200925 (64-bit version)
 * Copyright (c) 2000 - 2020 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of /Volumes/Common/workplace/zbookpowerg7/EFI/OC/ACPI/SSDT-PCI0.LPCB-Wake-AOAC.aml, Wed Jun 17 11:15:31 2026
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00000087 (135)
 *     Revision         0x02
 *     Checksum         0xB6
 *     OEM ID           "ACDT"
 *     OEM Table ID     "CLWAKE"
 *     OEM Revision     0x00001000 (4096)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200925 (538970405)
 */
DefinitionBlock ("", "SSDT", 2, "ACDT", "CLWAKE", 0x00001000)
{
    External (_SB_.PCI0.LPCB, DeviceObj)

    Scope (_SB.PCI0.LPCB)
    {
        Method (_DSW, 3, NotSerialized)  // _DSW: Device Sleep Wake
        {
            If ((Arg0 == 0x03))
            {
                OperationRegion (AOWR, SystemIO, 0x1800, 0x02)
                Field (AOWR, ByteAcc, NoLock, Preserve)
                {
                    AOAC,   8, 
                    AOEN,   1
                }

                AOEN = Arg2
            }
        }

        Name (_PRW, Package (0x02)  // _PRW: Power Resources for Wake
        {
            0x6D, 
            0x04
        })
    }
}

