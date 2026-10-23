/*
 * SSDT-thunderbolt-disable  (OEM Table ID: "noRPxx")
 *
 * 作用：仅在 macOS (Darwin) 下把 _SB.PCI0.RP01 的 _STA 置 0，使该 PCIe 根端口不被枚举，
 *       挂在它下面的 Thunderbolt NHI 控制器随之消失（规避 IOThunderboltFamily 空指针 panic）。
 *       Windows / Linux 下 _OSI("Darwin") 为假 ⇒ 显式返回 0x0F，
 *       行为与「DSDT 原本未定义 _STA」完全一致（存在 + 启用 + 可见 + 正常）。
 *
 * 历史：
 *   08-24  f76a982  首次加入。写法有缺陷：把「非 Darwin 还原逻辑」写成了 module-level
 *                   If(!Arg2 || !_OSI("Darwin")){Return(...)}，依赖「中止该 scope 剩余模块级
 *                   代码」这一未定义行为 —— ACPI 规范并不保证，属于歪打正着。
 *   10-09  审计（docs/acpi-darwin-gating-audit-2026-10-09.md §三/§四/§五）用 acpiexec 复现后
 *                   改成 _STA 内的显式 else 分支（AML 184B -> 164B，sha ca539c04…），
 *                   工作区与 ESP 双侧落盘。
 *   10-19  db40819  回退 EFI 到 09-18 基线（git checkout 7f5df6b -- EFI/），该修正被一并
 *                   冲掉，AML 退回 184B / df0fad04…，备份目录 docs/backups/tb-sta-fix-* 也已不存在。
 *   10-23  本次重做：按 10-09 方案重建。相对旧版只有两处差异 —— 删掉 module-level 段落、
 *                   _STA 补 Return (0x0F)。Darwin 分支一字未改，对 macOS 无行为变化。
 *
 * 验证（acpiexec，_OSI("Darwin") 默认 false ≡ Windows 语义）：
 *   修正版 非 Darwin ⇒ \_SB.PCI0.RP01._STA = 0x0F
 *   修正版 Darwin    ⇒ \_SB.PCI0.RP01._STA = 0x00
 *   旧  版 非 Darwin ⇒ AE_NOT_FOUND（module-level Return 中止，_STA 根本没被创建，
 *                     等价于本表不存在；这是「Windows 不受影响」的唯一原因，属未定义行为）
 */

DefinitionBlock ("", "SSDT", 2, "OCLT", "noRPxx", 0x00000000)
{
    External (_SB_.PCI0.RP01, DeviceObj)

    Scope (_SB.PCI0.RP01)
    {
        OperationRegion (DE01, PCI_Config, 0x50, One)
        Field (DE01, AnyAcc, NoLock, Preserve)
        {
                ,   4,
            DDDD,   1
        }

        Method (_STA, 0, Serialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }

            Return (0x0F)
        }
    }

    Scope (\)
    {
        If (_OSI ("Darwin"))
        {
            \_SB.PCI0.RP01.DDDD = One
        }
    }
}
