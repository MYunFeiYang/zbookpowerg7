/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20251212 (64-bit version)
 * Copyright (c) 2000 - 2025 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of /Volumes/ESP/efi/oc/ACPI/SSDT-GPI0.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000AD (173)
 *     Revision         0x02
 *     Checksum         0x2C
 *     OEM ID           "HP"
 *     OEM Table ID     "GPI0"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20251212 (539300370)
 */
DefinitionBlock ("", "SSDT", 2, "HP", "GPI0", 0x00000000)
{
    External (_SB_.PCI0.LPCB, DeviceObj)

    Scope (_SB.PCI0.LPCB)
    {
        Device (GPI0)
        {
            Name (_HID, "PRP0001")  // _HID: Hardware ID
            Name (_CID, "composite")  // _CID: Compatible ID
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }

            Name (_CRS, ResourceTemplate ()  // _CRS: Current Resource Settings
            {
                GpioInt (Edge, ActiveHigh, Exclusive, PullNone, 0x0000,
                    "\\_SB.PCI0.GPI0", 0x00, ResourceConsumer, ,
                    )
                    {   // Pin list
                        0x003D
                    }
            })
        }
    }
}

