# 睡眠档位调优测试记录

> ⚠️ **2026-09-16 复查：`round1` 的"档 A 判死"结论已撤回。**
> 真因是**测试条件不成立**（`standby` 要求电池供电，而测试在插电下进行），
> 且 EFI 缺 `HibernationFixup.kext`。详见 `round1-tierA-result.md` 顶部撤回声明
> 与 `round2-plan.md`。

---

## ⛔ 2026-09-16 18:30 结案：**本机"真休眠"路线已证伪，测试全部终止**

- **5 次真休眠尝试（11:16 / 12:04 / 13:11 / 14:39 / 18:09）全部失败**，其中 **2 次把 RTC/CMOS 写坏** ——
  重启后 POST 报 **HP 005 `Real-Time Clock Power Loss`** ＋ 系统时钟回落 `2019-01-01`。
- **`RTCMemoryFixup` 装对了也没挡住**（`rtcfx_exclude=80-FF` 语法经上游 README 核对**正确**，类实例计数 = 1）。
- **`HibernationFixup` 的 NVRAM 兜底从未触发**（失败后 `nvram -p` 无任何休眠变量）⇒ 机器死在"进入 hibernate 电源态"**之前**。
- ★ 上游 `RTCMemoryFixup` README 原文：`0x80–0xAB` 存放 `IOHibernateRTCVariables`，
  「**If any offset in this range causes a conflict, you can exclude it, but hibernation won't work.**」
  ⇒ **保 CMOS 与 保休眠，在这类硬件上互斥。**
- ⇒ **替代方案：出差/带机出门用「关机」** —— 0 W（比休眠更低）、零 RTC 风险、开机 30–40 s 与休眠唤醒相当。
- ⇒ 脚本 `pmset-hibernate.sh` 的 `auto / test / on / instant` **已加硬闸**（需 `FORCE_HIBERNATE=1`）。
- 完整取证：`round2-tierB-result.md` **§二十三**。

---

## 为什么必须先重启
`Misc/Boot/HibernateMode` 与 `Kernel/Add`（kext 清单）都是 **OpenCore 在启动时读取**的。
当前运行的会话由旧配置引导 —— 此时若休眠，OC 不认识休眠镜像 →
冷启动（会话丢失，系统不坏）。
故任何休眠测试前，必须先重启一次让 OC 加载新配置（`HibernateMode=NVRAM` + `HibernationFixup.kext`）。

## 关键前提（2026-09-16 两次修正）

| 计时器 | 生效条件 | 本机状态 |
|---|---|---|
| `standby` | 电池供电 + **无外接设备** + 无网络活动 + **无外接显示器** | AC 下未证实；**且本机常态接着外接显示器 + USB 鼠标，前提被破坏** |
| `autopoweroff` | 外部电源供电 + 无外接设备 + 无网络活动 | ❌ `pmset -g cap` **无此项** |

→ ✅ **2026-09-16 17:2x 已查明 —— 「AC 下走不通」撤回**：`pmset -g cap` 的 `-b` 与 `-c` 输出
**逐行完全相同** ⇒ 能力是**机型级**（说"AC 侧 cap 没有 X"这种框架本身就是错的）；cap **列出了
`standby`**，且 `pmset -g custom` 的 **AC 段可见 `standby`** ⇒ 按 man 判据
（"visible in `pmset -g` if the feature is supported"）**AC 侧 `standby` 受支持**。
真正不受支持的只有 `autopoweroff`/`autopoweroffdelay`（**机型级**）。详见 `round2-tierB-result.md` §二十二。
→ ★ **第 1 轮不触发的真实原因**：AC 侧当时 `standby = 0` 且 `standbydelay` 为默认 3h/24h
（10800/86400）⇒ **从未配置过触发条件**；而实测那次只睡了 **152 s**（距 10800 s 阈值**差 71 倍**）
⇒ **无效测试**，不构成"AC 走不通"的证据。
⚠️ 「外接显示器 / USB 鼠标破坏 standby 前提」那条是**社区总结** —— 本机 `man pmset` 的 standby 段
**通篇未提**外接设备条件 ⇒ 降级为**待验证假设**，不再当结论用。
→ ~~插电深睡**已配好**（§二十二 §4）：`hibernatemode 25 + standby 1`，长延迟 1 h / 2 h~~
→ ⛔ **已于 2026-09-16 18:27 撤回**：该配置在 18:09 的实测中与第 1–3 次**同型失败**
（入睡 → 断气 → 无 `Wake from` / 无 `Entering Hibernate` → 重启 POST 005 + 时钟回 2019）。
现两电源源均回 `hibernatemode 0 / standby 0`。**结论见文件顶部横幅。**

## 档位与安排

