# 系统开销审计 —— 「还有优化空间吗？」（2026-09-18）

> 起因：用户问「还有优化的空间吗？」。此前 09-14 ~ 09-18 的六轮全部聚焦**睡眠档位**（S3/S4/Deep Idle），
> 已收手。本轮**换维度**：不再问"睡眠能不能更深"，改问"这台机平时都在忙什么"。
>
> **结论**：睡眠方向确实到头了；但**日常系统开销**与**内存**两个维度**有实打实的空间，且此前从没查过**。
> 全文数据均为本轮在机实测（`pmset` / `mdutil` / `mount` / `launchctl` / `diagnostic-reports` / `system_profiler` / `pgrep`）。

---

## 0. 一句话结论

| 维度 | 空间 | 性质 |
|---|---|---|
| **睡眠档位** | **无** | 三档已定论（S4 ❌ / S3 ❌ / Deep Idle ✅），三条腿全断 |
| **睡眠功耗地板 ≈5 W ≈7%/h** | **仅边角** | 唯一大杠杆＝睡眠关 Wi-Fi/BT，**用户已否决** |
| **★ 日常系统开销** | **有，且不小** | 22 个第三方系统服务 + 15 个 LaunchAgents；**功能重复的常驻软件成对存在**；ESP 分区被 Spotlight 索引 |
| **★ 内存** | **有，且是唯一"花钱买确定性"的项** | 16 GB 已吃紧：**swap 用 70%**、free 仅 136 MB、压缩页 626 万 |
| **硬件** | 有（可选） | 内存可升到 64 GB、第二个 M.2 槽空着 |

---

## 1. 睡眠方向：确认到头（不重复论证）

见 `s4-requirements-audit.md`（30 条准入条件）与 `README.md` 横幅 §六十七。
一句话：真正"没法满足"只有 `#28`（RTC 在 S4 断电期保持有效），在固件手里；能凑的 29 条凑齐也不改变结果。

---

## 2. ★ 新维度一：日常系统开销

### 2.1 常驻服务清单（本轮实查，`/Library/LaunchDaemons` + `LaunchAgents`）

**系统级 LaunchDaemons（第三方 22 个）**

| 类别 | 条目 |
|---|---|
| 容器 | `com.docker.socket`、`com.docker.vmnetd` |
| **远程控制 ×2（功能重叠）** | **`com.oray.awesun.helper` + `com.oray.awesun`**（向日葵）｜**`com.youqu.todesk.service` + `.session` + `.startup` + `.UninstallerHelper` + `.UninstallerWatcher`**（ToDesk） |
| **清理工具 ×2（功能重叠）** | `com.macpaw.CleanMyMac5.Agent`｜**`com.tencent.Lemon` + `.uninstall` + `LemonMonitor` + `Lemon.trash`** |
| OCLP | `com.laobamac.oclp-mod.macos-update`、`com.laobamac.oclp-mod.os-caching`、`com.laobamac.oclp-mod.auto-patch` |
| **ESP 自动挂载** | `com.oc.mountesp` ← **与 §2.3 的索引浪费直接相关** |
| 代理 | `io.github.clash-verge-rev.clash-verge-rev.service` |
| 公司安全（不可动） | `com.sangfor.*` ×4、`saio_*` ×3 |
| 输入法 | `com.sogou.SogouServices`、`com.sogou.SogouTaskManager` |
| 浏览器更新器 | `com.google.GoogleUpdater.wake`、`com.microsoft.EdgeUpdater.wake` |

**用户级 LaunchAgents**：`Clash Verge`、`EcoPaste`、`MicFix`、`com.oc.micinputswitch`、`GoogleUpdater.wake`、`EdgeUpdater.wake`、`Lemon.trash`

### 2.2 进程实况（`pgrep` 计数，本轮实查）

| 软件 | 进程数 | 备注 |
|---|---|---|
| Clash Verge | **3** | 代理，持续网络活动 |
| ToDesk | **3** | 远程控制 ① |
| 向日葵 `awesun` | **2** | 远程控制 ②（`SunloginClient` 本体 0，agent 常驻） |
| 腾讯柠檬 `Lemon` | **3** | 清理 ① |
| 搜狗输入法 | **3** | |
| Sangfor 全家桶 | **10+**（含 **ES 系统扩展**） | 公司软件，**不可动** |
| Docker | 1 | |
| EcoPaste | 1 | |
| CleanMyMac | 0 进程（Agent 在册） | 清理 ② |
| OCLP-Mod | 0 进程（服务在册） | |

> ⇒ **两个远程控制 + 两个清理工具同时在册、功能完全重叠**。这类软件的共同特征是"常驻 + 定时轮询 + 界面注入"，是桌面环境（WindowServer）额外负担的常见来源。

### 2.3 ★ ESP 分区被 Spotlight 索引（纯浪费，铁证）—— ✅ **已于 09-18 11:19 关闭并验证**

> 执行与验证记录见 **§8**。本节保留当时的取证原文，作为"改前基线"。

```
mdutil -as
/Volumes/ESP:  Indexing enabled.          ← 问题所在
/Volumes/Common: Indexing enabled.
mount | grep ESP
/dev/disk0s1 on /Volumes/ESP (msdos, local, nodev, nosuid, noowners, noatime, fskit)

ls -la /Volumes/ESP/.Spotlight-V100/
  Store-V2/                      (2026-08-04 21:30)
  VolumeConfiguration.plist      (2026-08-05 10:34)
du -sh /Volumes/ESP/.Spotlight-V100  →  4.1M
df -h /Volumes/ESP  →  2.0Gi total, 1.3Gi used, 736Mi avail
```

**为什么是纯浪费**：ESP 是 **FAT32 引导分区**，内容是 `EFI/`（含 `EFI/HP/DEVFW/` 的固件文件，`Firmware.BIN` 就 31 MB）。
它**不产生用户可见的搜索结果价值**，却因为 `com.oc.mountesp` 让它**长期挂载**，而它又是 FreeFileSync 的**镜像目标** ⇒
**每次同步都改文件 ⇒ 每轮同步都触发重扫**。索引本身只 4.1 MB，但扫描/更新的进程开销是持续的。

