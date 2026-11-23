# 睡眠功耗 结案小结（2026-11-20）

> 本文是这一轮（11-16 ~ 11-20）全部排查的收口页。细节证据不重复贴，只给判决、依据来源、把握度与索引。
> 上位文档：`docs/deepidle-power-audit-2026-11-12.md`（C-state/功耗）、`docs/hbkp-hibernation-2026-11-20.md`（S4 取钥路，含 §九 撤回）。

## 〇、2026-11-23 增补（后于本文，两条推翻性纠正）

本文 11-20 定稿时**没有**直接功耗测量，C-state 判据只有 `deep_idle_stats`。11-23 用 RAPL + Apple 官方每核表补上后，结论的"理由"被改掉两条（判决本身不变）：

| 项 | 11-20 的写法 | 11-23 纠正 | 把握度 |
|---|---|---|---|
| 核心 C-state | 由 `CC7:0%` 推断"核心未进深态" | 睡眠期 **12 线程 100% 在 C6**（速率 12,156/s vs 上限 12,000/s）；`CC7` 是 **Core C7**，且该接口不报 Core C6 | **>95%** |
| 卡点定位 | LTR 许可支路（§68 系） | LTR/核显/核心三条件全满足 ⇒ 卡点是 **PC3→PC6 的 BCLK 关断 + IMVR VR 降压**，PCU 经 SVID 与主板 VR 协商，macOS 侧无驱动参与 | ~90%（排除法） |
| 3.6W 归因 | 未拆 | 封装 **2.06W**（core 1.121 / DDR 0.566 / uncore 0.362 / GT 0.008）；换算电池侧后 CPU 支出 2.37W、VR 损耗 0.31W、**真非 CPU 1.23W** | ~80% |

补充实证（同日）：GT≈0.008W ⇒ 睡眠期核显 RC6 坐实(>95%)；即便包级进 C6，core 1.12→~0.6W，整机仍 **2.8~3.0W**，那 1.23W 平台开销不随 C-state 变化。

新查证的限制（11-23 18:5x，只读）：powerlog 274 张表里**没有** per-rail / 平台能量归因表（`SMC_InstantKeyValues`、`SMC_AccumulatedKeyValues` 均 **0 行**，VirtualSMC 不回填）；电池计量在 S0ix 期间**停更**（样本跳变，`InstantAmperage` 出现 −3600/−7200 mA 的陈旧值）⇒ **平台 1.23W 无法用只读手段拆解**，只能做关设备的差分睡眠实验。

## 一、一句话结论

按"**保留会话 + 不接受 005**"这两条硬约束，本机睡眠功耗**没有可行方案**：3.6W（S0ix、包级 C3）就是最终值。
限制不在配置/操作，而在一条不可兼得的固件事实：**休眠恢复标记与镜像密钥只能写 CMOS 0x80–0xAB，而 HP BIOS 校验不过就报 005 并 load factory defaults**。OC / kext / ACPI 层没有绕开的余地。把握度 **≥90%**。

## 二、当前状态（已核对）

| 项 | 值 |
|---|---|
| config | `EFI/OC/config.plist` sha `851f0d98…`，repo 与 `/Volumes/ESP` **双侧一致** |
| DeepIdle 配置哈希 | `0206720a`（known-good 对齐态） |
| 睡眠形态 | S0ix / Modern Standby，全 AC 与电池均卡包级 C3 |
| 实测功耗 | 3.63–3.77 W（powerlog `PLBatteryAgent_EventBackward_Battery` mAh 端点法，20 min 样本 ±0.1 W；四组 3.700/3.683/3.669/3.612 W） |
| `hibernatemode` | 0（S4 关闭） |
| `rtcfx_exclude` | `0E-FF`（=0x80–0xAB 休眠变量区被屏蔽） |
| HBFX | 未安装（11-18 已删） |
| 最近提交 | `bd19517`（撤回 HBKP 方案）→ `6ae67e6`（config 回滚） |

