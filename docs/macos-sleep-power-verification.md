# 睡眠功耗复核报告（2026-09-15 首轮 / 09-16 二轮 / **09-16 三轮修正**）

> 起因：用户问「再确认一下吧？」，并授权「不局限于某一种睡眠方式，只要硬件支持都可以尝试」。
> 结论先行：**上一轮「档内已穷尽、没法优化」的结论需要收窄**——档内确实穷尽了，
> 但**深睡档本身是被我们自己的脚本主动关掉的**，而不是硬件不支持。现有 3 条可试路径。
>
> **09-16 二轮追加**（用户确认「5W 是合盖测的」）：拿到最近一次睡眠的精确账本
> （09-15 21:49:10 → 09-16 08:52:37 = **11h03m27s 单次**），并由此发现
> **「5W」的测量口径存在算术矛盾**（详见第七节第 2 点）：它极可能是**墙插功率**，
> 而非电池掉电率 → **电池模式的真实睡眠功耗至今仍是空白，必须补测**。
> 并纠正**三轮前的一个错误结论**：上一轮我写「ESP 并无自动同步任务」——**错**。
> ESP 确有自动同步（RealTimeSync + FreeFileSync 镜像，见第六节第 0 步），
> 但实测**会漏/滞后**，所以「改完必须核对 sha256」这条铁律依然要守。
>
> ## ★ 09-16 三轮修正（用户质疑「为什么 A 判死了？不用再确认一下？」）
>
> 复查证实：**第 1 轮的"档 A 判死"结论错误，测试条件本身不成立。** 三条错误：
>
> | # | 原说法 | 更正 |
> |---|---|---|
> | 1 | 「`standbydelay*` 与插不插电无关」 | ❌ **错**。`standby` 是**电池侧**计时器；AC 侧是 `autopoweroff`，而本机 `pmset -g cap` **无此项** → 插电时无深睡计时器 |
> | 2 | 「已超出 `standbydelay` 300 s」 | ⚠️ 实际只超 **38 秒**，而写 16 GB 镜像需 30~90 s → 不足以判定 |
> | 3 | （未考虑） | EFI **缺 `HibernationFixup.kext`** —— 缺了它，`HibernateMode=NVRAM` 只有读端没有写端，**空转** |
>
> 另有一条**同平台先例**：Dell Latitude 5410（i5-10310U + AX201 + `MacBookPro16,x`）
> 明确记录 **AOAC（`Low Power S0 Idle`）与 S4 休眠冲突**，其方案是
> `HibernationFixup.kext` + `hbfx-ahbm=129`（本机 FADT bit21 = SET，正处冲突侧）。
>
> → 复测路线见 `sleep-tests/round2-plan.md`；第 1 轮档案已加撤回声明。

---

## 一、结论摘要

| 项 | 结论 |
|---|---|
| 5W 是故障吗 | **不是**。5W ≈ 7.8%/h（按当前满充 63.9Wh），落在 OC-little 记录的 AOAC 区间（5%~10%/h）内 |
| 是被反复唤醒吗 | **不是**。942 次睡眠里 931 次集中在 09-08/09（OTA+OCLP 窗口），09-10 之后每天仅 3~4 次 |
| 为什么只能到 Deep Idle | FADT `Flags=0x002384A5`，bit21 `LOW_POWER_S0_IDLE_CAPABLE` = **SET** → macOS 选 S0ix |
| 硬件支持更深档吗 | **支持**。`pmset -g cap` 明确列出 `standby / standbydelayhigh / standbydelaylow / highstandbythreshold / hibernatemode / hibernatefile` |
| 那为什么没生效 | `hibernatemode 0` + `standby 0` + `standbydelayhigh 86400` —— **三档全部由 `pmset-reduce-wake.sh` 主动关闭** |
| 曾真的休眠过吗 | **从未**。`kern.hibernatecount = 0`，pmset log 中 standby/hibernate 事件 0 条 |
| 硬件上 S3 存在吗 | **存在**。DSDT 根作用域 `\SS3 = One`，所以 `\_S3` 被真实暴露（详见第四节） |

**一句话**：不是「不能优化」，是「深睡档从没开过」。这是一次**未做过的实验**，不是一条死路。

---

## 二、本轮实测事实（全部可复现）