**对照**：`/Volumes/Common/.Spotlight-V100` = **298 MB**（工作盘，是否保留取决于是否需要 Spotlight 搜工作区）。

### 2.4 CPU 超限告警（macOS 自动生成，非人工标注）

目录 `/Library/Logs/DiagnosticReports/`：

| 报告 | 时间窗 | 内容 |
|---|---|---|
| `WindowServer_2026-09-17-213618_TMacBook-Pro.cpu_resource.diag` | `21:33:15 → 21:36:15` | **`90 seconds cpu time over 180 seconds (50% cpu average), exceeding limit of 50% cpu over 180 seconds`**；PID 171 |
| `apfsd_2026-09-17-214329_TMacBook-Pro.cpu_resource.diag` | `21:40:27 → 21:43:26` | 同上口径，**50% × 179 s**；PID 191；`Total CPU Time 367.478s`；`Vnodes Available 69.83% (183776/263168)` |

两份报告共同字段（佐证机器状态正常、非硬件故障）：
`Hardware model: MacBookPro16,4`｜`Active cpus: 12`｜`Memory size: 16 GB`｜
`Advisory levels: Battery -> 3, User -> 2, ThermalPressure -> 0, Combined -> 2`（**无热压力**）｜`Fan speed: 1765 rpm`

> **解读**：`WindowServer` 与 `apfsd` 分别在 21:33 / 21:40 连续触发 50% 阈值。`apfsd` 高 CPU 典型关联**大量文件元数据操作**（Spotlight 索引、同步、快照），`WindowServer` 关联**界面合成负载**。
> ⚠️ 时间点正是 09-17 晚间（落盘文档 + 用户操作密集期），**不能直接归给常驻软件**；但两份报告证明"这台机确实出现过持续 3 分钟的 50% CPU 段"，值得作为后续观察锚点而非结论。
> **本轮 `loadavg` 快照**：`{ 11.08 21.76 33.99 }`（开机 17 min ⇒ 1 min 已降到 11，5/15 min 仍高，说明**开机后有一段密集负载**）。

### 2.5 不可动项（说明性质，不作建议）

**深信服（Sangfor）全家桶** —— 公司强制安全客户端，本轮实查在跑的有：

```
/Library/sangfor/sase/saio/bin/saio_permguard.app/.../saio_permguard
/Library/sangfor/sase/saio/update/saio_update
/Library/sangfor/sase/saio/bin/saio_service
/Library/sangfor/SDP/aTrust.app/.../aTrustAgent --plugin plugin-daemon
/Applications/SangforVDIClient.app/.../CSMonitor
/Library/SystemExtensions/.../com.sangfor.auem.sfservice.extension.systemextension
/Library/sangfor/SNAC/bin/snac_agent
/Library/sangfor/sase/saio/bin/saio_agent  (+ .advanced)
/Library/sangfor/sase/saio/xtunnel/saio_xtunnel
```
挂载点：`/dev/disk6s2 on /Volumes/sangfor/uem_disk_1388746378 (hfs, nobrowse)`

**关键一条**：`systemextensionsctl list` 显示它注册的是 **`endpoint_security` 类型系统扩展**
（`com.sangfor.auem.sfservice.extension (2.5.16/15) [activated enabled]`，teamID `YYE5WQ4M88`）。
ES 扩展在**每个进程/文件事件**上被回调 ⇒ 这是**结构性开销**，不是"多一个后台进程"。
⇒ **只能知情，不可动**（动了影响办公网接入）。

顺带（非公司）：`com.xiaomi.hyperConnect.MiCamera` 是 `cmio`（摄像头）系统扩展，`[activated enabled]`。

---

## 3. ★ 新维度二：内存 —— 16 GB 已吃紧

### 3.1 实测数据

```
sysctl -n vm.swapusage   →  total = 2048.00M  used = 1426.50M  free = 621.50M  (encrypted)
memory_pressure          →  Pages compressed: 6267929 / Pages decompressed: 2833219
                            Pageins: 3141546 / Pageouts: 43045
                            System-wide memory free percentage: 52%
vm_stat                  →  Pages free: 34955 (≈136 MB)
                            Pages active: 1078858 (≈4.1 GB) / inactive: 1069248 (≈4.1 GB)
                            Pages wired down: 1099314 (≈4.2 GB)
```

| 指标 | 值 | 判读 |
|---|---|---|
| **swap used** | **1426.5 M / 2048 M = 70%** | 已动用 70% 交换区 |
| free pages | 34955 ≈ **136 MB** | 极低 |
| wired | 4.2 GB | 内核常驻 |
| 压缩页 | 626 万（解压 283 万） | 压缩器高度活跃 |
| Pageins | 314 万 | 大量回读 ⇒ 磁盘 I/O |

> ⚠️ **口径诚实交代**：这是**开机 17 分钟**的读数，缓存尚未建满，且用户当时开着 Docker/Edge/Sangfor 等。
> ⇒ 不能断言"常态就是这个水平"，但 **swap 已用到 70%** 是硬读数，说明**峰值确实触碰内存上限**。
> 要下"常态"结论需要连续采样（见 §5 待办）。

### 3.2 物理规格与可升级性（HP 官方 QuickSpecs，可当判据）

`system_profiler SPMemoryDataType`：
```
BANK 0/Bottom-Slot 1(left):   8 GB DDR4 2933 MHz  Samsung M471A1K43DB1-CWE  Status: OK
BANK 1/Bottom-Slot 2(right):  8 GB DDR4 2933 MHz  Samsung M471A1K43DB1-CWE  Status: OK
ECC: Disabled        Upgradeable Memory: No     ← ⚠️ 见下
```

**HP 官方 QuickSpecs 原文**（`h20195.www2.hp.com` QuickSpecs PDF / 1worldsync 同一文档）：

> **MEMORY** — *Maximum Memory: **64 GB DDR4-3200 non-ECC SDRAM**｜**2 DDR4 SODIMMs**｜Supports Dual Channel Memory｜
> **Slots are customer accessible / upgradeable***

