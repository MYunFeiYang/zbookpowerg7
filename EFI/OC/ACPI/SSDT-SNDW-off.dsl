/*
 * HP ZBook Power G7 — disable Intel SoundWire (SNDW) on macOS.
 * Internal mic may route through SNDW/DMIC; macOS has no Intel SST driver.
 * Disabling SNDW can allow the analog ALC236 path (AppleALC) to be used.
 */
DefinitionBlock ("", "SSDT", 2, "ZBPWR", "SNDWOff", 0x00000000)
{
    External (\_SB.PCI0.HDAS.SNDW, DeviceObj)

    Scope (\_SB.PCI0.HDAS.SNDW)
    {
        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }
            Return (0x0B)
        }
    }
}
