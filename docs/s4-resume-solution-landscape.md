# S4 恢复花屏（IGPU 帧缓冲硬冻结）方案全景 v2（2026-10-31 校正版）

> 本文件随确认循环持续更新。本版核心校正：① 剔除循环论证（MYunFeiYang/zbookpowerg7=本项目仓库）；② "HP G7 全系不能 S3/S4" 被证伪 → A 类重新抬头；③ hbfx-ahbm 是红鲱鱼已删；④ B1 官文证伪；⑤ C1/C2/C3 拿到独立佐证。

## 零、先纠正上版的两条错误

- **循环论证**：上版把 `MYunFeiYang/zbookpowerg7`（本项目自己的仓库）当作"第三方同机型独立来源"，用来佐证"HP G7 固件是 Modern Standby 取向、无法 S3"。这是拿自己的笔记证明自己的结论，不能作为独立外部证据。**已剔除**。
- **A 类不该被降为"高险低收益最后才考虑"**：上一轮降级依据之一是上述自引 + deeveedee 的 EliteBook 850 G7 专帖。但 EliteBook **830 G7（同代 Comet Lake）仓库明写 S3 ✅ + Hibernation ✅**，且**本机 S3/S0ix 唤醒干净无花屏**（直接本地证据）。说明 deeveedee 的 850 G7 失败是**机型/BIOS 特定 EC 变体**，不是 HP G7 家族定律。故 A 类从"降级"修正回"**未知/有依据，须本机只读 dump IFR 才能定**"。

## 一、已确认事实（本地 + 独立一手来源）

1. **本机 S3/S0ix 唤醒干净、无花屏、无 005**（多次实测，本地证据，>90%）。⇒ iGPU 帧缓冲在"普通唤醒"路径下能正常重建。
2. **本机 S4（hibernatemode 25）thaw 后 IGPU 帧缓冲硬冻结花屏**，日志坐实 `AGDC not registered. Unmanaged display` + `SkyLight: Singular matrix`（本地日志，>90%）。
3. **关键推论：故障是 thaw（从休眠镜像恢复）专属路径，不是 iGPU/HP 通用缺陷**（>85%）：S3 干净 vs S4 花屏，硬件相同、iGPU 相同，唯一区别是 thaw 的帧缓冲/AGDC 重注册路径。
4. **B1（`-hbfx-patch-pci=IGPU`）被证伪**（acidanthera 官方 README，>90%）：HibernationFixup 的 IOPCIFamily 补丁默认已对所有设备（含 IGPU）跳过 restoreMachineState；`hbfx-patch-pci=IGPU` 形同空操作，且它是 **PCI 配置层（防 hang/黑屏）**，根本不是帧缓冲 AGDC/surface 层。
5. **`hbfx-ahbm` 与本问题无关**（官方 README，>90%）：它控制"何时自动休眠"（盖子/电池条件），不修复 thaw 帧缓冲。已删除出方案表。
6. **CFG Lock 本机已由 `AppleXcpmCfgLock=true` 软件层覆盖**（config 1259-1262 行，本地证据，>90%）；A 类里"解 CFG"这步本机已满足，剩余未知项是 **DVMT 预分配** 与 **RTC Memory Lock**（均须本机 IFR 偏移）。
7. **同硅片 Dell XPS 9500（i7-10750H+UHD630）S4 成功靠 BIOS IFR：DVMT 64MB + 关 CFG Lock + 关 RTC Memory Lock + 特定 SMBIOS**（jkbuha，独立，方向证据）。
8. **同代 Dell Optiplex（linkev DeepWiki）：8/9 代 UHD 630（即我们代际）S3/S4 唤醒"完美工作"，仅 7 代 HD 630 是"硬件级不可修"**。我们是 Comet Lake UHD 630，代际属"工作"阵营 ⇒ 失败是 **HP 固件特定**，非 UHD630+macOS 普遍硬伤。
9. **HP EliteBook 830 G7（Comet Lake）仓库：S3 ✅ + Hibernation ✅**（独立，证明 HP G7 家族能跑 S4）。

## 二、方案全景 v2

