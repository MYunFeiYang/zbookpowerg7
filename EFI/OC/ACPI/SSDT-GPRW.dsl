// Minimal GPRW → XPRW shim (replaces mislabeled full-DSDT blob previously named SSDT-GPRW.aml).
// Requires ACPI patch: Find GPRW, Replace XPRW (DSDT).
DefinitionBlock ("", "SSDT", 2, "OCGPRW", "GPRW", 0x00000000)
{
    External (XPRW, MethodObj)

    Method (GPRW, 4, NotSerialized)
    {
        If ((Arg2 == 0x03))
        {
            Arg3 = Zero
        }

        Return (XPRW (Arg0, Arg1, Arg2, Arg3))
    }
}
