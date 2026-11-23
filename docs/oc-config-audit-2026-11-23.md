# OpenCore config 死配置审计（2026-11-23）

## 1. 口径
一条配置判「死」必须满足：取值在本机当前状态下不可能产生任何作用，且有源码 / 文档原文 / 本机事实之一支撑。依赖未来状态（以后加回驱动、以后升版本）的一律只标注不删。跨 OS 生效的 booter/ACPI quirk 单独考虑。

## 2. 证据来源
| 来源 | 取法 | 用途 |
|---|---|---|
| `Docs/Configuration.tex` | upstream tag `1.0.8`，481558 B | 官方 333 个选项定义、Failsafe 基线 |
| `Docs/Sample.plist` | 同上，57956 B | 出厂值对照 |
| `Library/OcAppleKernelLib/CommonPatches.c` | 同上，88047 B | 版本门控分支 |
| `Docs/Configuration.tex`（master） | upstream master | 交叉核对 fork 专属键 |
| 本机 `nvram ...:opencore-version` | 只读 | `REL-109-2026-10-27 | MOD` |

**版本错配说明**：本机 OC 为 1.0.9 mod 构建，upstream 无 `1.0.9` tag（实测 404），审计基线取最近的正式 tag `1.0.8`。三个 fork 专属键另用 master 交叉核对，同样无此名 ⇒ 确认是 mod 二进制私有键，不能按官方 ocvalidate 报错删。

## 3. 全量比对结果
`oc_failsafe_diff.py` 解析到 333 个官方选项，本机 **61 条非出厂值**，逐条定性：

| 桶 | 数量 | 处置 |
|---|---|---|
| A 可证无效（与未来状态无关） | **0** | 无键可删 |
| B 条件当前为假 | 3 类 | 只标注不删 |
| C 平台必需 / 有意为之 | 其余 | 不删 |

### B 桶（当前无效但禁止删）
| 键 | 现值 | 为什么当前不起作用 |  why 不删 |
|---|---|---|---|
| `ACPI/Quirks/EnableForAll` | false | OC-Mod fork 私有键，官方文档无此名 | 删了会改变「是否向其他 OS 注入 ACPI」的行为；本机 mod 二进制认识它 |
| `Booter/Quirks/EnableForAll` | false | 同上 | 同上；跨 OS 生效 |
| `Misc/Boot/SkipCustomEntryCheck` | false | 同上；具体语义未知（<80%） | 本机 mod 二进制认识它，不编造解释 |
| `UEFI/Audio/AudioOutMask=1` + `MinimumAudibleGain=-55` | — | `AudioSupport=false` 且 `AudioDxe.efi` 文件在但未登记进 `UEFI/Drivers` 数组 ⇒ 音频后端未激活 | 依赖缺失后端，属「条件当前为假」；恢复办法是把 AudioDxe.efi 登记进 Drivers，不是删配置 |
| `Booter/Quirks/DiscardHibernateMap=true` | true | 本机已放弃 S4，无休眠映射可丢 | 跨 OS booter quirk，且依赖「未来若有休眠」状态，只标注 |

### 顺带查实的判据纠正
- OC 的 `Kernel/Add` 条目键名是 **`BundlePath`**，不是 `Path`。用 `Path` 过滤会全部返回空、误判「kext 未被引用」。本次已纠正。
- 官方 ocvalidate 对 OC-Mod 的 3 条 `No schema` 报错**不可当删键依据**；结论与 `docs/tooling-gotchas.md:342`、`docs/deepidle-power-audit-2026-11-12.md:388` 一致（>95%）。

## 4. 休眠实验残留核对
| 项 | 状态 |
|---|---|
| `Kernel/Patch` | 仅剩 AppleRTC 1 条；DeepIdle 写盘补丁已撤回（config sha `523e9b37`） |
| `kern.hibernatemode` / `kern.hibernatefile` | 0 / 空（重启后确认补丁失效） |
| pmset | `hibernatemode 3` + `standby 0` = 长期会话安全基线，无需回退 |
| NVRAM | 无休眠实验残留变量（boot-signature/boot-image 均 not found） |
| sleepimage | 8 GB（实验期由 1 GB 撑大），补丁撤后不再写，占盘但无害；磁盘余量 182 GiB |

## 5. 未跟踪文件（唯一实质待办）
11:49 外部改动新增 3 颗 kext，git 未跟踪，但**均已被当前 config 引用**：

