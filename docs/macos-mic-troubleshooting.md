# 内置麦克风结论（HP ZBook Power G7）

本机 **Windows 实查硬件** + **macOS 实测** 后的最终结论。后续**不必**再为内置麦更换 `layout-id` 或追加 ACPI 补丁。

最后更新：2026-06-11

---

## 定论（可直接引用）

| 项目 | 结论 |
|------|------|
| **内置麦克风** | **不支持**（Hackintosh / macOS 下无法使用） |
| **原因** | 内置麦为 **Intel SST / SoundWire 数字麦克风**，不经 Realtek ALC236 模拟通路；macOS **无** Intel SST 驱动 |
| **macOS 实测** | 系统设置 → 声音 → 输入 有「内置麦克风」，**输入电平始终无信号**（未插耳机、音量正常，对着麦说话电平不跳） |
| **AppleALC / layout** | 仅服务 **扬声器、3.5mm 耳机/线路**；**不能**修复内置数字麦 |
| **`SSDT-SNDW-off`** | 已验证**不能**使内置麦可用；保留与否只影响 SNDW 设备暴露，**以播放是否正常为准** |
| **可行输入** | **USB 麦**、**蓝牙麦**；**3.5mm 耳麦**可单独试「线路输入」（与内置麦无关） |

**停止排查**：勿再轮换 layout（11、13、19、55、68…），勿指望更多 ACPI 修好内置麦。

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
| 3.5mm 耳麦（线路输入） | **未在本仓库验证**；若需要输入，插耳麦后选「线路输入」单独试 |
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

## 4. 当前 EFI 策略（播放为主）

| 项 | 值 | 说明 |
|----|-----|------|
| `layout-id` | **`55`** | AppleALC：`ALC236 for HP-240G8`；服务 **播放/耳机孔**，非内置数字麦 |
| `SSDT-SNDW-off.aml` | 已启用 | Darwin 下隐藏 `\_SB.PCI0.HDAS.SNDW`；**不解决**内置麦 |
| AppleALC | 已启用 | `EFI/oc/Kexts/AppleALC.kext` |
| 注入路径 | `PciRoot(0x0)/Pci(0x1F,0x3)` | HD Audio / ALC236 |

### layout-id 变更史（归档，勿再为内置麦改动）

| 提交/阶段 | layout-id | 结果 |
|-----------|-----------|------|
| 早期 | `55` | 播放可用 |
| `9731c9e` | `21` | 无效（ALC236 无此 layout） |
| `9ccbb1d` | `13` | 内置麦仍无效 |
| 排查中 | `11`、`19` 等 | 内置麦仍无效 |
| **当前** | **`55`** | 播放策略；内置麦**已定论不支持** |

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

**内置麦 = Intel SST/SoundWire 数字麦；macOS 无驱动；2026-06-11 实测输入电平无信号 → 不支持。EFI 保持 `layout-id 55` 管播放即可；需要麦克风请用 USB/蓝牙麦，或插 3.5mm 耳麦试「线路输入」。**
