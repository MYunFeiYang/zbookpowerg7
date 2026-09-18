# zbookpowerg7 黑苹果（HP ZBook Power G7 / OC **1.0.8-dev** `REL-108-2026-09-16` / MacBookPro16,4 / macOS 26.6.2）
> **铁律 + 索引**（本文只放判据与指针，细节一律外置）。⚠️ `.workbuddy/` 被 gitignore ⇒ 本文件**不在版本控制**；精简前全文已快照 → `docs/memory-snapshots/MEMORY-2026-09-18-pre-trim.md`。
> 细节去处：`docs/sleep-tests/`（**README 顶部横幅＝最新索引**）｜`docs/macos-sleep-power-verification.md`｜`docs/memory-archive-2026-09.md`｜`docs/touchpad-os-gating.md`｜`docs/sleep-tests/{s4-requirements-audit,bios-facts,aspm-audit}.md`｜`.workbuddy/memory/<日期>.md`（逐日日志）。

## 铁律
- **★ 本机「走废纸篓 = 可恢复」不成立**（2026-09-18 实测）：`mv` 进 `~/.Trash/…` 后 **数分钟内被清空**
  （怀疑常驻的**腾讯柠檬 `LemonDaemon`/`LemonMonitor`**、`Sensei` 会清废纸篓）
  ⇒ **任何删除的正确顺序：① 先 `cp` 到 `docs/backups/` 存证 → ② 再删**，别依赖废纸篓暂存期。
- **判「某软件已卸载」前必须补全 app 的全部安装位置**：除 `/Applications`、`/System/Applications`、`~/Applications` 外，
  还有 **`/Library/Input Methods`（输入法！搜狗在这）**、`/Library/{PreferencePanes,QuickLook,Internet Plug-Ins,Screen Savers,Spotlight,Services,Extensions}`、
  `/Library/Audio/Plug-Ins/{HAL,Components}`；**并用「当前活跃进程名」做第二道交叉验证**。
  实测教训：只看 `/Applications` 会把搜狗输入法(948 M)、深信服 aTrust(365 M) 误判成孤儿。
- **★ 判残留还有两条判据（2026-09-18 清 A 档时暴露，前两条仍不够）**：
  **(3) 必须下钻到文件级 mtime** —— **目录 mtime 不随子文件更新**（`WeWorkMac` 顶层显 403 天前，子文件 3 天前刚写
  ⇒ 差点删掉**企业微信活动容器**）；**(4) CLI 工具的「家目录」不能靠 app/CLI 存在性判** ——
  `~/.qclaw`（**openclaw 家目录，股票系统核心**）、`~/.sclaw` 既无 `/Applications` app 也无 `command -v` 命中，
  **几乎被误判**；救回来靠**内容语义**。⇒ **凡 `~/.<name>` 内含 `*.json` 配置 + `workspace/`/`memory/`/`agents/` 类目录，一律先当活体。**
  另：可清项里若出现 `WorkBuddy.app/…/app.asar` 有引用的路径（如 `Application Support/CodeBuddyExtension`，
  内含当天 mtime 的 `Data/Public/auth`），**一律不动**。
  **(5) ★ shell 启动文件里的引用也是活引用**（2026-09-18 清隐藏目录时暴露）：`~/.zshrc`/`.zprofile`/`.bashrc`/`.bash_profile`
  里的 `export PATH=…`/`source …` 只要指向该目录就是用户主动装过的工具 —— `~/.costrict` 131 M 原判"可清"，
  实为 `~/.bashrc` 挂了 PATH 且 `bin/` 有 3 个真实 CLI（`costrict`/`codebase-indexer`/`cotun`）⇒ **保留**。
  ⇒ **"存在性判据"与"引用判据"必须两条都做，缺一条即无效证据**（上一轮只查 app/asar 就下结论，不完整）。
  另：CLI 工具常留**同前缀成对目录**（`~/.name` + `~/.name-venv`）⇒ 判活一起看、删后复查前缀（`ls -la ~ | grep`）。
- **★ 核账空间必须读 Data 卷**：APFS 上 `df /` = **只读系统卷**（本机固定 13 GiB used / 184 GiB avail），
  用户数据在 **`/System/Volumes/Data`**（`/dev/disk1s4`）。实测：删掉 4.86 GB 后 `df /` 前后**同一个数**，
  纯属读错卷 ⇒ **"是否真删掉"只能由"路径不存在"（`ls -d`/`du`）判定，空间读数仅参考**。别拿它当判据。
