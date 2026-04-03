/*
 * WARNING: This SSDT replaces TPD3._DSM entirely. The machine DSDT already
 * implements _DSM for HIDG / TP7G; a blanket override can break HID descriptor
 * negotiation. Keep disabled in OpenCore until _DSM filters by UUID.
 * Ref: VoodooI2C DSDT / GPIO _CRS guides (e.g. penghubingzhou blog).
 *
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20251212 (64-bit version)
 * Copyright (c) 2000 - 2025 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of /Volumes/ESP/efi/oc/ACPI/SSDT-ELAN.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000CA (202)
 *     Revision         0x02
 *     Checksum         0x38
 *     OEM ID           "ELAN"
 *     OEM Table ID     "FIX"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20251212 (539300370)
 */
DefinitionBlock ("", "SSDT", 2, "ELAN", "FIX", 0x00000001)
{
    /* DSDT: TPD3 lives under I2C0 — not _SB.TPD3 */
    External (_SB_.PCI0.I2C0.TPD3, DeviceObj)

    Scope (_SB.PCI0.I2C0.TPD3)
    {
        Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
        {
            If (!Arg2)
            {
                Return (Buffer (One)
                {
                     0x03                                             // .
                })
            }

            Return (Package (0x0A)
            {
                "device-type", 
                "i2c-device", 
                "elan,recalibrate-on-resume", 
                Buffer (One)
                {
                     0x01                                             // .
                }, 

                "polling-rate-ms", 
                0x06, 
                "interrupt-controller", 
                "GPI0", 
                "gpio-pin", 
                0x3D
            })
        }
    }
}