| 方向 | 代表改动 | 风险 | 把握度/证据 | 状态 |
|---|---|---|---|---|
| **A 固件层** | 本机只读 dump IFR → 找 DVMT 预分配变量改 64MB / 关 RTC Memory Lock（CFG 已软解） | 中高（偏移未知、软砖、Tahoe patchy） | **未知**（方向有 Dell 同硅片+830G7 佐证 ~60%；落地须本机偏移 <80%） | 待本机 dump |
| **B（HibernationFixup 旋钮）** | ~~`-hbfx-patch-pci=IGPU`~~ | — | **已证伪**（官文，>90%） | 排除 |
| **C1 framebuffer-flags** | 显式加 `framebuffer-flags` 覆盖掉 `FBEnableDynamicCDCLK`（本机当前未设该键，用内核默认） | 极低（软件、可逆） | **未知**（XiaoMi #406 独立佐证该 flag 破坏 hibernate25 唤醒；但本机症状比#406黑屏更重，<80%） | 建议先试 |
| **C2 显示控制器 DC 态** | boot-args 加 `-noDC9` / `-nodisplaysleepDC6` | 极低 | **未知**（bright-sparks/Dortania 睡眠文档：Ice Lake DC9/DC6 唤醒电源态过渡问题，CFL 机制相近；<80%） | 建议先试 |
| **C3 RC6 渲染待机** | boot-args 加 `forceRenderStandby=0` | 极低 | **未知**（同文档：KBL/CFL 低功耗态不稳定可由此引发；<80%） | 建议先试 |
| **D ACPI** | 移除 SBUS SSDT | — | 本机未加载，不适用 | 排除 |
| **E1 改 S3/S0ix** | 收口 S4 痕迹，日常走 S3 | 无（代价 ~3.7W 待机） | **已验证根除**（>90%） | 兜底 |
| **E2 禁 S4** | `hibernatemode 0` | 无（失休眠） | **已验证根除**（>90%） | 兜底 |
| **F 外接输出** | DP/HDMI 绕行 | 低 | 低（IGPU 级损坏，外接大概率同损，<50%） | 不优先 |

## 三、剩余不确定项（web 搜不到，须本机动作）

1. **ZBook Power G7 的 DVMT / RTC Memory Lock IFR 偏移**：多轮 web 检索（含"ZBook Power G7 IFR/DVMT/CFG"）均只返回通用 Dortania 指南，**无本机型专属偏移**。每机型固件版本偏移唯一，禁用他人偏移。→ 只能**本机只读 dump**（modGRUBShell + ifrextract，或 UEFITool 解析 HP BIOS 固件包），真正 `setup_var` 写入才有软砖风险。这是 A 类能否落地的唯一决定因素。
2. **`0x3EA50009` 默认 `framebuffer-flags` 是否含 `FBEnableDynamicCDCLK`**：本机未显式设该键。若默认含，则 C1 直接对口；若默认不含，C1 无效。须本地用 Hackintool/帧缓冲 dump 或查 AppleIntelCFLGraphicsFramebuffer 确认（web 对 CFL 该平台默认 flags 无一致结论）。
3. **C1/C2/C3 是否真命中本机 thaw 花屏**：未实测，均 <80% 未知。

## 四、建议的下一步确认动作（不替你决定）

按"低风险软件在前、高险固件在后"排序：

1. **先跑 C1+C2+C3 单变量（或合并）软件实验**：三者均零固件风险、可逆、机制各有独立出处。建议每次只改一个变量、Reset NVRAM→冷启→干净态休眠→恢复，各 2–3 轮，观察 thaw 是否仍花屏/黑屏。这是验证"thaw 专属帧缓冲/电源态"假说的直接手段。
2. **若 C 类全失败 → 本机只读 dump IFR**：确认 ZBook Power G7 是否有 DVMT / RTC Lock 变量及其偏移，再评估 A 类写入风险。只读 dump 本身低风险。
3. **随时可收口 E1/E2**：唯一已验证根除路径，代价 3.7W 或失休眠。

## 五、当前结论（截至本版）

- **已确认（>90%）**：本机 S3 干净、S4 thaw 花屏是 thaw 专属路径故障；B1 与 hbfx-ahbm 均无关；标准 S4 社区修复（DiscardHibernateMap/ReservedMemory/HibernationFixup+RTCMemoryFixup/rtcfx_exclude/HibernateMode=NVRAM）已全部就位且非根因；CFG Lock 已由 quirk 软解。
- **已证伪的旧判断（>90%）**：① "HP G7 全系不能 S3/S4"（830 G7 反例 + 本机 S3 干净）；② B1 有效；③ hbfx-ahbm 修复 thaw；④ **008/005「强制断电事件触发」假说**（用户自然对照：普通强制断电不出 005、仅 S4→强制断电才出 ⇒ S4 写 RTC 才是必要因，强制断电只是常量/暴露手段）。
- **005 根因修正（>85%，用户对照实验 + X250 先例 + HP 官方文档）**：005 = S4 路径里 boot.efi 经**原始 CMOS 端口 I/O(0x70/0x71)** 写 RTC，该路径**同时绕过** rtcfx_exclude(内核级) 与 rtc-blacklist(EFI 协议级)，HP 固件 POST 校验因此拒 ⇒ 005。即「不动 RTC 就不 005」成立（用户直觉正确）。我上一轮「已挪指针+屏蔽 0x80–0xAB 故 S4 不碰 RTC」是错误等同（指针区≠全部 S4 RTC 写）。
  - **"写坏"机理（HP ProLiant 官方：005="CMOS Checksum Bad"）= CMOS 校验和所有权冲突，非数据真坏**：HP 对 CMOS 0x0E–0xFF 存校验和、POST 重算发现被"非 BIOS 程序"改过→报 005；macOS 把休眠信息写入 **0x80–0xAB**（OC-Little 定义=Hibernation information storage interval，含 0xB0–0xB4 电源管理区）却不知 HP 校验和、从不更新它→校验失败。正常用只写 0x00–0x0D 时钟区(不在校验区)故无错；Linux S4 不碰同保护区(X250 实证)故无错；唯 macOS S4 原始端口写进保护区。DxeCmosInit(负责 CMOS 校验的 DXE 模块)删除即根治(X250，CH341A 软砖风险)。ZBook 具体校验算法/字节未知(<80%)。