- **EFI 真源 = 工作区 `EFI/`（git）；ESP 只读**，FreeFileSync 镜像 `EFI/oc`→ESP。⚠️ `EFI/boot`、`EFI/scripts/` **不同步**；自动触发会滞后 ⇒ 改完**手动点「开始」**，两边 `shasum -a 256` 一致才重启。`EFI/oc/` 下**别放非必需 plist**（会被镜像进 ESP，`oldConfig.plist` 已实测中招，已移至 `docs/backups/`）。
- 凡"不可行／已生效／封板"**必须实测或上游文档查证并标来源**；**严禁拿代理指标当判据**。
- **引导器/kext 版本以 NVRAM 为权威**：`nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version`。本机跑的是**开发版**（OC 官方最新**正式版** = 1.0.7/2026-03-20，**无 1.0.8 发布**；RTCMemoryFixup 同理，官方最新正式版 1.0.7/2020-10-05）⇒ 文档写"OC 1.0.8"一律理解为 dev 构建，判"某问题是否已修"必须落到 commit/changelog。
- `.workbuddy/` 删了不可逆；改 SSDT 前确认 DSDT 无同名对象。
- **★ 所有 SSDT 与 `ACPI/Patch` 必须做 `_OSI("Darwin")` 门控** —— **OpenCore 打 ACPI 补丁不区分操作系统**，会一并作用于 Windows。实测代价：`SSDT-TPD3-PIN`（14 张表里唯一漏门控）把 TPD3 中断引脚强改成 258 ⇒ **Windows 触控板直接失灵**（09-18 已修：`TPNM` 非 Darwin 回落 `\_SB.GNUM(Arg0)`；14 张表中其余 13 张本来就已门控）。**09-18 14:05 实测双侧通过**：macOS 自验 `gpioPin=258`/驱动栈全载，Windows 用户确认恢复。⚠️ macOS 侧能自验、**Windows 侧读不到 ⇒ 只能采信用户实机回报，写文档必须标明来源**。判据/修法/验证 → `docs/touchpad-os-gating.md`。⚠️ 修法**不要写死数字**，要回落调用原厂方法。
- 🚫 别用 `PlistBuddy` 改 plist（用 `plistlib` + `sort_keys=False` + `plutil -lint`）；🚫 同一文件别并行多个 Edit；`sudo` 无免密 ⇒ `osascript … with administrator privileges`。

## 配置要点
- boot-args：`-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -wegnoegpu -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=80-FF -rtcfxdbg`
- `AppleXcpmCfgLock`=true｜`csr-active-config=0x0FFF`｜`ProcessorType=1793`｜`ScanPolicy` 不可限定｜**OTA 四件套** = RestrictEvents 1.1.7 + `revpatch=sbvmm` + Skip Board ID + `SecureBootModel=Disabled`
- ACPI 14 张、kext 30 个、DeviceProperties 8 条；磁盘 s1 ESP / s3 NTFS(Win) / s4 APFS / s5 exFAT；AX201（CNVi `Pci(0x14,0x3)`）；SSD = WD SN570 1TB TLC @ `Pci(0x1B,0x0)`＝RP17。
- **RTC 四层防护全部保留且必需**：`rtcfx_exclude=0E-FF`｜`AppleRtcRam=true`｜`rtc-blacklist 0x0E–0x73`｜`NVRAM/Delete`。⚠️ 实测"四层全开仍可报 HP POST 005"，别指望它兜底。**睡眠相关变量台账 = 0**。

