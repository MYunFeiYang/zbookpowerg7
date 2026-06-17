// HP ZBook Power G7 — TB3 on _SB.PCI0.RP01.PXSX (JHL7540 8086:15e8).
// Rollback if unstable: disable this SSDT, enable SSDT-thunderbolt-disable.aml in config.plist.
DefinitionBlock ("", "SSDT", 2, "ACDT", "TB3ZBk", 0x00000000)
{
    External (_SB_.PCI0.RP01, DeviceObj)
    External (_SB_.PCI0.RP01.PXSX, DeviceObj)

    Scope (_SB.PCI0.RP01.PXSX)
    {
        If (_OSI ("Darwin"))
        {
            Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
            {
                If (!Arg2)
                {
                    Return (Buffer (One)
                    {
                         0x03
                    })
                }

                Return (Package (0x04)
                {
                    "built-in",
                    Buffer (One)
                    {
                         0x01
                    },

                    "device-properties",
                    Buffer (0x30)
                    {
                        0x9A, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x0D, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
                        0x9D, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x23, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
                    }
                })
            }

            // Re-init NHI after sleep → wake (Deep Idle / S0ix).
            Method (_DSW, 3, NotSerialized)  // _DSW: Device Sleep Wake
            {
                If ((Arg1 == 0x03))
                {
                    Notify (PXSX, 0x02)
                }
            }
        }
    }

    Scope (_SB.PCI0.RP01)
    {
        If (_OSI ("Darwin"))
        {
            Name (TBHP, Package (0x02)
            {
                "TBHP",
                Buffer (One)
                {
                     0x00
                }
            })

            Method (RSTH, 0, NotSerialized)
            {
                Notify (PXSX, 0x02)
            }

            Method (_DSM, 4, NotSerialized)  // _DSM: Device-Specific Method
            {
                If (!Arg2)
                {
                    Return (Buffer (One)
                    {
                         0x03
                    })
                }

                If ((Arg0 == ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbfbcaa27")))
                {
                    Return (TBHP)
                }

                // force-power only; power-save=1 breaks Deep Idle wake on this machine.
                Return (Package (0x06)
                {
                    "built-in",
                    Buffer (One)
                    {
                         0x01
                    },

                    "device-type",
                    Buffer (0x0E)
                    {
                        "Thunderbolt 3"
                    },

                    "force-power",
                    Buffer (One)
                    {
                         0x01
                    }
                })
            }
        }
    }

    Scope (\)
    {
        If (_OSI ("Darwin"))
        {
            Name (XDSM, Zero)
        }
    }
}
