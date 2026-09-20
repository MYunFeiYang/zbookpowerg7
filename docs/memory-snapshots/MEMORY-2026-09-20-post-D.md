# zbookpowerg7 黑苹果（HP ZBook Power G7 / OC **1.0.8-dev** `REL-108-2026-09-16` / MacBookPro16,4 / macOS 26.6.2）
> **本文只放铁律与指针，细节一律外置。⚠️ 硬约束：本文被整篇注入，长度上限约 11.5 K 字符，超了尾部会被静默截断 —— 新增任何内容必须同时压缩别处。** ⚠️ `.workbuddy/` 被 gitignore ⇒ 本文件**不在版本控制**；精简前快照 → `docs/memory-snapshots/MEMORY-2026-09-20-post-D.md`。
> 细节去处：`docs/sleep-tests/`（**README 顶部横幅＝最新索引**）｜`docs/system-overhead-audit.md`｜`docs/sleep-tests/tier-ladder-why.md`、`s4-requirements-audit.md`｜`docs/touchpad-os-gating.md`｜`docs/macos-sleep-power-verification.md`｜`docs/memory-archive-2026-09.md`｜`.workbuddy/memory/<日期>.md`（逐日日志）。

## 铁律（每条都是实测代价换来的）
- **★「走废纸篓 = 可恢复」在本机不成立**：`mv` 进 `~/.Trash/…` **数分钟内被清空**（疑腾讯柠檬/Sensei）⇒ **删除固定顺序：① 先 `cp` 到 `docs/backups/` 存证 → ② 再删**。
- **★ 判「软件已卸载」有 5 条判据（存在性／活跃进程／文件级 mtime／内容语义／引用），缺一条即无效证据** → 完整清单＋实测代价见 skill **`macos-uninstall-residue-audit`**。血泪例（搜狗 948 M、深信服 365 M、`~/.qclaw` 等）与「**目录 mtime 不随子文件更新**」全在 skill 内。
- **★ 核账空间必须读 Data 卷**：APFS 上 `df /` = **只读系统卷**，用户数据在 **`/System/Volumes/Data`**。实测删 4.86 GB 后 `df /` **同一个数** ⇒ **"是否真删掉"只认「路径不存在」；严禁拿代理指标当判据。**
- **★ 所有 SSDT 与 `ACPI/Patch` 必须做 `_OSI("Darwin")` 门控**（**OpenCore 打补丁不区分 OS**，会一并作用于 Windows）→ 见 skill **`hackintosh-acpi-os-gating`** 与 `docs/touchpad-os-gating.md`。（代价：`SSDT-TPD3-PIN` 漏门控把 TPD3 中断引脚强改成 258 ⇒ **Windows 触控板失灵**；**修法不要写死数字**）
- **EFI 真源 = 工作区 `EFI/`（git）；ESP 只读**，FreeFileSync 镜像 `EFI/oc`→ESP。⚠️ `EFI/boot`、`EFI/scripts/` **不同步**；自动触发会滞后 ⇒ 改完**手动点「开始」**，两边 `shasum -a 256` 一致才重启。`EFI/oc/` 下**别放非必需 plist**。
- 凡"不可行／已生效／封板"**必须实测或上游文档查证并标来源**。
- **引导器/kext 版本以 NVRAM 为权威**（`nvram 4D1FDA02-…:opencore-version`）。本机跑**开发版**（OC 最新**正式版** = 1.0.7/2026-03-20，**无 1.0.8 发布**）⇒ 判"是否已修"必须落到 commit/changelog。
- `.workbuddy/` 删了不可逆；改 SSDT 前确认 DSDT 无同名对象。🚫 别用 `PlistBuddy` 改 plist（用 `plistlib` + `sort_keys=False` + `plutil -lint`）；🚫 同一文件别并行多个 Edit；`sudo` 无免密 ⇒ `osascript … with administrator privileges`。

## 配置要点
- boot-args：`-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1 -wegnoegpu -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=80-FF -rtcfxdbg`
- `AppleXcpmCfgLock`=true｜`csr-active-config=0x0FFF`｜`ProcessorType=1793`｜`ScanPolicy` 不可限定｜**OTA 四件套** = RestrictEvents 1.1.7 + `revpatch=sbvmm` + Skip Board ID + `SecureBootModel=Disabled`
- ACPI 14 张、kext 30 个、DeviceProperties 8 条；磁盘 s1 ESP / s3 NTFS(Win) / s4 APFS / s5 exFAT；AX201（CNVi `Pci(0x14,0x3)`）；SSD = WD SN570 1TB TLC @ `Pci(0x1B,0x0)`＝RP17。
- **RTC 四层防护必需**：`rtcfx_exclude=0E-FF`｜`AppleRtcRam=true`｜`rtc-blacklist 0x0E–0x73`｜`NVRAM/Delete`。⚠️ 实测"四层全开仍可报 HP POST 005"。**睡眠变量台账 = 0**。
- **真实 BIOS = `T75 Ver. 01.24.02` / 2026-05-11**（出处 = Win hive `…\Control\SystemInformation`；旧记录 `S71` 错）⇒ 比 HP 基线 `01.22.00` 还新 ⇒ **"固件老旧缺陷"不成立**（⚠️ 刷固件不可回退）。

