/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-thunderbolt-nhi-disable.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x0000006B (107)
 *     Revision         0x02
 *     Checksum         0xCD
 *     OEM ID           "OCLT"
 *     OEM Table ID     "noTBnh"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "noTBnh", 0x00000000)
{
    External (_SB_.PCI0.RP01.PXSX, DeviceObj)

    Scope (_SB.PCI0.RP01.PXSX)
    {
        Method (_STA, 0, Serialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }

            Return (0x0F)
        }
    }
}

