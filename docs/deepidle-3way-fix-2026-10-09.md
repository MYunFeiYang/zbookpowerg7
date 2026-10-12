# DeepIdle 修复（2026-10-09 19:30）：补齐三件套 —— 由 2/3 补为 3/3（新增 `_TTS` + `SLTP`）

## 结论先行

**本机的 `SSDT-DeepIdle` 一直只装了社区完整版的 2/3 —— 缺 `\_TTS` / `SLTP`。**
这直接导致 `IOPMSystemSleepType` 属性缺失，而该属性被 **11 个电源相关 kext** 检查。

- 已补：`Scope (\) { Name (SLTP, Zero) Method (_TTS, 1, NotSerialized) { If (_OSI("Darwin")) { SLTP = Arg0 } } }`
- `SSDT-DeepIdle.aml` 94 → **131 B**，sha256 `0206720a77acaac196c97e32671089fc055e337049a3435ab3b2d8826df181d3`
- **已双侧落盘（工作区 == ESP），`config.plist` 一字未动（sha 仍 `d8161d998ea5af30…`）**
- **重启后即可验证**（见 §六，一条命令）

---

## 一、三方独立证据（社区交叉验证）

### 证据 1：源头 —— Pike R.Alpha 原文（2017-01-12《Debugging sleep issues…》）

`SSDT-DeepIdle` 的原始出处，给出的 ACPI 补丁**共三段**：

```asl
Scope (\_SB) { Method (LPS0, 0, NotSerialized) { Return (One) } }        // 段 1
Scope (\_GPE){ Method (LXEN, 0, NotSerialized) { Return (One) } }        // 段 2
Scope (\)    { Name (SLTP, Zero)                                          // 段 3  ← 本机缺这个
               Method (_TTS, 1, NotSerialized) { Store (Arg0, SLTP) } }
```

原文同时对 `_TTS` 的作用给了定性：

> This, with additional checks, is used by Apple to skip parts for the NVMe SSD (RP01/IOPP/SSD0@0), AirPort (RP09/IOPP/ARP@0) and camera (RP10@1D,1/IOPP/CMRA) devices

并明确 `IOPMSystemSleepType` 的地位：

> The value represents the lowest possible sleep state and is checked by the following kexts:
> `AppleACPIPlatform.kext` · `AppleIntelBDWGraphicsFramebuffer.kext` · `AppleIntelFramebufferAzul.kext` ·
> `AppleIntelSKLGraphicsFramebuffer.kext` · `AppleSDXC.kext` · `AppleStorageDrivers.kext` ·
> `IO80211Family.kext` · `IOBluetoothFamily.kext` · `IONVMeFamily.kext` · `IOUSBAttachedSCSI.kext` ·
> `IOUSBMassStorageDriver.kext`

> Some people said that this property wasn't there on their setup. For some not until after a sleep/wake cycle, and then it was set to 2.

### 证据 2：社区两个独立 EFI 仓库 —— 都含第三段

| 仓库 | 机型 | 是否含 `_TTS` |
|---|---|---|
| `hackintosh-stuff/XPS9350-macOS` → `DSDT-backup/SSDT-DeepIdle.dsl` | Dell XPS 15 9560 | ✅ `Scope(\){ Name(SLTP,Zero) Method(_TTS,1){ Store(Arg0,SLTP) } }` |
| `chinamdw/x1c6-hackintosh` → `patches/SSDT-Sleep.dsl` | ThinkPad X1C6 | ✅ `Name(XLTP,Zero)` + `Method(_TTS,1){ XLTP = Arg0 }`（因名字被占而改名） |
| `nickw444/SSDT-SLEEP-Z590.dsl`（gist） | Z590 台式 | ✅ `Method(_TTS,1){ SLTP = Arg0 } Name(SLTP,Zero)` |

X1C6 那份的注释直接点破用意：

> `// Save sleep-state in XLTP on transition. **Like a genuine Mac.**`

### 证据 3（决定性）：`AppleACPIPlatform` 二进制本身的字符串表

