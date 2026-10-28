# S4 休眠改走 NVRAM（2026-10-28）

> 取代 `docs/s4-hibernate-principle-2026-10-28.md`（那份是「放开 RTC 0x80–0xAB」路线）。

## 一、为什么放弃 RTC 路线

Apple 的休眠密钥位置是硬编码的：

```c
// Include/Apple/IndustryStandard/AppleRtc.h
#define APPLE_RTC_HIBERNATION_KEY_ADDR    0x80
#define APPLE_RTC_HIBERNATION_KEY_LENGTH  0x2C   // "effectively equals sizeof (AppleRTCHibernateVars)"
#define APPLE_RTC_CHECKSUM_START          0x0E
#define APPLE_RTC_TOTAL_SIZE              0x100
#define APPLE_RTC_MAIN_CHECKSUM_ADDR1     0x58   // 校验范围 [0x0E, 0x100)
#define APPLE_RTC_MAIN_CHECKSUM_ADDR2     0x59
```

`0x2C = 44` 字节，正好 `0x80–0xAB`，与 `AppleRTCHibernateVars`
（`signature[4]+revision+booterSignature[20]+wiredCryptKey[16]`）完全吻合。

**问题在于主校验和覆盖 `[0x0E, 0x100)`，包含 `0x80–0xAB`。**

而 OpenCore 的 `rtc-blacklist` 不是「拦截写」，是**内存模拟**：

```c
// Library/OcRtcLib/AppleRtcRam.c  :: OcAppleRtcRamInstallProtocol
GetVariable2 (OC_RTC_BLACKLIST_VARIABLE_NAME, &gOcVendorVariableGuid, ...);
for (Index = 0; Index < RtcBlacklistSize; ++Index)
    mEmulatedRtcStatus[RtcBlacklist[Index]] = TRUE;

// SyncRtcWrite: 命中 mEmulatedRtcStatus ⇒ 只写内存，永不落真实 RTC
```

⇒ 若「封 0x58/0x59、放开 0x80–0xAB」，就会内容变、校验和不跟
⇒ boot.efi 判 mismatch ⇒ 调 `AppleRtcRamReset` 把 `0x40–0xFF` 清零 ⇒ **密钥自毁**。
（`AppleRtcRam.c:354` 注释："Apple implementation calls AppleRtcRamReset on checksum mismatch."）
这正是本机历史上「坏 RTC 2 次」的机制。

**两条路只能选一条：**要么两边一起放开（=让 Apple 自由改 BIOS 的 CMOS 区 0x10–0x2F），
要么两边都别碰。选后者。

## 二、NVRAM 腿此前为什么不存在

HibernationFixup 的设计目标只覆盖「RTC 只有 1 bank（128 B）」的机器，README 开篇原话：

> But in case if you have to limit your RTC memory to **1 bank (128 bytes)**, it doesn't work

本机 RTC 是 256 B，于是：

```c
// HibernationFixup 1.5.4  kern_hbfx.cpp:89-100
if (result == KERN_SUCCESS || ioHibernateState == kIOHibernateStateHibernating) {
    if (!callbackHBFX->checkRTCExtendedMemory()) {        // ← 本机恒为 true，整段跳过
        ...
        OSData *rtc = OSDynamicCast(OSData, getPMRootDomain()->getProperty(kIOHibernateRTCVariablesKey));
        if (rtc && !nvstorage.exists(...)) nvstorage.write(...);
    }
}
```

```c
// Lilu  kern_rtc.cpp:44
bool RTCStorage::checkExtendedMemory() {
    uint8_t off = 0xB4; /* APPLERTC_POWER_BYTE_PM_ADDR */
    return read(off, 1, &dst);          // 能读到 0xB4 就算"RTC 够用"
}
```

⇒ 判定恒 true ⇒ **一个字节都不写**。实证：`nvram -p | grep -c -i hiber` 至今 = **0**。
09-16 那次装同版本 1.5.4 + `HibernateMode=NVRAM` 的 6 次失败，根因就在这里——
`HibernateMode=NVRAM` 让 OpenCore 去读一个**永远为空**的变量，比不设还差。

