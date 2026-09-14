# HP ZBook Power G7 — 雷电 BIOS 配置（实机核验版）

> **2026-09-14 20:41 实机截图核验**：选项**确实存在**，位于 `F10 → Advanced → Thunderbolt Options`。
> ⚠️ **但本机下拉只有 SL1–SL4 四档，没有黑苹果社区点名的 SL0（No Security）。**
> ✅ 2026-09-14 20:43 用户二次确认：列表就是这四档，滚不出第 5 项。
> 🔄 2026-09-14 20:5x **社区查证后修正**：SL0 缺失 **不等于** 无解 —— 社区有"Windows warm up"替代路径，详见文末「结论（修正）」。**BIOS 无需任何改动。**
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

✅ **已确认（2026-09-14 20:43 用户二次确认）**：列表就是这四档，滚不出第 5 项。本机 BIOS **不提供 SL0（No Security）**。

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

**已确认（20:43）**：本机下拉中**确实没有 SL0**。HP 在新版 BIOS / 合规要求下移除了该档（有先例：HP Z6 G5 A 用户反馈 BIOS 更新后 TB 安全设置直接消失）。**本机可选的最宽松档 = SL1 `User Authorization`，也就是当前默认值 —— 不需要改动任何设置。**

## 实操注意：可能改不动

`Require BIOS PW to change Thunderbolt Security Level` 已勾选。HP 官方手册原文：*"When checked, Thunderbolt Security Level cannot be changed unless a BIOS administrator password has been created."*
→ 若改动被灰掉/无法保存，需先在 `Security → BIOS Administrator Password` 设一个密码。**本机是否已设未知。**

## 确定性分级

| 维度 | 结论 | 依据 |
|---|---|---|
| **选项存在性** | ✅ **确定存在**（此前"本机不可达"结论**已作废**） | 用户 20:41 实机截图 |
| **菜单路径** | ✅ **确定为 `Advanced → Thunderbolt Options`** | 同上。此前文档写的 `Port Options` 是旧版组织方式（HP 手册注："previously located in the Port Options menu. This menu organization is new in 2019"）→ 这正是 20:2x 没找到的原因 |
| **本机有无 SL0** | ✅ **确定没有**（20:43 二次确认，下拉到底） | 用户实机核验 |
| **本机最宽松可选档** | ✅ **SL1 `User Authorization`（= 出厂默认，无需改动）** | HP 官方档位表 + 实机 |
| **改 BIOS 能否改善 macOS 26 半初始化** | ❌ **已无档可调** | 无更宽松档可选；SL 档管的是**外部设备准入**，与**主机内部 root switch 建立**的关系亦未验证 |

## 结论（2026-09-14 20:5x 社区查证后**修正**）

**上一版（20:43）结论"BIOS 无更宽松档 → 变量排除 → 雷电封板"作废。** 那个推理**只基于 HP 官方 BIOS 文档，没查黑苹果社区实证**。查证后结论如下。

### 实证 1（最关键）：症状一字不差的案例 + 解法
tonymacx86 论坛（Mojave + GC-Titan Ridge）用户报告：系统信息里 Thunderbolt 显示 **"no driver loaded"**、PCI 区什么都没有 —— **与我们 `Thunderbolt/USB4: No drivers are loaded.` 完全同一个症状**。

社区给的解法是 **"Windows warm up"**（原文）：
> "you need to **install Windows, load the drivers, update the firmware and then go back to Mojave** and you should see it. **Windows warm up is only required once for 'activation'.**"
> "**plug in a TB3 device to 'wake up' the card in Windows** ... I honestly think this is a **critical step** & many people don't test TB under Windows before switching over to macOS. ... you should see a new Windows dialog box that will ask you **if you want to approve the connection for the newly discovered TB device**. Make sure to connect & then accept this choice."

**含义**：SL1 的"用户授权"可以**在 Windows 侧完成一次**，授权信息（设备 GUID + 密钥）写入**雷电控制器 NVM**；之后进 macOS，控制器以"已授权"状态启动。**这就是没有 SL0 时的替代路径** —— 也解释了为什么有些机器不设 No Security 也能用。