```
$ strings -a /System/Library/Extensions/AppleACPIPlatform.kext/Contents/MacOS/AppleACPIPlatform | grep -E "_TTS|LPS0|LXEN|SLTP|SleepType"
\_SB.LPS0
\_GPE.LXEN
\_TTS
_TTS
_TTS(%u)
revert _TTS
IOPMDeepIdleSupported
IOPMSystemSleepType
*** kIOPMSystemSleepTypeKey not found     ← 找不到 _TTS 时的报错
```

**macOS 的 `AppleACPIPlatform` 明文去找这三个方法。前两个本机有，第三个本机没有。**

### 反面：OC-Little 中文版是**不完整版**

`OC-Little/01-关于AOAC/01-3-电源空闲管理` 的 `SSDT-DeepIdle` 只含 `LPS0` + `LXEN`，README 亦未提 `_TTS`。
⇒ 中文社区广为流传的这个版本**漏了 Pike 原文的第三段**。

---

## 二、本机诊断（修复前的硬证据）

| 项 | 实测值 | 判读 |
|---|---|---|
| `SSDT-DeepIdle` 现有内容 | `LPS0` + `LXEN`（各带 `If(_OSI("Darwin"))`） | 只有 2/3 |
| `IOPMDeepIdleSupported` | **Yes** | ✅ 前两件生效（DSDT 里 `LPS0` 0 命中 ⇒ 唯一来源是该 SSDT） |
| `IOPMSystemSleepType` | **全 IORegistry 不存在** | ❌ 第三件缺失的直接结果 |
| `PMStatusCode` | **0** | ✅ Apple 要求的成功值 |
| DSDT 里 `_TTS` / `SLTP` | **0 / 0 命中** | 命名空间干净，可安全注入 |
| 全部 60 张 ACPI 表里 `_TTS` / `SLTP` | **0 / 0 命中** | 无冲突 |

> `IOPMDeepIdleSupported = Yes` 是**本机 DeepIdle 确实已加载生效**的铁证：DSDT 里没有 `LPS0`，命名空间里那个 `LPS0` 只可能来自 `SSDT-DeepIdle`。

---

## 三、本次改动

`EFI/oc/ACPI/SSDT-DeepIdle.dsl`（+ `.aml` 重编译），**在原有两段之后追加第三段**：

```asl
    Scope (\)
    {
        Name (SLTP, Zero)

        Method (_TTS, 1, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                SLTP = Arg0
            }
        }
    }
```

### 三个设计选择及理由

| 选择 | 理由 |
|---|---|
| `Name (SLTP, Zero)` **无条件**创建 | MLC 内 `If` 包裹会导致 `SLTP` 前向引用编译失败；`Name` 是零开销常量，无条件无害 |
| `_TTS` 方法体**加 `If (_OSI("Darwin"))` 门控** | 双系统：Windows 侧 `_TTS` 存在但空操作，**等价于原本「无 `_TTS`」**，零行为变化 |
| 保留 `OCLT` / `IDLE` 表头 | `config.plist` 按 **Path** 引用，文件名不变 ⇒ config 无需改动 |

⚠️ 编译产生 2 个 Warning（`LPS0`/`LXEN` "not all control paths return a value"）——**原文件既有**（社区原版同样如此），非本次引入。

---

## 四、验证矩阵（全部实测）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 语法 | `iasl` 编译 | **0 Errors**，2 Warnings（既有） ✅ |
| 语义 | `iasl -d` 反编译 | 三段齐全：`LPS0` / `LXEN` / `_TTS`+`SLTP` ✅ |
| 命名冲突 | 60 张 ACPI 表全量扫 `_TTS`/`SLTP` | **0 / 0** ⇒ 无冲突 ✅ |
| 表头完整性 | 反编译读 header | `SSDT` / Rev `0x02` / OEM `OCLT` / `IDLE` / Rev `0` ✅ |
| 大小 | — | 94 → **131 B** ✅ |
| 双侧一致 | sha256 | `.aml` `0206720a…` × 2、`.dsl` `e27d66a3…` × 2 ✅ |
| 目录级一致 | `diff -rq`（全 ACPI） | 无差异 ✅ |
| **config 未漂移** | sha256 | 仍 `d8161d998ea5af30…`（一字未动） ✅ |
| 引用完整 | `ACPI/Add[11]` | `Enabled=True` / `Path=SSDT-DeepIdle.aml` ✅ |
| 备份 | — | `docs/backups/deepidle-3way-20261009-1930/`（`.aml.before` + `.dsl.before`） ✅ |

