# 「Disable RTC wake scheduling 补丁」与休眠的因果链 —— 源码级核验

> **触发**：用户问「**有理论支撑吗？不要只是盲目的尝试**」（针对议程 ⑤）。
> **一句话答**：**有，而且是一条可逐行复核的源码闭环** —— 但其中 **3 处需要修正我上一轮的说法**（见 §4）。
> **本轮零配置改动 / 零 EFI 改动 / 零固件写入** —— 全部为上游源码只读核验。

---

## §0 结论先行

| # | 命题 | 等级 | 依据 |
|---|---|---|---|
| 1 | 本机补丁挖空的 `AppleRTC::setupDateTimeAlarm` **正是 HibernationFixup 的 hook 目标**（逐字符同一符号） | 🟢 **判据** | 本机 `Kernel/Patch[0].Base` ≡ `kern_hbfx.cpp:845` |
| 2 | HBFX 的自动休眠**只有一条正常触发路径：maintenance dark wake** | 🟢 **判据（源码闭环）** | `:180-191` → `:449` → `:468-486`，且 `:449` 的其他三个 OR 项被逐一排除 |
| 3 | 那个 dark wake **由 RTC 闹钟产生** ⇒ 补丁掐掉闹钟 ⇒ 路径不存在 | 🟢 **判据** | `IOPMrootDomain.cpp:5032` + 社区逐字原文 |
| 4 | R3「仍 Deep Idle」与 R3b「睡下即断气」是**同一机制的两个必然分支** | 🟢 **判据** | `:449` 的 `standby_delay == 0` 分支 vs `sleepServiceWake` 分支 |
| 5 | 「关掉补丁后本机就能通」 | 🟡 **推断** | 上游机制成立，但**无任何人在"EC 不响应 S3"的机器上验证过** |
| 6 | OC patch 与 Lilu route 相遇时谁生效 | 🔵 **未知** | 两种可能都指向同一结果（都不写 RTC），但不排除 route 安装失败 |

---

## §1 因果链 —— 六个环节，逐环可复核

### 环 1｜`hbfx-ahbm` 的 bit0 = "去 hook 这个符号"（不是"让休眠变真"）

```cpp
// kern_hbfx.cpp:829   —— processKext() 里
if (autoHibernateModeEnabled && i == 1 && !(progressState & ProcessingState::AppleRTCRouted) && !doNotOverrideWakeUpTime)
{
    ...
    KernelPatcher::RouteRequest request
        {"__ZN8AppleRTC18setupDateTimeAlarmEPK11RTCDateTime", AppleRTC_setupDateTimeAlarm, orgAppleRTC_setupDateTimeAlarm};
```
其中 `autoHibernateModeEnabled = (autoHibernateMode & Configuration::EnableAutoHibernation)`（`:809`），而 `EnableAutoHibernation = 1`（`kern_config.hpp:51`）。
⇒ **`hbfx-ahbm=1` 的作用 = 让 HBFX 安装 4 条 hook**（`:668` 的门槛）：`IOHibernateSystemSleep/Wake`、`setMaintenanceWakeCalendar`、**`AppleRTC::setupDateTimeAlarm`**、`X86PlatformPlugin::sleepPolicyHandler`（`:854`）。
⇒ 它与"让 `setupHibernate` 变真"**无关**。

### 环 2｜唯一的正常触发路径 = maintenance dark wake

```cpp
// kern_hbfx.cpp:180-191   —— IOHibernateSystemWake() 里
if (wakeType->isEqualTo(kIOPMRootDomainWakeTypeMaintenance) || wakeType->isEqualTo(kIOPMRootDomainWakeTypeSleepService))
{
    callbackHBFX->sleepServiceWake = true;                  // ★ 唯一把它置真的地方
    if (callbackHBFX->isStandbyEnabled(...) && pmset_default_mode && callbackHBFX->nextSleepTimer)
        callbackHBFX->nextSleepTimer->setTimeoutMS(20000);  // ★ 20 s 后再次入睡
}
```
`sleepServiceWake` 全文件只在 **4 处被置 false**（`:150/:229/:381/:498`）、**1 处被置 true**（`:185`，即 dark wake）。

