# zbookpowerg7 黑苹果（HP ZBook Power G7 / OC **1.0.8-dev** / MacBookPro16,4 / macOS 26.6.2）
> **只放铁律与指针，细节一律外置。⚠️ 硬约束：本文被整篇注入，`wc -c` 上限 ~11,500 字节，超了尾部会被静默截断 ⇒ 新增须等量压缩别处。** ⚠️ 本文**不在版本控制**（`.workbuddy/` 被 gitignore）；快照 → `docs/memory-snapshots/`。
> 细节去处：`docs/sleep-tests/`（**README 顶部横幅=最新索引**）｜`docs/system-overhead-audit.md`｜`tier-ladder-why.md`、`s4-requirements-audit.md`｜`memory-archive-2026-09.md`｜`.workbuddy/memory/<日期>.md`。

## 铁律（每条都是实测代价换来的）
- **★「走废纸篓 = 可恢复」在本机不成立**：`mv` 进 `~/.Trash/…` **数分钟内被清空**（疑腾讯柠檬/Sensei）⇒ **删除固定顺序：① 先 `cp` 到 `docs/backups/` 存证 → ② 再删**。
- **★ 判「软件已卸载」有 5 条判据（存在性／活跃进程／文件级 mtime／内容语义／引用），缺一条即无效证据** → 清单见 skill **`macos-uninstall-residue-audit`**。
- **★ 核账只认「路径不存在」，严禁代理指标**：APFS 上 `df /` = **只读系统卷**，用户数据在 **`/System/Volumes/Data`**（删 4.86 GB 后 `df /` **同数**）。**计数类同样失效**（09-20）：`ls *.panic | wc -l` 恒为 **1**，但盘上那个已从 `…-09-17-114214` 换成 **`…-09-18-165628`（X86PlatformShim、开机 T+25 s、与睡眠无关）** ⇒ **必须逐个认文件＋读内容**。
- **★ 所有 SSDT 与 `ACPI/Patch` 必须做 `_OSI("Darwin")` 门控**（**OpenCore 打补丁不区分 OS**，会一并作用于 Windows）→ 见 skill **`hackintosh-acpi-os-gating`**、`docs/touchpad-os-gating.md`。（代价：`SSDT-TPD3-PIN` 漏门控把引脚强改成 258 ⇒ **Windows 触控板失灵**；**修法别写死数字**。09-20 复验：TPD3-PIN／DeepIdle／EC 三张均带 `_OSI`+`Darwin` ✅）
- **EFI 真源 = 工作区 `EFI/`（git）；ESP 只读**，FreeFileSync 镜像 `EFI/oc`→ESP。⚠️ `EFI/boot`、`EFI/scripts/` **不同步**；自动触发会滞后 ⇒ 改完**手动点「开始」**，两边 `shasum -a 256` 一致才重启。`EFI/oc/` 下**别放非必需 plist**。
- 凡"不可行／已生效／封板"**必须实测或上游文档查证并标来源**。
- **引导器/kext 版本：⚠️ 本机 `nvram 4D1FDA02-…:opencore-version` 不存在**（09-20 实测，`nvram -p` 正向对照通过、`OpenCore.efi` 只有占位符 `REL-XXX-YYYY-MM-DD`）⇒ **该 NVRAM 判据在本机失效**，退回来源记录/OC 日志。跑**开发版** ⇒ 判"是否已修"看 commit/changelog。
- `.workbuddy/` 删了不可逆；改 SSDT 前确认 DSDT 无同名对象。🚫 别用 `PlistBuddy` 改 plist（用 `plistlib` + `sort_keys=False` + `plutil -lint`）；🚫 同一文件别并行多个 Edit；`sudo` 无免密 ⇒ `osascript … with administrator privileges`。

## 配置要点
- boot-args：`-igfxblt -igfxhdmidivs igfxonln=1 igfxrpsc=1  -amfipassbeta -lilubetaall alctcsel=1 revpatch=sbvmm rtcfx_exclude=0E-FF -rtcfxdbg`（★ 09-20 按 **NVRAM 与 config 实测**改正：**没有** `-wegnoegpu`；`0E-FF` 而非 `80-FF`）
- `AppleXcpmCfgLock`=true｜`csr-active-config=0x0FFF`｜`ProcessorType=1793`｜`ScanPolicy` 不可限定｜**OTA 四件套** = RestrictEvents 1.1.7 + `revpatch=sbvmm` + Skip Board ID + `SecureBootModel=Disabled`
- ACPI 14 张、kext 30 个、DeviceProperties 8 条；磁盘 s1 ESP / s3 NTFS(Win) / s4 APFS / s5 exFAT；AX201（CNVi `Pci(0x14,0x3)`）；SSD = WD SN570 @ `Pci(0x1B,0x0)`。
- **RTC 四层防护必需**：`rtcfx_exclude=0E-FF`｜`AppleRtcRam=true`｜`rtc-blacklist 0x0E–0x73`｜`NVRAM/Delete`。⚠️ 实测"四层全开仍可报 HP POST 005"。**睡眠变量台账 = 0**。
- **真实 BIOS = `T75 Ver. 01.24.02` / 2026-05-11**（出处 = Win hive；旧记录 `S71` 错）⇒ 比 HP 基线 `01.22.00` 新 ⇒ **"固件老旧缺陷"不成立**。（⚠️ 校正：**回退策略其实允许**，不刷是因**没收益＋变砖风险**）

