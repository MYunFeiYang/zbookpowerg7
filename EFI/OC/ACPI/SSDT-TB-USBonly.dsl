// SSDT-TB-USBonly.dsl
// 目标：macOS 下只禁雷电 NHI (func 0)，保留 USB (func 2 = TXHC)
// 背景：
//   HP 的 HPTBT 表把雷电控制器的 USB 控制器 TXHC(func 2) 建模成 NHI(func 0) 的“子设备”
//   （路径 RP01.PXSX.EP02.TXHC）。原 SSDT-thunderbolt-disable 直接禁整个 RP01，
//   导致 USB-C 口的 USB 也一起被禁。
// 做法：
//   1) RP01 保持启用（不再禁整个端口）
//   2) 仅 macOS 下把 PXSX(NHI, func 0) 设 _STA=0 —— 雷电不被 macOS 驱动，避免 ThunderboltFamily panic
//   3) TXHC(USB, func 2) 提成 RP01 的直接子设备(TBTU) 并始终启用 —— USB-C 口在 macOS 下可用
// 注意：启用本表时必须同时禁用 SSDT-thunderbolt-disable（二者互斥）。
// 验证：回 macOS 后插 USB-C 设备看是否识别、睡眠唤醒是否还 panic。
DefinitionBlock ("", "SSDT", 2, "OCLT", "TBUSBOnl", 0x00000000)
{
    External (\_SB.PCI0.RP01, DeviceObj)
    External (\_SB.PCI0.RP01.PXSX, DeviceObj)

    // (1) macOS 下让 PXSX(NHI, func 0) 不可见 = 禁雷电 PCIe 功能
    Scope (\_SB.PCI0.RP01.PXSX)
    {
        Method (_STA, 0, Serialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }
            Return (0x0F)
        }
    }

    // (2) TXHC(USB, func 2) 作为 RP01 直接子设备，始终启用
    Scope (\_SB.PCI0.RP01)
    {
        Device (TBTU)
        {
            Name (_ADR, 0x00020000)   // func 2 (原 HPTBT 中的 EP02 地址)
            Method (_STA, 0, Serialized)
            {
                Return (0x0F)
            }
            Device (TXHC)
            {
                Name (_ADR, Zero)
                Method (_STA, 0, Serialized)
                {
                    Return (0x0F)
                }
            }
        }
    }
}