### 环 3｜`setupHibernate` 的判定式 —— 四个 OR 项

```cpp
// kern_hbfx.cpp:449
bool setupHibernate = (forceHibernate || !wakeCalendarSet || sleepServiceWake || standby_delay == 0);
```

逐项排除（正常睡眠、电量健康、`hbfx-ahbm=1` 即不设电量/合盖条件位）：

| 项 | 取值 | 为什么 |
|---|---|---|
| `forceHibernate` | **false** | 只在电量告警/临界、或 `WhenLidIsClosed`(2)/`WhenExternalPowerIsDisconnected`(4)/`WhenBatteryIsNotCharging`(8) 等**条件位**命中时置真（`:371-433`）。`hbfx-ahbm=1` **一个条件位都没设** ⇒ 恒 false |
| `!wakeCalendarSet` | **false** | ☠️ **恒为 false** —— 见环 4 |
| `sleepServiceWake` | **false** ← 唯一能翻真的项 | 只有 dark wake 能置真（环 2） |
| `standby_delay == 0` | **false** | `standbydelay != 0` 时 |

⇒ **`setupHibernate = false` ⇒ `:477-496` 走 else 分支 ⇒ `params->sleepType` 保持原值（=`DeepIdle`）⇒ 日志打 "postpone hibernate"。**

### 环 4｜☠️ `wakeCalendarSet` 恒为 true（这是本轮最关键的新发现）

```cpp
// HBFX 侧（kern_hbfx.cpp:282-283）
result = FunctionCast(...orgIOPMrootDomain_setMaintenanceWakeCalendar)(that, &overriden_calendar);
callbackHBFX->wakeCalendarSet = (result == KERN_SUCCESS);

// XNU 侧（IOPMrootDomain.cpp:7450-7473）
IOPMrootDomain::setMaintenanceWakeCalendar(const IOPMCalendarStruct * calendar) {
    ...
    if (kPMCalendarTypeMaintenance == calendar->selector)
        ret = setPMSetting(gIOPMSettingMaintenanceWakeCalendarKey.get(), data.get());
    ...
    return ret;
}

// XNU 侧（IOPMrootDomain.cpp:5022-5032）★
    if (ok) { recordRTCAlarm(type, object); }
unlock_exit:
    ...
    return kIOReturnSuccess;      // ★★★ 无条件返回成功
```

⇒ **`setPMSetting()` 永远返回 `kIOReturnSuccess`** ⇒ `wakeCalendarSet` **恒为 true** ⇒ `!wakeCalendarSet` **恒为 false**。

⇒ **HBFX 那个"闹钟没设上就强制休眠"的补偿设计（`!wakeCalendarSet` 那一项）形同虚设** —— 它**永远不会**帮上忙。
⇒ 顺带：`recordRTCAlarm`（`:5023`）也是"只要有人试图设闹钟"就置位 `_scheduledAlarmMask`，**与 RTC 是否真的写成功无关** ⇒ `kIOPMSleepFactorRTCAlarmScheduled`（`:5465-5467`）同样不代表硬件状态。

### 环 5｜`setupHibernate = true` 之后才是"真休眠"

```cpp
// kern_hbfx.cpp:468-473   phase < 2
params->sleepType  = kIOPMSleepTypeStandby;
params->sleepFlags = kIOPMSleepFlagHibernate;
// kern_hbfx.cpp:477-486   phase == 2
params->sleepType  = kIOPMSleepTypeHibernate;   // ★ 写镜像 + 断 RAM
```
（这与 R3 日志的 `type 5 flags 0x1` 完全对应。）

### 环 6｜本机补丁把环 2 的入口掐死

| 本机 `Kernel/Patch[0]` | 值 |
|---|---|
| `Identifier` | `com.apple.driver.AppleRTC` |
| `Base` | **`__ZN8AppleRTC18setupDateTimeAlarmEPK11RTCDateTime`** |
| `Find` / `Replace` | `<0B>` / **`C3`**（`ret`） |
| `Count` / `MinKernel` | `1` / `19.0.0` |