## ★ 睡眠：已封板（细节全在 `docs/sleep-tests/`）
- **三档终局**：**Deep Idle(S0ix) = ✅ 唯一可用**（唤醒 2.4 s、11 h 连睡零中断）｜**S3 = ❌ 实测坏**（EC 恢复后不响应：`AppleACPIEC EC OBF=1 poll timed out` 连绵 ⇒ PS2/SMBus 死等 ⇒ USB 栈 panic）｜**S4 = 🏁 不追**。⇒ **出远门直接关机。**
- **为什么只能 Deep Idle**：**L1 声明 ✅ / L2 选择 ✅ / L3 执行 ❌** —— 卡点在 **EC 固件**。撤 `SSDT-DeepIdle.dsl`（94 B，原厂 0 命中）即 `IOPMDeepIdleSupported` Yes→No、确实转 S3 ⇒ **EC 罢工**。**"半档"不存在**。
- **★ EC 罢工 ≠ EC 挂了**（09-20）：维修圈「EC 挂了」= 固件坏／连开机都不行／需编程器重烧 ❌；我们的「EC 不响应」= **状态性、冷启动即恢复** ✅（判据 = **能否正常开机**）。**"能修吗"四层答法** → skill **`macos-sleep-power-diagnosis` §4b-3d-2**。
- **★★「关 AOAC」= 正式封板**（→ `tier-ladder-why.md` 附录 A–G；台账 `firmware-facts-ledger.md` §8）：**① macOS 声明层**：撤 `\_SB.LPS0` **真跑过** ⇒ 转 S3 ⇒ EC 罢工。**② Win 声明层**：`PlatformAoAcOverride` **确认不存在**（12:0x 直接 `reg query`）；它是 **Windows 自己的键、对 macOS 零帮助** ⇒ **不做 Phase C**。**③ 固件菜单层**：BIOS 里没有；WMI 实测 **`Modern Standby`=`Enable`＋`DisplayInUI=0`＋`IsReadOnly=1`** ⇒ **"按名写"作废**（HP 官方 `SetBIOSSetting`/BCU 同此标志）⇒ **没入口**。`powercfg /a`：S1/S2 带「固件不支持」、**唯独 S3 没有** ⇒ S3=「声明了但被 AOAC 压住」，且出 S3 也只是**弱阳性**（"声明 ≠ 可用"已证）。**④ 魔改层**（附录 G）：无 IFR ⇒ `setup_var` 无偏移；`setuphide` 属 AMI；只剩「逆向＋签名＋物理刷」三闸，**终点已实测坏** ⇒ 不做。
- **★ 固件实锤**（SP169002 首查 ⇒ 09-20 用实跑版 01.24.02 复核）：`Modern Standby`＝正式 Setup 项（Enable/Disable、**三语 UI**）、help 自曝互斥；模块 `172 0147` 的 **ASCII 变量名表**含 `DeepS3`+`HpModernStandbyConfigurations`+`PowerControl`（平级）⇒ **互斥＝固件作者设计（AOAC-only 出厂）**；**无 IFR**（三判据全 0）。
- **★ EC = `34.31.00`**（⚠️ **别用 `Win32_BIOS` 的 `52/49`** ＝BCD `0x34/0x31` 当十进制读）⇒ **新规则：HP 出新 BIOS 包先比 EC 号，EC 号不变 ⇒ S3 不会好。**
- **★ 查"某 BIOS 设置的值／藏没藏"的固定路径**（12:0x 实测：**非管理员即可、无需装 HPCMSL、无需重启**）：Win 跑 `root/hp/InstrumentedBIOS` → `HP_BIOSSetting`（**258 项**，带 `DisplayInUI`/`IsReadOnly`）；提示词 `docs/windows-side-workbuddy-prompt.md`，全表存证见 `docs/backups/firmware-ledger-2026-09-20/win-side/`。
- 现役 **`hibernatemode 0` + `standby 0`**；**配置层已无牌**；**非用户唤醒源 = 0**（17 段普查）；**功耗真值 `6–11 %/h（≈4–7.5 W）`**（"11.2 %/h"=单样本）。工具 `tools/sleep-power-measure.sh`；⚠️ **不许 `pmset schedule wake`**（RTC 写 → POST 005）。
  - **合盖睡眠可行**（`Clamshell.app` 显式 `Software Sleep`）；⛔ 别动 `SSDT-LID-G7`。AC 上 `sleep 0`＋断言 ⇒ **永不自动睡**、空载 ~25 W（非故障）；**★ 断言持有者 = WorkBuddy 自己**（`NoIdleSleepAssertion` 自开机起未释放）⇒ **不用就退出它**，否则只能合盖。