| kext | BundlePath 状态 | MinKernel | MaxKernel | 本机 Darwin 25.6.0 是否加载 |
|---|---|---|---|---|
| `TGLDmic.kext` | ON | — | — | 加载 |
| `BTLEAdvFixup.kext` | ON | 21.0.0 | — | 加载 |
| `ForbiddenItlwm.kext` | ON | 25.0.0 | 25.99.99 | 加载（**升 Darwin 26 会被跳过，到时必复核**） |

风险：未进 git ⇒ 换机 / 重装 EFI 时这 3 颗会丢。

## 6. 变更记录
**本次审计未修改任何配置键**。config sha 保持 `523e9b37`（仓库 = ESP 逐字节一致），`plutil -lint` 通过。

---

## 7. 闲置资产清点（用户追问"不使用的配置，包括但不限于 kext"）

交叉比对 config 引用集 vs 物理文件集，并枚举所有 `Enabled=false` 条目。
结果：**config 引用但物理缺失 = 0**；**禁用条目 4 项**；**孤儿文件 8 项**。逐项定性如下。

### 7.1 禁用条目（config 里 Enabled=false，仍保留登记）
| 条目 | 状态 | 定性 | 依据 |
|---|---|---|---|
| `Kernel/Add[15] IntelBTPatcher.kext` | OFF (Min21) | **有意禁用，保留** | 11:49 外部改动把它关掉、换成 `BTLEAdvFixup`+`ForbiddenItlwm` 新栈；留着是回滚点 |
| `ACPI/Patch[5] RTC _CRS 0x08->0x02` | OFF | **禁止重开，保留标注** | Comment 原文："cannot fix 005; regresses S4. Do not re-enable." |
| `UEFI/Drivers[6] ext4_x64.efi` | OFF | 备用（无当前用途） | 10-22 为 Linux 选单加入，未启用 |
| `UEFI/Drivers[7] OpenLinuxBoot.efi` | OFF | 备用（无当前用途） | 同上，依赖 ext4_x64 |

### 7.2 孤儿文件（物理存在，config 未引用）
| 文件 | 定性 | 依据 |
|---|---|---|
| `Kexts/I219LTR.kext` | **实验残留，无长期价值** | deepidle audit §39f/§42：写 LTRV 无效，主假设证伪；§1388"保留作证据/回滚点，无害" |
| `Kexts/CStatePatch.kext` | **实验残留，建议优先清** | §1345 核心进 C7 但包级仍 C3；§1386"直接改内核 cstate 表，长期跑反有稳定性风险，更应撤" |
| `ACPI/SSDT-I219-LTR.aml` | **实验残留，无长期价值** | §1262 实测 `_INI` 写入未落地，确定失败 |
| `Kexts/AirportItlwm-Tahoe.kext` (2.4.0) | **被替代的旧 WiFi 栈** | 当前用 `ForbiddenItlwm.kext` (0.6.0)，二者 bundle id 不同、互斥；10-22 后不再登记 |
| `Kexts/IntelBTPatcher.kext` | 见 7.1（禁用但保留回滚点） | 物理文件与禁用条目是一回事 |
| `Drivers/AudioDxe.efi` | **备用后端，建议保留** | 文件在但未登记进 Drivers 数组；AudioSupport=false。恢复音频只需登记，删了要重新找 |
| `Drivers/ext4_x64.efi` / `Drivers/OpenLinuxBoot.efi` | 见 7.1（禁用条目的物理文件） | 一一对应 |

### 7.3 处置建议（未执行，待用户拍板）
- **可安全删（纯实验残留/被替代，删前留 git 可回滚）**：`I219LTR.kext`、`CStatePatch.kext`、`SSDT-I219-LTR.aml/.dsl`、`AirportItlwm-Tahoe.kext`。config 均已不引用，删除**零运行影响、不需重启**。CStatePatch 因涉及内核表改写，优先清。
- **建议保留**：`AudioDxe.efi`（音频备用后端）、禁用的 Linux 驱动一对（Linux 选单备用）、`IntelBTPatcher.kext`（BT 回滚点）。
- **勿动**：`RTC _CRS` 那条禁用 patch（注释明写禁止重开）。
- 所有待删文件均已在 git 历史中（除实验文件从未提交但早已按 §1388 决定留档），删除可随时从 git 恢复。

### 7.4 判据纠正
- `kextstat` / `ioreg -c IOKit` 在本环境无法列出已加载 kext 的 bundle id（无权限/过滤失效）⇒ 判断"是否在用"以 **config 的 Kernel/Add + 实测文档**为准，不靠这两个命令的空输出下结论。
- `Kernel/Add` 键名 = `BundlePath`（非 `Path`），前轮曾因用错键名误判 orphan，已纠正。