| 判据 | 实测值 | 命令 / 来源 |
|---|---|---|
| FADT Flags | `0x002384A5`，bit21 = SET | `xxd -s 112 -l 4 FACP-1.aml` |
| 平台类型 | 完整 AOAC/LPI（另有 `LPIT-1.aml`） | `docs/SysReport/ACPI/` |
| `standby` 支持 | ✅ 受支持（当前 0） | `pmset -g cap` |
| `autopoweroff` 支持 | ❌ 不在 cap 列表中 | `pmset -g cap` |
| 历史休眠次数 | `0` | `sysctl kern.hibernatecount` |
| standby/hibernate 日志 | 0 条 | `pmset -g log \| grep -E "Entering Standby\|Hibernate"` |
| 本次启动睡眠次数 | 0（19:23 与 20:06 两次启动） | `pmset -g log` |
| 电池健康 | **5533 / 7170 mAh = 77.2%**，131 循环 | `ioreg -rn AppleSmartBattery` |
| 外接设备 | `USB Optical Mouse` 挂 `0x4=USB` 唤醒断言 | `pmset -g assertions` |
| 空闲睡眠阻止者 | `pid 675(Electron)` 持 `NoIdleSleepAssertion` | `pmset -g assertions` |
| 唤醒源 GPE 归属 | `0x6D` = GLAN + XDCI + HDAS + CNVW **四设备共享**；`0x69` = PXSX（PCIe/雷电）；`0x72` = AWAC | DSDT 逐处回溯 |

### 睡眠次数按天分布（关键：排除唤醒风暴）

| 日期 | 睡眠次数 | DarkWake |
|---|---|---|
| 2026-09-08 | 174 | 174 |
| 2026-09-09 | **757** | **756** |
| 2026-09-10 | 4 | 0 |
| 2026-09-11 | 4 | 0 |
| 2026-09-14 | 3 | 0 |

→ 09-09 那次 756 次 DarkWake 是历史（升级+OCLP 窗口），**当前已自愈**，不构成 5W 的原因。
此判据印证了技能里的警告：**必须先按天分组**，否则会把历史窗口当成当前状态。

---

## 三、可用档位矩阵

| 档 | 设置 | 功耗 | 唤醒速度 | 支持性 | 先例 |
|---|---|---|---|---|---|
| **Deep Idle**（现状） | `hibernatemode 0` + `standby 0` | ~5 W | 瞬时 | ✅ 当前档 | 本机实测 |
| **A. Standby 延迟断电** | `hibernatemode 3` + `standby 1` + `standbydelay*` 缩短 | ~0.2 W | 短睡瞬时 / 长睡读镜像 | ✅ cap 支持 | 通用做法 |
| **B. Hibernate 立即断电** | `hibernatemode 25` + `standby 1` | ~0.2 W | 每次读镜像（慢） | ✅ cap 支持 | ThinkPad E480、Surface Laptop 3、Fujitsu Q958 |
| **C. 强制 S3**（实验） | 清 FADT bit21 + 禁 `SSDT-DeepIdle` | ~0.5 W | 瞬时 | ⚠️ ACPI 存在，macOS 侧零先例 | **无** |

### 档 A / B 的机制（`man pmset` 原文 + 09-16 三度修正，非推断）

- `hibernatemode 3`：写内存副本到磁盘，**但仍给内存供电** → 唤醒从内存。**只设 3 不省电**。
- `standby`：让内核在睡够一段时间后**自动 hibernate** —— 这才是「摘掉内存电」的那个动作。
- `standbydelayhigh/low`：**写镜像并断内存电**的延迟秒数。
  按剩余电量 vs `highstandbythreshold`(50%) 选 high/low。
- `highstandbythreshold` 默认 50%；`standbydelayhigh` 默认 **86400（24 小时）** → 不显式设短 = 永不触发。
- `hibernatemode 25`：写镜像 + **移除内存电**，必定从镜像恢复。不依赖 standby。

> ### ⚠️ 09-16 关键更正：`standby` 与 `autopoweroff` 是**按供电条件二选一**的两个计时器
>
> | 计时器 | 生效前提 | 本机 |
> |---|---|---|
> | `standby` | **电池供电** + 无外接设备 + 无网络活动 + 无外接显示器 | 电池下未测 |
> | `autopoweroff` | **外部电源供电** + 无外接设备 + 无网络活动 | ❌ `pmset -g cap` **无此项** |
>
> **本报告先前的表述「`standbydelay*` 与插不插电无关」是错的**，已更正。
> 正确结论：**插电时 `standby` 永远不会触发**（不是失效，是没有计时器在跑），
> 因为 AC 侧本该由 `autopoweroff` 接管，而本机固件未提供。
> → **插电场景想深睡，只能走不依赖计时器的 `hibernatemode 25`（或 `hbfx-ahbm`）。**
>
> 附带更正：`pmset -g cap` 列出 `standby` 只代表**该参数可设置**，
> 不代表**在 AC 下会生效** —— 这是先前误读的根源。