没有任何 boot-arg 能绕过这个门控（`hbfx-dump-nvram` 也不行：它路由的 `packA`
写的是 `AAPL,PanicInfo%04d`，是 panic 信息 dump，与休眠变量无关）。

## 三、改动：自编译 fork，新增 `-hbfxforce`

上游 1.5.4 源码，3 个文件 4 处：

| 文件 | 改动 |
|---|---|
| `kern_config.hpp` | 加 `bootargForceNvram {"-hbfxforce"}`；加 `bool forceNvram {false}` |
| `kern_start.cpp` | `readArguments()` 里解析 `-hbfxforce` |
| `kern_hbfx.cpp:91` | `if (!checkRTCExtendedMemory() \|\| ADDPR(hbfx_config).forceNvram)` |
| `kern_hbfx.cpp:96` | 加两条 `DBGLOG`：打印 PMRootDomain 里该键是 present 还是 MISSING，以及字节数 |

构建（本机已具备：clang 21 / Xcode 26.5 / `~/MacKernelSDK` / 本地 `Lilu.kext` 自带 `Resources/Headers`）：

```bash
# 1) 源码解压后，把依赖软链进项目目录
ln -sfn <repo>/EFI/OC/Kexts/Lilu.kext  ./Lilu.kext
ln -sfn ~/MacKernelSDK                 ./MacKernelSDK

# 2) 带日志编译（DBGLOG 在纯 Release 下会被编译掉，必须 -DDEBUG=1）
xcodebuild -project HibernationFixup.xcodeproj -scheme HibernationFixup \
  -configuration Release -derivedDataPath /tmp/hbfx_build_dbg \
  GCC_PREPROCESSOR_DEFINITIONS='DEBUG=1 $(inherited)' build
```

产物 `87488 B`（上游 release `58112 B`），校验点：

- `strings ... | grep -c -e "-hbfxforce"` = 1
- `strings ... | grep -c "NVStorage path entered"` = 1
- `otool -l | grep -c __DWARF` = 0（确认非 debug 目标）
- `OSBundleLibraries as.vit9696.Lilu = 1.2.4`（本机 1.7.3 满足）

日志只在 `-hbfxdbg` 时输出（`ADDPR(debugEnabled)` 控制），平时零开销。

## 四、配置（`EFI/OC/config.plist`）

| 项 | 新值 | 说明 |
|---|---|---|
| `Kernel/Add[1]` | `HibernationFixup.kext` | fork 版，紧跟 Lilu |
| `Misc/Boot/HibernateMode` | `NVRAM` | 只读 NVRAM。`Auto` 会先读 RTC，见下方「为什么不用 Auto」 |
| `Misc/Boot/HibernateSkipsPicker` | `true` | 恢复时跳过选择器 |
| `Misc/Debug/Target` | `69`（`0x45`） | `0x01\|0x04\|0x40`。0x40 是原计划的 boot-log 通道，**实测无效**（见第五节） |
| `boot-args` | `rtcfx_exclude=0E-FF … -hbfxdbg -hbfxforce` | 全封 RTC + 强制 NVRAM + 日志 |
| `rtc-blacklist` | `242 B`（`0x0E–0xFF`） | 全封，含 `0x80–0xAB` |
| `Kernel/Quirks/PowerTimeoutKernelPanic` | `false` | 超时不 panic，免污染判读 |
| `UEFI/Drivers` | `ResetNvramEntry.efi` 启用 | 真正的 Reset NVRAM 逃生口，另有 `CMD+OPT+P+R` |
| `Misc/Security/AllowNvramReset` | **已删除** | OC 1.0.x 移除了该键，留着 ocvalidate 报 `No schema`，且不生效 |

相对上一版（RTC 路线）的实质变化：`rtcfx_exclude` 与 `rtc-blacklist` **从「留出 80–AB」改回「全封」**。

### `AllowNvramReset` 是死配置（2026-10-28 纠正）

此前把 `Misc/Security/AllowNvramReset=true` 当成「Reset NVRAM 逃生口」，**错了**。

