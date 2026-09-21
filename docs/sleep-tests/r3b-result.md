# Round 3b 结果 —— `standbydelay 0` 实测（2026-09-20 19:01 → 09-21 08:52）

> **性质**：**议程 ① 已完成**（不是"待做"）。会话在触发睡眠后中断，直到 09-21 09:53 用户说「继续 S4 睡眠」才回来收账。
> **一句话结论**：**`standbydelay 0` 让系统真的"走进去"了 —— 但走不回来。没写出任何休眠镜像，机器睡下后内核停摆，只能强制断电。与 09-16「睡下即断气」同档。⇒ `hbfx-ahbm` 这条路到此为止。**
> **本轮零 EFI 改动**（只有 2 条 `pmset`），已回滚。

---

## 0. 结论（先看这个）

| 问题 | 答案 | 最硬证据 |
|---|---|---|
| 有没有进 S4 / 真休眠？ | **没有** | `/var/vm/sleepimage` 前 16 字节**全 0**；`IOHibernateState=<00000000>`；NVRAM 无 `IOHibernate*`；`kern.hibernatecount=0` |
| `standbydelay 0` 生效了吗？ | **生效了**（读回 0，未被钳位） | `run.log`: `解析 low='0' high='0'` |
| 那睡眠发生了什么？ | **睡下 → 内核停摆 5.7 min → 重新开机** | 内核日志 **19:01:00–19:08:23 零行**；19:08:23 起 PID 144/154/167/176/343 = **新 boot 的早期 PID** |
| 有正常唤醒吗？ | **没有** | `pmset` 那条 `Entering Sleep` **未回填时长**；无 `Wake from`；`HibernateStats` 断档（最后一条 18:36:35=14） |
| 用户侧后果 | **反复关机重启 5 次** | `ShutdownCause 5` @ 19:15:39 / 19:23:20 / 19:34:19 / 19:59:38 / 20:04:42；`last` 对应 19:15/19:23/19:34/19:59/20:04 reboot |
| 顺带炸出什么？ | **① 又一次 RTC/CMOS 被写坏（时钟 → 2019-01-01）② 看门狗完全失效** | 见 §3、§4 |
| 现在的配置 | **已回滚**（09-21 09:57 执行） | `standbydelaylow=10800 / standbydelayhigh=86400 / standby=0 / hibernatemode=0` |

---

## 1. 时间线（全部一手，标出处）

| 时刻 | 事件 | 出处 |
|---|---|---|
| 09-20 19:00:54 | R3b 脚本以 root 启动 | `r3b-artifacts/run.log` |
| 19:01:07 | `.armed` 写入 boottime=1789895948（=17:19:08 那次 boot） | `r3b-artifacts/.armed` |
| 19:01:08 | 看门狗启动，记基线 `Entering Sleep=21 / Wake from=14` | `r3b-artifacts/watch.log` |
| 19:01:12 | `pmset sleepnow` rc=0；MARKER=`ARMED` | `run.log` / `MARKER` |
| **19:02:41** | **`Entering Sleep state due to 'Software Sleep pid=46197'`**（看门狗 pid） | `pmset -g log` |
| 19:02:41 → 19:08:23 | **内核日志零行**（1,716,710 行的窗口里最早一条是 19:08:23.036833） | `verdict-0921-095734.txt` §[4] |
| **19:08:23** | 日志恢复，但**已是新 boot 特征**：ppid 链上 PID 144(apsd)/154(dasd)/167(bluetoothd)/176(loginwindow)/343(searchpartyd) | `verdict2-0921-100045.txt` §[B] |
| 19:08:43 | `PMRD: Desktop mode 1` / `Clamshell enabled` | 同上 |
| 19:15:39 → 20:04:42 | **5 次软件关机 + 5 次重启** | `verdict…txt` §[7] + `last reboot` |
| 20:04:43 | 最后一次重启（pmset 认为的 "since boot" 基准） | `pmset -g log` 尾行 |
| **21:03:35** | 用户**合盖**：`PMRD: Clamshell closed 1` → `changePowerStateWithOverTo(SLEEP_STATE)` → `sleep reason Software Sleep` —— **此时 `standbydelay` 仍是 0（看门狗没回滚）** | `verdict…txt` §[5] |
| 21:04:07 | `Entering Sleep ... pid=2924`（**又一次没有时长回填**） | `pmset -g log` |
| **09-21 08:52:52** | 本机当前 `kern.boottime` = **冷启动**（08:50–08:58 窗口内无任何 hibernate 恢复痕迹） | `verdict…txt` §[1]/§[3] |
| 09-21 09:57:34 | 本轮取证（提权 uid=0） | `verdict-0921-095734.txt` |

