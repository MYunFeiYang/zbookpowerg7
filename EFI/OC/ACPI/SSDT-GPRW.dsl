/*
 * SSDT-GPRW — 让 GPE 0x6D 在 Darwin 下不再作为睡眠唤醒源
 *
 * 必须配合 config.plist 的 ACPI/Patch 使用：
 *     Find    : 47 50 52 57 02   ("GPRW" + 参数个数 2)
 *     Replace : 58 50 52 57 02   ("XPRW" + 参数个数 2)
 * 该补丁把 DSDT 里的 GPRW 方法改名为 XPRW，本表接管 GPRW 这个名字。
 *
 * 背景：本机 GPE 0x6D 是共享唤醒线，原厂四处调用 GPRW(0x6D, 0x04)：
 *     GLAN (DSDT 12102) / XDCI (12718) / HDAS (12812) / CNVW (26371)
 * 返回 {0x6D, Zero} 表示"只能从 S0 唤醒"，macOS 因此不会把 GPE 0x6D
 * 注册为睡眠唤醒源，S0ix 下 USB/WiFi/音频事件不再把整机拉起来。
 *
 * 其他 GPE（例如 48 处 GPRW(0x69, 0x04) 的雷电 root port）以及
 * 非 Darwin 系统，全部原样转发给 XPRW，行为不变。
 */

DefinitionBlock ("", "SSDT", 2, "OCLT", "GPRW", 0x00000000)
{
    External (XPRW, MethodObj)

    Method (GPRW, 2, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            If ((Arg0 == 0x6D))
            {
                Return (Package (0x02)
                {
                    0x6D,
                    Zero
                })
            }
        }

        Return (XPRW (Arg0, Arg1))
    }
}
