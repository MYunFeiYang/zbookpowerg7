# HP ZBook Power G7 — 雷电 BIOS 配置（实机核验版）

> **2026-09-14 20:41 实机截图核验**：选项**确实存在**，位于 `F10 → Advanced → Thunderbolt Options`。
> ⚠️ **但本机下拉只有 SL1–SL4 四档，没有黑苹果唯一需要的 SL0（No Security）。**
>
> 适用场景：已切到 OpenCore `on` 档（force-power + DROM 注入，git `2ae4799`），想在 macOS 下启用 USB-C / 雷电。

## 实机菜单（2026-09-14 20:41 用户截图，本文件唯一权威依据）

`Main | Security | Advanced | UEFI Drivers` → **Advanced → Thunderbolt Options**：

| 控件 | 状态 |
|---|---|
| ☑ **Thunderbolt Mode** | 已勾选（= 启用 Type-C 口的雷电连接，正确） |
| ☑ **Require BIOS PW to change Thunderbolt Security Level** | 已勾选（= 改动安全等级需先设 BIOS 管理员密码，**实操障碍**） |
| **Thunderbolt Security Level** | 下拉展开，见下表 |

下拉可见项（自上而下）：
1. `PCIe and DisplayPort - User Authorization`
2. `PCIe and DisplayPort - Secure Connect`
3. `DisplayPort and USB`
4. `Daisy Chaining Disabled`

⚠️ **待确认**：下拉是否还能向上滚动（第 5 项 `No Security` 是否藏在列表上方）。截图看起来列表从第 1 项开始、到第 4 项结束，但需实机按 ↑/Home 键确认。

## 选项官方含义（HP 官方文档，非推断）

来源：HP 支持文档 `ish_12912068-12912121-16`、`ish_10066670-9875691-16`；HP 白皮书 `4AA7-3384ENW` / `4AA6-5088ENW`；ZBook Studio G5 BIOS 手册 `919946-004`。

| 截图选项 | HP 等级 | 官方含义（原文摘要） |
|---|---|---|
| `PCIe and DisplayPort - User Authorization` | **SL1** | **默认策略**。功能同 SL0，但需用户在 **Windows 环境**里通过 Thunderbolt 软件逐个批准新设备（批准后可记住 GUID 免提示） |
| `PCIe and DisplayPort - Secure Connect` | **SL2** | 需设备含安全证书/芯片；除批准外增加"预置密钥 + 挑战-响应"认证，验证不通过则接口不启用 |
| `DisplayPort and USB` | **SL3** | ⛔ **禁用全部雷电功能**（含 PCIe 隧道），仅保留原生 USB-C / DP-Alt 模式。HP 原文："All Thunderbolt functionality of the USB Type-C connectors on the notebook is disabled." |
| `Daisy Chaining Disabled` | **SL4** | 认证流程同 SL1，唯一区别是禁止从端口 B 菊花链 |

## ⛔ 危险项：绝对不要选 `DisplayPort and USB`（SL3）

它会把雷电 PCIe 功能**彻底关死**，比现在的"半初始化"**更糟**。选了之后 USB-C 只剩原生 USB/DP，雷电永无可能。

## 缺的那个档：SL0（No Security）

HP 官方对 SL0 的定义：**"Any Thunderbolt device attached is accessible without approval. No dialog boxes, prompts, or user interaction required."** —— 这是黑苹果社区唯一推荐的档（Gigabyte/ASUS/elitemacx86 多源一致），原因正是 **SL1/SL2 的授权客户端是 Windows 侧的 Intel Thunderbolt Software，macOS 没有这个客户端**，没人批准。

**关键不确定点**：本机下拉中 SL0 不可见。要么是 HP 在新版 BIOS 里移除了该档（有先例：HP Z6 G5 A 的用户反馈 BIOS 更新后 TB 安全设置直接消失），要么是列表可滚动。**须实机确认。**

## 实操注意：可能改不动

`Require BIOS PW to change Thunderbolt Security Level` 已勾选。HP 官方手册原文：*"When checked, Thunderbolt Security Level cannot be changed unless a BIOS administrator password has been created."*
→ 若改动被灰掉/无法保存，需先在 `Security → BIOS Administrator Password` 设一个密码。**本机是否已设未知。**

## 确定性分级

| 维度 | 结论 | 依据 |
|---|---|---|
| **选项存在性** | ✅ **确定存在**（此前"本机不可达"结论**已作废**） | 用户 20:41 实机截图 |
| **菜单路径** | ✅ **确定为 `Advanced → Thunderbolt Options`** | 同上。此前文档写的 `Port Options` 是旧版组织方式（HP 手册注："previously located in the Port Options menu. This menu organization is new in 2019"）→ 这正是 20:2x 没找到的原因 |
| **本机有无 SL0** | ❓ **待确认** | 截图下拉未见，需实机滚一下 |
| **调了能否改善 macOS 26 半初始化** | ❓ **不确定** | 无社区实证。且 20:23 实测已证明：补 ACPI 锚点后 `Switch` 仍 = 0。SL 档管的是**外部设备准入**，与**主机内部 root switch 建立**是否相关，**未经验证** |

## 结论：BIOS 变量尚未排除完

- **若有 SL0** → 设 `No Security` 是本机唯一还没试的、有理论依据的旋钮 → 值得重启验证一次
- **若无 SL0**（SL1 已是最宽松） → BIOS 变量**排除** → 结合 20:23 实测（`Switch` = 0 且 ACPI/ICM/kext 三层已到位），**雷电一线正式封板**
- **无论哪种**，都**不要**选 SL3 / SL2（更严，只会更糟）

## 重启后验证命令

```
ioreg -l -w0 | grep -oE "<class IOThunderbolt[A-Za-z_]+" | sort | uniq -c   # 权威实例计数（看 Switch）
ioreg -c IOThunderboltController -r                                          # LocalNode/Port 是否 registered
system_profiler SPThunderboltDataType                                        # macOS 26 此命令不可靠，仅参考
```

## 回滚

- BIOS 改坏 → F10 里 `Load Setup Defaults`，或改回 `User Authorization`
- EFI 想退回无 USB-C 稳态 → `bash EFI/scripts/tb-thunderbolt-profile.sh off`

---

## 变更史（保留纠错轨迹）

| 时间 | 结论 | 状态 |
|---|---|---|
| 2026-09-14 18:0x | 推荐 `No Security` + `PCIe Hot plug = Legacy`，路径写 `Advanced → Port Options` | ⚠️ 推导值，措辞混淆（把 Security Level 和 Hot plug Mode 混为一谈） |
| 2026-09-14 20:2x | 用户首次进 BIOS 未找到 → 判定"本机不可达"、雷电封板 | ❌ **此判定已作废** |
| 2026-09-14 20:41 | **用户实机找到**（`Advanced → Thunderbolt Options`）。真因：① 路径应为 Thunderbolt Options 非 Port Options ② 本机该项**不在 Port Options 下**。且**本机无 `PCIe Hot plug Mode` 项**（推荐表中那条也一并作废） | ✅ 现行 |
