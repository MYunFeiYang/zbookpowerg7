/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of SSDT-LID-G7.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000EB (235)
 *     Revision         0x02
 *     Checksum         0xAC
 *     OEM ID           "ACDT"
 *     OEM Table ID     "LIDG7"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200925 (538970405)
 */
DefinitionBlock ("", "SSDT", 2, "ACDT", "LIDG7", 0x00000000)
{
    Name (GLID, One)
    Device (LID)
    {
        Name (_HID, "PNP0C0D" /* Lid Device */)  // _HID: Hardware ID
        Name (_CID, "PNP0C0D" /* Lid Device */)  // _CID: Compatible ID
        Method (_STA, 0, NotSerialized)  // _STA: Status
        {
            Return (0x0B)
        }

        Method (_LID, 0, NotSerialized)  // _LID: Lid Status
        {
            Return (GLID) /* \GLID */
        }
    }

    Scope (_GPE)
    {
        Method (_L00, 0, NotSerialized)  // _Lxx: Level-Triggered GPE, xx=0x00-0xFF
        {
            Local0 = ^^EC0.LIDS /* \EC0_.LIDS */
            If ((Local0 == Zero))
            {
                GLID = Zero
                Notify (LID, 0x80) // Status Change
                Sleep (0x03E8)
                ^^S5.S5SL = 0x03
                GLID = One
            }
            Else
            {
                GLID = One
            }

            Return (Zero)
        }
    }

    Device (S5)
    {
        Name (_HID, "ACPI0004" /* Module Device */)  // _HID: Hardware ID
        Name (S5SL, Zero)
    }

    Device (EC0)
    {
        Name (_HID, "PNP0C09" /* Embedded Controller Device */)  // _HID: Hardware ID
        Name (LIDS, Zero)
    }
}