⇒ **本机 `Upgradeable Memory: No` 是错的**，来自 OpenCore 注入的 MacBookPro16,4 SMBIOS（真 Mac 内存板载，故字段为 No）。
**物理事实：2 个 SODIMM 插槽、当前 2×8 双通道、官方上限 64 GB。**
> ⚠️ 同一份 QuickSpecs 另有一处写 `Supports Single Channel Memory`（不同版本 PDF 措辞不一致），
> 但本机**两个 BANK 都插满**且有 Part/Serial ⇒ 双通道无疑。

### 3.3 为什么这算"优化空间"

内存压力 → 压缩器工作 → **swap 读写** → ① `apfsd` CPU 抬升（§2.4 已实测到 50% × 179 s）② 磁盘 I/O 增加 ③ 整体响应变慢。
这是**唯一"花钱就能买到确定性收益"**的方向，且对本机**零黑苹果风险**（不像刷固件/改 EFI）。

---

## 4. 硬件维度的其余选项

| 项 | 状态 | 备注 |
|---|---|---|
| 内存 | **可升** 至 64 GB（2×SODIMM，客户可访问） | 见 §3.2 |
| 存储 | **第二个 M.2 2280 槽空着**（官方最大 4 TB，双盘） | 需要更多本地空间时可用 |
| 电池 | **Cycle Count 131｜Condition Normal｜满充 5964 mAh** | 很新，无老化问题 |
| SSD 固件 | `234100WD`，官方工具仅 Windows（**本机有完整 Windows 分区 ⇒ 理论可刷**） | 高风险、收益不明 ⇒ **不建议** |
| BIOS | `T75 Ver. 01.24.02 / 2026-05-11` | 比 HP 2026-03 公告基线还新 ⇒ 刷固件无意义 |

---

## 5. 可执行清单（按性价比排序）

### A. 零成本 / 零风险 —— 建议做

| # | 动作 | 命令 | 预期 |
|---|---|---|---|
| **A-1** | **关掉 ESP 的 Spotlight 索引** | `sudo mdutil -i off /Volumes/ESP` | 消除每轮同步后的重扫；ESP 不产生搜索结果价值 |
| A-2 | 顺带清掉 ESP 上已建的索引目录 | `sudo rm -rf /Volumes/ESP/.Spotlight-V100` | 释放 4.1 MB 并复位状态（**可选**，`mdutil -i off` 已足够） |

### B. 零成本 / 需你取舍 —— 你决定

| # | 动作 | 依据 |
|---|---|---|
| **B-1** | **两个远程控制留一个**：ToDesk（3 进程）或 向日葵（2 进程） | 功能完全重叠 |
| **B-2** | **两个清理工具留一个**：腾讯柠檬（3 进程）或 CleanMyMac5 | 功能完全重叠 |
| B-3 | `/Volumes/Common` 索引（298 MB）是否保留 | 取决于你是否用 Spotlight 搜工作区；**你常用就不要关** |
| B-4 | 小米 `MiCamera` 摄像头系统扩展（不用小米互联即可禁用） | `systemextensionsctl list` 显示 enabled |

### C. 花钱 / 收益确定 —— 可考虑

| # | 动作 | 依据 |
|---|---|---|
| **C-1** | **内存 16 → 32 GB**（2×16 或留 1 条换） | §3：swap 70%、free 136 MB；官方支持且客户可自行更换 |
| C-2 | 加第二块 M.2（如需要更多本地盘位） | 槽位空置 |

### D. 不建议

- **S4 / hibernation**（已判死，见 `s4-requirements-audit.md`）
- **SSD 固件刷新**（`234100WD`，有 Windows 分区但风险/收益不匹配）
- **再刷 BIOS**（本机已比公告基线新）
- **睡眠关 Wi-Fi/BT**（唯一大杠杆，用户已否决）

---

## 6. ⚠️ 本轮顺带发现的两处文档不一致（已更正）

| 项 | 文档原写 | **实际（本轮实读）** | 说明 |
|---|---|---|---|
| `rtcfx_exclude` | `80-FF`（MEMORY.md 第 13 行） | **`0E-FF`** | `config.plist` 与 `nvram boot-args` **两边一致为 `0E-FF`**；`80-FF` 是 `4ceea3a`(09-16 13:39) 引入时的初值，后改为 `0E-FF`（README 横幅 §"④ 诚实交代混淆变量"记过这次变更） |
| `-wegnoegpu` | 列为 boot-args 成员（MEMORY.md 第 13 行） | **已移除** | `git log -S "wegnoegpu"` ⇒ 在 **`ebf6d5c`（09-17 17:29，"移除全部 pci-aspm-default 注入"）**那次一并删除；与"恢复 `SSDT-dGPU-PowerOff-Darwin.aml` 用 `PEGP._OFF` 断电"配套（不再靠屏蔽驱动） |

**当前 boot-args 权威值**（`config.plist` 与 `nvram` 一致）：
```
-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=0E-FF -rtcfxdbg
```

---

## 7. 待办（需连续采样才能定论）

- [ ] **内存常态压力**：跨 ≥4 h 每 15 min 采一次 `sysctl -n vm.swapusage` + `memory_pressure`，确认 §3.1 是峰值还是常态（决定 C-1 该不该做）
- [ ] **apfsd / WindowServer 告警是否复发**：观察 `/Library/Logs/DiagnosticReports/` 是否再出现 `*.cpu_resource.diag`
- [x] **A-1 重启后复核**（09-18 11:19 已执行，并已通过"卸载→重挂"验证，见 §8）—— ✅ **2026-09-18 14:05 重启后实测：`Indexing disabled` 保持**（复核记录见 §9.5）

---

## 8. ★ A-1 执行记录：关闭 ESP 的 Spotlight 索引（2026-09-18 11:19）

### 8.1 做了什么

```
osascript -e 'do shell script "mdutil -i off /Volumes/ESP" with administrator privileges'
→ /System/Volumes/Data/Volumes/ESP:	Indexing disabled.
```

### 8.2 前后对照（全部实读，非转述）

