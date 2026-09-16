# 第 1 轮：档 A（standby 路径）—— ⚠️ 结论已撤回，测试条件不成立

> ## ⚠️ 撤回声明（2026-09-16 复查，用户质疑"为什么 A 判死了？不用再确认一下？"）
>
> 本档案原先给出的结论是「**standby 机制在 AOAC 平台结构性失效，档 A 判死**」。
> **该结论错误，现予以撤回。** 实测数据显示的只是「**这一次没触发**」，
> 而**测试条件本身就不满足触发前提**：
>
> | # | 我原先的说法 | 实际情况 | 证据 |
> |---|---|---|---|
> | 1 | 「`man pmset` 写明 `standbydelay` 与插不插电无关」 | ❌ **错**。`standby` 是**电池侧**计时器，前提是**电池供电**；AC 侧对应的是 `autopoweroff` | 少数派/转载原文：standby 需"电池供电+无外接设备+无网络活动+无外接显示器"；autopoweroff 需"外部电源供电+…"；二者是**两个并行计时器**，按供电条件二选一 |
> | 2 | （未考虑） | 本机 AC 下**根本没有 autopoweroff** | `pmset -g cap` 实测：AC 能力列表**无** `autopoweroff` → 插电时深睡计时器**不存在** |
> | 3 | 「已超出 `standbydelay` 300 s」 | ⚠️ 实际只超 **38 秒**（300s 到期 → 38s 后就被唤醒），而写 16 GB 镜像需 30~90 s | 精确计算：10:09:41 生效 +300s = 10:14:41，实际唤醒 10:15:17 |
> | 4 | （未考虑） | EFI **缺 `HibernationFixup.kext`** —— 黑苹果休眠的**必要件**，负责把内核的加密密钥写进 NVRAM | 本机 `Kexts/` 无此 kext；`HibernateMode=NVRAM` 因此是**空转** |
> | 5 | 「AOAC 平台不存在 S3→S4 步骤」 | ⚠️ 方向对但表述不准：AOAC（BIOS `Low Power S0 Idle`）**与 S4 休眠冲突**，是**冲突**不是"不存在"，可通过关闭 AOAC 让路 | Dell Latitude 5410（**同代 Comet Lake + AX201 + MacBookPro16,x**）EFI 仓库：*"Low Power S0 Idle ... conflicts S3 Sleep wakeup and S4 Sleep"*，其解法是 modGRUBShell 关 AOAC + `HibernationFixup.kext` + `hbfx-ahbm=129` |
>
> **本次实测仍然有效的部分**：系统确实**正常入睡、正常唤醒、会话零丢失**
> （338 s → 唤醒 2.617 s），以及唤醒链路含 USB（`DriverReason:XHC`）。
> 这些与档位无关，是 Deep Idle 的基线表现，继续有效。
>
> **下一步**：见 `round2-plan.md`。档 A 需在**拔电 + 装 `HibernationFixup`** 后才谈得上复测。

**时间** 2026-09-16 10:09:39 → 10:15:17（**338 秒**，5 分 38 秒）
**配置** `hibernatemode 3` + `standby 1` + `standbydelaylow/high 300`（电池 + AC 两段）
**⚠️ 测试时的供电状态：AC（插电）—— 这正是本档**不可能**触发的前提条件**

## 结果

| 判据 | 实测 | 结论 |
|---|---|---|
| 进入睡眠 | `Entering Sleep state due to 'Software Sleep pid=174'` | ✅ 正常入睡 |
| 睡眠形态 | `Wake from **Deep Idle** [CDNVA]` | ⚠️ S0ix，**不是** standby |
| 睡眠时长 | 338 s | 已超出 `standbydelay` 300 s |
| 转 standby | **日志零记录** | ❌ 未触发 |
| 写休眠镜像 | `sleepimage` mtime 停在 `10:01:54`（未变） | ❌ 未执行 |
| `kern.hibernatecount` | **0** | ❌ 未休眠 |
| **是否冷启动** | `kern.boottime` 仍是 `10:01:31`（未变） | ✅ **未冷启动，会话完整保留** |

## 日志原文（硬证据）

```
2026-09-16 10:09:39 Sleep   Entering Sleep state due to 'Software Sleep pid=174':
                            TCPKeepAlive=disabled Using AC (Charge:100%) 338 secs
2026-09-16 10:15:17 Wake    Wake from Deep Idle [CDNVA] :
                            due to LPCB XDCI/UserActivity Assertion Using AC (Charge:100%)
2026-09-16 10:15:17 WakeDetails  DriverReason:XHC -
2026-09-16 10:15:17 HibernateStats  hibmode=3 standbydelaylow=300 standbydelayhigh=300
2026-09-16 10:15:17 WakeTime  WakeTime: 2.617 sec
```

系统**知道** `hibmode=3`、`standbydelay=300`，却什么也没做。

## 推断（已修正）

~~`standby` / `standbydelay` 是传统 S3 时代的机制，AOAC 平台不存在「S3→S4」这个可转换的步骤。~~

**修正后的推断**（依据见顶部撤回声明）：

1. **首要原因**：测试在 **AC（插电）** 下进行，而 `standby` 计时器要求 **电池供电**。
   AC 侧本该由 `autopoweroff` 接管，但本机 `pmset -g cap` **不支持 autopoweroff**
   → 插电时深睡计时器链路上**没有任何一个计时器在工作**。
2. **次要原因**：即便计时器生效，**38 秒**的余量不足以写完 16 GB 镜像。
3. **结构性原因**：AOAC（`Low Power S0 Idle`）与 S4 休眠**冲突**
   （同平台 Dell 5410 先例），且本机可能还缺 `HibernationFixup.kext`。

→ 三条都指向「**测试条件不成立**」，而非「机制已死」。

## 副作用观察（本轮附带收获）

- **Deep Idle 下基础睡眠健康**：5 分 38 秒睡眠 → 唤醒 **2.617 秒**，会话零丢失。
- **唤醒源含 USB**：`DriverReason:XHC` → 外接 USB 鼠标确实参与唤醒链路，
  测试必须拔掉。
- `sleepimage` 自创建起 **1 GB 且从未被写过**（16 GB 内存，社区口径应为 16 GB）
  → 待观察，可能是 macOS 26 行为，也可能是休眠不可用的信号。

## 下一步

**不再是"切档 B 就完事"**（原计划），而是先补齐前置，见 `round2-plan.md`：

1. **装 `HibernationFixup.kext`**（最新 1.5.4，2025-07-07，已支持 macOS 26）
   —— 无论走档 A 还是档 B，黑苹果休眠都需要它传递加密密钥；
   否则 `HibernateMode=NVRAM` 是空转。
2. **拔电复测档 A**（`standby` 要求电池供电）。
3. **插电场景**只能走不依赖计时器的路径（`hibernatemode 25`
   或 `hbfx-ahbm`），因为 AC 侧无 `autopoweroff`。