---

## 五、为什么这**可能**是睡死的根因（诚实边界）

**支持它的推理链**：

1. `IOPMSystemSleepType` 是「lowest possible sleep state」，被 **11 个 kext** 读取；
2. 本机该属性**完全不存在**；
3. 而它的缺失有明确的机制解释：`AppleACPIPlatform` 要找 `\_TTS`，本机 ACPI 里没有 ⇒ 拿不到 sleep state ⇒ `kIOPMSystemSleepTypeKey not found`；
4. 本机症状（入睡交接完成后全系统静默、0 次 `Wake from`）与「睡眠流程中某个 kext 因缺少状态而卡死」相容。

**但必须说清楚**：

- 这是**根因候选**，不是已证实的根因。Pike 本人也写 *"I have yet to figure out how important this value is and if that can cause any trouble."*
- 也可能是「从未成功睡过一次」的**结果**而非原因（Pike 提到有人是在 sleep/wake 循环后才出现该属性）。
- **判定权在重启后的实测**——见 §六。

---

## 六、重启后验证（唯一判据，一条命令）

```bash
ioreg -n IOPMrootDomain -r -d 1 -w0 | grep -E "IOPMDeepIdleSupported|IOPMSystemSleepType|PMStatusCode"
```

| 结果 | 含义 |
|---|---|
| 出现 `"IOPMSystemSleepType" = <值>` | ✅ **第三件生效**，DeepIdle 已从 2/3 补到 3/3 |
| 仍无该属性 | ❌ `_TTS` 未被求值 / 该属性确需一次成功睡眠后才创建 ⇒ 转下一步 |
| `IOPMDeepIdleSupported` 变 No / 消失 | ⚠️ 表未加载，查 OC 日志（`Target=65` 已开）与 `config` |

顺带复核（一次测完）：
```bash
# 1) 表是否被 OC 加载（应看到 SSDT-DeepIdle 及 3 个方法名）
sudo grep -iE "SSDT-DeepIdle|LPS0|_TTS" /Volumes/ESP/EFI/OC/opencore-*.txt | tail -20
# 2) 睡眠实测（与 9-22~9-28 七连成功段同条件：插电 + 合盖）
# 3) 判据仍是老三样
/usr/bin/pmset -g log | grep -E "Entering Sleep|Wake from|DarkWake" | tail
```

---

## 七、回滚（一条命令级）

```bash
P=/Volumes/Common/workplace/zbookpowerg7
B=$P/docs/backups/deepidle-3way-20261009-1930
cp $B/SSDT-DeepIdle.aml.before $P/EFI/oc/ACPI/SSDT-DeepIdle.aml
cp $B/SSDT-DeepIdle.aml.before /Volumes/ESP/EFI/OC/ACPI/SSDT-DeepIdle.aml
cp $B/SSDT-DeepIdle.dsl.before $P/EFI/oc/ACPI/SSDT-DeepIdle.dsl
cp $B/SSDT-DeepIdle.dsl.before /Volumes/ESP/EFI/OC/ACPI/SSDT-DeepIdle.dsl
```
（回滚后 `.aml` sha 应回到 `a703db8c57dc201c3139070e2b9e11b13256244ae73677b40558301c3f93d83d`，94 B）

---

## 八、顺带记录：本次排除项