### 前置件缺口：`HibernationFixup.kext` 未安装

黑苹果休眠需要它：内核加密 `sleepimage` 后把密钥放 `IOHibernateRTCVariables`（`PMRootDomain`），
但黑苹果的 RTC 通常只有 1 bank（128 B）写不进；HibernationFixup 负责**把密钥写进 NVRAM**，
再由 `Misc/Boot/HibernateMode = NVRAM` 让 OpenCore 读出。
**当前只有"读端"没有"写端" → 设置空转。** 最新 1.5.4（2025-07-07，支持 macOS 26）。
详见 `sleep-tests/round2-plan.md`。

---

## 四、S3 专项：为什么上一轮判死，现在可以说「能试」

### 上一轮的判死理由（现在看是不完整的）

1. OC-little 明文「Deep Idle 与 S3 严重冲突」，且它专门提供**禁用** S3 的 SSDT；
2. Windows 侧微软声明 Modern Standby 与 S3 互斥；
3. 社区零先例。

这些仍然成立 —— **但漏掉了一个前提检查：本机的 `_S3` 到底在不在。**

### 本轮新增的两个硬证据

**(1) 本机 ACPI 层确实暴露了 S3**

```
DSDT.dsl L5706-5709（根作用域，indent=4）：
    Name (SS1, Zero)
    Name (SS2, Zero)
    Name (SS3, One)      ← SS3 = One
    Name (SS4, One)

DSDT.dsl L38257（根作用域）：
    If (SS3)
    {
        Name (_S3, Package (0x04) { 0x05, Zero, Zero, Zero })
    }
```

→ `\SS3 = One` 使 `\_S3` 条件成立，**S3 对象真实存在于根命名空间**。
真正拦住 S3 的是 **FADT bit21**，不是 `_S3` 缺失。

> ⚠️ 排查过程本身有教训：先用「向上找最近 `Scope (`」的粗筛，得出 `_S3` 在 `\_GPE`
> 里的错误结论；用**缩进 + 括号归属**重新校验才纠正过来。作用域这类承重事实必须交叉验证。

**(2) 补丁点是干净的**

```
FACP 中 Find <A5 84 23 00>（= 0x002384A5 小端）出现位置：[112]，共 1 处
→ offset 112 正是 Flags 字段本身，ACPI/Patch 可安全使用
```

**(3) 外部同类机器的反例（重要）**

Surface IceLake 修复仓库遇到了**结构完全同构**的 DSDT（同样 `If (SS3)` 包 `_S3 = {0x05,...}`，
同样是 Intel 参考实现），他们改 `SS3 → One` 后：

- 内核日志由 `(AppleACPIPlatform) ACPI: sleep states S4 S5` 变为 `S3 S4 S5` ✅
- **但 S3 睡眠本身依然不可用** ❌ —— 他们最终靠 `hibernatemode 25` 解决

→ 所以 **C 档排在 A/B 之后**，只能当实验，不能当方案。

---

## 五、前置改动（已完成）

commit `2f5c047`：`EFI/OC/config.plist`

| 键 | 旧 | 新 | 理由 |
|---|---|---|---|
| `Misc/Boot/HibernateMode` | `None` | `NVRAM` | OC 手册取值仅 `None/Auto/RTC/NVRAM`，Failsafe 默认即 `None`。`None` = 忽略休眠状态 → 断电后不恢复镜像，开盖只会冷启动 |
| `Misc/Security/AllowNvramReset` | **缺失**（= Failsafe `false`） | `true` | 补上 Reset NVRAM 逃生口 |

**这两项在改 `pmset` 之前是惰性的**：当前仍是 `hibernatemode 0` + `standby 0`，不写镜像，行为不变。

回滚：`git revert 2f5c047`

> ⚠️ 用 `PlistBuddy` 会顺手重排无关区块的 `<data>`（实测产生 13 行噪音 diff），
> 已改用**外科式精确编辑**，最终 diff 仅 3 insertions / 1 deletion。

---

## 六、操作步骤