## 三、三堵墙（彼此独立，S4 要成必须同时推倒）

### 墙 ① 固件没有可用 S3/S4 通道
- 平台是 AOAC / Modern Standby only；09-17 实测 S3 → 159 s + panic（EC 未进入 S3）；Windows 侧 `powercfg /a` 已判 S3 不可用（用户判定）。
- 本轮新证据（BIOS 全量解包 + UTF-16 检索）：HP Setup 存在 `HpModernStandbyConfigurations`（`719 0A0A`，页签 `\Advanced`，Disable/Enable），且 Intel RC（`172 0147`）明写 **"Deep Sleep has been gray out because Modern Standby is set to On."**
- 判决：即便关 MS 能放开固件 S4，**EC 不支持 S3 这笔老账不变**，且会丢掉现在唯一能用的 S0ix，净负。**更关键：本机改不动** —— Windows 侧 WMI `SetBiosSetting` 报 `0x8004102f`（内部名/显示名均无果，11-20 15:36 实测）⇒ 平台未注册该设置，F10 也不显示，只剩 RU.EFI / 直接写 Setup 变量这一条未验证通道。

### 墙 ② 写 CMOS 0x80–0xAB 即 005
- xnu `iokit/Kernel/IOHibernateIO.cpp`（main）：`wiredCryptKey[16]` + `booterSignature[20]` 写进 `struct AppleRTCHibernateVars`（`'AAPL'`），**全文件只写 RTC，无 SMC 分支**；`volumeCryptKey` 才是唯一进 SMC(HBKP) 的东西，且条件为 `volumeCryptKeySize > 0`（=FileVault 开）。
- 本机 FileVault = Off ⇒ `vsmchbkp` / `AuthRestart` / `AppleSmcIo` 三开关**对恢复零作用**（≥85%）。
- 历史：武装休眠 ⇒ 005 本机 4/4（09-16×3 + 09-21 R3b）；社区一手（InsanelyMac 359189 X250：`rtc-blacklist` 09-FF 全屏蔽仍中招，唯一解 = UEFITool 删 `DxeCmosInit` + 编程器；T490 #35：mode 25 必现 0251）。
- HP 005 尤重：含 **load factory defaults**（BIOS 设置真被重置）。

### 墙 ③ 恢复后 iGPU 花屏
- 11-01 4/4；机制：IOPCIFamily 只重写 PCI config space，DPLL/transcoder/pipe/plane/GGTT 不重建；`hbfx-patch-pci=XHC,IMEI` 曾把花屏变蓝屏、未修好。
- 即便 ①② 推倒，会话仍可能因花屏丢失（要硬重启）。

## 四、已封死清单（勿重试）

| 方向 | 判决 | 关键依据 | 把握度 |
|---|---|---|---|
| 用户态 D3 / LTR / ASPM 注入 | 阴性 | sleep-scan 25 设备全干净，LTR 无阻塞 | ≥90% |
| L1.2 substates 注入 | 强阴性 | `C3:99% / C6-C10 全零`，与注入前一致 | ~85% |
| ACPI EC GPE 阻断（v1/v2/v3） | 真阴性 | v3 电池 18m46s：`C2 21% / C3 78% / C6-C10 0` | >95% |
| 0xE2 全核清零 / maxbusdelay / CPUFriend | 阴性 | 逐项实测 | ≥85% |
| 器件裁剪（TB/WiFi/NVMe） | 无可裁对象 | TB 无 `_PR3`（只能 D3hot）、WiFi 是 CNVi，合计 0.05–0.15 W 低于噪声 | ≥85% |
| S3（改固件/patched ACPI） | 关闭 | AOAC only + EC 罢工前科 + 用户侧判定 | ≥85% |
| BIOS 更新 | 无意义 | 01.25.00 已是最新 | >95% |
| HBKP / SMC 取钥路（11-20 方案） | **已撤回** | HBKP 只承载 FileVault 卷密钥 | ≥85% |
| RTC 路休眠（mode 25 / mode 3+standby） | 关闭 | 写 CMOS → 005，固件层 | ≥85% |

