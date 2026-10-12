/*
 * SSDT-DeepIdle — 电源空闲管理（Deep Idle）
 *
 * 三件套（与社区完整版一致，2026-10-09 由两件补为三件）：
 *   \_SB.LPS0        -> AppleACPIPlatform 据此置 IOPMDeepIdleSupported
 *   \_GPE.LXEN       -> 唤醒时允许 xnu 求值 _GPE.Lxx 方法
 *   \_TTS + \SLTP    -> AppleACPIPlatform 据此置 IOPMSystemSleepType
 *
 * 源头：
 *   https://pikeralpha.wordpress.com/2017/01/12/debugging-sleep-issues/
 *   hackintosh-stuff/XPS9350-macOS  DSDT-backup/SSDT-DeepIdle.dsl
 *   chinamdw/x1c6-hackintosh        patches/SSDT-Sleep.dsl
 *   OC-Little《01-关于AOAC/01-3-电源空闲管理》（仅含前两件）
 *
 * AppleACPIPlatform 二进制内明文引用：\_SB.LPS0 / \_GPE.LXEN / \_TTS /
 * IOPMDeepIdleSupported / IOPMSystemSleepType / "*** kIOPMSystemSleepTypeKey not found"
 *
 * 命名空间冲突核查（2026-10-09）：全部 60 张 ACPI 表中 _TTS=0、SLTP=0 ⇒ 可安全注入。
 * _TTS 仅在 Darwin 下写入 SLTP，Windows 侧为等价空操作。
 */
DefinitionBlock ("", "SSDT", 2, "OCLT", "IDLE", 0x00000000)
{
    Scope (_SB)
    {
        Method (LPS0, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
        }
    }

    Scope (_GPE)
    {
        Method (LXEN, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
        }
    }

    Scope (\)
    {
        Name (SLTP, Zero)

        Method (_TTS, 1, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                SLTP = Arg0
            }
        }
    }
}