- `ocvalidate`（1.0.9 MOD）报：`OCS: No schema for AllowNvramReset at 0 index, context <Security>`
- 官方 `Docs/Configuration.tex` 全文搜不到该键，`Library/OcMainLib/OpenCoreMisc.c` 也没有解析
- 官方给的替代品是驱动 `ResetNvramEntry.efi`：*"Adds a menu entry which resets NVRAM and
  immediately restarts. Additionally adds support for hotkey `CMD+OPT+P+R`"*（conf.tex:7320）

本机 `EFI/OC/Drivers/ResetNvramEntry.efi` 早已存在且 `UEFI/Drivers` 里 Enabled ⇒ 逃生口**其实一直是好的**，
只是不在那个键上。注意代价（conf.tex Note 2）：Reset NVRAM 会清掉非 `BlessOverride` 的启动项，
`LauncherOption=Short` 时 OC 自身启动项受保护，Windows 的 `Windows Boot Manager` 条目会被清，
但 OC 仍能从 EFI 文件扫到并启动，可事后重建。

### 为什么不用 `Auto`

`Auto` = `RTC | NVRAM`，而 RTC 分支在前：

```c
// Library/OcBootManagementLib/AppleHibernate.c:134-146
if (HibernateMask & HIBERNATE_MODE_RTC) {
  for (Index = 0; Index < sizeof (AppleRTCHibernateVars); Index++)
    RtcRawVars[Index] = OcRtcRead (Index + 128);
  HasHibernateInfoInRTC = RtcVars.signature[0] == 'A' && ... == 'L';
  HasHibernateInfo = HasHibernateInfoInRTC;
}
```

它会校验 `'AAPL'` 签名（所以纯垃圾不会误判），但 `OcRtcRead` 是直读硬件、**不经过** `rtcfx_exclude`
（那只拦 AppleRTC kext）。本机 09-16/09-17 那几次失败很可能在 RTC 里留下过 `AAPL` 签名，
一旦命中就会被优先采信、盖掉 NVRAM 的正确 44 B，而且日志看起来像 "RTC hibernation is 1"。
既然 NVRAM 腿已经打通，RTC 分支只剩负价值 ⇒ 改成 `NVRAM`（官方 toolTip 明确支持该值）。

## 五、必要条件清单（2026-10-28 16:50 状态）

macOS 走 S4 要同时满足 9 条，任一条断了就恢复不了。按链路顺序：

| # | 条件 | 状态 | 依据 / 缺口 |
|---|---|---|---|
| 1 | 固件支持 S4 | ✅ | `FACP-1.aml` `FLAGS=0x002384A5`：bit7 `RTC_S4`=1、bit16 `S4_RTC_STS`=1；Windows/Linux 同机实测可 S4 |
| 2 | 磁盘能放下镜像 | ✅ | 16 GB 内存 / 系统卷 193 GB 可用 |
| 3 | macOS 侧开启休眠 | ✅ | `s4-arm.sh arm` 设 25，已生效 |
| 3b | **`standby` 必须为 1** | ✘ | **2026-10-28 17:04 实测卡在这**：`standby 0` 会彻底关掉镜像写入（`man pmset`），`hibernatemode 25` 被静默降级成普通睡眠。见 1.1 节。`sleepimage` 本身不是前提，是结果 |
| 4 | macOS 把 44 B 密钥交出来 | ❓ | 需 `PMRootDomain` 提供 `kIOHibernateRTCVariables`，macOS 26 上未验证 |
| 5 | kext 把它写进 NVRAM | ✅ | fork + `-hbfxforce` 绕过 `checkRTCExtendedMemory()` 门控 |
| 6 | OC 从 NVRAM 读回 | ✅ | `HibernateMode=NVRAM`；读到后校验长度必须 **= 44**、签名必须 **`AAPL`** |
| 7 | OC 交出 `boot-image-key`/`boot-signature` | ✅ | `AppleHibernate.c:189-204` 自动写，格式对了就必定执行 |
| 8 | boot.efi 解密 sleepimage 并恢复 | ❓ | 只能实测 |
| 9 | 出问题能判读 | ⚠️ | 主判据改走内核侧（见下）。OC 侧 `boot-log` 实测取不到 |

`⏳` 是待执行动作，`❓` 是只能靠一次实测回答的未知。

