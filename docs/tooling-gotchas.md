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

## 固件卷解包 / IFR 判定（2026-09-18 追加）
| 坑 | 正确做法 |
|---|---|
| `pip install uefi_firmware` 解 HP 镜像只能看到一层（FFS 里嵌的 FV image 不递归） | 用 **UEFITool NE 的 `UEFIExtract`**：`https://github.com/LongSoft/UEFITool/releases` 有 **`UEFIExtract_NE_A*_universal_mac.zip`**（macOS 通用二进制，零依赖）。解压后 `xattr -dr com.apple.quarantine .` + `chmod +x` 即可跑 |
| `UEFIExtract <img> report` 好像没输出文件 | 报告写在**输入文件同目录**：`<img>.report.txt`（不是 stdout，也不是 cwd） |
| `UEFIExtract <img> <GUID> -o out` 报 `failed with 34 code!` | 该 GUID 在**压缩段内**时单模块导出会失败。改用全量 `UEFIExtract <img> all`（生成 `<img>.dump/`，按 GUID 分层，含解压后内容） |
| 在**未解包**镜像里搜 UI 字符串 → 0 命中 | UI 文本在**压缩段**内 ⇒ **必须先 `all` 解包再搜**。本机实测：未解包搜 `Modern Standby` = 0；解包后 = 9 个文件 |
| 用启发式"opcode 走链"判定 IFR → 报出"首 op = `0x24`(VARSTORE)" | **假阳性**。回读落点字节发现是 `f3 a5`(rep movsd)/`c3`(ret)/`cc`(int3) = **x86 机器码**（0x24 + 合理长度在代码里太常见）。**凡走链类启发式，必须回读落点字节交叉验证** |
| 想判定"这份固件到底有没有 IFR" | 用**三条独立的硬判据**：① `UEFIExtract report` 里 **HII section 计数**；② 全 dump 搜 **`EFI_HII_PACKAGE_END` 指纹 `06 00 00 00 DF 00`**；③ 严格 HII 包链扫描（≥3 包且以 `0xDF` 收尾）。本机三条全 0 ⇒ **无 IFR**（HP 自研 Setup 引擎） |
| 看到 `HII_DATABASE_PROTOCOL` GUID 就以为"有 HII/IFR" | **协议 GUID 存在 ≠ 有 HII 包**。厂商常保留 EDK2 框架代码但 Setup 不走它。必须用上面 ② 的指纹实测 |
| 想区分"UI 字符串包"与"代码里的宽字符串常量池" | 看**相邻性**：HII STRINGS 包的字符串前有 **SIBT 块头**（`0x10` = SIBT_STRING_UCS2）且总长含 ID；常量池里两个字符串**字节紧邻**（如 `Runtime Power Management` 50 B 后直接是 `Enables Runtime Power Management.`）⇒ **无 SIBT 结构 = 纯常量池** |
| 把固件里扫出的字符串当"证据"前 | 先跑**正向对照锚点**：挑一个**在界面上亲眼见过**的项名。本机锚点 = BIOS 实拍图里的 `Runtime Power Management` / `Extended Idle Power States` / `Power Management Options` / `Power On When AC Detected` |
| **`UEFIFind <原始ROM> all list <串>` 全部 0 命中**（2026-09-20） | ⚠️ **假空**。`UEFIFind` 只搜**未压缩**内容；本机 HpSetup 在 **LZMA 压缩段**内 ⇒ 连 `HpSetup`、`"Modern Standby"` 都是空。**必须对 `UEFIExtract … all` 产出的 dump 检索**。今天靠"先跑正向对照"才发现——又一次验证：**0 命中必须配对照才作数** |
| 在 302 MB / 15,718 文件的 dump 上跑 Python 全量 `os.walk` + 读文件搜串 | **被 `SIGKILL`（exit 137）**，两次都是死在扫描循环里。省力替代：① 按 **`info.txt` 反查 GUID** 直接定位模块目录 —— `grep -r "<模块GUID>" --include=info.txt <dump>`（每个模块目录都有 `info.txt`，含 `File GUID`/`Type`/`Full size`，纯文本、毫秒级）；② 只在**单个模块的 `body.bin`** 上搜（一般 1–2 MB，安全） |
| 只搜 **UTF-16** 就以为"这个能力固件里没有" | 固件里**两套命名并存**：**UI 显示文本 = UTF-16LE**（如 `Modern Standby`、`Deep sleep`）、**内部 Setup 变量名 = ASCII**（如 `DeepS3`、`HpModernStandbyConfigurations`、`CpuPwrMgmt`）。本机 `HpModernStandbyConfigurations` 在模块 `171 0147` 的 **@1,282,343（ASCII 名字表）**，而 `Modern Standby` 在 **@48,501 起（UTF-16 常量池）** ⇒ **两者都搜**才算穷尽 |
| **内置 `Grep` 工具对固件/二进制 dump 搜串**（2026-09-20） | ⚠️ **给出假否定**。它对二进制文件默认跳过 ⇒ 连 `Runtime Power Management`、`HpModernStandbyConfigurations` 这种**确实存在**的串都报 "No files found"。**当天靠"先跑正向对照"才发现**（第 5 次验证：0 命中必须配对照）。替代：Python 字节级 `bytes.find`，或 `grep -a` |
| 在 dump 上跑**递归**扫描（Python `os.walk` 全量读 / `grep -r` / `find -exec`） | **被沙箱 `SIGKILL`（exit 137）**，当天连栽三次（15,718 文件、3,501 文件的卷都杀）。**按文件数设预算**：< 100 个文件随便扫；上千个必然被杀。省力替代见下行 |
| 想给固件里的标识符**定位归属** | ① 直接对**原始镜像单文件**搜 —— 未压缩区的标识符是**明文**，命中后拿偏移；② 用 `.report.txt` 的 `Base`/`Size` 两列做区间反查（`base ≤ off < base+size`，取最内层）⇒ 得到「卷 / 模块 GUID / 段类型」三级归属。比解包后逐个搜**快且不触发 SIGKILL** |
| 把"固件组件名"当成"可写的设置项名" | ⚠️ 本机 `FspS3Notify` 是 **PEI 模块自己的名字**（在它的 UI section 里）、`HpCommonSetup`/`S3MemoryVariable`/`HpModernStandbyConfigurations` 是 **PEI 模块 PE32 里的标识符** —— 都**不是 NVRAM Setup 变量名**。真正的 Setup 变量名在 **HpSetup 模块的 ASCII 名字表**里。混淆会导致"按名字写入"时找不到项 |
| 想核**本机 BIOS 版本** | ★ **macOS 侧就能读真值**：`ioreg -p IODeviceTree -n efi -r -d 1 -w0` 的 `firmware-vendor`（`<480050000000>`=UTF-16 "HP"）与 `firmware-revision`（小端 UINT32 `0xMMmmPP00`，各字段为**原始字节值**，如 `0x01180200`=`0x18`=24 ⇒ 01.24.02）。⚠️ **`system_profiler` 的 `System Firmware Version` 是 OpenCore 装的假值**（本机 `2094.80.5.0.0`），不可用作判据 |

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

