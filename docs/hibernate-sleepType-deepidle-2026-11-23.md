# mode 3 安全睡眠实测：本机 DeepIdle 下永不写盘（2026-11-23）

> 判据等级：≥95%（日志一手 + xnu 源码 + 文件系统三重交叉）。本文推翻 11-23 上午"mode 3 可安全写盘取证"的假设。

## 1. 实验设置

```
hibernatemode 3   standby 0   standbydelay 60/60   sleep 1
sleepimage  8589934592 B (8GB, = 16GiB × 50%)   inode 38305315   mtime 10:17:52   flags 无 uchg
ioreg  "Hibernate Mode" = 3   "Hibernate File" = "/var/vm/sleepimage"
```
基线快照 `~/automation-workspace/hib-snap-before.txt`（10:18:35）。

执行 `sudo pmset sleepnow` → 10:24:29 入睡（`Software Sleep pid=43449`）→ 10:27:44 唤醒（`PWRB/User`，WakeTime 2.498s），实际睡 195s。
`HibernateStats 10:27:44 hibmode=3` 记到第 54 条。

## 2. 五项取证结果

| 项 | 结果 |
|---|---|
| sleepimage inode / mtime / size | 38305315 / 10:17:52 / 8GB —— **三者全未变，文件没被打开写过** |
| `IOHibernateRTCVariables`（/options） | **不存在** |
| HIBLOG 关键字（`hibernate image path` / `IOPolledFileOpen` / `pin_swap` / `hibernate_setup` / `alloc_page_lists`） | **命中 0 条** |
| `PMRD: hibernateMode 0x0` | **10:24:33.085 出现**（同一窗口前面几条 phase 0/1/2 都是 `hibernate 0x3`） |
| `PMRD: sleep params v2, type 7` | phase 0 / 1 / 2 全部 **type 7 = DeepIdle** |
| `ioreg IOPMSystemSleepType` | **7** |
| `IOPMSystemSleepPolicyHandler`（IOPMrootDomain） | **Yes**（已安装） |
| 已加载 kext | `X86PlatformPlugin 1.0.0` + `X86PlatformShim 1.0.0` |

## 3. 机制链（源码钉死）

1. `X86PlatformPlugin` 通过 `kIOPMInstallSystemSleepPolicyHandlerKey` 注册 handler —— `IOPMRD.cpp:9763-9772`，装完置 `IOPMSystemSleepPolicyHandler=true`（现场值为 Yes）。
2. handler 对本机返回 `sleepType = 7`（DeepIdle）。x86 上若无 handler，会落到 `IOPMRD.cpp:5675` 的 Invalid 分支按 mode 位推导（mode 3 → SafeSleep=3）；**有 handler 时走 handler 结果**，故恒为 7。
3. `getSleepTypeAttributes(7)` 查表 = **0**，没有 `kIOPMSleepAttributeHibernateSetup` —— `IOPMRD.cpp:5317`（表内 `/* deepidle */ 0`）。
4. `evaluateSystemSleepPolicyEarly` 里 `if (... & HibernateSetup) == 0` → **`hibernateDisabled = true`** —— `IOPMRD.cpp:5666-5670`。
5. `getHibernateSettings()` 里 `if (hibernateDisabled) *hibernateModePtr = 0;` —— `IOPMRD.cpp:5763-5764`，并 DLOG 出 `hibernateMode 0x0`（与实测日志逐字对上）。
6. `IOHibernateSystemSleep()` 在 `IOHib.cpp:504`：`if (!gIOHibernateMode || !gIOHibernateFilename[0]) return kIOReturnUnsupported;` → **直接返回，不写盘**。

## 4. 一条勘误（我自己上一轮判错的地方）

`kern.hibernatefile` 从空变成 `/var/vm/sleepimage`，我曾当成"已过 504 行"的证据 —— **错**。
`IOHib.cpp:495-500` 的 `strlcpy(gIOHibernateFilename, ...)` 在 504 检查**之前**，所以 filename 有值只证明"读到了 `Hibernate File` 属性"，**不证明任何写盘动作**。真正的分水岭是 `hibernateMode` 是否为 0。

## 5. 结论

