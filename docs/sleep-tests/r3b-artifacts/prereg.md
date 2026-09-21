# R3b 预注册（写于动手之前）

> 时间：2026-09-20 18:5x ｜ 触发：用户「动」
> 纪律来源：`next-test-agenda.md` §2、`~/.workbuddy/MEMORY.md`「实测前必须先写清三件事」

## 0. 唯一变量（严格一次只动一个）

| 键 | 改前（实读 18:56） | 改后 |
|---|---|---|
| `standbydelaylow` | 86400 | **0** |
| `standbydelayhigh` | 604800 | **0** |
| `hibernatemode` | 3 | 3（不动） |
| `standby` | 1 | 1（不动） |
| EFI / `boot-args` | `hbfx-ahbm=1 -hbfxdbg` | 不动 ｜ **不重启** |

`pmset -g custom` 两电源域同值；确认 **Battery 段的 `standbydelaylow/high` 都读回 0**（若被钳位 ⇒ 执行脚本自行中止，不触发睡眠）。

## 1. 预期形态

### 1.1 成功（→ 说明 `hbfx-ahbm` 这条路可通）
| # | 判据 | 期望 |
|---|---|---|
| ① | 内核 `PMRD: sleep params v2, type 5, flags 0x1` | **phase 1 也保持 5**（R3 就是在这里被打回 7） |
| ② | `phase 2` 的 type | **4**（Hibernate，源 `hbfx2.cpp:477-487`） |
| ③ | `PMRD: hibernateMode` | **0x3**（不再 0x0） |
| ④ | `sysctl kern.hibernatemode` | **3**（实时判据） |
| ⑤ | `/var/vm/sleepimage` 的 **mtime** | 落进**本次睡眠时刻**（不再等于 17:19 开机占位） |
| ⑥ | `kern.hibernatecount` | **> 0** |
| ⑦ | `pmset -g log` | 出现 `Entering Hibernate` / `Entering Standby` |
| ⑧ | 唤醒方式 | 需**按电源键**（内存已断电） |

### 1.2 失败
- **软失败**：phase1 仍翻回 `type 7`、`hibernateMode 0x0` ⇒ 与 R3 完全相同 ⇒ 说明卡点不止 `standbydelay`，`hbfx-ahbm` 这条路**到此为止**。
- **硬失败**（= 09-16 那一档）：入睡后**无响应**，电源灯亮/风扇停、按键盘无声 ⇒ 需**长按电源键 10 s** 强制断电，再正常开机。开机后可能报 **POST 005（CMOS 校验和）**，属已知现象。

## 2. 回滚点（唯一的"撤销"动作）

```bash
sudo pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400
```

- **由看守脚本自动执行**：唤醒后 ≤ 1 分钟（取证完立刻回滚），或冷启动后立刻执行。
- 基线出处：`.workbuddy/memory/MEMORY.md` L30「基线 `0`/`0`（待回滚）」。
- 若自动回滚失败 ⇒ 手工跑上面一行（`standbydelay` 两个值回到 3 h/24 h ⇒ 不再有"立即断内存电"）。

## 3. 不可逆风险（逐条）

| 风险 | 性质 | 兜底 |
|---|---|---|
| 写休眠镜像到内部盘 `/var/vm/sleepimage`（1 GiB） | **可逆**（覆盖写，非新增分区） | 无需要 |
| 断电瞬间未保存数据丢失 | 可逆（无未保存工作） | 已确认 |
| RTC/CMOS 被写（真休眠必经） | 已知（005） | 四层 RTC 防护在位 |
| **长按电源强制断电** | 硬件无损伤，仅文件系统 last-mount 脏标记 | APFS 有 journal，历史已 5 次无损伤 |
| `standbydelay 0` 期间**任何**睡眠都立即断内存电 | **危险项** | 看守自动回滚；**不留过夜** |

## 4. 观测者纪律（R3 的教训）

- `pmset sleepnow` 到真正入睡 **≈30 s**（关屏 → `darkwakelinger` 15 s → 协商）⇒ **不要提前读日志**。
- `pmset -g log | tail` 尾部是「当前断言摘要」块 ⇒ 必须按关键字过滤。
- `log show` 必须带 `--info --debug`，且经提权（沙箱跑不了 `log`）。