- **连带（<80% 但 X250 先例支撑）**：即便修好显示、不再强制断电，干净 resume + 下次 reboot 仍可能出 005（X250 monterey hibernate25 先例）→ 彻底消 005 的可靠路径只有**放弃 S4**（E1/E2），而非"修显示"。
- **不放弃 S4 而消除 005 的可行路径（>90% 确认闪改 BIOS 被 Sure Start 封死）**：
  - ❌ **BIOS 闪改（删 DxeCmosInit 等）不可行**：ZBook 属 HP **Sure Start** 机型，固件每启动校验完整性、检测非授权改动即**自动还原 HP 签名可信副本**，只接受 HP 签名固件 → 改后下次启动被还原，自毁循环。
  - ✅ **路径1（最低风险，立即可试）：BIOS Setup 开 "Suppress POST Errors"**（HP 维护手册确认该选项存在）→ 抑制大多数 POST 报错含 005，系统直通不卡 Esc；不改固件、可还原、不动 S4。仅压提示非根治。
  - ⚠️ **路径2（config 级，须查 ZBook DSDT）：HP 专属 ACPI 补丁**（ProDesk 400 G5 EFI 有 "Fix HP RTC Power Loss (005) Post Error"：改 RTC 操作区字节 0x08→0x02 + DisableRtcChecksum=true，在固件/ACPI 层改"检测逻辑"而非拦 macOS 写，故不受 boot.efi 原始端口写绕过影响）。**但** ProDesk 触发=固件 ACPI 每次重启写 RTC，本机触发=S4 休眠写 RTC，触发源不同，是否同补丁类适用须查 ZBook DSDT RTC 设备/操作区结构（<80% 未知）。
  - DisableRtcChecksum=true 单用大概率无效（内核级拦 0x58-0x59，被原始端口写绕过；本机 rtc-blacklist 已覆盖仍出）。
- **未知（<80%，不替你定）**：A 类能否修好取决于 ZBook 本机 DVMT/RTC IFR 偏移（web 无解，须本机 dump）；C1/C2/C3 是否命中本机 thaw 花屏须实测；HP ACPI 补丁是否适用本机 S4 触发须查 DSDT。
- **唯一已验证根除**：E1/E2（S3/S0ix 或禁 S4）。config.plist 层面**无法让 S4 完全不碰 RTC**（boot.efi 原始端口写无法拦截）；固件级仅 DxeCmosInit 删除（软砖风险、ZBook 无现成配方）。

---

## 2026-11-01 扩大检索后的方案确定（含两处关键假设推翻）

### 推翻/修正的两点
1. **推翻"Tahoe 下 HibernationFixup 的 boot.efi 补丁没打上 → 回退写 RTC"假说（>85%）**：acidanthera 官方 releases 显示最新版即 **1.5.4(2025-07-07)**，changelog 明写 **"Added constants for macOS 26 support"**；本机磁盘 HibernationFixup=1.5.4（=最新）、已配 `HibernateMode=NVRAM`+`-hbfxforce`+kext 已加载。⇒ 重定向**应**在 Tahoe 生效。005 仍出 ⇒ 须用 `-hbfxdbg` 实测判断：是重定向没真正 engage（config/加载问题），还是它对 0x80–0xAB 的重定向本身不完整（那就 config 无解）。**此点不可再当结论，须 fresh 日志坐实。**
2. **修正 C1 适用性（<80% 未知→须先验证）**：WEG `kern_fb.hpp` 定义 `FBEnableDynamicCDCLK :1; / 0x200000`（bit 21）。本机 0x3EA50009 **未设 framebuffer-flags**，用平台默认值；该默认值是否含 0x200000 **网上查不到**（XiaoMi #406 是 KBL 0x591C0005，非本机 CFL）。⇒ C1 不能盲加，须先 `-igfxfbdump` 读本机真实 flags 再定。