| 档 | 配置 | 睡眠行为 | 状态 |
|---|---|---|---|
| Deep Idle | `hibernatemode 0` `standby 0` | 永不落盘，内存全程带电（≈5 W 墙插） | ✅ **2026-09-16 18:27 起为现役档**（两电源源，`pmset-hibernate.sh off`） |
| ~~A 惰性深睡~~ | `hibernatemode 25` `standby 1` `standbydelay* 3600/7200` | 短睡内存秒醒 → 1~2 h 后落盘断电 | ⛔ **已证伪并停用**（18:09 实测：睡下即断气 + POST 005）；改成 `25/1/3600-7200` 也**没有改变结局** |
| ~~B 真休眠~~ | `hibernatemode 25` `standby 1` `standbydelay* 600/1800` | 短睡内存秒醒 → 10~30 min 后落盘断电 | ⛔ **已证伪并停用**；且**已拆掉地雷** —— 电池侧前提天然满足，留着它下次出门合盖必炸 |
| C 传统 S3 | 清 FADT bit21 / BIOS 关 AOAC | 实验级；**代价是放弃 Deep Idle** | 排最后，不建议 |

> ⚠️ 「档 B = 每次睡眠立即写镜像 + 断电」这条**原表述已修正**：`hibernatemode 25` **单独设了不生效**，
> 必须配 `standby 1` 作为**触发计时器**（本机无 `autopoweroff` 可用）。缺了它 ⇒ 全程 Deep Idle（14:39 实测）。

## S1 / S2 的差别（一句话）

| | S1（含 S0） | S2 |
|---|---|---|
| 换什么 | **测试条件**（拔外设、拔电） | **机制**（装 kext + 换档 25） |
| 改什么 | 无，只动 pmset | EFI：`HibernationFixup.kext` |
| 要重启吗 | 不需要 | **需要**（OC 启动时读配置） |
| 风险 | 🟢 零（第 1 轮已证会话不丢） | 🟡 中（新 kext） |
| 验证哪一段 | **计时器**：到点会不会自动断电 | **写镜像 → 断电 → 恢复** 全链路 |
| 回滚 | `pmset-hibernate.sh off` | `git revert` + 重启 |

## 缺失的前置件

**~~`HibernationFixup.kext` 未安装~~ → ✅ 已于 2026-09-16 安装（commit `85888f6`）。**

它负责把内核的 `IOHibernateRTCVariables`（加密密钥）写进 NVRAM，
而 `HibernateMode=NVRAM` 让 OC 从 NVRAM 读 —— **只有读端、没有写端 = 空转**。
现在**写端已补齐**（1.5.4，`Kernel/Add` index 1 紧挂 Lilu，依赖 Lilu ≥1.2.4 / 本机 1.7.3）。
→ 在此之前，任何档位都不该期望成功；**现在可以真正开始测了**。

## 判据（醒来后立刻跑）

1. `sysctl kern.hibernatecount` → **从 0 变 1** = 真正落盘断电过（最硬证据）
   ⚠️ 但实测冷启动恒回 0 ⇒ **别拿它当唯一判据**，要配合下面几条。
2. `stat -f "%m" /var/vm/sleepimage`（或 `ls -la`）→ mtime **更新** = 镜像被写过
3. `pmset -g log | grep -E "Entering Standby|Entering Hibernate"` → 出现记录
4. `sysctl kern.sleeptime kern.waketime` → 两时间差 ≈ 睡眠时长
5. 体感：睡着后机器**变凉**（5W → 0.2W）

### ⛔ 失败判据（本机实测 5/5 都是这个样子，务必先认它）

| 症状 | 证据 |
|---|---|
| 入睡后几分钟内**直接断气**（风扇停、灯灭，但不是正常断电） | `pmset -g log` 里**只有** `Entering Sleep`，**没有** `Wake from` / `Entering Hibernate` / `ShutdownCause` |
| 重启后 **HP POST 005 `Real-Time Clock Power Loss`** | 屏幕 |
| 系统时钟回落到 `2019-01-01`（约 35 s 后网络对时自愈） | `who -b` = `Jan  1 08:07`；开机瞬间 `date` |
| `nvram -p` 里**没有**任何休眠变量 | `HibernationFixup` 从未触发 ⇒ 死在进入 hibernate 之前 |
| `kern.hibernatecount` = **0** | 冷启动重置 |

## 回滚

```
./EFI/scripts/pmset-hibernate.sh off        # 回纯 Deep Idle
```

失败（起不来）：长按电源 → 能进系统就跑 off；macOS 也起不来则
OpenCore 菜单 Enter → Reset NVRAM（逃生口 `AllowNvramReset=true` 已开）。

## 档案索引

- `baseline-2026-09-16.txt` —— 改动前的 pmset 快照
- `round1-tierA-result.md` —— 第 1 轮实测（含撤回声明）
- `round2-plan.md` —— 修正后的复测路线 S1~S4