| 项 | 改前 | 改后 |
|---|---|---|
| `mdutil -s /Volumes/ESP` | `Indexing enabled.` | **`Indexing disabled.`** |
| `/Volumes/ESP/.Spotlight-V100` 占用 | **4.1 M** | **20 K**（只剩 `VolumeConfiguration.plist`，`Store-V2` 被清空） |
| `VolumeConfiguration.plist` mtime | 08-05 10:34 | 09-18 11:19（被改写） |
| 该 plist 的 `Options` / `Stores` | `Default` / 1 条 store 记录 | **仍是 `Default`**、store 记录仍在（只改了 mtime 与 `ConfigurationModificationVersion`）⇒ 卷上这份文件**不承载「禁用」语义**（机制见 **§9.3**，含对我上一轮错误推断的更正） |

### 8.3 持久性验证：卸载 → 重新挂载 → 状态保持

```
mdutil -s /Volumes/ESP      → Indexing disabled.
diskutil unmount disk0s1    → Volume ESP on disk0s1 unmounted
diskutil mount disk0s1      → ✗ failed to mount（非提权）
osascript … "diskutil mount disk0s1" with administrator privileges
                            → ✓ Volume ESP on disk0s1 mounted
mdutil -s /Volumes/ESP      → Indexing disabled.   ← 保持
du -sh /Volumes/ESP/.Spotlight-V100 → 20K          ← Store-V2 未被重建
```

⇒ **卸载重挂后不复活**，且没有重新生成索引存储 ⇒ 关闭是真生效，不是"暂时不扫"。ESP 内容完整性同时复核：`config.plist` / `OpenCore.efi` 与工作区 sha256 一致，ACPI 20 / Drivers 6 / Kexts 27 全等。

### 8.4 ⚠️ 两条必须记住的操作要点

1. **不要删 `/Volumes/ESP/.Spotlight-V100`**。虽然现在只有 20 K，但那是 Spotlight 读**卷级配置**的位置；删掉可能让该卷回落默认（启用）并被重新索引 —— 正好是这次要消除的行为。留着这 20 K 是"锚点"，不是垃圾。
2. **`diskutil mount disk0s1` 需要 root**。本轮实测非提权执行返回 `failed to mount … try the "readOnly" option`，**只有提权才成功**。`com.oc.mountesp` 由 LaunchDaemon（root）运行所以不受影响，但**任何手工卸载 ESP 的动作，都必须先确认手上有 root 手段能挂回来**，否则 FreeFileSync 的同步目标会消失。

### 8.5 顺带厘清：重扫的真实触发源不是挂载服务

- `com.oc.mountesp`（`/Library/LaunchDaemons/`，调 `/Library/Scripts/mount-esp.sh`）= `RunAtLoad=true`，**无 `WatchPaths` / `KeepAlive` / `StartInterval`** ⇒ **只在开机挂载一次**，不是"持续触发重扫"的元凶（§2.3 的表述不够准确，在此订正）。
- 真凶 = **RealTimeSync（实测常驻，PID 3663 / 3672）**：`LastRun.ffs_real` → `Commandline: FreeFileSync /Volumes/Common/FreeFileSync/BatchRun.ffs_batch`，`Delay: 3` ⇒ 工作区一有改动即触发同步，**每轮同步都改 ESP 上文件的 mtime ⇒ 每轮都喂给索引器**。
- 同步范围（`LastRun.ffs_gui` 实读）：`Left: /Volumes/Common/workplace/zbookpowerg7/EFI/oc` → `Right: /Volumes/ESP/EFI/oc` ⇒ **镜像目标是 `EFI/oc` 这一层，不含 ESP 根**，所以 ESP 根下的 `.Spotlight-V100` / `.Trashes` / `.fseventsd` 不会被镜像删掉（这正是它能存活到今天的原因）。

### 8.6 未执行的部分

- **`/Volumes/Common`（索引 298 MB）保持 enabled 不动** —— 它是工作区盘（git 仓库 + 代码 + 文档），Spotlight 搜索有实际价值。若要关：`sudo mdutil -i off /Volumes/Common`（可逆：`sudo mdutil -i on /Volumes/Common`）。
- 本轮**未动任何常驻软件**（B 组：ToDesk/向日葵、腾讯柠檬/CleanMyMac5 的功能重叠取舍仍待定）。

---

## 9. A-1 续：关闭 `/Volumes/Common` 的索引（2026-09-18 11:35）

### 9.1 执行与前后对照

```
osascript -e 'do shell script "mdutil -i off /Volumes/Common" with administrator privileges'
→ /System/Volumes/Data/Volumes/Common:	Indexing disabled.
```

| 项 | 改前 | 改后 |
|---|---|---|
| `mdutil -s /Volumes/Common` | `Indexing enabled.` | **`Indexing disabled.`** |
| `/Volumes/Common/.Spotlight-V100` | **298 M** | **512 K**（`Store-V2` 被清空） |
| 卷可用空间（`df -h`） | 112 Gi | **113 Gi**（约释放 298 MB） |
| `mdfind -onlyin /Volumes/Common "config.plist"` | 能命中 | **无输出**（符合预期）；直接路径访问不受影响 |

**卷信息**：`disk0s5` / **ExFAT** / UUID `C132AD3D-BFDB-3F77-A4F6-FCF939B2B9E0` / 303 GiB / 可用 113 GiB。
⚠️ **本卷是工作区所在盘**（`/Volumes/Common/workplace/zbookpowerg7`）。

### 9.2 ⚠️ 为什么这次**没有**做「卸载 → 重挂」持久性验证

ESP（`disk0s1`）那次做了，因为**卸载它不影响任何在用数据**。
`/Volumes/Common` 不同：**工作区（git 仓库）就在它上面**，而本轮已实测
**`diskutil mount` 需要 root、裸跑会失败** —— 一旦卸载后挂不回来，整个工作区当场不可用。
**风险不对等 ⇒ 主动降级验证强度**，改为"只读核对 + 重启后复核"。
（这不是图省事，是**对高代价操作主动收手** —— 与 skill 里「判据不能拿推断当结论」同一纪律。）