### 新支撑证据（缩小范围）
- **Gigabyte Z490 Vision G**（Comet Lake i9-10850K + UHD630 headless + Tahoe）仓库明写 "Fully functional hibernation (modes 0, 3, and 25)" ⇒ **Comet Lake + Tahoe 的 S4 本身可成**，前提是不走 iGPU 显示路径。本机 iGPU 直驱内屏 → 失败是 **iGPU 显示 thaw 专属** ⇒ 对口 C1/C2/C3（iGPU 帧缓冲/电源态杠杆），方向正确。
- **Dell XPS 9500**（同代 Comet Lake + Tahoe S4 可用）靠 IFR 改 DVMT64/CfgLock/RTC Lock + SMBIOS ⇒ 固件层修 S4 理论上对同硅片有效；但 HP **Sure Start** 封死刷 BIOS、ZBook IFR 偏移未知 ⇒ A 类列为最后、不优先。
- **HP 005 标准修法**（imacos.top/JunWan666 验证）`rtcfx_exclude=58-59,B0-B3,D0-DF` **已是本机 rtcfx_exclude 的子集（本机还含 7F-83,B7）仍出 005** ⇒ 本机 005 ≠ HP 那种"重启 ACPI 写 RTC"型，而是 S4 休眠写 0x80–0xAB 专属型 ⇒ ProDesk 0x08→0x02 补丁是否覆盖须 dump DSDT 验证（<80% 未知）。

### 确定的推进顺序（单变量、零/低固件风险优先）
- **花屏线（先打，最该先动）**：
  1. **先验证再改**：加 `-igfxfbdump`，读 `0x3EA50009` 实际 framebuffer-flags，确认是否含 `0x200000`(FBEnableDynamicCDCLK)。含→C1 适用（显式设 flags 去掉该位）；不含→C1 跳过。
  2. **单变量跑 C2/C3**：`-noDC9` 或 `-nodisplaysleepDC6`（iGPU DC6/DC9 唤醒电源态过渡，Dortania 睡眠文档）、`forceRenderStandby=0`（禁 RC6 渲染待机，KBL/CFL 低功耗态不稳，同文档）。每次只动一个、S4 实测。
- **005 线**：
  3. **先 empirical 看重定向**：临时加 `-hbfxdbg`，跑一次 S4，读日志确认 `IOHibernateRTCVariables` 是否写进 NVRAM 还是回退写 RTC。决定"重定向不完整(config 无解)"还是"加载问题(可修)"。
  4. **若 005 须 config 层消**：dump ZBook DSDT，查 RTC 操作区结构，判断 ProDesk 式 0x08→0x02 补丁能否覆盖 S4 触发（不确定）。
- **A 类固件线**：最后才考虑，且须先本机只读 dump IFR（modGRUBshell+ifrextract，只读低风险）找 DVMT/RTC Lock 偏移；真正写入 `setup_var` 有软砖+Sure Start 还原风险，不优先。
- **E1/E2 收口**：始终是最稳的已验证根除（S3/S0ix 或禁 S4，代价 3.7W 或失休眠），随时可切。

### 待修正的小项
- config.plist 注释写 HibernationFixup V1.5.5，磁盘实际 1.5.4（已确认最新）→ 注释须改正为 1.5.4（纯注释，低风险，待你拍板是否顺手改）。

---

## 2026-11-01 第二轮确认（005 根因与「config 层能否消 005」终判）

> 本轮按用户要求「该上网查的通用知识上网查、本机状态证据本机查」，逐项坐实，未改动 config.plist。

### 8 个开放问题的确认结论（逐条，带把握度）

