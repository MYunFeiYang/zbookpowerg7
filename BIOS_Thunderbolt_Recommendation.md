# HP ZBook Power G7 — 黑苹果雷电 BIOS 推荐配置

> 适用场景：已切到 OpenCore `on` 档（force-power + DROM 注入，git `2ae4799`），想在 macOS 下启用 USB-C / 雷电。
> 这些值是「黑苹果社区共识 + HP 平台文档」推导的推荐，**不是 macOS 26 + 本机 JHL7540 的专门实测**，需重启后验证。

## 进 BIOS 路径
开机按 **F10** → **Advanced** → **Port Options** → 找到以下两项。

## 推荐值

| 项目 | 推荐值 | 理由 / 来源 |
|---|---|---|
| **Thunderbolt Security Level** | **No Security (SL0)** | 黑苹果社区硬共识：macOS 需 No Security 才能检测并初始化 TB 设备。Gigabyte/ASUS/elitemacx86 多源一致（"For most motherboards and Laptops, this option is preferred"）。HP ZBook 手册确认档位含 No Security / User Authorization(默认) / Secure Connect / DisplayPort only。 |
| **Thunderbolt PCIe Hot plug Mode** | **Legacy Mode (disables RTD3)** | HP 白皮书 + ZBook 14u G5 社区实证：设为 Legacy 禁用 RTD3 深度电源管理，可修复睡眠/唤醒后 TB 设备断连。正好对症我们担心的「睡眠带设备 panic / 唤醒冻结」。 |
| Wake from Thunderbolt Devices | **Disabled**（建议） | 避免 TB 设备随意唤醒导致不稳定。 |

## 关键澄清（纠正 18:0x 的旧措辞）
- HP BIOS 里**有两个独立项**，之前我把它们混了：
  1. **Thunderbolt Security Level** —— 档位是 `No Security / User Authorization / Secure Connect / DisplayPort only`，**没有叫 "Legacy" 的档**。
  2. **Thunderbolt PCIe Hot plug Mode** —— 档位是 `Native + Low Power / Legacy Mode`，**"Legacy" 是这一项的真实叫法**（不是 Security Level 的档）。
- 之前说的「改成 Legacy」指的就是第②项的 **Legacy Mode**，措辞让人误以为是第①项的档位名，已纠正。

## 为什么这两个要配合 on 档
- OpenCore 的 `SSDT-TB3HP-ZBook.aml`（force-power + DROM）在软件层强制上电、注入 DROM；
- BIOS `No Security` 让控制器在 macOS 下不被安全层卡住、能完整枚举；
- BIOS `Legacy Mode`（禁 RTD3）让睡眠/唤醒时 TB 控制器不被深度电源管理搞死。
- 三者方向一致，目的都是"让 JHL7540 在 macOS 下尽量完整初始化 + 睡眠稳"。

## 风险与边界（诚实标注）
- **No Security 降低物理 DMA 防护**（任何人物理接触 USB-C 口可 DMA 攻击）。黑苹果普遍接受此代价；若介意，至少在开机密码 + 物理看护下使用。
- 调 BIOS **不破坏系统密封**、不碰 EFI，可随时改回，比改 EFI 安全。
- 即便两项都设对，**无社区实证保证 macOS 26 + 本机 JHL7540 完美**——仍可能面对热插拔冻结 / 关闭卡 panic。设完务必实测。

## 重启后验证命令
```
system_profiler SPThunderboltDataType        # 看 Thunderbolt 树是否完整(应有 NHI/Port/LocalNode)
ioreg -n RP01                                 # 应存在 RP01 节点
ioreg -n AppleThunderboltNHIType3             # 看控制器状态
log show --predicate 'eventMessage CONTAINS "Thunderbolt"' --last boot   # 看 TB 初始化日志
```

## 回滚
- BIOS 改坏 → F10 里 Load Setup Defaults 或改回 User Authorization / Native + Low Power。
- EFI 想退回无 USB-C 稳态 → `bash EFI/scripts/tb-thunderbolt-profile.sh off`（回到藏 RP01 态）。

## 确定性分级（你问的「确定是我们这台吗」）

| 维度 | 确定 / 不确定 | 依据 |
|---|---|---|
| **机型归属**：HP ZBook Power G7 属该 BIOS 家族、该家族 BIOS 确有 Thunderbolt 配置项 | ✅ **确定** | HP 官方白皮书 + ZBook Studio/Fury/Firefly 同系手册 + 社区三源证实；本机真实机型由你自述 + SysReport 抓的本机固件表确认（⚠️ `system_profiler` 现在显示的 `MacBookPro16,4` 是 OC 伪装的 SMBIOS，**不能当真实机型证据**） |
| **菜单逐字路径**：`F10 → Advanced → Port Options → …` 的精确位置 / 选项拼写 | ❓ **不确定，需进 BIOS 眼见** | 我进不了 BIOS、也没 dump 本机 IFR 固件；当前路径 / 选项名是从 HP 通用文档 + 同系机型**推导**的，非从你实机读出。进 BIOS 时若名字 / 位置有出入，以实机为准 |
| **调了能否改善 macOS 26 下 JHL7540 半初始化** | ❓ **不确定，可能无用** | 18:0x 已自我纠正：HP Security Level 管的是设备认证 / DMA 防护（安全层），**无社区实证**证明它能让 JHL7540 在 macOS 26 完整初始化。属「可试但无把握」旋钮，优先级低于 on 档 EFI 实测 + 使用纪律 |

**一句话**：配置「适配这台机器家族」是确定的；「菜单逐字路径」与「调了有用」两点**无法从 macOS 侧坐实**，须你进 BIOS 实拍 + 重启实测 `system_profiler SPThunderboltDataType` 验证。