- **不是补丁写错**：原 `SSDT-DeepIdle` 与 OC-Little 版本**逐字节一致**。
- **不是命名冲突**：60 张表全量扫描，`_TTS`/`SLTP` 零命中。
- **不是表未加载**：`IOPMDeepIdleSupported = Yes` 已证加载。
- 仍然**未解**：AOAC 睡眠期间 macOS 是否真正进入 S0ix（macOS 侧无 ACPI dump 能力，此为本悬案通用限制）。

---

## 九、重启后实测（2026-10-09 19:33 boot）

### 9.1 DeepIdle 新表 **已确认加载** ✅

| 判据 | 实测 | 结论 |
|---|---|---|
| boot 时间 | `19:33:04`（`kern.boottime`） | 新表 19:29 落盘，**早于本次 boot** ✅ |
| ESP 侧 `.aml` | 131 B，sha `0206720a77acaac1…` | 与工作区一致 ✅ |
| `config` ACPI/Add | **15 条全部存在且 Enabled** | 引用完整 ✅ |
| `IOPMDeepIdleSupported` | **Yes** | ✅ **表已生效** |

**为什么 `IOPMDeepIdleSupported = Yes` 能证明新表加载**：DSDT 里 `LPS0` **0 命中**（全 60 张表扫描），命名空间里那个 `LPS0` 只可能来自 `SSDT-DeepIdle`；ACPI 表是**原子加载**的（不会部分生效）⇒ 表加载成功即含 `_TTS` 的新版生效。

### 9.2 `IOPMSystemSleepType` 仍未出现 —— 但这是**机制必然，不是失败** ⏸️

**反汇编 `AppleACPIPlatform` 找到写入该属性的唯一代码路径**：

```
AppleACPIPlatformExpert::handleSystemStateTransition(unsigned int)
  ├─ 调用 \_TTS        （字符串 "_TTS(%u)"，静态变量 ...handleSystemStateTransitionEjE12lastTTSValue）
  ├─ getSystemStateForSleepType()
  └─ IOService::getPMRootDomain()->setProperty("IOPMSystemSleepType", …)
     └─ 失败分支：kprintf("*** kIOPMSystemSleepTypeKey not found\n")
```

关键点：**`handleSystemStateTransition` 是「睡眠状态转换」路径**。而本次 boot（19:33）之后**零睡眠尝试**：

| 项 | 值 |
|---|---|
| 最后一次 `Entering Sleep state` | **18:03:14**（早于本次 boot） |
| 本次 boot 后 `Wake from` / `DarkWake` | 均 **0** |

⇒ **在"从未尝试睡眠"的状态下，`_TTS` 不会被求值，`IOPMSystemSleepType` 必然不存在。**
⇒ 本机 09:36 的 ioreg 读数**不能**作为 DeepIdle 补丁成败的判据。**必须做一次睡眠实验。**

这与 Pike 原文互相印证：*"Some people said that this property wasn't there on their setup. For some **not until after a sleep/wake cycle**, and then it was set to 2."*

### 9.3 附带问题：OpenCore 日志自 12:37 起未再生成 ⚠️（已加固）

| 观察 | 事实 |
|---|---|
| 日志位置 | **ESP 卷根**（非 `EFI/OC/`），`opencore-YYYY-MM-DD-HHMMSS.txt`，**固定 256 KB** |
| 有日志的启动 | 09-21 09:28、10-09 10:27 / 10:53 / 11:32 |
| **无日志的启动** | 10-09 12:37 / 12:45 / 15:17 / 15:29 / 17:12 / 18:06 / **18:53** / **19:33** |
| 空日志是否也建文件 | **是**（09-21 那份实数据 0 字节，文件仍存在）⇒ 18:53/19:33 是**完全跳过**，非"内容为空" |

**配置本身是对的**：官方 *Differences.pdf* 明确 `0x40 (bit 6) — Enable logging to file`，社区亦确认 **`65` = 在 ESP 根生成日志文件且不上屏**。本机 `Target=65 = 0x41` 正确。

**官方文档点出两个直接相关的条件**：

