# Round 3 · `hbfx-ahbm` 自动休眠实测执行单

> **2026-09-20 16:5x 建立。** 这是「§7.10 发现的那条从未测过的路」的**首次上机实测**。
> 权威分析见 `s4-requirements-audit.md` §7.10；真相的判据在本文 §5。
> **本轮是自 2026-09-16 封板以来第一次真正动 EFI + pmset。** 回滚点见 §6。

---

## 1. 假设与目的

**假设**：`hbfx-ahbm` 能让 macOS 在**睡眠策略选择阶段**就把 `sleepType` 改写成 Hibernate，
从而**绕开"必须先走一段 S3 语义睡眠"**这个本机 S3 坏掉导致的卡点。

**与 09-16 那 5 次的本质区别**：

| | 09-16 那 5 次 | 本轮 |
|---|---|---|
| 触发方式 | `pmset sleepnow` / 到点 → 内核**先做常规睡眠**，再由 standby 转 | `hbfx-ahbm` 在**策略阶段直接改写** `params->sleepType` |
| 是否过 S3 语义 | 要 | **不要**（这是假设的核心） |
| `hibernatemode` | **25** ⇒ `pmset_default_mode = false` | **3** ⇒ `= true` |
| 是否开 ahbm | ❌ 从没开过 | ✅ **首次开** |

---

## 2. 本轮配置（已落地）

### 2.1 EFI（工作区 `EFI/oc/config.plist`，已自动同步到 ESP）

| 项 | 变动 | 说明 |
|---|---|---|
| `Kernel/Add` | **加回 `HibernationFixup.kext`**（idx 1，紧跟 Lilu） | 文件本就在 `EFI/oc/Kexts/`；**V1.5.4 = Latest，release note 原文 "Added constants for macOS 26 support"（2025-07-07）** |
| `boot-args` | **追加 `hbfx-ahbm=3 -hbfxdbg`** | `3` = bit0(启用自动休眠) + bit1(只在合盖时)；`-hbfxdbg` 为取证 |
| `rtcfx_exclude=0E-FF` | **保留** | 休眠密钥走 NVRAM，不依赖 RTC 放行；禁写 RTC 仍是防 005 的主防线 |
| `Misc/Boot/HibernateMode` | **保留 `NVRAM`** | 恢复侧设定，与保存侧不冲突 |

**为什么用 `hbfx-ahbm=3` 而不是 `1`**：
上游 README 原文 —— *"If this flag is set, system will hibernate instead of regular sleep (**flags below can be used to limit this behavior**)"*、
*"`WhenLidIsClosed` = 2: Auto hibernation can happen when lid is closed"*。
⇒ `1` = **每次**常规睡眠都改写成休眠（一旦失败，连现在唯一可用的 Deep Idle 都没了）；
⇒ `3` = **只在合盖时**改写 ⇒ `pmset sleepnow`（开盖）仍是常规 Deep Idle ⇒ **保留安全网**。

**为什么没加 `DoNotOverrideWakeUpTime`（bit6=64）**：源码里它会
`if (setupHibernate && doNotOverrideWakeUpTime && !forceHibernate) { if (vars->standbyTimer != 0) return result; }`
⇒ **取消休眠**，与目的相冲。（代价：会走一次 `setMaintenanceWakeCalendar`，见 §7 风险。）

### 2.2 pmset（**已设**）

```
sudo pmset -a hibernatemode 3 standby 1 standbydelaylow 86400 standbydelayhigh 604800
```

**★ 这两个 gate 是硬性前置，缺一个 ahbm 就 100% 假阴性。** 三条独立证据：

| # | 来源 | 原文 / 实测 |
|---|---|---|
| ① | **上游源码** `kern_hbfx.cpp:1197` `isStandbyEnabled()` | `pmset_default_mode = (latestHibernateMode == (kIOHibernateModeOn \| kIOHibernateModeSleep))` ⇒ **必须 == 3**；`standbyEnabled = deepSleepEnabled \|\| autoPowerOffEnabled` |
| ② | **本机现场 ioreg**（设之前） | `"Standby Enabled" = No`；且 **`AutoPowerOff` 属性根本不存在** ⇒ `standbyEnabled = false \|\| false = FALSE` ⇒ ahbm 代码块的 `while` **一次都不进** |
| ③ | **本机历史脚本** `EFI/scripts/pmset-hibernate.sh` 注释 | 「`hibernatemode` 单独设了不管用，必须同时给 `standby`」；「真正**不受支持**的只有 `autopoweroff`/`autopoweroffdelay`」|

设后的验证（实测）：

```
hibernatemode 3 · standby 1 · standbydelaylow 86400 · standbydelayhigh 604800
ioreg "Standby Enabled" = Yes      ← 已从 No 翻转
```

**为什么把 `standbydelay` 调大**：`standby` 启用后，睡满 `standbydelay` 会转入 standby（写镜像 + 断内存电）
—— 那正是**已知会挂**的路径。调大后 `standby` 只当"闸门"用，不会因超时误触发。

---

## 3. 测试步骤（需要人做）

1. **保存所有工作**（后面可能需要长按电源键强制关机）。
2. **重启**（kext 必须开机加载）。
3. **重启后先做 §4 的四项前置核验**（我来跑）。
4. **物理合盖**。
5. **等 40–60 秒。**
   - 观察：风扇是否停 / 键盘灯是否灭 ⇒ **断电 = 进了休眠**；风扇仍转 = 还在 Deep Idle。
6. **开盖**，等屏幕亮起。
7. **我取证**（§5）。

> ⚠️ 测试期间**保持插电**（电量 > 50% ⇒ 走 `standbydelayhigh`，不会超时触发 standby）。
> ⚠️ 不必先退出 WorkBuddy：`NoIdleSleepAssertion` 只挡**空闲自动睡**，不挡合盖。

