/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-PCI0.LPCB-Wake-AOAC.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000B0 (176)
 *     Revision         0x02
 *     Checksum         0xF6
 *     OEM ID           "ACDT"
 *     OEM Table ID     "CLWAKE"
 *     OEM Revision     0x00001000 (4096)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "ACDT", "CLWAKE", 0x00001000)
{
    External (_SB_.PCI0.LPCB, DeviceObj)

    Scope (_SB.PCI0.LPCB)
    {
        Method (_DSW, 3, NotSerialized)  // _DSW: Device Sleep Wake
        {
            If (!_OSI ("Darwin"))
            {
                Return (Zero)
            }

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

        Method (_PRW, 0, NotSerialized)  // _PRW: Power Resources for Wake
        {
            If (_OSI ("Darwin"))
            {
                Return (Package (0x02)
                {
                    0x6D, 
                    0x04
                })
            }

            Return (Package (0x02)
            {
                Zero, 
                Zero
            })
        }
    }
}

