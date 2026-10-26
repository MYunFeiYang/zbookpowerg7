/*
 * SSDT-disable-empty-ports  (OEM Table ID: "noEMPxx")
 *
 * 作用：仅在 macOS (Darwin) 下把以下"空端口 / 非功能设备"的 _STA 置 0，使其不被枚举，
 *       从而消除它们挂在共享传统 INTx 线 (CPU0 Vector 0x50) 上的中断风暴：
 *         - _SB.PCI0.PEG0  (00:01.0) 空 dGPU 根端口（P620 在 macOS 下不枚举）
 *         - _SB.PCI0.RP17  (00:1B.0) 空 PCH 根端口
 *         - _SB.PCI0.SBUS  (00:1F.4) SMBus（无功能子设备，且是 0x50 共享线常驻民）
 *       Windows / Linux 下 _OSI("Darwin") 为假 ⇒ 显式返回 0x0F，行为与 DSDT 原本一致。
 *
 * 动机（2026-10-26 中断风暴排查）：
 *   powermetrics 实测 CPU0 Vector 0x50 ≈ 23,000 interrupts/sec 持续不断，钉死 CPU0、
 *   风扇狂转。0x50 是共享传统 INTx 线；ioreg 实测只有 5 个设备是 legacy-only（无 MSI 可选、
 *   只能走 0x50）：PEG0 / I2C0 / RP17 / pci-bridge@1C / SBUS。
 *   HDEF AFG 补丁（-5%）、雷电 RP01 禁用（0%）均无效 ⇒ 风暴源不在这两者。
 *   本实验隔离上述 3 个"空端口/非功能"候选（I2C0 因挂触控板暂不碰），用于二分定位真凶。
 *
 * 回滚：config.plist 中本表 Enabled 改回 False 即可；git 留存历史。
 * 风险：极低。Darwin 作用域 _STA=0，对 Windows/Linux 无影响；禁用对象均为空端口/无功能子设备。
 *
 * 写法参考 SSDT-thunderbolt-disable.dsl（10-09 审计版）：_STA 内显式 else 分支返回 0x0F。
 */

DefinitionBlock ("", "SSDT", 2, "OCLT", "noEMPxx", 0x00000000)
{
    External (_SB_.PCI0.PEG0, DeviceObj)
    External (_SB_.PCI0.RP17, DeviceObj)
    External (_SB_.PCI0.SBUS, DeviceObj)

    Scope (_SB.PCI0.PEG0)
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

    Scope (_SB.PCI0.RP17)
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

    Scope (_SB.PCI0.SBUS)
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
}