- **ASPM 已撞墙**（26 条注入已移除），⚠️ 别再当"机会"。

## ★ 系统开销（→ `docs/system-overhead-audit.md`）
- **两卷 Spotlight 索引均关**（09-18）：**ESP** 4.1 M→20 K；**`/Volumes/Common`** 298 M→512 K；**跨重启持久**（09-20 复验 ✅）。回滚 `sudo mdutil -i on <卷>`。⚠️ **别删 `/<卷>/.Spotlight-V100`**（**卷级配置锚点**）。`/` 索引正常开着。
- **内存 16 GB = 真瓶颈**（09-20：swap **75%**、compressor 3.4 G、Swapins 34 万）。**可换：2×DDR4 SODIMM、上限 64 G**（`Upgradeable Memory: No` 是 OC 假字段）⇒ **唯一"花钱买确定性"方向（零黑苹果风险）**。
- **常驻（09-20 实测）**：`/Library` Daemons **20** + Agents **9**、`~` Agents **7**；实跑大户 = **aTrust 7 进程**（公司软件不可动）＋ToDesk 3＋腾讯柠檬 3 ⇒ **无重叠可清**。**第二个 M.2 槽空着**｜电池 `Cycle 131/Normal`。
- **`~` 下已无卸载残留可清**（09-18 清 4 项/4.86 GB，备份 `docs/backups/`）；其余大户均在用。

## ★ 判据纪律（血泪）
1. 判"能力不满足"前先问：**"这个观测在当前档位下本来就是预期行为吗？"** 要找「**配置已开 + 观测仍无**」。
2. 引用"**N 次实测全失败**"前，用 `git log -S "<键>" -- <配置>` 对齐当时配置 —— 缺桥/档位未生效那几次是**无效测试，必须剔掉**。
3. **移植社区配方前先查平台适用性**：读上游原文的**限定条件**。
4. **"固件声明了 + OS 选了" ≠ "能用"** ⇒ 判 L3 只能实测，判据是"**醒得回来且醒得正常**"。"唤醒慢/失败"要问"**哪个驱动在等谁**"。判"是否改配置改坏的"：先列混淆变量（`last reboot` 对齐 `git log`），再用**端口/驱动栈是否相交**做机制排除。**AOAC 类补丁成对，关一个必须关配套件。**
5. **查证三层（顺序固定）**：① 同作者父/邻页 ② 平台汇总仓库问题清单 ③ 用**症状原话**搜论坛；三层无先例才实测，实测前写清**预期形态 + 回滚点 + 是否有不可逆风险**。来源分级：`github.com/*`／远景／tonymacx86 = 判据；技术博客／QuickSpecs = 仅方向；**AI 内容农场 = 不可用**。
6. **★ 别把"同一层的两次实验"当"两条独立路径"**（09-18 栽过）：撤 `LPS0`(macOS) 与 `PlatformAoAcOverride=0`(Win) 同属 **OS 声明层** ⇒ 结果相同是**必然**，推不出固件层结论 —— 要证"固件层不行"**必须在固件层做**。

## 工具坑
**完整速查表 → `docs/tooling-gotchas.md`**。三条最常踩：
① **验 kext 真生效 = `ioreg -d 0 -l -w0` 的 `IOKitDiagnostics→Classes` 实例计数**（`ioreg -c 类名` 会给**相反**结论）；
② **BSD grep 不支持 `\s`/`\|`/`\b` ⇒ 一律 `grep -E`**（"0 命中" ≠ "不存在"，已栽两次）；
③ **Windows 注册表 hive 文件名是小写** `config/system`（大写 `SYSTEM` 报 `No such file`）；读法 = `strings -a`/`grep -a -c` 字节级检索，**必须先跑正向对照**再采信"0 命中"。
- 另：⚠️ **`/tmp` 重启即清**（09-20 实测：302 MB 固件 dump 全丢）⇒ 要留的产物一律落 `docs/backups/`；`log show` 需提权且必须缩窗（全窗扫被 SIGKILL）；`/var/vm` 空是假象（sleepimage 在 `/System/Volumes/VM`）；**沙箱拒 `ps`/`top`**（改 `pgrep -fl`／`lsof -p`／`launchctl list`）。
④ **★ `origin` 是公开仓库 ⇒ 回传产物入库前必须脱敏真机标识**（序列号／UUID／NVMe EUI／GPT GUID）→ `docs/tooling-gotchas.md` 末节。

## 状态
全功能机，diminishing returns。妥协：USB-C 仅 USB2／更新只能全量／SMCBattery 自旋锁／IGPU #967／beta boot-args／SIP 全关／电池 77%。**睡眠＝Deep Idle（~5 W，唤醒 2.4 s）**；**S3/S4 均判死**；**AOAC 已封板**。**panic 记账见铁律 ③**。**默认动作＝不改**。