## ★ 系统开销 / 内存（2026-09-18 新维度 → `docs/system-overhead-audit.md`）
- 睡眠方向已到头，但**日常开销与内存两处有实打实的空间**（此前六轮全在查睡眠档位，从没查过这两块）。
- **常驻**：第三方系统服务 22 个 + LaunchAgents 15 个。**功能重叠成对存在** —— 远程控制 **ToDesk(3 进程) + 向日葵 awesun(2)**；清理工具 **腾讯柠檬(3) + CleanMyMac5**。另有 Docker / Clash Verge(3) / 搜狗(3) / Google·Edge 更新器 / OCLP-Mod。
- **★ 两个卷的 Spotlight 索引均已关（09-18 11:19 / 11:35，用户要求）**：**ESP** 4.1 M → **20 K**（含"卸载→重挂"验证通过）；**`/Volumes/Common`（工作区所在盘！）** 298 M → **512 K**、可用空间 +298 MB、`mdfind` 已搜不到（直接路径/git/IDE 不受影响）。**09-18 14:05 重启后复核：两卷仍 `disabled`（根卷 `enabled` 作对照）⇒ 跨重启持久**。回滚 `sudo mdutil -i on <卷>`。⚠️ **别删 `/<卷>/.Spotlight-V100`**（剩的 20 K / 512 K 是**卷级配置锚点**，删了会回落默认→重新索引）；⚠️ **`diskutil mount` 必须提权**（裸跑 `failed to mount … try "readOnly"`）⇒ **卸载工作盘前务必先确认能挂回**（因此 Common 刻意不做卸载验证，属"高代价操作主动收手"）。⚠️ **禁用状态的存储位置未查明**（不在卷上 plist —— 关闭后 `Options` 仍 `Default`、`Stores` 记录仍在；也不在 `/System/Volumes/Data/.Spotlight-V100/` —— grep 卷 UUID 无匹配；`/var/db/Spotlight*` root 也 denied）。实证：**跨挂载持久、不依赖卷上文件**（长期 disabled 的 NTFS 卷无 `.Spotlight-V100`）。真凶 = **RealTimeSync 常驻**每轮同步改文件 mtime（**不是** `com.oc.mountesp`，它 `RunAtLoad` 无 WatchPaths，只在开机挂载一次）。
- **内存 16 GB 已吃紧**：`swap used 1426/2048 M = 70%`、free ≈136 MB、压缩页 626 万、wired 4.2 GB（⚠️ 开机 17 min 读数，非长期常态，待连续采样）。**HP 官方 QuickSpecs：2×DDR4 SODIMM、客户可更换、上限 64 GB** ⇒ `system_profiler` 的 `Upgradeable Memory: No` **是 OC 注入的假字段**。唯一"花钱买确定性"的方向（零黑苹果风险）。
- **CPU 告警锚点**：`/Library/Logs/DiagnosticReports/` 里 `WindowServer_2026-09-17-213618` 与 `apfsd_2026-09-17-214329` **各触发一次 50% CPU × 180 s 超限**（`ThermalPressure -> 0`，非热问题）。后续复发即观察点。
- **Sangfor 全家桶 10+ 进程，含 `endpoint_security` 系统扩展**（`com.sangfor.auem.sfservice.extension`）⇒ **公司软件，只能知情不可动**。同类：小米 `MiCamera`（cmio 扩展，enabled）。
- 硬件余量：**第二个 M.2 2280 槽空着**｜电池 `Cycle 131 / Normal / 5964 mAh`（很新）。