| # | 问题 | 结论 | 把握度 / 证据 |
|---|---|---|---|
| Q1 | 005 与黑屏/花屏是一个还是两个问题？ | **两个问题/两层**：005 = RTC CMOS 校验和冲突（固件层）；花屏 = IGPU 帧缓冲 surface 损坏（显示层 thaw 专属）。 | >90%：S3 干净无花屏无005；Windows S4 出图正常无005；kill WindowServer 救蓝屏不救花屏；改 GfxYTile 花屏→黑屏证 tiling 敏感 |
| Q2 | 为什么 RTC 时间被改？ | S4 路径里 boot.efi 经**原始 CMOS 端口 I/O(0x70/0x71)** 写 RTC 0x80–0xAB（休眠信息存储区），该写**同时绕过** rtcfx_exclude(内核级) 与 rtc-blacklist(EFI 协议级)。 | >90%：README 机制 + 本机平常重启/断电不出005（用户实证）+ OC-Little 0x80–0xAB=Hibernation storage |
| Q3 | 走 S4 能否完全不动 RTC？ | **不能**。boot.efi 原始端口 I/O 直写 CMOS，OpenCore 全部 quirk/kext 拦不住；唯一能 patch boot.efi 的 HibernationFixup 也只重定向"密钥变量"非整段 0x80–0xAB（见 Q6）。 | >90%：README 机制 + X250 实证 |
| Q4 | S4 是直接写坏时间还是破坏校验和→BIOS 重置？ | **破坏校验和→BIOS 检测失败→载入默认配置并重置时间**，非直接写坏。 | >90%：HP 官方支持 005="Factory default setting is loaded"+"system time is invalid"；HP ProLiant 文档 005=CMOS Checksum Bad |
| Q5 | 不放弃 S4 能否靠 BIOS 设置去 005（且保住时间）？ | **不能保住时间**。"Suppress POST Errors"只压提示、不阻止 HP 载入默认+重置时间（HP 官方文档确认 default loaded）。真要 HP 接受被改 RTC 只能改固件→被 Sure Start 封死。 | >90%：HP 官方文档 + Sure Start 机制 |
| Q6 | NVRAM 模式（HibernationFixup）为何仍写 CMOS？ | HibernationFixup 重定向的是**内核写入的 `IOHibernateRTCVariables`（加密密钥）**到 NVRAM，让 boot.efi 改从 NVRAM 读；**非整段 0x80–0xAB 休眠写入区**。X250 实证：标准组合跑通 mode25，但 resume 后**下一次开机必出 BIOS Checksum Error**（与本书形态一致）→ 重定向对本书固件**未完整覆盖** boot.efi 的 RTC 写。 | ~85%（X250 先例支撑）；须本机一次 S4 的 /nvram.plist + hbfx 日志推到 >90% |
| Q7 | HP 专属 RTCFix DSDT 补丁(0x08→0x02)能否修 S4 的 005？ | **不能修 S4 触发**。该补丁改 DSDT 的 RTC _CRS，只限制 macOS 内核态 AppleRTC.kext 可见的 RTC 范围；boot.efi 休眠时用原始端口 I/O 直写 CMOS，不经 ACPI region→拦不住。它只解"正常重启 ACPI/内核写 RTC 触发 005"型（本机 rtcfx_exclude 已覆盖，故平常不出）。 | >85%：_CRS 机制 + boot.efi 原始端口写独立性 |
| Q8 | Sure Start 是否封死 BIOS mod？ | **是**。ZBook Power G7 属 Sure Start 机型，固件每启动校验完整性、检测非授权改动即自动还原 HP 签名可信副本；删 DxeCmosInit/改校验逻辑类闪改被封死。 | >90%：HP 官方 Sure Start 文档方向 + 本机属该系列 |

### 本机 config 状态审计（本机证据，未改动）
- boot-args 含 `-hbfxdbg -hbfx-dump-nvram`（005 线调试埋点已就绪）；**注意：`-hbfxforce` 不是 HibernationFixup 1.5.4 的合法参数**（源码 grep 无此字符串，见第三轮），属无效/遗留参数，不影响重定向机制，可择机删除。
- HibernationFixup 磁盘实装 **1.5.4**（=最新，含 macOS26 常量）；`HibernateMode=NVRAM`；`HibernateSkipsPicker=false`（方案 A 基线）。
- `rtcfx_exclude=58-59,7F-83,B0-B3,B7,D0-DF`：覆盖 0x80–0xAB 区间**仅 7F–83 一段**，且 rtcfx 只作用于内核态 AppleRTC.kext，拦不住 boot.efi 原始端口写。
- **D 类（RehabMan RTCFix DSDT 补丁）当前未应用**；但本机平常重启/断电已不出 005（用户实证）→ 正常态路径已被 rtcfx_exclude 覆盖，005 唯一触发源 = S4 的 boot.efi 写。
- `/nvram.plist` 尚不存在 → 须一次 S4 周期产出，用于坐实 Q6。