⇒ `AppleRTC::setupDateTimeAlarm` 被改成"立即返回" ⇒ **任何调用它的路径都不再写 RTC 闹钟** ⇒ 环 2 的 dark wake 不发生 ⇒ `sleepServiceWake` 恒 false ⇒ 环 3 恒 false ⇒ **永远 postpone**。

### 链条总图

```
hbfx-ahbm=1
   └─ 安装 hook（含 AppleRTC::setupDateTimeAlarm）          ← 环1
        └─ 入睡：setupHibernate 判定                        ← 环3
             ├─ sleepServiceWake ……………………………… false
             ├─ !wakeCalendarSet …………………………… false（恒，环4）
             ├─ standby_delay == 0 ……………………… false（≠0 时）
             └─ forceHibernate ………………………………… false（无条件位）
                  ⇒ postpon → Deep Idle
                  
        ★ 唯一能翻真的：maintenance dark wake ⇒ sleepServiceWake=true
             └─ 由 RTC 闹钟产生
                  └─ ✂️ 本机补丁把 RTC 闹钟路径挖空          ← 环6 ⇒ 死
```

---

## §2 本机符号级对齐（这是"不是猜"的关键）

| 位置 | 符号 |
|---|---|
| 本机 `EFI/oc/config.plist` → `Kernel/Patch[0].Base` | `__ZN8AppleRTC18setupDateTimeAlarmEPK11RTCDateTime` |
| `HibernationFixup/kern_hbfx.cpp:845` 的 hook 目标 | `__ZN8AppleRTC18setupDateTimeAlarmEPK11RTCDateTime` |

**逐字符相同。** ⇒ 这两者**必然**在同一条路径上相遇，不是"可能相关"。
（上游 `kern_hbfx.cpp:293-326` 的 hook 实现末尾是 `return orgAppleRTC_setupDateTimeAlarm(that, rtcDateTime);` —— **它依赖"原始函数真的写 RTC"**。）

---

## §3 三个必然推论 —— 回头解释既有观测

### 推论 A｜R3「仍 Deep Idle」是**必然**，不是"参数没调好"

`standbydelay = 86400`（≠ 0）+ `hbfx-ahbm=1`（无条件位）+ 补丁开 ⇒ 环 3 四项全 false ⇒ postpone。
`kern_hbfx.cpp:437-438` 还会在 `phase > 0` 时**主动**调 `explicitlyCallSetMaintenanceWakeCalendar()` ⇒ 把 `wakeCalendarSet` 再置 true ⇒ 同一调用内 `:449` 即 false ⇒ 这就是 **phase 0 设 type5、1.58 s 后被翻回 type7** 的成因。
⇒ **与 R3 日志逐字吻合。**（此项与 `round3-hbfx-ahbm-plan.md:315-342` 的既有记录一致。）

### 推论 B｜R3b「睡下即断气」也是**必然**，是同一个式子的另一分支

`standbydelay = 0` ⇒ 环 3 第四项 `standby_delay == 0` = **true** ⇒ **`setupHibernate = true`（不需要 dark wake！）** ⇒ `:468` 设 `Standby + kIOPMSleepFlagHibernate` ⇒ phase2 `:483` 设 `kIOPMSleepTypeHibernate` ⇒ **真的去写镜像 + 断 RAM**。
⇒ R3b 不是"绕过了自我推迟所以能测"，而是**跳过了"先普通睡眠、等 dark wake 再决定"这个保护，直接撞进真休眠**。
⇒ 这正是它硬断电、`sleepimage` 前 16 B 全 0、`Entering Hibernate` 0 命中的原因。
⇒ **⇒ `standbydelay = 0` 与 `standbydelay ≠ 0` 在源码上是两条不同的路，不是"同一个测试的两个参数"。**

### 推论 C｜`hbfx-ahbm` 的位选择必须整表核对

`kern_config.hpp:49-74` 全表：