### 1.1 2026-10-28 17:04 第一次实测：没进休眠；根因是 `standby 0` 抑制了镜像写入

`arm` 成功（AC 侧 `hibernatemode 25`、`sleep 0`），17:04:19 菜单睡眠、17:08:35 按电源键唤醒，
睡了 256 秒。**但走的是 Deep Idle，不是 S4**：

| 判据 | 实测 | 读法 |
|---|---|---|
| `pmset -g log` | `Entering Sleep state due to 'Software Sleep pid=217'` | 普通睡眠，**没有** `Entering Hibernate` |
| 唤醒类型 | `Wake from Deep Idle [CDNVA] : due to PWRB/User` | S0ix，不是 S4 |
| `WakeTime` | 2.443 sec | 与历史 Deep Idle 唤醒一致（S4 恢复不可能是这个量级） |
| `kern.hibernatecount` | **0** | 从未成功 |
| `/System/Volumes/VM/sleepimage` | **不存在** | 镜像从未被写 |
| VM 卷 `disk1s6` 已用 | 1.0 MB（只有 `kernelcore`） | 从未放过镜像 |
| `vm.swapusage` | `total = 0.00M` | VM 子系统没有任何文件 |
| NVRAM `boot-image*` | 无 | 从未写成过 |

#### 根因：`standby = 0` 会直接关掉休眠镜像写入

`man pmset` 原文（本机手册，逐字）：

> `hibernatemode` supports values of 0, 3, or 25. **Whether or not a hibernation
> image gets written is also dependent on the values of standby and autopoweroff**
>
> To disable hibernation images completely, ensure hibernatemode standby and
> autopoweroff are all set to 0.

反过来读：**`standby 0` ⇒ 不写镜像**。此时 `hibernatemode 25` 是个空标志，睡眠照常走
普通睡眠（本机即 Deep Idle）。第一次 `arm` 时脚本把 `standby` 设成了 0 —— 依据是
"25 是立刻落盘、与 standby 的渐进逻辑无关"，**这个判断是错的**，被上面这句手册原文直接否掉。

正确的组合是 `hibernatemode 25` **加** `standby 1`：`standby` 负责"允许写镜像"这个开关，
`hibernatemode 25` 负责"写完就断内存电"。`standbydelay` 在 25 下不参与（它管的是
3 模式"先睡 RAM、若干分钟后再落盘"），但设一个 300 s 的值可以作为兜底退路。

#### 已被证伪的旧判断（留档，避免再犯）

17:04 之后曾判断"macOS 只在启动时按当时的 hibernatemode 分配 sleepimage，所以改完 25 必须重启"，
并据此在脚本里加了硬门槛。**17:17 重启后该判断被实测推翻**：`hibernatemode` 仍是 25，
`/System/Volumes/VM/sleepimage` **依然不存在**，VM 卷仍只有 `kernelcore`，
`dynamic_pager` 仍是 `not running`（`launchctl print system/com.apple.dynamic_pager` → `state = not running`）。

结论：`sleepimage` 不是"启动时预分配"的前置条件，而是休眠动作的结果 —— 只有真的决定写镜像时
内核才会去创建/扩展它。所以它不存在**不构成阻塞**，脚本里那条硬门槛已降级为提示。

**★ 位置陷阱（上次就搞错过）**：两台卷上都可能有同名文件，不是同一个：

```
/System/Volumes/VM/sleepimage      ← VM 卷（disk1s6，nobrowse,noexec），真正的镜像位置
/var/vm/sleepimage                 ← Data 卷（disk1s4）上的另一份，本机 0 字节、mtime 停在 10-27 12:37
```

用 `stat -f "inode=%i dev=%d"` 可证两者 `dev` 不同（16777226 vs 16777227）。
`kern.hibernatefile` 指向的是 `/var/vm/sleepimage`，但实际镜像落在 VM 卷。

**下一步**：重新 `arm`（这次会写 `standby 1`），然后按 6.1 的操作前提睡一次。
判读只看 `sysctl kern.hibernatecount` 与 `pmset -g log` 里有没有 `Entering Hibernate`。