### 9.3 ★ 机制查证：禁用状态到底存在哪？（并更正我上一轮的错误推断）

**结论：存储位置未查明；但"跨挂载持久"有实证。**

已排除：
- ❌ **不在被改卷上的 `VolumeConfiguration.plist`**：ESP 与 Common 关闭后，该文件的
  `Options` **仍是 `{'ConfigurationType': 'Default'}`**、`Stores` 里那条记录**仍在**（10 个键），
  只改了 `ConfigurationModificationDate` 与 `ConfigurationModificationVersion`（`26.5.2 → 26.6.2`）
  ⇒ **卷上这份文件不承载"禁用"语义**。
- ❌ **不在 `/System/Volumes/Data/.Spotlight-V100/VolumeConfiguration.plist`**（我上一轮的推断）：
  实测 `plutil -p … | grep -i -E "C132AD3D|852A2DCE"` ⇒ **NO_MATCH**。
- ⚠️ `/var/db/Spotlight`（`root:wheel`）与 `/var/db/Spotlight-V100`（`root:_mds_stores`）
  **即使 `with administrator privileges` 也 `Permission denied`** ⇒ 受系统保护，读不到。

仍成立的实证（**这两条才是判据**）：
1. ESP 关闭后经 **"卸载 → 重新挂载"** 仍为 disabled、`Store-V2` 未被重建
   —— 重挂会让 mds 重新评估该卷，仍不索引 ⇒ **磁盘上有持久记录**（不是内存态）。
2. **`/Volumes/TZBOOK`（NTFS）长期 disabled，且根本没有 `.Spotlight-V100` 目录**
   ⇒ 该状态**不依赖卷上文件**。

⇒ 判据写作：**"跨挂载持久（有实证）；存储位置未查明（受系统保护，读不到）"**。
⚠️ 这正是 skill §0a-3 / §0a-6 的纪律：**推断不能当结论**；查不到就写"未查明"。

### 9.4 待办

- [x] **下次重启后复核两个卷**：`mdutil -s /Volumes/ESP; mdutil -s /Volumes/Common` —— ✅ **已复核通过，见 §9.5**

### 9.5 ★ 跨重启复核（2026-09-18 14:05）—— ✅ 通过（本条为「跨挂载持久」的补充实证）

**时机**：用户 14:01 从 Windows 关机、14:05 重启回 macOS（`last reboot` 实读）。重启 = 卷全部重新挂载 ⇒ 是「跨重启」这一维度的天然测试点。

**实测（`osascript … with administrator privileges` 提权读）**：

```
--- ESP ---
/Volumes/ESP:       Indexing disabled.
--- Common ---
/Volumes/Common:    Indexing disabled.
--- 根卷 ---
/:                  Indexing enabled.      ← 对照组：根卷仍开，说明 mdutil 本体工作正常，不是"全都报 disabled"
```

**结论**：
1. 两卷关闭状态 **跨重启保持**，§9.4 的"若复活需改用 launchd 挂钩"这一兜底**不触发**。
2. **补强了 §9.3 的机制判断**：上一轮已有的实证是"跨挂载（卸载→重挂）持久"，现在**又多了"跨重启（整机重启、卷重新挂载）持久"** —— 两种重挂路径都不丢 ⇒ 更坐实「状态不依赖卷上文件、存在系统保护位置」，也再次排除"内存态"的可能。
3. **对照组（根卷 `Indexing enabled`）是本条的关键**：如果三个卷都报 disabled，就该怀疑 `mdutil -s` 输出被污染；根卷一开两关，说明读数可信。

*回滚不变：`sudo mdutil -i on <卷>`。*
- [ ] 若日后需要 Spotlight 搜工作区 ⇒ `sudo mdutil -i on /Volumes/Common`
      （会重建索引，首轮全盘扫描有一次性开销）。

---

*本轮**改动共两处**（均为系统级、一条命令可逆）：`mdutil -i off /Volumes/ESP`、`mdutil -i off /Volumes/Common`。**EFI / pmset / config 零改动**，其余均为读取与落盘。回滚：`sudo mdutil -i on <卷>`。*

---

## §10（09-18 11:4x）CleanMyMac 5 卸载残留清点（B 组前置调查）

**触发**：B 组"常驻软件重叠"（远程控制＝ToDesk+向日葵；清理工具＝腾讯柠檬+CleanMyMac5）待办。
查 CMM5 现状时发现：**应用本体已不在 `/Applications`**（`ls /Applications` 44 项全列，无任何 clean/macpaw 条目）、**废纸篓也无** ⇒ 已被**拖拽删除，未走官方卸载器**。

### 10.1 残留清单（全部实测，按权限分层）

| # | 位置 | 体积 | 属主 | 性质 |
|---|---|---|---|---|
| 1 | `/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent` | **2.0 M** | `root:wheel` `r-xr--r--` | **root 特权助手二进制**（2026-05-08） |
| 2 | `/Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist` | 572 B | `root:wheel` | launchd **系统域已注册**（`launchctl print system/…` 可打印，`state = not running`） |
| 3 | **BTM 登录项** `16.com.macpaw.CleanMyMac5.Agent` | — | 系统数据库 | `sfltool dumpbtm` 条目 #14，`Type: legacy daemon`，**`Disposition: [enabled, allowed, notified]`** |
| 4 | `~/Library/Group Containers/S8EX82NJP6.com.macpaw.CleanMyMac5` | **9.3 M** | <REDACTED-USER> | 最大头（内部 `Library/` 独占 9.3 M） |
| 5 | `~/Library/Group Containers/S8EX82NJP6.com.macpaw.CleanMyMac4` | 4 K | <REDACTED-USER> | **跨代残留**（CleanMyMac **4** 时代遗留） |
| 6 | `~/Library/HTTPStorages/com.macpaw.CleanMyMac5{,.HealthMonitor,.Menu}` + 3×`.binarycookies` | ≈3.0 M | <REDACTED-USER> | 6 项 |
| 7 | `~/Library/Preferences/com.macpaw.CleanMyMac5.Menu.plist` | 4 K | <REDACTED-USER> | 菜单栏组件偏好 |
| 8 | `~/Library/Application Support/CleanMyMac_5_HealthMonitor` | 0 B | <REDACTED-USER> | 空目录 |
| 9 | `~/Library/Application Scripts/{S8EX82NJP6.…CleanMyMac4, S8EX82NJP6.…CleanMyMac5, com.macpaw.CleanMyMac5.AppIntentsExtension}` | 0 B ×3 | <REDACTED-USER> | 沙箱脚本目录 |
| 10 | `~/Library/Application Support/CrashReporter/CleanMyMac_5_Menu_416EF620-….plist` | 4 K | <REDACTED-USER> | 崩溃报告 |

