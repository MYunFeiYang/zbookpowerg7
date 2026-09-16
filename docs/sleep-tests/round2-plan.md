# 第 2 轮计划：补齐前置后复测（2026-09-16）

> 起因：用户质疑「为什么 A 判死了？不用再确认一下？」
> → 复查证实**第 1 轮结论错误**，测试条件不成立（详见 `round1-tierA-result.md` 顶部撤回声明）。
> 本文件是修正后的复测方案。
>
> **2026-09-16 10:40 用户追加诉求**：「功耗还是要降的，谁能说不准不会要出差呢？」
> → **拔电场景（出差 / 移动）的续航是真需求**，不再是「插电时只值合盖发热」的可忽略项。
> 这条把 S2 从「备选」提为**主路**：`hibernatemode 25` 不依赖任何计时器，
> **插电与拔电都生效**，是唯一同时覆盖两种场景的机制。

---

## 一、核心认知修正（两条）

### 1. `standby` 与 `autopoweroff` 是**两个按供电条件二选一**的计时器

| 计时器 | 前提条件 | 本机状态 |
|---|---|---|
| `standby` | **电池供电** + 无外接设备 + 无网络活动 + 无外接显示器 | 电池下**未知**（从未在电池上测过） |
| `autopoweroff` | **外部电源供电** + 无外接设备 + 无网络活动 | ❌ `pmset -g cap` 里**没有此项** → 插电时无深睡计时器 |

**推论（2026-09-16 10:30 二次修正 —— 两个前提被实测破坏）**：

- ⚠️ **先撤回一句过头话**：`pmset -g cap` 的输出标题就是 **「Capabilities for AC Power」**，
  其中**明确列出 `standby` 与 `standbydelayhigh/low`** → 「AC 下没有 standby 计时器」这句**说过了**。
  cap 只证明该参数**可设置**，不证明它在 AC 下**会生效**。**这一点依然未知。**
- ★ **新证据（本次实测发现）**：本机当前**接着外接显示器 PHL 241B8Q（HDMI，Online: Yes）**
  与**外接 USB 光电鼠标**。`standby` 的四个前提里
  「**无外接设备**」「**无外接显示器**」**两条直接不满足**。
  → 这很可能是第 1 轮不触发的**真正主因**，与插不插电**无关**。
- 因此供电状态**不是第一个该排除的变量，外设才是**。测试改为
  **先摘外设（S0）→ 再换供电（S1）**，一次只动一个变量。

### 2. AOAC（`Low Power S0 Idle`）与 S4 休眠**冲突**

同代同平台先例 —— **Dell Latitude 5410**（i5-10310U + Intel AX201 + `MacBookPro16,3`）
EFI 仓库原文：

> **Enable Hibernation (S4) (Supported by default in this EFI)**
> In config.plist: `Hibernatemode = NVRAM`
> Run: `sudo pmset hibernatemode 3`
> Add to EFI: **`Hibernationfixup.kext`** + boot-args: **`hbfx-ahbm=129`**
>
> **Notes for Low Power S0 Idle**: The default value of Low Power S0 Idle is enabled,
> it **conflicts S3 Sleep wake up and S4 Sleep**. I strongly recommend to use S3 sleep by
> disabling Low Power S0 Idle capability by:
> `setup_var_cv Setup 0x14 0x1 0x0 // Disable Low Power S0 Idle`

本机 FADT bit21 = **SET**（AOAC 开启）→ 正处在"冲突"的那一侧。

---

## 二、缺失的前置件：`HibernationFixup.kext`

**当前 EFI 里没有它** —— 这是最实质的缺口。

它做什么（acidanthera 官方 README）：

> An open source kernel extension providing a sync between RTC variables and NVRAM.
> By design the mach kernel encrypts hibernate sleepimage and writes the encryption key
> to variable `IOHibernateRTCVariables` in the system registry (PMRootDomain).
> Somehow this value has to be written into RTC (or SMC) in order the boot.efi could read it.
> But in case if you have to limit your RTC memory to 1 bank (128 bytes), it doesn't work...
> **Fortunately, boot.efi can read key `IOHibernateRTCVariables` from NVRAM!**
> This kext detects entering into "hibernate" power state, reads variable from the system
> registry and writes it to NVRAM.

**对我们的意义**：内核加密 sleepimage 后把密钥放进 `PMRootDomain`。
黑苹果的 RTC 通常只有 1 bank（128 B）→ 写不进 RTC。
`HibernationFixup` 负责把它写进 **NVRAM**，而我们的
`Misc/Boot/HibernateMode = NVRAM` 正是让 OpenCore 从 NVRAM 读。
**两边必须配套 —— 现在只有读的一端，没有写的一端 → 空转。**

- 最新版本：**1.5.4**（2025-07-07，*Added constants for macOS 26 support*）
- 依赖：Lilu（已有 1.7.3）
- 关键 boot-arg：`hbfx-ahbm=<bitsum>`
  - `1` = EnableAutoHibernation（用休眠代替普通睡眠）
  - `2` = WhenLidIsClosed（仅合盖时）
  - `128` = DisableStimulusDarkWakeActivityTickle
  - → 先例用的 **`129` = 1 + 128**

---

## 三、复测路线（按风险从低到高）

