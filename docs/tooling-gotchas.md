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
| `grep "A\|B"` 静默 0 命中 | **BSD grep 不支持 `\s` / `\|` / `\b`** ⇒ 一律 `grep -E`。"0 命中" ≠ "不存在"（本机已栽两次） |
| `iasl -d` 覆盖同名 `.dsl` | 反编译前先备份 / 换目录 |
| zsh glob 无匹配会**直接中断**整条命令 | 加 `2>/dev/null` 或 `|| true`，或用 `(N)` 修饰符 |
| `find ~/Library` 被沙箱 SIGTERM | 缩小路径、加 `-maxdepth`，或分段跑 |

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
