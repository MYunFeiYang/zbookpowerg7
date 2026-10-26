/*
 * SSDT-thunderbolt-nhi-disable  (OEM Table ID: "noTBnh")
 *
 * 作用：仅在 macOS (Darwin) 下把 _SB.PCI0.RP01.PXSX 的 _STA 置 0，使雷电控制器
 *       (含 pci8086,15e8 NHI) 不被枚举；其 INTx 中断随之从共享线 0x50 消失，
 *       消除 "Kernel/Block 屏蔽驱动但 PCI 功能仍灌中断" 的风暴。
 *       TXHC (USB-C, AppleUSBXHCITR) 是 RP01 下的平级独立设备、走 MSI，不受影响 → USB-C 保留可用。
 *       Windows / Linux 下 _OSI("Darwin") 为假 ⇒ 返回 0x0F（存在+启用+可见+正常）。
 *
 * 与 SSDT-thunderbolt-disable (隐藏整个 RP01) 的区别：
 *   后者连 TXHC/USB-C 一起摘掉；本表只摘 PXSX，保住 USB-C。
 *
 * 验证（acpiexec，_OSI("Darwin") 默认 false ≡ Windows 语义）：
 *   非 Darwin ⇒ \_SB.PCI0.RP01.PXSX._STA = 0x0F
 *   Darwin    ⇒ \_SB.PCI0.RP01.PXSX._STA = 0x00
 */

DefinitionBlock ("", "SSDT", 2, "OCLT", "noTBnh", 0x00000000)
{
    External (_SB_.PCI0.RP01.PXSX, DeviceObj)

    Scope (_SB.PCI0.RP01.PXSX)
    {
        Method (_STA, 0, Serialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }

            Return (0x0F)
        }
    }
}