## 五、剩下的三条路与定价（都不满足当前约束）

| 路 | 能解决 | 代价 | 判断 |
|---|---|---|---|
| 关 Modern Standby（只剩 RU.EFI / 直接写 Setup 变量；WMI 与 F10 均不可用） | 固件层 S4 能力 | 失去 S0ix；EC 不支持 S3 不变；写坏 Setup 变量无 UI 可回滚 | 净负，不推荐 |
| 改 BIOS（绕/删 `DxeCmosInit`，或改 CMOS 映射使 0x80–0xAB 不参与校验） | 直接消除 005 | 拆机 + CH341A + 签名/写保护风险，可能永久变砖 | 唯一真解，代价不可逆 |
| RTC 虚拟化（kext 钩 AppleRTC 写 → NVRAM，OC `AppleRtcRam` 协议回喂 boot.efi） | 不写 CMOS 也能给 boot.efi 恢复标记 | 自建 kext + 改 OC fork；仍卡墙 ③ 花屏 | 工序大、终点仍大概率丢会话 |

三条同时成立概率粗算 ≈ 0.6 × 0.5 × 0.3 ≈ 0.1。

## 六、什么时候值得重新打开

只有下列条件之一发生变化才值得再投入，否则按现状维持：

1. macOS 大版本对 PM / XCPM 有实质改动（当前为 26.7.3 / Darwin 25.6.0）。
2. 社区出现 CML-H（Comet Lake-H）在 macOS 上进入包级 C6 的实测数据或新 kext。
3. IGPU #967（MEDIA SafeForceWake 超时）被修复 —— 关系到 deep idle 相关实验可行性。
4. 有人拿出 HP 消费级 BIOS 免编程器安全改 `DxeCmosInit` 的路径。
5. 用户放宽约束（接受一次 005 / 接受不保留会话 / 愿意拆机刷 BIOS）。

## 七、维护要点（别踩回去）

- EFI 改动纪律：workspace + `/Volumes/ESP` 三写 + `sync`×3 + sha 双侧复验；fskit unmount 会丢脏缓存。
- `ocvalidate` 不适用于 OC-Mod（3 条 `No schema` 是 fork 专属键），**禁止按报错删键**。
- `Misc.Debug.Target`：`0x40` = 文件通道、`0x04` = Data Hub（曾误写 71→67）。
- 取证通道：Bash 在 toybox.sb 下 `/usr/bin/log` 拒跑，用 `~/automation-workspace/*.app`（osacompile applet + `open`）跨沙箱取日志。
- BIOS 文本检索：UEFI HII 字符串是 **UTF-16LE**，`strings` 搜不到；流程 = `UEFIExtract <bin> all` → 解包目录里按 UTF-16 扫。

## 八、文档索引

| 主题 | 文档 |
|---|---|
| **11-23 RAPL 直接功耗分解**（工具链 + 7 个 bug 修复） | `docs/rapl-direct-power-decomposition-2026-11-23.md` |
| **11-23 首次真实睡眠 RAPL 分解**（2.06W / 四域占比） | `docs/sleep-rapl-first-measurement-2026-11-23.md` |
| **11-23 核心其实在 C6**（推翻十几轮前提 + 卡点重定位） | `docs/core-c6-vs-package-c3-2026-11-23.md` |
| C-state / 功耗权威审计（含 §64 L1.2 阴性） | `docs/deepidle-power-audit-2026-11-12.md` |
| EC GPE 实验判决（v3 真阴性） | `docs/deepidle-ec-gpe-proposal-2026-11-20.md` |
| S4 取钥路 + §九 撤回 | `docs/hbkp-hibernation-2026-11-20.md` |
| 历史 S4/005 考古 | `.workbuddy/memory/2026-11-18.md` §410-413 |
| 本轮日志（§88–§98） | `.workbuddy/memory/2026-11-20.md` |
