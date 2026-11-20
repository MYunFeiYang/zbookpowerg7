# 开源社区 S4/Hibernation 路线二次调研（2026-11-20 17:3x）

> 起因：用户「再找开源社区尝试一下？」。目标是复核上一轮"结案"是否漏了社区已有解法。
> 方法：国外一手源优先（OpenCore 官方 Configuration.tex、GitHub 上游 issue、实操者仓库），本地记忆仅作线索。
> 把握度标注：≥80% 才算结论。

## 一、四条新线索与逐条判决

### 线索 1：`Misc/Boot/HibernateMode` 有第四档 `NVRAM`
- **官方原文**（`Docs/Configuration.tex` 3472-3486 行）：
  > Hibernation detection mode. The following modes are supported:
  > `None` — Ignore hibernation state. / `Auto` — Use RTC and NVRAM detection. /
  > `RTC` — Use RTC detection. / `NVRAM` — Use NVRAM detection.
- 关键在标题：**"Hibernation detection mode"** ＝ 检测模式，不是存储模式。
- 社区实操者（X250/T530 的 @jozews321）声称：*"with HibernateMode set to NVRAM you are only using NVRAM to do the hibernation"*。
- **判决：社区说法不成立（>90%）**。官方定义 + 11-18 已核准（"只影响 OC 是否跳过 picker，不改变 boot.efi 需 RTC 变量才能真正恢复"）+ 11-18 17:23 实测（屏蔽 0x80-0xAB 后 mode 25 冷启动、恢复从未尝试）。**HibernateMode 不能替代 RTC。**

### 线索 2：社区是否做了"RTC 写重定向到 NVRAM"
- 唯一的固件层拦截器是 `UEFI/ProtocolOverrides/AppleRtcRam`。官方原文（9062-9071 行）：
  > Replaces the Apple RTC RAM protocol with a builtin version.
  > Note: Builtin version ... may **filter out I/O attempts** to certain RTC memory addresses.
  > The list ... in `4D1FDA02-…:rtc-blacklist` as a data array.
- 语义是「过滤 I/O」，**不存在"写入暂存到 NVRAM、读取时回放"的实现**。
- 底层 `Library/OcRtcLib/OcRtcLib.c` 只有 `OcRtcRead/OcRtcWrite`（直接 in/out 0x70/0x71）+ `OcRtcChecksumApple`，无缓存层。
- **判决：RTC→NVRAM 重定向在 OC 上游不存在（>90%）。** 要做只能自写 OC 驱动 + 自写 kext，工程量大，且终点仍卡花屏（见线索 4）。

### 线索 3：X250 的完整 S4 配置清单（`zamkara/Lenovo-Thinkpad-X250-Hackintosh` issue #11）
实操者 @flo-at-work 给出的可复现配置：HibernationFixup 1.5.0（不需要 RTCMemoryFixup）+ DevirtualiseMmio=True + MmioWhitelist 两组地址 + DiscardHibernateMap=False + EnableWriteUnprotector=True + RebuildAppleMemoryMap=False + SyncRuntimePermissions=True + DisableLinkeditJettison=True + **HibernateMode=NVRAM** + WriteFlash=True + `rtc-blacklist=5859` + NVRAM `E09B9297-7928-4440-9AAB-D1F8536FBF0A` + ReservedMemory 条目。
- 他的结果：**hibernatemode 25 能恢复、会话保留成功**，但——
  > "I get a Bios Checksum Error on **every boot/reboot after having resuming** from Hibernation"
  > "It seems that Hibernation mode 25 is triggering a CMOS error on next startup after resuming"
- 注意 `rtc-blacklist=5859` 只屏蔽主校验和（0x58-0x59），**0x80-0xAB 是真写进 CMOS 的**——这正解释了为什么他能恢复、又为什么会报 checksum。
- **判决：社区最成功案例同样卡在 005 上，至今未解（>85%）。** 他的 005 形态是"BIOS checksum error"，HP 的形态更重（load factory defaults）。