| 步骤 | 操作 | 改什么 | 风险 | 能验证什么 |
|---|---|---|---|---|
| **S0** | **拔掉外接显示器 + 外接 USB 鼠标**，**保持插电**，切回档 A（`hibernatemode 3` + `standby 1` + delay 300），睡 15 min | 无（只动 pmset） | 🟢 零 | `standby` 在 **AC + 无外设**下是否触发（第 1 轮两个被破坏的前提已排除） |
| **S1** | 若 S0 仍不触发 → 再**拔电**，重测同一档 | 无（只动 pmset） | 🟢 零 | 是否**只有电池供电**才会触发 `standby` |
| **S2** | 装 `HibernationFixup.kext` 1.5.4 → 重启 → 插电测档 B（`hibernatemode 25`） | EFI（工作区，git 可回退） | 🟡 中 | 休眠全链路（写镜像→断电→恢复）是否通 |
| **S3** | 加 `hbfx-ahbm=129`（合盖即休眠） | boot-args | 🟡 中 | 绕开计时器，AC 下也能深睡 |
| **S4** | BIOS 关 `Low Power S0 Idle`（modGRUBShell，隐藏项） | BIOS | 🔴 高 | 换来 S3/S4，**代价是放弃 Deep Idle** |

> ⚠️ **测试前必看**：本机**常态接着外接显示器（PHL 241B8Q，HDMI）+ 外接 USB 鼠标**。
> 这两样都会**破坏 `standby` / `autopoweroff` 的前提**（「无外接设备」「无外接显示器」）。
> S0/S1 必须**拔干净**再测；S2 用的是 `hibernatemode 25`，**不依赖计时器，外设不影响**。
>
> ⚠️ **档位当前是 `hibernatemode 25`（档 B）**，跑 S0/S1 前要先切回档 A：
> `sudo pmset -a hibernatemode 3 standby 1 standbydelaylow 300 standbydelayhigh 300`

**S4 是本末倒置**：我们本来的目标就是"Deep Idle 睡眠耗电高"，
关掉 Deep Idle 等于把要优化的对象换掉了。**不建议**，除非 S1~S3 全部失败。

---

## 三·补、两种场景下的最优档位（2026-09-16 因「可能出差」重估）

用户提出可能出差 → **拔电续航成为真需求**，需要按场景分别判断：

| 场景 | 计时器前提 | 可用机制 |
|---|---|---|
| **办公室**（插电 + 外接显示器 PHL 241B8Q + USB 鼠标） | `standby` ❌（外设/显示器前提被破坏）<br>`autopoweroff` ❌（`cap` 无此项） | **只有档 B（`hibernatemode 25`）** —— 不依赖计时器 |
| **出差**（电池 + 无外接显示器 + 无外接设备） | `standby` ✅ **四条前提恰好全部满足** | **档 A（`3` + `standby 1` + 短 delay）** 最优 |

> ★ 关键认知：**档 A 的前提在出差时恰好全部满足。**
> 这解释了第 1 轮为什么在办公室测不出来（外设破坏前提），
> 但**不代表档 A 没用** —— 它只是"插电 + 外接显示器"这个特定组合下测不出来。

**代价对比（选型依据）**：

| | 档 A（`3` + `standby 1`） | 档 B（`25`） |
|---|---|---|
| 短睡（合盖几分钟） | **秒醒**（内存睡眠，不落盘） | 每次都要写 16 GB 镜像 → 合盖后数秒~数十秒才断电；唤醒要读回 |
| 长睡（数小时） | 到点自动落盘断电 | 已断电 |
| SSD 写入量 | 仅长睡时写一次 | **每次睡眠都写 16 GB**（每天 2 次 ≈ 12 TB/年，消费级 SSD 可忽略但非零） |
| 依赖 | `standby` 计时器 + 四条前提 | **无依赖** |
| 适合 | **出差**（前提恰好满足） | **办公室**（前提不满足，只能靠它） |

→ **不是"二选一"，而是按场景切换** —— `EFI/scripts/pmset-hibernate.sh` 的 `on`/`off` 就是为此准备。
→ 但档 A 在电池下**是否真的会触发，至今未测**（S1 未做）。这是出差场景唯一的未知数。

---

## 四、第 1 轮结论中仍然有效的部分

- 系统**正常入睡 / 正常唤醒 / 会话零丢失**（338 s 睡眠 → 2.617 s 唤醒）。
- **唤醒链路含 USB**：`DriverReason:XHC` → 测睡眠务必**拔掉外接 USB 鼠标**。
- `sleepimage` 创建于 10:01:54，**1 GB 且从未被写过**。
  （16 GB 内存的镜像按社区口径应为 16 GB；此异常待 `HibernationFixup` 装上后复看）

---

## 五、已知风险（先例警告）

- daliansky/XiaoMi-Pro issue #661：**`HibernationFixup` + 电量耗尽 → 可能卡在休眠无法开机**
  （当事人最终移除该 kext 才恢复）。→ 测试期间**保持插电**，不要让电池耗尽。
- Dortania 官方立场：`Misc/Boot/HibernateMode = None`，
  *"We're gonna avoid the black magic that is S4 for this guide"*。
  → 我们走的是**官方不建议**的路径，属用户明确授权的实验。

---

## 六、回滚

```bash
# pmset 回到 Deep Idle 基线
cd /Volumes/Common/workplace/zbookpowerg7/EFI/scripts && ./pmset-hibernate.sh off

# EFI 回滚（若已装 kext）
cd /Volumes/Common/workplace/zbookpowerg7 && git revert <commit>
```

起不来：长按电源 → 能进系统就跑回滚；macOS 也起不来 →
OpenCore 菜单 → **Reset NVRAM**（逃生口 `AllowNvramReset=true` 已开），
或 `WriteFlash=True` 下执行 `sudo nvram -c` 让 OC 重写 boot-args。