**合计 ≈ 14 MB / 12 处。**

### 10.2 已核对干净的位置（避免误报"到处是残留"）

`/Applications`（44 项全列无匹配）｜`~/.Trash`｜`~/Library/{Containers, Caches, Logs, LaunchAgents}`｜`/Library/{LaunchAgents, Application Support, Preferences, Caches, Logs, Receipts}`｜`/private/var/db/receipts`（无 ⇒ **非 pkg 安装**）｜用户域 `launchctl list`（无 macpaw）⇒ **确认不是 pkg 分发、也不是全盘开花**。

### 10.3 影响判定（按"性能 vs 攻击面"分开说，不混为一谈）

- ✅ **不耗 CPU、不占内存**（实测）：`launchctl print system/com.macpaw.CleanMyMac5.Agent` ⇒ `active count = 0`、`state = not running`；用户域无服务。
  理由：plist 只声明 `MachServices`（**按需 XPC 启动**，无 `RunAtLoad`/`KeepAlive`/`StartInterval`），app 已删 ⇒ 无人请求 ⇒ 永不拉起。**所以这 14 MB 不是"性能问题"。**
- ⚠️ **真正的代价有两条**：
  1. **一个 root 特权二进制（2 MB）长期留在盘上**。任何本地进程仍可尝试连它的 Mach 端口，属**攻击面**而非开销；
  2. **BTM 里一条 `enabled` 的 legacy daemon 登录项**留在登录项数据库，且日后若重装 CMM5 会**被复用**（而非干净重装）。

### 10.4 清理方案（**未执行，待用户确认**）

**系统级 3 处（需 root，`osascript … with administrator privileges`）**：
```bash
launchctl bootout system/com.macpaw.CleanMyMac5.Agent     # 先从 launchd 卸服务（顺序重要）
rm /Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist
rm /Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent
```
⚠️ **BTM 条目（#3）的两种处理**：
- **推荐**：删掉 plist/二进制后**重启**，看 `sfltool dumpbtm` 里 #14 是否自动消失（legacy daemon 条目随 plist 消失而失效）。**代价 0**。
- **兜底**：`sfltool resetbtm` —— ⚠️ **代价大**：会**重置整个登录项数据库**，连带清掉 Clash Verge / EcoPaste / Edge·Google 更新器 / OCLP-Mod 等**所有第三方登录项**，需逐个重建。**只在前者无效时用，且须先 `dumpbtm` 存一份现状备份。**

**用户级 9 处（无需 root，走废纸篓 `trash`，不用 `rm`）**：清单见 10.1 的 #4~#10。
⚠️ `~/Library/Group Containers/S8EX82NJP6.com.macpaw.CleanMyMac5`（9.3 M）删除前确认**没有别的 app 依赖该 group**（同 teamID `S8EX82NJP6` ⇒ 仅 MacPaw 自家产品，本机仅 CMM4/5）⇒ 安全。


---

## §11 ★ 空闲功耗归因（2026-09-18 14:20 / 14:36 两轮实测）

**背景**：09-17 曾测出"静默 45 s 后仍 `package power ≈ 25 W`、`Package C-state 0.00%`"，
但当时进程榜被自己的诊断命令污染（`lsof`/`seedusaged`/`system_profiler` 全是我跑的）⇒ 未定案。
09-18 14:05 重启后趁干净窗口重测 **两轮**。

**方法**：`powermetrics --samplers cpu_power,tasks --show-process-energy`（提权）。
⚠️ `ps`/`top` 被沙箱硬禁（连 root 也 `Operation not permitted`）⇒ 进程数据**只能**来自 powermetrics 的 tasks 表。

### 11.1 两轮读数

| | 第一轮 14:20（重启后 15 min） | 第二轮 14:36 |
|---|---|---|
| `package power` | 19.16 ~ 22.45 W | 24.73 ~ 25.18 W |
| `Package C-state` | **0.00%（C2~C10 全 0）** | **0.00%（同）** |
| `System freq` | 135% of nominal (3521 MHz) | 114~135%（2959~3477 MHz） |
| `Cores Active` | 82.9 ~ 86.2 % | 93.1 ~ 97.7 % |
| `Avg Num of Cores Active` | 2.01 ~ 2.50 | **2.87 → 4.44（爬升）** |
| `ALL_TASKS` 合计 | — | **2748 / 3702 / 4792 ms/s（≈2.7~4.8 核）** |
| `load average` | — | **25.84** |

### 11.2 ★ 关键更正：Spotlight 是**插曲**，不是常态

第一轮进程榜上前列是 **7 个 `mdworker_shared`（PID 连号 12064~12070），各 ≈515~528 ms/s**
（合计 ≈3.5 核）—— 形态是**批量启动、并行猛扫、批量退出**。

**但第二轮它们全部消失**（只剩零星新 PID 12902/13135，CPU 仅 0.27~7.81 ms/s）⇒
**这是重启后的一次性重建，不是无限循环**。⚠️ 上一轮"Spotlight 反复重索引"的判断在**本次重启周期内不成立**。

（旁证：`mdutil -a -s` 全卷状态 = `/`、`/System/Volumes/Data`、`/Preboot` enabled；
`Common`、`ESP`、`TZBOOK` disabled —— 与 09-18 上午的改动一致，无漂移。）

### 11.3 25 W 的真实归因（以第二轮"最安静"快照 #2，合计 2652 ms/s ≈ 2.65 核）

