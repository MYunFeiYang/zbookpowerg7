/*
 * SSDT-TPD3-CRS — HP TPD3 (ELAN073D @ I2C0 0x2C) _CRS fix
 *
 * DSDT._SB.PCI0.I2C0.TPD3._CRS returns only Interrupt (SBFI) when OSYS < 0x07DC,
 * which omits the I2cSerialBus template. On Hackintosh, GNVS OSYS can be low
 * before patching, so always expose the Windows-style I2C+GPIO template used
 * for SDM1 == Zero:
 *   ConcatenateResTemplate (SBFB, SBFG)
 *
 * GPIO pin word is filled with the same GNUM(GPDI) as OEM _INI (offset 0x17
 * matches stock DSDT CreateWordField on SBFG).
 *
 * Ref: VoodooI2C DSDT / _CRS discussion (e.g. penghubingzhou tutorial).
 *
 * Note: If GNVS / GPDI is uninitialized on some boots, GNUM(GPDI) can return 0
 * and the GPIO word stays 0 — no IRQ. Fallback 0x003D matches this machine’s
 * OEM pin (see SSDT-ELAN disassembly / disabled SSDT-GPI0 pin list).
 */
DefinitionBlock ("", "SSDT", 2, "HPTPD3", "CRSfix", 0x00000001)
{
    External (_SB_.PCI0.I2C0.TPD3, DeviceObj)
    External (_SB_.GNUM, MethodObj)
    External (GPDI, IntObj)

    Scope (_SB.PCI0.I2C0.TPD3)
    {
        Name (SBFX, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,
                AddressingMode7Bit, "\\_SB.PCI0.I2C0",
                0x00, ResourceConsumer, , Exclusive,
                )
        })

        Name (SBFG, ResourceTemplate ()
        {
            GpioInt (Level, ActiveLow, ExclusiveAndWake, PullDefault, 0x0000,
                "\\_SB.PCI0.GPI0", 0x00, ResourceConsumer, ,
                )
                {
                    0x0000
                }
        })

        CreateWordField (SBFG, 0x17, GPIN)

        Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
        {
            Local0 = \_SB.GNUM (GPDI)
            If ((Local0 == Zero))
            {
                Local0 = 0x003D
            }

            GPIN = Local0
            Return (ConcatenateResTemplate (SBFX, SBFG))
        }
    }
}