### 实证 2：HP 同代商务本在 macOS 下 TB3 可用
`kecinzer/hpelitebook850g5-opencore`（**HP EliteBook 850 G5**，i5-8350U，macOS 11 Big Sur）明确列出：
- 使用 **i-tec TB3 坞站（JHL7440 芯片）+ TB3→双 DP 适配器**，"connects to my laptop only over TB3 port that also powers it"
- BIOS 只写了一条 TB 相关设置：**`Thunderbolt PCIe Hot plug Mode = Native + Power saving`**，**全文未提 Security Level**
→ **"没有 No Security" 不必然是致命伤**（但注意：该机 BIOS 比我们多一个 `PCIe Hot plug Mode` 选项，本机没有）。

### 实证 3：SL0 的厂商别名对照（elitemacx86 权威指南）
> "For some motherboards, you may not have option of 'No Security' in such case, **use this option [Legacy Mode] which is similar to 'No Security'**."

| Intel 等级 | 常见 BIOS 叫法 |
|---|---|
| SL0 | `No Security` / **`Legacy Mode`** / `Normal Mode w/o NHI` |
| SL1 | `Unique ID` / `User Authorization` |
| SL2 | `One time saved key` / `Secure Connect` |
| SL3 | `DP++ only` / `DisplayPort and USB` |
| SL4 | `Daisy Chaining Disabled` |

**HP 这套四档里确实没有 SL0 的对应物**（这点上一版没说错），但 HP 体系里也**没有** `Legacy Mode` 可选。

### 实证 4：Titan Ridge 的 NVM 固件版本是变量（AIC 插卡领域）
- imacpc.net 中文教程：Titan Ridge 卡出厂 `nvm43`，**降级到 `nvm23` + 配 SSDT** 才能让 macOS 完整识别
- `liuxu623/ASUS-X299-Hackintosh`：Titan Ridge 需 `SSDT-TB3HP.aml` + `SSDT-DTPG.aml`，BIOS 设 `Security Level = SL0-No Security`、`GPIO3 Force Pwr = On`、`Skip PCI OptionRom = Enabled`
⚠️ 这些全是 **AIC 插卡**的操作。本机是 **onboard 焊死** 的 JHL7540 —— 刷 NVM 风险极高，**不建议**。

---

## 修正后的可选路径

| 路径 | 可行性 | 成本 / 风险 |
|---|---|---|
| **A. Windows warm up**：进 Windows 装 TB 驱动 → 插 TB3 设备 → 弹窗批准授权 → 重启回 macOS | ⭐ **社区对同症状的推荐解法**；本机双系统具备条件 | 需重启进 Windows；**前提是有真实 TB3 设备**；macOS 26 无先例，成功率未验证 |
| B. BIOS 设 SL0 | ❌ 本机无此档 | — |
| C. 刷雷电控制器 NVM 固件 | ⚠️ 理论可行（NVM 版本确会影响识别） | onboard 焊死，**变砖风险极高**，不建议 |
| D. 外接真实雷电设备硬试 | ⚠️ 可能逼出 Switch | panic 风险 |

**BIOS 不需要改任何设置** —— 保持默认 `User Authorization` 即可。
⛔ 仍**不要**选 SL2 / SL3 / SL4（SL2/SL4 更严，SL3 直接禁死雷电功能）。

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
| 2026-09-14 20:43 | 用户二次确认：下拉**只有 SL1–SL4，无 SL0** → 当时判定"BIOS 变量排除，雷电封板" | ❌ **已被下一行修正** |
| 2026-09-14 20:5x | **社区查证后修正**：① tonymacx86 有"**no driver loaded**"同症状案例，解法=**Windows warm up**（Windows 侧授权一次写入控制器 NVM）② HP EliteBook 850 G5（同代）在 Big Sur 下 TB3 坞站可用且未设 No Security ③ elitemacx86 确认 SL0 无 HP 别名。→ **"无 SL0 = 无解"不成立**，存在 Windows warm up 路径 | ✅ 现行（终版） |