| 来源 | 实测 CPU ms/s | 性质 | 可否动 |
|---|---|---|---|
| `WindowServer` | 383 ~ 556 | 界面合成 | 必需 |
| **深信服全家桶** | `sfservice.exten` 258~496 ＋ `saio_xtunnel` 156 ＋ `saio_agent` 41~53 ＋ `aTrust` 33 ＋ `CSMonitor` | 公司 EDR | ❌ **公司软件** |
| `kernel_task` | 198 ~ 294 | 内核 | 必需 |
| **`coreaudiod`** | **166 ~ 207** | ⚠️ **三个第三方虚拟声卡 in-process** | ✅ **可动** |
| WorkBuddy（`Electron`＋Renderer＋GPU） | 95 ~ 818 | 本次诊断期间是我自己 | — |
| Edge（3 进程）＋ Chrome | 80＋48＋44＋39＋17 ≈ 230 | 双浏览器 | ⚪ 可用性权衡 |
| `mediaremoted` | 71 ~ 85 | 媒体远程服务 | ⚪ 待查 |
| `SogouInput` | 39 ~ 47 | 输入法 | ⚪ 待查 |

**另见**：第二轮出现了**不是本次诊断启动的** `ps`(PID 13795, 1040 ms/s)、`system_profiler`(13791, 351 ms/s)、
`saio_dialog`(13865, 430 ms/s) —— 三者同一时段出现，形态符合**深信服定期资产盘点/扫描**（EDR 典型行为）。

### 11.4 ★★ 真发现：三个远程控制虚拟声卡塞进了 coreaudiod

```
/Library/Audio/Plug-Ins/HAL/
  OrayVirtualAudioDevice.driver   ← 向日葵（上海贝锐 oray）  2025-03-26
  ToDeskOutputDriver.driver       ← ToDesk                  2026-08-11
  ParrotAudioPlugin.driver        ← 远程音频插件             2026-08-13
```

HAL 插件是**加载进 `coreaudiod` 进程内**运行的 ⇒ 其开销**全部计入 coreaudiod 的 CPU 账**。
`system_profiler SPAudioDataType` 里实际注册的虚拟设备 = `OrayVirtualAudioDevice`（制造商
`Shanghai best oray information s&t co.,ltd`）；`coreaudiod` 日志中
`AllowNegotiateAdaptInSetComposition` 与 `AXHearingHalPlugin` 反复出现 = HAL 持续协商音频上下文的形态。

⇒ **`coreaudiod` 的 ~180 ms/s 不是音频子系统自身的病**，是三个远程控制塞进来的虚拟声卡开销。
⇒ 与 §5-B「常驻软件重叠：ToDesk vs 向日葵」是**同一件事的两面** —— 卸掉其中一个远程控制，
   同时省进程 + 省 coreaudiod 开销。**这是本节唯一"既省 CPU 又不损失功能"的动作。**

### 11.5 结论

1. **25 W 不是电源管理故障，也不是"待机异常"** —— 是**这台机器从未真正空闲**：
   公司 EDR ＋ 界面合成 ＋ 三个虚拟声卡 ＋ 双浏览器 ＋ 输入法 ＋ Electron 叠加 ≈ 2.6~4.8 核。
2. **`Package C-state 0.00%` 单独不能当判据**：合理（4.8 核在跑时封装难进深度态）但**极端**，
   黑苹果上 powermetrics 读 PMU/C-state 的可靠性存疑 ⇒ 标记为**存疑、不作结论依据**；
   高功耗结论由 `load average 25.84` ＋ `Avg Cores Active 4.44` ＋ 进程榜三方独立支撑。
3. **与"睡眠待机功耗"是两条轴**：合盖睡眠实测 **≈4.1 W（6%/h）**，那条线已到头；
   本节的 25 W 影响的是**开盖续航**，与合盖睡眠无关。
4. **可行动项**（按收益/代价排序）：
   - ✅ **卸掉 ToDesk / 向日葵之一**（顺带清三个虚拟声卡，省 coreaudiod ~180 ms/s）← 唯一"净赚"项
   - ⚪ 查 `mediaremoted` 空转（Now Playing 会话残留？）
   - ⚪ 双浏览器并开（Edge＋Chrome）→ 留一个
   - ❌ 深信服：只能知情，不可动
   - ❌ WindowServer / kernel_task：必需

---

## §12 已卸载软件残留清理（2026-09-18 14:45~14:52）

**用户指令**：「安装的软件那就别动了，卸载残留可以处理一下」⇒ 范围 = **app 本体已删除、只留下痕迹的软件**；
在装软件（深信服/向日葵/ToDesk/搜狗/腾讯柠檬等）**一律不动**。

### 12.1 扫描方法（两级判据 + 一次严重误报）

| 判据 | 做法 | 结果 |
|---|---|---|
| ① launchd 孤儿 | plist 里 `Program`/`ProgramArguments[0]` 路径是否存在 | 37 条**全部存在**，0 孤儿 |
| ② 关联 app 是否存在 | plist 里的 `/Applications/*.app` 引用是否还在 | 0 命中 |
| ③ 库目录孤儿 | 库目录条目名 ↔ 存活集比对 | ⚠️ **第一版严重误报** |
| ④ 特权助手反查 | `/Library/PrivilegedHelperTools/*` ↔ app | **2 个孤儿** |

⚠️ **判据 ③ 的第一版几乎闯祸**：存活集只扫了 `/Applications`，结果把
**搜狗输入法（`Sogou` 948 MB）**、**深信服 `aTrust`（365 MB）** 判成"孤儿"——
它们装在 **`/Library/Input Methods/SogouInput.app`** 等**非 /Applications 位置**。
⇒ **教训：判"某软件已卸载"必须先补全 app 的全部安装位置**，至少包括：
`/Applications`、`/System/Applications{,/Utilities}`、`~/Applications`、
**`/Library/Input Methods`（输入法！）**、`/Library/PreferencePanes`、`/Library/QuickLook`、
`/Library/Internet Plug-Ins`、`/Library/Screen Savers`、`/Library/Spotlight`、`/Library/Services`、
`/Library/Extensions`、`/Library/Audio/Plug-Ins/{HAL,Components}`。
**再加一层交叉验证：当前活跃进程名**（最硬的存活证据）。
修正后：候选从 **213 条 / 1753 MB → 146 条 / 405 MB**。