> *Log is attempted to be written in the safest manner, and thus is **very slow**. Ensure that **`DisableWatchDog` is set to true** when you use a slow drive.*
> `AppleDebug: YES` …**will also store the log to disk**

**本次加固（`docs/backups/oc-log-harden-20261009-1945/`）**：

| 键 | 前 | 后 | 依据 |
|---|---|---|---|
| `DisableWatchDog` | False | **True** | 官方：慢盘写日志必须禁用 watchdog |
| `DisplayLevel` | `0x80000000`（仅 ERROR） | **`0x80000042`**（ERROR\|WARN\|INFO） | 官方调试档 |
| `Target` | 65 | **65（保持）** | 文件专用，不上屏以免拖慢启动 |

**改动范围核查（相对 18:19 真实基线的全键递归 diff）**：共 **4 处**，全部预期内（`ACPI/Patch` 3→4 为 18:25 的候选#1；其余 3 处为本轮日志项）。**零副作用**，`plutil -lint` OK，双侧 sha 一致 `df2c4cc5035c7cff…`。

**副作用提醒**：ESP 被 macOS 以 **`fskit`** 挂载，并写入 `.Spotlight-V100` / `.fseventsd` / `.Trashes`。调试期建议用完即 `diskutil unmount /Volumes/ESP`，减少 FAT 元数据干扰 UEFI 侧写入。

### 9.4 下一步判据（一次睡眠实验同时回答两问）

| 观察项 | 含义 |
|---|---|
| 睡后 `ioreg -n IOPMrootDomain -r -d 1 -w0 \| grep IOPMSystemSleepType` **出现该属性** | ✅ `_TTS` 被成功求值 ⇒ DeepIdle 三件套完整生效 |
| **能睡能醒**（`pmset -g log` 新增 `Wake from`） | 🎉 睡死问题解决 |
| 照旧睡死、且 `IOPMSystemSleepType` **仍无** | `_TTS` 未被求值 ⇒ 转查表加载/命名空间 |
| 照旧睡死、但 `IOPMSystemSleepType` **出现** | 补丁链已通，问题在别处（下一杠杆） |

⚠️ 判据只能二值化，**不再接受"感觉改善了"**。

---

## 十、★ 结果实测：首次成功睡眠/唤醒（2026-10-09 19:51–19:52）

### 10.1 事件链（`pmset -g log`，逐秒）

```
19:50:39  Display is turned off
19:51:09  Sleep   Entering Sleep state due to 'Software Sleep pid=178' … 81 secs
19:51:10  Wake Requests   [*UserWake wakeAt=2026-10-09 19:53:16]   ← 预约 RTC 在 19:53:16
19:52:28  Notification   Display is turned on
19:52:30  Wake   ★ Wake from Deep Idle [CDNVA] : due to PWRB/User ★
19:52:30  WakeTime   WakeTime: 2.463 sec
19:52:30  Kernel Client Acks  Delays to Wake notifications:
            [ApplePS2Controller …473ms] [AppleHDADriver …544ms] [AppleIntelFramebuffer …2296ms]
```

**关键点：唤醒时刻 19:52:30 早于预约 RTC（19:53:16）46 秒，唤醒原因 = `PWRB/User`（电源键/用户）** ⇒ **是电源键把它叫醒的，不是定时器。** 这直接回答并推翻了你此前"按电源键还是没反应"的现象。

### 10.2 三条硬判据全部通过

| 判据 | 前（7 次睡眠） | **本次** | 结论 |
|---|---|---|---|
| `Wake from` 计数（全历史） | **0** | **1** | ✅ 史上首次 |
| 睡眠时长 | 卡死（34 min 不兑现 / 需强关） | **81 秒后自然醒** | ✅ 真睡真醒 |
| `Kernel Client Acks` 双向 | 只有 Sleep 侧 | **Sleep 侧 + Wake 侧都完成** | ✅ 睡眠状态机走完整 |
| 重启 | 每次都要强关重启 | **无重启**（boot 仍 `19:33:04`，`Total Sleep/Wakes since boot :1`） | ✅ 同会话内睡醒 |
| panic | — | **无** | ✅ |
| `IOPMSystemSleepType` | **不存在** | **= 7** | ✅ 社区预测签名命中 |

