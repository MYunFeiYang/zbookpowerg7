/*
 * HP ZBook Power G7 - trackpad (TPD3 / ELAN073D) GPIO interrupt pin fix.
 *
 * Problem
 * -------
 * DSDT TPD3._INI computes the GpioInt pin of SBFG as:
 *
 *     INT1 = GNUM (GPDI)
 *     INT2 = INUM (GPDI)
 *
 * GPDI is a 32-bit GNVS field (BIOS filled, never written by ACPI), and
 * GNUM(v) = GINF(GGRP(v), 6) + GNMB(v) resolves to pin 333 on this machine.
 * Pin 333 is GPP_I13, which is NOT wired to the trackpad interrupt line.
 * macOS (VoodooI2C in GPIO interrupt mode) therefore installs the interrupt
 * on the wrong pad and the trackpad never reports any event.
 *
 * Windows reports the real line for the very same device as GPP_E2:
 * group index 4 in the GPCH package (elem1 = 13 pins, elem6 = 0x0100 base)
 * plus offset 2, i.e. pin 0x0102 = 258 in the VoodooGPIO numbering.
 *
 * Why an SSDT override of _INI / _CRS does not work
 * ------------------------------------------------
 * DSDT already defines TPD3._INI, TPD3._CRS and TPD3.SBFG. Any SSDT that
 * declares the same names inside Scope(\_SB.PCI0.I2C0.TPD3) is rejected by
 * the interpreter with AE_ALREADY_EXISTS:
 *
 *   ACPI Error: [SBFG] Namespace lookup failure, AE_ALREADY_EXISTS
 *   ACPI Exception: AE_ALREADY_EXISTS, (SSDT:  CRSfix) while loading table
 *   ACPI Error: [_INI] Namespace lookup failure, AE_ALREADY_EXISTS
 *
 * So the DSDT is patched instead. OpenCore ACPI/Patch rewrites the single
 * call site "GNUM(GPDI)" in the DSDT into "TPNM(GPDI)", and this SSDT
 * supplies TPNM. The ambiguous GNUM() group lookup (GPCH vs GPCL, selected
 * by PCHS) is bypassed completely, so the result is deterministic.
 *
 * Net effect: INT1 = 258 = GPP_E2. INT2 (the fallback APIC IRQ in SBFI) is
 * intentionally left untouched.
 *
 * Rollback: git revert this commit (config.plist) - this table alone is inert
 * without the matching ACPI/Patch entry.
 *
 * NOTE: do not run "iasl -d" on SSDT-TPD3-PIN.aml from this directory, it
 * writes the disassembly to SSDT-TPD3-PIN.dsl and overwrites this source.
 */

DefinitionBlock ("", "SSDT", 2, "HPTPD3", "PINfix", 0x00000003)
{
    Method (TPNM, 1, NotSerialized)
    {
        /* 0x0102 = 258 = GPP_E2 (VoodooGPIO CannonLake-H gpio_base table). */
        Return (0x0102)
    }
}