## ★ 睡眠：三档终局
- 🏁 **S4 真休眠 = 不追**（2026-09-18 定论）。三条腿全断：**先例**（同机型只到 "Sleep"＝即我们的 Deep Idle；同代 Fury G7 无 hibernation；AOAC 家族 0 先例；全球仅 4 台跑通且**全为 Legacy S3 世代**；Dortania 原文 *"avoid the black magic that is S4"*）｜**配方**（唯一公开配方 T530 三件套对本机 **0/3 适用**）｜**机制**（`s4-requirements-audit.md` 30 条中**真·没法满足仅 `#28`**「RTC 在断电期保持」，落在固件手里）。
- **"为什么只能 Deep Idle"一页纸 = `docs/sleep-tests/tier-ladder-why.md`**（2026-09-18）：**L1 声明层 ✅ / L2 选择层 ✅ / L3 执行层 ❌** —— 卡点在 **EC 固件**，不是 OpenCore 变量。L1 一手：`FACP FLAGS@0x70=0x002384A5`（bit21 AOAC=1 + bit20=0「完整 ACPI 与 AOAC 并存」）+ `DSDT _S3@38259/_S4@38270`、`SS3/SS4=One@5708`；L2 一手：`SSDT-DeepIdle.dsl` 仅 94 B（`LPS0`/`LXEN`，原厂 DSDT 里 **0 命中**=我们自己补的），撤掉即 `IOPMDeepIdleSupported` Yes→No。**"半档"不存在**：`mode 3` 电气形态=S3（只是多写 8–16 G 镜像）、`standby` 终点=S4（故 `standby 0` 是"不撞墙"）、C-state 属另一维度。新读数：`SystemPowerProfileOverrideDict` 里 `Hibernate Mode=3/Standby Enabled=1/delay=10800` vs 现役 `0/No`（疑似机型模板默认，**待确认**）。
- **「关掉 AOAC」三层开关（2026-09-18）**：**① OS 声明层**（macOS = `\_SB.LPS0`／Win = 注册表 `PlatformAoAcOverride=0`）**已关过且无效**（关完 macOS 确实转 S3 ⇒ EC 罢工）；**② 固件菜单层 = HP 没有**（官方《Power Management Options》全表 7 项无 `Modern Standby`/`S0ix`/`Sleep State`/`Low Power S0 Idle`；名字最像的 `Extended Idle Power States` 官方定义是 **C-state**，同族 ZBook 实测原文 *"was indeed a dud"*）；**③ 固件隐藏变量层**（UEFI Shell `setup_var_cv`，Dell 5410 先例）**从未试、HP 零先例、🔴 写错可致不开机**。**★ 赌注不对称**：代价=放弃**唯一可用**的 Deep Idle，目标=**已实测坏**的 S3 ⇒ 赌输**两头空**；上游把「禁止 S3」列为 AOAC 平台**标准解**＝我们现状。**上游微软侧口径**：*"Systems that support Modern Standby do not use S1-S3"*；MS 问答区**同形先例**（`PlatformAoAcOverride=0` ⇒ *"点击睡眠后无法唤醒"*）= 与 macOS"只能强制关机"同形。**下一步零风险判据 = Windows `powercfg /a`；没 S3 即彻底封板。**
- **S3 = ❌ 实测不可用，已回滚收手**（根因＝EC 在 S3 恢复后不响应：`AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ USB 栈 panic；`WakeTime` 2.4 s→159 s、PS2 460 ms→157,735 ms）。**Deep Idle(S0ix) = ✅ 唯一可用**：`IOPMDeepIdleSupported=Yes`，唤醒 2.4 s，**11.0 h 连睡零中途唤醒**（09-17 21:51→09-18 08:52）。**出远门直接关机。**
- 现役 **`hibernatemode 0` + `standby 0`**；`pmset-hibernate.sh` 已加硬闸（需 `FORCE_HIBERNATE=1`）。功耗地板 ≈5 W ≈7%/h（社区"未压降"区间）；**最大杠杆＝睡眠关 Wi-Fi/BT，用户已否决** ⇒ 剩余全是边角。
  - **★ 2026-09-18 复核：配置层已无牌**（`powernap/tcpkeepalive/womp/proximitywake/standby/hibernatemode/networkoversleep` 全在省电侧），
    **唤醒源非用户唤醒 = 0**（17 段睡眠普查）⇒ **可改项用尽，缺的只是"真值"**。
  - **★ "11.2 %/h" 不是单点真值，要写区间 `6–11 %/h（≈4–7.5 W）`**：round3 是 50 min 样本（瞬态混入；按"10 min@20 W+40 min@4 W"
    算出的平均正好 7.2 W 与实测吻合 ⇒ 稳态可能仅 ~4 W），且 `pmset Charge` 与 `ioreg mAh` 两口径**差近 2×**。
  - **★ 测量工具 `tools/sleep-power-measure.sh`**（只读）：`status` / `arm <标签>` / `report [--save]` ——
    自动出「时长/睡眠形态/唤醒原因/区间 DarkWake 数/WakeTime/ΔmAh→%/h→W」+ 双口径对照 + AC 守卫；
    数据落 `docs/sleep-tests/power-samples/arms.jsonl`。协议/三臂见 `docs/sleep-tests/round4-power-measurement.md`。
    ⚠️ **不许用 `pmset schedule wake` 自动唤醒**（RTC 写 → HP POST 005）。
  - **顺手观察**：AC 上 `sleep 0`（Apple 默认）+ Electron `NoIdleSleepAssertion` ⇒ 插电离开时**永不自动睡**、空载 ~25 W 一直烧 ⇒ 离开就合盖。
- **唯一未做实测 = B-1（`mode 3` 验写镜像），建议不做**：通过也只证"镜像能写"、后面仍撞 `#28` 固件墙；不通过只把"未验证"改写成"实测否定" —— 两条都不改结论，却要再赌一次 RTC 写入/`POST 005`。
- **合盖睡眠可行**：由 `Clamshell.app`（偏好 `whenClamshellIsClosed=sleep`）以显式 `Software Sleep` 发起，不经 idle 路径 ⇒ **不受 WorkBuddy `NoIdleSleepAssertion` 阻挡**（该断言只挡"空闲自动睡眠"）。⛔ 别动 `SSDT-LID-G7`。
- **真实 BIOS = `T75 Ver. 01.24.02` / 2026-05-11**（⚠️ 旧记录的 `S71` 是错的；出处在 Win 的 `Windows/System32/config/**system**` hive → `ControlSet001\Control\SystemInformation`）⇒ 比 HP 2026-03 公告的该机型基线 `01.22.00` **还新**，S4 照旧失败 ⇒ **"固件老旧缺陷"假设基本不成立**（唯一开口"刷 BIOS"基本关闭；⚠️ 刷固件不可回退）。
- **ASPM**：26 条 `pci-aspm-default` 注入已整批移除（`ebf6d5c`）；逐条审计 **23/26 天生无效**，真受影响仅 3 条（`PEG0`/`RP17`/`pci-bridge@1C`）；SSD 本体从未被注入（走 NVMeFix APST）。⚠️ 别再当"机会"，是已撞墙的路径（`7b0ab03` 误归因见 `docs/sleep-tests/README.md` §五十九）。