### 12.2 CleanMyMac5 —— 已清理完毕

**系统级（root，`rm` 不可逆 ⇒ 先备份到工作区）**

| 对象 | 体积 | 处置 |
|---|---|---|
| `/Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist` | 572 B | `launchctl bootout` → 删除 |
| `/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent` | 2.0 MB | 删除 |

备份：`docs/backups/cleanmymac5-residue-2026-09-18/`（含 plist + 二进制，
二进制 sha256 `e783df0a5af5cbdf9cb67afcfbb701358ea41050cc0c5be2251d66e8c5a6e12a`）⇒ **可回滚**。

**用户级（14 项 ≈ 12.6 MB）**：Group Containers（`CleanMyMac5` 9.3 M ＋ **跨代 `CleanMyMac4`**）、
HTTPStorages ×7（`…CleanMyMac5`／`.HealthMonitor`／`.Menu` ＋ 各 `…binarycookies`）、
Application Support（`CleanMyMac_5_HealthMonitor`）、Application Scripts ×3、
Preferences（`…CleanMyMac5.Menu.plist`）、CrashReporter（`CleanMyMac_5_Menu_*.plist`）。

**终检**：21 个目标目录（用户级 13 ＋ 系统级 8）**全部 0 命中** ✅

**⚠️ 未闭项：BTM 登录项**

删除文件后 `sfltool dumpbtm` 中 **`16.com.macpaw.CleanMyMac5.Agent` 仍在**，
其 `URL: file:///Library/LaunchDaemons/com.macpaw.CleanMyMac5.Agent.plist`、
`Executable Path: /Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent` —— **两者均已不存在**。
⇒ 按机制（legacy daemon 条目随 plist 消失而失效）应在**下次重启**时自行清除。
**待验证**；若重启后仍在，再考虑 `sfltool resetbtm`（代价大，会清掉所有第三方登录项，不首选）。

### 12.3 ★★ 过程中的重大发现：这台机器上「走废纸篓」不可靠

按"personal files 走废纸篓而非 `rm`"的原则，用户级 14 项是先 `mv` 进
`~/.Trash/CleanMyMac5-residue-20260918/` 的（当时 `du` 显示 12 M，命令全部返回成功）。
**数分钟后复查：`~/.Trash` 整个为空（mtime = 14:48）** —— 那 12 项**已被清空**。

**元凶（高度怀疑）**：常驻的**腾讯柠檬（`LemonDaemon` / `LemonMonitor`，进程表实读在跑）**、
以及 `Sensei` —— 这类清理/优化工具会定期或触发式**清空废纸篓**。

⇒ **结论：本机「走废纸篓 = 可恢复」这个前提不成立。**
⇒ **后续在本机做任何删除，正确顺序改为：① 先 `cp` 到工作区 `docs/backups/` 存证 →
② 再执行删除**（不要依赖废纸篓的暂存期）。

### 12.4 剩余候选（**未执行**，待用户逐项确认）

**A. 高置信「配置残留」（app 已不在，且属配置而非用户数据）**

| 位置 | 体积 | 归属 |
|---|---|---|
| `~/Library/Group Containers/4C6364ACXT.com.parallels.toolbox` | 15.1 M | Parallels Toolbox |
| `~/Library/Preferences/Parallels` | 39 K | 同上 |
| `~/Library/HTTPStorages/io.tailscale.ipn.macsys` 等 | 338 K | Tailscale |
| `~/Library/Group Containers/group.com.nektony.MacCleaner-PRO-SIII` | 1 K | **MacCleaner PRO**（另一个清理工具） |
| `~/Library/HTTPStorages/org.altervista.mackie100projects.OpenCore-Configurator` + plist | 103 K | OpenCore Configurator |
| `~/Library/HTTPStorages/fr.madrau.switchresx.app` | 52 K | SwitchResX |
| `~/Library/Group Containers/D43XN356JM.com.charliemonroe.Permute-{3,setapp}` | 2 K | Permute |
| `~/Library/HTTPStorages/{LaunchNext,MiniLauncher,msedge_crashpad_handler}` | ~350 K | 启动器类 |
| `~/Library/Group Containers/88L2Q4487U.WeWorkMac` | 1.3 M | 企业微信旧版 |
| `~/Library/HTTPStorages/com.anthropic.claudefordesktop` | 52 K | Claude Desktop |
| `~/Library/Saved Application State/net.java.openjdk.java.savedState` | 17 K | Java 应用 |
| `~/Library/Application Support/{Ollama, GitKrakenCLI, CodeBuddyExtension}` | ~1 M | ⚠️ 可能是 CLI 工具，**须先确认** |

**B. ⚠️ 疑似「用户数据」—— 删除会丢内容，必须单独确认**

| 位置 | 体积 | 风险 |
|---|---|---|
| `~/Library/Containers/com.hihonor.hihonornote`（＋ `.notifextension`） | **351 M** | **荣耀笔记：可能是笔记正文** |
| `~/Library/Containers/com.bot.neotix.doubao` | 24.5 M | 豆包：可能是对话记录 |
| `~/Library/Containers/is.follow` | 22.3 M | Follow RSS：订阅源／已读状态 |

**C. 系统级需谨慎的一项**

| 位置 | 体积 | 说明 |
|---|---|---|
| `/Library/PrivilegedHelperTools/com.dortania.opencore-legacy-patcher.privileged-helper` | 0.13 M | **原版 OCLP 的特权助手**；`/Applications` 只有 `OCLP-Mod` ⇒ 原版已卸。⚠️ 但 OCLP 与启动安全相关，**建议单独确认后再动** |

> 合计可清理量级：A 档 ≈ 17 MB（安全）；B 档 ≈ 398 MB（**含用户数据，需本人判断**）。
