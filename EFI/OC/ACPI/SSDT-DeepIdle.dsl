/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-DeepIdle.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x00000083 (131)
 *     Revision         0x02
 *     Checksum         0xC6
 *     OEM ID           "OCLT"
 *     OEM Table ID     "IDLE"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "IDLE", 0x00000000)
{
    Scope (_SB)
    {
        Method (LPS0, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
        }
    }

    Scope (_GPE)
    {
        Method (LXEN, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
        }
    }

    Scope (\)
    {
        Name (SLTP, Zero)
        Method (_TTS, 1, NotSerialized)  // _TTS: Transition To State
        {
            If (_OSI ("Darwin"))
            {
                SLTP = Arg0
            }
        }
    }
}