---

## 2. 判据对照（prereg.md §1.1 的 8 条）

| # | 判据 | 期望（成功） | 实测 | 判 |
|---|---|---|---|---|
| ① | `PMRD: sleep params v2, type 5, flags 0x1` phase 1 保持 | 保持 5 | **无任何 `sleep params` 记录**（整个取证文件 0 命中） | ❌ |
| ② | phase 2 type | 4 | 无记录 | ❌ |
| ③ | `PMRD: hibernateMode` | 0x3 | 无记录 | ❌ |
| ④ | `sysctl kern.hibernatemode` | 3 | **0** | ❌ |
| ⑤ | `sleepimage` mtime | = 本次睡眠时刻 | mtime = **2019-01-01 08:01:05**（≠19:02） | ❌ |
| ⑥ | `kern.hibernatecount` | > 0 | **0** | ❌ |
| ⑦ | `pmset` 出现 `Entering Hibernate`/`Standby` | 有 | 只有 `Entering Sleep` | ❌ |
| ⑧ | 唤醒方式 | 需按电源键 | **需强制断电**（含内核停摆） | — |

**8/8 未达标。** ⇒ 与议程 §2.4 预先写下的第二种结果**逐字吻合**：
> 「若卡点其实在 S4 事务本身（不是配置）⇒ **重现 09-16 的「睡下即断气 + POST 005」**」

---

## 3. 副产物①：又一次 RTC/CMOS 被写坏（时钟 → 2019-01-01）

两条独立来源指向同一个"错误时刻"：

| 来源 | 值 | 说明 |
|---|---|---|
| `stat /var/vm/sleepimage` | mtime = **2019-01-01 08:01:05** | 17:19 那次 boot 时它是 17:19（会随 boot 变化）⇒ 说明**被某次 boot 重建** |
| `log show` 输出（§[5] 窗口内） | **70 行**条目时间戳 = `2019-01-01 08:00:44` | log 数据库里**存在一个时钟 ≈ 2019-01-01 08:00:44 的 boot session** |

⇒ 差值 21 s = "boot 后创建 sleepimage 占位"的典型间隔。
⇒ **与既有结论一致**：四层 RTC 防护全开，macOS 自己仍会写坏 CMOS（`AppleRTC` 休眠密钥 `0x80–0xAB` 落在 HP 校验和区）。
⚠️ **待用户确认**：那几次开机时 BIOS 是否报过 POST 005 / 系统时间是否跑到 2019 —— 若「是」，此条从"推断"升为"实锤"。

---

## 4. 副产物②：看门狗（自动兜底）**完全失效** —— 这是本轮最重要的工程教训

| 检查项 | 结果 | 说明 |
|---|---|---|
| `MARKER` | 仍是 `ARMED 2026-09-20 19:01:12` | 未写 `DONE` / `BOOT-ROLLBACK` |
| `.armed` | **仍在** | `CLEANUP()` 会删它 ⇒ 说明 CLEANUP **没跑过** |
| `/var/log/watch.log` | **不存在** | watch.sh 第 13 行的冷启动回退路径（`OUT=/var/log`）**从未被走到** |
| `/Library/LaunchDaemons/com.wb.r3b.watch.plist` | **不存在** | 但 `.armed` 还在 ⇒ **不是自己的 CLEANUP 删的** |
| `wb-r3b-watch.out/.err` | 存在、0 字节、mtime 19:01:08 | launchd 起过 job，脚本自己重定向走了 |

**最可能的凶手**：`/Library/LaunchDaemons/` 目录 mtime = **20:13**，同时 `com.sangfor.aTrustDaemon.plist` = 20:13、`com.sangfor.eaio.service.plist` / `com.sangfor.saio.appwatch.plist` = **20:06**；19:56 有 `system_installd` 诊断报告 ⇒ **公司安全软件 aTrust（深信服）在 19:56–20:13 之间做了自我更新/重装，期间清掉了我们的 plist**（多家安全软件会接管/清理 LaunchDaemons）。

