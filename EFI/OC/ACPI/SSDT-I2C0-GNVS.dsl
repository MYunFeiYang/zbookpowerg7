/*
 * SSDT-I2C0-GNVS — Run before TPD3._INI: align GNVS OSYS/SDM1 with Windows 10+
 *
 * DSDT _SB.PCI0._INI sets OSYS = 0x07D0 then only raises it when _OSI matches
 * "Windows …" strings. Darwin matches none, so OSYS stays 0x07D0 (< 0x07DC).
 *
 * TPD3._INI then takes a different branch than Windows 10+ (SRXO / SHPO).
 *
 * GNVS base (this machine SysReport DSDT): 0x77B2F000
 * SDM1 at byte 0x42E (after Offset(0x429) ATLB + SDM0 + SDM1)
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
            TPSD,   8,
        }
    }

    Scope (_SB.PCI0.I2C0)
    {
        Method (_INI, 0, NotSerialized)  // replaces DSDT — keep OEM assignments
        {
            TPOX = 0x07DF
            TPSD = Zero
            I2CN = SDS0 /* \SDS0 */
            I2CX = Zero
        }
    }
}
