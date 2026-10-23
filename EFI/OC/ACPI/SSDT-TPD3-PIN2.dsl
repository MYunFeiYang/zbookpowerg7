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
 * The real line is GPP_E2 = 258 (VoodooGPIO CannonLake-H numbering).
 *
 * Why an SSDT override of _INI / _CRS does not work
 * ------------------------------------------------
 * DSDT already defines TPD3._INI, TPD3._CRS and TPD3.SBFG. Any SSDT that
 * declares the same names inside Scope(\_SB.PCI0.I2C0.TPD3) is rejected by
 * the interpreter with AE_ALREADY_EXISTS. So the DSDT is patched instead:
 * OpenCore ACPI/Patch rewrites the single "GNUM(GPDI)" call site in the
 * DSDT into "TPNM(GPDI)" (TableSignature=DSDT, Count=1), and this SSDT
 * supplies TPNM.
 *
 * *** Operating-system gating (2026-09-18) ***
 * -------------------------------------------
 * OpenCore applies ACPI/Patch to the DSDT handed to EVERY operating system,
 * Windows included. Because of that, the DSDT that Windows sees also calls
 * TPNM(GPDI) instead of GNUM(GPDI). The earlier revision of this table
 * returned 258 unconditionally, which silently overwrote the interrupt pin
 * that Windows' I2C HID stack uses as well - and the touchpad stopped
 * responding under Windows.
 *
 * TPNM is therefore branched on _OSI("Darwin"):
 *   - Darwin/macOS : 258 (GPP_E2), what VoodooI2C needs.
 *   - anything else : the stock result of GNUM(GPDI), i.e. byte-for-byte
 *                    the pre-hackintosh behaviour. Windows is unaffected.
 *
 * Rollback: git revert this commit (config.plist) - this table alone is inert
 * without the matching ACPI/Patch entry.
 *
 * NOTE: do not run "iasl -d" on SSDT-TPD3-PIN.aml from this directory, it
 * writes the disassembly to SSDT-TPD3-PIN.dsl and overwrites this source.
 */

DefinitionBlock ("", "SSDT", 2, "HPTPD3", "PINfix", 0x00000003)
{
    External (_SB_.GNUM, MethodObj)    // 1 Arguments

    Method (TPNM, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            /* 0x0102 = 258 = GPP_E2 (VoodooGPIO CannonLake-H gpio_base table). */
            Return (0x0102)
        }

        /*
         * Windows / any other OS: reproduce the untouched DSDT behaviour so
         * the rename has no observable effect. GNUM still lives in \_SB.
         */
        Return (\_SB.GNUM (Arg0))
    }
}