## ★ 判据纪律（血泪，已固化进 skill）
1. 判"能力不满足"前先问：「**这个观测在当前档位下本来就是预期行为吗？**」—— 拿"配置关着时的正常状态"证明能力缺失是无效证据；要找「**配置已开 + 观测仍无**」。
2. 引用"**N 次实测全失败**"前，用 `git log -S "<键>" -- <配置文件>` 对齐每次测试时配置是否齐备 —— 缺桥/档位未生效的那几次是**无效测试，必须从 N 里剔掉**。
3. **移植社区配方前先查平台适用性**：读上游原文的**限定条件**（OC 官方 Note 的硬件限定 / Dortania 同平台页的推荐值 / 原始 issue 的**症状限定词**）。
4. **"固件声明了 + OS 选了" ≠ "能用"** ⇒ 判 L3 只能实测，判据是"**醒得回来且醒得正常**"（同机 `WakeTime` / `Kernel Client Acks` 历史对照）。"唤醒慢/失败"别停在"谁叫醒的"，要问"**哪个驱动在等谁**"。判"是不是改配置改坏的"：先列混淆变量（`last reboot` 对齐 `git log`），再用**端口/驱动栈是否相交**做机制排除。**AOAC 类补丁成对，关一个必须关配套件。**
5. **查证三层（顺序固定）**：① 同作者父/邻页 ② 平台汇总仓库的问题清单 ③ 用**症状原话**搜论坛；三层无先例才实测，实测前写清**预期形态 + 回滚点 + 是否触发不可逆风险**。来源分级：`github.com/*`／远景／tonymacx86 = 可当判据；技术博客／QuickSpecs = 仅方向；**AI 内容农场 = 不可用**。

## 工具坑（选存）
🚫 `log show` 沙箱直连硬禁 ⇒ `osascript … with administrator privileges`；⚠️ **全窗口扫描被 SIGKILL(137)** ⇒ 必须 `--predicate` + 缩小窗口｜🚫 `dmesg` 读不到启动期（环缓冲被 IGPU 刷爆）｜★ **验 kext 真生效 = `ioreg -d 0 -l -w0` 的 `IOKitDiagnostics→Classes` 实例计数**（别用 `ioreg -c 类名`：hook-only kext 无节点，会给相反结论）｜⚠️ `ioreg -p IOACPIPlane/-p IOPCIDevice` 返回 0 行（路不通 ≠ 对象不存在）⇒ 查 PCI 用 `-c IOPCIDevice -t`，**PCI 地址→ACPI 名用 `"acpi-path"` 反查**（不需 Hackintool）｜⚠️ **`sleepimage`/`swapfile*` 在 VM 卷 `/System/Volumes/VM`，`/var/vm` 空是假象**｜⚠️ BSD grep 不支持 `\s`/`\|`/`\b` ⇒ 一律 `grep -E`｜⚠️ `log show --start/--end` 查旧窗口不可靠 ⇒ 旧窗口结论须复核时间戳｜`iasl -d` 会覆盖同名 `.dsl`；zsh glob 无匹配会中断｜⚠️ **Windows 分区注册表 hive 文件名是「小写」**：`Windows/System32/config/` 下是 `system` / `software`（**大写 `SYSTEM` 会 `No such file or directory`** —— 曾据此误判为"读注册表此路不通"，实际完全可读）；读法 = `strings -a` / `grep -a -c` 做**字节级键名检索**，但**必须先跑正向对照**（同 hive 内找一个必定存在的键名，如 `HiberbootEnabled`）再采信"0 命中"。
- FADT 偏移：`FLAGS`@**0x70(112)**、`PM1a_EVT_BLK`@**0x38**（0x24 是 `FIRMWARE_CTRL`）、`GPE0_BLK`@**0x50**｜本机 `FLAGS=0x002384A5`（`RTC_S4`=1、AOAC(bit21)=1、`HW_REDUCED_ACPI`=0）。

## 状态
全功能机，已到 diminishing returns。妥协：USB-C 仅 USB2／更新只能全量／SMCBattery 自旋锁／IGPU #967／beta boot-args／SIP 全关／电池 77%。**睡眠＝Deep Idle（~5 W，唤醒 2.4 s）**；**S3、S4 均已判死**。全机 panic 总数 = 1。EFI ≠ 理想但已达可用稳态；**默认动作＝不改**。
