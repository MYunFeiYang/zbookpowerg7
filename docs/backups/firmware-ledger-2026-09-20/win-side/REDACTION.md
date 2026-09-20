# 本目录已脱敏（真相机身份字段已遮蔽）

本目录是 **2026-09-20** Windows 侧只读取证的原始产物回传。因为本工作区**会同步到一个公开的 GitHub 仓库**，
落盘后已把与睡眠结论**无关**的真机身份字段统一替换为占位符。

| 文件 | 原始字段 | 原值 → 现值 |
|---|---|---|
| `HPBIOS-all.csv`（第 209 行） | `Serial Number` | `5CD…77` → `<REDACTED-SERIAL>` |
| `HPBIOS-all.csv`（第 224 行） | `System Board CT Number` | `PKY…6V` → `<REDACTED-BOARD-CT>` |
| `HPBIOS-all.csv`（第 240 行） | `Universally Unique Identifier (UUID)` | `<REDACTED-UUID>` |
| `HPBIOS-all.csv`（第 249 行） | `UUID (standard format)` | `<REDACTED-UUID>` |
| `HPBIOS-all.csv`（第 81/83 行） | 引导路径里的 `NVMe(0x1,…)` / `GPT,…` | `<REDACTED-NVME-EUI>` / `<REDACTED-GPT-GUID>` |
| `SUMMARY.md`（第 218/222 行） | 同上序列号 / 主板序列号 | 同上 |

**脱敏没有删任何行**，`Name` / `DisplayInUI` / `IsReadOnly` / `RequiresPhysicalPresence` 列**原样保留** ——
本批产物要支撑的两条结论（① 258 项全表里**不存在** `Deep Sleep` / `S3` / `AOAC`；② `Modern Standby` = `Enable` +
`DisplayInUI=0` + `IsReadOnly=1`）**不受影响**。

**未脱敏的内容**：BIOS 版本（`T75 Ver. 01.24.02`）、EC 版本（`34.31.00`）、机型 / SKU、`Modern Standby` 等设置项本身 ——
这些都是本次取证的**目标证据**，必须保留。

> 本目录下的 CSV 是把取证脚本的临时产物 `C:\HPBIOS-all.csv` 拷过来的；**未脱敏的原件只存在于那台 Windows 机的系统盘上，从未进入本仓库的 git 历史。**
> 下次再跑这份提示词时，脱敏步骤已写进 `docs/windows-side-workbuddy-prompt.md`（「落盘后必做」一节），会在采集端就处理好。