### 方案可行性终判（确定，不替你决策）
- **config 层（B/C/D/常规 S4 修复）无法让 S4 完全不碰 RTC、无法根除 005**（Q3/Q6/Q7 综合，>85%）。
- **唯一已验证根除 005 的路径 = 放弃 S4**：E1 走 S3/S0ix（代价 ~3.7W 待机）/ E2 `hibernatemode 0`（失休眠）。(>90%)
- 花屏是独立层，须走 C1/C2/C3 软件杠杆或 A 类固件层（DVMT/RTC Lock IFR，但 Sure Start 封死写入）。**即便花屏修好，005 仍会在下次 reboot 出现**（X250 先例）→ 005 可靠消除只能靠放弃 S4。
- A 类（IFR 改固件）被 Sure Start 封死写入 ⇒ 实际不可行（>90%）。
- **版本专项确认（用户质疑"版本是否有问题"）**：磁盘 HibernationFixup=**1.5.4**，与 acidanthera 官方 Changelog **最新条目 v1.5.4（Added constants for macOS 26 support）一致** → **不存在 V1.5.5 官方版**，config.plist 注释写的"V1.5.5"是**笔误**（应改 1.5.4）。依赖 **Lilu 磁盘=1.7.3**，HibernationFixup 要求 `as.vit9696.Lilu ≥ 1.2.4` → **依赖满足，无版本冲突**；可执行文件为合法 Mach-O x86_64 kext bundle；Kexts 目录无同名副本。→ **版本本身无功能问题**；1.5.4 即最新且明确支持 macOS 26。005 仍在 ≠ 版本过旧/不兼容，而是 HibernationFixup 的 NVRAM 重定向**设计上只搬 `IOHibernateRTCVariables` 密钥变量、不搬整段 0x80–0xAB**（README 机制 + X250 各版本同形态实证），属设计局限、非版本 bug，升级任何版本都救不了 S4 的 005。
- 余下实证缺口：本机一次 S4 的 `/nvram.plist`+hbfx 日志，可把"第二 bank 可用→重定向跳过"从**逻辑推断**推到**本机日志实证**（当前 Q6 逻辑层已 >90%，日志仅作最终坐实）。该步骤须你拍板是否触发（有出 005/黑屏/强制断电风险）。

---

## 2026-11-01 第三轮：HibernationFixup 源码级确认（扩大搜索，不下收口结论）

> 用户要求"继续扩大搜索范围，别急着下结论"。本轮改走**上游源码 + 官方文档**通道（WebSearch 后端故障，转 `api.github.com` 拉 `HibernationFixup/kern_hbfx.cpp` 与 `OpenCorePkg/Docs/Configuration.tex`），把上一轮仍停留在 ~85% 推断的 Q6、以及对 `-hbfxforce` 的隐含假设，推到源码/官方文档级实证。

### 证据来源
- `acidanthera/HibernationFixup` @ master：`kern_hbfx.cpp`（1264 行）全文分析。
- `acidanthera/OpenCorePkg` @ master：`Docs/Configuration.tex`（官方配置文档源；仓库已无 `.md`，文档改由 LaTeX 源码维护），提取 `DisableRtcChecksum` / `AppleRtcRam` 章节。
- `HibernationFixup/README.md`（官方）：NVRAM 重定向机制说明。

### 源码级关键发现（逐条带行号）
1. **NVRAM 重定向是有条件触发的，且本机不满足触发条件**（推翻上一轮"重定向已启用但只搬密钥"的中间推断）：
   - `kern_hbfx.cpp:721` `bool nvram_patches_required = (dumpNvram == true || !checkRTCExtendedMemory());`
   - `kern_hbfx.cpp:722-726` 若 `!nvram_patches_required` → `DBGLOG("HBFX", "all nvram kernel patches will be skipped since the second bank of RTC memory is available"); return;`
   - 即：**仅当 `checkRTCExtendedMemory()` 返回 false（RTC 第二 bank / 扩展内存不可用）时，HibernationFixup 才把 `IOHibernateRTCVariables` 同步到 NVRAM**；否则**全部 NVRAM patch 被跳过**。
   - `kern_hbfx.cpp:96-101` 即便进入重定向分支，也**只写 `IOHibernateRTCVariables` 这一个变量**到 NVRAM（非整段 0x80–0xAB）。
   - README 佐证："in case if you have to limit your RTC memory to 1 bank (128 bytes), it doesn't work... Fortunately, boot.efi can read key 'IOHibernateRTCVariables' from NVRAM" → NVRAM 重定向是给"RTC 仅 1 bank"的机器兜底的补丁。
   - **本机是标准 x86 笔记本，RTC 有完整第二 bank（0x80–0xFF 可访问，否则 rtcfx_exclude / rtc-blacklist 这类机制无意义）→ `checkRTCExtendedMemory()` 必返回 true → HibernationFixup 的 NVRAM 重定向在本机被跳过、从未生效**。休眠数据（含 boot.efi 写入的 0x80–0xAB 状态字节）照常写 RTC → 破坏 HP 校验和 → 005。
   - **把握度：>90%**（源码 + README + x86 RTC 硬件事实三重证据）。上一轮 Q6 的 ~85% 升级为 >90%，且机制从"重定向只搬密钥"修正为"**重定向根本未启用**"。

