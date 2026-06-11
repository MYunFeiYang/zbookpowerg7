# 内置麦克风排查备忘（HP ZBook Power G7）

在 **Windows** 上实查硬件 + 对照本仓库 EFI/ACPI 后的结论，供切换到 **macOS** 后继续排查时查阅。

最后更新：2026-06-11

---

## 1. 本机硬件（Windows 实查，可信）

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

## 2. 麦克风结论（主线）

### Windows 上的音频拓扑

```
Intel SST 控制器 (8086:06C8)
├── LINKTYPE_02 → Realtek ALC236 (10EC:0236)   ← 播放 / 耳机孔（AppleALC 可驱动）
└── LINKTYPE_03 → Intel AE30 (SoundWire)       ← 内置麦克风阵列（Intel 智音）
```

ACPI 中另有 **`HDAS.SNDW`**（4 条 MIPI-SDW 链路，`nhlt-version 1.8-0`），与 Windows 上 SST/SoundWire 路径一致。

### 判断

| 能力 | Hackintosh 预期 |
|------|-----------------|
| 扬声器 / 3.5mm 耳机 | **可用**（ALC236 + AppleALC） |
| **内置麦克风** | **大概率不可用**；无 Intel SST/SoundWire macOS 驱动 |
| `SSDT-SNDW-off` + 换 layout | **值得一试**，但若硬件无模拟麦回落，仍无效 |

**务实预期**：内置麦当作已知限制；长期方案为 USB 麦 / 耳机麦 / 蓝牙麦。

---

## 3. 当前 EFI 配置（本仓库）

| 项 | 值 | 说明 |
|----|-----|------|
| `layout-id` | **`55`** | AppleALC：`ALC236 for HP-240G8`（比 layout `13` 更贴 HP） |
| `SSDT-SNDW-off.aml` | **已加入 `config.plist` ACPI Add** | 在 Darwin 下隐藏 `\_SB.PCI0.HDAS.SNDW` |
| 源码 | `EFI/oc/ACPI/SSDT-SNDW-off.dsl` | 修改后需编译为 `.aml` 并放入 ESP `EFI/oc/ACPI/` |
| AppleALC | 已启用 | `EFI/oc/Kexts/AppleALC.kext` |

### layout-id 变更史（便于回滚）

| 日期/提交 | layout-id | 备注 |
|-----------|-----------|------|
| 早期 | `55` | HP ALC236 |
| `9731c9e` | `21` → 无效（ALC236 无此 layout） | |
| `9ccbb1d`「内置麦克风」 | `13` | Lenovo Air 13 Pro ALC236 |
| **当前** | **`55`** | 为 macOS 排查改回 HP layout |

### 部署到 ESP 前检查

```bash
# 在 macOS 或 Linux 上，于 EFI/oc/ACPI/ 目录：
./compile-ssdt.sh   # 或 iasl -ve SSDT-SNDW-off.dsl
```

确认 ESP 上存在：

- `EFI/oc/ACPI/SSDT-SNDW-off.aml`
- `EFI/oc/config.plist`（含 `layout-id` 55 与 SNDW SSDT 条目）

---

## 4. 切换到 macOS 后的排查清单

### 4.1 基础确认

- [ ] 扬声器/耳机是否有声（验证 AppleALC + layout 55 是否正常）
- [ ] **系统设置 → 声音 → 输入** 是否出现「内建麦克风」/ Internal Microphone
- [ ] 用 **语音备忘录** 或 **QuickTime → 新建音频录制** 试录，看电平是否跳动

### 4.2 终端采集（排查时保存输出）

```bash
# 音频设备总览
system_profiler SPAudioDataType

# 声卡 / HDA 相关（看 codec、layout 是否生效）
ioreg -l | grep -iE 'HDEF|IOHDACodec|AppleALC|layout|ALC236'

# 可选：OpenCore 是否加载 SSDT（需安装 acpidump 等工具时再用）
# ls /sys/firmware/acpi/tables/  # Linux 下查 SSDT 名
```

把 **`SPAudioDataType` 里 Input 整段** 贴回 issue/笔记，便于判断下一步。

### 4.3 若仍无内置麦

1. 确认 `SSDT-SNDW-off.aml` 已加载（改 DSL 后忘记编译是最常见失误）
2. 可再试 layout（成功率低，按需）：`18`、`54`、`68`（均为 AppleALC 内 ALC236）
3. 若无输入设备 → **停止折腾 layout**，改用外接麦

### 4.4 若扬声器也异常

- 先确认 `layout-id` 注入在 `PciRoot(0x0)/Pci(0x1F,0x3)`（HD Audio 控制器）
- 试回 `layout-id` **`13`** 或 **`3`** 对比播放是否正常（与麦问题分开测）

---

## 5. 相关文件索引

| 路径 | 用途 |
|------|------|
| `EFI/oc/config.plist` | `layout-id`、`ACPI → Add` |
| `EFI/oc/ACPI/SSDT-SNDW-off.dsl` | 禁用 SNDW（Darwin） |
| `EFI/oc/ACPI/compile-ssdt.sh` | 编译 SSDT |
| `EFI/oc/SysReport/ACPI/DSDT.dsl` | 本机 ACPI 导出（`HDAS`/`SNDW`/`TPD3`） |
| `README.md` | 机型总览 |

---

## 6. 一句话结论

**内置麦走 Intel SST/SoundWire，不是 ALC236 模拟输入；macOS 无对应驱动 → 大概率无法解决。当前策略：`layout-id 55` + `SSDT-SNDW-off`，在 macOS 上按第 4 节验证一次即可定论。**