**结论（工程纪律，下次必守）**：
1. 🔴 **不要把"自动回滚"托付给 `/Library/LaunchDaemons` 的自建守护** —— 会被第三方安全软件清理，且失效时**无声**。
2. 🔴 **更根本的**：这次失效的**不是回滚逻辑，而是"机器根本没走到正常唤醒"** —— 冷启动回滚路径依赖 `RunAtLoad`，而 plist 已被删 ⇒ 两条腿都断。
3. ✅ **改用**：① 测试窗口内**人在旁边**，测完立刻手工回滚；② 或把回滚做成 `pmset` 之外的"可自证"形态（例如写入一个开机就报的 `~/Desktop/请回滚.txt` + `osascript` 弹窗），而不是静默守护。

---

## 5. 已执行的回滚（09-21 09:57）

```bash
sudo pmset -a hibernatemode 0 standby 0 standbydelaylow 10800 standbydelayhigh 86400
```
读回：`standbydelaylow 10800 / standbydelayhigh 86400 / standby 0 / hibernatemode 0`（= 基线）。
⇒ **"睡后立即断内存电"这个地雷已解除。**

---

## 6. 对 S4 这件事的净影响

- **议程 ① 关闭**：`hbfx-ahbm` + `standbydelay 0` 这条路**实测走不通**，而且代价比 R3 更高（R3 是软失败=正常唤醒；R3b 是硬失败=强制断电 + 写坏时钟）。
- **`hbfx-ahbm` 这条从未测过的路径，现在测过了 ⇒ 判不通行**。
- **"在已试过的配置空间里没解"这句，现在覆盖到了最大**（R3 软失败 + R3b 硬失败 + 09-16 五次 mode 25 失败）。
- ⚠️ **仍未闭环的一点**：R3b 的内核轨迹**整段丢失**（`sleep params` 0 命中）⇒ 无法确证"是否真的走到 `type 4`"。但**行为证据（内核停摆 + 未写镜像 + 需强制断电）已足以判"这条路不能用"**，且这正是议程预写的失败形态。
- **剩余可测**（见 `next-test-agenda.md`）：② OC 日志核 `DevirtualiseMmio`（低风险，与"S4 能不能用"关系弱）｜③ Win 功耗量准（独立价值）｜④ `dmpstore`（顺手，门后是死 S3）。

---

## 7. 证据清单（分级）

| # | 证据 | 级 |
|---|---|---|
| 1 | `pmset`: 19:02:41 `Entering Sleep pid=46197` **无时长回填**；21:04:07 `pid=2924` 同样无回填 | 🟢 本机一手 |
| 2 | 内核 19:01:00–19:08:23 **零行**（同窗口总行数 1,716,710，最早条目 19:08:23.036833） | 🟢 本机一手（提权） |
| 3 | 19:08:23 起进程 PID 全为开机早期值（144/154/167/176/343）⇒ 新 boot | 🟢 本机一手 |
| 4 | `sleepimage` = 1 GiB，**前 16 字节全 0**，mtime=2019-01-01 08:01:05 | 🟢 本机一手 |
| 5 | `IOHibernateState=<00000000>`；NVRAM 无 `IOHibernate*`；`kern.hibernatecount=0` | 🟢 本机一手 |
| 6 | 09-20 19:15:39…20:04:42 五次 `SMC shutdown cause: 5` + `last` 五次 reboot | 🟢 本机一手 |
| 7 | 21:03:35 内核 `Clamshell closed 1` → `SLEEP_STATE` → `sleep reason Software Sleep` | 🟢 本机一手 |
| 8 | 09-21 08:52:52 boot，08:50–08:58 无 hibernate 恢复痕迹 | 🟢 本机一手 |
| 9 | 看门狗：MARKER=ARMED、.armed 在、`/var/log/watch.log` 不存在、plist 不存在 | 🟢 本机一手 |
| 10 | aTrust 系 plist mtime 20:06/20:13 + LaunchDaemons 目录 mtime 20:13 | 🟢 本机一手 |
| 11 | 「看门狗被 aTrust 更新清掉」 | 🟡 **推断**（时间高度吻合，无直接删除日志） |
| 12 | 「时钟被写坏到 2019-01-01」 | 🟡 **推断**（两条独立来源同值，但缺 BIOS 侧 POST 005 确认） |
