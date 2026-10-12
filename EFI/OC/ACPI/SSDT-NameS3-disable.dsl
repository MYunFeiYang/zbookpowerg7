//
// OC-little - i_Prevent_S3_Sleep companion SSDT (Name variant)
// Source: daliansky/OC-little / 5T33Z0/OC-Little-Translated
//   Content/04_Fixing_Sleep_and_Wake_Issues/Fixing_AOAC_Machines/i_Prevent_S3_Sleep
//
// Purpose: OS-gate the S3 disable, so the binary rename does not strip S3 from Windows.
//   - Darwin (macOS)     : _S3 stays renamed away (XS3) -> S3 disabled -> forced AOAC/S0ix
//   - non-Darwin (Windows): _S3 is restored from the renamed XS3 -> Windows keeps S3
//
// REQUIRES the ACPI/Patch binary rename: _S3 (5F53335F) -> XS3 (5853335F)
// Toggle this SSDT and that rename TOGETHER. If the rename is off, XS3 is a dangling
// External reference and ACPI table load can fail.
//
// Variant = Name, because this machine's DSDT declares S3 as a Name (not a Method):
//   DSDT: If (SS3) { Name (_S3, Package (0x04) { 0x05, 0, 0, 0 }) }
//
// Added 2026-10-08.
//
DefinitionBlock("", "SSDT", 2, "OCLT", "S3-Fix", 0)
{
    External (XS3, IntObj)

    If (_OSI ("Darwin"))
    {
        //
    }
    Else
    {
        Method (_S3, 0, NotSerialized)
        {
            Return (XS3)
        }
    }
}
