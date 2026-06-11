# 内置麦克风结论（HP ZBook Power G7）

本机 **Windows 实查硬件** + **macOS 实测** 后的最终结论。后续**不必**再为内置麦更换 `layout-id` 或追加 ACPI 补丁。

最后更新：2026-06-12

---

## 定论（可直接引用）

| 项目 | 结论 |
|------|------|
| **内置麦克风** | **不支持**（Hackintosh / macOS 下无法使用） |
| **原因** | 内置麦为 **Intel SST / SoundWire 数字麦克风**，不经 Realtek ALC236 模拟通路；macOS **无** Intel SST 驱动 |
| **macOS 实测** | 系统设置 → 声音 → 输入 有「内置麦克风」，**输入电平始终无信号**（未插耳机、音量正常，对着麦说话电平不跳） |
| **AppleALC / layout** | 仅服务 **扬声器、3.5mm 耳机/线路**；**不能**修复内置数字麦 |
| **`SSDT-SNDW-off`** | 已验证**不能**使内置麦可用；保留与否只影响 SNDW 设备暴露，**以播放是否正常为准** |
| **可行输入** | **USB 麦**、**蓝牙麦**；**3.5mm 耳麦**走 ALC236 模拟通路，需正确 `layout-id`（见下文） |
| **耳机孔麦** | **`layout 55` 可用**：插 TRRS 耳麦、手动选 **「线路输入」** 有电平；**不会自动切换**输入设备 |

**停止排查内置麦**：勿再为**内置数字麦**轮换 layout 或追加 ACPI。耳机孔麦可单独调 layout。

---

## 1. 本机硬件（Windows 实查）

| 项目 | 值 |
|------|-----|
| 机型 | HP ZBook Power G7 Mobile Workstation |
| 主板 ACPI | `87EC` |
| CPU | Intel Core **i7-10750H**（6C/12T） |
| 内存 | **16 GB** |
| 核显 | Intel UHD Graphics |
| 独显 | NVIDIA **Quadro P620**（Hackintosh 下禁用：`-wegnoegpu`） |
| 有线 | Intel **I219-LM** |
| 无线/蓝牙 | Intel **AX201** + Intel BT（`8087:0026`） |
| 声卡 Codec | **Realtek ALC236**（`10EC:0236`，子系统 `103C880C`） |
| 触控板 | **ELAN073D**（I²C） |
| 存储 | **2× WD Blue SN570 1TB** |
| 雷电 | Intel **JHL7540**（`DEV_15E8`） |
| 内屏 | 1920×1080（WMI：`CMN1512`；外接可见 `PHL0929`） |

---

## 2. 音频拓扑（为何内置麦修不好）

### Windows 上的路径

```
Intel SST 控制器 (8086:06C8)
├── LINKTYPE_02 → Realtek ALC236 (10EC:0236)   ← 播放 / 3.5mm 孔（AppleALC 可驱动）
└── LINKTYPE_03 → Intel AE30 (SoundWire)       ← 内置麦克风阵列（数字麦）
```

本机 ACPI：**`HDAS.SNDW`**（4 条 MIPI-SDW 链路，`nhlt-version 1.8-0`），与上表一致。

### Hackintosh 能力边界

| 能力 | 状态 |
|------|------|
| 扬声器 / 3.5mm 耳机输出 | **可用**（ALC236 + AppleALC，`layout-id` **55**） |
| 内置麦克风 | **不支持** |
| 3.5mm 耳麦（线路输入） | **`layout 55` 已验证有电平**（需手动选「线路输入」）；输出可自动切耳机 |
| USB / 蓝牙麦克风 | **推荐**日常使用方案 |

---

## 3. macOS 验证记录

**日期**：2026-06-11（当前 EFI：`layout-id` 55 + `SSDT-SNDW-off.aml` 已加载，重启后）

| 检查项 | 结果 |
|--------|------|
| 系统设置 → 声音 → 输入 | 出现「内置麦克风」「线路输入」 |
| 选中内置麦克风，未插耳机 | 输入音量约 75%～80% |
| 对着内置麦说话 | **输入电平条无跳动** |
| 语音备忘录 / 录音 | **无有效输入**（与电平一致） |