```bash
cd /Volumes/Common/workplace/zbookpowerg7

# 0. 确认前置已同步到 ESP —— ⚠️ **有自动同步，但实测会漏/滞后，必须手动核对**
#    机制（09-16 查实）：RealTimeSync 14.9 常驻（空闲 3s）→ 触发 FreeFileSync 批处理
#      /Volumes/Common/FreeFileSync/BatchRun.ffs_batch
#      镜像(左→右) EFI/oc → /Volumes/ESP/EFI/oc，TimeAndSize，DeletionPolicy=Permanent（带删除）
#    实测滞后：09-16 09:02:29 改完 config.plist，直到 09:31:14 用户手点「开始」才推过去
#    同步日志：~/Library/Application Support/FreeFileSync/Logs/BatchRun*.html
shasum -a 256 EFI/OC/config.plist /Volumes/ESP/EFI/OC/config.plist   # 两边一致才重启
#    不放心就打开 RealTimeSync 点一次「开始」强制同步
#    ⚠️ 同步范围**只有 EFI/oc**：EFI/boot(BOOTx64.efi) 与 EFI/scripts/ 都不在同步内
cd EFI/scripts

# 1. 先看能力与现状（只读，不需要 root）
./pmset-hibernate.sh status

# 2. 重启一次让 config.plist 生效

# 3. 受控试验（档 A）：合盖 5 分钟后断电
./pmset-hibernate.sh test

# 4. 试验通过后落到日常档
./pmset-hibernate.sh on       # >50% 电量 60 分钟，<50% 电量 30 分钟
# 或直接选档 B
./pmset-hibernate.sh instant  # hibernatemode 25，合盖即断电

# 回滚
./pmset-hibernate.sh off
```

### 判据

| 结果 | 含义 | 处理 |
|---|---|---|
| 功率计 5W → ~0.2W，开盖回到原会话 | ✅ 成功 | 保留 |
| 断电了，但开盖是冷启动 | 半成功 —— `HibernateMode` 值不对 | 试 `Auto` |
| 断电后起不来 | 失败 | 长按电源；进系统后 `./pmset-hibernate.sh off` |
| macOS 也起不来 | 失败 | ① OpenCore 菜单 → **Reset NVRAM**（该入口需 `AllowNvramReset=true`，已由 `2f5c047` 补上，09-16 复核**两侧一致**）② 或进恢复环境/macOS 执行 `sudo nvram -c` —— `WriteFlash=True` + `NVRAM/Delete` 含 `boot-args`，OC 下次启动会重写 `boot-args`/`csr-active-config`，**不依赖 `AllowNvramReset`** |

**睡前务必拔掉外接 USB 鼠标** —— 它在 `pmset -g assertions` 里挂着 `0x4=USB` 断言，
包里被蹭到就会唤醒整机。这是技能里点名的头号外因。

---

## 七、两个容易被误读的点

### 1. 电池已经掉到 77%，它放大了「掉电快」的体感

| 项 | 值 |
|---|---|
| 设计容量 | 7170 mAh ≈ 82.8 Wh |
| 当前满充 | 5533 mAh ≈ 63.9 Wh |
| 健康度 | **77.2%**（131 循环） |

同样 5W 放电：
- 满血电池 → 5 / 82.8 = **6.0 %/h**
- 当前电池 → 5 / 63.9 = **7.8 %/h**

→ **功率没变，是分母小了 23%。** 这条与睡眠档位无关，是独立结论。

### 2. 「5W」是墙插功率还是电池掉电率？—— 二轮查证：口径存疑

**首轮疑问**（`pmset -g assertions` 显示 `pid 675(Electron)` 长期持有
`NoIdleSleepAssertion`，它会阻止**空闲自动**睡眠，但不阻止合盖睡眠）已在二轮澄清：
用户确认「**是合盖测的**」→ 前提成立，测的确实是真睡眠。

**但二轮算账后出现新的、更硬的矛盾**：

```
最近一次睡眠：09-15 21:49:10 → 09-16 08:52:37 = 11h03m27s = 11.06 h
若 5W 是这 11 小时的均值：  5 W × 11.06 h = 55.3 Wh
  占老化满充 63.9 Wh 的：    86.5 %
  占设计容量 82.8 Wh 的：    66.8 %
```

若真如此，醒来时电量应只剩 ~14%。但：

- 唤醒（08:52）→ 本次查证（09:16）**仅 24 分钟**
- 当前 `ExternalConnected = Yes`、`Not Charging`、SoC **96%**，`pmset -g rawlog` 记 `Full=09/16 09:16:57`
- **24 分钟内从 ~14% 充到 96%（约 52 Wh）物理上不可能**（充电器峰值 45~65 W，且 CV 段更慢）

→ **推论：昨晚极可能插着 AC。** 那么「5W」测的是**墙插侧的整机功率**
（AC 进线，含充电器空载损耗与 AC 保持电路），**不能直接换算成电池掉电率**。

