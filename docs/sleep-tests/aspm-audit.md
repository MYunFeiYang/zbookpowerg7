# ASPM 注入审计（HP ZBook Power G7 / macOS 26 Tahoe）

> 触发：用户问「ASPM 现在不是全被禁用了吗？」→ 追问「确定？」→ 逐路径实测复核。
> 方法：把 26 条已删注入路径 **逐条映射到 ioreg 实际设备**，再解每个设备的
> `IOPCIExpressLinkCapabilities` 的 **ASPM Support = bits[11:10]**（`0`=不支持 / `1`=L0s / `2`=L1 / `3`=L0s+L1）。

## 结论

- 被删的 26 条值**全是 `pci-aspm-default = 3`**（L0s+L1 全允许）。
- **23 / 26 天生无效**：15 条注在「ASPM 字段=0 的设备」上，8 条注在「不存在的设备」上。
- 真实受影响链路 **只有 3 条**：`Pci(0x1,0x0)`→PEG0、`Pci(0x1B,0x0)`→RP17、`Pci(0x1C,0x0)`→pci-bridge@1C。
- **"删注入" ≠ "禁用 ASPM"**：只是不再强制，回落到固件/OS 默认。

## 26 条注入逐条判定

| 注入路径 | 对应设备 | LinkCap ASPM | 判定 |
|---|---|---|---|
| `Pci(0x1,0x0)` | PEG0（独显桥） | L0s+L1 | **真受影响**（但桥后是已断电独显） |
| `Pci(0x1B,0x0)` | RP17（SSD 根口） | L1 | **真受影响** |
| `Pci(0x1C,0x0)` | pci-bridge@1C | L1 | **真受影响** |
| `Pci(0x0,0x0)` | 宿主桥 | 0 | 无效 |
| `Pci(0x12,0x0)` / `Pci(0x14,0x0/2/3)` / `Pci(0x15,0x0/1)` / `Pci(0x16,0x0)` | 热感/XHC/CNVi WiFi/I2C0/I2C1/IMEI | 0（PCH 内建或私有链路） | 无效 ×7 |
| `Pci(0x1F,0x0/3/4/5/6)` | LPCB/HDEF/SBUS/1F,5/GLAN | 0 | 无效 ×5 |
| `Pci(0x2,0x0)` / `Pci(0x4,0x0)` | IGPU / B0D4 | 0 | 无效 ×2 |
| `Pci(0x1C,0x0)/…` 深链 ×6 | 子设备不存在 | — | 无效 ×6 |
| `Pci(0x1D,0x0)`、`…/Pci(0x0,0x0)` | 0x1D 设备不存在 | — | 无效 ×2 |

## 全机真实 ASPM 链路（4 条）

| 设备 | ASPM 能力 | 曾被注入? |
|---|---|---|
| `PEG0`（独显桥） | L0s+L1 | 是（=3） |
| `RP17`（SSD 根口） | L1 | 是（=3） |
| `PXSX`（WD SN570 SSD） | L1 | **否**（SSD 省电走 NVMeFix APST） |
| `pci-bridge@1C` | L1 | 是（=3） |

## 现存 8 条 DeviceProperties 的「落地」实测

判据 = 属性名能否在 ioreg 反查到（指向不存在设备的条目不会出现）：

| 键 | 落地节点 | 判定 |
|---|---|---|
| `enable-l1-aspm` | XHC | 落地（但 XHC 无 PCIe 链路 ⇒ 装饰性） |
| `ps-max-latency-us` | **仅 `PXSX@0`（SSD）** | 落地 1 处 |
| `ps-max-latency-us` | `Pci(0x1D,0x0)/Pci(0x0,0x0)` | **惰性**（0x1D 不存在） |
| `built-in=1` | `Pci(0x1C,0x0)/Pci(0x0,0x0)` | **惰性**（1C 无子设备） |
| `ec-device`/`fan-count` | LPCB | 落地 |
| `layout-id`/`hda-gfx` | HDEF（实得 `alc-layout-id=55`、引擎 layout-id=7） | 落地 |
| `AAPL,ig-platform-id` 等 | IGPU | 落地 |

## 边界与待确认

- `ioreg` 只给 **Capabilities**，读不到 **Link Control**（当前开关）⇒ "现在开没开"命令行无法断言。
- 唯一实时判据：**Hackintool → PCIe 页 ASPM 列**。若 SSD 两跳显示 `Disabled`，则删除确实改了行为（非零变化），
  但那是**醒着空闲**项，**与睡眠掉电 11.2%/h 无关**（睡眠时链路已 D3 断开）。
- 回加风险：`7b0ab03`（2026-07-08）改 ASPM 后 1.5 h 因睡醒不稳回退 ⇒ 要加就逐设备加、加完测睡眠。