| 位 | 值 | 语义（**注释方向容易读反**） |
|---|---|---|
| `EnableAutoHibernation` | **1** | 必设；= 安装 hooks 的门槛 |
| `WhenLidIsClosed` | 2 | **设了** = 只有合盖才休（不设 = 不管盖子状态） |
| `WhenExternalPowerIsDisconnected` | 4 | **设了** = 只有拔电才休 |
| `WhenBatteryIsNotCharging` | 8 | **设了** = 只有不充电才休 |
| `WhenBatteryIsAtWarnLevel` | 16 | 低电告警 ⇒ `forceHibernate` |
| `WhenBatteryAtCriticalLevel` | 32 | 电量临界 ⇒ `forceHibernate` |
| `DoNotOverrideWakeUpTime` | **64** | ☠️ **设了会取消休眠**（`:450-456`：`standbyTimer != 0` 时直接 `return result`；`:1216-1219`：`explicitlyCallSetMaintenanceWakeCalendar` 直接返回） |
| `DisableStimulusDarkWakeActivityTickle` | 128 | 禁止 dark wake→full wake 的触发 |
| `RemainCapacityBit1-4` | 256~2048 | 最小剩余电量百分比（高 4 位） |

⇒ 社区用的是 **`5` = bit0｜bit2 = "启用 + 只在拔电时休眠"**（T430 作者原话："only enters hibernation when it's disconnected from AC"）；Latitude 5300 用 **`5`**；T530 用 **`1`**。
⇒ **`hbfx-ahbm=1`（本机 R3 用的值）是"无条件自动休眠"，比社区更激进** —— 这也是 16/32/256+ 位绝不设的原因（一旦设了，低电量会走 `forceHibernate` ⇒ 与 R3b 同风险的同一条路）。

---

## §4 ★ 修正我上一轮的 3 处说法

| # | 我上一轮说的 | 实际 | 性质 |
|---|---|---|---|
| 1 | "社区用 `standbydelay 7200`，我们用 86400 ⇒ **参数本身测不出结果**" | **方向对，但理由不完整**。7200 与 86400 在源码上**走同一条路**（都 `≠ 0` ⇒ 都 postpone）。真正的差别是：**`≠0` ⇒ 需要 dark wake 才能进第二步；`=0` ⇒ 跳过 dark wake 直接强制休眠（危险档）**。所以"改成 7200"不是"让测试更快生效"，而是"让 dark wake 落在可测窗口内"——**而它成立的前提仍然是"RTC 闹钟真的能响"** | 表述收紧 |
| 2 | "两个来源指名补丁 ⇒ 这是 R3 失败的真因" | **R3 的 Deep Idle 有 100% 的源码级解释，且不需要补丁** —— `standbydelay ≠ 0` 单独就足以 self-postpone（环 3 + `:437-438`）。补丁是**另一个独立缺陷**（掐死 dark wake）。两者**互相叠加**，R3 无法把账归给其中任一个 | **归因纠正** |
| 3 | "关掉补丁（议程 ⑤）就大概率能通" | **只在机制层成立，不构成对本机的预测**。上游机制被我逐行核通了，但 §5 的三条本机特有障碍**一条都没有被排除**，且社区成功组**没有一个是"EC 不响应 S3"的机器** | 证据等级下调 |

---

## §5 仍未验证的（🔵 禁止当结论）

