/*
 * SSDT-TPD3-INI — Replace TPD3._INI: GNVS OSYS/SDM1 then OEM SRXO/GNUM/SHPO
 * Self-contained GNVS writes (same base as DSDT / SSDT-I2C0-GNVS).
 */
DefinitionBlock ("", "SSDT", 2, "HPTPD3", "INIfix", 0x00000002)
{
    External (_SB_.GNUM, MethodObj)
    External (_SB_.INUM, MethodObj)
    External (_SB_.SHPO, MethodObj)
    External (_SB_.SRXO, MethodObj)
    External (_SB_.PCI0.I2C0.TPD3, DeviceObj)
    External (GPDI, FieldUnitObj)
    External (OSYS, FieldUnitObj)
    External (SDM1, FieldUnitObj)

    Scope (_SB)
    {
        OperationRegion (TPN2, SystemMemory, 0x77B2F000, 0x07FA)
        Field (TPN2, AnyAcc, NoLock, Preserve)
        {
            TPNX,   16,
            Offset (0x42C),
            TPNS,   8,
        }
    }

    Scope (_SB.PCI0.I2C0.TPD3)
    {
        External (INT1, FieldUnitObj)
        External (INT2, FieldUnitObj)
        External (HID2, IntObj)
        External (BADR, FieldUnitObj)
        External (SPED, FieldUnitObj)

        Method (_INI, 0, NotSerialized)
        {
            TPNX = 0x07DF
            TPNS = Zero
            If ((OSYS < 0x07DC))
            {
                \_SB.SRXO (GPDI, One)
            }

            INT1 = \_SB.GNUM (GPDI)
            INT2 = \_SB.INUM (GPDI)
            If ((SDM1 == Zero))
            {
                \_SB.SHPO (GPDI, One)
            }

            HID2 = 0x20
            BADR = 0x2C
            SPED = 0x00061A80
        }
    }
}
