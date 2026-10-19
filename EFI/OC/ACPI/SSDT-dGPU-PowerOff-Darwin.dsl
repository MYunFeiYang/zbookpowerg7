/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-dGPU-PowerOff-Darwin.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000A1 (161)
 *     Revision         0x02
 *     Checksum         0x0E
 *     OEM ID           "OCLT"
 *     OEM Table ID     "NDGP"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200925 (538970405)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "NDGP", 0x00000000)
{
    External (_SB_.PCI0.PEG0.PEGP._OFF, MethodObj)    // 0 Arguments

    If (_OSI ("Darwin"))
    {
        Device (DGPU)
        {
            Name (_HID, "DGPU1000")  // _HID: Hardware ID
            Method (_INI, 0, NotSerialized)  // _INI: Initialize
            {
                If (CondRefOf (\_SB.PCI0.PEG0.PEGP._OFF))
                {
                    \_SB.PCI0.PEG0.PEGP._OFF ()
                }
            }
        }
    }
}