**第 9 条的实测结果（2026-10-28 16:50，重启后）**：`Target` 已从 5 改成 69 并确认运行态生效，
但 `ioreg -lw0 | grep -c '"boot-log"'` = **0**，`IODeviceTree` 里根本没有该属性。
本机 OC 文件日志此前也是坏的（13 份 262144 B 全零）⇒ **OC 的 `OCB:` 日志在本机拿不到**，
`Target` 那一位开不开都一样。判读改走内核侧，且这套判据足以区分第 4 条成立与否：

| 要看什么 | 命令 | 读法 |
|---|---|---|
| macOS 有没有交出密钥 | `log show --last 30m --predicate 'eventMessage CONTAINS "HBFX"'` | `PMRootDomain key present` + `is N bytes` = 交了；`MISSING` = 没交（第 4 条不成立）。**必须在你的终端跑**：AI 沙箱里会报 `Cannot run while sandboxed` |
| 是否真的 hibernation | `sysctl kern.hibernatecount` | 成功一次 +1（当前 **0**，从未成功） |
| 镜像是否写了 | `ls -lh /System/Volumes/VM/sleepimage` | 应 ≈16 GB、mtime 是刚才。**别用 `/var/vm/`，那里是 Data 卷上的 0 字节残留** |
| 系统怎么记的 | `pmset -g log \| grep -e Hibernat -e "Entering Sleep"` | 出现 `Entering Hibernate` 而非 `Entering Sleep` |

## 六、验证与判读

### 6.1 操作前提：**接屏测**、不许合盖

**外屏不拔** —— 日常就是接外屏使用，拔屏测出来的"成功"没有意义；S4 必须在接屏状态下成立才算数。

外屏也确实不需要被当成变量排除，理由三条：

1. **S4 恢复是完整重新初始化**，不是 S0ix 式的"保电、只关部分电路"。`hibernatemode 25` 断内存电后，唤醒走的是 boot.efi 读镜像 → 内核接棒 → 驱动重新 probe，IGPU 从零 init，外屏链路训练路径与**冷启动完全一致**。冷启动时外屏能出图，S4 恢复时就没有理由不行。
2. **内建屏是主屏**（`Main Display: Yes`、`port 0`、`connector-type 0x0002`），唤醒后它先亮，本身就是判读窗口。外屏（`port 6`/`port 7`、`connector-type 0x0004`）回没回来是**独立观测项**，记下来即可，不影响成败判定。
3. 真要出问题，把外屏当**对照变量**比当**前置条件**更有价值：第一次带屏失败，第二次拔屏 —— 这样才区分得出"是 S4 本身不行"还是"多屏拖累"。先拔了反而把这个信息永久丢掉。

**不许合盖** —— 本机 `ioreg -n IOPMrootDomain` 实测：

```
"AppleClamshellCausesSleep" = No
"AppleClamshellState" = No
```

合盖判定是 **AC + 外接显示器 ⇒ clamshell 模式 ⇒ 合盖不睡、继续用外屏跑**。你以为"合盖就睡了"，实际上机器的睡眠路径根本不是要测的那条；测出来的"没进休眠"会被误读成 S4 失败。

另外 DSDT 里挂了**两个 LID 设备**（`ioreg -c AppleACPIDevice` 可见两个 `LID` → `AppleACPILid`，`IOPMrootDomain` 里 `"AppleACPILid"=2`），合盖事件的归属本身不可靠，行为不可复现。一次实验只能有一个变量，合盖会同时引入 clamshell 判定 + LID 事件归属两个未知。

**唤醒只按电源键** —— 本机 `pmset -g` / `pmset -g custom` 里**没有 `lidwake` 项**，开盖唤醒不可依赖。合盖睡下去再开盖，很可能不动，容易被误判成"醒不来"。

**唤醒后若内建屏也不亮** —— 先拔插一次 HDMI 等 10 s；仍黑则长按电源键重启，开机后查 `pmset -g log`，就能区分「恢复了但屏没亮」和「压根没恢复」。不要凭黑屏直接判失败。

```bash
bash EFI/scripts/s4-arm.sh check        # 只读体检，A 段 11 项静态判据
bash EFI/scripts/rtc-protect-verify.sh  # 四层防护核验
sudo bash EFI/scripts/s4-arm.sh arm     # 武装当前电源源
# ... 睡一次 ...
sudo bash EFI/scripts/s4-arm.sh disarm  # 无论成败先回滚
```

