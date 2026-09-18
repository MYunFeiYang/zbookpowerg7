# macOS / 黑苹果 工具坑速查（zbookpowerg7 实测沉淀）

> 出处：从 `.workbuddy/memory/MEMORY.md` **外置**（该文件每轮被整篇注入、有长度上限）。
> 用途：**动手跑命令前先扫一眼**，避免重复踩坑。每条都是"现象 → 正确做法"。

## 日志 / 进程 / 内核
| 坑 | 正确做法 |
|---|---|
| `log show` 在沙箱里被硬禁 | 用 `osascript … with administrator privileges` 提权跑 |
| 全窗口 `log show` 扫描被 **SIGKILL(137)**（不是超时） | 必须加 `--predicate` + 缩小 `--start/--end` 窗口 |
| `log show --start/--end` 查**旧**窗口不可靠（时间戳错乱） | 旧窗口的结论必须复核实际时间戳再采信 |
| `dmesg` 读不到启动期（环缓冲被 IGPU 刷爆） | 改看 `log show --predicate 'process == "kernel"'` 或 panic 报告 |
| `ps` / `top` 连 root 也 `Operation not permitted`（本机限制） | 改用 `pgrep -fl`、`launchctl list`、`ioreg` |

## ioreg / kext
| 坑 | 正确做法 |
|---|---|
| 用 `ioreg -c <类名>` 判断 kext 是否生效 —— **hook-only kext 没有自己的节点，会给相反结论** | ★ **看实例计数**：`ioreg -d 0 -l -w0` 里的 `IOKitDiagnostics → Classes` |
| `ioreg -p IOACPIPlane` / `-p IOPCIDevice` 返回 0 行 | **路不通 ≠ 对象不存在**。查 PCI 用 `-c IOPCIDevice -t`；**PCI 地址 → ACPI 名用设备属性 `"acpi-path"` 反查**（不需要 Hackintool） |

## 磁盘 / 空间
| 坑 | 正确做法 |
|---|---|
| `df /` 看起来"空间没释放" | APFS 上 `df /` 读的是**只读系统卷**；用户数据在 **`/System/Volumes/Data`**。**"是否真删掉"只认「路径不存在」** |
| `/var/vm` 是空的，以为没有 sleepimage/swap | **`sleepimage` / `swapfile*` 实际在 `/System/Volumes/VM`**，`/var/vm` 空是**假象** |
| `diskutil mount <卷>` 裸跑报 `failed to mount … try "readOnly"` | **必须提权**；卸载任何工作盘前先确认能挂回 |

## grep / shell
| 坑 | 正确做法 |
|---|---|
| `grep "A\|B"` 静默 0 命中 | **BSD grep 不支持 `\s` / `\|` / `\b`** ⇒ 一律 `grep -E`。"0 命中" ≠ "不存在"（本机已栽**三次**，2026-09-18 又栽一次） |
| `iasl -d` 覆盖同名 `.dsl` | 反编译前先备份 / 换目录 |
| zsh glob 无匹配会**直接中断**整条命令 | 加 `2>/dev/null` 或 `|| true`，或用 `(N)` 修饰符 |
| `find ~/Library` 被沙箱 SIGTERM | 缩小路径、加 `-maxdepth`，或分段跑 |

## 固件包 / 二进制字符串检索（2026-09-18 新增，离线拆 HP BIOS 包时沉淀）
| 坑 | 正确做法 |
|---|---|
| 拿 `zipfile` 开 HP 的 BIOS SoftPaq（`sp*.exe`）→ `File is not a zip file` | 它是 **PE32 + 尾部 overlay 内嵌 MSCF CAB**。**不要用 exe 头判断格式**，直接找 `MSCF` |
| 找到的第一个 `MSCF` 就当 CAB 头 → 字段全乱（versionMinor=110 / cFolders=101） | **必须校验头部字段**：`versionMajor ∈ {1,2,3}` 且 `1 ≤ cFolders ≤ 32` 且 `cbCabinet < 文件长`。本机真 CAB 在 **第二个** `MSCF`（@331,559 vs 巧合的 @216,064） |
| 以为要装 `7z` / `cabextract` | **macOS 自带 `bsdtar`（libarchive）就能解 CAB**：`bsdtar -xf <cab>`。前提是偏移正确 |
| 用 ASCII 字节串搜"明明存在"的字符串 → 0 命中 | UEFI / Setup 的名字多为 **UCS-2（UTF-16LE）**。用 `re.escape("名".encode("utf-16-le"))` 重搜。⚠️ macOS `strings` **没有 `-e`**（不支持 UTF-16），要自己写扫描 |
| 裸扫固件镜像找设置项名 → 大批 0 命中 | 镜像**大部分模块是压缩的**（裸扫只覆盖未压缩区）。**必须先跑正向对照**（搜一个 UI 上确凿有的项名）；**对照不中 ⇒ 只能把"搜到"当证据，绝不能把"没搜到"当"不存在"** |
| `uefi_firmware`（pip）解 HP BIOS 镜像 → `type() -> unknown` | HP 是**自研多组件容器**（EC/GOP/ME/TB/PD 各一份），非标准 FV 顶层。需先手工定位 `_FVH` 再逐个解（本机镜像里有 **34** 个） |
| 用 `curl -I` 猜一个文件在不在 | 看 `Content-Length`；HP 的 404 会返回 `Content-Length: 10`（很小）⇒ 可据此判存在性 |

## Windows 侧（跨分区取证）
| 坑 | 正确做法 |
|---|---|
| `config/SYSTEM` → `No such file`（曾据此误判"读注册表此路不通"） | ⚠️ **hive 文件名是小写**：`system` / `software` / `sam` / `security` / `default` |
| 怎么读 hive 内容 | `strings -a` / `grep -a -c` 做**字节级键名检索**；但**必须先跑正向对照**（同 hive 内找一个必定存在的键名，如 `HiberbootEnabled`）再采信"0 命中" |

## ACPI 偏移速查
- FADT：`FLAGS` @ **0x70 (112)**｜`PM1a_EVT_BLK` @ **0x38**（⚠️ 0x24 是 `FIRMWARE_CTRL`）｜`GPE0_BLK` @ **0x50**
- 本机 `FACP-1.aml` `FLAGS = 0x002384A5`：`RTC_S4`=1、**AOAC(bit21)=1**、`HW_REDUCED_ACPI`(bit20)=0
- 全部 ACPI 表 `OEM ID = HPQOEM`、`Creator = INTL` —— **判不出底层固件厂商**（Insyde / AMI），别拿它当判据

## 权限
- 本机 `sudo` **无免密** ⇒ 需要提权的命令一律走 `osascript … with administrator privileges`（**间歇失败，需重试**）
- `mdutil` / `pmset -g log` / `powermetrics` / `diskutil mount` 都需要提权