- **本机不存在"写盘但不断电"这个形态**：写盘需要 `HibernateSetup` 属性，而本机 sleepType 恒为 DeepIdle(7)，属性为 0 ⇒ hibernate 被永久跳过；只有 mode 25（清掉 `kIOPMSleepModeSleep` 位）才会被 `IOPMRD.cpp:5405-5418` 强制成 Hibernate（有 HibernateSetup）从而写盘。
- 因此 `hibernatemode 3` 与 `hibernatemode 0` 在**写盘行为上等价**（都不写），差别只在 pmset 显示值与 `gIOHibernateMode` 非零（因 hibernateDisabled 而无效）。
- 副作用：DeepIdle 睡眠期间没有内存镜像兜底 ⇒ 睡到一半断电/亏电，会话必丢。
- 要验证 S4 只能 mode 25 = 写盘后 `kIOHibernatePostWriteHalt` 断电，**必然牺牲会话**；而恢复仍受 OC `rtc-blacklist`（0x0E–0xFF 全段）拦截 boot.efi 读 RTC 0x80 段元数据所限。

## 6. 处置建议

保留 `hibernatemode 3` + `standby 0` 作为会话安全基线（纯 S0ix、3.6W、合盖不断电）。
S4 若要继续，唯一有意义的下一步是「OC 侧伪造 RTC 0x80–0xAB 读取（数据源取 NVRAM `IOHibernateRTCVariables`）」+ 一次强制断电实测，代价一次会话；在此之前不必再跑 mode 3 类实验。

---

## 7. 终局更新（11-23 12:40，覆盖 §5/§6）

§5/§6 写于内核补丁之前，**已被实测推翻，作废**。以本节为准。

**patch 已生效（≥95%）**：`Kernel/Patch` NOP 掉 `hibernateDisabled → *mode=0` 的 `jne` 后，11-23 12:08 合盖睡眠日志出现完整写盘链：
`hibernateMode 0x3` → `hibernate image path` → `hibernate_page_list_setall(preflight 0) found pageCount 2639101` → `IOHibernatePollerOpen(0)` → `PMStats: Hibernate write took 9353 ms` → `hibernate_write_image done(0)`。
sleepimage mtime `10:17 → 12:10`，inode/大小对齐。会话完整保留（写盘后回 S0ix）。
⇒ **本机确实能"mode 3 写盘 + 不断电"**，§5 的"不存在此形态"结论作废。

**两个新事实**：
1. `kern.hibernatemode` = **31**（0x1F，含 Encrypt 位），而 pmset = 3、内核日志打印 0x3。patch 跳过清零后写入全局变量的是 `IOPMrootDomain+0x1f4` 的 31，不是 pmset 值。含 Sleep 位 ⇒ 仍 PostWriteSleep、会话安全；Encrypt 位只在"万一恢复"时有影响。
2. S4 断电恢复的第一道门 `H:IS` 要 `boot-signature` + `boot-image-key` 两个 NVRAM 变量同时在。全系统核查：`boot-image-key` 在 BootKernelExtensions.kc / SystemKernelExtensions.kc 各 0 次，xnu 里只建符号从不读写；boot.efi 全文对该变量只有 GetVariable 与 SetVariable 删除、**无写入**；HBFX 也不写。本次 boot-log 三条 `#[EB|H:IS] 0`（Err 0xE = NOT_FOUND）。⇒ 缺写入方，把握 ~85%。

**终局决策（11-23 12:48 更新，用户拍板撤补丁）**：
- **S4 断电实测不做**。两条独立理由：① 会话保留是硬约束，S4=断电=会话必丢，定义上互斥，非配置/源码可解；② 恢复链 `H:IS` 缺写入方（~85%）且恢复后 iGPU 花屏社区无解（>90%）。投入产出比不成立。
- **patch 已撤除（12:48）**。撤的原因不是安全，而是**性价比翻盘**：12:08 那次睡眠证明写盘完成的同一瞬间（uptime 893.9s done(0) → 894.0s Wake）机器被唤醒，整段只睡 73 秒；历史上无补丁时同样场景能睡数小时。即 patch 把"睡得久但不写盘"换成"写盘但每次 73 秒被叫醒"——那份镜像本就是半成品（`H:IS` 缺写入方，真断电未必能恢复），拿睡眠质量换它不划算。用户一句"之前没这问题，第一次发现"直接命中：这就是补丁引入的新变量。
- 撤法：删 `Kernel/Patch` 中 Comment 含 `DeepIdle: allow hibernate write-back` 的条目 → 同步 ESP → **重启才生效**（内核补丁在 OpenCore 引导期应用）。config sha `dc17a641 → 523e9b37`，仓库与 ESP 逐字节一致；11:49 外部新增的 3 颗 kext 与 Kernel/Add 重排原样保留。
- `sleep=1` 无需再改：补丁撤掉后 mode 3 不写盘，闲置 1 分钟自动睡只是进 S0ix、不丢会话，地雷自动消失。
- pmset 保持 `hibernatemode 3` + `standby 0`（会话安全基线）。8GB sleepimage 留在磁盘无妨；想收回改 `hibernatemode 0` 即可。
