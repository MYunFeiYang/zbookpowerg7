# 睡眠档位调优测试记录

> ⚠️ **2026-09-16 复查：`round1` 的"档 A 判死"结论已撤回。**
> 真因是**测试条件不成立**（`standby` 要求电池供电，而测试在插电下进行），
> 且 EFI 缺 `HibernationFixup.kext`。详见 `round1-tierA-result.md` 顶部撤回声明
> 与 `round2-plan.md`。

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

→ ⚠️ 「`standby` 在 AC 下永远走不通」这句**已撤回过头表述**：
`pmset -g cap` 的标题就是「**Capabilities for AC Power**」，其中**列出了 `standby`** ——
它只证明**可设置**，不证明**会生效**。**仍属未知**。
→ ★ **第 1 轮不触发的主因很可能是外设**：本机接着 **外接显示器 PHL 241B8Q（HDMI）**
与 **USB 光电鼠标**，「无外接设备 / 无外接显示器」两条前提均不满足。
→ 顺序改为：**S0 先摘外设（保持插电）→ S1 再拔电**，一次只动一个变量。
→ 插电想深睡，还有**不依赖计时器**的路：`hibernatemode 25` 或 `hbfx-ahbm`。

## 档位与安排

| 档 | 配置 | 睡眠行为 | 状态 |
|---|---|---|---|
| 基线 | `hibernatemode 0` `standby 0` `standbydelayhigh 86400` | 永不落盘，内存全程带电（≈5W 墙插） | 原状 |
| A | `hibernatemode 3` `standby 1` `standbydelay* 300` | 先内存睡眠 → 到点转落盘断电 | **待 S0 复测（需先拔外接显示器 + 鼠标）** |
| B | `hibernatemode 25` | 每次睡眠立即写镜像 + 断电 | **当前已设置，未测（S2）** |
| C | 清 FADT bit21 / BIOS 关 AOAC → 传统 S3 | 实验级；**代价是放弃 Deep Idle** | 排最后，不建议 |

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
