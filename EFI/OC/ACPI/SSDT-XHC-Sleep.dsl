// SSDT-XHC-Sleep.dsl
// 睡眠时把整个 XHC（USB 控制器，含摄像头 HS04 / 蓝牙 HS06）置为离线（_STA=0），
// 唤醒时由 _WAK 复位恢复。需配合 config 里的两个 rename 补丁：_PTS->_ZPTS、_WAK->_ZWAK。
// 收益：睡眠期间 USB 子系统整体断电，省电（社区实测 no battery drain / no heat）。
// 代价：睡眠中只能靠电源键 / 开盖唤醒，USB 键盘鼠标唤不醒。
DefinitionBlock ("", "SSDT", 2, "OCLT", "XHCSLEEP", 0x00000000)
{
    External (_SB.PCI0.XHC, DeviceObj)
    External (ZPTS, MethodObj)
    External (ZWAK, MethodObj)

    Scope (_SB.PCI0.XHC)
    {
        Name (XHSF, 0)
        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                If (XHSF) { Return (Zero) }
                Return (0x0F)
            }
            Return (0x0F)
        }
    }

    Method (_PTS, 1, NotSerialized)
    {
        \_SB.PCI0.XHC.XHSF = 1
        ZPTS (Arg0)
    }

    Method (_WAK, 1, NotSerialized)
    {
        \_SB.PCI0.XHC.XHSF = 0
        Return (ZWAK (Arg0))
    }
}
