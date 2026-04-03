# zbookpowerg7

**HP ZBook Power G7** 移动工作站的 **OpenCore** EFI（Hackintosh / 黑苹果）。适用于基于该机型的 **macOS** 安装与日常驱动；含 **ACPI SSDT**、**kext**、**config.plist** 与可选 **合盖关机** 脚本。

> **English:** OpenCore EFI for the **HP ZBook Power G7** mobile workstation — Hackintosh, macOS, Intel iGPU, `itlwm` Wi‑Fi, VoodooI2C trackpad, VirtualSMC, AppleALC. **NVIDIA dGPU not supported.** Sleep: **Deep Idle** + optional **lid shutdown**. **Thunderbolt** not fully tested.

## 关于本仓库

| 项目 | 说明 |
|------|------|
| **机型** | HP ZBook Power G7（移动工作站 / Mobile Workstation） |
| **引导** | OpenCore，EFI 位于 `EFI/oc/` |
| **验证盘** | 西数 WD Blue SN570（换盘请自测） |
| **睡眠策略** | 无 S3 → Deep Idle；可配合 `EFI/scripts/` 合盖关机 |
| **独显** | NVIDIA 在 macOS 下不可用（无驱动） |
| **雷电** | Thunderbolt 未完整测试 |

## 已验证可用的功能

在本机配置下，以下功能可正常使用（包括但不限于）：

- **核显**（Intel UHD）、外接显示器、亮度与亮度快捷键  
- **声卡**（AppleALC）、**有线网**（Intel）、**无线网**（`itlwm`）、**蓝牙**  
- **键盘**（PS2）、**内置触控板**（I²C + VoodooI2C 等）  
- **电池状态**、**SMC/传感器**（VirtualSMC 系）、**NVMe**（配合 `NVMeFix` 等）  
- **USB**、**读卡器**等常规外设（按实际机型与 ACPI 为准）  

> 本仓库在 **西数 SN570** 上验证；更换硬盘时请自行核对兼容性与引导。

## 仓库结构

| 路径 | 说明 |
|------|------|
| `EFI/oc/` | OpenCore：引导、驱动、kext、`config.plist`、ACPI（`.aml` / `.dsl` 源码） |
| `EFI/boot/` | 引导相关文件 |
| `EFI/SysReport/` | 机器 ACPI 导出（便于对照与调试） |
| `EFI/scripts/` | 合盖关机、`pmset` 降低唤醒等（与睡眠策略配合） |

将整棵 **`EFI`** 目录复制到 **EFI 系统分区** 根目录（与 `EFI/oc` 同级），按 OpenCore 常规方式使用。

## 不工作

1. **独显**（NVIDIA，macOS 无可用驱动）

## 睡眠与节能（当前方案）

- 本机**无法使用传统 S3 睡眠**，采用 **Deep Idle** 降低空闲功耗；待机仍可能有约 **5W** 级别功耗（视外设与设置而定）。  
- 与 **合盖关机** 配合使用：通过 `EFI/scripts/` 中的脚本实现合盖即关机，避免长时间合盖仍处于浅睡/空闲状态。按需安装，详见脚本内说明。

## 雷电（Thunderbolt）

**尚未在本配置下完整测试**；若后续验证电源或热插拔行为，再补充说明。

## 常见问题（FAQ）

**Q：这台机器用的是什么引导？**  
A：OpenCore；配置文件与驱动在 `EFI/oc/`，请将整个 `EFI` 复制到 ESP 分区根目录。

**Q：触控板、Wi‑Fi、蓝牙能正常用吗？**  
A：在本仓库验证配置下，内置触控板、无线（`itlwm`）与蓝牙可正常使用；具体依赖当前 kext 与 ACPI，升级系统后请自行回归测试。

**Q：为什么不能用独显？**  
A：NVIDIA 独显在较新 macOS 上无官方驱动，Hackintosh 场景通常仅使用 Intel 核显。

**Q：睡眠怎么配？**  
A：使用 Deep Idle；若希望合盖即关机，可使用 `EFI/scripts/` 内脚本按说明安装。

**Q：雷电和雷雳扩展坞能用吗？**  
A：当前未做完整测试，兼容性请自行验证。

---

*仅供学习与交流；请确保在合法授权的设备上使用。*
