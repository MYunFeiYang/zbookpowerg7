/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-I2C0-GNVS.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x000000DC (220)
 *     Revision         0x02
 *     Checksum         0x5B
 *     OEM ID           "HPI2C0"
 *     OEM Table ID     "GNVSfix"
 *     OEM Revision     0x00000001 (1)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20260408 (539362312)
 */
DefinitionBlock ("", "SSDT", 2, "HPI2C0", "GNVSfix", 0x00000001)
{
    External (_SB_.PCI0.I2C0, DeviceObj)
    External (_SB_.PCI0.I2C0.I2CN, IntObj)
    External (_SB_.PCI0.I2C0.I2CX, IntObj)
    External (SDS0, FieldUnitObj)

    Scope (_SB)
    {
        OperationRegion (TPGN, SystemMemory, 0x77B2F000, 0x07FA)
        Field (TPGN, AnyAcc, NoLock, Preserve)
        {
            TPOX,   16, 
            Offset (0x42C), 
            TPSD,   8
        }
    }

    Scope (_SB.PCI0.I2C0)
    {
        If (_OSI ("Darwin"))
        {
            Method (_INI, 0, NotSerialized)  // _INI: Initialize
            {
                TPOX = 0x07DF
                TPSD = Zero
                I2CN = SDS0 /* External reference */
                I2CX = Zero
            }
        }
    }
}