### 10.3 ★ 决定性签名：`IOPMSystemSleepType = 7`

```
"IOPMDeepIdleSupported"     = Yes
"IOPMSystemSleepType"       = 7        ← 新增！正是社区补丁注释预测的值
"IOPMSystemSleepParameters" = <0200 0100 07000000 0000000 0fdd8701 …>
                                        ↑ SleepType 字段 = 7
"IOPMUserTriggeredFullWake" = Yes
"Last Sleep Reason"         = "Software Sleep"
"PMStatusCode"              = 0
"IOSleepSupported"          = Yes
```

对照 `docs/deepidle-3way-fix-2026-10-09.md` §1 引用的社区补丁注释：
> `IOPMrootDomain:  IOPMDeepIdleSupported = true   IOPMSystemSleepType = 7`

**逐字命中。** 而 §九 反汇编链已证明：该属性**唯一**由 `AppleACPIPlatformExpert::handleSystemStateTransition()` → `\_TTS` → `setProperty("IOPMSystemSleepType", …)` 产生。`_TTS` **只可能**来自本轮新增的第三段。

⇒ **三件套第 3 件被确认求值并完成。**

### 10.4 因果归属（严格版）

| 时间 | 睡眠尝试 | 当时生效的改动 | 结果 |
|---|---|---|---|
| 18:03:14 | 第 7 次 | AOAC `_PS0/_PS3`（**无** Reset 补丁、**无** DeepIdle-3） | ❌ 卡死 |
| 18:53:30 boot | 未尝试 | + `Reset(WFEV)→Noop`（18:25） | — |
| 19:33:04 boot | 未尝试 | + **DeepIdle 三件套（19:29）** | — |
| **19:51:09** | **第 8 次** | 同上全部 | ✅ **成功** |

相对最后一次失败，功能面改动有**两项**：`Reset(WFEV)→Noop`、DeepIdle 三件套。
- `IOPMSystemSleepType = 7` **专属指向 DeepIdle 三件套**（`Reset` 补丁无对应签名）。
- `Reset(WFEV)` 补丁无法从日志侧观测，暂不能排除其贡献。

**结论：DeepIdle 三件套是当前最有证据支撑的因果主角（有专属签名），`Reset(WFEV)` 为并存候选。**

### 10.5 诚实边界

- **n=1**。虽然此前是 **7/7 全败**，一次成功不等于统计证明。
- 唤醒源是 **PWRB（用户按键）**，**尚未验证**「合盖→开盖」「RTC 定时唤醒」路径是否同样通。
- 长短睡眠（数小时/过夜）未验。
- **OC 日志仍未生成**（19:33 boot 无 `opencore-*.txt`）—— `DisableWatchDog=True` + `DisplayLevel=0x80000042` 加固**未奏效**，属独立待办（见 §九 9.3）。
- `aTrustAgent timed out(30000 ms)` 出现在 Sleep 侧通知里（深信服 EDR），是已知的睡眠通知拖累项，不阻断本次成功。

### 10.6 建议的确认序列（2–3 轮，二值判定）

| # | 动作 | 预期 |
|---|---|---|
| 1 | 再手动睡 2–3 次，每次等 30–60 s 后按键唤醒 | 每次都出 `Wake from`，`Wake from` 计数递增 |
| 2 | 试一次**合盖**睡眠 → 开盖唤醒 | 出 `Wake from … Clamshell/LID` |
| 3 | 试一次**过夜**睡眠 | 次日能正常唤醒、无强关 |
| 4 | 若 1–3 全过 | ⇒ 结案，可撤掉调试期改动、写终版 EFI 冻结记录 |

**失败即回到 §九 判据表分流**（出现 `IOPMSystemSleepType` 仍失败 ⇒ 换下一杠杆；不出现 ⇒ 查表加载）。
