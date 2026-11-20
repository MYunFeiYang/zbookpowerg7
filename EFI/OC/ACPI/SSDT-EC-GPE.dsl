/*
 * SSDT-EC-GPE — mimic Windows PEP "MS Enter/Exit" EC GPE noise reduction.
 * Windows: PEPD._DSM func3 -> ECNT(One) -> EC0.SLPT = 0x06 (quiet noisy GPEs)
 * macOS never calls PEPD._DSM, so SLPT is never written (ECUP=1 makes
 * DSDT _PTS's ECNT(Zero) branch dead code).
 * This SSDT hooks _PTS/_WAK (via OC ACPI/Patch rename to ZPTS/ZWAK) and writes
 * SLPT on sleep entry / restores 0 on wake. Darwin-only. No kext, no MMIO.
 *
 * v2 (2026-11-20 14:3x): v1 was placed under an invalid "ACPI/Rename" config
 * key, so the renames never applied and the table failed to load with
 * AE_ALREADY_EXISTS (_PTS/_WAK duplicate). v2 is deployed via ACPI/Patch and
 * carries Debug markers so kernel log proves invocation.
 */
DefinitionBlock ("", "SSDT", 2, "ECGP", "ECGPE", 0x00002000)
{
    External (ZPTS, MethodObj)    // 1 Arguments
    External (ZWAK, MethodObj)    // 1 Arguments
    External (_SB_.PCI0.LPCB.EC0_.SLPT, FieldUnitObj)

    Method (_PTS, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            Debug = Concatenate ("ECGP_PTS arg=", ToHexString (Arg0))
            If ((Arg0 == One))
            {
                \_SB.PCI0.LPCB.EC0.SLPT = 0x06
                Debug = "ECGP_SLPT_set6"
            }
        }
        ZPTS (Arg0)
    }

    Method (_WAK, 1, Serialized)
    {
        If (_OSI ("Darwin"))
        {
            \_SB.PCI0.LPCB.EC0.SLPT = Zero
            Debug = "ECGP_SLPT_clear"
        }
        Return (ZWAK (Arg0))
    }
}
