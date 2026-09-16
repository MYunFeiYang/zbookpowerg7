# 睡眠档位调优测试记录

> ⚠️ **2026-09-16 复查：`round1` 的"档 A 判死"结论已撤回。**
> 真因是**测试条件不成立**（`standby` 要求电池供电，而测试在插电下进行），
> 且 EFI 缺 `HibernationFixup.kext`。详见 `round1-tierA-result.md` 顶部撤回声明
> 与 `round2-plan.md`。

## 为什么必须先重启
`Misc/Boot/HibernateMode` 是 **OpenCore 在启动时读取**的配置项。
当前运行的 macOS 会话由旧配置引导 —— 此时若休眠，
下次开机 OC 不认休眠镜像 → 冷启动（会话丢失，系统不坏）。
故任何休眠测试前，必须先重启一次让 OC 加载 `NVRAM` 值。

## 关键前提（2026-09-16 修正）

| 计时器 | 生效条件 | 本机状态 |
|---|---|---|
| `standby` | **电池供电** + 无外接设备 + 无网络活动 + 无外接显示器 | 电池下未测 |
| `autopoweroff` | **外部电源供电** + 无外接设备 + 无网络活动 | ❌ `pmset -g cap` 无此项 → **插电时无深睡计时器** |

→ **插电场景下，`standby` 这条路永远走不通**（不是坏，是没有计时器）。
→ 插电想深睡，只能靠**不依赖计时器**的路径：`hibernatemode 25` 或 `hbfx-ahbm`。

## 档位与安排

| 档 | 配置 | 睡眠行为 | 状态 |
|---|---|---|---|
| 基线 | `hibernatemode 0` `standby 0` `standbydelayhigh 86400` | 永不落盘，内存全程带电（≈5W 墙插） | 原状 |
| A | `hibernatemode 3` `standby 1` `standbydelay* 300` | 先内存睡眠 → 到点转落盘断电 | **需拔电复测** |
| B | `hibernatemode 25` | 每次睡眠立即写镜像 + 断电 | **当前已设置，未测** |
| C | 清 FADT bit21 / BIOS 关 AOAC → 传统 S3 | 实验级；**代价是放弃 Deep Idle** | 排最后，不建议 |

## 缺失的前置件

**`HibernationFixup.kext`（最新 1.5.4，2025-07-07，支持 macOS 26）未安装。**
它负责把内核的 `IOHibernateRTCVariables`（加密密钥）写进 NVRAM，
而 `HibernateMode=NVRAM` 让 OC 从 NVRAM 读 —— **只有读端、没有写端 = 空转**。
→ 装它之前，任何档位都不该期望成功。

## 判据（醒来后立刻跑）

1. `sysctl kern.hibernatecount` → **从 0 变 1** = 真正落盘断电过（最硬证据）
2. `stat -f "%m" /var/vm/sleepimage`（或 `ls -la`）→ mtime **更新** = 镜像被写过
3. `pmset -g log | grep -E "Entering Standby|Entering Hibernate"` → 出现记录
4. `sysctl kern.sleeptime kern.waketime` → 两时间差 ≈ 睡眠时长
5. 体感：睡着后机器**变凉**（5W → 0.2W）

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