### 线索 4：iGPU 唤醒花屏，社区有没有解
- 同一 issue 里 @jozews321 主动问花屏，并说：
  > "I've seen online people with T420, T430, X230, and more second and third gen Thinkpads but **I haven't been able to find info on how to solve it**"
  临时规避手段：**再睡一次唤醒 / Shift+Ctrl+Eject 开关显示屏 / 合盖再开**。
- 仓库维护者 @5T33Z0：*"I have never seen anything like this, sorry."*
- 同族 issue（T530 #48）对黑屏的正解是 `DiscardHibernateMap` + `ReservedMemory`，但那是修**"二次休眠/空闲自动休眠"**，不是修**"恢复瞬间花屏"**。
- **判决：iGPU 恢复花屏，社区无根治方案（>90%）。** 只有"事后再睡一次"的规避。

## 二、我自己途中提出又撤回的一个假说（留痕防再犯）
- 假说：本机 `DevirtualiseMmio=true` 但 `MmioWhitelist` 为空 ⇒ iGPU MMIO 被 devirtualise ⇒ 恢复花屏。
- 撤回依据（官方 `Configuration.tex` 1337-1376 行）：MmioWhitelist 保护的是 **"addresses critical for particular firmware functioning"**，让该区域**保持虚拟化**以便固件直接通信；Dortania Comet Lake 页明说"Mmost users can ignore this section"。
- **结论：空白名单与花屏无因果关系（>85%），撤回该假说。**

## 三、为什么这条路仍然不通（硬约束链，逐环已有独立证据）

1. boot.efi 恢复的唯一凭据 = RTC 0x80–0xAB 的 `AppleRTCHibernateVars`（'AAPL' 签名 + booterSignature + wiredCryptKey）。依据：xnu `IOHibernateIO.cpp` 全文件唯一写入点（无 SMC/NVRAM 分支）+ 11-18 实测屏蔽后恢复从未尝试。
2. 该数据要跨 S4 断电存活 ⇒ 必须真写 CMOS ⇒ 无任何 OC/kext 手段能让它"只在内存/NVRAM 里存在又被 boot.efi 读到"（线索 2）。
3. HP BIOS 在下次上电发现 CMOS 异常 ⇒ POST 005 ⇒ **load factory defaults**（HP 官方定义，比 ThinkPad 的"按 Esc 过"重得多）。
4. 即便①-③全绕过，恢复瞬间 iGPU 显示管线未重编程 ⇒ 花屏，社区无解（线索 4）。

## 四、如果用户非要试，最小代价路径（仅供定价，不推荐）

| 步骤 | 内容 | 风险 |
|---|---|---|
| 1 | `git checkout` 恢复 11-01 的 S4 配置（`ff8fe31` 前后） | 无（可回滚） |
| 2 | 补齐 T530/X250 的 quirk 组合（RebuildAppleMemoryMap、ReservedMemory 等），但**保留** 0x80-0xAB 可写 | 中（平台不同，可能 boot 失败） |
| 3 | `hibernatemode 25` → 重启 → 合盖 → 拔电 2-3 min → 按键 | 高（005 ⇒ BIOS 重置，需重设 CFG Lock/VT-d/启动顺序） |
| 4 | 若花屏：合盖再唤醒（社区唯一规避） | 不确定能否救回 |

**收益**：3.6W → 0.1-0.2W。**代价**：每次休眠后 BIOS 回出厂默认（可能直接导致黑苹果启动配置失效）+ 每次恢复后要额外操作。
按用户既定约束（保留会话 + 不接受 005），**该路径不满足约束，不推荐执行。**

## 五、结论
- 社区没有我们没走过的路。真正的新增只有两点：①确认 `HibernateMode=NVRAM` 是"检测"而非"存储"（堵住了"改用 NVRAM 就免 005"的幻想）；②拿到 X250 可复现清单，而它**同样死在 005 上**。
- `sleep-power-final-2026-11-20.md` 的结案结论**维持不变**：3.6W 为最终值（≥90%）。
- 唯一改变的是判据强度：从"我们推断不可行"升级为"社区最成功的实操者停在同一个 005 上"。
