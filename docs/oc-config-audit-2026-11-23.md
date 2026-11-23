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