## 临时产物与「卡住」报告（2026-09-20 追加）
| 坑 | 正确做法 |
|---|---|
| 把中间产物放 `/tmp` 就以为留住了 | ⚠️ **macOS 重启即清 `/tmp`**。本机实测：10:44 还在的 302 MB 固件 dump、两个 `.exe`、UEFITool，到 12:04 **全没了**（`/private/tmp` 只剩本次启动创建的文件）⇒ **要留的产物一律落工作区或 exFAT 卷**（`docs/backups/…`），别放 `/tmp` |
| 看到 `*.shutdownStall` 就当"关机卡死" | 它是 **spindump 二进制**（`base64` → `zlib` → `bplist`），**可本地解**：取 `Spindump binary format` 之后的内容 → base64 解码 → 找 `78 9c` → zlib 解压 → 得 NSKeyedArchiver plist（`plistlib.loads`）。关键字段：`_event`、**`_extraDuration`**、`_durationNote`、`_customOutput` |
| 忽略 `_extraDuration` 的语义 | 本机三份报告 `_extraDuration = 2.0` ＋ `_durationNote = sampling started after 2 seconds` ⇒ **触发门槛只是"比预期多花 2 秒"** ⇒ **2 s 门槛的 "stall" ≠ 用户感知的卡死** |
| 以为 `_customOutput` 写的就是"卡住的原因" | ⚠️ 它是**诊断系统自己挑的分析对象**。本机三份（09-18 16:40 / 09-18 17:53 / **09-20 11:46**）**全部指向 `logd`**（`heap --addresses=.*transaction.*`）⇒ 正确读法是「关机时 logd 处理日志事务慢了约 2 秒」，**与 EC / ACPI 无关**，不是我们担心的那类卡死 |
| 想核 boot-args 但记不清 / NVRAM 已被覆盖 | spindump 里**原样存了 `_bootArgs`**（字符串）。本机：`nvram -p` ／ `config.plist` ／ shutdownStall 报告 **三方一致** ⇒ 再加一个可复验来源 |
| 想核系统与硬件元数据 | 同一份 spindump 还带 `_osProductVersion` / `_osBuildVersion` / `_kernelVersion` / `_hardwareModel` / `_memSize` / `_numActiveCPUs` / `_numVnodes*`，全是只读秒取的 |

