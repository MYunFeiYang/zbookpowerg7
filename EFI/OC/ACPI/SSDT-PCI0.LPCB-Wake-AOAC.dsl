/*
 * SSDT-PCI0.LPCB-Wake-AOAC  (HP ZBook Power G7 / hackintosh)
 *
 * 来源与演进：
 *   [2026-06-17] 原始件：_DSW（入睡时打开 AOAC 常电使能 AOEN）+ _PRW（声明唤醒源 GPE 0x6D）
 *                —— 只有"入睡那半"，缺"唤醒恢复那半"。
 *   [2026-10-09] 合并 OC-Little《01-关于AOAC/01-4-AOAC唤醒方法》的 _PS0/_PS3。
 *
 * 为什么加 _PS0/_PS3：
 *   OC-Little 原文（01-3-电源空闲管理）：SSDT-DeepIdle 可使机器进入深度空闲，
 *   "但同时也会导致唤醒机器比较困难"，解法见《AOAC唤醒方法》；
 *   且 "SSDT-DeepIdle 和 S3 睡眠可能有严重冲突，使用 SSDT-DeepIdle 应避免 S3 睡眠"。
 *   本机只上了 DeepIdle、未禁 S3，且唤醒侧缺 _PS0 —— 与原文点名的冲突组合一致。
 *   _PS0 里重放 \_WAK(0x03) 用于"重置唤醒状态"（点亮屏幕 + 更新电源数据）。
 *
 * 门控：_PS0/_PS3 只在 Darwin 下定义（沿用 OC-Little 原版写法），
 *       不影响 Windows 侧的 LPCB 电源状态机。
 */
DefinitionBlock ("", "SSDT", 2, "ACDT", "CLWAKE", 0x00001000)
{
    External (_SB_.PCI0.LPCB, DeviceObj)
    External (_WAK, MethodObj)          // DSDT 根作用域: Method (_WAK, 1, Serialized)

    Scope (_SB.PCI0.LPCB)
    {
        // ---- 原有：入睡侧 -------------------------------------------------
        Method (_DSW, 3, NotSerialized)  // _DSW: Device Sleep Wake
        {
            If (!_OSI ("Darwin"))
            {
                Return (Zero)
            }

            If ((Arg0 == 0x03))
            {
                OperationRegion (AOWR, SystemIO, 0x1800, 0x02)
                Field (AOWR, ByteAcc, NoLock, Preserve)
                {
                    AOAC,   8,
                    AOEN,   1
                }

                AOEN = Arg2
            }
        }

        Method (_PRW, 0, NotSerialized)  // _PRW: Power Resources for Wake
        {
            If (_OSI ("Darwin"))
            {
                Return (Package (0x02)
                {
                    0x6D,
                    0x04
                })
            }

            Return (Package (0x02)
            {
                Zero,
                Zero
            })
        }

        // ---- 新增：唤醒侧（OC-Little AOACWake）----------------------------
        If (_OSI ("Darwin"))
        {
            Method (_PS0, 0, Serialized)  // _PS0: Power State 0 (D0) -> 重置唤醒状态
            {
                \_WAK (0x03)
                // 如需定制"更新电源数据"，在此追加对应 Notify(***, 0x80) 方法
            }

            Method (_PS3, 0, Serialized)  // _PS3: Power State 3 (D3)
            {
            }
        }
    }
}
