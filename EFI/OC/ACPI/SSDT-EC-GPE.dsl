/*
 * SSDT-EC-GPE v3 — EC GPE noise reduction (Windows PEP "MS Enter" emulation).
 *
 * Windows path: PEPD._DSM func3 -> ECNT(One) -> EC0.SLPT = 0x06 (quiet noisy GPEs)
 * macOS never calls PEPD._DSM; DSDT _PTS's ECNT(Zero) branch is dead code (ECUP=1).
 *
 * v3 rationale (measured 2026-11-20 14:40:12):
 *   AppleACPIPlatform logged "ACPI SLEEP" at 14:40:12.762518 and "ACPI S0 WAKE" at
 *   14:40:12.781448 — _PTS and _WAK are evaluated 18.9 ms apart, because the Deep
 *   Idle target state is S0 (S3 is renamed away). v2 cleared SLPT inside _WAK, so the
 *   write was undone before the 5m38s idle window even started (deep_idle_last_stats
 *   = 5:38 matches exactly 14:40:12.762 -> 14:45:50.999). The v2 sample therefore
 *   says nothing about SLPT.
 *   v3 writes 6 unconditionally on _PTS and NEVER clears it, so the value holds for
 *   the whole idle window. EC RAM is volatile: power cycle / reboot restores SLPT=0.
 *
 * Trade-off accepted for this test: SLPT stays 0x06 after wake until the next boot
 * (EC may report battery/AC events less often while awake). Reversible by rebooting.
 */
DefinitionBlock ("", "SSDT", 2, "ECGP", "ECGPE", 0x00003000)
{
    External (ZPTS, MethodObj)    // 1 Arguments
    External (ZWAK, MethodObj)    // 1 Arguments
    External (_SB_.PCI0.LPCB.EC0_.SLPT, FieldUnitObj)

    Method (_PTS, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            // unconditional: the sleep type macOS passes on the S0ix path is not
            // documented, and the conditional write is what voided the v2 sample.
            \_SB.PCI0.LPCB.EC0.SLPT = 0x06
        }
        ZPTS (Arg0)
    }

    Method (_WAK, 1, Serialized)
    {
        // deliberately no SLPT clear: _WAK runs ~19 ms after _PTS on S0ix entry.
        Return (ZWAK (Arg0))
    }
}