`rtc-blacklist` 的运行态**可以读到**（之前判断读不到是错的）：

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:rtc-blacklist
```

一次睡眠后判读。**注意判据方向**：OC 读到 `IOHibernateRTCVariables` 后会立刻把它擦掉——

```c
// AppleHibernate.c:173-183
if (!EFI_ERROR (Status)) {
  gRT->SetVariable (L"IOHibernateRTCVariables", &gAppleBootVariableGuid, ..., 0, NULL);  // 长度 0 = 删除
```

所以**醒来后 `nvram` 里还有这个变量 = OC 压根没消费它**，是坏信号；
看不到它才是正常（前提是 boot-log 显示读到过）。

| 现象 | 含义 | 下一步 |
|---|---|---|
| `kern.hibernatecount` 从 0 变 1，且系统恢复原会话 | NVRAM 路线成立 | 转日常配置，`-hbfxdbg` 可移除 |
| 计数变了，但唤醒黑屏 / 半途重启 / 回到登录界面重开 App | 卡在 boot.efi 解密或镜像 | 查 sleepimage 大小与加密；再考虑 `ReservedMemory` / CSM |
| `pmset -g log` 里只有 `Entering Sleep`、没有 `Entering Hibernate`，计数仍 0 | 没走休眠路径 | 先查 `pmset -g \| grep standby` 是否为 **1**（`standby 0` 会关掉镜像写入）；再核对 `hibernatemode 25` 与 boot-args 的 `-hbfxforce` |
| 醒后 `nvram` 里仍能查到 `IOHibernateRTCVariables` | 没被识别成休眠唤醒（或 HibernateMode 未生效） | 查 boot-args 是否真带上 `-hbfxforce`、OC 版本是否吃到新 config |

**本机取不到 OC 侧 `OCB:` 日志**（实测依据见下），所以判读走内核侧四条：

```bash
sysctl kern.hibernatecount                             # 基线 0，成功一次 +1
ls -lh /System/Volumes/VM/sleepimage                   # 应 ≈16 GB、mtime 是刚才（别用 /var/vm/）
pmset -g log | grep -e Hibernat -e 'Entering Sleep' | tail -5
log show --last 30m --predicate 'eventMessage CONTAINS "HBFX"' | tail -30
```

`boot-log` 取法**在本机无效**，留档备查（`Target` 已含 `0x40` 也取不到，
`ioreg -lw0 | grep -c '"boot-log"'` = **0**，且 ESP 根目录 13 份 `opencore-*.txt` 全是 262144 B 零字节）：

```bash
ioreg -lw0 -p IODeviceTree | grep boot-log | sed 's/.*<\(.*\)>.*/\1/' | xxd -r -p | grep -a OCB
```

v3 的日志判据（`-hbfxdbg` 开着）：

```
HBFX: NVStorage path entered (forceNvram=1), PMRootDomain key present
HBFX: kIOHibernateRTCVariables is 44 bytes
```

注意第二条在二进制里是格式化串 `is %u bytes`（`strings` 实测确认），所以 grep 时用
`kIOHibernateRTCVariables is` 这个前缀，别拿固定的 `44 bytes` 去匹配。

若字节数不是 44，说明结构变了；若是 `MISSING`，说明前提不成立。

## 七、回滚

| 层级 | 动作 |
|---|---|
| 只关 fork 逻辑 | boot-args 去掉 `-hbfxforce`（kext 留着无害，此时行为等于上游） |
| 回上游 kext | `cp -R docs/backups/hbfx-fork-20261028-1630/HibernationFixup.kext.upstream EFI/OC/Kexts/` |
| 回整个配置 | `cp docs/backups/hbfx-fork-20261028-1630/config.plist.before EFI/OC/config.plist` |

不改固件、不写 RTC ⇒ 无不可逆风险。最坏情况是「睡下去醒不来，需长按电源键」，
NVRAM 里的 `IOHibernateRTCVariables` 可用 OpenCore 的 Reset NVRAM 清掉。
