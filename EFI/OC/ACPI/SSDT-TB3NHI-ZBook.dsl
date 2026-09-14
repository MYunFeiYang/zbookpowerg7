/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of SSDT-TB3NHI-ZBook.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000001DE (478)
 *     Revision         0x02
 *     Checksum         0x2C
 *     OEM ID           "OCLT"
 *     OEM Table ID     "TB3NHI"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "TB3NHI", 0x00000000)
{
    External (_SB_.PCI0.RP01, DeviceObj)
    External (_SB_.PCI0.RP01.PXSX, DeviceObj)

    Scope (_SB.PCI0.RP01.PXSX)
    {
        If (_OSI ("Darwin"))
        {
            Device (DSB0)
            {
                Name (_ADR, Zero)  // _ADR: Address
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Device (NHI0)
                {
                    Name (_ADR, Zero)  // _ADR: Address
                    Name (_STR, Unicode ("Thunderbolt"))  // _STR: Description String
                    Method (_STA, 0, NotSerialized)  // _STA: Status
                    {
                        Return (0x0F)
                    }

                    Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
                    {
                        If (!Arg2)
                        {
                            Return (Buffer (One)
                            {
                                 0x03                                             // .
                            })
                        }

                        Return (Package (0x06)
                        {
                            "device_type", 
                            Buffer (0x19)
                            {
                                "Thunderbolt 3 Controller"
                            }, 

                            "model", 
                            Buffer (0x0C)
                            {
                                "JHL7540 NHI"
                            }, 

                            "power-save", 
                            One
                        })
                    }
                }
            }

            Device (DSB1)
            {
                Name (_ADR, 0x00010000)  // _ADR: Address
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }
            }

            Device (DSB2)
            {
                Name (_ADR, 0x00020000)  // _ADR: Address
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    Return (0x0F)
                }

                Device (XHC5)
                {
                    Name (_ADR, Zero)  // _ADR: Address
                    Method (_STA, 0, NotSerialized)  // _STA: Status
                    {
                        Return (0x0F)
                    }

                    Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
                    {
                        If (!Arg2)
                        {
                            Return (Buffer (One)
                            {
                                 0x03                                             // .
                            })
                        }

                        Return (Package (0x06)
                        {
                            "device_type", 
                            Buffer (0x1D)
                            {
                                "Thunderbolt 3 USB Controller"
                            }, 

                            "model", 
                            Buffer (0x0D)
                            {
                                "JHL7540 XHCI"
                            }, 

                            "built-in", 
                            One
                        })
                    }
                }
            }
        }
    }
}