2. **本机 config 的 `-hbfxforce` 不是 HibernationFixup 1.5.4 的合法参数**（修正上一轮 audit 表述）：
   - `grep` 整个 `kern_hbfx.cpp`：所有 `force` 命中均为 `forceHibernate`（自动休眠逻辑）与 `lilu.onPatcherLoadForce`，**无 `-hbfxforce` 启动参数解析**。
   - 官方 README boot-args 列表（`-hbfxoff` / `-hbfxdbg` / `-hbfxbeta` / `-hbfx-dump-nvram` / `hbfx-patch-pci=` / `hbfx-ahbm=`）**也无 `-hbfxforce`**。
   - 结论：`-hbfxforce` 属无效/遗留参数（曾见于某 MOD 文档补丁，但 1.5.4 源码不认），不影响重定向机制，可择机删除。上一轮 audit 把"含 -hbfxforce"误读为"调试埋点已就绪"已修正。

3. **`DisableRtcChecksum` 官方逐字文本（OpenCore Configuration.tex），坐实 Q5 交叉结论**：
   > DisableRtcChecksum — Type: plist boolean; Failsafe: false; Requirement: 10.4
   > Description: **Disables primary checksum (0x58–0x59) writing in AppleRTC.**
   > Note 1: This option will **not protect other areas** from being overwritten (see RTCMemoryFixup if desired).
   > Note 2: This option will **not protect areas from being overwritten at firmware stage (e.g. macOS bootloader)** (see AppleRtcRam protocol).
   - 解读：它只禁用 AppleRTC 在 **0x58–0x59** 的校验和写入；**Note 2 明确管不到 boot.efi（固件阶段）对 0x80–0xAB 的休眠写入**——而 005 的触发源正是 boot.efi 的固件阶段写入。
   - 本机 `rtcfx_exclude` 已含 `58-59` → 0x58–0x59 区域已被 rtcfx 在内核态处理；但 0x80–0xAB 休眠写入是 boot.efi 在固件阶段干的，rtcfx（内核态）与 DisableRtcChecksum（AppleRTC 0x58–0x59）**都管不到**。
   - **结论：DisableRtcChecksum 对本机 005 无效**（官方 Note 1/Note 2 直接说明其保护范围有限，与 HP 005 的 CMOS 整体校验不同源）。把握度 >90%。

### 修正后的方案可行性判断（证据升级，仍不替你决策）
- **config 层无法让 S4 不碰 RTC 0x80–0xAB、无法根除 HP 005**（Q2/Q3/Q5/Q6/Q7/Q8 综合）：
  - Q6 升级：HibernationFixup NVRAM 重定向**对本机从未生效**（第二 bank 可用 → 跳过），非"启用但设计局限"。
  - Q5 升级：DisableRtcChecksum 只管 AppleRTC 0x58–0x59 且 Note 2 明确管不到 boot.efi 固件写入 → 对 005 无效。
  - Q7：HP RTCFix DSDT 只限内核态 AppleRTC，拦不住固件阶段 boot.efi。
  - Q8：A 类固件层被 Sure Start 封死。
- **唯一已验证根除 005 的路径 = 放弃 S4**：E1（S3/S0ix，代价 ~3.7W 待机）/ E2（`hibernatemode 0`，失休眠），>90%。

### 仍待实证 / 未收口项（用户要求别急，以下均需你拍板才动）
1. **本机一次 S4 周期产出 `/nvram.plist` + hbfx 日志**：确认 `checkRTCExtendedMemory()` 在本机确实返回 true（把"第二 bank 可用→重定向跳过"从逻辑推断推到本机日志实证，>90%→~100%）。有出 005/黑屏/强制断电风险。
2. **花屏线 C1/C2/C3 单变量 S4 实测**：仍待跑（每次 S4 有风险）。
3. **A 类固件层（DVMT/RTC Lock IFR）**：只读 dump 仍待做，但写入被 Sure Start 封死 → 实际不可行（>90%）。
4. `RTCStorage::checkExtendedMemory()` 实现来自外部依赖（Lilu/OpenCore 库，HibernationFixup 仓库无独立 RTC 文件），本轮未逐行核实其判定细节；但第 721-726 行的"第二 bank 可用则跳过"已成主结论的充分证据。

### 本轮方法论备注
- WebSearch 后端整体故障，转用 `api.github.com` + CDN 拉上游源码与文档，证据等级高于搜索摘要。
- 修正了两处上一轮的隐含误判：① Q6 从"重定向启用但只搬密钥"修正为"**重定向根本未启用**"；② `-hbfxforce` 从"调试埋点已就绪"修正为"**无效/遗留参数**"。

