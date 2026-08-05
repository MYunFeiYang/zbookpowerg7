/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of EFI/OC/ACPI/SSDT-OCLT-S3Fix.aml
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x0000004B (75)
 *     Revision         0x02
 *     Checksum         0x10
 *     OEM ID           "OCLT"
 *     OEM Table ID     "S3-Fix"
 *     OEM Revision     0x00000000 (0)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20200925 (538970405)
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "S3-Fix", 0x00000000)
{
    External (XS3_, IntObj)

    If (_OSI ("Darwin")){}
    Else
    {
        Method (_S3, 0, NotSerialized)  // _S3_: S3 System State
        {
            Return (XS3) /* External reference */
        }
    }
}