---

## 4. 重启后的四项前置核验（缺一不可，否则测试无效）

| # | 检查 | 命令 | 期望 |
|---|---|---|---|
| 1 | boot-arg 是否真传到内核 | `nvram boot-args` | 含 `hbfx-ahbm=3` |
| 2 | **kext 是否真加载**（铁律①：用 IOKitDiagnostics 实例计数，不用 `ioreg -c`） | `ioreg -d 0 -l -w0 \| grep -c HibernationFixup` | **≥ 1** |
| 3 | pmset 是否还在（重启不重置，但要确认） | `pmset -g \| grep -E "hibernatemode\|^ standby"` | `3` / `1` |
| 4 | gate 属性 | `ioreg -rn IOPMrootDomain -d 1 \| grep "Standby Enabled"` | `Yes` |

---

## 5. 预期形态与判据

### ✅ 成功
- 合盖后 **10–30 s** 断电（风扇停）
- 开盖后从镜像恢复（比 Deep Idle 唤醒慢，屏亮约 10–20 s），桌面与时间正常
- `pmset -g log` 出现 **`Entering Hibernate`**
- `-hbfxdbg` 日志出现 `Auto hibernate: ... set hibernate values` / `hibernate now`

### ❌ 失败 A —— 同 09-16 签名（进休眠前硬断电）
- 合盖后直接断气；开盖**无任何反应**；`pmset -g log` 里这次会话**没有** `Wake from`
- 处理：**长按电源键**强制关机

### ❌ 失败 B —— POST 005
- 重启后 HP 屏报 `Real-Time Clock Power Loss (005)`，时间回到 `2019-01-01 08:00`
- 处理：**进 BIOS 重设时间 → F10 保存**（非永久损坏）
- 含义：本机在断内存电时 RTC 也丢电（与 §二十五 定论一致）

### ❌ 失败 C —— ahbm 没生效（仍走 Deep Idle）
- 合盖后正常深睡，功耗仍是 ~5 W，**无 `Entering Hibernate`**
- `-hbfxdbg` 日志显示以下任一条：
  - `Auto hibernate: clamshell is open, do not force to hibernate` ⇒ **合盖状态没被识别**（`Clamshell.app` 假合盖？）
  - `Auto hibernate: setupHibernate 0` ⇒ `standbyTimer` 等条件没满足
  - **完全没有 `HBFX` 日志** ⇒ kext 没加载 / boot-arg 没传进去
- ⇒ 说明是**配置问题而非平台问题**，可继续调（例如改用 `hbfx-ahbm=1` 去掉合盖限制）

**取证命令**（我来跑）：
```bash
pmset -g log | grep -E "Entering (Sleep|Hibernate)|Wake from" | tail -25
log show --last 20m --predicate 'process == "kernel"' 2>/dev/null | grep -i HBFX | tail -40
```

---

## 6. 回滚（一条命令）

```bash
# pmset 侧（立即生效）
sudo pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400

# EFI 侧（二选一）
cp docs/backups/hbfx-ahbm-2026-09-20/config.plist.before EFI/oc/config.plist   # 快照回滚
git revert <本轮 commit>                                                        # git 回滚
```
改完 EFI 后 **RealTimeSync 会在 3 秒内自动同步到 ESP**（方向：工作区 → ESP，单向）。

---

## 7. 风险（实测前已声明）

| 风险 | 量级 | 可否逆 |
|---|---|---|
| 写 8 GiB `sleepimage` | 磁盘占用 + SSD 磨损 | ✅ 可删 |
| 断电期间 RTC 丢电 ⇒ **POST 005** | 中等（09-16 为 3/5） | ✅ 进 BIOS 改时间 |
| 失败后需长按电源键 | — | ⚠️ 可能丢未保存数据 ⇒ **测试前保存** |
| 会走一次 `setMaintenanceWakeCalendar`（写 RTC 闹钟寄存器 `0x01/0x03/0x05`） | 低 | ① 不在 `rtcfx_exclude` 区间内，也不在休眠密钥区 `0x80–0xAB`；② 按 §二十五，005 的根因是"断电期 RTC 掉电"而非"写了某寄存器" |
| 固件 / SPI 写入 | **0** | — |

---

## 8. 台账（变动前值，供回滚核对）

| 项 | 变动前 | 变动后 |
|---|---|---|
| `pmset hibernatemode` | `0` | `3` |
| `pmset standby` | `0` | `1` |
| `pmset standbydelaylow` | `10800` | `86400` |
| `pmset standbydelayhigh` | `86400` | `604800` |
| `ioreg "Standby Enabled"` | `No` | `Yes` |
| `Kernel/Add` 数量 | 30 | **31** |
| `boot-args` | `…rtcfx_exclude=0E-FF -rtcfxdbg` | `…rtcfx_exclude=0E-FF -rtcfxdbg hbfx-ahbm=3 -hbfxdbg` |
| config.plist sha256（改前） | `a9c01104d146…` | `9051c778b67e…` |

备份：`docs/backups/hbfx-ahbm-2026-09-20/config.plist.before`

---

## 9. 待办（结果出来后）

- [ ] 更新 `EFI/scripts/pmset-hibernate.sh` 的**硬闸与结案注释** —— 它现在写着「本机真休眠已证伪，不要再用 auto/on/test」，
      而本轮正是要推翻它。硬闸是 `FORCE_HIBERNATE=1`，**不拦直接 `pmset -a`**（所以本轮能set上）。
- [ ] 若成功 ⇒ `s4-requirements-audit.md` §7.10(c) 由 🟡 升为 🟢，并改写"出远门关机"的默认结论。
- [ ] 若失败 ⇒ 「所有已知手段均已试过」，**"没解"才算真正闭环**。