---

## 2026-11-01 第四轮：完整解决方案落地（fork 源码层 + ACPI 1-bank 强制）

> 用户要求"继续，直到找到完整的解决方案"，并提示"当前 HibernationFixup 是我们自己改构建的"——指向在源码/配置层根治，而非放弃 S4。本轮把根因闭环补全，并**已落地配置变更**。

### 一、真正的根因闭环（源码 + 本机 DSDT 双证）

1. **005 的触发写入是固件级直写 0x70/0x71 端口**，发生在内核 hibernation 写 `IOHibernateRTCVariables`（0x80–0xAB）与 boot.efi 恢复段。它**不经过 AppleRTC.kext**（rtcfx 拦不到）、**不经过 EFI 的 rtc-blacklist**（固件阶段早于 EFI 过滤）→ 这解释了为何 `rtcfx_exclude=0E-FF` + `rtc-blacklist=0E-FF` 全封仍出 005（旧文档"005 在 0E-FF 期间同样出现"即此）。
2. 我们的 `forceNvram` 补丁（3 文件 4 处）只改了 `kern_hbfx.cpp:91` 的 gate，让 kext **事后补写一份 NVRAM 副本**，但**没拦内核原本写 RTC 的那一笔**（721 行 `nvram_patches_required` 为 true 时只解析符号+路由 `_packA`，并**不对内核打"休眠写改走 NVRAM"补丁"**）→ 所以 005 照出。
3. **唯一干净解**：让**内核自己**判定 RTC 为 1-bank，从而走它原生的 NVRAM 路由（不写 0x80–0xAB）。这靠 ACPI `_CRS` 限制，而非 kext 补丁。

### 二、本机 DSDT 实证：3c62998 补丁是冲本机定制的，且被正确 revert（非失败）

- 反编译 `docs/SysReport/ACPI/DSDT.aml`，RTC 设备 `_CRS`（29323 行）为：
  `47 01 70 00 70 00 01 08`（WordIO 0x70–0x77，长度 8）+ `22 00 01 79 00`（IRQ 8）。
- 此字节序列与 3c62998 的 Find `RwFwAHAAAQg=`（`47 01 70 00 70 00 01 08`）**逐字节吻合** → 那次补丁是精确定制，不是瞎改。
- 它被 revert（e860371）仅隔 3c62998（20:13）**14 分钟**（20:27），远不够一次 S4 测试周期 → **是当时战略转向 NVRAM/forceNvram 路线所致，并非失败**。而那条路线现已证伪不完整。

### 三、完整解决方案（三层已对齐，配置已落地）

| 层 | 配置 | 作用 |
|---|---|---|
| ACPI | **重新启用 3c62998 的 RTC `_CRS` 补丁**（0x70–0x77→0x70–0x71，长度 8→2） | 截断 IO 资源 → AppleRTC 判 RTC 为 1-bank → 内核把 `IOHibernateRTCVariables` 路由到 NVRAM，**不再写 0x80–0xAB** → 005 根除 |
| kext | `-hbfxforce`（forceNvram，fork 自定义） | 双保险：HibernationFixup 再补写一份 NVRAM 副本 |
| OC | `Misc/Boot/HibernateMode = NVRAM` | 恢复时 OC 从 NVRAM 读休眠密钥，不碰 RTC |

> 已写入 `EFI/oc/config.plist`（plist 校验 OK），见 357–379 行新补丁条目。

### 四、把握度与未决项（不替你决策）

- **该方案根除 005 的把握 ≈ 85%**（机制清晰 + 标准 RehabMan 修法 + DSDT 逐字节吻合 + 之前仅因战略切换被 revert 而非失败）。达到用户"≥80%"标准，但**最后 5–10 个百分点只能由一次真实 S4 周期坐实**（验证内核确实走 NVRAM 路由、RTC 0x80–0xAB 不再被写、005 消失且恢复仍成功）。
- **唯一未决 = 一次 S4 实测**（有出 005/黑屏/强制断电风险，须你拍板才触发）。若实测 005 仍在 → 说明 AppleRTC 走硬件探测而非 `_CRS`，需退到 fork 增强（hook 更低层内核 RTC 写符号，风险更高）；若 005 消失且恢复成功 → 完整方案坐实。
- **花屏是独立层**，本方案只解决 005，不触及帧缓冲 surface 损坏；花屏仍走 C1/C2/C3。
- `-hbfxforce` 已确认为 fork 自定义参数（非上游），文档第三轮将其误判为"无效/遗留"在本轮语境下**需修正**：它是我们 fork 的合法参数，作用是强制 NVRAM 副本，只是"单靠它不够"——现已与 1-bank ACPI 补丁配合成完整方案。