**旁证（排除另一来源）**：本机只装了 `Intel Power Gadget`，其目录下仅有一个 2020 年的
`PowerLog` 二进制——它测的是 **CPU 封装功耗**，睡眠时 CPU 已停，根本测不出睡眠功耗。
故 5W 更可能来自插座功率计。

**用户随后亲口确认：「之前测试的，最近一直都是插着电源使用」→ 定案**：

| 项 | 状态 |
|---|---|
| 合盖 = 真睡眠 | ✅ 已确认 |
| **5W = 墙插功率** | ✅ **定案**（AC 进线，含充电器损耗 + AC 保持电路）—— **不是电池掉电率** |
| 昨晚那 11 h 在 AC 上 | ✅ 与「24 分钟充回 96%」的算术推论一致 |
| 电池模式的真实睡眠功耗 | ❌ **至今零数据**（一直插电，从未测过）—— 要数据只能刻意**拔电合盖睡一夜** |

### 3. 「长期插电」这个使用画像，把问题的性质换了

用户当前是**长期插电使用**。在这个场景下，5W 的实际代价要重算：

| 场景 | 5W 的实际代价 |
|---|---|
| **长期插电**（当前） | **合盖持续发热**（笔记本被动散热，放包里更明显）；电费 ≈ **26 元/年**（5W × 24h × 365 × 0.6 元/kWh）→ **可忽略** |
| 拔电带出 | 掉电率高 —— 但**零数据**支撑 |

→ **「省电」的收益必须先说清是省什么**：不是省电费，而是**降低合盖发热**，
  以及**万一拔电时不掉那么快**。拿一个插电读数去解释「掉电快」是错位的。

→ ~~**换档在插电时照样生效**：`standbydelay*` 由**剩余电量 vs `highstandbythreshold`(50%)** 决定
  （`man pmset` 原文：与插不插电无关）→ 插电睡眠也能把 5W 压到 ~0.2 W，**发热同步降下来**。~~

> ⚠️ **上述结论已于 09-16 撤回（错误）**。`standby` 要求**电池供电**；
> 插电时对应的是 `autopoweroff`，而本机不支持它。
> → **插电时想让 5W 降下来，只能靠 `hibernatemode 25`**（每次睡眠立即写镜像断电，
> 不依赖任何计时器）。这反而让档 B 从"备用"变成了**插电场景的首选**。
> 详细的复测路线见 `sleep-tests/round2-plan.md`。

> 所以「能优化」依然成立（第三节档位矩阵不变），只是目标从"省电费"
> 改成 **"降合盖发热 + 拔电时更耐久"**。

---

## 八、未闭环的风险

1. **OCLP 根补丁的 Wi-Fi 在休眠恢复后能否加载** —— 零先例，必须实测。
   本机 Wi-Fi 依赖 OCLP 把 `IO80211.framework` 合并进系统卷，不是纯 EFI kext。
2. **S3 若真走通，EC query 类功能可能在唤醒后失效**（ThinkPad E480 明确记录：
   睡眠唤醒后 Fn 快捷键、合盖事件、电池状态更新失效）。
3. **SSV seal 已损坏**，休眠镜像写入与恢复是否受「认证根」逻辑影响未验证。
4. ~~双 LID 设备（DSDT `\_SB.LID` 真 + `SSDT-LID-G7` 恒返回 1）导致
   `AppleClamshellCausesSleep=No`（正常 Mac 为 Yes）→ **合盖不直接睡，靠空闲计时器兜底**。
   收益小，未修。~~
   > ⚠️ **2026-09-17 更正（见 `docs/sleep-tests/round2-tierB-result.md` §四十一）**：此归因**不成立**。
   > `AppleClamshellCausesSleep=No` 在「**外接屏 + 电源**」下**本来就该是 No** —— 这是 Apple 官方 clamshell 语义
   > （`IOPMrootDomain::shouldSleepOnClamshellClosed()` = `!clamshellDisabled && !(desktopMode && acAdaptorConnected) && !clamshellSleepDisabled`），
   > **真机同样如此**，与 LID 补丁无关（若 LID 通路恒"未合盖"，09-16 那 7 次合盖睡眠不可能发生）。
   > 本机"合盖能睡"实际由第三方 **`/Applications/Clamshell.app`**（`whenClamshellIsClosed = sleep`）实现；
   > 而它今天失效的原因是该动作依赖 **idle sleep**，被 `NoIdleSleepAssertion` 挡住。**⛔ 仍不建议动 `SSDT-LID-G7`。**