| # | 项 | 为什么仍是未知 |
|---|---|---|
| 1 | **OC `Kernel/Patch` 与 Lilu `routeMultiple` 相遇时谁生效** | OC patch 在 kext 加载时改二进制；HBFX 在 `processKext` 里 route。两种可能的最终形态（Lilu 拷到的原始字节已是 `C3` / route 因字节校验失败而放弃）**都指向"不写 RTC"**，但不排除第三种（hook 未装 ⇒ `orgAppleRTC_setupDateTimeAlarm` 为空） |
| 2 | **本机 Deep Idle(S0ix) 下 RTC 闹钟能不能唤醒** | 社区成功组的第一次入睡是 **S3/S0ix 普通睡眠**，其 RTC 闹钟能唤醒它们。**本机只跑 Deep Idle**（EC 不响应 S3），这条**没有先例** |
| 3 | **`rtc-blacklist 0x0E–0xFF` / `rtcfx_exclude=0E-FF` 是否挡住 RTC 闹钟** | 前轮记录：闹钟寄存器 `0x01/0x03/0x05`（`round3-hbfx-ahbm-plan.md:249`）**不在** exclude 区间 ⇒ 推断不受影响。**本轮未复验**这两个地址 |
| 4 | **`IOPM.cpp:5743`（"关 Sleep 位 ⇒ 强制真休眠"）** | 前轮引用；**本轮未复验** —— xnu 主分支里该文件路径已变（`iokit/Kernel/IOPM.cpp` 与 `iokit/pwr_mgt/IOPM.cpp` 均 404），需按具体版本另找 |
| 5 | **深挖 `IOPPF` 侧**：`kIOPMSleepFactorRTCAlarmScheduled` 对最终 `sleepType` 的影响 | `X86PlatformPlugin::sleepPolicyHandler` 是**闭源**的（HBFX 在 `:854` hook 它）；XNU 只负责把 factor 填进 `gSleepPolicyVars`（`:5465-5467`） |

---

## §6 对议程 ⑤ 的影响

议程 ⑤ 的四项改动，在源码上**互相咬合、缺一不可**：

| 改动 | 源码作用 |
|---|---|
| 关掉 `Disable RTC wake scheduling` 补丁 | 让环 2 的 maintenance dark wake **真的可能发生**（唯一的翻真路径） |
| `standbydelay 7200` | 让那个 dark wake 落在**可测窗口**内（≠0 ⇒ 必须走 dark wake；=0 ⇒ 跳过保护直撞硬断电） |
| `hbfx-ahbm=1` | 让 HBFX **安装 hooks**（`:668/:829/:854` 门槛）；且不引入 `forceHibernate` |
| `hibernatemode 3` + `standby 1` | 让 `isStandbyEnabled` 与 `pmset_default_mode` 成立（`:1197-1211` 要求 `latestHibernateMode == 3`） |

⇒ **这是一条有理论支撑的假设，不再是"盲试"。** 但它的**成功仍需三条本机特有障碍全被推翻**（§5 第 2 条最致命），所以**预期形态必须写成"可能失败"**。

**代价（不变，且是既定的）**：写 RTC 闹钟 = 写 RTC。本机「武装休眠 ⇒ 写坏 CMOS / POST 005」已 **4/4**。
⚠️ 更准确地说：**那个补丁本来就是为防这件事装的** —— 关掉它 = **主动恢复那条会写坏 CMOS 的路径**。这是议程 ⑤ 的真实定价。

---

## §7 复现方法（任何人都能跑一遍）

```bash
mkdir -p /tmp/src-probe && cd /tmp/src-probe
base=https://raw.githubusercontent.com
curl -sSL $base/apple-oss-distributions/xnu/main/iokit/Kernel/IOPMrootDomain.cpp -o xnu-IOPMrootDomain.cpp
curl -sSL $base/acidanthera/HibernationFixup/master/HibernationFixup/kern_hbfx.cpp  -o kern_hbfx.cpp
curl -sSL $base/acidanthera/HibernationFixup/master/HibernationFixup/kern_config.hpp -o kern_config.hpp

grep -n "setupHibernate"                kern_hbfx.cpp        # :449 判定式
grep -n "sleepServiceWake = true"       kern_hbfx.cpp        # :185 唯一置真处
grep -n "setupDateTimeAlarm"            kern_hbfx.cpp        # :845 hook 目标
grep -n "EnableAutoHibernation"         kern_config.hpp      # :51 位定义
grep -n "return kIOReturnSuccess"       xnu-IOPMrootDomain.cpp | sed -n '...'   # :5032 setPMSetting 恒成功

# 本机补丁的目标符号（任意 python3 均可，只用 plistlib 标准库）
python3 -c "
import plistlib
d=plistlib.load(open('EFI/oc/config.plist','rb'))
p=[x for x in d['Kernel']['Patch'] if x.get('Enabled') and 'RTC' in str(x.get('Identifier',''))]
print([ (x['Base'], bytes(x['Replace']).hex()) for x in p ])"
```