## ★ 睡眠：已封板（细节全在 `docs/sleep-tests/`）
- **三档终局**：**Deep Idle(S0ix) = ✅ 唯一可用**（唤醒 2.4 s、**11.0 h 连睡零中断**）｜**S3 = ❌ 实测坏**（EC 恢复后不响应：`AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ USB 栈 panic）｜**S4 = 🏁 不追**。⇒ **出远门直接关机。**
- **为什么只能 Deep Idle**（`tier-ladder-why.md`）：**L1 声明 ✅ / L2 选择 ✅ / L3 执行 ❌** —— 卡点在 **EC 固件**，不是 OC 变量。撤 `SSDT-DeepIdle.dsl`（94 B，原厂 DSDT **0 命中**）即 `IOPMDeepIdleSupported` Yes→No、确实转 S3 ⇒ **EC 罢工**。**"半档"不存在**（细节见 `tier-ladder-why.md`）。
- **「关 AOAC」定案**（附录 A/A.6＋B＋C＋**D**）：① **OS 声明层**（唯一能碰的一层）：**macOS `\_SB.LPS0` 真跑过**（转 S3 ⇒ **EC 罢工**）｜**Win `PlatformAoAcOverride=0` 从未设过**（hive 字节级 0 命中＋正向对照通过）⇒ **"已关过且无效"只对 macOS 半场成立**，Win 那条**裁决性测试仍未做 = 当前最高优先级**（设键→重启→**只看** `powercfg /a`，零风险；出 S3 才睡，`reg delete` 还原）；② **固件菜单层**：BIOS 实拍**翻完、界面里没有** `Modern Standby`/`Deep sleep`（＝**隐藏而非灰化**：固件池顺序 `Extended Idle→Deep sleep→Modern Standby→Power Control` 对照实拍 **4/4 吻合、中间两组整段缺失**；HP 灰项本会照显＊。`Extended Idle Power States` 是 C-state，同族实测 *"was indeed a dud"*）；③ `powercfg /a` 落**中间态**（S1/S2 带「固件不支持」、**唯独 S3 没有**）⇒ S3="**声明了但被 AOAC 压住**"。**★ C/D 固件实锤（SP169002/01.23.00）**：`Modern Standby`＝**正式 Setup 项**（Enable/Disable、**三语 UI**），help 自曝互斥 *"Deep Sleep has been gray out because Modern Standby is set to On."*；**★ D 新证据（09-20）**＝模块 `171 0147` 内一张 **ASCII Setup 变量名表**，含 **`DeepS3`+`DeepS3Support`+`HpModernStandbyConfigurations`+`PowerControl`**（平级）⇒ **互斥＝固件作者的设计 ⇒ 厂商按 AOAC-only 出厂**（与上游 *"Systems that support Modern Standby do not use S1-S3"* 一致）；**无 IFR**（三判据全 0 ⇒ "解 IFR 拿偏移"已划掉）。⇒ **不赌不变，理由升级**（不是配置没调对，是设计如此）。
  - ＊同固件例：`Hyperthreading … grayed out because Deep sleep is set to On`（灰项照显）。**零风险动作只剩一条**：HP 官方只读 —— 商用机经 `root/HP/InstrumentedBIOS` WMI 暴露 BIOS **全部**设置（含隐藏项，带 `DisplayInUI`）：`Get-WmiObject -Namespace root/HP/InstrumentedBIOS -Class HP_BIOSSetting | Select Name,Value,DisplayInUI | Export-Csv C:\HPBIOS-all.csv`，**搜 `Modern Standby`/`DeepS3`/`PowerControl`**。（BIOS 界面找开关已划掉＝翻完没有。）离线链：SP169002→`UEFIExtract all`(macOS 版)→302 MB dump，清单存证 `docs/backups/bios-teardown-2026-09-18/`。
- 现役 **`hibernatemode 0` + `standby 0`**；**配置层已无牌**（省电侧开关全开）；**非用户唤醒源 = 0**（17 段普查）；**功耗真值 = `6–11 %/h（≈4–7.5 W）`**（"11.2 %/h"是 50 min 单样本）。工具 `tools/sleep-power-measure.sh`（只读）；⚠️ **不许用 `pmset schedule wake`**（RTC 写 → HP POST 005）。
  - **合盖睡眠可行**（`Clamshell.app` 显式 `Software Sleep`，不经 idle ⇒ 不被断言挡）；⛔ 别动 `SSDT-LID-G7`。AC 上 `sleep 0`+Electron 断言 ⇒ **永不自动睡**、空载 ~25 W（常驻软件叠加，**非电源故障**）⇒ **离开就合盖**。
- **ASPM 已撞墙**（26 条注入已移除），⚠️ 别再当"机会"。

## ★ 系统开销（→ `docs/system-overhead-audit.md`）
- **两卷 Spotlight 索引均关**（09-18 用户要求）：**ESP** 4.1 M→20 K；**`/Volumes/Common`（工作区盘）** 298 M→512 K；**跨重启持久**。回滚 `sudo mdutil -i on <卷>`。⚠️ **别删 `/<卷>/.Spotlight-V100`**（**卷级配置锚点**，删了会回落默认→重新索引）。
- **内存 16 GB 已吃紧**（swap 70%）。**HP QuickSpecs：2×DDR4 SODIMM、可更换、上限 64 GB** ⇒ `system_profiler` 的 `Upgradeable Memory: No` **是 OC 注入的假字段**。**唯一"花钱买确定性"方向（零黑苹果风险）。**
- **常驻**：第三方系统服务 22 + LaunchAgents 15（含**重叠成对**：ToDesk+向日葵、腾讯柠檬+CleanMyMac5）；**Sangfor 全家桶含系统扩展 ⇒ 公司软件不可动**。**第二个 M.2 槽空着**｜电池 `Cycle 131/Normal`。
- **`~` 下已无卸载残留可清**（09-18 清 4 项/4.86 GB，备份 `docs/backups/residue-uninstalled-2026-09-18/`）；剩余大户（`.nvm`/`.sdkman`/`.m2`/`.vscode`）均在用。

## ★ 判据纪律（血泪）
1. 判"能力不满足"前先问：**"这个观测在当前档位下本来就是预期行为吗？"** 要找「**配置已开 + 观测仍无**」。
2. 引用"**N 次实测全失败**"前，用 `git log -S "<键>" -- <配置>` 对齐当时配置 —— 缺桥/档位未生效那几次是**无效测试，必须剔掉**。
3. **移植社区配方前先查平台适用性**：读上游原文的**限定条件**。
4. **"固件声明了 + OS 选了" ≠ "能用"** ⇒ 判 L3 只能实测，判据是"**醒得回来且醒得正常**"。"唤醒慢/失败"要问"**哪个驱动在等谁**"。判"是否改配置改坏的"：先列混淆变量（`last reboot` 对齐 `git log`），再用**端口/驱动栈是否相交**做机制排除。**AOAC 类补丁成对，关一个必须关配套件。**
5. **查证三层（顺序固定）**：① 同作者父/邻页 ② 平台汇总仓库的问题清单 ③ 用**症状原话**搜论坛；三层无先例才实测，实测前写清**预期形态 + 回滚点 + 是否有不可逆风险**。来源分级：`github.com/*`／远景／tonymacx86 = 可当判据；技术博客／QuickSpecs = 仅方向；**AI 内容农场 = 不可用**。
6. **★ 别把"同一层的两次实验"当成"两条独立路径"**（09-18 栽过）：撤 `LPS0`(macOS) 与 `PlatformAoAcOverride=0`(Win) 都属 **OS 声明层** ⇒ 结果相同是**必然**，推不出固件层结论。要证明"固件层不行"**必须真的在固件层做**。

## 工具坑
**完整速查表 → `docs/tooling-gotchas.md`**（动手前扫一眼）。三条最常踩：
① **验 kext 真生效 = `ioreg -d 0 -l -w0` 的 `IOKitDiagnostics→Classes` 实例计数**（`ioreg -c 类名` 会给**相反**结论）；
② **BSD grep 不支持 `\s`/`\|`/`\b` ⇒ 一律 `grep -E`**（"0 命中" ≠ "不存在"，已栽两次）；
③ **Windows 注册表 hive 文件名是小写** `config/system`（大写 `SYSTEM` 报 `No such file`，曾据此误判"此路不通"）；读法 = `strings -a`/`grep -a -c` 字节级检索，**必须先跑正向对照**再采信"0 命中"。
- 另：`log show` 需提权且必须缩窗（全窗口扫描被 SIGKILL）；`/var/vm` 空是假象（sleepimage 在 `/System/Volumes/VM`）；ACPI 偏移速查见 `tooling-gotchas.md`。

## 状态
全功能机，diminishing returns。妥协：USB-C 仅 USB2／更新只能全量／SMCBattery 自旋锁／IGPU #967／beta boot-args／SIP 全关／电池 77%。**睡眠＝Deep Idle（~5 W，唤醒 2.4 s）**；**S3/S4 均判死**；**AOAC 定案＝现状即上游标准解**。panic 总数 = 1。**默认动作＝不改**。