## 存证入库前的脱敏（2026-09-20 追加）
**背景**：本工作区 `origin` = **公开** GitHub 仓库（`github.com/MYunFeiYang/zbookpowerg7`）⇒ 任何 `git add` 的内容**可能被公开**。

| 坑 | 正确做法 |
|---|---|
| 跨 OS 取证回传的原始产物**直接 `git add`** | ⚠️ `HP_BIOSSetting` 全表里混着**真机身份字段**：`Serial Number`、`System Board CT Number`、`Universally Unique Identifier (UUID)`（SMBIOS 系统 UUID）、引导路径里的 `NVMe(0x1,…)` EUI64 与 `GPT,…` 分区 GUID ⇒ **入库前一律替换为 `<REDACTED-…>` 占位符**（别删行，保留 `Name`/`DisplayInUI`/`IsReadOnly` 列，结论才可复算） |
| 以为"没 push 就没关系" | 先跑 `git status -sb` 看 **ahead 几个 commit**；再看远端是不是公开：`curl -s -o /dev/null -w '%{http_code}' <repo-url>`（**200 = 公开**）。本机实测：本地领先 **99** 个 commit、远端停在 09-08 ⇒ 12 天工作全未公开 |
| 想确认某个标识是否**已泄露** | `git log --all -S "<标识>" --oneline`（空 = 从未入库）；再对**公开快照**单独扫：`git grep -a -n -E "<正则>" origin/main -- '*.md' '*.plist' '*.txt' '*.sh'` ⚠️ 别用 `for f in $(git ls-tree …)` 逐文件 `git show` —— 会扫到 `.icns` 等二进制，**必被 SIGTERM 掐** |
| 区分"真机标识"与"伪装 SMBIOS" | `config.plist` 里 `PlatformInfo/Generic` 的 `SystemSerialNumber`/`MLB`/`SystemUUID`/`ROM`（如 `C02GC2YFMD6T` / ROM `333333`）是**为 MacBookPro16,4 生成的伪装值，不是本机 HP 标识** ⇒ 本来就在公开仓库里，属黑苹果常态，**保留**；只有固件读出的**真机值**才需脱敏 |
| 让脱敏只做这一次 | 把脱敏写进**采集端提示词**（`docs/windows-side-workbuddy-prompt.md`「落盘后必做」）⇒ 下次回传即为脱敏版；并在产物目录留 `REDACTION.md` 说明遮了哪些字段（**诚实可审计**，避免后人误读为"该字段原本为空"） |
