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
- [ ] **A-1 重启后复核**（09-18 11:19 已执行，并已通过"卸载→重挂"验证，见 §8）：下次重启后再跑一次 `mdutil -s /Volumes/ESP` 确认跨重启保持；若复活，说明要改用 launchd 挂钩在挂载后自动关

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
| 该 plist 的 `Options` | `{ConfigurationType: 'Default'}` | **仍是 `Default`** ⇒ 禁用状态**不**存在卷上这份文件里，而存在数据卷侧的中央配置（按 `ConfigurationVolumeUUID = 852A2DCE-…C59A` 索引） |

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

*本轮**唯一改动**：`mdutil -i off /Volumes/ESP`（系统级、一条命令可逆）。**EFI / pmset / config 零改动**，其余均为读取与落盘。回滚：`sudo mdutil -i on /Volumes/ESP`。*