**解读**：macOS 会列出「内置麦克风」（AppleHDA 按 layout 创建的输入端），但**数字麦硬件无驱动 → 无真实音频流**。这与 Windows 上「麦走 SoundWire」一致，**不是配置遗漏**。

---

## 4. 当前 EFI 策略

| 项 | 值 | 说明 |
|----|-----|------|
| `layout-id` | **`55`** | AppleALC：`ALC236 for HP-240G8`；播放 + **耳麦（线路输入）** 已验证 |
| `boot-args` | **`alctcsel=1`** **`alcverbs=1`** | 插孔检测；供 **MicFix** 等 combo jack 助手发 verb |
| `SSDT-SNDW-off.aml` | 已启用 | Darwin 下隐藏 `\_SB.PCI0.HDAS.SNDW`；**不解决**内置麦 |
| AppleALC | 已启用 | `EFI/oc/Kexts/AppleALC.kext` |
| 注入路径 | `PciRoot(0x0)/Pci(0x1F,0x3)` | HD Audio / ALC236 |

### 耳机孔麦 vs 内置麦

| 问题 | 通路 | 能否用 layout 修 |
|------|------|------------------|
| 内置麦克风无信号 | Intel SST / SoundWire | **不能** |
| 插耳麦有耳机声、线路输入无电平 | ALC236 combo jack 模拟麦 | **可以**（换 layout / `alctcsel`） |

### 自动切换输入设备

macOS 在真机上插耳麦会同时切 **输出 → 耳机**、**输入 → 外接麦**。Hackintosh 上 AppleALC 通常只做好 **输出自动切换**；**输入仍停在「内置麦克风」** 是常见现象，不是麦坏了。

| 方案 | 说明 |
|------|------|
| **手动** | 插耳麦后：**系统设置 → 声音 → 输入 → 线路输入** |
| **[MicFix](https://github.com/WingLim/MicFix)**（推荐） | 支持 **ALC236**；插拔耳麦时发 HDA verb。需 `alcverbs=1`（已加入 `boot-args`）。安装：`brew tap winglim/taps && brew install micfix && brew services start micfix` |
| **[ComboJack](https://github.com/macos86/ComboJack)** | 文档写明 **ALC236 layout 68**；插孔时弹窗选耳机类型。若 MicFix 无效可试 |

### layout-id 变更史（归档）

| layout-id | 结果 |
|-----------|------|
| **`55`** | **当前**：播放 + 耳麦（手动线路输入）✅ |
| `19`、`68` | 本机线路输入无电平 |
| `11`、`13` 等 | 内置数字麦仍无效 |

修改 `SSDT-SNDW-off.dsl` 后编译：

```bash
cd EFI/oc/ACPI && ./compile-ssdt.sh
```

---

## 5. 如何自行确认麦克风类型（他机参考）

1. **Windows 设备管理器**：内置麦是否在 **Intel Smart Sound / 数字麦克风** 下（而非仅 Realtek）。
2. **录制设备 → 属性 → 硬件 Id**：`INTELAUDIO\…` / `VEN_8086` → 数字通路；`VEN_10EC` → Realtek 模拟。
3. **Linux `codec#0` dump**：ALC236 上若无有效 **Internal Mic / IN pin**，但系统仍有麦 → 多为数字麦。
4. **本机 DSDT**：存在 **`HDAS.SNDW`** → 存在 SoundWire，与数字麦一致。

---

## 6. 相关文件

| 路径 | 用途 |
|------|------|
| `EFI/oc/config.plist` | `layout-id`、`ACPI → Add` |
| `EFI/oc/ACPI/SSDT-SNDW-off.dsl` | SNDW 补丁源码 |
| `EFI/oc/ACPI/compile-ssdt.sh` | 编译 SSDT（需 `iasl`） |
| `EFI/oc/SysReport/ACPI/DSDT.dsl` | 本机 ACPI（`HDAS` / `SNDW`） |
| `README.md` | 机型总览与已知限制 |

---

## 7. 一句话

**内置麦 = Intel 数字麦 → 不支持。耳机孔麦 = `layout 55` + 手动「线路输入」→ 有电平；自动切换输入需 MicFix 或手动。**
